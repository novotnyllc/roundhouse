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
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$PluginRoot = Split-Path -Parent $PSScriptRoot
$CollectScript = Join-Path $PSScriptRoot "collect-windows.ps1"
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
    $ExpectedFiles = @($Expected.files | Sort-Object path)
    $ActualFiles = @($Actual.files | Sort-Object path)
    if ($ExpectedFiles.Count -ne $ActualFiles.Count) { throw "$Label file list does not match" }
    for ($Index = 0; $Index -lt $ExpectedFiles.Count; $Index++) {
        if ($ExpectedFiles[$Index].path -ne $ActualFiles[$Index].path -or
            $ExpectedFiles[$Index].sha256 -ne $ActualFiles[$Index].sha256) {
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
        files = @($Files | Sort-Object path)
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
        $ExpectedOperationProperties = if ([string]$Operation.type -eq "package-upgrade") {
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
        if ($HasTargets -and [string]$Operation.type -ne "chezmoi-apply") {
            throw "Only chezmoi apply may declare targets"
        }
        if ($HasTargets) { [void](Get-ChezmoiTargets $Operation) }
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
    $Output = @(& $Command.Source status -- $Targets)
    $Succeeded = $?
    $ExitCode = $LASTEXITCODE
    if (-not $Succeeded -or ($null -ne $ExitCode -and $ExitCode -ne 0)) {
        throw "Chezmoi target status failed"
    }
    $HasDrift = $Output.Count -gt 0
    if ($HasDrift -ne $ExpectDrift) { throw "Chezmoi targets did not reach the expected status" }
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

function Invoke-Exact([string[]]$Argv) {
    $Command = Get-Command $Argv[0] -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $Command) { throw "Required command is unavailable: $($Argv[0])" }
    & $Command.Source @($Argv | Select-Object -Skip 1) *> $null
    $Succeeded = $?
    $NativeExitCode = $LASTEXITCODE
    if (-not $Succeeded -or ($null -ne $NativeExitCode -and $NativeExitCode -ne 0)) {
        $Failure = [InvalidOperationException]::new("Native command failed: $($Argv[0])")
        $Failure.Data["ExitCode"] = $(if ($null -eq $NativeExitCode) { 1 } else { [int]$NativeExitCode })
        throw $Failure
    }
    return $(if ($null -eq $NativeExitCode) { 0 } else { [int]$NativeExitCode })
}

function Invoke-CodexPluginHooks([string]$Action, [string]$PluginId) {
    if ($Action -notin @("approve", "update")) { throw "Invalid Codex hook action" }
    if ($PluginId -notmatch "^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$") {
        throw "Invalid Codex plugin ID"
    }
    $Node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $Node) { throw "Node.js is required for Codex plugin hook refresh" }
    $Helper = Join-Path $PSScriptRoot "codex-plugin-hooks.mjs"
    Assert-RegularFile $Helper "Codex plugin hook helper" | Out-Null
    & $Node.Source $Helper $Action $PluginId *> $null
    $Succeeded = $?
    $NativeExitCode = $LASTEXITCODE
    if (-not $Succeeded -or ($null -ne $NativeExitCode -and $NativeExitCode -ne 0)) {
        $Failure = [InvalidOperationException]::new("Codex plugin hook operation failed")
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
    return $Message
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

function Assert-Postcondition([object]$Operation, [object[]]$Before, [object[]]$After) {
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
                throw "Winget did not reach the sealed candidate version"
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
                throw "Chezmoi still reports drift after apply"
            }
        }
    }
}

function Write-Result([object[]]$Records) {
    Assert-ResultPath
    $Directory = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
    $Temporary = Join-Path $Directory (".machine-utilities-" + [Guid]::NewGuid().ToString("N"))
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
    return [ordered]@{
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
        errors = $(if ($Completed) {
            @()
        } else {
            @(@{
                code = "operation_failed"
                severity = "error"
                retryable = $true
                message = [string]$Result.message
            })
        })
    }
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
        errors = $(if ($Completed) {
            @()
        } else {
            @(@{
                code = "apply_partial"
                severity = "error"
                retryable = $true
                message = [string]$Failure.message
            })
        })
    }
}

if ($SelfTest) {
    $SelfTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("machine-utilities-selftest-" + [Guid]::NewGuid().ToString("N"))
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
        $ChezmoiPullArgv = @(Get-ExactArgv ([pscustomobject]@{
            type = "chezmoi-pull"; kind = "file"; id = "chezmoi:source"
        }) $null $null)
        if ((ConvertTo-CanonicalJson $ChezmoiPullArgv) -ne
            '["chezmoi","git","--","pull","--ff-only"]') {
            throw "Chezmoi pull argv self-test failed"
        }
        $TargetedChezmoiArgv = @(Get-ExactArgv ([pscustomobject]@{
            type = "chezmoi-apply"; kind = "chezmoi_state"; id = "live"
            targets = @("C:\Users\Claire\.profile.d\10-env.sh", "C:\Users\Claire\.zprofile.d\10-env.zsh")
        }) $null $null)
        if ((ConvertTo-CanonicalJson $TargetedChezmoiArgv) -ne
            '["chezmoi","--no-tty","apply","--","C:\\Users\\Claire\\.profile.d\\10-env.sh","C:\\Users\\Claire\\.zprofile.d\\10-env.zsh"]') {
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
                argv = @("chezmoi", "--no-tty", "apply", "--", "C:\Users\Claire\.profile.d\10-env.sh")
                targets = @("C:\Users\Claire\.profile.d\10-env.sh")
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
                targets = @("C:\Users\Claire\.profile.d\10-env.sh")
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
            & $Git.Source -C $SeedPath -c user.name=machine-utilities `
                -c user.email=machine-utilities@example.invalid commit --quiet -m fixture
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
    [void](Invoke-CodexPluginHooks "approve" $ApproveCodexPluginHooks)
    [ordered]@{ pluginId = $ApproveCodexPluginHooks; approved = $true } |
        ConvertTo-Json -Compress
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
            throw "Winget candidate no longer matches the sealed plan"
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
    try {
        if ($Operation.type -in @("project-clone", "project-update")) {
            Prepare-ProjectMutationPath $Operation $Config $Machine
        }
        if ($Operation.type -eq "agent-update" -and [string]$Operation.id -like "codex:*") {
            $ExitCode = Invoke-CodexPluginHooks "update" $ExpectedArgv[3]
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
        })
    } catch {
        $ExitCode = $null
        if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains("ExitCode")) {
            $ExitCode = [int]$_.Exception.Data["ExitCode"]
        }
        $Failure = [ordered]@{
            operation = $Operation
            index = $Index
            exit_code = $ExitCode
            operation_status = "failed"
            stage = "execute"
            message = Get-SafeFailureMessage $_
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
            Assert-Postcondition @($Plan.operations)[$Index] $Before $After
        } catch {
            $Result = $OperationResults[$Index]
            $Result.operation_status = "failed"
            $Result.stage = "verify"
            $Result.message = Get-SafeFailureMessage $_
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
    [Console]::Error.WriteLine("roundhouse: Windows apply failed at $($Failure.stage)")
    exit 70
}
