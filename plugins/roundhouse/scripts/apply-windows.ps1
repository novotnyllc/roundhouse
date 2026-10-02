[CmdletBinding(DefaultParameterSetName = "Apply")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")][string]$ConfigPath,
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")][string]$PlanPath,
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")]
    [ValidatePattern("^[0-9A-Fa-f]{64}$")][string]$ExpectedPlanFileSha256,
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")]
    [Parameter(Mandatory = $true, ParameterSetName = "VerifyExecutor")]
    [Parameter(Mandatory = $true, ParameterSetName = "ApproveHooks")]
    [string]$ExecutorRequirementPath,
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")]
    [ValidatePattern("^plan-[0-9a-f]{16}$")][string]$PlanId,
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")]
    [ValidatePattern("^[A-Za-z0-9._-]+$")][string]$HostId,
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")]
    [ValidatePattern("^[0-9A-Fa-f]{64}$")][string]$ControllerConfigDigest,
    [Parameter(Mandatory = $true, ParameterSetName = "Apply")][string]$ResultPath,
    [Parameter(Mandatory = $true, ParameterSetName = "VerifyExecutor")][switch]$VerifyExecutor,
    [Parameter(Mandatory = $true, ParameterSetName = "ApproveHooks")]
    [ValidatePattern("^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$")]
    [string]$ApproveCodexPluginHooks,
    [Parameter(Mandatory = $true, ParameterSetName = "BootstrapNodeFnm")][switch]$BootstrapNodeFnm,
    [Parameter(Mandatory = $true, ParameterSetName = "BootstrapNodeFnm")]
    [ValidateRange(1, 999)][int]$NodeMajor,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$PluginRoot = Split-Path -Parent $PSScriptRoot
$CollectScript = Join-Path $PSScriptRoot "collect-windows.ps1"
# fnm discovery, shared with collect-windows.ps1.
. (Join-Path $PSScriptRoot "node-fnm-windows.ps1")
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Windows apply requires PowerShell 7 or newer" }

function Assert-RegularFile([string]$Path, [string]$Label, [long]$MaximumBytes = 10485760) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is not a regular file" }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label must not be a link" }
    if ($Item.Length -gt $MaximumBytes) { throw "$Label exceeds $MaximumBytes bytes" }
    return $Item
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return (($Hasher.ComputeHash($Bytes) |
            ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $Hasher.Dispose()
    }
}

function Get-TextSha256([string]$Text) {
    return Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertTo-CanonicalJson([object]$Value) {
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
    if ($Value -is [string]) { return ($Value | ConvertTo-Json -Compress) }
    if ($Value -is [DateTime]) {
        return ($Value.ToUniversalTime().ToString(
            "yyyy-MM-ddTHH:mm:ssZ",
            [Globalization.CultureInfo]::InvariantCulture
        ) | ConvertTo-Json -Compress)
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [Collections.IDictionary]) {
        $Names = @($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($Names, [StringComparer]::Ordinal)
        $Members = foreach ($Name in $Names) {
            "$(ConvertTo-CanonicalJson $Name):$(ConvertTo-CanonicalJson $Value[$Name])"
        }
        return "{$($Members -join ',')}"
    }
    if ($Value -is [Collections.IEnumerable]) {
        $Members = foreach ($Item in $Value) { ConvertTo-CanonicalJson $Item }
        return "[$($Members -join ',')]"
    }
    $Properties = @($Value.PSObject.Properties.Name)
    [Array]::Sort($Properties, [StringComparer]::Ordinal)
    $Members = foreach ($Name in $Properties) {
        "$(ConvertTo-CanonicalJson $Name):$(ConvertTo-CanonicalJson $Value.$Name)"
    }
    return "{$($Members -join ',')}"
}

function Test-BoundedStrings([object]$Value) {
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) {
        return $Value.Length -le 8192 -and $Value -notmatch "[\x00-\x1f\x7f-\x9f]"
    }
    if ($Value -is [ValueType]) { return $true }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($Key in $Value.Keys) {
            if (-not (Test-BoundedStrings $Key) -or -not (Test-BoundedStrings $Value[$Key])) { return $false }
        }
        return $true
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($Item in $Value) {
            if (-not (Test-BoundedStrings $Item)) { return $false }
        }
        return $true
    }
    foreach ($Property in @($Value.PSObject.Properties)) {
        if (-not (Test-BoundedStrings $Property.Name) -or -not (Test-BoundedStrings $Property.Value)) {
            return $false
        }
    }
    return $true
}

function Test-ContainsProtectedPlanField([object]$Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $false }
    $ProtectedNames = @(
        "action_id", "broker", "broker_protocol", "certificate_source_addresses", "context", "enrollment",
        "observed_execution_principal", "payload", "policy", "policy_token", "privilege", "privilege_request",
        "request", "request_sid", "required_context", "semantic_action", "target_uid"
    )
    if ($Value -is [Collections.IDictionary]) {
        foreach ($Key in $Value.Keys) {
            $NormalizedKey = ([string]$Key).ToLowerInvariant().Replace('-', '_')
            if ($NormalizedKey -cin $ProtectedNames -or (Test-ContainsProtectedPlanField $Value[$Key])) { return $true }
        }
        return $false
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($Item in $Value) { if (Test-ContainsProtectedPlanField $Item) { return $true } }
        return $false
    }
    foreach ($Property in @($Value.PSObject.Properties)) {
        $NormalizedName = $Property.Name.ToLowerInvariant().Replace('-', '_')
        if ($NormalizedName -cin $ProtectedNames -or (Test-ContainsProtectedPlanField $Property.Value)) { return $true }
    }
    return $false
}

function Test-ExactProperties([object]$Value, [string[]]$Expected) {
    if ($null -eq $Value) { return $false }
    $Actual = if ($Value -is [Collections.IDictionary]) {
        @($Value.Keys | ForEach-Object { [string]$_ })
    } else { @($Value.PSObject.Properties.Name) }
    [Array]::Sort($Actual, [StringComparer]::Ordinal)
    $Wanted = @($Expected)
    [Array]::Sort($Wanted, [StringComparer]::Ordinal)
    return ($Actual.Count -eq $Wanted.Count -and ($Actual -join "`0") -ceq ($Wanted -join "`0"))
}

function Test-HexSha256([object]$Value) {
    return $Value -is [string] -and [string]$Value -match "^[0-9a-f]{64}$"
}

function Assert-ExecutorFiles([object]$Executor) {
    $Files = @($Executor.files)
    if ($Files.Count -lt 2 -or $Files.Count -gt 256) { throw "Invalid executor file list" }
    $Seen = @{}
    foreach ($File in $Files) {
        $Path = [string]$File.path
        if ($Path -notmatch "^[A-Za-z0-9._/-]+$" -or
            [IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or
            $Path -match "(^|/)\.\.(/|$)" -or -not (Test-HexSha256 $File.sha256) -or
            $Seen.ContainsKey($Path)) {
            throw "Invalid executor file entry"
        }
        $Seen[$Path] = $true
    }
    if (-not $Seen.ContainsKey("scripts/apply-windows.ps1") -or
        -not $Seen.ContainsKey("scripts/collect-windows.ps1")) {
        throw "Executor requirement omits a Windows worker script"
    }
}

function Assert-ExecutorShape([object]$Executor, [switch]$RequireEnvelope) {
    if ($RequireEnvelope -and
        ($Executor.schema -ne "roundhouse.executor" -or $Executor.schema_version -ne 1)) {
        throw "Invalid executor requirement envelope"
    }
    if ($Executor.plugin -ne "roundhouse" -or
        [string]$Executor.marketplace -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
        [string]$Executor.version -notmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$" -or
        -not (Test-HexSha256 $Executor.integrity_manifest_sha256)) {
        throw "Invalid executor requirement"
    }
    Assert-ExecutorFiles $Executor
}

function Assert-SameExecutorFiles([object]$Expected, [object]$Actual, [string]$Label) {
    # Matched by path, never by sorted position. Sort-Object cannot read a key
    # off an [ordered] dictionary — the shape Get-InstalledExecutor emits — so
    # it sorts every element equal and returns them in whatever order its
    # unstable sort lands on, which only shows up once the list is long enough
    # to stop being a no-op. Its culture-aware string compare also treats "/"
    # and "-" as ignorable, so two distinct release paths can tie. Neither trap
    # can bite a lookup keyed on the path itself.
    $ExpectedFiles = @($Expected.files)
    $ActualFiles = @($Actual.files)
    if ($ExpectedFiles.Count -ne $ActualFiles.Count) { throw "$Label file list does not match" }
    $Index = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($File in $ExpectedFiles) { $Index[[string]$File.path] = [string]$File.sha256 }
    if ($Index.Count -ne $ExpectedFiles.Count) { throw "$Label file list does not match" }
    foreach ($File in $ActualFiles) {
        $Expectation = $null
        if (-not $Index.TryGetValue([string]$File.path, [ref]$Expectation) -or
            $Expectation -cne [string]$File.sha256) {
            throw "$Label file list does not match"
        }
    }
}

function Assert-SameExecutor([object]$Expected, [object]$Actual, [string]$Label) {
    if ($Actual.plugin -ne $Expected.plugin -or
        $Actual.marketplace -ne $Expected.marketplace -or
        $Actual.version -ne $Expected.version -or
        $Actual.integrity_manifest_sha256 -ne $Expected.integrity_manifest_sha256) {
        throw "$Label does not match the sealed executor"
    }
    Assert-SameExecutorFiles $Expected $Actual $Label
}

function Assert-Executor([object]$Required, [object]$Reported, [string]$Root = $PluginRoot) {
    Assert-ExecutorShape $Required
    Assert-ExecutorShape $Reported -RequireEnvelope
    Assert-SameExecutor $Required $Reported "Executor status"
    if ($null -ne $Reported.source -and $Reported.source.dirty -eq $true) {
        throw "Dirty source executors cannot perform mutations"
    }

    $RootItem = Get-Item -LiteralPath $Root -Force
    if (-not $RootItem.PSIsContainer -or
        ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Executor plugin root must be a regular directory"
    }
    $ManifestPath = Join-Path $Root "integrity.json"
    Assert-RegularFile $ManifestPath "Executor integrity manifest" | Out-Null
    if ((Get-FileSha256 $ManifestPath) -ne $Required.integrity_manifest_sha256) {
        throw "Executor integrity manifest hash mismatch"
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.schema -ne "roundhouse.integrity" -or $Manifest.schema_version -ne 1 -or
        $Manifest.plugin -ne $Required.plugin -or $Manifest.marketplace -ne $Required.marketplace -or
        $Manifest.version -ne $Required.version) {
        throw "Integrity manifest does not match the sealed executor"
    }
    Assert-ExecutorFiles $Manifest
    Assert-SameExecutorFiles $Required $Manifest "Integrity manifest"

    foreach ($File in @($Required.files)) {
        $Path = Join-Path $Root ([string]$File.path)
        $FullPath = [IO.Path]::GetFullPath($Path)
        $FullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        if (-not $FullPath.StartsWith($FullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Executor file escapes the plugin root"
        }
        Assert-RegularFile $FullPath "Executor file" 52428800 | Out-Null
        if ((Get-FileSha256 $FullPath) -ne [string]$File.sha256) {
            throw "Executor file hash mismatch: $($File.path)"
        }
    }

    $Git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $Git) {
        $Inside = @(& $Git.Source -C $Root rev-parse --is-inside-work-tree 2>$null)
        $InsideSucceeded = $?
        $InsideExitCode = $LASTEXITCODE
        if ($InsideSucceeded -and $InsideExitCode -eq 0 -and $Inside[0] -eq "true") {
            $Commit = @(& $Git.Source -C $Root rev-parse HEAD 2>$null)
            $CommitSucceeded = $?
            $CommitExitCode = $LASTEXITCODE
            $Tree = @(& $Git.Source -C $Root rev-parse "HEAD^{tree}" 2>$null)
            $TreeSucceeded = $?
            $TreeExitCode = $LASTEXITCODE
            $Dirty = @(& $Git.Source -C $Root status --porcelain --untracked-files=no -- $Root 2>$null)
            $DirtySucceeded = $?
            $DirtyExitCode = $LASTEXITCODE
            if (-not $CommitSucceeded -or $CommitExitCode -ne 0 -or
                -not $TreeSucceeded -or $TreeExitCode -ne 0 -or
                -not $DirtySucceeded -or $DirtyExitCode -ne 0 -or
                $Dirty.Count -ne 0 -or $Reported.source.commit -ne $Commit[0] -or
                $Reported.source.tree -ne $Tree[0] -or $Reported.source.dirty -ne $false) {
                throw "Source executor identity is dirty or does not match its Git checkout"
            }
        }
    }
}

function Get-InstalledExecutor([string]$Root = $PluginRoot) {
    $RootItem = Get-Item -LiteralPath $Root -Force
    if (-not $RootItem.PSIsContainer -or
        ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Executor plugin root must be a regular directory"
    }
    $ManifestPath = Join-Path $Root "integrity.json"
    Assert-RegularFile $ManifestPath "Executor integrity manifest" | Out-Null
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.schema -ne "roundhouse.integrity" -or $Manifest.schema_version -ne 1 -or
        $Manifest.plugin -ne "roundhouse" -or
        [string]$Manifest.marketplace -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
        [string]$Manifest.version -notmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$") {
        throw "Invalid executor integrity manifest"
    }
    Assert-ExecutorFiles $Manifest

    $Files = foreach ($File in @($Manifest.files)) {
        $Path = Join-Path $Root ([string]$File.path)
        $FullPath = [IO.Path]::GetFullPath($Path)
        $FullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        if (-not $FullPath.StartsWith($FullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Executor file escapes the plugin root"
        }
        Assert-RegularFile $FullPath "Executor file" 52428800 | Out-Null
        [ordered]@{ path = [string]$File.path; sha256 = Get-FileSha256 $FullPath }
    }

    $Source = [ordered]@{ commit = $null; tree = $null; dirty = $null }
    $Git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $Git) {
        $Inside = @(& $Git.Source -C $Root rev-parse --is-inside-work-tree 2>$null)
        if ($? -and $LASTEXITCODE -eq 0 -and $Inside[0] -eq "true") {
            $Commit = @(& $Git.Source -C $Root rev-parse HEAD 2>$null)
            if (-not $? -or $LASTEXITCODE -ne 0 -or $Commit.Count -ne 1) {
                throw "Cannot determine executor source commit"
            }
            $Tree = @(& $Git.Source -C $Root rev-parse "HEAD^{tree}" 2>$null)
            if (-not $? -or $LASTEXITCODE -ne 0 -or $Tree.Count -ne 1) {
                throw "Cannot determine executor source tree"
            }
            $Dirty = @(& $Git.Source -C $Root status --porcelain --untracked-files=no -- $Root 2>$null)
            if (-not $? -or $LASTEXITCODE -ne 0) { throw "Cannot determine executor source state" }
            $Source = [ordered]@{
                commit = [string]$Commit[0]
                tree = [string]$Tree[0]
                dirty = $Dirty.Count -ne 0
            }
        }
    }

    return [ordered]@{
        schema = "roundhouse.executor"
        schema_version = 1
        plugin = [string]$Manifest.plugin
        marketplace = [string]$Manifest.marketplace
        version = [string]$Manifest.version
        integrity_manifest_sha256 = Get-FileSha256 $ManifestPath
        # Manifest order, which the generator already sorts by path. Re-sorting
        # here does nothing but reintroduce the Sort-Object traps described in
        # Assert-SameExecutorFiles.
        files = @($Files)
        source = $Source
        verified = $true
    }
}

function Resolve-UserPath([string]$Path) {
    if ($Path -eq "~") { return $HOME }
    if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) {
        return Join-Path $HOME $Path.Substring(2)
    }
    return $Path
}

function Get-ConfiguredMachine([object]$Config) {
    if ($Config.version -ne 1 -or $null -eq $Config.machines.$HostId) {
        throw "Invalid version 1 configuration or unknown host"
    }
    if ($Config.worker.target -ne $HostId -or
        $Config.worker.controller_configuration_digest -ne $ControllerConfigDigest.ToLowerInvariant()) {
        throw "Worker configuration is not bound to this controller and target"
    }
    $Machine = $Config.machines.$HostId
    if (-not $IsWindows -or $Machine.platform -ne "windows" -or
        $Machine.transport -ne "codex-remote-control" -or
        [string]::IsNullOrWhiteSpace([string]$Machine.codex_host)) {
        throw "Windows apply requires native codex-remote-control transport"
    }
    if ([string]$Machine.expected_hostname -notmatch "^[A-Za-z0-9._-]+$" -or
        [string]$Machine.expected_user -notmatch "^[A-Za-z0-9._@-]+$") {
        throw "Windows mutation requires expected_hostname and expected_user"
    }
    if ([string]$env:COMPUTERNAME -ine [string]$Machine.expected_hostname -or
        [string][Environment]::UserName -ine [string]$Machine.expected_user) {
        throw "Windows target hostname or user does not match configuration"
    }
    return $Machine
}

