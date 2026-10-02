# Roundhouse WSL interop launcher for native Windows.
#
# The controller sends these exact, integrity-verified bytes together with one
# bounded request on standard input to a fixed bootstrap that the configured
# `wsl_interop_via` sibling starts as full-path `pwsh.exe -EncodedCommand`
# from `/mnt/c`. The process is a native Windows process holding the
# logged-in user's token; WSL is only the launcher and never supplies
# evidence.
#
# This launcher carries no inventory or mutation logic of its own. It finds
# the INSTALLED Roundhouse executor whose version equals the controller's,
# stages the controller-bounded inputs in a private temporary directory,
# requires that executor's own `apply-windows.ps1 -VerifyExecutor` to accept
# the controller's integrity requirement, and only then runs that executor's
# collector or sealed-plan worker. The staging directory is always removed.
# The single result envelope is the last stdout line, prefixed by a marker.
[CmdletBinding()]
param(
    [object]$Request,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
# Child executor processes report errors as plain text, never ANSI styling.
$env:NO_COLOR = "1"
$Utf8 = [Text.UTF8Encoding]::new($false)
$ResultMarker = "roundhouse-interop-result "
$MaximumStagedFileBytes = 16777216
$Sections = @("all", "host", "packages", "agents", "auth", "projects", "startup", "chezmoi")

function Test-Pattern([object]$Value, [string]$Pattern) {
    return $Value -is [string] -and $Value -cmatch $Pattern
}

function Get-PropertyNames([object]$Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return @() }
    $Names = @($Value.PSObject.Properties.Name)
    [Array]::Sort($Names, [StringComparer]::Ordinal)
    return $Names
}

function Get-SafeMessage([object]$ErrorRecord) {
    $Text = [string]$ErrorRecord.Exception.Message
    $Text = $Text -replace '[\x00-\x1f\x7f-\x9f]', ' '
    if ($Text.Length -gt 1024) { $Text = $Text.Substring(0, 1024) }
    return $Text
}

function Get-BytesSha256([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Assert-Request([object]$Value) {
    $Base = @("controller_configuration_digest", "files", "host_id", "mode", "schema", "schema_version")
    if ($null -eq $Value -or $Value.schema -cne "roundhouse.interop-request" -or
        $Value.schema_version -ne 1 -or -not (Test-Pattern $Value.mode '^(collect|apply)$') -or
        -not (Test-Pattern $Value.host_id '^[A-Za-z0-9._-]+$') -or
        -not (Test-Pattern $Value.controller_configuration_digest '^[0-9a-f]{64}$')) {
        throw "Invalid interop request"
    }
    if ($Value.mode -ceq "collect") {
        $Expected = @($Base + @("allow_auth_verify", "sections", "snapshot_id"))
        $FileNames = @("config", "executor")
        $Requested = @($Value.sections)
        if (-not (Test-Pattern $Value.snapshot_id '^[A-Za-z0-9._-]{1,128}$') -or
            $Value.allow_auth_verify -isnot [bool] -or $Requested.Count -eq 0 -or
            $Requested.Count -gt $Sections.Count -or
            @($Requested | Where-Object { -not (Test-Pattern $_ '^[a-z]+$') -or $_ -cnotin $Sections }).Count -gt 0) {
            throw "Invalid interop collect request"
        }
    } else {
        $Expected = @($Base + @("plan_id"))
        $FileNames = @("config", "executor", "plan")
        if (-not (Test-Pattern $Value.plan_id '^plan-[0-9a-f]{16}$')) { throw "Invalid interop apply request" }
    }
    [Array]::Sort($Expected, [StringComparer]::Ordinal)
    [Array]::Sort($FileNames, [StringComparer]::Ordinal)
    if (((Get-PropertyNames $Value) -join "`0") -cne ($Expected -join "`0") -or
        ((Get-PropertyNames $Value.files) -join "`0") -cne ($FileNames -join "`0")) {
        throw "Interop request has unexpected fields"
    }
    foreach ($Name in $FileNames) {
        $File = $Value.files.$Name
        if (((Get-PropertyNames $File) -join "`0") -cne "base64`0sha256" -or
            -not (Test-Pattern $File.sha256 '^[0-9a-f]{64}$') -or
            -not (Test-Pattern $File.base64 '^[A-Za-z0-9+/]*={0,2}$')) {
            throw "Invalid interop request file: $Name"
        }
    }
}

function Get-RequestFileBytes([object]$File, [string]$Name) {
    $Bytes = [Convert]::FromBase64String([string]$File.base64)
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $MaximumStagedFileBytes) {
        throw "Interop request file has an invalid size: $Name"
    }
    if ((Get-BytesSha256 $Bytes) -cne [string]$File.sha256) {
        throw "Interop request file does not match its declared SHA-256: $Name"
    }
    return ,$Bytes
}

function New-PrivateStage {
    $Path = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-interop-" + [Guid]::NewGuid().ToString("N"))
    if ($IsWindows) {
        Add-Type -AssemblyName System.IO.FileSystem.AccessControl
        $Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $Security = [Security.AccessControl.DirectorySecurity]::new()
        # Protected and owner-only: nothing is inherited from the parent.
        $Security.SetAccessRuleProtection($true, $false)
        $Security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $Sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow))
        if (Test-Path -LiteralPath $Path) { throw "Interop staging path already exists" }
        [void][IO.FileSystemAclExtensions]::CreateDirectory($Security, $Path)
        $Rules = @((Get-Acl -LiteralPath $Path).Access)
        if (-not (Get-Acl -LiteralPath $Path).AreAccessRulesProtected -or $Rules.Count -ne 1 -or
            $Rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -ne $Sid) {
            throw "Interop staging directory is not private to the current user"
        }
    } else {
        [void][IO.Directory]::CreateDirectory($Path, [IO.UnixFileMode]"UserRead, UserWrite, UserExecute")
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if (-not $Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Interop staging directory is not a regular directory"
    }
    return $Item.FullName
}

