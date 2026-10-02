# Roundhouse: the fnm Node runtime on native Windows, shared by
# collect-windows.ps1 (inventory) and apply-windows.ps1 (the sealed switch and
# the bootstrap), which dot-source it. Definitions only, no parameters, so a
# dot-source never touches the caller's own; `pwsh -File node-fnm-windows.ps1
# -SelfTest` runs its fixture checks.
#
# fnm is the Node runtime source on Windows as on POSIX
# (docs/specs/2026-09-28-npm-global-manager.md §7.7). It keeps one prefix per
# version, `<FNM_DIR>\node-versions\vX\installation`, holding node.exe, the npm
# shims and node_modules. The release zip fnm installs carries no npmrc (the
# MSI adds one pointing the prefix at %APPDATA%\npm), so that directory is the
# version's npm global prefix too, and `aliases\default` is a junction to one
# of them. Off Windows (the self-check only) pwsh sees fnm's POSIX layout, with
# bin/ and lib/node_modules, so the same code runs against the POSIX fixtures.

$script:FnmOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
# The switch's lock and in-flight record: one fixed path under the profile in
# every lane (interop, the Codex control lane, the bootstrap), never under an
# XDG variable. The self-tests point it at their fixtures.
$script:NodeSwitchStateDir = Join-Path (Join-Path (Join-Path $HOME ".local") "state") "roundhouse"

function Get-FnmBinDir([string]$Installation) {
    if ($script:FnmOnWindows) { return $Installation }
    return Join-Path $Installation "bin"
}

function Get-NodeToolPath([string]$BinDir, [string]$Tool) {
    # node or npm in a Node bin directory: node.exe and npm.cmd on Windows.
    $Name = if (-not $script:FnmOnWindows) { $Tool } elseif ($Tool -ceq "node") { "node.exe" } else { "$Tool.cmd" }
    return Join-Path $BinDir $Name
}

function Get-FnmNpmRoot([string]$Prefix) {
    # npm's global node_modules under a prefix.
    if ($script:FnmOnWindows) { return Join-Path $Prefix "node_modules" }
    return Join-Path (Join-Path $Prefix "lib") "node_modules"
}

function Get-FnmInstallation([string]$Root, [string]$Version) {
    return Join-Path (Join-Path (Join-Path $Root "node-versions") $Version) "installation"
}

function Get-FnmAliasDir([string]$Root) {
    return Join-Path (Join-Path $Root "aliases") "default"
}

function Get-FnmAliasBinDir([string]$Root) {
    return Get-FnmBinDir (Get-FnmAliasDir $Root)
}