function Assert-Plan([object]$Plan, [string]$WorkerConfigDigest) {
    if ($Plan.schema -ne "roundhouse.plan" -or $Plan.schema_version -ne 2 -or
        $Plan.plan_id -ne $PlanId -or [string]$Plan.plan_id -notmatch "^plan-[0-9a-f]{16}$" -or
        $Plan.target -ne $HostId -or
        [string]$Plan.domain -notin @("updates", "agents", "chezmoi", "projects") -or
        [string]$Plan.required_section -notin @("packages", "agents", "chezmoi", "projects") -or
        -not (Test-HexSha256 $Plan.plan_digest.value) -or
        -not (Test-HexSha256 $Plan.precondition_digest.value)) {
        throw "Invalid sealed Windows plan"
    }
    if (Test-ContainsProtectedPlanField $Plan) {
        throw "Protected schema 3/4 fields are forbidden in the ordinary interactive Windows lane"
    }
    $ControllerDigest = if ($null -ne $Plan.controller_configuration_digest) {
        $Plan.controller_configuration_digest
    } else {
        $Plan.configuration_digest
    }
    if ($ControllerDigest.algorithm -ne "sha256" -or
        [string]$ControllerDigest.value -ne $ControllerConfigDigest.ToLowerInvariant() -or
        $Plan.worker_configuration_digest.algorithm -ne "sha256" -or
        [string]$Plan.worker_configuration_digest.value -ne $WorkerConfigDigest) {
        throw "Plan configuration digest mismatch"
    }
    if (-not (Test-BoundedStrings $Plan)) { throw "Plan contains an oversized or control string" }
    $Operations = @($Plan.operations)
    if ($Operations.Count -eq 0 -or $Operations.Count -gt 128) { throw "Invalid plan operations" }
    foreach ($Operation in $Operations) {
        $HasTargets = $null -ne $Operation.PSObject.Properties["targets"]
        $IsNodeSwitch = [string]$Operation.type -eq "package-upgrade" -and [string]$Operation.id -ceq "fnm:node"
        $ExpectedOperationProperties = if ($IsNodeSwitch) {
            @("argv", "candidate_version", "carry", "hooks", "id", "kind", "required", "type")
        } elseif ([string]$Operation.type -eq "package-upgrade") {
            @("argv", "candidate_version", "id", "kind", "type")
        } elseif ([string]$Operation.type -eq "chezmoi-apply" -and $HasTargets) {
            @("argv", "id", "kind", "targets", "type")
        } else { @("argv", "id", "kind", "type") }
        if (-not (Test-ExactProperties $Operation $ExpectedOperationProperties) -or
            [string]$Operation.type -eq "semantic-action") {
            throw "Invalid ordinary Windows operation shape"
        }
        if (@($Operation.argv).Count -eq 0 -or @($Operation.argv).Count -gt 64 -or
            @($Operation.argv | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "Invalid operation argv"
        }
        $Valid = switch ([string]$Plan.domain) {
            "updates" { $Operation.type -eq "package-upgrade" -and $Operation.kind -eq "package" }
            "agents" { $Operation.type -eq "agent-update" -and
                [string]$Operation.kind -in @("agent_runtime", "plugin", "skill") }
            "chezmoi" {
                ($Operation.type -eq "chezmoi-pull" -and $Operation.kind -eq "file" -and $Operation.id -eq "chezmoi:source") -or
                ($Operation.type -eq "chezmoi-apply" -and $Operation.kind -eq "chezmoi_state" -and $Operation.id -eq "live")
            }
            "projects" { [string]$Operation.type -in @("project-clone", "project-update") -and
                $Operation.kind -eq "project" }
            default { $false }
        }
        if (-not $Valid) { throw "Unsupported Windows operation" }
        if ($IsNodeSwitch) { Assert-NodeSwitchOperationShape $Operation }
        if ($HasTargets -and [string]$Operation.type -ne "chezmoi-apply") {
            throw "Only chezmoi apply may declare targets"
        }
        if ($HasTargets) { [void](Get-ChezmoiTargets $Operation) }
    }
    # At most one Node switch, before every npm upgrade in the plan: an npm
    # upgrade first would change a version the sealed carry names.
    $Ids = @($Operations | ForEach-Object { [string]$_.id })
    $SwitchIndex = [Array]::IndexOf([string[]]$Ids, "fnm:node")
    if (@($Ids | Where-Object { $_ -ceq "fnm:node" }).Count -gt 1 -or
        ($SwitchIndex -gt 0 -and @($Ids[0..($SwitchIndex - 1)] | Where-Object { $_ -like "npm:*" }).Count -gt 0)) {
        throw "A plan may contain one Node switch, before every npm upgrade"
    }

    $PlanCopy = $Plan | ConvertTo-Json -Compress -Depth 100 | ConvertFrom-Json
    $PlanCopy.PSObject.Properties.Remove("plan_id")
    $PlanCopy.PSObject.Properties.Remove("plan_digest")
    $CanonicalDigest = Get-TextSha256 ((ConvertTo-CanonicalJson $PlanCopy) + "`n")
    if ($CanonicalDigest -ne $Plan.plan_digest.value -or
        $PlanId -ne "plan-$($CanonicalDigest.Substring(0, 16))") {
        throw "Plan digest or ID integrity check failed"
    }
}

function Read-Inventory([string[]]$Sections, [string]$SnapshotId) {
    $Lines = @(& $CollectScript -ConfigPath $ConfigPath -HostId $HostId `
        -ControllerConfigDigest $ControllerConfigDigest -SnapshotId $SnapshotId -Sections $Sections)
    $Succeeded = $?
    if (-not $Succeeded -or $Lines.Count -eq 0) { throw "Windows inventory failed" }
    $Records = @($Lines | ForEach-Object {
        if ([Text.Encoding]::UTF8.GetByteCount([string]$_) -gt 65536) { throw "Inventory record is too large" }
        $_ | ConvertFrom-Json
    })
    if (@($Records | Where-Object {
        $_.kind -eq "operation" -and $_.id -eq "collect" -and
        $_.data.operation_status -eq "completed"
    }).Count -ne 1) {
        throw "Windows inventory did not complete"
    }
    if (@($Records | Where-Object { $_.host_id -ne $HostId }).Count -gt 0) {
        throw "Inventory returned the wrong host"
    }
    return $Records
}

function Get-PreconditionDigest([object]$Plan, [object[]]$Records) {
    $Wanted = @{}
    $TargetedChezmoi = @{}
    foreach ($Operation in @($Plan.operations)) {
        $Key = "$($Operation.kind)`0$($Operation.id)"
        $Wanted[$Key] = $true
        if ($Operation.type -eq "chezmoi-apply" -and
            $null -ne $Operation.PSObject.Properties["targets"]) {
            $TargetedChezmoi[$Key] = $true
        }
    }
    $Selected = @($Records | Where-Object { $Wanted.ContainsKey("$($_.kind)`0$($_.id)") } |
        Sort-Object host_id, kind, id)
    $Text = ""
    foreach ($Record in $Selected) {
        $Copy = $Record | ConvertTo-Json -Compress -Depth 100 | ConvertFrom-Json
        $Copy.PSObject.Properties.Remove("snapshot_id")
        $Copy.PSObject.Properties.Remove("observed_at")
        if ($null -ne $Copy.data) {
            $Copy.data.PSObject.Properties.Remove("codex_checked_at")
            if ($TargetedChezmoi.ContainsKey("$($Copy.kind)`0$($Copy.id)")) {
                $Copy.data.PSObject.Properties.Remove("drift_count")
                $Copy.data.PSObject.Properties.Remove("status_codes")
                $Copy.data.PSObject.Properties.Remove("status_digest")
            }
        }
        $Text += (ConvertTo-CanonicalJson $Copy) + "`n"
    }
    return Get-TextSha256 $Text
}

function Get-Record([object[]]$Records, [string]$Kind, [string]$Id) {
    return @($Records | Where-Object { $_.kind -eq $Kind -and $_.id -eq $Id })
}

function Get-ChezmoiTargets([object]$Operation) {
    $Property = $Operation.PSObject.Properties["targets"]
    if ($null -eq $Property) { return $null }
    $Targets = @($Property.Value)
    if ($Targets.Count -eq 0 -or $Targets.Count -gt 16) { throw "Invalid chezmoi targets" }
    $Seen = @{}
    foreach ($Target in $Targets) {
        if ($Target -isnot [string] -or $Target.Length -eq 0 -or $Target.Length -gt 512 -or
            (-not (($Target.StartsWith("/") -and -not $Target.Contains("\")) -or
                ($Target -match "^[A-Za-z]:\\" -and $Target.Contains("\")))) -or
            $Target -match "(^|[\\/])\\.\\.?($|[\\/])" -or $Seen.ContainsKey($Target)) {
            throw "Invalid chezmoi target"
        }
        $Seen[$Target] = $true
    }
    return [string[]]$Targets
}

function Assert-ChezmoiTargetsWithinHome([string[]]$Targets) {
    $Home = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile))
    $Prefix = $Home.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    foreach ($Target in $Targets) {
        $FullPath = [IO.Path]::GetFullPath($Target)
        if (-not $FullPath.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Chezmoi target escapes the current user profile"
        }
        $Relative = [IO.Path]::GetRelativePath($Home, $FullPath)
        $Current = $Home
        foreach ($Segment in @($Relative -split "[\\/]")) {
            if ([string]::IsNullOrWhiteSpace($Segment) -or $Segment -eq ".") { continue }
            $Current = Join-Path $Current $Segment
            $Item = Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
            if ($null -ne $Item -and ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Chezmoi target traverses a reparse point"
            }
        }
    }
}

function Assert-ChezmoiTargetStatus([object]$Operation, [bool]$ExpectDrift) {
    $Targets = @(Get-ChezmoiTargets $Operation)
    if ($Targets.Count -eq 0) { throw "Targeted chezmoi operation has no targets" }
    Assert-ChezmoiTargetsWithinHome $Targets
    $Command = Get-Command "chezmoi" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $Command) { throw "Required command is unavailable: chezmoi" }
    $PSNativeCommandUseErrorActionPreference = $false
    $Output = @(& $Command.Source status -- $Targets 2>&1)
    $ExitCode = $LASTEXITCODE
    $Stdout = @($Output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
    if ($null -ne $ExitCode -and $ExitCode -ne 0) {
        $Failure = [InvalidOperationException]::new("Chezmoi target status failed")
        $Failure.Data["OutputTail"] = Get-OutputTail $Output
        throw $Failure
    }
    $HasDrift = $Stdout.Count -gt 0
    if ($HasDrift -ne $ExpectDrift) {
        $Failure = [InvalidOperationException]::new("Chezmoi targets did not reach the expected status")
        $Failure.Data["OutputTail"] = Get-OutputTail $Output
        throw $Failure
    }
}

function Get-ChezmoiStatusTail {
    # Read-only, and only after a chezmoi apply already failed its drift
    # postcondition: the same `chezmoi status` the collector runs, kept as a
    # bounded tail so the report names what is still drifting and why.
    try {
        $Command = Get-Command "chezmoi" -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $Command) { return [string[]]@() }
        $PSNativeCommandUseErrorActionPreference = $false
        return Get-OutputTail @(& $Command.Source status 2>&1)
    } catch {
        return [string[]]@()
    }
}

function Test-SameMeaningfulData([object]$Before, [object]$After) {
    $Ignored = @("installed_at", "updated_at", "inferred_installed_at",
        "inferred_installed_at_evidence", "inferred_installed_at_confidence")
    $BeforeCopy = $Before.data | ConvertTo-Json -Compress -Depth 100 | ConvertFrom-Json
    $AfterCopy = $After.data | ConvertTo-Json -Compress -Depth 100 | ConvertFrom-Json
    foreach ($Name in $Ignored) {
        $BeforeCopy.PSObject.Properties.Remove($Name)
        $AfterCopy.PSObject.Properties.Remove($Name)
    }
    return (ConvertTo-CanonicalJson $BeforeCopy) -eq (ConvertTo-CanonicalJson $AfterCopy)
}

function Get-ProjectCommand([object]$Operation, [object]$Config, [object]$Machine) {
    $Definition = $Config.projects.([string]$Operation.id)
    if ($null -eq $Definition -or [string]::IsNullOrWhiteSpace([string]$Machine.dev_root)) {
        throw "Project is not configured for this target"
    }
    $Relative = [string]$Definition.path
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or
        $Relative.Contains("\") -or $Relative -match "(^|/)\.\.(/|$)") {
        throw "Unsafe configured project path"
    }
    $ConfiguredDevRoot = Resolve-UserPath ([string]$Machine.dev_root)
    if (-not [IO.Path]::IsPathRooted($ConfiguredDevRoot)) { throw "Configured dev_root must be absolute" }
    $DevRoot = [IO.Path]::GetFullPath($ConfiguredDevRoot)
    $ProjectPath = [IO.Path]::GetFullPath((Join-Path $DevRoot $Relative))
    $RootPrefix = $DevRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $ProjectPath.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Project path escapes dev_root"
    }
    $Source = [string]$Definition.source
    if ([string]::IsNullOrWhiteSpace($Source) -or $Source.Contains("?") -or
        $Source -match "^[A-Za-z][A-Za-z0-9+.-]*://(?!git@)[^/@]+@") {
        throw "Unsafe configured project source"
    }
    if ($Source -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
        $Source = "https://github.com/$Source.git"
    }
    if ([string]$Operation.type -eq "project-clone") {
        return @("git", "clone", "--", $Source, $ProjectPath)
    }
    return @("git", "-C", $ProjectPath, "pull", "--ff-only")
}

function Prepare-ProjectMutationPath([object]$Operation, [object]$Config, [object]$Machine) {
    $Argv = @(Get-ProjectCommand $Operation $Config $Machine)
    $IsClone = [string]$Operation.type -eq "project-clone"
    $DevRoot = [IO.Path]::GetFullPath((Resolve-UserPath ([string]$Machine.dev_root)))
    $ProjectPath = [IO.Path]::GetFullPath([string]$(if ($IsClone) { $Argv[-1] } else { $Argv[2] }))
    $RootPrefix = $DevRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $ProjectPath.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Project path escapes dev_root"
    }
    if ($IsClone -and $null -ne (Get-Item -LiteralPath $ProjectPath -Force -ErrorAction SilentlyContinue)) {
        throw "Project clone destination is no longer absent"
    }

    $RootItem = Get-Item -LiteralPath $DevRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $RootItem -and $IsClone) {
        [void][IO.Directory]::CreateDirectory($DevRoot)
        $RootItem = Get-Item -LiteralPath $DevRoot -Force
    }
    if ($null -eq $RootItem -or -not $RootItem.PSIsContainer -or
        ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Configured dev_root must be a regular directory"
    }

    $CheckedPath = $(if ($IsClone) { [IO.Path]::GetDirectoryName($ProjectPath) } else { $ProjectPath })
    $RelativePath = [IO.Path]::GetRelativePath($DevRoot, $CheckedPath)
    if ($RelativePath -eq ".." -or $RelativePath.StartsWith("..\", [StringComparison]::Ordinal)) {
        throw "Project path escapes dev_root"
    }
    $Current = $DevRoot
    foreach ($Segment in @($RelativePath -split "[\\/]")) {
        if ([string]::IsNullOrWhiteSpace($Segment) -or $Segment -eq ".") { continue }
        $Current = Join-Path $Current $Segment
        $Item = Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
        if ($null -eq $Item -and $IsClone) {
            [void][IO.Directory]::CreateDirectory($Current)
            $Item = Get-Item -LiteralPath $Current -Force
        }
        if ($null -eq $Item -or -not $Item.PSIsContainer -or
            ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Project path must contain only existing regular directories"
        }
    }
}

function Get-ExactArgv([object]$Operation, [object]$Config, [object]$Machine) {
    $Id = [string]$Operation.id
    switch ([string]$Operation.type) {
        "package-upgrade" {
            if ($Id -ceq "fnm:node") {
                # The Node runtime switch's fixed marker; its shape is checked
                # in Assert-Plan and its carry and hooks in the preflight.
                if (-not (Test-NodeVersionText $Operation.candidate_version)) { throw "Invalid Node runtime switch" }
                return @("fnm", "default", [string]$Operation.candidate_version)
            }
            if ($Id -cmatch "^npm:(?<name>(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*)$") {
                # Two shapes only: the exact-version global install, or the
                # updater the configuration declares for this package.
                $PackageName = $Matches.name
                if ([string]$Operation.candidate_version -cnotmatch "^[0-9A-Za-z][0-9A-Za-z.+-]*$") {
                    throw "Invalid npm upgrade"
                }
                $Install = @("npm", "install", "--global", ($PackageName + "@" + [string]$Operation.candidate_version))
                if ((ConvertTo-CanonicalJson @($Operation.argv)) -eq (ConvertTo-CanonicalJson $Install)) {
                    return $Install
                }
                $Configured = $null
                if ($null -ne $Config -and $null -ne $Config.package_updaters) {
                    $Configured = $Config.package_updaters.PSObject.Properties |
                        Where-Object { $_.Name -ceq $Id } | Select-Object -First 1
                }
                if ($null -ne $Configured) { return [string[]]@($Configured.Value) }
                return $Install
            }
            if ($Id -notmatch "^winget:(?<name>[A-Za-z0-9._+-]+)$") {
                throw "Invalid winget upgrade"
            }
            $PackageName = $Matches.name
            if ([string]$Operation.candidate_version -notmatch "^[A-Za-z0-9._+-]+$") {
                throw "Invalid winget upgrade"
            }
            return @("winget", "upgrade", "--id", $PackageName, "--exact",
                "--version", [string]$Operation.candidate_version,
                "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")
        }
        "agent-update" {
            if ($Id -in @("codex", "claude") -and [string]$Operation.kind -eq "agent_runtime") {
                return @($Id, "update")
            }
            if ($Id -match "^skills-cli:(?<name>[A-Za-z0-9@._/][A-Za-z0-9@._/-]*)$") {
                return @("npx", "skills", "update", [string]$Matches.name, "-g", "-y")
            }
            if ($Id -match "^jsm:(?<name>[A-Za-z0-9._/][A-Za-z0-9._/-]*)$") {
                return @("jsm", "upgrade", [string]$Matches.name)
            }
            if ($Id -match "^(?<agent>claude|codex):(?<market>[A-Za-z0-9._-]+):(?<name>[A-Za-z0-9._-]+):[^:]+$") {
                $PluginId = "$($Matches.name)@$($Matches.market)"
                if ($Matches.agent -eq "claude") {
                    return @("claude", "plugin", "update", $PluginId, "--scope", "user")
                }
                return @("codex", "plugin", "add", $PluginId, "--json")
            }
            throw "Unsupported agent update"
        }
        "project-clone" { return Get-ProjectCommand $Operation $Config $Machine }
        "project-update" { return Get-ProjectCommand $Operation $Config $Machine }
        "chezmoi-pull" { return @("chezmoi", "git", "--", "pull", "--ff-only") }
        "chezmoi-apply" {
            if ($null -eq $Operation.PSObject.Properties["targets"]) {
                return @("chezmoi", "--no-tty", "apply")
            }
            return @("chezmoi", "--no-tty", "apply", "--") + @(Get-ChezmoiTargets $Operation)
        }
        default { throw "Unsupported Windows operation" }
    }
}

function Test-NpmUpdaterOperation([object]$Operation) {
    if ([string]$Operation.type -ne "package-upgrade" -or [string]$Operation.id -notlike "npm:*") { return $false }
    $Install = @("npm", "install", "--global",
        (([string]$Operation.id).Substring(4) + "@" + [string]$Operation.candidate_version))
    return (ConvertTo-CanonicalJson @($Operation.argv)) -ne (ConvertTo-CanonicalJson $Install)
}

function Get-NpmUpdaterPath([string]$Name, [string]$Bin) {
    # A declared updater runs only as a bin the installed package itself
    # declares, from the global prefix the durable npm reports, never by PATH
    # lookup.
    $Npm = Get-DurableNpmPath
    $Root = ((@(& $Npm root --global 2>$null) | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $Prefix = ((@(& $Npm prefix --global 2>$null) | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Prefix)) {
        throw "npm global prefix is unavailable"
    }
    $Path = Get-PackageBinPath $Root $Prefix $Name $Bin
    if ($null -eq $Path) { throw "npm updater is not a bin of the installed package in the global prefix" }
    return $Path
}

function Assert-NpmRegistryCandidate([string]$Npm, [string]$Name, [string]$Candidate) {
    # A package updater takes no version argument, so the only binding to the
    # sealed candidate is that the registry still names it as latest right
    # before the updater runs. Fail closed otherwise.
    $Latest = ((@(& $Npm view $Name version 2>$null) | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($Latest -cnotmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') {
        throw "npm registry latest is unavailable; refusing the sealed updater"
    }
    if ($Latest -cne $Candidate) {
        throw "npm latest moved from the sealed candidate; create a new plan"
    }
}

function Get-SelectedNpm {
    # The durable npm (Get-DurableNpmPath): the fnm default's, else PATH's.
    return Get-DurableNpmPath
}

function Invoke-WithNpmOnPath([string]$NpmSource, [scriptblock]$Body) {
    # npm.cmd and every global-prefix shim run the node.exe beside themselves
    # or, failing that, the first node on PATH. The global prefix carries no
    # node.exe, so without this an updater could run under an unrelated Node.
    # The selected npm's own directory goes first for the call, then PATH is
    # restored whatever happens.
    $Saved = $env:PATH
    try {
        $env:PATH = (Split-Path -Parent $NpmSource) + [IO.Path]::PathSeparator + $Saved
        return (& $Body)
    } finally {
        $env:PATH = $Saved
    }
}

# Failure diagnostics. A failing native command's own output is the only
# explanation of why it failed, so the worker keeps a bounded, sanitized tail
# of it: at most $OutputTailLines lines of at most $OutputTailLineLength
# characters, ANSI styling, carriage-return progress redraws, spinner rows and
# PowerShell CLIXML progress stripped. Redaction is a best-effort filter:
# every line inside a PEM block, every line matching a known secret pattern,
# and both lines of any adjacent pair whose joined text matches one, are
# replaced whole. Nothing else is ever captured: no environment, no argv
# beyond the sealed command name, and never the output of a command that
# succeeded unless a later postcondition on that same operation fails.
$OutputTailLines = 20
$OutputTailLineLength = 240
$OutputTailMessageLength = 2560
# CLIXML carries many records on one line and is scanned by one linear regex;
# every other line is cut before the per-line expressions run.
$OutputTailClixmlLength = 1048576
$OutputTailRawLineLength = 65536
$OutputTailRedacted = "[redacted: line matched a secret pattern]"
$FailureMessageRedacted = "[redacted: message matched a secret pattern]"
$script:LastOutputTail = [string[]]@()

function Test-SecretLikeText([string]$Text) {
    # The same named classes and entropy floor as the replicated-record
    # redaction floor (lib/fleet-store.sh fleet_quote_is_secret), plus
    # credential-shaped assignments and URLs, since tool output may echo a
    # rendered configuration line or a Git remote.
    if ($Text.Length -gt $OutputTailRawLineLength) { $Text = $Text.Substring(0, $OutputTailRawLineLength) }
    if ($Text.Contains("-----BEGIN") -or $Text.Contains("-----END")) { return $true }
    if ($Text -cmatch "eyJ[A-Za-z0-9_=-]*\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]*") { return $true }
    if ($Text -cmatch "(^|[^A-Za-z0-9_-])(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{8,}") {
        return $true
    }
    if ($Text -cmatch "(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9]{16,}") { return $true }
    if ($Text -cmatch "(^|[^A-Za-z0-9])AKIA[0-9A-Z]{16}") { return $true }
    if ($Text -match "(?i)[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@") { return $true }
    if ($Text -match "(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}") { return $true }
    if ($Text -match "(?i)(pass(word|wd)?|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth(orization)?)s?[""']?\s*[:=]\s*[""']?[^\s""']{4,}") {
        return $true
    }
    foreach ($Match in [regex]::Matches($Text, "[A-Za-z0-9_]{32,}")) {
        $Token = $Match.Value
        # A snake_case identifier (a chezmoi script name such as
        # run_onchange_after_10_register_task) is words, not entropy.
        if ($Token.Contains("_") -and
            @($Token -split "_" | Where-Object { $_.Length -gt 16 }).Count -eq 0) {
            continue
        }
        if (($Token -cmatch "[0-9]" -and $Token -cmatch "[A-Za-z]") -or
            ($Token -cmatch "[a-z]" -and $Token -cmatch "[A-Z]")) {
            return $true
        }
    }
    return $false
}

function ConvertFrom-ClixmlText([string]$Text) {
    # Windows PowerShell writes CLIXML to a redirected stderr. Only its error
    # strings explain a failure; progress and every other object is dropped.
    $Lines = New-Object System.Collections.Generic.List[string]
    foreach ($Match in [regex]::Matches($Text, '<S S="Error">(?<text>[^<]*)</S>')) {
        $Decoded = [regex]::Replace($Match.Groups["text"].Value, "_x(?<hex>[0-9A-Fa-f]{4})_", {
            param($Escape)
            [string][char][Convert]::ToInt32($Escape.Groups["hex"].Value, 16)
        })
        $Decoded = [Net.WebUtility]::HtmlDecode($Decoded)
        foreach ($Line in @($Decoded -split "\r?\n")) { $Lines.Add($Line) }
    }
    return [string[]]$Lines.ToArray()
}

function ConvertTo-CleanOutputLines([object]$Item) {
    # Strips styling and progress noise; redaction happens in the tail, which
    # sees neighbouring lines.
    if ($null -eq $Item) { return [string[]]@() }
    $Text = [string]$Item
    if ($Text -match "^\s*#<\s*CLIXML\s*$") { return [string[]]@() }
    $Candidates = if ($Text.Contains("<Objs ") -or $Text -match '^\s*<Obj[ >]') {
        if ($Text.Length -gt $OutputTailClixmlLength) { $Text = $Text.Substring(0, $OutputTailClixmlLength) }
        @(ConvertFrom-ClixmlText $Text)
    } else {
        if ($Text.Length -gt $OutputTailRawLineLength) { $Text = $Text.Substring(0, $OutputTailRawLineLength) }
        @($Text -split "\n")
    }
    $Clean = New-Object System.Collections.Generic.List[string]
    foreach ($Candidate in $Candidates) {
        $Line = [string]$Candidate
        if ($Line.Length -gt $OutputTailRawLineLength) { $Line = $Line.Substring(0, $OutputTailRawLineLength) }
        # ANSI CSI and OSC sequences, then any other two-byte escape.
        $Line = $Line -replace "\x1b\[[0-?]*[ -/]*[@-~]", ""
        $Line = $Line -replace "\x1b\][^\x07\x1b]*(\x07|\x1b\\)?", ""
        $Line = $Line -replace "\x1b[@-Z\\-_]?", ""
        # A carriage return redraws the line: only the last frame was shown.
        $Frames = @($Line -split "\r" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $Line = if ($Frames.Count -gt 0) { [string]$Frames[-1] } else { "" }
        # Leading space is kept: it is a chezmoi status column and PowerShell
        # error-record indentation.
        $Line = ($Line -replace "[\x00-\x1f\x7f-\x9f]", " ").TrimEnd()
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        # Spinner and progress-bar rows (block elements and geometric
        # shapes) carry no diagnostic text.
        if ($Line -match '^[\-\\|/\s\u2580-\u259F\u25A0-\u25FF]+$' -or
            $Line -match '^[\s\u2580-\u259F\u25A0-\u25FF]+\s*[\d.]+\s*(%|[KMGT]?i?B\s*/\s*[\d.]+\s*[KMGT]?i?B)\s*$') {
            continue
        }
        $Clean.Add($Line)
    }
    return [string[]]$Clean.ToArray()
}

function New-OutputTail {
    return @{
        Entries = [System.Collections.Generic.Queue[object]]::new()
        InPem = $false
        Previous = $null
    }
}

function Add-OutputTailLine([hashtable]$Tail, [object]$Item) {
    foreach ($Line in @(ConvertTo-CleanOutputLines $Item)) {
        $Entry = @{ Text = $Line; Redacted = $false }
        if ($Tail.InPem) {
            # Everything from BEGIN through END, or to the end of the tail
            # when the block never terminates.
            $Entry.Redacted = $true
            if ($Line.Contains("-----END")) { $Tail.InPem = $false }
        } elseif ($Line.Contains("-----BEGIN")) {
            $Entry.Redacted = $true
            $Tail.InPem = $Line.LastIndexOf("-----END") -lt $Line.LastIndexOf("-----BEGIN")
        } elseif (Test-SecretLikeText $Line) {
            $Entry.Redacted = $true
        }
        # A secret wrapped across two lines: judge each adjacent pair whole,
        # both unseparated (a split token) and space-joined (a split
        # assignment), as lib/fleet-store.sh joins lines before its check.
        # When one side already matched on its own, the other is redacted
        # only if it is a bare fragment (no inner space) that the unseparated
        # join still flags, so one secret line never hides the error beside it.
        $Previous = $Tail.Previous
        if ($null -ne $Previous -and -not ($Previous.Redacted -and $Entry.Redacted)) {
            $Left = [string]$Previous.Text
            if ($Left.Length -gt 4096) { $Left = $Left.Substring($Left.Length - 4096) }
            $Right = $Line
            if ($Right.Length -gt 4096) { $Right = $Right.Substring(0, 4096) }
            $Tight = $Left.TrimEnd() + $Right.TrimStart()
            if (-not $Previous.Redacted -and -not $Entry.Redacted) {
                if ((Test-SecretLikeText $Tight) -or (Test-SecretLikeText ($Left + " " + $Right))) {
                    $Previous.Redacted = $true
                    $Entry.Redacted = $true
                }
            } else {
                $Unredacted = if ($Previous.Redacted) { $Entry } else { $Previous }
                if (([string]$Unredacted.Text).Trim() -match '^\S+$' -and (Test-SecretLikeText $Tight)) {
                    $Unredacted.Redacted = $true
                }
            }
        }
        $Tail.Previous = $Entry
        $Tail.Entries.Enqueue($Entry)
        while ($Tail.Entries.Count -gt $OutputTailLines) { [void]$Tail.Entries.Dequeue() }
    }
}

function Get-OutputTailLines([hashtable]$Tail) {
    $Lines = New-Object System.Collections.Generic.List[string]
    foreach ($Entry in $Tail.Entries) {
        $Line = [string]$Entry.Text
        if ($Entry.Redacted) {
            $Line = $OutputTailRedacted
        } elseif ($Line.Length -gt $OutputTailLineLength) {
            $Line = $Line.Substring(0, $OutputTailLineLength - 3) + "..."
        }
        $Lines.Add($Line)
    }
    return [string[]]$Lines.ToArray()
}

function Get-OutputTail([object[]]$Items) {
    $Tail = New-OutputTail
    foreach ($Item in @($Items)) { Add-OutputTailLine $Tail $Item }
    return Get-OutputTailLines $Tail
}

function ConvertTo-SafeOutputLines([object]$Item) {
    # One item, sanitized and redacted exactly as a tail would be.
    return Get-OutputTail @(, $Item)
}

function Join-OutputTail([string[]]$Earlier, [string[]]$Later) {
    # Both halves stay visible: at most half the budget for the earlier one.
    $Keep = [Math]::Min(@($Earlier).Count, [int]($OutputTailLines / 2))
    $Head = @(@($Earlier) | Select-Object -Last $Keep)
    $Rest = @(@($Later) | Select-Object -Last ($OutputTailLines - $Head.Count))
    return [string[]]@($Head + $Rest | Where-Object { $null -ne $_ })
}

function Get-ErrorOutputTail([object]$ErrorRecord) {
    $Exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) {
        $ErrorRecord.Exception
    } else {
        $ErrorRecord
    }
    if ($Exception -is [Exception] -and $null -ne $Exception.Data -and $Exception.Data.Contains("OutputTail")) {
        return [string[]]@($Exception.Data["OutputTail"])
    }
    return [string[]]@()
}

function Join-FailureDetail([string]$Message, [string[]]$Tail) {
    # The one-line form the controller log shows. Earlier lines give way first:
    # the last lines of a failing command are the ones that name the error.
    $Lines = @(@($Tail) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($Lines.Count -eq 0) { return $Message }
    $Prefix = "$Message; output tail: "
    $Joined = $Lines -join " | "
    while ($Lines.Count -gt 1 -and ($Prefix.Length + $Joined.Length) -gt $OutputTailMessageLength) {
        $Lines = @($Lines | Select-Object -Skip 1)
        $Joined = "... | " + ($Lines -join " | ")
    }
    $Detail = $Prefix + $Joined
    if ($Detail.Length -gt $OutputTailMessageLength) { $Detail = $Detail.Substring(0, $OutputTailMessageLength) }
    return $Detail
}

function New-NativeFailure([string]$Name, [object]$NativeExitCode, [string[]]$Tail) {
    $ExitCode = $(if ($null -eq $NativeExitCode) { 1 } else { [int]$NativeExitCode })
    $Failure = [InvalidOperationException]::new("Native command failed: $Name (exit $ExitCode)")
    $Failure.Data["ExitCode"] = $ExitCode
    $Failure.Data["OutputTail"] = [string[]]@($Tail)
    return $Failure
}

function Invoke-Captured([string]$Source, [string[]]$Arguments) {
    # The sealed argv runs exactly as before, with stdout and stderr still
    # redirected away from the console; only a bounded, sanitized tail of the
    # merged streams is kept, as it streams, in $script:LastOutputTail.
    $PSNativeCommandUseErrorActionPreference = $false
    $Tail = New-OutputTail
    $script:LastOutputTail = [string[]]@()
    & $Source @Arguments 2>&1 | ForEach-Object { Add-OutputTailLine $Tail $_ }
    $NativeExitCode = $LASTEXITCODE
    $script:LastOutputTail = Get-OutputTailLines $Tail
    return $NativeExitCode
}

function Invoke-NpmUpdater([object]$Operation, [string[]]$Argv) {
    $Name = ([string]$Operation.id).Substring(4)
    $NpmSource = Get-SelectedNpm
    Assert-NpmRegistryCandidate $NpmSource $Name ([string]$Operation.candidate_version)
    $Path = Get-NpmUpdaterPath $Name $Argv[0]
    return Invoke-WithNpmOnPath $NpmSource {
        $NativeExitCode = Invoke-Captured $Path ([string[]]@($Argv | Select-Object -Skip 1))
        if ($null -ne $NativeExitCode -and $NativeExitCode -ne 0) {
            throw (New-NativeFailure $Argv[0] $NativeExitCode $script:LastOutputTail)
        }
        $(if ($null -eq $NativeExitCode) { 0 } else { [int]$NativeExitCode })
    }
}

function Invoke-Exact([string[]]$Argv) {
    $Command = Get-Command $Argv[0] -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $Command) { throw "Required command is unavailable: $($Argv[0])" }
    $NativeExitCode = Invoke-Captured $Command.Source ([string[]]@($Argv | Select-Object -Skip 1))
    if ($null -ne $NativeExitCode -and $NativeExitCode -ne 0) {
        throw (New-NativeFailure $Argv[0] $NativeExitCode $script:LastOutputTail)
    }
    return $(if ($null -eq $NativeExitCode) { 0 } else { [int]$NativeExitCode })
}

function Invoke-CodexPluginHooks {
    param(
        [string]$Action,
        [string]$PluginId,
        [AllowNull()][string]$HelperPath = $null
    )

    if ($Action -notin @("approve", "update")) { throw "Invalid Codex hook action" }
    if ($PluginId -notmatch "^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$") {
        throw "Invalid Codex plugin ID"
    }
    # Keep the DSC executor on the same resolver as the documented native
    # Windows path: Codex owns the primary bundled Node, with Claude last.
    $PowerShell = Get-Command -Name @(
        "pwsh.exe", "pwsh", "powershell.exe", "powershell"
    ) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $PowerShell) { throw "PowerShell is required for Codex plugin hook refresh" }
    $Helper = if ($HelperPath) { $HelperPath } else { Join-Path $PSScriptRoot "codex-plugin-hooks.ps1" }
    Assert-RegularFile $Helper "Codex plugin hook helper" | Out-Null
    $DiagnosticPath = [IO.Path]::GetTempFileName()
    $Diagnostic = ""
    try {
        & $PowerShell.Source -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $Helper -Action $Action -PluginId $PluginId 1>$null 2>$DiagnosticPath
        $Succeeded = $?
        $NativeExitCode = $LASTEXITCODE
        if ([IO.File]::Exists($DiagnosticPath)) {
            $Diagnostic = [IO.File]::ReadAllText($DiagnosticPath)
        }
    } finally {
        Remove-Item -LiteralPath $DiagnosticPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $Succeeded -or ($null -ne $NativeExitCode -and $NativeExitCode -ne 0)) {
        if (-not [string]::IsNullOrWhiteSpace($Diagnostic)) {
            [Console]::Error.Write($Diagnostic.TrimEnd() + [Environment]::NewLine)
        }
        $FailureMessage = "Codex plugin hook operation failed"
        if (-not [string]::IsNullOrWhiteSpace($Diagnostic)) {
            $FailureMessage += ": " + $Diagnostic.Trim()
        }
        $Failure = [InvalidOperationException]::new($FailureMessage)
        $Failure.Data["ExitCode"] = $(if ($null -eq $NativeExitCode) { 1 } else { [int]$NativeExitCode })
        throw $Failure
    }
    return $(if ($null -eq $NativeExitCode) { 0 } else { [int]$NativeExitCode })
}

function Get-SafeFailureMessage([object]$ErrorRecord) {
    $Message = [string]$ErrorRecord
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) {
        $Message = [string]$ErrorRecord.Exception.Message
    } elseif ($ErrorRecord -is [Exception]) {
        $Message = [string]$ErrorRecord.Message
    }
    $Message = $Message -replace "[\x00-\x1f\x7f-\x9f]", " "
    if ($Message.Length -gt 512) { $Message = $Message.Substring(0, 512) }
    if ([string]::IsNullOrWhiteSpace($Message)) { return "Windows operation failed" }
    if (Test-SecretLikeText $Message) { return "Windows operation failed: $FailureMessageRedacted" }
    return $Message
}

function Get-FailureLine([string]$Stage, [object]$Message) {
    # The single stderr line the interop launcher relays. The message is
    # checked again as a whole: it may not have been built from a tail.
    $Line = "roundhouse: Windows apply failed at $Stage"
    $Text = [string]$Message -replace "[\x00-\x1f\x7f-\x9f]", " "
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Line }
    if (Test-SecretLikeText $Text) { return "$Line`: $FailureMessageRedacted" }
    return "$Line`: $Text"
}

function Assert-ResultPath {
    $Directory = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Result directory does not exist"
    }
    if (Test-Path -LiteralPath $ResultPath) {
        $Existing = Get-Item -LiteralPath $ResultPath -Force
        if ($Existing.PSIsContainer -or
            ($Existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Result path must be a regular non-link file"
        }
    }
}

function Assert-Postcondition([object]$Operation, [object[]]$Before, [object[]]$After, [object[]]$Operations = @()) {
    $BeforeRecord = @(Get-Record $Before ([string]$Operation.kind) ([string]$Operation.id))
    $AfterRecord = @(Get-Record $After ([string]$Operation.kind) ([string]$Operation.id))
    if ($Operation.type -eq "agent-update" -and [string]$Operation.id -match
        "^(?<agent>claude|codex):(?<market>[A-Za-z0-9._-]+):(?<name>[A-Za-z0-9._-]+):[^:]+$") {
        $Agent = $Matches.agent
        $Marketplace = $Matches.market
        $Name = $Matches.name
        $AfterRecord = @($After | Where-Object {
            $_.kind -eq "plugin" -and $_.status -eq "present" -and
            $_.data.agent -eq $Agent -and $_.data.marketplace -eq $Marketplace -and
            $_.data.name -eq $Name
        })
    }
    if ($AfterRecord.Count -ne 1 -or $AfterRecord[0].status -ne "present") {
        throw "Post-change inventory does not contain the expected record"
    }
    switch ([string]$Operation.type) {
        "package-upgrade" {
            if ($AfterRecord[0].data.installed_version -ne [string]$Operation.candidate_version) {
                throw "Package did not reach the sealed candidate version"
            }
            if ([string]$Operation.id -ceq "fnm:node") {
                Assert-NodeSwitchPostcondition $Operation $AfterRecord[0] $Operations
            }
        }
        "agent-update" {
            if ([string]$Operation.kind -eq "agent_runtime") { break }
            if ($BeforeRecord.Count -ne 1 -or (Test-SameMeaningfulData $BeforeRecord[0] $AfterRecord[0])) {
                throw "Agent update produced no authoritative state change"
            }
        }
        "project-clone" {
            if ($AfterRecord[0].data.repository_readiness -ne "ready" -or
                $AfterRecord[0].data.origin_matches -ne $true -or
                [int]$AfterRecord[0].data.dirty_count -ne 0) {
                throw "Cloned project is not ready"
            }
        }
        "project-update" {
            if ($BeforeRecord.Count -ne 1 -or $BeforeRecord[0].data.head -eq $AfterRecord[0].data.head -or
                $AfterRecord[0].data.repository_readiness -ne "ready" -or
                $AfterRecord[0].data.origin_matches -ne $true -or
                [int]$AfterRecord[0].data.dirty_count -ne 0) {
                throw "Project did not fast-forward to a ready state"
            }
        }
        "chezmoi-pull" {
            if ([int]$AfterRecord[0].data.dirty_count -ne 0) {
                throw "Chezmoi source is not clean after pull"
            }
        }
        "chezmoi-apply" {
            if ($null -ne $Operation.PSObject.Properties["targets"]) {
                Assert-ChezmoiTargetStatus $Operation $false
            } elseif ([int]$AfterRecord[0].data.drift_count -ne 0) {
                $Failure = [InvalidOperationException]::new("Chezmoi still reports drift after apply")
                $Failure.Data["OutputTail"] = Get-ChezmoiStatusTail
                throw $Failure
            }
        }
    }
}

function Write-Result([object[]]$Records) {
    Assert-ResultPath
    $Directory = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
    $Temporary = Join-Path $Directory (".roundhouse-" + [Guid]::NewGuid().ToString("N"))
    try {
        $Lines = @($Records | Sort-Object host_id, kind, id | ForEach-Object {
            if (-not (Test-BoundedStrings $_)) { throw "Result record contains an oversized or control string" }
            $Line = $_ | ConvertTo-Json -Compress -Depth 20
            if ([Text.Encoding]::UTF8.GetByteCount($Line) -gt 65536) {
                throw "Result record exceeds 65536 bytes"
            }
            $Line
        })
        [IO.File]::WriteAllText($Temporary, (($Lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $Temporary -Destination $ResultPath -Force
    } finally {
        Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue
    }
}

function New-ApplyOperationRecord(
    [object]$Result,
    [string]$SnapshotId,
    [string]$ObservedAt,
    [object]$Plan,
    [string]$ConfirmedPlanId,
    [string]$TargetHostId,
    [string]$ControllerDigest,
    [string]$WorkerDigest
) {
    $Completed = [string]$Result.operation_status -eq "completed"
    $Record = [ordered]@{
        schema = "roundhouse.inventory"
        schema_version = 1
        snapshot_id = $SnapshotId
        host_id = $TargetHostId
        kind = "operation"
        id = "apply:$ConfirmedPlanId`:$($Result.index)"
        observed_at = $ObservedAt
        status = $(if ($Completed) { "present" } else { "error" })
        confidence = "high"
        data = @{
            run_id = $SnapshotId
            host_id = $TargetHostId
            scope = @($Plan.domain)
            phase = [string]$Result.stage
            operation_status = [string]$Result.operation_status
            plan_id = $ConfirmedPlanId
            operation_index = $Result.index
            operation_type = $Result.operation.type
            operation_id = $Result.operation.id
            exit_code = $Result.exit_code
            transport = "codex-remote-control"
            configuration_digest = $ControllerDigest
            worker_configuration_digest = $WorkerDigest
            executor = $Plan.required_executor
        }
        evidence = @(@{
            source = "sealed-plan"
            method = $(if ($Completed) { "exact-argv+native-exit+post-inventory" } else { "exact-argv+native-failure+post-inventory-attempt" })
        })
        errors = @(if (-not $Completed) {
            @{
                code = "operation_failed"
                severity = "error"
                retryable = $true
                message = [string]$Result.message
            }
        })
    }
    # Only a failed operation carries its sanitized output tail.
    $Tail = @(@($Result.output_tail) | Where-Object { $_ -is [string] -and $_.Length -gt 0 })
    if (-not $Completed -and $Tail.Count -gt 0) {
        $Record.data["output_tail"] = [string[]]$Tail
    }
    return $Record
}

function New-ApplySummaryRecord(
    [object]$Failure,
    [string]$SnapshotId,
    [string]$ObservedAt,
    [object]$Plan,
    [string]$ConfirmedPlanId,
    [string]$TargetHostId,
    [string]$PlanFileSha256,
    [string]$ControllerDigest,
    [string]$WorkerDigest,
    [string]$PostInventoryStatus
) {
    $Completed = $null -eq $Failure
    return [ordered]@{
        schema = "roundhouse.inventory"
        schema_version = 1
        snapshot_id = $SnapshotId
        host_id = $TargetHostId
        kind = "operation"
        id = "apply:$ConfirmedPlanId"
        observed_at = $ObservedAt
        status = $(if ($Completed) { "present" } else { "partial" })
        confidence = "high"
        data = @{
            run_id = $SnapshotId
            host_id = $TargetHostId
            scope = @($Plan.domain)
            phase = $(if ($Completed) { "verify" } else { [string]$Failure.stage })
            operation_status = $(if ($Completed) { "completed" } else { "partial" })
            plan_id = $ConfirmedPlanId
            plan_file_sha256 = $PlanFileSha256
            operation_count = @($Plan.operations).Count
            failed_operation_index = $(if ($Completed) { $null } else { $Failure.index })
            failed_operation_status = $(if ($Completed) { $null } else { "failed" })
            post_inventory_status = $PostInventoryStatus
            transport = "codex-remote-control"
            configuration_digest = $ControllerDigest
            worker_configuration_digest = $WorkerDigest
            executor = $Plan.required_executor
        }
        evidence = @(@{
            source = "sealed-plan"
            method = $(if ($Completed) { "verified-execution+post-inventory" } else { "partial-execution+post-inventory-attempt" })
        })
        errors = @(if (-not $Completed) {
            @{
                code = "apply_partial"
                severity = "error"
                retryable = $true
                message = [string]$Failure.message
            }
        })
    }
}

# --- The Node runtime on Windows: the sealed fnm:node switch ------------------
#
# lib/node-runtime.sh's Windows arm (docs/specs/2026-09-28-npm-global-manager.md
# §7.7), over node-fnm-windows.ps1's discovery. A switch starts the target
# with an EMPTY global set and carries every global explicitly, in the user's
# own session: fnm installs per user, so nothing here is ever elevated.
#
# Three phases with POSIX's guarantees. PREFLIGHT mutates nothing. STAGING
# installs the target and makes its prefix exactly the carry while the old
# default stays live. The FLIP records the switch in flight, moves the
# default, verifies it, runs the hooks, verifies it again, and only then
# clears the record; any failure after the flip restores the old default
# (verified) or leaves the record for the bootstrap to restore.

# The pinned official release the bootstrap falls back to when winget cannot
# install fnm in this session: verified by SHA-256 before anything is unpacked.
$script:FnmPinnedRelease = "v1.39.0"
$script:FnmPinnedWindowsZipSha256 = "8183bed4348cb78fdfd8abb3d1247fbeab7b2082f941363929c61e747c001e10"

function Get-DurableNpmPath {
    # lib/npm.sh's order: fnm's `default` alias first, then PATH (the winget
    # MSI's npm while fnm has no default). Never an fnm per-shell path.
    $Root = Get-FnmRoot
    if ($null -ne $Root) { return Get-NodeToolPath (Get-FnmAliasBinDir $Root) "npm" }
    $Npm = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $Npm -or [string]$Npm.Source -match 'fnm_multishells') { throw "Required command is unavailable: npm" }
    return [string]$Npm.Source
}

function Get-NodeTargetBundled([string]$Target) {
    # What a Node release ships itself: npm always, corepack on 24 and older.
    if ((Get-NodeVersionMajor $Target) -lt 25) { return @("npm", "corepack") }
    return @("npm")
}

function Test-NpmArgv([object]$Value) {
    # lib/npm.sh's npm_argv_ok: a bin the package installs, then at most seven
    # literal arguments.
    if ($Value -isnot [array]) { return $false }
    $Items = @($Value)
    if ($Items.Count -lt 1 -or $Items.Count -gt 8 -or @($Items | Where-Object { $_ -isnot [string] }).Count -gt 0) { return $false }
    if ([string]$Items[0] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return $false }
    foreach ($Item in @($Items | Select-Object -Skip 1)) {
        if ($Item.Length -gt 128 -or $Item -cnotmatch '^[A-Za-z0-9@=:,._/+-]+$') { return $false }
    }
    return $true
}

function Test-NodeHookList([object]$Value) {
    if ($Value -isnot [array] -or @($Value).Count -gt 64) { return $false }
    foreach ($Hook in @($Value)) {
        if (-not (Test-ExactProperties $Hook @("argv", "package")) -or $Hook.package -isnot [string] -or
            -not ([string]$Hook.package).StartsWith("npm:", [StringComparison]::Ordinal) -or
            -not (Test-NpmNameText ([string]$Hook.package).Substring(4)) -or -not (Test-NpmArgv $Hook.argv)) {
            return $false
        }
    }
    return $true
}

function Assert-NodeSwitchOperationShape([object]$Operation) {
    # node_switch_operations_valid: the fixed marker argv, and `carry`,
    # `hooks` and `required` in the npm grammar, carried names unique.
    $Candidate = [string]$Operation.candidate_version
    if (-not (Test-NodeVersionText $Operation.candidate_version) -or
        (ConvertTo-CanonicalJson @($Operation.argv)) -cne (ConvertTo-CanonicalJson @("fnm", "default", $Candidate))) {
        throw "Invalid Node runtime switch"
    }
    $Carry = $Operation.carry
    if ($Carry -isnot [array] -or @($Carry).Count -gt 256) { throw "Invalid Node switch carry list" }
    $Names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($Item in @($Carry)) {
        if (-not (Test-ExactProperties $Item @("name", "version")) -or -not (Test-NpmNameText $Item.name) -or
            -not (Test-NpmVersionText $Item.version) -or -not $Names.Add([string]$Item.name)) {
            throw "Invalid Node switch carry list"
        }
    }
    if (-not (Test-NodeHookList $Operation.hooks) -or -not (Test-NodeHookList $Operation.required)) {
        throw "Invalid Node switch hook list"
    }
}

function Get-ConfigNodeSwitchHooks([object]$Config, [object[]]$Carry) {
    # What this worker configuration declares for the carried packages, in
    # carry order: the hooks a switch runs.
    $Hooks = New-Object System.Collections.Generic.List[object]
    foreach ($Item in @($Carry)) {
        $Key = "npm:" + [string]$Item.name
        $Declared = $null
        if ($null -ne $Config -and $null -ne $Config.node_switch_hooks) {
            $Declared = $Config.node_switch_hooks.PSObject.Properties |
                Where-Object { $_.Name -ceq $Key } | Select-Object -First 1
        }
        if ($null -eq $Declared) { continue }
        foreach ($Argv in @($Declared.Value)) {
            $Hook = [ordered]@{ package = $Key; argv = [string[]]@($Argv) }
            $Hooks.Add($Hook)
        }
    }
    # ToArray, not @(): PowerShell 7.6 cannot wrap a List of dictionaries.
    return , $Hooks.ToArray()
}

function Get-NodeSwitchExpected([object]$Record, [string]$Target, [object]$Config) {
    # node_switch_plan over the fresh snapshot, without definitions (`required`
    # is bound by the plan digest): the carry is every global installed under
    # the current default at its exact version, less what TARGET ships itself;
    # an unknown or unpinnable global, or a switch in flight, holds.
    $Bundled = Get-NodeTargetBundled $Target
    $Data = $Record.data
    $UnpinnableProperty = $Data.PSObject.Properties["globals_unpinnable"]
    $DetailKnown = $null -ne $UnpinnableProperty -and $UnpinnableProperty.Value -is [array]
    $Unpinnable = if ($DetailKnown) { @($UnpinnableProperty.Value | ForEach-Object { [string]$_ }) } else { @() }
    $Names = @()
    if ($null -ne $Data.globals) { $Names = @($Data.globals.PSObject.Properties.Name) }
    [Array]::Sort($Names, [StringComparer]::Ordinal)
    $Carry = New-Object System.Collections.Generic.List[object]
    foreach ($Name in $Names) {
        if ($Bundled -ccontains $Name -or $Unpinnable -ccontains $Name) { continue }
        $Item = [ordered]@{ name = $Name; version = [string]$Data.globals.$Name }
        $Carry.Add($Item)
    }
    $Stranded = @($Unpinnable | Where-Object { $Bundled -cnotcontains $_ } | Sort-Object -Unique)
    $Inflight = $Data.PSObject.Properties["switch_inflight"]
    $Held = if (-not $DetailKnown) {
        "which npm globals cannot be reinstalled by exact registry version is unknown (the global inventory detail is unavailable)"
    } elseif ($Stranded.Count -gt 0) {
        "npm globals $($Stranded -join ' ') cannot be reinstalled by exact registry version (file:, link:, git or no version); a switch would strand them"
    } elseif ($null -ne $Inflight -and $null -ne $Inflight.Value) {
        "an interrupted Node switch is pending recovery on this host"
    } else { $null }
    $CarryItems = $Carry.ToArray()
    return @{ Carry = $CarryItems; Hooks = (Get-ConfigNodeSwitchHooks $Config $CarryItems); Held = $Held }
}

function Assert-NodeSwitchMatchesSnapshot([object]$Operation, [object]$Record, [object]$Config) {
    # node_switch_verify_snapshot plus plan-apply.sh's hook check: the carry
    # rule over the fresh snapshot must hold nothing and give exactly the
    # sealed carry, the hooks must be exactly what this worker's configuration
    # declares for it, and every sealed `required` hook must be among them.
    if ($Record.status -ne "present" -or $null -eq $Record.data.globals -or
        -not (Test-NodeVersionText $Record.data.installed_version)) {
        throw "the snapshot does not record the npm globals under the current Node default"
    }
    $Expected = Get-NodeSwitchExpected $Record ([string]$Operation.candidate_version) $Config
    if ($null -ne $Expected.Held) { throw "Node switch held: $($Expected.Held)" }
    if ((ConvertTo-CanonicalJson @($Operation.carry)) -cne (ConvertTo-CanonicalJson @($Expected.Carry))) {
        throw "the Node switch carry no longer matches the installed npm globals; create a new plan"
    }
    if ((ConvertTo-CanonicalJson @($Operation.hooks)) -cne (ConvertTo-CanonicalJson @($Expected.Hooks))) {
        throw "Node switch hooks differ from the configured node_switch_hooks"
    }
    $HookTexts = @(@($Operation.hooks) | ForEach-Object { ConvertTo-CanonicalJson $_ })
    foreach ($Required in @($Operation.required)) {
        if ($HookTexts -cnotcontains (ConvertTo-CanonicalJson $Required)) {
            throw "a required post-switch hook is not among the configured hooks"
        }
    }
}

function Assert-NodeSwitchPostcondition([object]$Operation, [object]$AfterRecord, [object[]]$Operations) {
    # The NEW default holds exactly the carry (plus what the release bundles,
    # and nothing left over from an earlier use), each at its carried version
    # or at the candidate of a later npm upgrade of it in this same plan.
    $Bundled = Get-NodeTargetBundled ([string]$Operation.candidate_version)
    $Data = $AfterRecord.data
    $Unpinnable = $Data.PSObject.Properties["globals_unpinnable"]
    if ($null -eq $Data.globals -or $null -eq $Unpinnable -or $Unpinnable.Value -isnot [array] -or
        $null -ne $Data.switch_inflight) {
        throw "Node switch post-state is not a verified default with a known global set"
    }
    $Names = @($Data.globals.PSObject.Properties.Name | Where-Object { $Bundled -cnotcontains $_ })
    $Carried = @(@($Operation.carry) | ForEach-Object { [string]$_.name })
    [Array]::Sort($Names, [StringComparer]::Ordinal)
    [Array]::Sort($Carried, [StringComparer]::Ordinal)
    if (($Names -join "`0") -cne ($Carried -join "`0") -or
        @($Unpinnable.Value | Where-Object { $Bundled -cnotcontains $_ }).Count -gt 0) {
        throw "the npm globals under the new Node default are not exactly the carry"
    }
    foreach ($Item in @($Operation.carry)) {
        $Expected = [string]$Item.version
        foreach ($Later in @($Operations)) {
            if ($Later.type -eq "package-upgrade" -and [string]$Later.id -ceq ("npm:" + [string]$Item.name)) {
                $Expected = [string]$Later.candidate_version
            }
        }
        if ([string]$Data.globals.($Item.name) -cne $Expected) {
            throw "a carried npm global is not at its carried version under the new Node default"
        }
    }
}

function Invoke-FnmInRoot([string]$Root, [scriptblock]$Body) {
    # BODY with fnm found and pinned to ROOT ($Fnm in its scope).
    $Fnm = Get-FnmCommandPath
    if ($null -eq $Fnm) { throw "fnm is not installed" }
    $Saved = $env:FNM_DIR
    try {
        $env:FNM_DIR = $Root
        return (& $Body)
    } finally {
        $env:FNM_DIR = $Saved
    }
}

function ConvertTo-ExitCode([object]$NativeExitCode) {
    return $(if ($null -eq $NativeExitCode) { 0 } else { [int]$NativeExitCode })
}

# The commands a switch runs, as replaceable operations: the real ones here,
# in-memory fakes in the self-test, so the phases are proven without fnm. The
# ones returning an exit code leave the command's output tail in
# $script:LastOutputTail (Invoke-Captured).
$script:NodeOps = @{
    Fnm = {
        param([string]$Root, [string[]]$Arguments)
        return Invoke-FnmInRoot $Root { ConvertTo-ExitCode (Invoke-Captured $Fnm $Arguments) }
    }
    FnmLines = {
        param([string]$Root, [string[]]$Arguments)
        return Invoke-FnmInRoot $Root { Invoke-FnmLines $Fnm $Root $Arguments }
    }
    Npm = {
        # The npm at NPMPATH under the node beside it, against PREFIX (so no
        # `prefix=` in an npmrc can redirect it).
        param([string]$NpmPath, [string]$Prefix, [string[]]$Arguments)
        $All = [string[]](@("--prefix", $Prefix) + $Arguments)
        return Invoke-WithNpmOnPath $NpmPath { ConvertTo-ExitCode (Invoke-Captured $NpmPath $All) }
    }
    NpmText = {
        # A query's stdout (`ls`, `prefix`), against PREFIX when given.
        param([string]$NpmPath, [string]$Prefix, [string[]]$Arguments)
        # Typed and wrapped: an `if` used as an expression unrolls a one-element
        # array into a bare string, and splatting a string passes its characters
        # (`npm --version` ran as `npm - - v e r …`).
        [string[]]$All = @(if ([string]::IsNullOrEmpty($Prefix)) { $Arguments } else { @("--prefix", $Prefix) + $Arguments })
        return Invoke-WithNpmOnPath $NpmPath { ((@(& $NpmPath @All 2>$null) | ForEach-Object { [string]$_ }) -join "`n") }
    }
    NpmSelf = {
        # npm replacing itself in a Node prefix: run by the prefix's node
        # from its npm-cli.js, never through the npm.cmd it overwrites, with
        # --force for the shims that ship with Node (not npm-written ones).
        param([string]$Prefix, [string]$Version)
        $Bin = Get-FnmBinDir $Prefix
        $Cli = Join-Path (Join-Path (Join-Path (Get-FnmNpmRoot $Prefix) "npm") "bin") "npm-cli.js"
        $Arguments = [string[]]@($Cli, "--prefix", $Prefix, "install", "--global", "--force", "npm@$Version")
        return Invoke-WithNpmOnPath (Get-NodeToolPath $Bin "npm") {
            ConvertTo-ExitCode (Invoke-Captured (Get-NodeToolPath $Bin "node") $Arguments)
        }
    }
    NodeVersion = {
        param([string]$BinDir)
        $Node = Get-NodeToolPath $BinDir "node"
        if (-not (Test-Path -LiteralPath $Node -PathType Leaf)) { return $null }
        return ((@(& $Node --version 2>$null) | Select-Object -First 1) -as [string])
    }
    Hook = {
        # By absolute path, with the new node first on PATH.
        param([string]$Path, [string[]]$Arguments, [string]$BinDir)
        return Invoke-WithNpmOnPath (Get-NodeToolPath $BinDir "npm") { ConvertTo-ExitCode (Invoke-Captured $Path $Arguments) }
    }
}

function New-NodeSwitchFailure([string]$Message, [string[]]$Tail) {
    # A switch failure carrying the failing command's own output, as
    # New-NativeFailure does for a sealed argv.
    $Failure = [InvalidOperationException]::new($Message)
    $Failure.Data["OutputTail"] = [string[]]@($Tail)
    return $Failure
}

function Get-NpmGlobalDetail([string]$NpmPath, [string]$Prefix) {
    # One `npm ls` through Split-NpmGlobalList. Throws when it fails: an
    # unknown global set is never an empty one.
    $Text = [string](& $script:NodeOps.NpmText $NpmPath $Prefix @("ls", "--global", "--json", "--depth=0"))
    $List = $null
    try { $List = $Text | ConvertFrom-Json -ErrorAction Stop } catch { $List = $null }
    $Split = Split-NpmGlobalList $List
    if ($null -eq $Split) { throw "the npm global inventory$(if ($Prefix) { " under $Prefix" }) failed" }
    return $Split
}

function Get-NodeHookPath([string]$Prefix, [string]$Name, [string]$Bin) {
    return Get-PackageBinPath (Get-FnmNpmRoot $Prefix) $Prefix $Name $Bin
}

function Write-NodeSwitchMarker([string]$Root, [string]$Old, [string]$Target, [object[]]$Carry) {
    # lib/node-runtime.sh's record, plus the fnm root the switch used, so a
    # recovery restores the same tree.
    [void][IO.Directory]::CreateDirectory($script:NodeSwitchStateDir)
    $Path = Get-NodeSwitchMarkerPath
    $Json = [ordered]@{
        old = $Old
        target = $Target
        root = $Root
        carry = @($Carry)
        writer = [ordered]@{ pid = [string]$PID; start = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o") }
        at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json -Compress -Depth 6
    [IO.File]::WriteAllText("$Path.$PID", $Json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath "$Path.$PID" -Destination $Path -Force
}

function Clear-NodeSwitchMarker {
    # Removed, provably: a record left behind would roll a finished switch back.
    $Path = Get-NodeSwitchMarkerPath
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) { throw "the in-flight Node switch record $Path could not be removed" }
}

function Enter-NodeSwitchLock {
    # One lock covers a whole switch, a recovery and the bootstrap: a file held
    # open exclusively, which the OS releases however the holder exits, so a
    # killed switch never leaves a stale lock (the in-flight record, not the
    # lock, says what needs rolling back).
    [void][IO.Directory]::CreateDirectory($script:NodeSwitchStateDir)
    $Path = Join-Path $script:NodeSwitchStateDir "node-switch.lock"
    try {
        return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw "another Node switch is in progress on this host; not switching"
    }
}

function Test-NodeDefaultVerified([string]$Root, [string]$Version) {
    # node_default_verified: the alias names VERSION, the durable npm resolves
    # through this alias, its node is VERSION, and its npm keeps the globals
    # in fnm (no npmrc `prefix=` sends them elsewhere).
    if ((Get-FnmDefaultVersion $Root) -cne $Version -or (Get-FnmRoot) -cne $Root) { return $false }
    $AliasBin = Get-FnmAliasBinDir $Root
    if (([string](& $script:NodeOps.NodeVersion $AliasBin)).Trim() -cne $Version) { return $false }
    return Test-FnmNpmPrefix ([string](& $script:NodeOps.NpmText (Get-NodeToolPath $AliasBin "npm") $null @("prefix", "--global"))) `
        $Root $Version
}

function Invoke-NodeSwitchCore {
    # STAGING then the FLIP, shared by the sealed switch and the bootstrap.
    # OLD is the fnm default being replaced, or empty when the bootstrap
    # creates the first one (nothing to restore: the MSI stays the runtime).
    param([string]$Root, [string]$Old, [string]$Target, [object[]]$Carry, [object[]]$Hooks, [string]$SourceNpmVersion)
    $Kept = if ($Old) { "$Old stays the default" } else { "fnm still has no default" }
    $Stage = {
        param([string]$Message)
        throw (New-NodeSwitchFailure "$Message; nothing switched ($Kept)" $script:LastOutputTail)
    }
    $script:LastOutputTail = [string[]]@()
    if ((& $script:NodeOps.Fnm $Root @("install", $Target)) -ne 0 -or
        -not (Test-Path -LiteralPath (Get-NodeToolPath (Get-FnmBinDir (Get-FnmInstallation $Root $Target)) "node") -PathType Leaf)) {
        & $Stage "fnm install $Target failed"
    }
    $Prefix = Get-FnmInstallation $Root $Target
    $TargetNpm = Get-NodeToolPath (Get-FnmBinDir $Prefix) "npm"
    $Bundled = Get-NodeTargetBundled $Target
    # The npm that installs the carry must not be older than the one the host
    # runs now: npm 12 honours `allow-scripts` in ~/.npmrc, and an older
    # bundled npm would run every dependency install script.
    $TargetNpmVersion = $null
    try {
        $TargetNpmVersion = [string]([IO.File]::ReadAllText((Join-Path (Join-Path (Get-FnmNpmRoot $Prefix) "npm") "package.json")) |
            ConvertFrom-Json).version
    } catch { $TargetNpmVersion = $null }
    if ((Test-NodeReleaseNewer $SourceNpmVersion $TargetNpmVersion) -and
        (& $script:NodeOps.NpmSelf $Prefix $SourceNpmVersion) -ne 0) {
        & $Stage "upgrading the npm of $Target to $SourceNpmVersion failed"
    }
    $Specs = [string[]]@(@($Carry) | ForEach-Object { "$($_.name)@$($_.version)" })
    if ($Specs.Count -gt 0 -and (& $script:NodeOps.Npm $TargetNpm $Prefix (@("install", "--global") + $Specs)) -ne 0) {
        & $Stage "carrying the npm globals to $Target failed"
    }
    # Exactly the carry: old versions are kept, so TARGET may be a version
    # used before, whose prefix still holds globals removed since. Left there,
    # a rollback would resurrect them.
    $Carried = @(@($Carry) | ForEach-Object { [string]$_.name })
    $Present = Get-NpmGlobalDetail $TargetNpm $Prefix
    foreach ($Extra in @(@($Present.Globals.Keys) + @($Present.Unpinnable) | Sort-Object -Unique)) {
        if ($Carried -ccontains $Extra -or $Bundled -ccontains $Extra) { continue }
        if ((& $script:NodeOps.Npm $TargetNpm $Prefix @("uninstall", "--global", $Extra)) -ne 0) {
            & $Stage "could not remove $Extra, left in $Target by an earlier use"
        }
    }
    $After = Get-NpmGlobalDetail $TargetNpm $Prefix
    $AfterNames = @(@($After.Globals.Keys) + @($After.Unpinnable) | Where-Object { $Bundled -cnotcontains $_ } | Sort-Object -Unique)
    if (($AfterNames -join "`0") -cne (@($Carried | Sort-Object -Unique) -join "`0") -or
        @(@($Carry) | Where-Object { -not $After.Globals.ContainsKey([string]$_.name) -or
            $After.Globals[[string]$_.name] -cne [string]$_.version }).Count -gt 0) {
        $script:LastOutputTail = [string[]]@()
        & $Stage "the npm globals under $Target are not exactly the carry at its versions"
    }

    # THE FLIP. A failure restores the old default (verified), keeping the
    # failing command's output from before the restore ran.
    $Fail = {
        param([string]$Message)
        $Tail = [string[]]@($script:LastOutputTail)
        if ($Old) {
            [void](& $script:NodeOps.Fnm $Root @("default", $Old))
            if (Test-NodeDefaultVerified $Root $Old) {
                Clear-NodeSwitchMarker
                throw (New-NodeSwitchFailure "$Message; fnm default restored to $Old ($Target stays installed)" $Tail)
            }
            throw (New-NodeSwitchFailure ("$Message; could not restore the fnm default to $Old; the switch stays " +
                "recorded as in flight ($(Get-NodeSwitchMarkerPath)); rerun the fnm bootstrap to restore it") $Tail)
        }
        # No old default: remove the unverified one, provably, so a rerun
        # never accepts it as already in the major.
        [void](& $script:NodeOps.Fnm $Root @("unalias", "default"))
        $Alias = Get-FnmAliasDir $Root
        $Left = Get-Item -LiteralPath $Alias -Force -ErrorAction SilentlyContinue
        if ($null -ne $Left -and ($Left.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            try { [IO.Directory]::Delete($Alias, $false) } catch { }
        }
        if ($null -ne (Get-Item -LiteralPath $Alias -Force -ErrorAction SilentlyContinue)) {
            throw (New-NodeSwitchFailure ("$Message; the unverified fnm default could not be removed: remove $Alias " +
                "(fnm unalias default) before rerunning") $Tail)
        }
        throw (New-NodeSwitchFailure "$Message; the fnm default was removed ($Target stays installed)" $Tail)
    }
    $script:LastOutputTail = [string[]]@()
    if ($Old -cne $Target) {
        if ($Old) { Write-NodeSwitchMarker $Root $Old $Target @($Carry) }
        if ((& $script:NodeOps.Fnm $Root @("default", $Target)) -ne 0) { & $Fail "fnm default $Target failed" }
    }
    if (-not (Test-NodeDefaultVerified $Root $Target)) {
        & $Fail "the durable npm does not run under $Target after the switch"
    }
    # Each hook is re-proved under the new default and runs through the
    # alias, so a service it registers names a path that survives later
    # switches.
    $AliasBin = Get-FnmAliasBinDir $Root
    foreach ($Hook in @($Hooks)) {
        $Name = ([string]$Hook.package).Substring(4)
        $Argv = [string[]]@($Hook.argv)
        $script:LastOutputTail = [string[]]@()
        $Path = Get-NodeHookPath (Get-FnmAliasDir $Root) $Name $Argv[0]
        if ($null -eq $Path) { & $Fail "post-switch hook $($Argv[0]) is not a bin of the installed $Name under $Target" }
        if ((& $script:NodeOps.Hook $Path ([string[]]@($Argv | Select-Object -Skip 1)) $AliasBin) -ne 0) {
            & $Fail "post-switch hook $(ConvertTo-CanonicalJson $Argv) for $Name failed"
        }
    }
    $script:LastOutputTail = [string[]]@()
    if (-not (Test-NodeDefaultVerified $Root $Target)) {
        & $Fail "the fnm default moved off $Target while the switch ran"
    }
    Clear-NodeSwitchMarker
}

function Invoke-NodeRuntimeSwitch([string]$Target, [object[]]$Carry, [object[]]$Hooks) {
    # The sealed `fnm:node` operation: make TARGET the fnm default with exactly
    # CARRY in its prefix, then run HOOKS (already matched to this worker's
    # configuration). Returns 0, or throws with the default never moved,
    # restored and verified, or recorded in flight.
    $Lock = Enter-NodeSwitchLock
    try {
        # PREFLIGHT mutates nothing.
        if ($null -ne (Read-NodeSwitchMarker)) {
            throw "an interrupted Node switch is pending recovery on this host; refusing another (rerun the fnm bootstrap to restore it)"
        }
        $Root = Get-FnmRoot
        if ($null -eq $Root) { throw "no fnm default Node on this host" }
        $Old = Get-FnmDefaultVersion $Root
        if ($null -eq $Old) { throw "the fnm default alias does not name an installed version" }
        $AliasNpm = Get-NodeToolPath (Get-FnmAliasBinDir $Root) "npm"
        if (-not (Test-FnmNpmPrefix ([string](& $script:NodeOps.NpmText $AliasNpm $null @("prefix", "--global"))) $Root $Old)) {
            throw "the fnm default's npm keeps its globals outside fnm (an npmrc prefix= or NPM_CONFIG_PREFIX); refusing the switch"
        }
        $Before = Get-NpmGlobalDetail $AliasNpm $null
        # The carry is exactly what is installed now, re-derived here: it
        # never introduces a package, and a global installed (or relinked)
        # since the apply inventory is never stranded under the old version.
        $Bundled = Get-NodeTargetBundled $Target
        $Installed = @(@($Before.Globals.Keys) + @($Before.Unpinnable) | Where-Object { $Bundled -cnotcontains $_ } | Sort-Object -Unique)
        $Carried = @(@($Carry) | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
        if (@($Before.Unpinnable | Where-Object { $Bundled -cnotcontains $_ }).Count -gt 0 -or
            ($Installed -join "`0") -cne ($Carried -join "`0") -or
            @(@($Carry) | Where-Object { $Before.Globals[[string]$_.name] -cne [string]$_.version }).Count -gt 0) {
            throw "the carry is not what is installed under $Old; refusing the switch"
        }
        $CarriedNames = @(@($Carry) | ForEach-Object { [string]$_.name })
        foreach ($Hook in @($Hooks)) {
            $Name = ([string]$Hook.package).Substring(4)
            if ($CarriedNames -cnotcontains $Name) { throw "a post-switch hook names $Name, which is not carried" }
            if ($null -eq (Get-NodeHookPath (Get-FnmInstallation $Root $Old) $Name ([string]@($Hook.argv)[0]))) {
                throw "post-switch hook $([string]@($Hook.argv)[0]) is not a bin of the installed $Name; refusing the switch"
            }
        }
        $SourceNpm = if ($Before.Globals.ContainsKey("npm")) { $Before.Globals["npm"] } else { $null }
        Invoke-NodeSwitchCore -Root $Root -Old $Old -Target $Target -Carry @($Carry) -Hooks @($Hooks) -SourceNpmVersion $SourceNpm
        return 0
    } finally {
        $Lock.Dispose()
    }
}

function Assert-NoNodeSwitchInflight {
    # Never an npm mutation under a default a switch left unverified.
    if ($null -ne (Read-NodeSwitchMarker)) {
        throw "a Node switch is recorded in flight on this host; npm upgrades are refused until it is resolved"
    }
}

# --- Bootstrap: migrate a Windows host to fnm (run once, by its user) ---------
#
# `apply-windows.ps1 -BootstrapNodeFnm -NodeMajor 26`, in the user's own,
# NON-elevated session; it shares the switch's staging and flip above. It is
# idempotent, and every step converges or is already done:
#   1. fnm, user scope: winget (Schniz.fnm, --scope user), else the pinned
#      official release, verified by SHA-256, into %LOCALAPPDATA%\fnm.
#   2. FNM_DIR, a user variable; a switch recorded in flight is restored first.
#   3. Unless the fnm default is already in the major (the sealed lane then
#      moves it within the major, running the host's post-switch hooks), the
#      newest release in the major as the fnm default, carrying every global
#      the current npm has (the MSI's %APPDATA%\npm on first run) at its
#      exact version.
#   4. The default alias first on the user PATH.
# The MSI stays installed (removing it needs elevation). The collector then
# reports it shadowed and unmanaged, and `fnm:node` carries runtimes.node.

function Test-ProcessElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-FnmArchive([string]$Path, [string]$ExpectedSha256) {
    if ((Get-FileSha256 $Path) -cne $ExpectedSha256) {
        throw "the downloaded fnm release does not match its pinned SHA-256; nothing installed"
    }
}

function Install-FnmUserScope {
    $Existing = Get-FnmCommandPath
    if ($null -ne $Existing) { return $Existing }
    $Winget = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $Winget) {
        $Code = Invoke-Captured ([string]$Winget.Source) @("install", "--id", "Schniz.fnm", "--exact", "--source", "winget",
            "--scope", "user", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")
        $Found = Get-FnmCommandPath
        if ($null -ne $Found) { return $Found }
        [Console]::Out.WriteLine("roundhouse: winget could not install fnm in this session (exit $Code); using the pinned $script:FnmPinnedRelease release")
    }
    $Work = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-fnm-" + [Guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($Work)
        $Zip = Join-Path $Work "fnm-windows.zip"
        Invoke-WebRequest -Uri "https://github.com/Schniz/fnm/releases/download/$script:FnmPinnedRelease/fnm-windows.zip" `
            -OutFile $Zip -UseBasicParsing
        Assert-FnmArchive $Zip $script:FnmPinnedWindowsZipSha256
        Expand-Archive -LiteralPath $Zip -DestinationPath (Join-Path $Work "x")
        $Destination = Join-Path $env:LOCALAPPDATA "fnm"
        [void][IO.Directory]::CreateDirectory($Destination)
        Copy-Item -LiteralPath (Join-Path (Join-Path $Work "x") "fnm.exe") -Destination (Join-Path $Destination "fnm.exe") -Force
    } finally {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Installed = Get-FnmCommandPath
    if ($null -eq $Installed) { throw "fnm could not be installed" }
    return $Installed
}

function Select-FnmBootstrapRoot {
    # An explicit FNM_DIR, else a root that already holds versions, else
    # %LOCALAPPDATA%\fnm (machine-local: never roamed with the profile).
    foreach ($Candidate in @($env:FNM_DIR, [Environment]::GetEnvironmentVariable("FNM_DIR", "User"))) {
        if (-not [string]::IsNullOrWhiteSpace($Candidate)) { return [string]$Candidate }
    }
    foreach ($Candidate in @(Get-FnmRootCandidates)) {
        if (Test-Path -LiteralPath (Join-Path $Candidate "node-versions") -PathType Container) { return $Candidate }
    }
    return Join-Path $env:LOCALAPPDATA "fnm"
}

function Get-PathWithFirstEntry([string]$PathValue, [string]$Entry) {
    # ENTRY first, once; every other entry kept in order.
    $Want = $Entry.TrimEnd('\', '/')
    $Rest = @($PathValue -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim().TrimEnd('\', '/') -ine $Want
    })
    return (@($Entry) + $Rest) -join ';'
}

function Set-NodeFnmUserEnvironment([string]$Root, [string]$AliasBin) {
    # The user's own registry environment, raw, so %VAR% entries and the
    # value kind survive. SetEnvironmentVariable broadcasts the change.
    $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    try {
        $Raw = [string]$Key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $Kind = if (@($Key.GetValueNames()) -contains "Path") { $Key.GetValueKind("Path") } else {
            [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
        $New = Get-PathWithFirstEntry $Raw $AliasBin
        if ($New -cne $Raw) { $Key.SetValue("Path", $New, $Kind) }
    } finally {
        $Key.Dispose()
    }
    [Environment]::SetEnvironmentVariable("FNM_DIR", $Root, "User")
}

function Get-MsiNpmPath([string]$Root) {
    # The npm that owns the globals before the first fnm default: PATH npm
    # outside fnm, else the MSI's own.
    $Found = @(Get-Command npm -CommandType Application -All -ErrorAction SilentlyContinue | Where-Object {
        [string]$_.Source -notmatch 'fnm_multishells' -and
        -not ([string]$_.Source).StartsWith($Root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
    if ($null -ne $Found) { return [string]$Found.Source }
    if ($env:ProgramFiles) {
        $Msi = Join-Path (Join-Path $env:ProgramFiles "nodejs") "npm.cmd"
        if (Test-Path -LiteralPath $Msi -PathType Leaf) { return $Msi }
    }
    return $null
}

function Resolve-NodeSwitchInflight([string]$Root) {
    # A switch recorded in flight (killed mid-flip, or a restore that could not
    # be verified): restore its old default in the root it recorded, verified,
    # then clear it. Never cleared blindly.
    $Marker = Read-NodeSwitchMarker
    if ($null -eq $Marker) { return $null }
    $Old = [string]$Marker.old
    $SwitchRoot = if (-not [string]::IsNullOrWhiteSpace([string]$Marker.root)) { [string]$Marker.root } else { $Root }
    if (-not (Test-NodeVersionText $Old) -or
        -not (Test-Path -LiteralPath (Get-NodeToolPath (Get-FnmBinDir (Get-FnmInstallation $SwitchRoot $Old)) "node") -PathType Leaf)) {
        throw "a Node switch is recorded in flight ($(Get-NodeSwitchMarkerPath)) and its old default '$Old' is not installed; set a default (fnm default <version>), check it, then delete that record"
    }
    [void](& $script:NodeOps.Fnm $SwitchRoot @("default", $Old))
    if (-not (Test-NodeDefaultVerified $SwitchRoot $Old)) {
        throw "a Node switch is recorded in flight and the fnm default could not be restored to $Old; nothing else changed"
    }
    Clear-NodeSwitchMarker
    return "restored the interrupted Node switch to its old default $Old (verified)"
}

function Get-SourceNpmVersion([string]$NpmPath, [object]$Detail) {
    # The newer of what NPMPATH reports running (`npm --version`) and the npm
    # its global listing holds. Throws when the running version is unknown.
    $Running = ([string](& $script:NodeOps.NpmText $NpmPath $null @("--version"))).Trim()
    if ($Running -cnotmatch '^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$') {
        throw "cannot establish the version of the npm that owns the globals ($NpmPath --version); nothing switched"
    }
    $Listed = if ($Detail.Globals.ContainsKey("npm")) { $Detail.Globals["npm"] } else { $null }
    if (Test-NodeReleaseNewer $Listed $Running) { return $Listed }
    return $Running
}

function Invoke-NodeFnmMigration {
    # The bootstrap's runtime step: leave a default already in MAJOR alone;
    # otherwise install the newest release in MAJOR and make it the default,
    # carrying every global of the current npm (the fnm default's, or
    # SOURCENPM's when fnm has none) at its exact version.
    param([string]$Root, [int]$Major, [string]$SourceNpm)
    $Default = $null
    if (Test-FnmDurableBin (Get-FnmAliasBinDir $Root)) {
        $Default = Get-FnmDefaultVersion $Root
        if ($null -eq $Default) {
            throw "the fnm default alias in $Root does not name an installed version; repair it (fnm default <version>) and rerun"
        }
    }
    if ($null -ne $Default -and (Get-NodeVersionMajor $Default) -eq $Major) {
        if (-not (Test-NodeDefaultVerified $Root $Default)) {
            throw "the fnm default $Default is not self-consistent (alias, node and npm prefix disagree); repair it (fnm default <version>) and rerun"
        }
        return @{ Switched = $false; Old = $Default; Default = $Default; Carry = @() }
    }
    $Lines = & $script:NodeOps.FnmLines $Root @("list-remote")
    if ($null -eq $Lines) { throw "cannot list the published Node releases (fnm list-remote failed)" }
    $Target = Select-FnmRemoteLatest $Lines $Major
    if ($null -eq $Target) { throw "no published Node $Major release is listed" }
    $Source = if ($null -ne $Default) { Get-NodeToolPath (Get-FnmAliasBinDir $Root) "npm" } else { $SourceNpm }
    if ([string]::IsNullOrEmpty($Source)) { throw "no npm to carry the globals from (neither an fnm default nor the MSI's npm)" }
    $Detail = Get-NpmGlobalDetail $Source $null
    $Bundled = Get-NodeTargetBundled $Target
    $Stranded = @($Detail.Unpinnable | Where-Object { $Bundled -cnotcontains $_ })
    if ($Stranded.Count -gt 0) {
        throw "npm globals $($Stranded -join ' ') cannot be reinstalled by exact registry version (file:, link:, git or no version); reinstall them from the registry or remove them, then rerun"
    }
    $Carry = @(@($Detail.Globals.Keys) | Where-Object { $Bundled -cnotcontains $_ } |
        ForEach-Object { [ordered]@{ name = $_; version = $Detail.Globals[$_] } })
    # The npm that owns the globals now, measured by running it: on the first
    # migration that is the MSI's npm.cmd, whose own npm (under Program
    # Files, or a newer one it defers to) is not in the %APPDATA%\npm listing.
    # The carry is never staged with an older npm (npm 12 honours
    # allow-scripts; an older one runs every install script), so an npm
    # version that cannot be established refuses.
    $SourceNpmVersion = Get-SourceNpmVersion $Source $Detail
    Invoke-NodeSwitchCore -Root $Root -Old $Default -Target $Target -Carry $Carry -Hooks @() -SourceNpmVersion $SourceNpmVersion
    return @{ Switched = $true; Old = $Default; Default = $Target; Carry = $Carry }
}

function Get-NodeOnNewSessionPath {
    # Which node a NEW session's bare `node` finds: Windows puts the machine
    # PATH before the user's, so a machine-wide MSI entry wins over any user
    # entry until the MSI is removed.
    $Dirs = @(([Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")) -split ';' | Where-Object { $_ })
    foreach ($Dir in $Dirs) {
        $Candidate = Join-Path ([Environment]::ExpandEnvironmentVariables($Dir)) "node.exe"
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
    }
    return $null
}

function Invoke-NodeFnmBootstrap([int]$Major) {
    if (-not $script:FnmOnWindows) { throw "the fnm bootstrap runs on native Windows only" }
    if (Test-ProcessElevated) {
        throw "refusing to run elevated: fnm installs per user; rerun from your own, non-elevated session"
    }
    $Lock = Enter-NodeSwitchLock
    try {
        $Fnm = Install-FnmUserScope
        $Root = Select-FnmBootstrapRoot
        [void][IO.Directory]::CreateDirectory($Root)
        $env:FNM_DIR = $Root
        $Restored = Resolve-NodeSwitchInflight $Root
        if ($null -ne $Restored) { Write-Output "roundhouse: $Restored" }
        $Result = Invoke-NodeFnmMigration -Root $Root -Major $Major -SourceNpm (Get-MsiNpmPath $Root)
        $AliasBin = Get-FnmAliasBinDir $Root
        Set-NodeFnmUserEnvironment $Root $AliasBin
        Write-Output "roundhouse: fnm $Fnm, FNM_DIR $Root (user)"
        if ($Result.Switched) {
            $From = if ($Result.Old) { "fnm $($Result.Old)" } else { "the MSI's npm" }
            $Carried = @($Result.Carry | ForEach-Object { "$($_.name)@$($_.version)" })
            Write-Output ("roundhouse: fnm default $($Result.Default), carried from ${From}: " +
                $(if ($Carried.Count -gt 0) { $Carried -join " " } else { "no npm globals" }))
        } else {
            Write-Output "roundhouse: fnm default $($Result.Default) is already in Node $Major; nothing switched"
        }
        Write-Output "roundhouse: $AliasBin is first on the user PATH; global bins resolve to the fnm default"
        $NodeOnPath = Get-NodeOnNewSessionPath
        if ($null -ne $NodeOnPath -and -not $NodeOnPath.StartsWith($AliasBin, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Output ("roundhouse: note: the machine PATH comes before the user PATH, so a bare node/npm/npx in a new " +
                "session still resolves to $NodeOnPath until that MSI is removed (elevated; not done here). " +
                "Roundhouse itself always uses the fnm default.")
        }
        Write-Output ("roundhouse: a service an npm global registered before the migration still runs on the MSI's " +
            "Node until that package's own repair runs (its node_switch_hooks)")
    } finally {
        $Lock.Dispose()
    }
}

# --- Node switch self-test: in-memory fnm and npm over a real link tree ------

function Get-NodeSelfTestShim([string]$Prefix, [string]$Bin) {
    if ($script:FnmOnWindows) { return Join-Path $Prefix "$Bin.cmd" }
    return Join-Path (Join-Path $Prefix "bin") $Bin
}

function Set-NodeSelfTestShim([string]$Prefix, [string]$Name, [string]$Bin) {
    # npm's shim for a bin of NAME: a `.cmd` naming the package on Windows,
    # a link into it elsewhere.
    $Shim = Get-NodeSelfTestShim $Prefix $Bin
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Shim))
    Remove-Item -LiteralPath $Shim -Force -ErrorAction SilentlyContinue
    if ($script:FnmOnWindows) {
        Set-Content -LiteralPath $Shim -Value ('"%_prog%"  "%dp0%\node_modules\' + ($Name -replace '/', '\') + '\cli.js" %*')
    } else {
        [void](New-Item -ItemType SymbolicLink -Path $Shim -Target ("../lib/node_modules/" + $Name + "/cli.js"))
    }
}

function Get-NodeSelfTestPrefix([string]$NpmPath, [string]$Prefix) {
    if ($Prefix) { return $Prefix }
    $Dir = Split-Path -Parent $NpmPath
    if ($script:FnmOnWindows) { return $Dir }
    return Split-Path -Parent $Dir
}

function Read-NodeSelfTestGlobals([string]$Prefix) {
    $State = Join-Path $Prefix "globals.json"
    $Ordered = [ordered]@{}
    if (-not (Test-Path -LiteralPath $State)) { return $Ordered }
    $Value = [IO.File]::ReadAllText($State) | ConvertFrom-Json -AsHashtable
    foreach ($Key in @($Value.Keys | Sort-Object)) { $Ordered[$Key] = $Value[$Key] }
    return $Ordered
}

function Set-NodeSelfTestGlobal([string]$Prefix, [string]$Name, [string]$Version) {
    # Install (VERSION) or remove (empty) one global: its state, manifest and shims.
    $Globals = Read-NodeSelfTestGlobals $Prefix
    if ([string]::IsNullOrEmpty($Version)) { $Globals.Remove($Name) } else { $Globals[$Name] = $Version }
    $Globals | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Prefix "globals.json")
    $PackageDir = Join-Path (Get-FnmNpmRoot $Prefix) $Name
    $Bins = if ($script:NodeSelfTestFake.Catalog.ContainsKey($Name)) { @($script:NodeSelfTestFake.Catalog[$Name]) } else { @() }
    foreach ($Bin in $Bins) { Remove-Item -LiteralPath (Get-NodeSelfTestShim $Prefix $Bin) -Force -ErrorAction SilentlyContinue }
    if ([string]::IsNullOrEmpty($Version)) {
        Remove-Item -LiteralPath $PackageDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    [void][IO.Directory]::CreateDirectory($PackageDir)
    $BinMap = [ordered]@{}
    Set-Content -LiteralPath (Join-Path $PackageDir "cli.js") -Value ""
    foreach ($Bin in $Bins) {
        $BinMap[$Bin] = "cli.js"
        Set-NodeSelfTestShim $Prefix $Name $Bin
    }
    @{ name = $Name; version = $Version; bin = $BinMap } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $PackageDir "package.json")
}

function Get-NodeSelfTestDefault {
    $Value = Get-FnmDefaultVersion $script:NodeSelfTestFake.Root
    if ($null -eq $Value) { "none" } else { $Value }
}

function Assert-NodeSelfTestThrows([scriptblock]$Body, [string]$Like, [string]$Label) {
    try { & $Body } catch {
        if ($_.Exception.Message -like $Like) { return }
        throw "Node switch self-test: $Label failed with an unexpected error: $($_.Exception.Message)"
    }
    throw "Node switch self-test: $Label did not fail"
}

$script:NodeSelfTestOps = @{
    Fnm = {
        param([string]$FnmRoot, [string[]]$Arguments)
        $Fake = $script:NodeSelfTestFake
        $Fake.Log.Add("fnm $($Arguments -join ' ')")
        switch ($Arguments[0]) {
            "install" {
                if ($Fake.FailFnmInstall) { return 1 }
                $Installation = Get-FnmInstallation $FnmRoot $Arguments[1]
                if (-not (Test-Path -LiteralPath $Installation)) {
                    $Bin = Get-FnmBinDir $Installation
                    [void][IO.Directory]::CreateDirectory($Bin)
                    Set-Content -LiteralPath (Get-NodeToolPath $Bin "node") -Value ""
                    Set-Content -LiteralPath (Get-NodeToolPath $Bin "npm") -Value ""
                    Set-Content -LiteralPath (Join-Path $Bin "version.txt") -Value $Arguments[1]
                    $NpmDir = Join-Path (Get-FnmNpmRoot $Installation) "npm"
                    [void][IO.Directory]::CreateDirectory($NpmDir)
                    @{ name = "npm"; version = $Fake.BundledNpm } | ConvertTo-Json -Compress |
                        Set-Content -LiteralPath (Join-Path $NpmDir "package.json")
                    @{ npm = $Fake.BundledNpm } | ConvertTo-Json -Compress |
                        Set-Content -LiteralPath (Join-Path $Installation "globals.json")
                }
                return 0
            }
            "default" {
                $Installation = Get-FnmInstallation $FnmRoot $Arguments[1]
                if (-not (Test-Path -LiteralPath $Installation)) { return 1 }
                if ($null -ne $Fake.DefaultOnly -and $Arguments[1] -cne $Fake.DefaultOnly) { return 1 }
                [void][IO.Directory]::CreateDirectory((Join-Path $FnmRoot "aliases"))
                $Link = Get-FnmAliasDir $FnmRoot
                if (Test-Path -LiteralPath $Link) { [IO.Directory]::Delete($Link, $false) }
                [void](New-Item -ItemType $(if ($script:FnmOnWindows) { "Junction" } else { "SymbolicLink" }) -Path $Link -Target $Installation)
                return 0
            }
            "unalias" {
                if ($Fake.FailUnalias) { return 1 }
                $Link = Get-FnmAliasDir $FnmRoot
                if (Test-Path -LiteralPath $Link) { [IO.Directory]::Delete($Link, $false) }
                return 0
            }
        }
        return 64
    }
    FnmLines = { param([string]$FnmRoot, [string[]]$Arguments) return , [string[]]@($script:NodeSelfTestFake.Remote) }
    Npm = {
        param([string]$NpmPath, [string]$Prefix, [string[]]$Arguments)
        $Fake = $script:NodeSelfTestFake
        $Fake.Log.Add("npm $($Arguments -join ' ') default=$(Get-NodeSelfTestDefault)")
        if ($Arguments[0] -ceq "install") {
            if ($Fake.FailInstall) {
                $script:LastOutputTail = [string[]]@("npm error code E404")
                return 1
            }
            foreach ($Spec in @($Arguments | Select-Object -Skip 2)) {
                $At = $Spec.LastIndexOf("@")
                Set-NodeSelfTestGlobal $Prefix $Spec.Substring(0, $At) $Spec.Substring($At + 1)
            }
            return 0
        }
        if ($Arguments[0] -ceq "uninstall") {
            foreach ($Name in @($Arguments | Select-Object -Skip 2)) { Set-NodeSelfTestGlobal $Prefix $Name "" }
            return 0
        }
        return 64
    }
    NpmText = {
        param([string]$NpmPath, [string]$Prefix, [string[]]$Arguments)
        $Fake = $script:NodeSelfTestFake
        $Effective = Get-NodeSelfTestPrefix $NpmPath $Prefix
        if ($Arguments[0] -ceq "prefix") { return $(if ($Fake.ForeignPrefix) { "C:\elsewhere\npm" } else { $Effective }) }
        if ($Arguments[0] -ceq "--version") {
            if ($Fake.NpmVersionFail) { return "" }
            if ($Fake.RunningNpm) { return $Fake.RunningNpm }
            $Own = (Read-NodeSelfTestGlobals $Effective)["npm"]
            return $(if ($Own) { $Own } else { $Fake.BundledNpm })
        }
        $Dependencies = [ordered]@{}
        $Globals = Read-NodeSelfTestGlobals $Effective
        foreach ($Key in $Globals.Keys) { $Dependencies[$Key] = @{ version = $Globals[$Key] } }
        if ($Fake.Linked) { $Dependencies["devtool"] = @{ version = "0.0.1"; resolved = "file:../devtool" } }
        return (@{ dependencies = $Dependencies } | ConvertTo-Json -Compress -Depth 5)
    }
    NpmSelf = {
        param([string]$Prefix, [string]$Version)
        $script:NodeSelfTestFake.Log.Add("npm-self $Version default=$(Get-NodeSelfTestDefault)")
        Set-NodeSelfTestGlobal $Prefix "npm" $Version
        return 0
    }
    NodeVersion = {
        param([string]$BinDir)
        $File = Join-Path $BinDir "version.txt"
        if (-not (Test-Path -LiteralPath $File)) { return $null }
        return ([IO.File]::ReadAllText($File)).Trim()
    }
    Hook = {
        param([string]$Path, [string[]]$Arguments, [string]$BinDir)
        $Fake = $script:NodeSelfTestFake
        $Fake.Log.Add("hook $([IO.Path]::GetFileNameWithoutExtension($Path)) $($Arguments -join ' ') node=$(([IO.File]::ReadAllText((Join-Path $BinDir 'version.txt'))).Trim())")
        if ($Fake.HookExit -ne 0) { $script:LastOutputTail = [string[]]@("svc: service registration failed") }
        return $Fake.HookExit
    }
}

function Reset-NodeSelfTestTree {
    # One installed version, v26.0.0, as the default, with a service package
    # whose bin is a hook, a plain package and npm itself.
    $Fake = $script:NodeSelfTestFake
    Remove-Item -LiteralPath $Fake.Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:NodeSwitchStateDir -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($Key in @("FailInstall", "FailFnmInstall", "FailUnalias", "Linked", "ForeignPrefix", "NpmVersionFail")) { $Fake[$Key] = $false }
    $Fake.RunningNpm = $null
    $Fake.HookExit = 0
    $Fake.DefaultOnly = $null
    $Fake.BundledNpm = "11.0.0"
    [void](& $script:NodeOps.Fnm $Fake.Root @("install", "v26.0.0"))
    [void](& $script:NodeOps.Fnm $Fake.Root @("default", "v26.0.0"))
    foreach ($Pair in @(@("@example/svc", "1.0.0"), @("plain", "2.0.0"), @("npm", "12.1.0"))) {
        Set-NodeSelfTestGlobal (Get-FnmInstallation $Fake.Root "v26.0.0") $Pair[0] $Pair[1]
    }
    $Fake.Log.Clear()
}

function Invoke-NodeSwitchSelfTest([string]$Root) {
    # The switch, the carry rule, the operation checks and the bootstrap's
    # migration, against an fnm tree in ROOT and the in-memory fakes above.
    $Saved = @{ Ops = $script:NodeOps; State = $script:NodeSwitchStateDir; FnmDir = $env:FNM_DIR; Fake = $script:NodeSelfTestFake }
    if ($IsWindows) {
        # The REAL NpmText (the fakes below replace it): a single argument with
        # no prefix must reach npm whole, not as its characters.
        $EchoDir = Join-Path $Root "npm-echo"
        [void](New-Item -ItemType Directory -Force -Path $EchoDir)
        $Echo = Join-Path $EchoDir "npm.cmd"
        Set-Content -LiteralPath $Echo -Value "@echo args=%*" -Encoding ascii
        $Got = [string](& $script:NodeOps.NpmText $Echo $null @("--version"))
        if ($Got.Trim() -cne "args=--version") { throw "NpmText passed a single argument as '$($Got.Trim())', not '--version'" }
        $Got = [string](& $script:NodeOps.NpmText $Echo "C:\p" @("ls"))
        if ($Got.Trim() -cne "args=--prefix C:\p ls") { throw "NpmText with a prefix passed '$($Got.Trim())'" }
    }
    $Fnm = Join-Path $Root "fnm"
    $script:NodeSelfTestFake = @{
        Root = $Fnm
        Log = New-Object System.Collections.Generic.List[string]
        Remote = @("v24.2.0 (Krypton)", "v26.0.0", "v26.10.0", "v27.0.0")
        Catalog = @{ "@example/svc" = @("svc"); "plain" = @("plain") }
    }
    $Fake = $script:NodeSelfTestFake
    $script:NodeOps = $script:NodeSelfTestOps
    $script:NodeSwitchStateDir = Join-Path $Root "state"
    $env:FNM_DIR = $Fnm
    $Carry = @([ordered]@{ name = "@example/svc"; version = "1.0.0" }, [ordered]@{ name = "plain"; version = "2.0.0" })
    $Hooks = @([ordered]@{ package = "npm:@example/svc"; argv = @("svc", "service") })
    try {
        # Success: staged through the target's own npm while the old default
        # is live (npm brought up to the installed one first), then flipped,
        # the hook run under the new node, the record cleared.
        Reset-NodeSelfTestTree
        if ((Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) -ne 0 -or (Get-FnmDefaultVersion $Fnm) -cne "v26.10.0") {
            throw "Node switch self-test: the switch did not complete"
        }
        if ((ConvertTo-CanonicalJson (Read-NodeSelfTestGlobals (Get-FnmInstallation $Fnm "v26.10.0"))) -cne
                '{"@example/svc":"1.0.0","npm":"12.1.0","plain":"2.0.0"}' -or
            $null -ne (Read-NodeSwitchMarker) -or
            @($Fake.Log | Where-Object { $_ -like "npm*install*" -or $_ -like "npm-self*" }).Count -ne 2 -or
            @($Fake.Log | Where-Object { ($_ -like "npm*install*" -or $_ -like "npm-self*") -and $_ -notlike "*default=v26.0.0" }).Count -ne 0 -or
            @($Fake.Log | Where-Object { $_ -ceq "hook svc service node=v26.10.0" }).Count -ne 1 -or
            (ConvertTo-CanonicalJson (Read-NodeSelfTestGlobals (Get-FnmInstallation $Fnm "v26.0.0"))) -cne
                '{"@example/svc":"1.0.0","npm":"12.1.0","plain":"2.0.0"}') {
            throw "Node switch self-test: carry before flip, npm bring-up, hook or old prefix wrong: $($Fake.Log -join ' | ')"
        }
        # Refusals before anything moves: an invented carry, npm keeping its
        # globals outside fnm, a failed fnm install, a failed carry.
        Reset-NodeSelfTestTree
        Assert-NodeSelfTestThrows { [void](Invoke-NodeRuntimeSwitch "v26.10.0" @([ordered]@{ name = "plain"; version = "9.9.9" }) @()) } `
            "*carry is not what is installed*" "an invented carry"
        Set-NodeSelfTestGlobal (Get-FnmInstallation $Fnm "v26.0.0") "late" "1.0.0"
        Assert-NodeSelfTestThrows { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } `
            "*carry is not what is installed*" "a global installed after the inventory"
        Set-NodeSelfTestGlobal (Get-FnmInstallation $Fnm "v26.0.0") "late" ""
        $Fake.ForeignPrefix = $true
        Assert-NodeSelfTestThrows { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } "*outside fnm*" "a foreign npm prefix"
        $Fake.ForeignPrefix = $false
        if (@($Fake.Log | Where-Object { $_ -like "fnm install*" }).Count -ne 0) { throw "Node switch self-test: a refused switch staged" }
        $Fake.FailFnmInstall = $true
        Assert-NodeSelfTestThrows { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } "fnm install v26.10.0 failed; nothing switched*" "a failed fnm install"
        $Fake.FailFnmInstall = $false
        $Fake.FailInstall = $true
        try { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } catch { $CarryFailure = $_ }
        if ($null -eq $CarryFailure -or $CarryFailure.Exception.Message -notlike "carrying*nothing switched*" -or
            (Get-ErrorOutputTail $CarryFailure) -cnotcontains "npm error code E404" -or
            (Get-FnmDefaultVersion $Fnm) -cne "v26.0.0" -or $null -ne (Read-NodeSwitchMarker)) {
            throw "Node switch self-test: a failed carry moved the default, recorded a switch or lost its output"
        }
        # A failed hook restores the old default, verified, clears the record
        # and keeps the hook's own output.
        Reset-NodeSelfTestTree
        $Fake.HookExit = 1
        try { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } catch { $HookFailure = $_ }
        if ($null -eq $HookFailure -or $HookFailure.Exception.Message -notlike "*restored to v26.0.0*" -or
            (Get-ErrorOutputTail $HookFailure) -cnotcontains "svc: service registration failed" -or
            (Get-FnmDefaultVersion $Fnm) -cne "v26.0.0" -or $null -ne (Read-NodeSwitchMarker)) {
            throw "Node switch self-test: a failed hook did not restore the old default with its output"
        }
        # A restore that cannot be verified leaves the switch recorded in
        # flight (with its root); it blocks the next switch and npm until the
        # bootstrap's recovery restores it.
        Reset-NodeSelfTestTree
        $Fake.HookExit = 1
        $Fake.DefaultOnly = "v26.10.0"
        Assert-NodeSelfTestThrows { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } "*stays recorded as in flight*" "an unverified restore"
        $Marker = Read-NodeSwitchMarker
        if ($null -eq $Marker -or $Marker.old -cne "v26.0.0" -or $Marker.target -cne "v26.10.0" -or $Marker.root -cne $Fnm) {
            throw "Node switch self-test: an unverified restore did not stay recorded"
        }
        Assert-NodeSelfTestThrows { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } "*pending recovery*" "a switch over a recorded one"
        Assert-NodeSelfTestThrows { Assert-NoNodeSwitchInflight } "*npm upgrades are refused*" "npm over a recorded switch"
        $Fake.DefaultOnly = $null
        if ((Resolve-NodeSwitchInflight (Join-Path $Root "elsewhere")) -notlike "*v26.0.0*" -or
            (Get-FnmDefaultVersion $Fnm) -cne "v26.0.0" -or $null -ne (Read-NodeSwitchMarker)) {
            throw "Node switch self-test: recovery did not restore the old default in the recorded root"
        }
        # One switch at a time.
        Reset-NodeSelfTestTree
        $Held = Enter-NodeSwitchLock
        try {
            Assert-NodeSelfTestThrows { [void](Invoke-NodeRuntimeSwitch "v26.10.0" $Carry $Hooks) } "*another Node switch*" "a second switch under the lock"
        } finally { $Held.Dispose() }

        # The carry rule over a snapshot record, and the sealed operation.
        $Record = '{"status":"present","data":{"installed_version":"v24.18.0","globals":{"npm":"12.1.0","corepack":"0.34.0","plain":"2.0.0","@example/svc":"1.0.0"},"globals_unpinnable":[],"switch_inflight":null}}' | ConvertFrom-Json
        $Config = '{"node_switch_hooks":{"npm:@example/svc":[["svc","service"]],"npm:absent":[["x"]]}}' | ConvertFrom-Json
        $Expected = Get-NodeSwitchExpected $Record "v26.10.0" $Config
        if ($null -ne $Expected.Held -or (ConvertTo-CanonicalJson @($Expected.Carry)) -cne
            '[{"name":"@example/svc","version":"1.0.0"},{"name":"corepack","version":"0.34.0"},{"name":"plain","version":"2.0.0"}]' -or
            (ConvertTo-CanonicalJson @($Expected.Hooks)) -cne '[{"argv":["svc","service"],"package":"npm:@example/svc"}]') {
            throw "Node switch self-test: carry rule (24 -> 26 carries corepack, hooks in carry order)"
        }
        if ((ConvertTo-CanonicalJson @((Get-NodeSwitchExpected $Record "v24.20.0" $Config).Carry)) -cne
            '[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"}]') {
            throw "Node switch self-test: a target that bundles corepack carried it"
        }
        foreach ($Case in @(
            @{ Name = "unknown"; Edit = { param($R) $R.data.globals_unpinnable = $null }; Like = "*unknown*" },
            @{ Name = "unpinnable"; Edit = { param($R) $R.data.globals_unpinnable = @("plain") }; Like = "*plain cannot be reinstalled*" },
            @{ Name = "inflight"; Edit = { param($R) $R.data.switch_inflight = [pscustomobject]@{ old = "v26.0.0" } }; Like = "*pending recovery*" }
        )) {
            $Copy = $Record | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            & $Case.Edit $Copy
            if ((Get-NodeSwitchExpected $Copy "v26.10.0" $Config).Held -notlike $Case.Like) {
                throw "Node switch self-test: carry rule did not hold on $($Case.Name)"
            }
        }
        $Operation = ('{"type":"package-upgrade","kind":"package","id":"fnm:node","candidate_version":"v26.10.0",' +
            '"argv":["fnm","default","v26.10.0"],"carry":' + (ConvertTo-CanonicalJson @($Expected.Carry)) +
            ',"hooks":[{"package":"npm:@example/svc","argv":["svc","service"]}],"required":[{"package":"npm:@example/svc","argv":["svc","service"]}]}') |
            ConvertFrom-Json
        Assert-NodeSwitchOperationShape $Operation
        Assert-NodeSwitchMatchesSnapshot $Operation $Record $Config
        if ((ConvertTo-CanonicalJson @(Get-ExactArgv $Operation $Config $null)) -cne '["fnm","default","v26.10.0"]') {
            throw "Node switch self-test: the exact argv is not the fixed marker"
        }
        foreach ($Bad in @(
            @{ Name = "argv"; Edit = { param($O) $O.argv = @("fnm", "install", "v26.10.0") } },
            @{ Name = "version"; Edit = { param($O) $O.candidate_version = "26.10.0" } },
            @{ Name = "duplicate"; Edit = { param($O) $O.carry = @($O.carry) + @($O.carry[0]) } },
            @{ Name = "carry-extra"; Edit = { param($O) $O.carry[0] | Add-Member -NotePropertyName source -NotePropertyValue "x" } },
            @{ Name = "hook-argv"; Edit = { param($O) $O.hooks[0].argv = @("svc", "a b") } },
            @{ Name = "required"; Edit = { param($O) $O.required = "none" } }
        )) {
            $Copy = $Operation | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            & $Bad.Edit $Copy
            Assert-NodeSelfTestThrows { Assert-NodeSwitchOperationShape $Copy } "Invalid Node*" "the operation shape check ($($Bad.Name))"
        }
        foreach ($Bad in @(
            @{ Name = "padded"; Edit = { param($O) $O.carry = @($O.carry) + @([pscustomobject]@{ name = "extra"; version = "1.0.0" }) } },
            @{ Name = "partial"; Edit = { param($O) $O.carry = @($O.carry | Select-Object -First 1) } },
            @{ Name = "no-hooks"; Edit = { param($O) $O.hooks = @() } },
            @{ Name = "required-undeclared"; Edit = { param($O) $O.required = @([pscustomobject]@{ package = "npm:plain"; argv = @("plain") }) } }
        )) {
            $Copy = $Operation | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            & $Bad.Edit $Copy
            Assert-NodeSelfTestThrows { Assert-NodeSwitchMatchesSnapshot $Copy $Record $Config } "*" "the snapshot check ($($Bad.Name))"
        }
        Assert-NodeSelfTestThrows { Assert-NodeSwitchMatchesSnapshot $Operation $Record ('{"node_switch_hooks":{}}' | ConvertFrom-Json) } `
            "*differ from the configured*" "hooks absent from the worker configuration"
        $After = '{"status":"present","data":{"installed_version":"v26.10.0","globals":{"npm":"12.1.0","corepack":"0.34.0","plain":"2.0.0","@example/svc":"1.0.1"},"globals_unpinnable":[],"switch_inflight":null}}' | ConvertFrom-Json
        $LaterNpm = [pscustomobject]@{ type = "package-upgrade"; id = "npm:@example/svc"; candidate_version = "1.0.1" }
        Assert-NodeSwitchPostcondition $Operation $After @($Operation, $LaterNpm)
        Assert-NodeSelfTestThrows { Assert-NodeSwitchPostcondition $Operation $After @($Operation) } "*carried version*" "a post-state at the wrong version"
        $After.data.globals | Add-Member -NotePropertyName leftover -NotePropertyValue "1.0.0"
        Assert-NodeSelfTestThrows { Assert-NodeSwitchPostcondition $Operation $After @($Operation, $LaterNpm) } "*exactly the carry*" "a post-state with a leftover global"

        # The bootstrap's migration: from the MSI's npm (no fnm default yet),
        # carrying every global into the first default; a rerun changes nothing.
        Remove-Item -LiteralPath $Fnm -Recurse -Force -ErrorAction SilentlyContinue
        $Fake.Log.Clear()
        $MsiPrefix = Join-Path $Root "msi"
        $MsiNpm = Get-NodeToolPath (Get-FnmBinDir $MsiPrefix) "npm"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $MsiNpm))
        Set-Content -LiteralPath $MsiNpm -Value ""
        Set-Content -LiteralPath (Get-NodeToolPath (Split-Path -Parent $MsiNpm) "node") -Value ""
        foreach ($Pair in @(@("@bitkyc08/opencodex", "2.75.0"), @("npm", "12.1.0"), @("typescript", "7.0.2"))) {
            Set-NodeSelfTestGlobal $MsiPrefix $Pair[0] $Pair[1]
        }
        $Fake.Linked = $true
        Assert-NodeSelfTestThrows { [void](Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm) } `
            "*devtool cannot be reinstalled*" "a bootstrap carrying a linked global"
        if ($null -ne (Get-FnmDefaultVersion $Fnm)) { throw "Node switch self-test: a refused bootstrap made a default" }
        $Fake.Linked = $false
        $Migrated = Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm
        if (-not $Migrated.Switched -or $Migrated.Default -cne "v26.10.0" -or (Get-FnmDefaultVersion $Fnm) -cne "v26.10.0" -or
            (ConvertTo-CanonicalJson (Read-NodeSelfTestGlobals (Get-FnmInstallation $Fnm "v26.10.0"))) -cne
                '{"@bitkyc08/opencodex":"2.75.0","npm":"12.1.0","typescript":"7.0.2"}' -or
            (ConvertTo-CanonicalJson (Read-NodeSelfTestGlobals $MsiPrefix)) -cne
                '{"@bitkyc08/opencodex":"2.75.0","npm":"12.1.0","typescript":"7.0.2"}' -or
            $null -ne (Read-NodeSwitchMarker)) {
            throw "Node switch self-test: the bootstrap did not carry the MSI globals into the first fnm default"
        }
        if (@($Fake.Log | Where-Object { $_ -like "npm-self 12.1.0 *" }).Count -ne 1) {
            throw "Node switch self-test: the bootstrap did not bring npm up to the MSI's"
        }
        $Fake.Log.Clear()
        $Again = Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm
        if ($Again.Switched -or $Fake.Log.Count -ne 0) { throw "Node switch self-test: a bootstrap rerun was not idempotent" }
        # A rerun never accepts an in-major default it cannot verify.
        $Fake.ForeignPrefix = $true
        Assert-NodeSelfTestThrows { [void](Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm) } `
            "*is not self-consistent*" "a bootstrap rerun over an unverified default"
        $Fake.ForeignPrefix = $false
        # An alias that names no installed version is never read as "no
        # default": the bootstrap refuses rather than replace or unalias it.
        [IO.Directory]::Delete((Get-FnmAliasDir $Fnm), $false)
        [void](New-Item -ItemType $(if ($script:FnmOnWindows) { "Junction" } else { "SymbolicLink" }) `
            -Path (Get-FnmAliasDir $Fnm) -Target $MsiPrefix)
        Assert-NodeSelfTestThrows { [void](Invoke-NodeFnmMigration -Root $Fnm -Major 27 -SourceNpm $MsiNpm) } `
            "*does not name an installed version*" "a bootstrap over an unreadable default"
        [IO.Directory]::Delete((Get-FnmAliasDir $Fnm), $false)
        # The MSI's own npm (12, under Program Files, so not in the
        # %APPDATA%\npm listing) is measured by running it: the target's
        # bundled npm 11 is brought up to 12 before any global is installed,
        # and an npm whose version cannot be read refuses.
        Remove-Item -LiteralPath $Fnm -Recurse -Force -ErrorAction SilentlyContinue
        Set-NodeSelfTestGlobal $MsiPrefix "npm" ""
        $Fake.Log.Clear()
        $Fake.NpmVersionFail = $true
        Assert-NodeSelfTestThrows { [void](Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm) } `
            "*cannot establish the version*" "a bootstrap whose npm version is unknown"
        if ($null -ne (Get-FnmDefaultVersion $Fnm) -or @($Fake.Log | Where-Object { $_ -like "npm*" }).Count -ne 0) {
            throw "Node switch self-test: a bootstrap with an unknown npm version staged"
        }
        $Fake.NpmVersionFail = $false
        $Fake.RunningNpm = "12.1.0"
        [void](Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm)
        $Staging = @($Fake.Log | Where-Object { $_ -like "npm*" })
        if ($Staging.Count -lt 2 -or $Staging[0] -notlike "npm-self 12.1.0 *" -or
            @($Staging | Select-Object -Skip 1 | Where-Object { $_ -like "npm-self*" }).Count -ne 0 -or
            (Read-NodeSelfTestGlobals (Get-FnmInstallation $Fnm "v26.10.0"))["npm"] -cne "12.1.0") {
            throw "Node switch self-test: the MSI's npm 12 was not brought up before the globals: $($Staging -join ' | ')"
        }
        $Fake.RunningNpm = $null
        Set-NodeSelfTestGlobal $MsiPrefix "npm" "12.1.0"
        # A first default that cannot be verified is removed again: the MSI
        # stays the runtime and nothing claims otherwise.
        Remove-Item -LiteralPath $Fnm -Recurse -Force -ErrorAction SilentlyContinue
        $Fake.DefaultOnly = "v0.0.0"
        Assert-NodeSelfTestThrows { [void](Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm) } `
            "fnm default v26.10.0 failed; the fnm default was removed*" "a failed first default"
        if ($null -ne (Get-FnmDefaultVersion $Fnm) -or $null -ne (Read-NodeSwitchMarker)) {
            throw "Node switch self-test: a failed first default was left behind"
        }
        # A first default that sets but does not verify is removed even when
        # `fnm unalias` itself fails: a rerun must not accept it.
        $Fake.DefaultOnly = $null
        $Fake.ForeignPrefix = $true
        $Fake.FailUnalias = $true
        Assert-NodeSelfTestThrows { [void](Invoke-NodeFnmMigration -Root $Fnm -Major 26 -SourceNpm $MsiNpm) } `
            "*does not run under v26.10.0*the fnm default was removed*" "an unverified first default"
        if ($null -ne (Get-Item -LiteralPath (Get-FnmAliasDir $Fnm) -Force -ErrorAction SilentlyContinue)) {
            throw "Node switch self-test: an unverified first default survived a failed unalias"
        }
        $Fake.ForeignPrefix = $false
        $Fake.FailUnalias = $false

        if ((Get-PathWithFirstEntry 'C:\a;C:\fnm\aliases\default\;C:\b;;C:\FNM\aliases\default' 'C:\fnm\aliases\default') -cne
            'C:\fnm\aliases\default;C:\a;C:\b') {
            throw "Node switch self-test: the user PATH entry was not moved first exactly once"
        }
        $Archive = Join-Path $Root "fnm-windows.zip"
        Set-Content -LiteralPath $Archive -Value "not the release"
        Assert-NodeSelfTestThrows { Assert-FnmArchive $Archive $script:FnmPinnedWindowsZipSha256 } "*pinned SHA-256*" "an archive that is not the pinned release"
        Assert-FnmArchive $Archive (Get-FileSha256 $Archive)
    } finally {
        $script:NodeOps = $Saved.Ops
        $script:NodeSwitchStateDir = $Saved.State
        $script:NodeSelfTestFake = $Saved.Fake
        $env:FNM_DIR = $Saved.FnmDir
    }
}

if ($SelfTest) {
    $SelfTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-selftest-" + [Guid]::NewGuid().ToString("N"))
    try {
        [void][IO.Directory]::CreateDirectory($SelfTestRoot)
        $Canonical = ConvertTo-CanonicalJson ([ordered]@{ b = 2; a = 1 })
        if ($Canonical -ne '{"a":1,"b":2}') { throw "Canonical JSON ordering self-test failed" }
        foreach ($Control in @([char]0x00, [char]0x1b, [char]0x81)) {
            if (Test-BoundedStrings "safe$Control") {
                throw "Control-string self-test failed"
            }
        }
        if (-not (Test-BoundedStrings ([DateTime]::UtcNow))) {
            throw "JSON scalar self-test failed"
        }
        $ProtectedInjection = [pscustomobject]@{
            schema = "roundhouse.plan"
            schema_version = 2
            operations = @([pscustomobject]@{
                type = "package-upgrade"; kind = "package"; id = "fixture"
                argv = @("winget", "upgrade"); policy_token = "forbidden"
            })
        }
        if (-not (Test-ContainsProtectedPlanField $ProtectedInjection) -or
            (Test-ExactProperties $ProtectedInjection.operations[0] @(
                "argv", "candidate_version", "id", "kind", "type"
            ))) {
            throw "Protected schema-2 injection self-test failed"
        }
        $CanonicalTimestamp = ConvertTo-CanonicalJson ([DateTime]::Parse(
            "2026-01-02T03:04:05Z",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        ))
        if ($CanonicalTimestamp -ne '"2026-01-02T03:04:05Z"') {
            throw "Canonical timestamp self-test failed"
        }

        $Operation = [pscustomobject]@{
            type = "package-upgrade"
            id = "winget:Example.Package"
            candidate_version = "2.0.0"
        }
        $Argv = @(Get-ExactArgv $Operation $null $null)
        $Expected = @("winget", "upgrade", "--id", "Example.Package", "--exact",
            "--version", "2.0.0", "--accept-package-agreements",
            "--accept-source-agreements", "--disable-interactivity")
        if ((ConvertTo-CanonicalJson $Argv) -ne (ConvertTo-CanonicalJson $Expected)) {
            throw "Winget argv self-test failed"
        }
        $NpmOperation = [pscustomobject]@{
            type = "package-upgrade"; kind = "package"; id = "npm:@example/tool"
            candidate_version = "2.0.0"; argv = @("npm", "install", "--global", "@example/tool@2.0.0")
        }
        $NpmPathBefore = $env:PATH
        $NpmSeenPath = Invoke-WithNpmOnPath (Join-Path (Join-Path ([IO.Path]::GetTempPath()) "rh-npm-dir") "npm.cmd") { $env:PATH }
        if (-not $NpmSeenPath.StartsWith((Join-Path ([IO.Path]::GetTempPath()) "rh-npm-dir") + [IO.Path]::PathSeparator) -or
            $env:PATH -ne $NpmPathBefore) {
            throw "npm PATH binding self-test failed"
        }
        try { Invoke-WithNpmOnPath "C:\npm\npm.cmd" { throw "inner" } | Out-Null } catch { }
        if ($env:PATH -ne $NpmPathBefore) { throw "npm PATH binding did not restore PATH after a failure" }
        $NpmArgv = @(Get-ExactArgv $NpmOperation $null $null)
        if ((ConvertTo-CanonicalJson $NpmArgv) -ne '["npm","install","--global","@example/tool@2.0.0"]' -or
            (Test-NpmUpdaterOperation $NpmOperation)) {
            throw "npm install argv self-test failed"
        }
        $NpmUpdaterOperation = [pscustomobject]@{
            type = "package-upgrade"; kind = "package"; id = "npm:@example/tool"
            candidate_version = "2.0.0"; argv = @("tool", "update")
        }
        $NpmUpdaterConfig = [pscustomobject]@{
            package_updaters = [pscustomobject]@{ "npm:@example/tool" = @("tool", "update") }
        }
        if ((ConvertTo-CanonicalJson @(Get-ExactArgv $NpmUpdaterOperation $NpmUpdaterConfig $null)) -ne
            '["tool","update"]' -or -not (Test-NpmUpdaterOperation $NpmUpdaterOperation)) {
            throw "npm configured updater argv self-test failed"
        }
        if ((ConvertTo-CanonicalJson @(Get-ExactArgv $NpmUpdaterOperation $null $null)) -eq '["tool","update"]') {
            throw "npm unconfigured updater argv self-test failed"
        }
        $OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
        $FakeNpm = Join-Path $SelfTestRoot $(if ($OnWindows) { "fake-npm.cmd" } else { "fake-npm" })
        if ($OnWindows) {
            Set-Content -LiteralPath $FakeNpm -Value "@echo 2.0.0" -Encoding ascii
        } else {
            Set-Content -LiteralPath $FakeNpm -Value "#!/bin/sh`nprintf '2.0.0\n'" -Encoding ascii
            & chmod 755 $FakeNpm
        }
        Assert-NpmRegistryCandidate $FakeNpm "@example/tool" "2.0.0"
        $MovedRejected = $false
        try { Assert-NpmRegistryCandidate $FakeNpm "@example/tool" "1.9.0" } catch { $MovedRejected = $true }
        if (-not $MovedRejected) { throw "npm updater registry-candidate self-test failed" }
        $RuntimeArgv = @(Get-ExactArgv ([pscustomobject]@{
            type = "agent-update"; kind = "agent_runtime"; id = "codex"
        }) $null $null)
        if ((ConvertTo-CanonicalJson $RuntimeArgv) -ne '["codex","update"]') {
            throw "Agent runtime argv self-test failed"
        }
        $ApprovalRejected = $false
        try { [void](Invoke-CodexPluginHooks "invalid" "example@test-market") } catch {
            $ApprovalRejected = $true
        }
        if (-not $ApprovalRejected) { throw "Codex hook approval action self-test failed" }
        $FailureHelper = Join-Path $SelfTestRoot "codex-plugin-hooks-failure.ps1"
        [IO.File]::WriteAllText($FailureHelper, (@(
            'param([string]$Action, [string]$PluginId)'
            '[Console]::Error.WriteLine("Roundhouse hook approval needs Node.js. PATH node: fixture; CODEX-BUNDLED node: fixture; Claude-bundled node: fixture; Recovery: WSL interop")'
            'exit 69'
        ) -join [Environment]::NewLine), $OutputEncoding)
        $FailurePropagated = $false
        try {
            [void](Invoke-CodexPluginHooks "approve" "example@test-market" $FailureHelper)
        } catch {
            $FailurePropagated = $null -ne $_.Exception.Data -and
                $_.Exception.Data.Contains("ExitCode") -and
                [int]$_.Exception.Data["ExitCode"] -eq 69 -and
                $_.Exception.Message.Contains("PATH node:")
        }
        if (-not $FailurePropagated) { throw "Codex hook resolver failure did not preserve exit 69 diagnostics" }
        # Failure diagnostics: a bounded, sanitized tail of the failing
        # command's own output reaches the failure message and the result.
        $Esc = [char]0x1b
        $KnownError = "Register-ScheduledTask : Access is denied."
        $SecretLine = "token ghp_abcdefghijklmnopqrstuvwxyz0123"
        $Styled = @(ConvertTo-SafeOutputLines "$Esc[31m$KnownError$Esc[0m")
        if ($Styled.Count -ne 1 -or $Styled[0] -cne $KnownError) { throw "ANSI output-tail self-test failed" }
        $Redrawn = @(ConvertTo-SafeOutputLines "progress 10%`rprogress 100%`rdone")
        if ($Redrawn.Count -ne 1 -or $Redrawn[0] -cne "done") { throw "Carriage-return output-tail self-test failed" }
        foreach ($Noise in @("  - ", " \ ", "  $([char]0x2588)$([char]0x2588)$([char]0x2592)  1.2 MB / 3.4 MB",
                "$([char]0x2588)$([char]0x2588) 45%", "#< CLIXML", "   ")) {
            if (@(ConvertTo-SafeOutputLines $Noise).Count -ne 0) { throw "Progress-noise output-tail self-test failed: $Noise" }
        }
        $Clixml = '<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">' +
            '<Obj S="progress" RefId="0"><TN RefId="0"><T>System.Management.Automation.PSCustomObject</T></TN>' +
            '<MS><I64 N="SourceId">1</I64><PR N="Record"><AV>Preparing modules for first use.</AV></PR></MS></Obj>' +
            '<S S="Error">Register-ScheduledTask : Access is denied._x000D__x000A_</S>' +
            '<S S="Error">    + CategoryInfo : PermissionDenied: (&lt;task&gt;) [Register-ScheduledTask]_x000D__x000A_</S></Objs>'
        $Decoded = @(ConvertTo-SafeOutputLines $Clixml)
        if ($Decoded.Count -ne 2 -or $Decoded[0] -cne $KnownError -or
            $Decoded[1] -cne "    + CategoryInfo : PermissionDenied: (<task>) [Register-ScheduledTask]" -or
            ($Decoded -join "`n").Contains("Preparing modules")) {
            throw "CLIXML output-tail self-test failed: $($Decoded -join ' | ')"
        }
        foreach ($Secret in @($SecretLine, "key -----BEGIN OPENSSH PRIVATE KEY-----",
                "export KEY=sk-abcdefghijklmnop0123", "GITHUB_TOKEN=abcd1234efgh", "password: hunter2hunter2",
                "Authorization: Bearer abcdefgh.ijklmnop", "AKIAABCDEFGHIJKLMNOP leaked",
                "value 3f9a1c0b7e6d5a4f3e2d1c0b9a8f7e6d5c4b3a29")) {
            $Redacted = @(ConvertTo-SafeOutputLines $Secret)
            if ($Redacted.Count -ne 1 -or $Redacted[0] -cne $OutputTailRedacted) {
                throw "Secret-class output-tail self-test failed: $Secret"
            }
        }
        foreach ($Ordinary in @(
                "chezmoi: .chezmoiscripts/run_onchange_after_10_register_scheduled_task.ps1: exit status 1",
                " M .config/powershell/Microsoft.PowerShell_profile.ps1",
                "Basic authentication failed for the package source", $KnownError)) {
            $Kept = @(ConvertTo-SafeOutputLines $Ordinary)
            if ($Kept.Count -ne 1 -or $Kept[0] -cne $Ordinary) { throw "Ordinary output-tail self-test failed: $Ordinary" }
        }
        foreach ($Url in @("https://git.example.com/owner/repo.git", "ssh://git@github.com/owner/repo.git")) {
            if (@(ConvertTo-SafeOutputLines $Url)[0] -cne $Url) { throw "Ordinary URL output-tail self-test failed: $Url" }
        }
        foreach ($Url in @("fatal: unable to access 'https://claire:Sup3rS3cretPass@git.example.com/owner/repo.git/'",
                "remote: https://oauth2:abc123DEF456@gitlab.example.com/group/project.git")) {
            if (@(ConvertTo-SafeOutputLines $Url)[0] -cne $OutputTailRedacted) {
                throw "Credential URL output-tail self-test failed: $Url"
            }
        }
        # PEM blocks are redacted from BEGIN through END, then output resumes;
        # an unterminated block is redacted to the end of the tail, even after
        # its BEGIN line has scrolled out.
        $Pem = @(Get-OutputTail @("before the key", "-----BEGIN OPENSSH PRIVATE KEY-----",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ", "short body words", "-----END OPENSSH PRIVATE KEY-----",
            $KnownError))
        if (($Pem -join "`n") -cne (@("before the key", $OutputTailRedacted, $OutputTailRedacted,
                $OutputTailRedacted, $OutputTailRedacted, $KnownError) -join "`n")) {
            throw "PEM block output-tail self-test failed: $($Pem -join ' | ')"
        }
        $Unterminated = @(Get-OutputTail (@("-----BEGIN RSA PRIVATE KEY-----") + @(1..24 | ForEach-Object { "body line $_" })))
        if ($Unterminated.Count -ne $OutputTailLines -or
            @($Unterminated | Where-Object { $_ -cne $OutputTailRedacted }).Count -ne 0) {
            throw "Unterminated PEM output-tail self-test failed"
        }
        # A secret wrapped across two lines redacts both halves, and one
        # secret line never hides the ordinary error beside it.
        $Wrapped = @(Get-OutputTail @("export GITHUB_TOKEN_VALUE ghp_abcd", "efghijklmnop0123", $KnownError))
        if (($Wrapped -join "`n") -cne (@($OutputTailRedacted, $OutputTailRedacted, $KnownError) -join "`n")) {
            throw "Wrapped-token output-tail self-test failed: $($Wrapped -join ' | ')"
        }
        $SplitAssignment = @(Get-OutputTail @("password:", "hunter2hunter2"))
        if (@($SplitAssignment | Where-Object { $_ -cne $OutputTailRedacted }).Count -ne 0) {
            throw "Split-assignment output-tail self-test failed"
        }
        $Continued = @(Get-OutputTail @($SecretLine, "ABCDEFGH4567", $KnownError))
        if (($Continued -join "`n") -cne (@($OutputTailRedacted, $OutputTailRedacted, $KnownError) -join "`n")) {
            throw "Token-continuation output-tail self-test failed: $($Continued -join ' | ')"
        }
        $Huge = @(ConvertTo-SafeOutputLines ("z" + (" q" * 150000)))
        if ($Huge.Count -ne 1 -or $Huge[0].Length -ne $OutputTailLineLength) {
            throw "Raw line cap output-tail self-test failed"
        }
        # The relayed stderr line and every safe failure message are checked
        # whole, whether or not they were built from a tail.
        $SecretMessage = "Native command failed: git; remote https://claire:Sup3rS3cretPass@git.example.com/repo.git"
        if ((Get-FailureLine "execute" $SecretMessage) -cne
                "roundhouse: Windows apply failed at execute: $FailureMessageRedacted" -or
            (Get-FailureLine "verify" "Native command failed: winget (exit 1)") -cne
                "roundhouse: Windows apply failed at verify: Native command failed: winget (exit 1)" -or
            (Get-FailureLine "post-inventory" "") -cne "roundhouse: Windows apply failed at post-inventory" -or
            (Get-SafeFailureMessage ([InvalidOperationException]::new("helper said token=abcd1234efgh"))) -cne
                "Windows operation failed: $FailureMessageRedacted") {
            throw "Final failure-message redaction self-test failed"
        }
        $Long = @(ConvertTo-SafeOutputLines ("x " * 600))
        if ($Long.Count -ne 1 -or $Long[0].Length -ne $OutputTailLineLength -or -not $Long[0].EndsWith("...")) {
            throw "Output-tail line bound self-test failed"
        }
        $Bounded = @(Get-OutputTail @(1..50 | ForEach-Object { "line $_" }))
        if ($Bounded.Count -ne $OutputTailLines -or $Bounded[0] -cne "line 31" -or $Bounded[-1] -cne "line 50") {
            throw "Output-tail line count self-test failed"
        }
        $Wide = @(1..20 | ForEach-Object { "wide $_ " + ("y " * 115) })
        $WideDetail = Join-FailureDetail "Native command failed: fixture (exit 1)" (Get-OutputTail $Wide)
        if ($WideDetail.Length -gt $OutputTailMessageLength -or
            -not $WideDetail.StartsWith("Native command failed: fixture (exit 1); output tail: ... | ") -or
            -not $WideDetail.Contains("wide 20 ")) {
            throw "Failure-detail bound self-test failed"
        }
        $Merged = @(Join-OutputTail ([string[]]@(1..15 | ForEach-Object { "apply $_" })) ([string[]]@(1..15 | ForEach-Object { "status $_" })))
        if ($Merged.Count -ne $OutputTailLines -or $Merged[0] -cne "apply 6" -or $Merged[9] -cne "apply 15" -or
            $Merged[10] -cne "status 6" -or $Merged[-1] -cne "status 15") {
            throw "Output-tail merge self-test failed"
        }

        $FakeBin = Join-Path $SelfTestRoot "fake-bin"
        [void][IO.Directory]::CreateDirectory($FakeBin)
        $IsWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
        function New-SelfTestCommand([string]$Name, [string[]]$Stdout, [string[]]$Stderr, [int]$ExitCode) {
            if ($IsWindowsHost) {
                $Path = Join-Path $FakeBin "$Name.cmd"
                $Body = @("@echo off") + @($Stdout | ForEach-Object { "echo $_" }) +
                    @($Stderr | ForEach-Object { "echo $_ 1>&2" }) + @("exit /b $ExitCode")
                [IO.File]::WriteAllText($Path, (($Body -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
            } else {
                $Path = Join-Path $FakeBin $Name
                $Body = @("#!/bin/sh") + @($Stdout | ForEach-Object { "printf '%s\n' '$_'" }) +
                    @($Stderr | ForEach-Object { "printf '%s\n' '$_' >&2" }) + @("exit $ExitCode")
                [IO.File]::WriteAllText($Path, (($Body -join "`n") + "`n"), [Text.Encoding]::ASCII)
                & chmod 755 $Path
            }
            return $Path
        }
        [void](New-SelfTestCommand "fixture-fail" @("Applying fixture") @($SecretLine, $KnownError) 7)
        $FailureTail = $null
        # By name, as a sealed argv names it: a temporary path's random
        # directory would itself trip the entropy floor.
        $SavedPath = $env:PATH
        try {
            $env:PATH = $FakeBin + [IO.Path]::PathSeparator + $SavedPath
            [void](Invoke-Exact @("fixture-fail", "--fixture"))
        } catch {
            $FailureTail = Get-ErrorOutputTail $_
            $FailureExit = $_.Exception.Data["ExitCode"]
            $FailureDetail = Join-FailureDetail (Get-SafeFailureMessage $_) $FailureTail
        } finally {
            $env:PATH = $SavedPath
        }
        # stdout and stderr interleave in arrival order; each keeps its own.
        if ($null -eq $FailureTail -or $FailureExit -ne 7 -or
            @($FailureTail | Where-Object { $_ -ceq $KnownError }).Count -ne 1 -or
            @($FailureTail | Where-Object { $_ -ceq $OutputTailRedacted }).Count -ne 1 -or
            -not $FailureDetail.Contains($KnownError) -or
            -not $FailureDetail.StartsWith("Native command failed: fixture-fail (exit 7); output tail: ") -or
            ($FailureDetail + ($FailureTail -join "`n")).Contains("ghp_") -or
            @($FailureTail | Where-Object { $_ -ceq "Applying fixture" }).Count -ne 1) {
            throw "Native failure output-tail self-test failed: $FailureDetail"
        }
        $SucceedingCommand = New-SelfTestCommand "fixture-ok" @("applied fixture") @() 0
        if ((Invoke-Exact @($SucceedingCommand)) -ne 0 -or @($script:LastOutputTail)[-1] -cne "applied fixture") {
            throw "Native success output-tail self-test failed"
        }

        [void](New-SelfTestCommand "chezmoi" @(" M .zshrc") @($SecretLine) 0)
        $SavedPath = $env:PATH
        try {
            $env:PATH = $FakeBin + [IO.Path]::PathSeparator + $SavedPath
            $DriftOperation = [pscustomobject]@{ type = "chezmoi-apply"; kind = "chezmoi_state"; id = "live" }
            $DriftAfter = @([pscustomobject]@{
                kind = "chezmoi_state"; id = "live"; status = "present"; data = [pscustomobject]@{ drift_count = 1 }
            })
            $DriftTail = $null
            try {
                Assert-Postcondition $DriftOperation $DriftAfter $DriftAfter
            } catch {
                $DriftMessage = Get-SafeFailureMessage $_
                $DriftTail = Join-OutputTail ([string[]]@("chezmoi: warning: fixture hook skipped")) (Get-ErrorOutputTail $_)
            }
        } finally {
            $env:PATH = $SavedPath
        }
        $DriftDetail = Join-FailureDetail $DriftMessage $DriftTail
        if ($DriftMessage -cne "Chezmoi still reports drift after apply" -or
            @($DriftTail)[0] -cne "chezmoi: warning: fixture hook skipped" -or
            @($DriftTail | Where-Object { $_ -ceq " M .zshrc" }).Count -ne 1 -or
            $DriftDetail.Contains("ghp_") -or -not $DriftDetail.Contains(" M .zshrc")) {
            throw "Chezmoi drift output-tail self-test failed: $DriftDetail"
        }
        $ChezmoiPullArgv = @(Get-ExactArgv ([pscustomobject]@{
            type = "chezmoi-pull"; kind = "file"; id = "chezmoi:source"
        }) $null $null)
        if ((ConvertTo-CanonicalJson $ChezmoiPullArgv) -ne
            '["chezmoi","git","--","pull","--ff-only"]') {
            throw "Chezmoi pull argv self-test failed"
        }
        $TargetedChezmoiArgv = @(Get-ExactArgv ([pscustomobject]@{
            type = "chezmoi-apply"; kind = "chezmoi_state"; id = "live"
            targets = @("C:\Users\Operator\.profile.d\10-env.sh", "C:\Users\Operator\.zprofile.d\10-env.zsh")
        }) $null $null)
        if ((ConvertTo-CanonicalJson $TargetedChezmoiArgv) -ne
            '["chezmoi","--no-tty","apply","--","C:\\Users\\Operator\\.profile.d\\10-env.sh","C:\\Users\\Operator\\.zprofile.d\\10-env.zsh"]') {
            throw "Targeted chezmoi argv self-test failed"
        }
        $Rejected = $false
        try {
            [void](Get-ChezmoiTargets ([pscustomobject]@{
                targets = @("C:relative\\example")
            }))
        } catch {
            $Rejected = $true
        }
        if (-not $Rejected) { throw "Drive-relative chezmoi target self-test failed" }
        foreach ($UnsafeId in @("skills-cli:--help", "jsm:-x")) {
            $Rejected = $false
            try {
                [void](Get-ExactArgv ([pscustomobject]@{
                    type = "agent-update"; id = $UnsafeId
                }) $null $null)
            } catch {
                $Rejected = $true
            }
            if (-not $Rejected) { throw "Option-shaped manager name self-test failed: $UnsafeId" }
        }

        $Rejected = $false
        try {
            Assert-ExecutorFiles ([pscustomobject]@{
                files = @([pscustomobject]@{
                    path = "../escape"
                    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
                })
            })
        } catch {
            $Rejected = $true
        }
        if (-not $Rejected) { throw "Executor path traversal self-test failed" }

        $CloneRoot = Join-Path $SelfTestRoot "dev"
        $CloneConfig = [pscustomobject]@{
            projects = [pscustomobject]@{
                example = [pscustomobject]@{
                    path = "nested/team/example"
                    source = "owner/example"
                }
            }
        }
        $CloneMachine = [pscustomobject]@{ dev_root = $CloneRoot }
        $CloneOperation = [pscustomobject]@{ type = "project-clone"; id = "example" }
        Prepare-ProjectMutationPath $CloneOperation $CloneConfig $CloneMachine
        if (-not (Test-Path -LiteralPath (Join-Path $CloneRoot "nested/team") -PathType Container)) {
            throw "Nested project parent self-test failed"
        }

        $UpdateRoot = Join-Path $SelfTestRoot "update-dev"
        $UpdateTarget = Join-Path $SelfTestRoot "update-target"
        [void][IO.Directory]::CreateDirectory($UpdateRoot)
        [void][IO.Directory]::CreateDirectory($UpdateTarget)
        $UpdatePath = Join-Path $UpdateRoot "example"
        [void](New-Item -ItemType $(if ($IsWindows) { "Junction" } else { "SymbolicLink" }) `
            -Path $UpdatePath -Target $UpdateTarget)
        $UpdateConfig = [pscustomobject]@{
            projects = [pscustomobject]@{
                example = [pscustomobject]@{
                    path = "example"
                    source = "owner/example"
                }
            }
        }
        $UpdateOperation = [pscustomobject]@{ type = "project-update"; id = "example" }
        $Rejected = $false
        try {
            Prepare-ProjectMutationPath $UpdateOperation $UpdateConfig `
                ([pscustomobject]@{ dev_root = $UpdateRoot })
        } catch {
            $Rejected = $true
        }
        if (-not $Rejected) { throw "Project update reparse-point self-test failed" }

        $ExecutorRoot = Join-Path $SelfTestRoot "executor"
        [void][IO.Directory]::CreateDirectory((Join-Path $ExecutorRoot "scripts"))
        [IO.File]::WriteAllText((Join-Path $ExecutorRoot "scripts/apply-windows.ps1"), "apply", $OutputEncoding)
        [IO.File]::WriteAllText((Join-Path $ExecutorRoot "scripts/collect-windows.ps1"), "collect", $OutputEncoding)
        $FixtureFiles = @(
            [ordered]@{
                path = "scripts/apply-windows.ps1"
                sha256 = Get-FileSha256 (Join-Path $ExecutorRoot "scripts/apply-windows.ps1")
            },
            [ordered]@{
                path = "scripts/collect-windows.ps1"
                sha256 = Get-FileSha256 (Join-Path $ExecutorRoot "scripts/collect-windows.ps1")
            }
        )
        $FixtureManifest = [ordered]@{
            schema = "roundhouse.integrity"
            schema_version = 1
            plugin = "roundhouse"
            marketplace = "selftest"
            version = "0.0.0"
            files = $FixtureFiles
        }
        [IO.File]::WriteAllText(
            (Join-Path $ExecutorRoot "integrity.json"),
            ($FixtureManifest | ConvertTo-Json -Depth 10),
            $OutputEncoding
        )
        $FixtureExecutor = Get-InstalledExecutor $ExecutorRoot
        Assert-Executor $FixtureExecutor $FixtureExecutor $ExecutorRoot

        $HostId = "fixture-host"
        $ControllerConfigDigest = "a" * 64
        $RuntimeWorkerDigest = "b" * 64
        $RuntimePlan = [pscustomobject][ordered]@{
            schema = "roundhouse.plan"
            schema_version = 2
            target = $HostId
            domain = "agents"
            required_section = "agents"
            controller_configuration_digest = [ordered]@{ algorithm = "sha256"; value = $ControllerConfigDigest }
            worker_configuration_digest = [ordered]@{ algorithm = "sha256"; value = $RuntimeWorkerDigest }
            precondition_digest = [ordered]@{ algorithm = "sha256"; value = "c" * 64 }
            operations = @([pscustomobject][ordered]@{
                type = "agent-update"; kind = "agent_runtime"; id = "codex"; argv = @("codex", "update")
            })
        }
        $RuntimeDigest = Get-TextSha256 ((ConvertTo-CanonicalJson $RuntimePlan) + "`n")
        Add-Member -InputObject $RuntimePlan -NotePropertyName plan_id -NotePropertyValue "plan-$($RuntimeDigest.Substring(0, 16))"
        Add-Member -InputObject $RuntimePlan -NotePropertyName plan_digest -NotePropertyValue ([ordered]@{
            algorithm = "sha256"; value = $RuntimeDigest
        })
        $PlanId = $RuntimePlan.plan_id
        Assert-Plan $RuntimePlan $RuntimeWorkerDigest

        $TargetedChezmoiPlan = [pscustomobject][ordered]@{
            schema = "roundhouse.plan"
            schema_version = 2
            target = $HostId
            domain = "chezmoi"
            required_section = "chezmoi"
            controller_configuration_digest = [ordered]@{ algorithm = "sha256"; value = $ControllerConfigDigest }
            worker_configuration_digest = [ordered]@{ algorithm = "sha256"; value = $RuntimeWorkerDigest }
            precondition_digest = [ordered]@{ algorithm = "sha256"; value = "c" * 64 }
            operations = @([pscustomobject][ordered]@{
                type = "chezmoi-apply"; kind = "chezmoi_state"; id = "live"
                argv = @("chezmoi", "--no-tty", "apply", "--", "C:\Users\Operator\.profile.d\10-env.sh")
                targets = @("C:\Users\Operator\.profile.d\10-env.sh")
            })
        }
        $TargetedChezmoiDigest = Get-TextSha256 ((ConvertTo-CanonicalJson $TargetedChezmoiPlan) + "`n")
        Add-Member -InputObject $TargetedChezmoiPlan -NotePropertyName plan_id -NotePropertyValue "plan-$($TargetedChezmoiDigest.Substring(0, 16))"
        Add-Member -InputObject $TargetedChezmoiPlan -NotePropertyName plan_digest -NotePropertyValue ([ordered]@{
            algorithm = "sha256"; value = $TargetedChezmoiDigest
        })
        $PlanId = $TargetedChezmoiPlan.plan_id
        Assert-Plan $TargetedChezmoiPlan $RuntimeWorkerDigest

        $UnexpectedTargetsPlan = [pscustomobject][ordered]@{
            schema = "roundhouse.plan"
            schema_version = 2
            plan_id = "plan-0000000000000000"
            target = $HostId
            domain = "agents"
            required_section = "agents"
            controller_configuration_digest = [ordered]@{ algorithm = "sha256"; value = $ControllerConfigDigest }
            worker_configuration_digest = [ordered]@{ algorithm = "sha256"; value = $RuntimeWorkerDigest }
            plan_digest = [ordered]@{ algorithm = "sha256"; value = "d" * 64 }
            precondition_digest = [ordered]@{ algorithm = "sha256"; value = "c" * 64 }
            operations = @([ordered]@{
                type = "agent-update"; kind = "agent_runtime"; id = "codex"; argv = @("codex", "update")
                targets = @("C:\Users\Operator\.profile.d\10-env.sh")
            })
        }
        $Rejected = $false
        try {
            Assert-Plan $UnexpectedTargetsPlan $RuntimeWorkerDigest
        } catch {
            $Rejected = $true
        }
        if (-not $Rejected) { throw "Unexpected operation targets self-test failed" }
        $PlanId = $TargetedChezmoiPlan.plan_id

        $PartialPlan = [pscustomobject]@{
            domain = "agents"
            operations = @([pscustomobject]@{
                type = "agent-update"
                kind = "skill"
                id = "skills-cli:example"
            })
            required_executor = $FixtureExecutor
        }
        $PartialFailure = [ordered]@{
            operation = $PartialPlan.operations[0]
            index = 0
            exit_code = 17
            operation_status = "failed"
            stage = "execute"
            message = "fixture failure"
        }
        $PartialOperationRecord = New-ApplyOperationRecord $PartialFailure "fixture-snapshot" `
            "2026-01-01T00:00:00Z" $PartialPlan "plan-0000000000000000" "fixture-host" `
            ("b" * 64) ("c" * 64)
        $PartialSummaryRecord = New-ApplySummaryRecord $PartialFailure "fixture-snapshot" `
            "2026-01-01T00:00:00Z" $PartialPlan "plan-0000000000000000" "fixture-host" `
            ("d" * 64) ("b" * 64) ("c" * 64) "completed"
        if ($PartialOperationRecord.data.operation_status -ne "failed" -or
            $PartialSummaryRecord.status -ne "partial" -or
            $PartialSummaryRecord.data.failed_operation_index -ne 0) {
            throw "Partial result self-test failed"
        }
        $ResultPath = Join-Path $SelfTestRoot "partial.jsonl"
        Write-Result @($PartialOperationRecord, $PartialSummaryRecord)
        $PartialLines = @(Get-Content -LiteralPath $ResultPath | ForEach-Object { $_ | ConvertFrom-Json })
        if ($PartialLines.Count -ne 2 -or
            @($PartialLines | Where-Object { $_.id -eq "apply:plan-0000000000000000" -and
                $_.status -eq "partial" -and $_.data.failed_operation_index -eq 0 }).Count -ne 1) {
            throw "Partial result serialization self-test failed"
        }
        foreach ($Record in $PartialLines) {
            if ($Record.errors -isnot [array] -or $Record.errors.Count -ne 1) {
                throw "Partial result errors must serialize as a JSON array"
            }
        }
        $CompletedResult = [ordered]@{}
        foreach ($Key in $PartialFailure.Keys) { $CompletedResult[$Key] = $PartialFailure[$Key] }
        $CompletedResult.operation_status = "completed"
        $CompletedResult.exit_code = 0
        $CompletedOperationRecord = New-ApplyOperationRecord $CompletedResult "fixture-snapshot" `
            "2026-01-01T00:00:00Z" $PartialPlan "plan-0000000000000000" "fixture-host" `
            ("b" * 64) ("c" * 64)
        $CompletedSummaryRecord = New-ApplySummaryRecord $null "fixture-snapshot" `
            "2026-01-01T00:00:00Z" $PartialPlan "plan-0000000000000000" "fixture-host" `
            ("d" * 64) ("b" * 64) ("c" * 64) "completed"
        Write-Result @($CompletedOperationRecord, $CompletedSummaryRecord)
        $CompletedLines = @(Get-Content -LiteralPath $ResultPath | ForEach-Object { $_ | ConvertFrom-Json })
        foreach ($Record in $CompletedLines) {
            if ($Record.errors -isnot [array] -or $Record.errors.Count -ne 0 -or
                $Record.data.operation_status -ne "completed") {
                throw "Completed result errors must serialize as an empty JSON array"
            }
        }
        $TailResult = [ordered]@{}
        foreach ($Key in $PartialFailure.Keys) { $TailResult[$Key] = $PartialFailure[$Key] }
        $TailResult.output_tail = [string[]]@($OutputTailRedacted, $KnownError)
        $TailResult.message = Join-FailureDetail "Native command failed: npx (exit 17)" $TailResult.output_tail
        $CompletedResult.output_tail = [string[]]@("not serialized on success")
        $CompletedResult.index = 1
        Write-Result @(
            (New-ApplyOperationRecord $TailResult "fixture-snapshot" "2026-01-01T00:00:00Z" $PartialPlan `
                "plan-0000000000000000" "fixture-host" ("b" * 64) ("c" * 64)),
            (New-ApplyOperationRecord $CompletedResult "fixture-snapshot" `
                "2026-01-01T00:00:00Z" $PartialPlan "plan-0000000000000000" "fixture-host" ("b" * 64) ("c" * 64))
        )
        $TailLines = @(Get-Content -LiteralPath $ResultPath | ForEach-Object { $_ | ConvertFrom-Json })
        $FailedTailRecord = @($TailLines | Where-Object { $_.data.operation_status -eq "failed" })
        $CompletedTailRecord = @($TailLines | Where-Object { $_.data.operation_status -eq "completed" })
        if ($FailedTailRecord.Count -ne 1 -or $FailedTailRecord[0].data.output_tail -isnot [array] -or
            $FailedTailRecord[0].data.output_tail[-1] -cne $KnownError -or
            -not $FailedTailRecord[0].errors[0].message.EndsWith($KnownError) -or
            $CompletedTailRecord.Count -ne 1 -or
            $null -ne $CompletedTailRecord[0].data.PSObject.Properties["output_tail"]) {
            throw "Output-tail result serialization self-test failed"
        }

        if ($IsWindows) {
            $FixtureHostId = "windows-selftest"
            $FixtureControllerDigest = "a" * 64
            $FixtureConfig = [ordered]@{
                version = 1
                worker = [ordered]@{
                    target = $FixtureHostId
                    controller_configuration_digest = $FixtureControllerDigest
                }
                machines = [ordered]@{
                    $FixtureHostId = [ordered]@{
                        platform = "windows"
                        transport = "codex-remote-control"
                        codex_host = "selftest"
                        expected_hostname = [string]$env:COMPUTERNAME
                        expected_user = [string][Environment]::UserName
                        groups = @()
                        package_managers = @()
                    }
                }
            }
            $FixtureConfigPath = Join-Path $SelfTestRoot "worker.json"
            [IO.File]::WriteAllText(
                $FixtureConfigPath,
                ($FixtureConfig | ConvertTo-Json -Depth 20),
                $OutputEncoding
            )
            $Collected = @(& $CollectScript -ConfigPath $FixtureConfigPath -HostId $FixtureHostId `
                -ControllerConfigDigest $FixtureControllerDigest -SnapshotId "selftest" -Sections host)
            if (@($Collected | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.kind -eq "operation" -and $_.data.operation_status -eq "completed" }).Count -ne 1) {
                throw "Normal collector boundary self-test failed"
            }

            foreach ($Case in @("target-binding", "digest-binding", "hostname", "user", "control")) {
                $InvalidConfig = $FixtureConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                if ($Case -eq "target-binding") {
                    $InvalidConfig.worker.target = "wrong-target"
                } elseif ($Case -eq "digest-binding") {
                    $InvalidConfig.worker.controller_configuration_digest = "f" * 64
                } elseif ($Case -eq "hostname") {
                    $InvalidConfig.machines.$FixtureHostId.expected_hostname = "wrong-host"
                } elseif ($Case -eq "user") {
                    $InvalidConfig.machines.$FixtureHostId.expected_user = "wrong-user"
                } else {
                    $InvalidConfig.machines.$FixtureHostId.codex_host = "bad$([char]0x81)"
                }
                $InvalidPath = Join-Path $SelfTestRoot "$Case.json"
                [IO.File]::WriteAllText($InvalidPath, ($InvalidConfig | ConvertTo-Json -Depth 20), $OutputEncoding)
                $Rejected = $false
                try {
                    & $CollectScript -ConfigPath $InvalidPath -HostId $FixtureHostId `
                        -ControllerConfigDigest $FixtureControllerDigest -SnapshotId "selftest-$Case" `
                        -Sections host *> $null
                } catch {
                    $Rejected = $true
                }
                if (-not $Rejected) { throw "Collector $Case rejection self-test failed" }
            }

            $Git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $SeedPath = Join-Path $SelfTestRoot "seed"
            $OriginPath = Join-Path $SelfTestRoot "origin.git"
            [void][IO.Directory]::CreateDirectory($SeedPath)
            & $Git.Source -C $SeedPath init --quiet
            if ($LASTEXITCODE -ne 0) { throw "Fixture Git init failed" }
            [IO.File]::WriteAllText((Join-Path $SeedPath "README.md"), "fixture`n", $OutputEncoding)
            & $Git.Source -C $SeedPath add README.md
            & $Git.Source -C $SeedPath -c user.name=roundhouse `
                -c user.email=roundhouse@example.invalid commit --quiet -m fixture
            if ($LASTEXITCODE -ne 0) { throw "Fixture Git commit failed" }
            & $Git.Source clone --quiet --bare -- $SeedPath $OriginPath
            if ($LASTEXITCODE -ne 0) { throw "Fixture bare clone failed" }

            $FixtureDevRoot = Join-Path $SelfTestRoot "apply-dev"
            $OriginUri = [Uri]::new((Resolve-Path -LiteralPath $OriginPath).Path).AbsoluteUri
            $FixtureConfig.machines.$FixtureHostId.dev_root = $FixtureDevRoot
            $FixtureConfig.projects = [ordered]@{
                good = [ordered]@{
                    path = "nested/team/good"
                    source = $OriginUri
                    groups = @()
                    codex = $false
                }
                bad = [ordered]@{
                    path = "blocked/bad"
                    source = $OriginUri
                    groups = @()
                    codex = $false
                }
            }
            [void][IO.Directory]::CreateDirectory($FixtureDevRoot)
            [IO.File]::WriteAllText((Join-Path $FixtureDevRoot "blocked"), "not-a-directory", $OutputEncoding)
            [IO.File]::WriteAllText(
                $FixtureConfigPath,
                ($FixtureConfig | ConvertTo-Json -Depth 20),
                $OutputEncoding
            )
            $FixtureWorkerDigest = Get-FileSha256 $FixtureConfigPath
            $PlanningLines = @(& $CollectScript -ConfigPath $FixtureConfigPath -HostId $FixtureHostId `
                -ControllerConfigDigest $FixtureControllerDigest -SnapshotId "planning-selftest" -Sections projects)
            $PlanningRecords = @($PlanningLines | ForEach-Object { $_ | ConvertFrom-Json })
            $PlanningSnapshot = @($PlanningRecords | Where-Object {
                $_.kind -eq "snapshot" -and $_.id -eq "snapshot"
            })
            if ($PlanningSnapshot.Count -ne 1) { throw "Fixture planning inventory failed" }

            $GoodOperation = [pscustomobject]@{
                type = "project-clone"
                kind = "project"
                id = "good"
            }
            $BadOperation = [pscustomobject]@{
                type = "project-clone"
                kind = "project"
                id = "bad"
            }
            $FixtureConfigObject = Get-Content -LiteralPath $FixtureConfigPath -Raw | ConvertFrom-Json
            $FixtureMachineObject = $FixtureConfigObject.machines.$FixtureHostId
            $GoodOperation | Add-Member -NotePropertyName argv -NotePropertyValue @(
                Get-ExactArgv $GoodOperation $FixtureConfigObject $FixtureMachineObject
            )
            $BadOperation | Add-Member -NotePropertyName argv -NotePropertyValue @(
                Get-ExactArgv $BadOperation $FixtureConfigObject $FixtureMachineObject
            )
            $FixtureExecutor = Get-InstalledExecutor
            $PlanBase = [ordered]@{
                schema = "roundhouse.plan"
                schema_version = 2
                created_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                domain = "projects"
                target = $FixtureHostId
                operations = @($GoodOperation, $BadOperation)
                required_section = "projects"
                planning_snapshot_id = [string]$PlanningSnapshot[0].snapshot_id
                planning_observed_at = [string]$PlanningSnapshot[0].observed_at
                configuration_digest = @{
                    algorithm = "sha256"
                    value = $FixtureControllerDigest
                }
                worker_configuration_digest = @{
                    algorithm = "sha256"
                    value = $FixtureWorkerDigest
                }
                precondition_digest = @{
                    algorithm = "sha256"
                    value = Get-PreconditionDigest ([pscustomobject]@{
                        operations = @($GoodOperation, $BadOperation)
                    }) $PlanningRecords
                }
                required_executor = $FixtureExecutor
            }
            $FixturePlanDigest = Get-TextSha256 ((ConvertTo-CanonicalJson $PlanBase) + "`n")
            $FixturePlanId = "plan-$($FixturePlanDigest.Substring(0, 16))"
            $PlanBase.plan_id = $FixturePlanId
            $PlanBase.plan_digest = @{
                algorithm = "sha256"
                value = $FixturePlanDigest
            }
            $FixturePlanPath = Join-Path $SelfTestRoot "plan.json"
            $FixtureExecutorPath = Join-Path $SelfTestRoot "executor.json"
            $FixtureApplyResultPath = Join-Path $SelfTestRoot "apply-result.jsonl"
            [IO.File]::WriteAllText(
                $FixturePlanPath,
                ($PlanBase | ConvertTo-Json -Depth 100),
                $OutputEncoding
            )
            [IO.File]::WriteAllText(
                $FixtureExecutorPath,
                ($FixtureExecutor | ConvertTo-Json -Depth 20),
                $OutputEncoding
            )
            $FixturePlanFileDigest = Get-FileSha256 $FixturePlanPath
            $PriorNativePreference = $PSNativeCommandUseErrorActionPreference
            try {
                $PSNativeCommandUseErrorActionPreference = $false
                $FixtureApplyOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $PSCommandPath `
                    -ConfigPath $FixtureConfigPath `
                    -PlanPath $FixturePlanPath `
                    -ExpectedPlanFileSha256 $FixturePlanFileDigest `
                    -ExecutorRequirementPath $FixtureExecutorPath `
                    -PlanId $FixturePlanId `
                    -HostId $FixtureHostId `
                    -ControllerConfigDigest $FixtureControllerDigest `
                    -ResultPath $FixtureApplyResultPath 2>&1)
                $FixtureApplyExitCode = $LASTEXITCODE
            } finally {
                $PSNativeCommandUseErrorActionPreference = $PriorNativePreference
            }
            if ($FixtureApplyExitCode -ne 70 -or
                -not (Test-Path -LiteralPath $FixtureApplyResultPath -PathType Leaf)) {
                $FixtureApplyDiagnostic = (@($FixtureApplyOutput | Select-Object -Last 8) -join " | ")
                throw "Normal partial-apply boundary self-test failed: exit=$FixtureApplyExitCode result=$(
                    Test-Path -LiteralPath $FixtureApplyResultPath -PathType Leaf
                ) output=$FixtureApplyDiagnostic"
            }
            $FixtureApplyRecords = @(Get-Content -LiteralPath $FixtureApplyResultPath |
                ForEach-Object { $_ | ConvertFrom-Json })
            if (@($FixtureApplyRecords | Where-Object {
                $_.id -eq "apply:$FixturePlanId" -and
                $_.status -eq "partial" -and
                $_.data.failed_operation_index -eq 1 -and
                $_.data.failed_operation_status -eq "failed" -and
                $_.data.post_inventory_status -eq "completed"
            }).Count -ne 1 -or
                -not (Test-Path -LiteralPath (Join-Path $FixtureDevRoot "nested/team/good/.git") -PathType Container)) {
                throw "Partial-apply result or nested clone self-test failed"
            }
        }

        Invoke-NodeSwitchSelfTest (Join-Path $SelfTestRoot "node-switch")

        foreach ($ChildSelfTest in @(
            @{ Path = (Join-Path $PSScriptRoot "privilege-broker-windows.ps1"); Marker = "PASS: privilege-broker-windows fixture-safe self-check" },
            @{ Path = (Join-Path $PSScriptRoot "profile-worker-windows.ps1"); Marker = "PASS: profile-worker-windows fixture-safe self-check" },
            @{ Path = (Join-Path $PSScriptRoot "register-profile-task-windows.ps1"); Marker = "PASS: register-profile-task-windows fixture-safe self-check" },
            @{ Path = (Join-Path $PSScriptRoot "enroll-privilege-windows.ps1"); Marker = "PASS: enroll-privilege-windows fixture-safe self-check" }
        )) {
            Assert-RegularFile $ChildSelfTest.Path "Windows privilege lifecycle script" | Out-Null
            $ChildOutput = @(& $ChildSelfTest.Path -SelfTest)
            if (@($ChildOutput | Where-Object { $_ -ceq $ChildSelfTest.Marker }).Count -ne 1) {
                throw "Windows privilege lifecycle child self-test failed: $($ChildSelfTest.Path)"
            }
        }
        Write-Output "PASS: apply-windows native boundary self-check"
        exit 0
    } finally {
        Remove-Item -LiteralPath $SelfTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($VerifyExecutor) {
    Assert-RegularFile $ExecutorRequirementPath "Executor requirement" | Out-Null
    $RequirementEnvelope = Get-Content -LiteralPath $ExecutorRequirementPath -Raw | ConvertFrom-Json
    if (-not (Test-BoundedStrings $RequirementEnvelope)) {
        throw "Executor requirement contains an oversized or control string"
    }
    $RequiredExecutor = if ($null -ne $RequirementEnvelope.required_executor) {
        $RequirementEnvelope.required_executor
    } else {
        $RequirementEnvelope
    }
    Assert-ExecutorShape $RequiredExecutor
    $InstalledExecutor = Get-InstalledExecutor
    Assert-Executor $RequiredExecutor $InstalledExecutor
    $InstalledExecutor | ConvertTo-Json -Depth 20
    exit 0
}

if ($PSCmdlet.ParameterSetName -eq "ApproveHooks") {
    Assert-RegularFile $ExecutorRequirementPath "Executor requirement" | Out-Null
    $RequiredExecutor = Get-Content -LiteralPath $ExecutorRequirementPath -Raw | ConvertFrom-Json
    if ($null -ne $RequiredExecutor.required_executor) {
        $RequiredExecutor = $RequiredExecutor.required_executor
    }
    Assert-ExecutorShape $RequiredExecutor
    Assert-Executor $RequiredExecutor (Get-InstalledExecutor)
    try {
        [void](Invoke-CodexPluginHooks "approve" $ApproveCodexPluginHooks)
    } catch {
        $ExitCode = 1
        if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains("ExitCode")) {
            $ExitCode = [int]$_.Exception.Data["ExitCode"]
        }
        [Console]::Error.WriteLine((Get-SafeFailureMessage $_))
        exit $ExitCode
    }
    [ordered]@{ pluginId = $ApproveCodexPluginHooks; approved = $true } |
        ConvertTo-Json -Compress
    exit 0
}

if ($PSCmdlet.ParameterSetName -eq "BootstrapNodeFnm") {
    # Run by the host's own user, never through a sealed plan or elevated.
    try {
        Invoke-NodeFnmBootstrap $NodeMajor
    } catch {
        [Console]::Error.WriteLine("roundhouse: fnm bootstrap failed: " + (Get-SafeFailureMessage $_))
        exit 1
    }
    exit 0
}

Assert-RegularFile $ConfigPath "Worker configuration" | Out-Null
Assert-RegularFile $PlanPath "Apply plan" | Out-Null
Assert-RegularFile $ExecutorRequirementPath "Executor requirement" | Out-Null
Assert-RegularFile $CollectScript "Windows collector" 52428800 | Out-Null
$PlanBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $PlanPath).Path)
if ((Get-BytesSha256 $PlanBytes) -ne $ExpectedPlanFileSha256.ToLowerInvariant()) {
    throw "Apply plan file hash mismatch"
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Plan = [Text.Encoding]::UTF8.GetString($PlanBytes) | ConvertFrom-Json
$ExecutorStatus = Get-Content -LiteralPath $ExecutorRequirementPath -Raw | ConvertFrom-Json
if (-not (Test-BoundedStrings $Config) -or -not (Test-BoundedStrings $ExecutorStatus)) {
    throw "Worker input contains an oversized or control string"
}
$Machine = Get-ConfiguredMachine $Config
$WorkerConfigDigest = Get-FileSha256 $ConfigPath
Assert-Plan $Plan $WorkerConfigDigest
Assert-Executor $Plan.required_executor $ExecutorStatus
Assert-ResultPath

$Sections = @([string]$Plan.required_section)
$Before = @(Read-Inventory $Sections ("apply-pre-" + [Guid]::NewGuid().ToString("N")))
$BeforeSnapshot = @($Before | Where-Object { $_.kind -eq "snapshot" -and $_.id -eq "snapshot" })
if ($BeforeSnapshot.Count -ne 1 -or
    $BeforeSnapshot[0].data.configuration_digest.value -ne $ControllerConfigDigest.ToLowerInvariant() -or
    $BeforeSnapshot[0].data.worker_configuration_digest.value -ne $WorkerConfigDigest) {
    throw "Preflight inventory configuration digest mismatch"
}
$PlanningTime = [DateTime]::Parse(
    [string]$Plan.planning_observed_at,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
).ToUniversalTime()
$BeforeTime = [DateTime]::Parse(
    [string]$BeforeSnapshot[0].observed_at,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
).ToUniversalTime()
$BeforeAge = ([DateTime]::UtcNow - $BeforeTime).TotalSeconds
if ($Plan.planning_snapshot_id -eq $BeforeSnapshot[0].snapshot_id -or
    $BeforeAge -lt 0 -or $BeforeAge -gt 900 -or
    $PlanningTime -gt [DateTime]::UtcNow) {
    throw "Apply requires a distinct, fresh inventory"
}
if ((Get-PreconditionDigest $Plan $Before) -ne [string]$Plan.precondition_digest.value) {
    throw "Target state changed after planning"
}
foreach ($Operation in @($Plan.operations)) {
    $PreflightRecord = @(Get-Record $Before ([string]$Operation.kind) ([string]$Operation.id))
    if ($PreflightRecord.Count -ne 1) {
        throw "Preflight inventory does not cover every operation"
    }
    if ($Operation.type -eq "package-upgrade") {
        $Record = $PreflightRecord[0]
        if ($Record.status -ne "present" -or $Record.data.update_available -ne $true -or
            $Record.data.candidate_version -ne [string]$Operation.candidate_version) {
            throw "Package candidate no longer matches the sealed plan"
        }
        if ((Test-NpmUpdaterOperation $Operation) -and
            (ConvertTo-CanonicalJson @($Record.data.updater)) -ne (ConvertTo-CanonicalJson @($Operation.argv))) {
            throw "npm updater is no longer proven for the installed package"
        }
        if ([string]$Operation.id -ceq "fnm:node") {
            # The carry is still exactly the installed set this fresh
            # inventory shows, with this worker's configured hooks.
            Assert-NodeSwitchMatchesSnapshot $Operation $Record $Config
        }
        if ([string]$Operation.id -like "npm:*" -and @($Before | Where-Object {
            $_.kind -eq "package" -and $_.id -ceq "fnm:node" -and $null -ne $_.data.switch_inflight
        }).Count -gt 0) {
            throw "a Node switch is recorded in flight on the target; npm upgrades are refused until it is resolved"
        }
    }
    if ($Operation.type -eq "project-clone" -and $PreflightRecord[0].status -ne "absent") {
        throw "Project clone requires an absent configured project"
    }
        if ($Operation.type -eq "project-update" -and
        ($PreflightRecord[0].status -ne "present" -or
        $PreflightRecord[0].data.origin_matches -ne $true -or
        $PreflightRecord[0].data.repository_readiness -ne "ready" -or
        [int]$PreflightRecord[0].data.dirty_count -ne 0 -or
        $PreflightRecord[0].data.sync_state -ne "local-tracking-behind")) {
            throw "Project update requires a clean, correct-origin checkout that is behind its upstream"
        }
    if ($Operation.type -eq "chezmoi-apply" -and
        $null -ne $Operation.PSObject.Properties["targets"]) {
        Assert-ChezmoiTargetStatus $Operation $true
    }
}
Assert-Executor $Plan.required_executor $ExecutorStatus

$ExactArgvByIndex = New-Object System.Collections.Generic.List[object]
foreach ($Operation in @($Plan.operations)) {
    $ExpectedArgv = @(Get-ExactArgv $Operation $Config $Machine)
    if ((ConvertTo-CanonicalJson @($Operation.argv)) -ne (ConvertTo-CanonicalJson $ExpectedArgv)) {
        throw "Operation argv does not match the Windows allowlist"
    }
    [void]$ExactArgvByIndex.Add($ExpectedArgv)
}

$OperationResults = New-Object System.Collections.Generic.List[object]
$Failure = $null
for ($Index = 0; $Index -lt @($Plan.operations).Count; $Index++) {
    $Operation = @($Plan.operations)[$Index]
    $ExpectedArgv = [string[]]@($ExactArgvByIndex[$Index])
    # Never attribute an earlier operation's output to this one.
    $script:LastOutputTail = [string[]]@()
    try {
        if ($Operation.type -in @("project-clone", "project-update")) {
            Prepare-ProjectMutationPath $Operation $Config $Machine
        }
        if ($Operation.type -eq "agent-update" -and [string]$Operation.id -like "codex:*") {
            $ExitCode = Invoke-CodexPluginHooks "update" $ExpectedArgv[3]
        } elseif ($Operation.type -eq "package-upgrade" -and [string]$Operation.id -ceq "fnm:node") {
            $ExitCode = Invoke-NodeRuntimeSwitch ([string]$Operation.candidate_version) @($Operation.carry) @($Operation.hooks)
        } elseif (Test-NpmUpdaterOperation $Operation) {
            Assert-NoNodeSwitchInflight
            $ExitCode = Invoke-NpmUpdater $Operation $ExpectedArgv
        } elseif ($Operation.type -eq "package-upgrade" -and [string]$Operation.id -like "npm:*") {
            Assert-NoNodeSwitchInflight
            $ExitCode = Invoke-WithNpmOnPath (Get-SelectedNpm) { Invoke-Exact $ExpectedArgv }
        } else {
            $ExitCode = Invoke-Exact $ExpectedArgv
        }
        [void]$OperationResults.Add([ordered]@{
            operation = $Operation
            index = $Index
            exit_code = $ExitCode
            operation_status = "completed"
            stage = "execute"
            message = $null
            # Kept in memory only: serialized if a postcondition fails later.
            execute_output_tail = [string[]]@($script:LastOutputTail)
            output_tail = [string[]]@()
        })
    } catch {
        $ExitCode = $null
        if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains("ExitCode")) {
            $ExitCode = [int]$_.Exception.Data["ExitCode"]
        }
        $Tail = Get-ErrorOutputTail $_
        $Failure = [ordered]@{
            operation = $Operation
            index = $Index
            exit_code = $ExitCode
            operation_status = "failed"
            stage = "execute"
            message = Join-FailureDetail (Get-SafeFailureMessage $_) $Tail
            execute_output_tail = $Tail
            output_tail = $Tail
        }
        [void]$OperationResults.Add($Failure)
        break
    }
}

$After = @()
$PostInventoryStatus = "failed"
try {
    $After = @(Read-Inventory $Sections ("apply-post-" + [Guid]::NewGuid().ToString("N")))
    $PostInventoryStatus = "completed"
} catch {
    if ($null -eq $Failure) {
        $Failure = [ordered]@{
            operation = $null
            index = $null
            exit_code = $null
            operation_status = "failed"
            stage = "post-inventory"
            message = Get-SafeFailureMessage $_
        }
    }
}

if ($PostInventoryStatus -eq "completed" -and $null -eq $Failure) {
    for ($Index = 0; $Index -lt @($Plan.operations).Count; $Index++) {
        try {
            Assert-Postcondition @($Plan.operations)[$Index] $Before $After @($Plan.operations)
        } catch {
            $Result = $OperationResults[$Index]
            # The operation's own output first, then what the check observed.
            $Tail = Join-OutputTail ([string[]]@($Result.execute_output_tail)) (Get-ErrorOutputTail $_)
            $Result.operation_status = "failed"
            $Result.stage = "verify"
            $Result.message = Join-FailureDetail (Get-SafeFailureMessage $_) $Tail
            $Result.output_tail = $Tail
            $Failure = $Result
            break
        }
    }
}

$Snapshot = if ($PostInventoryStatus -eq "completed") {
    @($After | Where-Object { $_.kind -eq "snapshot" } | Select-Object -First 1)[0]
} else {
    $BeforeSnapshot[0]
}
$ObservedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$ResultRecords = New-Object System.Collections.Generic.List[object]
if ($PostInventoryStatus -eq "completed") {
    foreach ($Record in $After) { [void]$ResultRecords.Add($Record) }
} else {
    [void]$ResultRecords.Add($Snapshot)
}
foreach ($Result in $OperationResults) {
    [void]$ResultRecords.Add((New-ApplyOperationRecord $Result $Snapshot.snapshot_id $ObservedAt `
        $Plan $PlanId $HostId $ControllerConfigDigest.ToLowerInvariant() $WorkerConfigDigest))
}
[void]$ResultRecords.Add((New-ApplySummaryRecord $Failure $Snapshot.snapshot_id $ObservedAt `
    $Plan $PlanId $HostId $ExpectedPlanFileSha256.ToLowerInvariant() `
    $ControllerConfigDigest.ToLowerInvariant() $WorkerConfigDigest $PostInventoryStatus))

Write-Result $ResultRecords
if ($null -ne $Failure) {
    # One line: the interop launcher relays exactly the last stderr line.
    [Console]::Error.WriteLine((Get-FailureLine ([string]$Failure.stage) $Failure.message))
    exit 70
}