function Get-ExecutorRoots([string]$Marketplace, [string]$Version) {
    $UserProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($UserProfile)) { throw "Windows user profile is unavailable" }
    $Roots = New-Object System.Collections.Generic.List[string]
    $Versions = New-Object System.Collections.Generic.List[string]
    # Same order as the SSH worker: the Codex cache first, then Claude's.
    foreach ($Harness in @(".codex", ".claude")) {
        $Base = Join-Path $UserProfile $Harness "plugins" "cache" $Marketplace "roundhouse"
        if (-not (Test-Path -LiteralPath $Base -PathType Container)) { continue }
        foreach ($Item in @(Get-ChildItem -LiteralPath $Base -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($Item.Name -cmatch '^[0-9A-Za-z.+-]{1,64}$') { $Versions.Add($Item.Name) }
            if ($Item.Name -ceq $Version -and
                ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $Roots.Add($Item.FullName)
            }
        }
    }
    # A diagnostic only: capped at the 64 entries the controller's envelope
    # check accepts, so a long cache history never voids a valid result.
    return @{ Roots = @($Roots); Versions = @($Versions | Sort-Object -Unique | Select-Object -Last 64) }
}

function Invoke-ChildPowerShell([string]$Pwsh, [string[]]$Arguments) {
    # A separate native process, as the Codex protocol runs the executor.
    # Its stderr is captured so a refusal reaches the controller as one
    # plain-text reason rather than raw console output: the last stderr line,
    # which the apply worker makes its sanitized failure summary.
    $Output = @(& $Pwsh -NoLogo -NoProfile -NonInteractive @Arguments 2>&1)
    $ExitCode = $LASTEXITCODE
    $Stderr = @($Output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } |
        ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $Reason = if ($Stderr.Count -gt 0) { ($Stderr[-1] -replace '^\s*\|\s*', '').Trim() } else { "" }
    $Reason = $Reason -replace '[\x00-\x1f\x7f-\x9f]', ' '
    # Room for the apply worker's bounded failure detail (at most 2560
    # characters plus its prefix) while every envelope message the controller
    # builds from it stays under the envelope's 4096-character limit.
    if ($Reason.Length -gt 3072) { $Reason = $Reason.Substring(0, 3072) }
    return @{
        ExitCode = $ExitCode
        Stdout = @($Output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        Reason = $Reason
    }
}

function Test-InstalledExecutor([string]$Pwsh, [string]$Root, [string]$RequirementPath, [object]$Required) {
    $ApplyScript = Join-Path $Root "scripts" "apply-windows.ps1"
    $Manifest = Join-Path $Root "integrity.json"
    # Not one installed byte executes before it matches the requirement: the
    # verifier itself and the manifest it checks against are hashed here
    # first, then the verified verifier checks every other file.
    $ApplyEntry = @($Required.files | Where-Object { $_.path -ceq "scripts/apply-windows.ps1" })
    foreach ($Pair in @(@($ApplyScript, [string]$ApplyEntry[0].sha256), @($Manifest, [string]$Required.integrity_manifest_sha256))) {
        if (-not (Test-Path -LiteralPath $Pair[0] -PathType Leaf)) { return "installed executor is incomplete" }
        $Item = Get-Item -LiteralPath $Pair[0] -Force
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-FileHash -LiteralPath $Pair[0] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pair[1]) {
            return "installed $($Item.Name) does not match the controller"
        }
    }
    $Child = Invoke-ChildPowerShell $Pwsh @("-File", $ApplyScript, "-VerifyExecutor",
        "-ExecutorRequirementPath", $RequirementPath)
    if ($Child.ExitCode -ne 0) { return $(if ($Child.Reason) { $Child.Reason } else { "verification exited $($Child.ExitCode)" }) }
    try { $Status = ($Child.Stdout -join "`n") | ConvertFrom-Json } catch { return "verification returned no status" }
    if ($Status.verified -eq $true -and $Status.plugin -ceq "roundhouse" -and
        $Status.marketplace -ceq [string]$Required.marketplace -and
        $Status.version -ceq [string]$Required.version -and
        $Status.integrity_manifest_sha256 -ceq [string]$Required.integrity_manifest_sha256) {
        return ""
    }
    return "verification status does not match the requirement"
}

