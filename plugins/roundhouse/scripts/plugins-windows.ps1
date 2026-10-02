# Roundhouse plugin currency for native Windows: one bounded run of the
# per-user, unelevated `RoundhousePluginCurrency` Task Scheduler task.
#
# Native Windows has no roundhouse runtime (no jj, CLI or fleet store), so
# `roundhouse fleet-run` never runs here and nothing else keeps this user's
# plugins current. `fleet-schedule install` on the machine's WSL side
# registers this script (a content-addressed copy, with the hook helper beside
# it) to run every 20 minutes; each run, inside one hard time bound:
#
#   1. Claude Code: `claude plugin marketplace update`, then
#      `claude plugin update ID --scope user` for every installed user-scope
#      plugin — the unowned path of lib/fleet-plugins.sh: never an install,
#      enable or removal.
#   2. Codex: trigger Codex's own sync of its Git marketplaces
#      (`codex-plugin-hooks.mjs sync`, each root to its upstream head).
#   3. Codex: reconcile every installed, ENABLED copy against its
#      marketplace's catalog. Codex reinstalls only when a marketplace clone
#      MOVES, so a clone already at the latest revision can still hold an old
#      copy; a copy whose source SHA is not the catalog's is reinstalled with
#      `codex plugin add` — the reinstall `codex-plugin-hooks.mjs update`
#      runs, without its unverified re-trust of changed hooks. A hook that
#      changed reads `modified`, untrusted, as Codex itself leaves it.
#   4. Codex: byte-verified hook approval for the fleet's own plugins
#      (novotnyllc: roundhouse, railyard, agent-utilities), under the same
#      verified-identity contract as the POSIX run (lib/fleet-run.sh
#      fleet_run_approve_plugin_hooks / fleet_run_codex_bytes_verified):
#      Codex's copy is from the source Claude's catalog names, at its pinned
#      SHA; Claude's user install is at that SHA; and the helper itself checks
#      the two trees byte-identical in the session that writes trust. A hook
#      never trusted is the operator's, always.
#   5. A status file under %LOCALAPPDATA%\Roundhouse\plugin-currency\, which
#      `roundhouse fleet-schedule status` reports from the WSL side.
#
# Node.js (for the hook helper) is PATH node first, then Codex's bundled
# runtime, then Claude's, as fleet-update documents. Nothing here elevates,
# prompts or opens a window, and nothing it runs outlives the run's bound.
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Utf8 = [Text.UTF8Encoding]::new($false)
$DeadlineSeconds = 780
$FleetMarketplace = "novotnyllc"
$FleetPlugins = @("roundhouse", "railyard", "agent-utilities")
$PluginIdPattern = '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$'
$PartPattern = '^[A-Za-z0-9._-]+$'
$ShaPattern = '^[0-9a-f]{40}$'
$MaximumMessages = 32
$CodexCatalogPaths = @(
    @(".agents", "plugins", "marketplace.json"),
    @(".agents", "plugins", "api_marketplace.json"),
    @(".claude-plugin", "marketplace.json"),
    @(".cursor-plugin", "marketplace.json")
)

$Script:Deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
$Script:TimedOut = $false
$Script:Updated = 0
$Script:Held = 0
$Script:Messages = [Collections.Generic.List[string]]::new()

function Get-SafeText([object]$Value, [int]$Limit) {
    $Text = ([string]$Value) -replace '[\x00-\x1f\x7f-\x9f]', ' '
    if ($Text.Length -gt $Limit) { $Text = $Text.Substring(0, $Limit) }
    return $Text
}

function Add-Note([string]$Kind, [string]$Text) {
    # Kind: update (something moved), hold (something could not be made
    # current; the next run retries) or note (said, counted as neither).
    if ($Kind -ceq "update") { $Script:Updated++ }
    if ($Kind -ceq "hold") { $Script:Held++ }
    if ($Script:Messages.Count -lt $MaximumMessages) {
        $Script:Messages.Add((Get-SafeText "$Kind $Text" 256))
    }
}

function Get-RemainingSeconds {
    return [int][Math]::Floor(($Script:Deadline - [DateTime]::UtcNow).TotalSeconds)
}

function Invoke-Tool {
    # Invoke-Tool FILE ARGUMENTS TIMEOUT [ENVIRONMENT] — one bounded child:
    # its exit code and stdout, or TimedOut once the smaller of TIMEOUT and
    # the run's remaining time passes (the whole process tree is then
    # killed). Never a shell: each argument is passed as itself.
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [hashtable]$Environment = @{})
    $Bound = [Math]::Min($TimeoutSeconds, (Get-RemainingSeconds))
    if ($Bound -le 0) {
        $Script:TimedOut = $true
        return [pscustomobject]@{ ExitCode = -1; Stdout = ""; TimedOut = $true }
    }
    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $FilePath
    foreach ($Argument in $Arguments) { [void]$Info.ArgumentList.Add($Argument) }
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardInput = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.WorkingDirectory = (Get-HomeDirectory)
    foreach ($Key in $Environment.Keys) { $Info.Environment[$Key] = [string]$Environment[$Key] }
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    try {
        [void]$Process.Start()
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Stdout = ""; TimedOut = $false }
    }
    $Process.StandardInput.Close()
    $Out = $Process.StandardOutput.ReadToEndAsync()
    $Err = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit($Bound * 1000)) {
        try { $Process.Kill($true) } catch { }
        [void]$Process.WaitForExit(5000)
        $Script:TimedOut = $true
        return [pscustomobject]@{ ExitCode = -1; Stdout = ""; TimedOut = $true }
    }
    $Process.WaitForExit()
    [void]$Err.Wait(5000)
    $Stdout = if ($Out.Wait(5000)) { $Out.Result } else { "" }
    return [pscustomobject]@{ ExitCode = $Process.ExitCode; Stdout = $Stdout; TimedOut = $false }
}