function Get-FnmRootCandidates {
    # %FNM_DIR% (this process, then the user's own setting, which a process
    # started before the migration does not see), then fnm's own default
    # (%APPDATA%\fnm) and the migration's (%LOCALAPPDATA%\fnm).
    $UserFnmDir = if ($script:FnmOnWindows) { [Environment]::GetEnvironmentVariable("FNM_DIR", "User") } else { $null }
    $AppData = if ($env:APPDATA) { Join-Path $env:APPDATA "fnm" } else { $null }
    $LocalAppData = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "fnm" } else { $null }
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Roots = New-Object System.Collections.Generic.List[string]
    foreach ($Candidate in @($env:FNM_DIR, $UserFnmDir, $AppData, $LocalAppData)) {
        if ([string]::IsNullOrWhiteSpace($Candidate)) { continue }
        if ($Seen.Add(([string]$Candidate).TrimEnd('\', '/'))) { $Roots.Add([string]$Candidate) }
    }
    return @($Roots)
}

function Test-FnmDurableBin([string]$BinDir) {
    # Durable: not per-shell state, and npm travels with its own node.
    if ([string]::IsNullOrWhiteSpace($BinDir) -or $BinDir -match 'fnm_multishells') { return $false }
    return (Test-Path -LiteralPath (Get-NodeToolPath $BinDir "npm") -PathType Leaf) -and
        (Test-Path -LiteralPath (Get-NodeToolPath $BinDir "node") -PathType Leaf)
}

function Get-FnmRoot {
    # The first root whose `default` alias holds a durable npm: the one the
    # durable npm resolves, so the runtime observed owns the globals.
    foreach ($Root in @(Get-FnmRootCandidates)) {
        if (Test-FnmDurableBin (Get-FnmAliasBinDir $Root)) { return $Root }
    }
    return $null
}

function Test-NodeVersionText([object]$Value) {
    # fnm's spelling, `v` included, as lib/npm.sh's node_version_ok.
    return $Value -is [string] -and $Value -cmatch '^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}$'
}

function Get-NodeVersionMajor([string]$Version) {
    return [int](($Version.TrimStart('v') -split '\.')[0])
}

function Test-NodeReleaseNewer([string]$A, [string]$B) {
    # A is a strictly newer plain release than B (`X.Y.Z`, optional `v`), as
    # lib/npm.sh's release_newer: also npm's own versions.
    $Pattern = '^v?([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$'
    if ($A -cnotmatch $Pattern) { return $false }
    $Left = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    if ($B -cnotmatch $Pattern) { return $false }
    $Right = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    return $Left -gt $Right
}

function Get-FnmDefaultVersion([string]$Root) {
    # The version the `default` alias links to, read from the link itself:
    # `…\node-versions\vX.Y.Z\installation`, with that version installed.
    $Alias = Get-FnmAliasDir $Root
    try { $Item = Get-Item -LiteralPath $Alias -Force -ErrorAction Stop } catch { return $null }
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return $null }
    $Target = [string]@($Item.Target)[0]
    if ([string]::IsNullOrWhiteSpace($Target)) { return $null }
    $Target = ($Target -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', '').TrimEnd('\', '/')
    if (-not [IO.Path]::IsPathRooted($Target)) { $Target = Join-Path (Split-Path -Parent $Alias) $Target }
    $VersionDir = Split-Path -Parent $Target
    $Version = Split-Path -Leaf $VersionDir
    if ((Split-Path -Leaf $Target) -cne "installation" -or -not (Test-NodeVersionText $Version) -or
        (Split-Path -Leaf (Split-Path -Parent $VersionDir)) -cne "node-versions") {
        return $null
    }
    if (-not (Test-Path -LiteralPath (Get-NodeToolPath (Get-FnmBinDir (Get-FnmInstallation $Root $Version)) "node") -PathType Leaf)) {
        return $null
    }
    return $Version
}

function Get-FnmInstalledVersions([string]$Root) {
    # Every installed version that carries a node binary, oldest first.
    $Dir = Join-Path $Root "node-versions"
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $Found = foreach ($Item in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-NodeVersionText $Item.Name)) { continue }
        if (Test-Path -LiteralPath (Get-NodeToolPath (Get-FnmBinDir (Join-Path $Item.FullName "installation")) "node") -PathType Leaf) {
            [string]$Item.Name
        }
    }
    return @(@($Found) | Sort-Object { [version]$_.Substring(1) })
}

function Select-FnmRemoteLatest([string[]]$Lines, [int]$Major) {
    # `fnm list-remote`: one version per line, LTS lines with a codename after
    # it. Only the first token is read; anything else is ignored.
    $Best = $null
    foreach ($Line in @($Lines)) {
        $First = @(([string]$Line).Trim() -split '\s+')[0]
        if (-not (Test-NodeVersionText $First) -or (Get-NodeVersionMajor $First) -ne $Major) { continue }
        if ($null -eq $Best -or (Test-NodeReleaseNewer $First $Best)) { $Best = $First }
    }
    return $Best
}