function Write-Envelope([string]$State, [string]$Message, [string]$Jsonl, [string[]]$Installed, [bool]$StageRemoved) {
    $Envelope = [ordered]@{
        schema = "roundhouse.interop-result"
        schema_version = 1
        state = $State
        message = $Message
        installed_versions = @($Installed | Where-Object { -not [string]::IsNullOrEmpty($_) })
        stage_removed = $StageRemoved
        jsonl = $Jsonl
    }
    $Json = ConvertTo-Json -InputObject $Envelope -Compress -Depth 5
    # A leading newline keeps the marker at the start of a line even if a
    # native tool left partial output on stdout.
    [Console]::Out.Write("`n" + $ResultMarker + [Convert]::ToBase64String($Utf8.GetBytes($Json)) + "`n")
    [Console]::Out.Flush()
}

function Invoke-InteropRequest([object]$Value) {
    $Result = @{ State = "failed"; Message = ""; Jsonl = ""; Installed = @(); StageRemoved = $true }
    $Stage = $null
    try {
        Assert-Request $Value
        $ExecutorBytes = Get-RequestFileBytes $Value.files.executor "executor"
        $Required = $Utf8.GetString($ExecutorBytes) | ConvertFrom-Json
        if ($Required.schema -cne "roundhouse.executor" -or $Required.plugin -cne "roundhouse" -or
            -not (Test-Pattern $Required.marketplace '^[A-Za-z0-9][A-Za-z0-9._-]*$') -or
            -not (Test-Pattern $Required.version '^[0-9]+\.[0-9]+\.[0-9]+$') -or
            -not (Test-Pattern $Required.integrity_manifest_sha256 '^[0-9a-f]{64}$') -or
            @($Required.files | Where-Object {
                $_.path -ceq "scripts/apply-windows.ps1" -and (Test-Pattern $_.sha256 '^[0-9a-f]{64}$')
            }).Count -ne 1) {
            throw "Invalid executor requirement"
        }
        $Found = Get-ExecutorRoots ([string]$Required.marketplace) ([string]$Required.version)
        $Result.Installed = @($Found.Versions)
        if (@($Found.Roots).Count -eq 0) {
            $Result.State = "executor_update_required"
            $Result.Message = "no installed roundhouse $($Required.version) executor from $($Required.marketplace)"
            return $Result
        }

        $Stage = New-PrivateStage
        $Result.StageRemoved = $false
        $Paths = @{}
        foreach ($Name in @($Value.files.PSObject.Properties.Name)) {
            $Bytes = Get-RequestFileBytes $Value.files.$Name $Name
            $Paths[$Name] = Join-Path $Stage "$Name.json"
            [IO.File]::WriteAllBytes($Paths[$Name], $Bytes)
        }

        $Pwsh = [Environment]::ProcessPath
        if ([string]::IsNullOrWhiteSpace($Pwsh)) { $Pwsh = (Get-Process -Id $PID).Path }
        $Root = $null
        $Refusal = ""
        foreach ($Candidate in @($Found.Roots)) {
            $Refusal = Test-InstalledExecutor $Pwsh $Candidate $Paths["executor"] $Required
            if ($Refusal -ceq "") {
                $Root = $Candidate
                break
            }
        }
        if ($null -eq $Root) {
            $Result.State = "executor_update_required"
            $Result.Message = "installed roundhouse $($Required.version) failed integrity verification against the controller: $Refusal"
            return $Result
        }

        if ($Value.mode -ceq "collect") {
            $Arguments = @{
                ConfigPath = $Paths["config"]
                HostId = [string]$Value.host_id
                ControllerConfigDigest = [string]$Value.controller_configuration_digest
                SnapshotId = [string]$Value.snapshot_id
                Sections = [string[]]@($Value.sections)
            }
            if ($Value.allow_auth_verify -eq $true) { $Arguments["AllowAuthVerify"] = $true }
            $Lines = @(& (Join-Path $Root "scripts" "collect-windows.ps1") @Arguments)
            if ($Lines.Count -eq 0 -or @($Lines | Where-Object { $_ -isnot [string] }).Count -gt 0) {
                throw "Windows collector returned no inventory records"
            }
            $Result.Jsonl = ($Lines -join "`n") + "`n"
            $Result.State = "completed"
        } else {
            $ResultPath = Join-Path $Stage "result.jsonl"
            $Child = Invoke-ChildPowerShell $Pwsh @("-File", (Join-Path $Root "scripts" "apply-windows.ps1"),
                "-ConfigPath", $Paths["config"], "-PlanPath", $Paths["plan"],
                "-ExpectedPlanFileSha256", [string]$Value.files.plan.sha256,
                "-ExecutorRequirementPath", $Paths["executor"], "-PlanId", [string]$Value.plan_id,
                "-HostId", [string]$Value.host_id,
                "-ControllerConfigDigest", [string]$Value.controller_configuration_digest,
                "-ResultPath", $ResultPath)
            if (Test-Path -LiteralPath $ResultPath -PathType Leaf) {
                $Result.Jsonl = [IO.File]::ReadAllText($ResultPath, $Utf8)
                $Result.State = $(if ($Child.ExitCode -eq 0) { "completed" } else { "partial" })
                if ($Child.ExitCode -ne 0) {
                    $Result.Message = "Windows apply worker exited $($Child.ExitCode): $($Child.Reason)"
                }
            } else {
                $Result.Message = "Windows apply worker returned no result (exit $($Child.ExitCode)): $($Child.Reason)"
            }
        }
    } catch {
        $Result.State = "failed"
        $Result.Message = Get-SafeMessage $_
    } finally {
        if ($null -ne $Stage) {
            try {
                Remove-Item -LiteralPath $Stage -Recurse -Force
                $Result.StageRemoved = -not (Test-Path -LiteralPath $Stage)
            } catch {
                $Result.StageRemoved = $false
            }
        }
    }
    return $Result
}