function Get-HomeDirectory {
    foreach ($Candidate in @($env:USERPROFILE, $env:HOME, [Environment]::GetFolderPath("UserProfile"))) {
        if (-not [string]::IsNullOrEmpty($Candidate)) { return $Candidate }
    }
    throw "No user profile directory"
}

function Get-ClaudeHome {
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_CONFIG_DIR)) { return $env:CLAUDE_CONFIG_DIR }
    return Join-Path (Get-HomeDirectory) ".claude"
}

function Get-CodexHome {
    if (-not [string]::IsNullOrEmpty($env:CODEX_HOME)) { return $env:CODEX_HOME }
    return Join-Path (Get-HomeDirectory) ".codex"
}

function Get-StateRoot {
    $Local = [string]$env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($Local)) { $Local = [Environment]::GetFolderPath("LocalApplicationData") }
    if ([string]::IsNullOrEmpty($Local)) { throw "No local application data directory for the status file" }
    return [IO.Path]::Combine($Local, "Roundhouse", "plugin-currency")
}

function Read-JsonFile([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        return $null
    }
}

function ConvertFrom-ToolJson([object]$Result) {
    if ($Result.ExitCode -ne 0) { return $null }
    try { return $Result.Stdout | ConvertFrom-Json } catch { return $null }
}

function Find-Tool([string[]]$Names, [string[]]$Candidates) {
    foreach ($Name in $Names) {
        $Command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Command) { return [string]$Command.Source }
    }
    foreach ($Candidate in $Candidates) {
        if (-not [string]::IsNullOrEmpty($Candidate) -and (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $Candidate }
    }
    return $null
}

function Resolve-Node {
    # PATH Node first, then Codex's bundled runtime, then Claude's (last,
    # best effort): fleet-update's native-Windows resolver order. Returns
    # {Path, Source}, or $null with every probe in $Script:NodeProbes.
    param([AllowNull()][string]$PathNode, [string]$HomeDirectory, [AllowNull()][string]$Claude)
    $Script:NodeProbes = [Collections.Generic.List[string]]::new()
    $Script:NodeProbes.Add("PATH node: $(if ($PathNode) { $PathNode } else { '(none)' })")
    if ($PathNode -and (Test-Path -LiteralPath $PathNode -PathType Leaf)) {
        return [pscustomobject]@{ Path = $PathNode; Source = "PATH" }
    }
    $Bundled = [IO.Path]::Combine($HomeDirectory, ".cache", "codex-runtimes", "codex-primary-runtime",
        "dependencies", "node", "bin", "node.exe")
    $Script:NodeProbes.Add("CODEX-BUNDLED node: $Bundled")
    if (Test-Path -LiteralPath $Bundled -PathType Leaf) {
        return [pscustomobject]@{ Path = $Bundled; Source = "CODEX-BUNDLED" }
    }
    if ($Claude) {
        $ClaudeDirectory = Split-Path -Parent $Claude
        foreach ($Candidate in @((Join-Path $ClaudeDirectory "node.exe"),
                [IO.Path]::Combine($ClaudeDirectory, "resources", "node.exe"))) {
            $Script:NodeProbes.Add("Claude-bundled node: $Candidate")
            if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
                return [pscustomobject]@{ Path = $Candidate; Source = "CLAUDE-BUNDLED" }
            }
        }
    }
    return $null
}