function Get-FnmCommandPath {
    # fnm itself: PATH outside fnm_multishells, then where the bootstrap puts
    # it (winget's user-scope link, the pinned release under
    # %LOCALAPPDATA%\fnm, or beside a root), which a stale PATH can miss.
    $OnPath = @(Get-Command fnm -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.Source -notmatch 'fnm_multishells' }) | Select-Object -First 1
    if ($null -ne $OnPath) { return [string]$OnPath.Source }
    if (-not $script:FnmOnWindows) { return $null }
    $Fixed = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $Fixed.Add((Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\fnm.exe"))
        $Fixed.Add((Join-Path $env:LOCALAPPDATA "fnm\fnm.exe"))
    }
    foreach ($Root in @(Get-FnmRootCandidates)) { $Fixed.Add((Join-Path $Root "fnm.exe")) }
    foreach ($Path in $Fixed) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $Path }
    }
    return $null
}

function Invoke-FnmLines([string]$Fnm, [string]$Root, [string[]]$Arguments) {
    # fnm pinned to ROOT, its stdout as lines; $null on failure, never an
    # empty "success".
    $Saved = $env:FNM_DIR
    try {
        $env:FNM_DIR = $Root
        $Lines = @(& $Fnm @Arguments 2>$null)
        if (-not $? -or ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)) { return $null }
        return , [string[]]@($Lines | ForEach-Object { [string]$_ })
    } catch {
        return $null
    } finally {
        $env:FNM_DIR = $Saved
    }
}

function Test-NpmNameText([object]$Value) {
    return $Value -is [string] -and $Value.Length -le 214 -and
        $Value -cmatch '^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*$'
}

function Test-NpmVersionText([object]$Value) {
    return $Value -is [string] -and $Value.Length -le 128 -and $Value -cmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$'
}