if ($SelfTest) {
    $Digest = "0" * 64
    $Payload = $Utf8.GetBytes("{}")
    $File = [pscustomobject]@{ base64 = [Convert]::ToBase64String($Payload); sha256 = (Get-BytesSha256 $Payload) }
    $Valid = [pscustomobject]@{
        schema = "roundhouse.interop-request"; schema_version = 1; mode = "collect"; host_id = "host-1"
        controller_configuration_digest = $Digest; snapshot_id = "snapshot-1"; sections = @("host")
        allow_auth_verify = $false; files = [pscustomobject]@{ config = $File; executor = $File }
    }
    Assert-Request $Valid
    $Mutations = @(
        { param($R) $R.mode = "shell" },
        { param($R) $R.host_id = "../host" },
        { param($R) $R.controller_configuration_digest = "A" * 64 },
        { param($R) $R.sections = @("all", "registry") },
        { param($R) $R.allow_auth_verify = "true" },
        { param($R) $R | Add-Member -NotePropertyName argv -NotePropertyValue @("cmd") },
        { param($R) $R.files | Add-Member -NotePropertyName plan -NotePropertyValue $File },
        { param($R) $R.files = [pscustomobject]@{ config = $File } }
    )
    foreach ($Mutation in $Mutations) {
        $Copy = ConvertTo-Json -InputObject $Valid -Depth 5 | ConvertFrom-Json
        & $Mutation $Copy
        $Rejected = $false
        try { Assert-Request $Copy } catch { $Rejected = $true }
        if (-not $Rejected) { throw "Self-test accepted an invalid interop request: $Mutation" }
    }
    $Tampered = [pscustomobject]@{ base64 = $File.base64; sha256 = "1" * 64 }
    $Rejected = $false
    try { [void](Get-RequestFileBytes $Tampered "config") } catch { $Rejected = $true }
    if (-not $Rejected) { throw "Self-test accepted a staged file with the wrong SHA-256" }
    $Stage = New-PrivateStage
    try {
        if (-not $IsWindows -and ((Get-Item -LiteralPath $Stage).UnixFileMode -ne [IO.UnixFileMode]"UserRead, UserWrite, UserExecute")) {
            throw "Self-test staging directory is not owner-only"
        }
    } finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force
    }
    if (Test-Path -LiteralPath $Stage) { throw "Self-test staging directory was not removed" }
    Write-Output "PASS: interop-windows launcher self-check"
    exit 0
}

$Outcome = Invoke-InteropRequest $Request
Write-Envelope $Outcome.State $Outcome.Message $Outcome.Jsonl ([string[]]@($Outcome.Installed)) $Outcome.StageRemoved