function Get-InstalledClaudePlugins {
    # installed_plugins.json's user-scope records, by plugin ID.
    $Records = @{}
    $Document = Read-JsonFile (Join-Path (Get-ClaudeHome) "plugins\installed_plugins.json".Replace('\', [IO.Path]::DirectorySeparatorChar))
    if ($null -eq $Document -or $null -eq $Document.plugins) { return $Records }
    foreach ($Property in @($Document.plugins.PSObject.Properties)) {
        if ($Property.Name -cnotmatch $PluginIdPattern) { continue }
        $User = @($Property.Value | Where-Object { $_.scope -ceq "user" }) | Select-Object -First 1
        if ($null -ne $User) { $Records[$Property.Name] = $User }
    }
    return $Records
}

function Update-ClaudePlugins([string]$Claude) {
    $Refresh = Invoke-Tool $Claude @("plugin", "marketplace", "update") 300
    if ($Refresh.ExitCode -ne 0) {
        Add-Note "hold" "claude plugin marketplace update did not complete; plugins update against the catalogs already here"
    }
    $Before = Get-InstalledClaudePlugins
    foreach ($Id in @($Before.Keys | Sort-Object)) {
        $Result = Invoke-Tool $Claude @("plugin", "update", $Id, "--scope", "user") 180
        if ($Result.ExitCode -ne 0) {
            Add-Note "hold" "claude plugin update $Id did not complete"
            continue
        }
        $After = (Get-InstalledClaudePlugins)[$Id]
        if ($null -ne $After -and ([string]$After.gitCommitSha -cne [string]$Before[$Id].gitCommitSha -or
                [string]$After.version -cne [string]$Before[$Id].version)) {
            Add-Note "update" "claude $Id $($Before[$Id].version) -> $($After.version)"
        }
    }
}

function Get-RemoteHead([string]$Git, [string]$Url, [string]$Ref) {
    # The 40-hex commit URL serves at REF (a branch wins over a tag, which
    # peels; HEAD when REF is empty), or $null. Never prompts.
    if ($Url -notmatch '^(https://|ssh://|git@)[^\s]+$' -or ($Ref -and $Ref -notmatch '^[A-Za-z0-9._/-]+$')) { return $null }
    $Refs = if ($Ref) { @("refs/heads/$Ref", "refs/tags/$Ref", "refs/tags/$Ref^{}") } else { @("HEAD") }
    $Result = Invoke-Tool $Git (@("ls-remote", "--", $Url) + $Refs) 30 @{ GIT_TERMINAL_PROMPT = "0"; GCM_INTERACTIVE = "never" }
    if ($Result.ExitCode -ne 0) { return $null }
    $Found = @{}
    foreach ($Line in @($Result.Stdout -split "`r?`n")) {
        $Fields = $Line -split "`t"
        if ($Fields.Count -eq 2 -and $Fields[0] -match '^[0-9a-fA-F]{40}$') { $Found[$Fields[1]] = $Fields[0].ToLowerInvariant() }
    }
    if (-not $Ref) { return $Found["HEAD"] }
    foreach ($Key in @("refs/heads/$Ref", "refs/tags/$Ref^{}", "refs/tags/$Ref")) {
        if ($Found.ContainsKey($Key)) { return $Found[$Key] }
    }
    return $null
}

function Get-CodexMarketplaces([string]$Codex) {
    # Codex's Git marketplaces, {Name, Url, Root, Ref}. Local and bundled ones
    # advance with Codex itself.
    $Listed = ConvertFrom-ToolJson (Invoke-Tool $Codex @("plugin", "marketplace", "list", "--json") 60)
    $Markets = [Collections.Generic.List[object]]::new()
    if ($null -eq $Listed) {
        Add-Note "hold" "codex plugin marketplace list did not answer"
        return , $Markets.ToArray()
    }
    $Entries = if ($Listed -is [array]) { $Listed } else { @($Listed.marketplaces) }
    foreach ($Entry in $Entries) {
        if ([string]$Entry.marketplaceSource.sourceType -cne "git" -or [string]$Entry.name -cnotmatch $PartPattern -or
            [string]::IsNullOrEmpty([string]$Entry.root)) { continue }
        $Install = Read-JsonFile (Join-Path ([string]$Entry.root) ".codex-marketplace-install.json")
        $Markets.Add([pscustomobject]@{
            Name = [string]$Entry.name; Url = [string]$Entry.marketplaceSource.source
            Root = [string]$Entry.root; Ref = if ($Install) { [string]$Install.ref_name } else { "" }
        })
    }
    return , $Markets.ToArray()
}

function Sync-Codex([string]$Node, [string]$Helper, [string]$Codex, [object[]]$Markets, [AllowNull()][string]$Git) {
    $Pairs = [Collections.Generic.List[string]]::new()
    foreach ($Market in $Markets) {
        $Head = if ($Git) { Get-RemoteHead $Git $Market.Url $Market.Ref } else { $null }
        if ($null -eq $Head) {
            Add-Note "note" "codex marketplace $($Market.Name): upstream head unknown$(if (-not $Git) { ' (no git)' }); reconciled against its clone as it stands"
            continue
        }
        $Pairs.Add($Market.Root)
        $Pairs.Add($Head)
    }
    if ($Pairs.Count -eq 0) { return }
    $Result = Invoke-Tool $Node (@($Helper, "sync", "--codex-executable", $Codex) + $Pairs.ToArray()) 240 @{ ROUNDHOUSE_CODEX_SYNC_WAIT_MS = "180000" }
    $Report = ConvertFrom-ToolJson ([pscustomobject]@{ ExitCode = 0; Stdout = $Result.Stdout })
    if ($null -eq $Report) {
        Add-Note "hold" "Codex's marketplace sync did not report"
        return
    }
    foreach ($Root in @($Report.missing)) {
        $Name = @($Markets | Where-Object { $_.Root -ceq [string]$Root } | ForEach-Object Name) | Select-Object -First 1
        Add-Note "hold" "codex marketplace $(if ($Name) { $Name } else { 'unknown' }) did not sync to its upstream head yet"
    }
}

function Get-CodexInstalled([string]$Codex) {
    $Listed = ConvertFrom-ToolJson (Invoke-Tool $Codex @("plugin", "list", "--json") 60)
    if ($null -eq $Listed) { return $null }
    $Installed = if ($Listed -is [array]) { $Listed } else { @($Listed.installed) }
    return , @($Installed | Where-Object { $null -ne $_ -and $_.installed -ne $false })
}

function Read-Catalog([string]$Root, [object[]]$Layouts) {
    foreach ($Parts in $Layouts) {
        $Path = $Root
        foreach ($Part in $Parts) { $Path = Join-Path $Path $Part }
        $Catalog = Read-JsonFile $Path
        if ($null -ne $Catalog) { return $Catalog }
    }
    return $null
}

function Get-CatalogEntry([object]$Catalog, [string]$Name) {
    if ($null -eq $Catalog) { return $null }
    return @($Catalog.plugins | Where-Object { [string]$_.name -ceq $Name }) | Select-Object -First 1
}

function Get-PinnedSha([object]$Entry) {
    $Sha = [string]$Entry.source.sha
    if ($Sha -cmatch $ShaPattern) { return $Sha }
    return $null
}

function Update-StaleCodexCopies([string]$Codex, [object[]]$Markets) {
    # Every installed, ENABLED Codex copy whose source SHA is not the one its
    # marketplace's catalog pins is reinstalled (a disabled copy is the
    # operator's, and `codex plugin add` would enable it).
    $Installed = Get-CodexInstalled $Codex
    if ($null -eq $Installed) {
        Add-Note "hold" "codex plugin list did not answer"
        return
    }
    foreach ($Market in $Markets) {
        $Catalog = Read-Catalog $Market.Root $CodexCatalogPaths
        foreach ($Record in @($Installed | Where-Object { [string]$_.marketplaceName -ceq $Market.Name -and $_.enabled -eq $true })) {
            $Id = [string]$Record.pluginId
            if ($Id -cnotmatch $PluginIdPattern) { continue }
            $Sha = Get-PinnedSha (Get-CatalogEntry $Catalog ([string]$Record.name))
            if ($null -eq $Sha -or [string]$Record.source.sha -ceq $Sha) { continue }
            $Add = Invoke-Tool $Codex @("plugin", "add", $Id, "--json") 240
            $After = Get-CodexInstalled $Codex
            $Now = @($After | Where-Object { [string]$_.pluginId -ceq $Id }) | Select-Object -First 1
            if ($Add.ExitCode -eq 0 -and $null -ne $Now -and [string]$Now.source.sha -ceq $Sha) {
                Add-Note "update" "codex $Id $($Record.version) -> $($Now.version)"
            } else {
                Add-Note "hold" "codex $Id is not at its catalog's $($Sha.Substring(0, 12)) yet; the next run retries"
            }
        }
    }
}

function Get-SourceIdentity([object]$Source) {
    # A plugin source's repository and path, GitHub spellings folded together
    # (lib/fleet-run.sh fleet_run_codex_source_ok), or $null.
    if ($null -eq $Source) { return $null }
    $Url = if ([string]$Source.source -ceq "github") { "https://github.com/" + [string]$Source.repo } else { [string]$Source.url }
    if ([string]::IsNullOrEmpty($Url)) { return $null }
    $Url = $Url.TrimEnd('/')
    if ($Url -match '^(https://|ssh://git@|git@)github[.]com[:/]') {
        $Url = "github:" + ($Url -replace '^(https://|ssh://git@|git@)github[.]com[:/]', '').ToLowerInvariant()
    }
    $Url = $Url -replace '[.]git$', ''
    $Path = ([string]$Source.path) -replace '^[.]/', '' -replace '^[.]$', '' -replace '/+$', ''
    return "$Url|$Path"
}

function Approve-FleetHooks([string]$Node, [string]$Helper, [string]$Codex) {
    $Known = Read-JsonFile ([IO.Path]::Combine((Get-ClaudeHome), "plugins", "known_marketplaces.json"))
    $Location = if ($Known) { [string]$Known.$FleetMarketplace.installLocation } else { "" }
    $ClaudeCatalog = if ($Location) { Read-Catalog $Location @(, @(".claude-plugin", "marketplace.json")) } else { $null }
    $ClaudeInstalled = Get-InstalledClaudePlugins
    $Installed = Get-CodexInstalled $Codex
    if ($null -eq $Installed) {
        Add-Note "hold" "codex plugin list did not answer; no hook approval this run"
        return
    }
    foreach ($Name in $FleetPlugins) {
        $Id = "$Name@$FleetMarketplace"
        $Record = @($Installed | Where-Object { [string]$_.pluginId -ceq $Id }) | Select-Object -First 1
        # Codex does not have it, or the operator disabled it: no hooks run,
        # nothing to approve.
        if ($null -eq $Record -or $Record.enabled -ne $true) { continue }
        $Entry = Get-CatalogEntry $ClaudeCatalog $Name
        $Sha = Get-PinnedSha $Entry
        if ($null -eq $Sha) {
            Add-Note "hold" "$Id hooks: Claude's catalog pins no SHA to verify against"
            continue
        }
        $Want = Get-SourceIdentity $Entry.source
        if ($null -eq $Want -or $Want -cne (Get-SourceIdentity $Record.source)) {
            Add-Note "hold" "$Id hooks: Codex's copy is not from the source Claude's catalog names"
            continue
        }
        if ([string]$Record.source.sha -cne $Sha) {
            Add-Note "hold" "$Id hooks: Codex has not synced to $($Sha.Substring(0, 12)) yet; the next run retries"
            continue
        }
        $ClaudeRecord = $ClaudeInstalled[$Id]
        $VerifiedTree = if ($ClaudeRecord -and [string]$ClaudeRecord.gitCommitSha -ceq $Sha) { [string]$ClaudeRecord.installPath } else { "" }
        if ([string]::IsNullOrEmpty($VerifiedTree) -or -not (Test-Path -LiteralPath $VerifiedTree -PathType Container)) {
            Add-Note "hold" "$Id hooks: no Claude install at $($Sha.Substring(0, 12)) to compare against"
            continue
        }
        $Version = [string]$Record.version
        if ($Version -cnotmatch $PartPattern -or $Version -in @(".", "..")) {
            Add-Note "hold" "$Id hooks: Codex's record names no installed copy"
            continue
        }
        $CodexTree = [IO.Path]::Combine((Get-CodexHome), "plugins", "cache", $FleetMarketplace, $Name, $Version)
        if (-not (Test-Path -LiteralPath $CodexTree -PathType Container)) {
            Add-Note "hold" "$Id hooks: Codex's installed copy is missing"
            continue
        }
        $Status = ConvertFrom-ToolJson (Invoke-Tool $Node @($Helper, "status", $Id, "--codex-executable", $Codex) 60)
        if ($null -eq $Status -or $Status.modified -isnot [ValueType] -or $Status.untrusted -isnot [ValueType]) {
            Add-Note "hold" "$Id hooks: their trust could not be read"
            continue
        }
        if ([int]$Status.untrusted -gt 0) {
            Add-Note "hold" "$Id hooks: a hook was never trusted; approve it explicitly (approve-codex-plugin-hooks)"
            continue
        }
        if ([int]$Status.modified -eq 0) { continue }
        # The verified identity, not a bare yes: the helper re-checks the SHA
        # and that the two trees are byte-identical in the one app server
        # session that writes trust, and carries only existing trust.
        $Approve = Invoke-Tool $Node @($Helper, "approve", $Id, "--codex-executable", $Codex) 120 @{
            ROUNDHOUSE_AUTOMATIC_HOOK_APPROVAL = "1"; ROUNDHOUSE_VERIFIED_SHA = $Sha
            ROUNDHOUSE_VERIFIED_TREE = $VerifiedTree; ROUNDHOUSE_CODEX_TREE = $CodexTree
            ROUNDHOUSE_CODEX_SOURCE_PATH = ""
        }
        if ($Approve.ExitCode -eq 0) {
            Add-Note "update" "$Id hooks: trust carried to the verified $($Sha.Substring(0, 12))"
        } else {
            Add-Note "hold" "$Id hooks: automatic approval refused (the copy is not byte-identical to Claude's verified install, or it moved)"
        }
    }
}

function Write-Status([string]$State, [string]$StartedAt) {
    $Root = Get-StateRoot
    [void][IO.Directory]::CreateDirectory($Root)
    $Bundle = Read-JsonFile (Join-Path $PSScriptRoot "bundle.json")
    $Status = [ordered]@{
        schema = "roundhouse.plugin-currency-status"; schema_version = 1
        version = if ($Bundle -and [string]$Bundle.version -match '^[0-9A-Za-z.+-]{1,64}$') { [string]$Bundle.version } else { "" }
        started_at = $StartedAt
        finished_at = if ($State -ceq "running") { "" } else { [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") }
        state = $State; updated = $Script:Updated; held = $Script:Held
        messages = [string[]]$Script:Messages.ToArray()
    }
    $Path = Join-Path $Root "status.json"
    $Next = "$Path.next"
    [IO.File]::WriteAllText($Next, (ConvertTo-Json -InputObject $Status -Depth 4), $Utf8)
    Move-Item -LiteralPath $Next -Destination $Path -Force
}

function Invoke-PluginCurrency {
    # One run. The tools are found here, or handed in by the self-test.
    param([AllowNull()][string]$Claude, [AllowNull()][string]$Codex, [AllowNull()][string]$Git,
        [AllowNull()][string]$PathNode, [string]$Helper = (Join-Path $PSScriptRoot "codex-plugin-hooks.mjs"))
    $StartedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $State = "failed"
    Write-Status "running" $StartedAt
    try {
        if ($Claude) { Update-ClaudePlugins $Claude } else { Add-Note "note" "Claude Code is not installed" }
        if ($Codex) {
            $Markets = Get-CodexMarketplaces $Codex
            $Node = Resolve-Node -PathNode $PathNode -HomeDirectory (Get-HomeDirectory) -Claude $Claude
            if ($null -eq $Node) {
                Add-Note "hold" ("no Node.js for Codex's sync and hook approval; probes: " + ($Script:NodeProbes -join "; "))
            } elseif (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) {
                Add-Note "hold" "the hook helper is missing beside this script; re-run roundhouse fleet-schedule install"
                $Node = $null
            } else {
                Sync-Codex $Node.Path $Helper $Codex $Markets $Git
            }
            Update-StaleCodexCopies $Codex $Markets
            if ($null -ne $Node) { Approve-FleetHooks $Node.Path $Helper $Codex }
        } else {
            Add-Note "note" "Codex is not installed"
        }
        $State = if ($Script:TimedOut) { "timeout" } elseif ($Script:Held -gt 0) { "held" } else { "current" }
    } catch {
        Add-Note "hold" (Get-SafeText $_.Exception.Message 200)
        $State = "failed"
    } finally {
        Write-Status $State $StartedAt
    }
    return $State
}

if ($SelfTest) {
    $FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-plugins-selftest-" + [Guid]::NewGuid().ToString("N"))
    $Saved = @{}
    foreach ($Name in @("USERPROFILE", "LOCALAPPDATA", "CLAUDE_CONFIG_DIR", "CODEX_HOME")) {
        $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name)
    }
    function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "plugins-windows self-test: $Message" } }
    function Write-Fixture([string]$Path, [object]$Value) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        $Text = if ($Value -is [string]) { $Value } else { ConvertTo-Json -InputObject $Value -Depth 8 }
        [IO.File]::WriteAllText($Path, $Text, $Utf8)
    }
    function Reset-Run { $Script:Deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds); $Script:TimedOut = $false
        $Script:Updated = 0; $Script:Held = 0; $Script:Messages.Clear(); $Script:Calls.Clear() }
    try {
        $env:USERPROFILE = Join-Path $FixtureRoot "home"
        $env:LOCALAPPDATA = Join-Path $FixtureRoot "local"
        $env:CLAUDE_CONFIG_DIR = Join-Path $FixtureRoot "home/.claude"
        $env:CODEX_HOME = Join-Path $FixtureRoot "home/.codex"
        $Old = "1" * 40; $New = "2" * 40; $Other = "3" * 40
        $ClaudeMarket = Join-Path $FixtureRoot "claude-market"
        $CodexMarket = Join-Path $FixtureRoot "codex-market"
        $ThirdMarket = Join-Path $FixtureRoot "third-market"
        $RoundhouseClaude = Join-Path $FixtureRoot "claude-cache/roundhouse"
        foreach ($Directory in @($RoundhouseClaude, (Join-Path $env:CODEX_HOME "plugins/cache/novotnyllc/roundhouse/0.9.66"),
                (Join-Path $env:CODEX_HOME "plugins/cache/novotnyllc/railyard/0.12.12"))) {
            [void][IO.Directory]::CreateDirectory($Directory)
        }
        Write-Fixture (Join-Path $env:CLAUDE_CONFIG_DIR "plugins/installed_plugins.json") @{ version = 2; plugins = [ordered]@{
            "roundhouse@novotnyllc" = @(@{ scope = "user"; version = "0.9.66"; gitCommitSha = $New; installPath = $RoundhouseClaude })
            "railyard@novotnyllc" = @(@{ scope = "user"; version = "0.12.12"; gitCommitSha = $New; installPath = $RoundhouseClaude })
            "tool@third" = @(@{ scope = "user"; version = "1.0.0"; gitCommitSha = $Old; installPath = $RoundhouseClaude })
            "local-only@third" = @(@{ scope = "project"; projectPath = "C:\x"; version = "1.0.0" })
        } }
        Write-Fixture (Join-Path $env:CLAUDE_CONFIG_DIR "plugins/known_marketplaces.json") @{
            novotnyllc = @{ source = @{ source = "github"; repo = "novotnyllc/marketplace" }; installLocation = $ClaudeMarket } }
        $RoundhouseSource = @{ source = "git-subdir"; url = "https://github.com/novotnyllc/roundhouse.git"; path = "plugins/roundhouse"; sha = $New }
        $RailyardSource = @{ source = "git-subdir"; url = "https://github.com/novotnyllc/railyard.git"; path = "plugins/railyard"; sha = $New }
        Write-Fixture (Join-Path $ClaudeMarket ".claude-plugin/marketplace.json") @{ plugins = @(
            @{ name = "roundhouse"; source = @{ source = "git-subdir"; url = "https://GitHub.com/novotnyllc/roundhouse"; path = "./plugins/roundhouse"; sha = $New } },
            @{ name = "railyard"; source = $RailyardSource }) }
        Write-Fixture (Join-Path $CodexMarket ".agents/plugins/marketplace.json") @{ plugins = @(
            @{ name = "roundhouse"; source = $RoundhouseSource }, @{ name = "railyard"; source = $RailyardSource }) }
        Write-Fixture (Join-Path $CodexMarket ".codex-marketplace-install.json") @{ ref_name = "main"; revision = $Old }
        Write-Fixture (Join-Path $ThirdMarket ".agents/plugins/marketplace.json") @{ plugins = @(
            @{ name = "tool"; source = @{ source = "git"; url = "https://example.invalid/tool.git"; sha = $New } },
            @{ name = "off"; source = @{ source = "git"; url = "https://example.invalid/off.git"; sha = $New } },
            @{ name = "current"; source = @{ source = "git"; url = "https://example.invalid/current.git"; sha = $New } }) }
        Write-Fixture (Join-Path $ThirdMarket ".codex-marketplace-install.json") @{ revision = $Old }
        $Helper = Join-Path $FixtureRoot "codex-plugin-hooks.mjs"
        Write-Fixture $Helper "// fixture"
        $FakeNode = Join-Path $FixtureRoot "path-bin/node.exe"
        Write-Fixture $FakeNode "x"

        # The tools, as one fixture dispatcher: every call is recorded, and
        # Codex's records change as `codex plugin add` would change them.
        $RealInvokeTool = ${function:Invoke-Tool}
        $Script:Calls = [Collections.Generic.List[object]]::new()
        $Script:CodexRecords = @{}
        $Script:Hooks = @{}
        $Script:Hang = ""
        function Reset-Codex {
            $Script:CodexRecords = [ordered]@{
                "roundhouse@novotnyllc" = @{ pluginId = "roundhouse@novotnyllc"; name = "roundhouse"; marketplaceName = "novotnyllc"
                    version = "0.9.61"; installed = $true; enabled = $true; source = @{ source = "git-subdir"; url = $RoundhouseSource.url; path = "plugins/roundhouse"; sha = $Old } }
                "railyard@novotnyllc" = @{ pluginId = "railyard@novotnyllc"; name = "railyard"; marketplaceName = "novotnyllc"
                    version = "0.12.12"; installed = $true; enabled = $true; source = @{ source = "git-subdir"; url = "https://github.com/someone-else/railyard.git"; path = "plugins/railyard"; sha = $New } }
                "tool@third" = @{ pluginId = "tool@third"; name = "tool"; marketplaceName = "third"; version = "1.0.0"
                    installed = $true; enabled = $true; source = @{ source = "git"; url = "https://example.invalid/tool.git"; sha = $Old } }
                "off@third" = @{ pluginId = "off@third"; name = "off"; marketplaceName = "third"; version = "1.0.0"
                    installed = $true; enabled = $false; source = @{ source = "git"; url = "https://example.invalid/off.git"; sha = $Old } }
                "current@third" = @{ pluginId = "current@third"; name = "current"; marketplaceName = "third"; version = "2.0.0"
                    installed = $true; enabled = $true; source = @{ source = "git"; url = "https://example.invalid/current.git"; sha = $New } }
            }
            $Script:Hooks = @{ "roundhouse@novotnyllc" = @{ modified = 1; untrusted = 0 }; "railyard@novotnyllc" = @{ modified = 1; untrusted = 0 } }
        }
        function Invoke-Tool {
            param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [hashtable]$Environment = @{})
            $Line = (@([IO.Path]::GetFileNameWithoutExtension($FilePath)) + $Arguments) -join " "
            $Script:Calls.Add([pscustomobject]@{ Line = $Line; Environment = $Environment.Clone() })
            $Ok = { param($Out) [pscustomobject]@{ ExitCode = 0; Stdout = $Out; TimedOut = $false } }
            if ($Script:Hang -and $Line -clike $Script:Hang) {
                $Script:TimedOut = $true
                return [pscustomobject]@{ ExitCode = -1; Stdout = ""; TimedOut = $true }
            }
            switch -wildcard ($Line) {
                "claude plugin marketplace update" { return & $Ok "" }
                "claude plugin update *" { return & $Ok "" }
                "git ls-remote -- https://github.com/novotnyllc/marketplace.git refs/heads/main*" {
                    return & $Ok "$New`trefs/heads/main`n" }
                "git ls-remote *" { return [pscustomobject]@{ ExitCode = 2; Stdout = ""; TimedOut = $false } }
                "codex plugin marketplace list --json" {
                    return & $Ok (ConvertTo-Json -Depth 6 -InputObject @{ marketplaces = @(
                        @{ name = "novotnyllc"; root = $CodexMarket; marketplaceSource = @{ sourceType = "git"; source = "https://github.com/novotnyllc/marketplace.git" } },
                        @{ name = "third"; root = $ThirdMarket; marketplaceSource = @{ sourceType = "git"; source = "https://example.invalid/third.git" } },
                        @{ name = "openai-bundled"; root = (Join-Path $FixtureRoot "bundled") }) }) }
                "codex plugin list --json" {
                    return & $Ok (ConvertTo-Json -Depth 6 -InputObject @{ installed = @($Script:CodexRecords.Values) }) }
                "codex plugin add * --json" {
                    $Id = $Arguments[2]
                    $Market = if ($Id -like "*@novotnyllc") { $CodexMarket } else { $ThirdMarket }
                    $Sha = Get-PinnedSha (Get-CatalogEntry (Read-Catalog $Market $CodexCatalogPaths) $Id.Split("@")[0])
                    $Script:CodexRecords[$Id].source.sha = $Sha
                    $Script:CodexRecords[$Id].version = $Script:CodexRecords[$Id].version + "-new"
                    if ($Id -ceq "roundhouse@novotnyllc") { $Script:CodexRecords[$Id].version = "0.9.66" }
                    return & $Ok "{}" }
                "node * sync --codex-executable codex *" { return & $Ok '{"synced":1,"missing":[],"unconfirmed":[]}' }
                "node * status * --codex-executable codex" {
                    $Counts = $Script:Hooks[$Arguments[2]]
                    return & $Ok (ConvertTo-Json -Compress -InputObject @{ pluginId = $Arguments[2]; modified = $Counts.modified; untrusted = $Counts.untrusted }) }
                "node * approve * --codex-executable codex" { return & $Ok "{}" }
            }
            return [pscustomobject]@{ ExitCode = 64; Stdout = ""; TimedOut = $false }
        }

        # --- one full run ---
        Reset-Codex
        Reset-Run
        $State = Invoke-PluginCurrency -Claude "claude" -Codex "codex" -Git "git" -PathNode $FakeNode -Helper $Helper
        $Lines = @($Script:Calls | ForEach-Object Line)
        # Claude: the catalogs, then every user-scope plugin, and nothing that
        # installs, enables or removes.
        Assert-True ($Lines -ccontains "claude plugin marketplace update") "Claude's marketplaces were not refreshed"
        foreach ($Id in @("railyard@novotnyllc", "roundhouse@novotnyllc", "tool@third")) {
            Assert-True ($Lines -ccontains "claude plugin update $Id --scope user") "Claude plugin $Id was not updated"
        }
        Assert-True (-not ($Lines -clike "*local-only@third*")) "a project-scope Claude plugin was touched"
        Assert-True (-not ($Lines | Where-Object { $_ -cmatch '^claude plugin (install|enable|disable|uninstall|remove)\b' })) "Claude was asked to install, enable or remove a plugin"
        # Codex: its own sync to the upstream head, then a reinstall of each
        # enabled copy behind its catalog — the roundhouse that a clone at
        # the latest revision left old — and of nothing else.
        Assert-True ($Lines -ccontains "node $Helper sync --codex-executable codex $CodexMarket $New") "Codex's sync was not triggered to the upstream head"
        Assert-True (-not ($Lines -clike "* sync *$ThirdMarket*")) "a marketplace with no known upstream head was synced to a guessed revision"
        Assert-True ($Lines -ccontains "codex plugin add roundhouse@novotnyllc --json") "a Codex copy older than its catalog was not reinstalled"
        Assert-True ($Lines -ccontains "codex plugin add tool@third --json") "a stale third-party Codex copy was not reinstalled"
        Assert-True (-not ($Lines -ccontains "codex plugin add off@third --json")) "a disabled Codex copy was reinstalled (and so enabled)"
        Assert-True (-not ($Lines -ccontains "codex plugin add current@third --json")) "a current Codex copy was reinstalled"
        Assert-True (-not ($Lines -ccontains "codex plugin add railyard@novotnyllc --json")) "a Codex copy at its catalog SHA was reinstalled"
        Assert-True (-not ($Lines | Where-Object { $_ -cmatch '\bupdate (roundhouse|tool|railyard)@' -and $_ -clike "node *" })) "the unverified re-trusting update ran"
        # Hooks: approval only for the fleet's own plugin whose identity is
        # verified, with that identity; railyard's copy is from another
        # source and holds; a third-party plugin is never approved.
        $Approvals = @($Script:Calls | Where-Object { $_.Line -clike "node * approve *" })
        Assert-True ($Approvals.Count -eq 1 -and $Approvals[0].Line -clike "* approve roundhouse@novotnyllc *") "approval ran for other than the verified fleet plugin"
        $Env = $Approvals[0].Environment
        Assert-True ($Env.ROUNDHOUSE_AUTOMATIC_HOOK_APPROVAL -ceq "1" -and $Env.ROUNDHOUSE_VERIFIED_SHA -ceq $New -and
            $Env.ROUNDHOUSE_VERIFIED_TREE -ceq $RoundhouseClaude -and
            $Env.ROUNDHOUSE_CODEX_TREE -ceq ([IO.Path]::Combine($env:CODEX_HOME, "plugins", "cache", "novotnyllc", "roundhouse", "0.9.66"))) "approval did not carry the verified identity"
        Assert-True ($State -ceq "held") "a run with a held item did not end held ($State)"
        $Status = Get-Content -Raw -LiteralPath (Join-Path (Get-StateRoot) "status.json") | ConvertFrom-Json
        Assert-True ($Status.schema -ceq "roundhouse.plugin-currency-status" -and $Status.state -ceq "held" -and
            $Status.updated -eq 3 -and $Status.held -eq 1 -and -not [string]::IsNullOrEmpty([string]$Status.finished_at)) "the status file does not report the run"
        Assert-True (@($Status.messages | Where-Object { $_ -clike "hold railyard@novotnyllc hooks: Codex's copy is not from the source*" }).Count -eq 1) "the status file does not name the held item"

        # A hook never trusted is the operator's; a copy not yet at the
        # catalog SHA is not approved.
        Reset-Codex
        Reset-Run
        $Script:Hooks["roundhouse@novotnyllc"] = @{ modified = 1; untrusted = 1 }
        # Codex's clone lags Claude's catalog: its copy is current for Codex
        # (no reinstall) but not at the SHA Claude's catalog pins.
        $Script:CodexRecords["railyard@novotnyllc"].source.url = $RailyardSource.url
        $Script:CodexRecords["railyard@novotnyllc"].source.sha = $Other
        $Lagging = @{ source = "git-subdir"; url = $RailyardSource.url; path = "plugins/railyard"; sha = $Other }
        Write-Fixture (Join-Path $CodexMarket ".agents/plugins/marketplace.json") @{ plugins = @(
            @{ name = "roundhouse"; source = $RoundhouseSource }, @{ name = "railyard"; source = $Lagging }) }
        [void](Invoke-PluginCurrency -Claude "claude" -Codex "codex" -Git "git" -PathNode $FakeNode -Helper $Helper)
        Assert-True (@($Script:Calls | Where-Object { $_.Line -clike "node * approve *" }).Count -eq 0) "a never-trusted hook, or a copy off the catalog SHA, was approved"
        Assert-True (@($Script:Messages | Where-Object { $_ -clike "hold railyard@novotnyllc hooks: Codex has not synced*" }).Count -eq 1) "a copy off Claude's catalog SHA was not held"

        # The run's bound: a tool that does not answer in time ends the run as
        # `timeout`, with the status written.
        Reset-Codex
        Reset-Run
        $Script:Hang = "node * sync *"
        $State = Invoke-PluginCurrency -Claude "claude" -Codex "codex" -Git "git" -PathNode $FakeNode -Helper $Helper
        $Script:Hang = ""
        Assert-True ($State -ceq "timeout" -and (Get-Content -Raw -LiteralPath (Join-Path (Get-StateRoot) "status.json") | ConvertFrom-Json).state -ceq "timeout") "a run past its bound was not reported as a timeout"

        # Node: PATH first, then Codex's bundled runtime, then Claude's.
        $FixtureHome = $env:USERPROFILE
        $Bundled = [IO.Path]::Combine($FixtureHome, ".cache", "codex-runtimes", "codex-primary-runtime", "dependencies", "node", "bin", "node.exe")
        $ClaudeExe = Join-Path $FixtureRoot "claude-bin/claude.exe"
        Write-Fixture $Bundled "x"
        Write-Fixture $ClaudeExe "x"
        Write-Fixture ([IO.Path]::Combine((Split-Path -Parent $ClaudeExe), "resources", "node.exe")) "x"
        Assert-True ((Resolve-Node -PathNode $FakeNode -HomeDirectory $FixtureHome -Claude $ClaudeExe).Source -ceq "PATH") "PATH Node did not win"
        Assert-True ((Resolve-Node -PathNode $null -HomeDirectory $FixtureHome -Claude $ClaudeExe).Path -ceq $Bundled) "Codex's bundled runtime was not second"
        Remove-Item -LiteralPath $Bundled
        Assert-True ((Resolve-Node -PathNode $null -HomeDirectory $FixtureHome -Claude $ClaudeExe).Source -ceq "CLAUDE-BUNDLED") "Claude's Node was not the last fallback"
        Assert-True ($null -eq (Resolve-Node -PathNode $null -HomeDirectory $FixtureHome -Claude $null) -and $Script:NodeProbes.Count -ge 2) "a missing Node was not reported with its probes"

        # The real bounded child: its output, and a kill past its bound.
        Set-Item -Path Function:\Invoke-Tool -Value $RealInvokeTool
        Reset-Run
        $Self = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $Echo = Invoke-Tool $Self @("-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Write-Output `$env:RH_PROBE") 60 @{ RH_PROBE = "probe value" }
        Assert-True ($Echo.ExitCode -eq 0 -and $Echo.Stdout.Trim() -ceq "probe value") "a bounded child's output or environment was lost"
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        $Slow = Invoke-Tool $Self @("-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30") 2
        Assert-True ($Slow.TimedOut -and $Watch.Elapsed.TotalSeconds -lt 20 -and $Script:TimedOut) "a child past its bound was not stopped"
    } finally {
        foreach ($Name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output "PASS: plugins-windows fixture-safe self-check"
    exit 0
}

# One mutual exclusion beside the task's own IgnoreNew: a run started by
# hand while the scheduled one runs leaves it alone.
$Mutex = [Threading.Mutex]::new($false, "Local\RoundhousePluginCurrency")
if (-not $Mutex.WaitOne(0)) {
    Write-Output "roundhouse: another plugin currency run is in progress"
    exit 75
}
try {
    $Claude = Find-Tool @("claude", "claude.exe") @((Join-Path (Get-HomeDirectory) ".local\bin\claude.exe"))
    $Codex = Find-Tool @("codex", "codex.exe") @(
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin\codex.exe" }))
    $Git = Find-Tool @("git", "git.exe") @(
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "Git\cmd\git.exe" }))
    $PathNode = Find-Tool @("node", "node.exe") @()
    $State = Invoke-PluginCurrency -Claude $Claude -Codex $Codex -Git $Git -PathNode $PathNode
} finally {
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}
Write-Output "roundhouse: plugin currency $State"
exit $(switch ($State) { "current" { 0 } "held" { 75 } "timeout" { 75 } default { 70 } })