function Split-NpmGlobalList([object]$List) {
    # The one rule (lib/npm.sh's npm_list_detail_parse) over a parsed
    # `npm ls --global --json --depth=0`: Globals, {name: version} for every
    # global with a version; Unpinnable, the sorted names a switch cannot
    # reinstall by exact registry version (no version, file:, link: or git).
    # $null for a failed listing: unknown is never an empty set.
    if ($null -eq $List -or $null -ne $List.PSObject.Properties["error"]) { return $null }
    $Globals = [Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
    $Unpinnable = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    if ($null -ne $List.dependencies) {
        foreach ($Property in $List.dependencies.PSObject.Properties) {
            $Name = [string]$Property.Name
            $Value = $Property.Value
            if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { continue }
            $Version = if ($Value.version -is [string]) { [string]$Value.version } else { $null }
            if ($null -ne $Version) { $Globals[$Name] = $Version }
            $Resolved = if ($Value.resolved -is [string]) { [string]$Value.resolved } else { "" }
            if (-not (Test-NpmVersionText $Version) -or -not (Test-NpmNameText $Name) -or
                $Resolved -cmatch '^(file:|link:|git[+:]|github:|gitlab:|bitbucket:)' -or $Value.link -eq $true) {
                [void]$Unpinnable.Add($Name)
            }
        }
    }
    return @{ Globals = $Globals; Unpinnable = [string[]]@($Unpinnable) }
}

function Test-FnmNpmPrefix([string]$Prefix) {
    # npm's own answer to `prefix --global` names an fnm version (the
    # installation, or the default alias it is read through): no npmrc
    # `prefix=` or NPM_CONFIG_PREFIX sends the globals elsewhere, such as the
    # MSI's %APPDATA%\npm.
    if ([string]::IsNullOrWhiteSpace($Prefix)) { return $false }
    $Path = $Prefix.Trim().TrimEnd('\', '/')
    $Leaf = Split-Path -Leaf $Path
    $Parent = Split-Path -Parent $Path
    if ($Leaf -ceq "default") { return (Split-Path -Leaf $Parent) -ceq "aliases" }
    return $Leaf -ceq "installation" -and (Test-NodeVersionText (Split-Path -Leaf $Parent)) -and
        (Split-Path -Leaf (Split-Path -Parent $Parent)) -ceq "node-versions"
}

function Get-PackageBinPath([string]$NpmRoot, [string]$Prefix, [string]$Name, [string]$Bin) {
    # BIN as a bin the installed package NAME itself declares, found as npm's
    # shim in PREFIX: the proof behind an updater and a post-switch hook.
    # $null otherwise.
    $Manifest = Join-Path (Join-Path $NpmRoot $Name) "package.json"
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { return $null }
    try { $Package = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $Bins = if ($Package.bin -is [string]) { @(($Name -split '/')[-1]) }
        elseif ($null -ne $Package.bin) { @($Package.bin.PSObject.Properties.Name) } else { @() }
    if ($Bins -cnotcontains $Bin) { return $null }
    foreach ($Candidate in @((Join-Path $Prefix "$Bin.cmd"), (Join-Path $Prefix "$Bin.exe"),
        (Join-Path (Join-Path $Prefix "bin") $Bin))) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
    }
    return $null
}

function Get-NodeSwitchMarkerPath { return Join-Path $script:NodeSwitchStateDir "node-switch-inflight.json" }

function Read-NodeSwitchMarker {
    # The switch's in-flight record, or $null when none is. An unreadable
    # record still reads as in flight, with nothing to restore to.
    $Path = Get-NodeSwitchMarkerPath
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $Value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
        if ($Value -is [Management.Automation.PSCustomObject]) { return $Value }
    } catch { }
    return [pscustomobject]@{ old = $null; target = $null; unreadable = $true }
}

function Invoke-NodeFnmWindowsSelfTest {
    $Root = Join-Path ([IO.Path]::GetTempPath()) ("rh-fnm-" + [guid]::NewGuid())
    $Saved = @{ FnmDir = $env:FNM_DIR; State = $script:NodeSwitchStateDir }
    try {
        foreach ($Version in @("v24.18.0", "v26.7.0")) {
            $Bin = Get-FnmBinDir (Get-FnmInstallation $Root $Version)
            New-Item -ItemType Directory -Path $Bin -Force | Out-Null
            Set-Content -LiteralPath (Get-NodeToolPath $Bin "node") -Value ""
            Set-Content -LiteralPath (Get-NodeToolPath $Bin "npm") -Value ""
        }
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $Root "node-versions") "v27.0.0-bad") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root "aliases") -Force | Out-Null
        $Alias = Get-FnmAliasDir $Root
        $env:FNM_DIR = $Root
        if ((Get-FnmRoot) -ceq $Root) { throw "self_test_fnm_root_without_default" }
        # A plain directory named default is not fnm's alias.
        New-Item -ItemType Directory -Path $Alias -Force | Out-Null
        if ($null -ne (Get-FnmDefaultVersion $Root)) { throw "self_test_fnm_default_not_a_link" }
        Remove-Item -LiteralPath $Alias -Force
        [void](New-Item -ItemType $(if ($script:FnmOnWindows) { "Junction" } else { "SymbolicLink" }) `
            -Path $Alias -Target (Get-FnmInstallation $Root "v26.7.0"))
        if ((Get-FnmRoot) -cne $Root) { throw "self_test_fnm_root_not_found" }
        if ((Get-FnmDefaultVersion $Root) -cne "v26.7.0") { throw "self_test_fnm_default_not_read" }
        if ((@(Get-FnmInstalledVersions $Root) -join ",") -cne "v24.18.0,v26.7.0") { throw "self_test_fnm_installed_versions" }
        $Remote = @("v24.2.0   (Krypton)", "v26.0.0", "v26.10.0", "v26.9.0", "v27.0.0", "not-a-version", "* v26.99.0")
        if ((Select-FnmRemoteLatest $Remote 26) -cne "v26.10.0") { throw "self_test_fnm_remote_latest" }
        if ($null -ne (Select-FnmRemoteLatest $Remote 25)) { throw "self_test_fnm_remote_invented" }
        if (-not (Test-NodeReleaseNewer "12.1.0" "11.0.0") -or (Test-NodeReleaseNewer "" "11.0.0") -or
            (Test-NodeReleaseNewer "v26.9.0" "v26.10.0")) {
            throw "self_test_node_release_order"
        }
        $List = '{"dependencies":{"npm":{"version":"12.1.0"},"@bitkyc08/opencodex":{"version":"2.75.0"},' +
            '"dev":{"version":"0.0.1","resolved":"file:../dev"},"linked":{"version":"1.0.0","link":true},' +
            '"broken":{}}}' | ConvertFrom-Json
        $Split = Split-NpmGlobalList $List
        if (((@($Split.Globals.Keys) | ForEach-Object { "$_=$($Split.Globals[$_])" }) -join ",") -cne
            "@bitkyc08/opencodex=2.75.0,dev=0.0.1,linked=1.0.0,npm=12.1.0" -or
            ($Split.Unpinnable -join ",") -cne "broken,dev,linked") {
            throw "self_test_npm_global_split"
        }
        if ($null -ne (Split-NpmGlobalList $null) -or
            $null -ne (Split-NpmGlobalList ('{"error":{"code":"ENOTDIR"}}' | ConvertFrom-Json))) {
            throw "self_test_npm_global_split_unknown"
        }
        foreach ($Good in @('C:\fnm\node-versions\v26.7.0\installation', 'C:\fnm\aliases\default\',
            (Get-FnmInstallation $Root "v26.7.0"))) {
            if (-not (Test-FnmNpmPrefix $Good)) { throw "self_test_fnm_prefix_refused: $Good" }
        }
        foreach ($Bad in @('C:\Users\u\AppData\Roaming\npm', '', 'C:\fnm\node-versions\v26.7.0', 'C:\x\default')) {
            if (Test-FnmNpmPrefix $Bad) { throw "self_test_fnm_prefix_accepted: $Bad" }
        }
        $Prefix = Get-FnmInstallation $Root "v26.7.0"
        $Package = Join-Path (Get-FnmNpmRoot $Prefix) "@example/svc"
        New-Item -ItemType Directory -Path $Package -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Package "package.json") -Value '{"name":"@example/svc","bin":{"svc":"cli.js"}}'
        if ($null -ne (Get-PackageBinPath (Get-FnmNpmRoot $Prefix) $Prefix "@example/svc" "svc")) {
            throw "self_test_package_bin_without_shim"
        }
        $Shim = if ($script:FnmOnWindows) { Join-Path $Prefix "svc.cmd" } else { Join-Path (Join-Path $Prefix "bin") "svc" }
        Set-Content -LiteralPath $Shim -Value ""
        if ((Get-PackageBinPath (Get-FnmNpmRoot $Prefix) $Prefix "@example/svc" "svc") -cne $Shim -or
            $null -ne (Get-PackageBinPath (Get-FnmNpmRoot $Prefix) $Prefix "@example/svc" "other")) {
            throw "self_test_package_bin_proof"
        }
        $script:NodeSwitchStateDir = Join-Path $Root "state"
        if ($null -ne (Read-NodeSwitchMarker)) { throw "self_test_marker_invented" }
        New-Item -ItemType Directory -Path $script:NodeSwitchStateDir -Force | Out-Null
        Set-Content -LiteralPath (Get-NodeSwitchMarkerPath) -Value '{"old":"v26.7.0","target":"v26.10.0"}'
        if ((Read-NodeSwitchMarker).target -cne "v26.10.0") { throw "self_test_marker_read" }
        Set-Content -LiteralPath (Get-NodeSwitchMarkerPath) -Value 'not json'
        if ((Read-NodeSwitchMarker).unreadable -ne $true) { throw "self_test_marker_unreadable" }
    } finally {
        $env:FNM_DIR = $Saved.FnmDir
        $script:NodeSwitchStateDir = $Saved.State
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Run directly (`pwsh -File node-fnm-windows.ps1 -SelfTest`), never when
# dot-sourced.
if ($MyInvocation.InvocationName -ne "." -and @($args) -contains "-SelfTest") {
    $ErrorActionPreference = "Stop"
    Invoke-NodeFnmWindowsSelfTest
    Write-Output "PASS: node-fnm-windows fixture-safe self-check"
    exit 0
}
