[CmdletBinding(DefaultParameterSetName = "Status")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Status")][switch]$Status,
    [Parameter(Mandatory = $true, ParameterSetName = "Enroll")][switch]$Enroll,
    [Parameter(Mandatory = $true, ParameterSetName = "Enroll")][string]$HostId,
    [Parameter(ParameterSetName = "Enroll")][switch]$Elevated,
    [Parameter(ParameterSetName = "Enroll")][string]$OwnerSid = "",
    [Parameter(ParameterSetName = "Enroll")][string]$PluginRoot = "",
    [Parameter(ParameterSetName = "Enroll")][string]$ReceiptPath = "",
    [Parameter(Mandatory = $true, ParameterSetName = "Revoke")][switch]$Revoke,
    [Parameter(Mandatory = $true, ParameterSetName = "Dispatch")][switch]$Dispatch,
    [Parameter(Mandatory = $true, ParameterSetName = "Candidate")][switch]$Candidate,
    [Parameter(Mandatory = $true, ParameterSetName = "Lookup")][switch]$Lookup,
    [Parameter(Mandatory = $true, ParameterSetName = "Lookup")]
    [Parameter(ParameterSetName = "Request")][string]$RequestId = "",
    [Parameter(Mandatory = $true, ParameterSetName = "Request")][switch]$Request,
    [Parameter(Mandatory = $true, ParameterSetName = "Request")][string]$Action,
    [Parameter(Mandatory = $true, ParameterSetName = "Candidate")]
    [Parameter(ParameterSetName = "Request")][string]$Package = "-",
    [Parameter(ParameterSetName = "Request")][string]$Version = "-",
    [Parameter(ParameterSetName = "Candidate")]
    [Parameter(ParameterSetName = "Request")][string]$Source = "-",
    [Parameter(ParameterSetName = "Request")][string]$PayloadSha256 = "-",
    [Parameter(ParameterSetName = "Request")][string]$PlanId = "fleet-run",
    [Parameter(ParameterSetName = "Request")][string]$PlanSha256 = "-",
    [Parameter(ParameterSetName = "Request")][string]$OperationIndex = "-",
    [Parameter(ParameterSetName = "Request")][int]$Wait = 600,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

# roundhouse — the local privilege lane (Windows).
#
# One UAC consent per host installs a LocalSystem scheduled task, a
# SYSTEM-owned copy of this script, the pinned WinGet client module, and an
# owner-writable request queue. From then on machine-scope winget work runs
# unattended: the owner (through the ordinary WSL interop lane) writes a
# closed, semantic request into the queue and starts the task; SYSTEM moves
# the request out of the owner's reach, validates it, performs the one
# provider operation the action stands for, and publishes a digest-bound
# result. No S4U, no stored password, no request account, no certificate.
#
# Trust model, catalog and residual risks:
# docs/specs/2026-10-01-hands-off-privilege-lane.md

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Ascii = [Text.Encoding]::ASCII
$script:TaskName = "RoundhouseLaneV1"
$script:LaneDirectoryName = "Roundhouse-Lane"
$script:ScriptName = "privilege-lane-windows.ps1"
$script:PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
$script:MaximumRequestBytes = 8192
$script:MaximumRequestsPerDispatch = 32
$script:MaximumRequestsPerHour = 32
$script:MaximumRequestAge = 600
$script:MaximumRequestTtl = 3600
$script:MaximumFutureSkew = 60
$script:RetainSeconds = 604800
$script:TaskCreateOrUpdate = 0x6
$script:TaskDontAddPrincipalAce = 0x10
$script:TaskLogonServiceAccount = 0x5
$script:TaskSecurityInformation = 0x7
$script:SystemSid = "S-1-5-18"
$script:Fixture = $false
$script:LaneRoot = $null
$script:Native = $null

# --- records ------------------------------------------------------------------
function Get-Sha256Bytes([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $Hasher.Dispose() }
}
function Get-Sha256Text([string]$Text) { return Get-Sha256Bytes $script:Ascii.GetBytes($Text) }
function Get-Sha256File([string]$Path) { return Get-Sha256Bytes ([IO.File]::ReadAllBytes($Path)) }
function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function ConvertFrom-CanonicalAsciiBytes([byte[]]$Bytes, [int]$MaximumBytes, [string]$Label) {
    if ($Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or $Bytes[-1] -ne 10) { throw "invalid_$Label" }
    foreach ($Byte in $Bytes) {
        if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { throw "invalid_$Label" }
    }
    $Text = $script:Ascii.GetString($Bytes)
    return [string[]]@($Text.Substring(0, $Text.Length - 1).Split("`n"))
}
function ConvertTo-CanonicalAsciiBytes([string[]]$Lines) {
    foreach ($Line in $Lines) {
        if ($Line -cnotmatch '\A[\x20-\x7e]*\z') { throw "non_ascii_record" }
    }
    return $script:Ascii.GetBytes(($Lines -join "`n") + "`n")
}
function Read-FixedFields([string[]]$Lines, [string[]]$Names, [string]$Header, [string]$Trailer, [string]$Label) {
    if ($Lines.Count -ne $Names.Count + 2 -or $Lines[0] -cne $Header -or $Lines[-1] -cne $Trailer) { throw "invalid_$Label" }
    $Result = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Parts[1].Length -gt 4096) { throw "invalid_$Label" }
        $Result[$Parts[0]] = $Parts[1]
    }
    return $Result
}
$script:QuietRecords = $false
function Write-Record([string[]]$Lines) {
    if ($script:QuietRecords) { return }
    [Console]::Out.Write($script:Ascii.GetString((ConvertTo-CanonicalAsciiBytes $Lines)))
}

function Test-Token([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' }
function Test-RequestId([string]$Value) { return $Value -cmatch '^request-[0-9a-f]{32}$' }
function Test-Digest([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }
function Test-DigestOrDash([string]$Value) { return $Value -ceq "-" -or (Test-Digest $Value) }
function Test-UInt([string]$Value) { return $Value -cmatch '^(0|[1-9][0-9]{0,18})$' }
function Test-UIntOrDash([string]$Value) { return $Value -ceq "-" -or (Test-UInt $Value) }
function Test-VersionToken([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,127}$' }
function Test-VersionOrDash([string]$Value) { return $Value -ceq "-" -or (Test-VersionToken $Value) }
function Test-PluginVersion([string]$Value) { return $Value -cmatch '^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$' }
function Test-Sid([string]$Value) { return $Value -cmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' }
function Test-WinGetId([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$' }
function Test-PlanId([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' }
function Test-WindowsAbsolutePath([string]$Path) {
    return $Path -cmatch '^[A-Za-z]:\\[^:*?"<>|\r\n]+$' -and $Path -notmatch '(?:^|\\)\.\.?(?:\\|$)'
}

$script:Actions = [string[]]@("winget.inventory-machine.v1", "winget.install-machine-package.v1",
    "winget.upgrade-machine-package.v1", "lane.probe.v1", "lane.self-upgrade.v1")

# --- identity -----------------------------------------------------------------
$script:IdentityFields = [string[]]@("host-id", "platform", "owner-sid", "owner-name", "plugin-root",
    "marketplace", "plugin", "lane-version", "lane-sha256", "enrolled-at", "activation")
function Get-LanePaths {
    $Root = $script:LaneRoot
    return [pscustomobject]@{
        Root = $Root
        Script = Join-Path $Root $script:ScriptName
        Identity = Join-Path $Root "lane.identity"
        Ingress = Join-Path $Root "queue\ingress"
        Results = Join-Path $Root "queue\results"
        Claims = Join-Path $Root "claims"
        Journal = Join-Path $Root "journal"
        JournalLog = Join-Path $Root "journal\events.log"
        Module = Join-Path $Root "winget\Microsoft.WinGet.Client"
        ModuleLock = Join-Path $Root "windows-winget-provider.lock"
        Lock = Join-Path $Root "claims\.lock"
    }
}
function Render-Identity([hashtable]$Values) {
    $Lines = @("lane-identity|1")
    foreach ($Name in $script:IdentityFields) { $Lines += "$Name|$($Values[$Name])" }
    $Lines += "end-identity|"
    return ConvertTo-CanonicalAsciiBytes $Lines
}
function Read-Identity([string]$Path) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 4096 "identity") `
        $script:IdentityFields "lane-identity|1" "end-identity|" "identity"
    if (-not (Test-Token $Fields.'host-id') -or $Fields.platform -cne "windows" -or
        -not (Test-Sid $Fields.'owner-sid') -or $Fields.'owner-sid' -ceq $script:SystemSid -or
        $Fields.'owner-name'.Length -lt 1 -or -not (Test-Token $Fields.marketplace) -or
        -not (Test-Token $Fields.plugin) -or -not (Test-PluginVersion $Fields.'lane-version') -or
        -not (Test-Digest $Fields.'lane-sha256') -or -not (Test-UInt $Fields.'enrolled-at') -or
        $Fields.activation -cnotin @("pending", "passed") -or
        ($Fields.'plugin-root' -cne "-" -and -not $script:Fixture -and -not (Test-WindowsAbsolutePath $Fields.'plugin-root'))) {
        throw "invalid_identity"
    }
    return $Fields
}

# --- request and result records -----------------------------------------------
$script:RequestFields = [string[]]@("request-id", "host-id", "owner", "plan-id", "plan-sha256",
    "operation-index", "action-id", "package", "version", "source", "payload-sha256", "created-at", "expires-at")
function Render-Request([hashtable]$Values) {
    $Lines = @("lane-request|1")
    foreach ($Name in $script:RequestFields) { $Lines += "$Name|$($Values[$Name])" }
    $Lines += "end-request|"
    $Body = ConvertTo-CanonicalAsciiBytes $Lines
    $Digest = Get-Sha256Bytes $Body
    return ConvertTo-CanonicalAsciiBytes ($Lines + @("request-sha256|$Digest"))
}
function Read-Request([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes $script:MaximumRequestBytes "request"
    if ($Lines.Count -ne 16) { throw "invalid_request" }
    $Fields = Read-FixedFields $Lines[0..14] $script:RequestFields "lane-request|1" "end-request|" "request"
    $DigestParts = $Lines[15].Split('|')
    if ($DigestParts.Count -ne 2 -or $DigestParts[0] -cne "request-sha256" -or -not (Test-Digest $DigestParts[1])) {
        throw "invalid_request"
    }
    $Body = ConvertTo-CanonicalAsciiBytes $Lines[0..14]
    if ((Get-Sha256Bytes $Body) -cne $DigestParts[1]) { throw "invalid_request" }
    if (-not (Test-RequestId $Fields.'request-id') -or -not (Test-Token $Fields.'host-id') -or
        -not (Test-Sid $Fields.owner) -or -not (Test-PlanId $Fields.'plan-id') -or
        -not (Test-DigestOrDash $Fields.'plan-sha256') -or -not (Test-UIntOrDash $Fields.'operation-index') -or
        -not (Test-Token $Fields.'action-id') -or
        ($Fields.package -cne "-" -and -not (Test-WinGetId $Fields.package)) -or
        -not (Test-VersionOrDash $Fields.version) -or
        ($Fields.source -cne "-" -and -not (Test-Token $Fields.source)) -or
        -not (Test-DigestOrDash $Fields.'payload-sha256') -or
        -not (Test-UInt $Fields.'created-at') -or -not (Test-UInt $Fields.'expires-at')) {
        throw "invalid_request"
    }
    return [pscustomobject]@{ Fields = $Fields; Sha256 = $DigestParts[1] }
}
function Test-ActionParameters([object]$Fields) {
    switch ($Fields.'action-id') {
        "winget.inventory-machine.v1" { return $Fields.package -ceq "-" -and $Fields.version -ceq "-" -and $Fields.source -ceq "-" -and $Fields.'payload-sha256' -ceq "-" }
        "lane.probe.v1" { return $Fields.package -ceq "-" -and $Fields.version -ceq "-" -and $Fields.source -ceq "-" -and $Fields.'payload-sha256' -ceq "-" }
        "winget.install-machine-package.v1" { return (Test-WinGetId $Fields.package) -and $Fields.source -cin @("winget", "msstore") -and $Fields.'payload-sha256' -ceq "-" }
        "winget.upgrade-machine-package.v1" { return (Test-WinGetId $Fields.package) -and (Test-VersionToken $Fields.version) -and $Fields.source -cin @("winget", "msstore") -and $Fields.'payload-sha256' -ceq "-" }
        "lane.self-upgrade.v1" { return $Fields.package -ceq "-" -and (Test-PluginVersion $Fields.version) -and $Fields.source -ceq "-" -and (Test-Digest $Fields.'payload-sha256') }
        default { return $false }
    }
}
$script:ResultFields = [string[]]@("request-id", "host-id", "plan-id", "plan-sha256", "operation-index", "action-id",
    "package", "version", "state", "reason", "native-exit", "pre-state-sha256", "post-state-sha256",
    "started-at", "finished-at", "lane-version", "lane-sha256", "request-sha256")
function Render-Result([hashtable]$Values) {
    $Lines = @("lane-result|1")
    foreach ($Name in $script:ResultFields) { $Lines += "$Name|$($Values[$Name])" }
    $Lines += "end-result|"
    $Digest = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines)
    return ConvertTo-CanonicalAsciiBytes ($Lines + @("result-sha256|$Digest"))
}
function Read-Result([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 8192 "result"
    if ($Lines.Count -ne 21) { throw "invalid_result" }
    $Fields = Read-FixedFields $Lines[0..19] $script:ResultFields "lane-result|1" "end-result|" "result"
    $DigestParts = $Lines[20].Split('|')
    if ($DigestParts.Count -ne 2 -or $DigestParts[0] -cne "result-sha256" -or
        (Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines[0..19])) -cne $DigestParts[1] -or
        $Fields.state -cnotin @("completed", "rejected", "failed", "partial")) { throw "invalid_result" }
    return $Fields
}

# --- native boundary ----------------------------------------------------------
# Everything that touches Windows itself goes through $script:Native so the
# self-check can replace it with an in-memory fixture on any platform.
function New-NativeBoundary {
    return [pscustomobject]@{
        IsWindows = $IsWindows
        CurrentSid = {
            $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { return [string]$Identity.User.Value } finally { $Identity.Dispose() }
        }
        CurrentName = {
            $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { return [string]$Identity.Name } finally { $Identity.Dispose() }
        }
        IsSystem = {
            $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { return [bool]$Identity.IsSystem } finally { $Identity.Dispose() }
        }
        IsElevated = {
            $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try {
                return [Security.Principal.WindowsPrincipal]::new($Identity).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
            } finally { $Identity.Dispose() }
        }
        FileOwnerSid = {
            param([string]$Path)
            $Acl = Get-Acl -LiteralPath $Path
            return [string]$Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        }
        ReadSddl = {
            param([string]$Path)
            return [string](Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm("DAO")
        }
        SetDirectorySddl = {
            param([string]$Path, [string]$Sddl)
            $Security = [Security.AccessControl.DirectorySecurity]::new()
            $Security.SetSecurityDescriptorSddlForm($Sddl)
            Set-Acl -LiteralPath $Path -AclObject $Security
        }
        SetFileSddl = {
            param([string]$Path, [string]$Sddl)
            $Security = [Security.AccessControl.FileSecurity]::new()
            $Security.SetSecurityDescriptorSddlForm($Sddl)
            Set-Acl -LiteralPath $Path -AclObject $Security
        }
        RegisterTask = {
            param([string]$Xml, [string]$Sddl)
            $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
            $Flags = $script:TaskCreateOrUpdate -bor $script:TaskDontAddPrincipalAce
            $Task = $Service.GetFolder("\").RegisterTask($script:TaskName, $Xml, $Flags, $script:SystemSid, $null,
                $script:TaskLogonServiceAccount, $null)
            if ($null -eq $Task) { throw "task_registration_failed" }
            $Task.SetSecurityDescriptor($Sddl, $script:TaskDontAddPrincipalAce)
        }
        ReadTask = {
            $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
            try { $Task = $Service.GetFolder("\").GetTask("\" + $script:TaskName) } catch { return $null }
            return [pscustomobject]@{ Xml = [string]$Task.Xml
                Sddl = [string]$Task.GetSecurityDescriptor($script:TaskSecurityInformation) }
        }
        UnregisterTask = {
            $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
            try { $Service.GetFolder("\").DeleteTask($script:TaskName, 0) } catch { }
        }
        StartTask = {
            $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
            [void]$Service.GetFolder("\").GetTask("\" + $script:TaskName).Run($null)
        }
        InstallModule = {
            param([string]$LockPath, [string]$Destination, [string]$Scratch)
            Install-PinnedWinGetModule $LockPath $Destination $Scratch
        }
        ImportModule = { param([string]$ManifestPath) Import-Module -Name $ManifestPath -Force -ErrorAction Stop }
        WinGetFind = {
            param([string]$Id, [string]$Source)
            return @(Microsoft.WinGet.Client\Find-WinGetPackage -Id $Id -Source $Source -MatchOption EqualsCaseInsensitive -ErrorAction Stop)
        }
        WinGetInstalled = {
            param([string]$Id, [string]$Source)
            return @(Microsoft.WinGet.Client\Get-WinGetPackage -Id $Id -Source $Source -MatchOption EqualsCaseInsensitive -ErrorAction Stop)
        }
        WinGetInventory = {
            return @(Microsoft.WinGet.Client\Get-WinGetPackage -ErrorAction Stop)
        }
        WinGetInstall = {
            param([string]$Id, [string]$Source, [string]$Version)
            $Parameters = @{ Id = $Id; Source = $Source; MatchOption = "EqualsCaseInsensitive"; Scope = "System"
                Mode = "Silent"; Confirm = $false; ErrorAction = "Stop" }
            if ($Version -cne "-") { $Parameters.Version = $Version }
            return @(Microsoft.WinGet.Client\Install-WinGetPackage @Parameters)
        }
        WinGetUpgrade = {
            param([string]$Id, [string]$Source, [string]$Version)
            return @(Microsoft.WinGet.Client\Update-WinGetPackage -Id $Id -Source $Source -Version $Version `
                -MatchOption EqualsCaseInsensitive -Scope System -Mode Silent -Confirm:$false -ErrorAction Stop)
        }
        Elevate = {
            param([string[]]$Arguments)
            $Process = Start-Process -FilePath $script:PowerShellPath -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
            return [int]$Process.ExitCode
        }
    }
}

function Install-PinnedWinGetModule([string]$LockPath, [string]$Destination, [string]$Scratch) {
    $Lock = Read-WinGetModuleLock ([IO.File]::ReadAllBytes($LockPath))
    if ([IO.Directory]::Exists($Scratch)) { [IO.Directory]::Delete($Scratch, $true) }
    [void][IO.Directory]::CreateDirectory($Scratch)
    $Archive = Join-Path $Scratch "Microsoft.WinGet.Client.zip"
    $Expanded = Join-Path $Scratch "expanded"
    Invoke-WebRequest -Uri $Lock.PackageUrl -OutFile $Archive -UseBasicParsing
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Lock.PackageSha256) {
        throw "winget_module_package_hash_mismatch"
    }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Expanded
    Assert-WinGetModuleTree $Expanded $Lock
    foreach ($Relative in $Lock.Signatures.Keys) {
        $Signature = Get-AuthenticodeSignature -FilePath (Join-Path $Expanded $Relative)
        if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $Signature.SignerCertificate -or
            $Signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
            throw "winget_module_signature_invalid"
        }
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
    if ([IO.Directory]::Exists($Destination)) { [IO.Directory]::Delete($Destination, $true) }
    [IO.Directory]::Move($Expanded, $Destination)
}
function Read-WinGetModuleLock([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "winget_module_lock"
    if ($Lines[0] -cne "winget-module-lock|1" -or $Lines[-1] -cne "end-lock|") { throw "invalid_winget_module_lock" }
    $Lock = [ordered]@{ Module = ""; Version = ""; PackageUrl = ""; PackageSha256 = ""; Manifest = ""
        Signatures = [ordered]@{}; Files = [ordered]@{} }
    foreach ($Line in $Lines[1..($Lines.Count - 2)]) {
        $Parts = $Line.Split('|')
        switch ($Parts[0]) {
            "module" { $Lock.Module = $Parts[1] }
            "version" { $Lock.Version = $Parts[1] }
            "package-url" { $Lock.PackageUrl = $Parts[1] }
            "package-sha256" { $Lock.PackageSha256 = $Parts[1] }
            "manifest" { $Lock.Manifest = $Parts[1] }
            "signature" { $Lock.Signatures[$Parts[1]] = $Parts[2] }
            "file" { $Lock.Files[$Parts[1]] = $Parts[2] }
            default { throw "invalid_winget_module_lock" }
        }
    }
    if ($Lock.Module -cne "Microsoft.WinGet.Client" -or -not (Test-Digest $Lock.PackageSha256) -or
        $Lock.PackageUrl -cnotmatch '^https://www\.powershellgallery\.com/' -or $Lock.Files.Count -lt 1) {
        throw "invalid_winget_module_lock"
    }
    return [pscustomobject]$Lock
}
function Assert-WinGetModuleTree([string]$Root, [object]$Lock) {
    $Observed = [ordered]@{}
    foreach ($Path in [IO.Directory]::EnumerateFiles($Root, "*", [IO.SearchOption]::AllDirectories)) {
        $Relative = [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
        $Observed[$Relative] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($Observed.Count -ne $Lock.Files.Count) { throw "winget_module_file_set_mismatch" }
    foreach ($Entry in $Lock.Files.GetEnumerator()) {
        if (-not $Observed.Contains($Entry.Key) -or $Observed[$Entry.Key] -cne $Entry.Value) { throw "winget_module_file_hash_mismatch" }
    }
}

# --- layout and contracts -----------------------------------------------------
function Get-ProtectedSddl { return "O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)" }
function Get-OwnerReadSddl([string]$OwnerSid) { return "O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;$OwnerSid)" }
function Get-IngressSddl([string]$OwnerSid) { return "O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;$OwnerSid)" }
function Get-ResultFileSddl([string]$OwnerSid) { return "O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x120089;;;$OwnerSid)" }
function Test-ProtectedAcl([string]$Sddl, [string]$OwnerSid, [bool]$OwnerMayRead) {
    # SYSTEM and Administrators must hold allow ACEs; no other principal may
    # hold any write/delete/change-permission bit, and the owner may hold at
    # most read bits (only on owner-readable paths). The service rewrites
    # generic rights, so masks are inspected, never compared for equality.
    if ($script:Fixture) {
        $Expected = if ($OwnerMayRead) { Get-OwnerReadSddl $OwnerSid } else { Get-ProtectedSddl }
        return $Sddl -ceq $Expected
    }
    try { $Descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl) } catch { return $false }
    $WriteBits = 0x40000000 -bor 0x10000000 -bor 0x00000002 -bor 0x00000004 -bor 0x00000100 -bor 0x00010000 -bor 0x00040000 -bor 0x00080000
    $Seen = @{}
    foreach ($Ace in @($Descriptor.DiscretionaryAcl)) {
        if ($Ace -isnot [Security.AccessControl.CommonAce]) { return $false }
        $Sid = [string]$Ace.SecurityIdentifier.Value
        if ($Ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed) { continue }
        $Seen[$Sid] = $true
        if ($Sid -cin @($script:SystemSid, "S-1-5-32-544")) { continue }
        if ($Sid -ceq $OwnerSid -and $OwnerMayRead) {
            if (([int]$Ace.AccessMask -band $WriteBits) -ne 0) { return $false }
            continue
        }
        return $false
    }
    return $Seen.ContainsKey($script:SystemSid) -and $Seen.ContainsKey("S-1-5-32-544")
}
function Get-TaskSddl([string]$OwnerSid) { return "O:SYG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;$OwnerSid)" }
function Get-LaneTaskXml([string]$ScriptPath, [string]$WorkingDirectory) {
    $Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -Dispatch'
    return '<?xml version="1.0" encoding="UTF-16"?>' +
        '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' +
        '<RegistrationInfo><URI>\' + $script:TaskName + '</URI></RegistrationInfo>' +
        '<Triggers><TimeTrigger><StartBoundary>2000-01-01T00:00:00</StartBoundary>' +
        '<Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>' +
        '<Enabled>true</Enabled></TimeTrigger></Triggers>' +
        '<Principals><Principal id="Author"><UserId>' + $script:SystemSid + '</UserId>' +
        '<LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>' +
        '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' +
        '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' +
        '<AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>' +
        '<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><Enabled>true</Enabled><Hidden>true</Hidden>' +
        '<RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT1H</ExecutionTimeLimit>' +
        '<Priority>7</Priority></Settings><Actions Context="Author"><Exec><Command>' +
        [Security.SecurityElement]::Escape($script:PowerShellPath) + '</Command><Arguments>' +
        [Security.SecurityElement]::Escape($Arguments) + '</Arguments><WorkingDirectory>' +
        [Security.SecurityElement]::Escape($WorkingDirectory) + '</WorkingDirectory></Exec></Actions></Task>'
}
function Test-LaneTaskXml([string]$XmlText, [string]$ScriptPath, [string]$WorkingDirectory) {
    # The service re-serializes a registered task (adds Date/Author, IdleSettings,
    # defaults), so the contract is a projection: who runs it, what it runs,
    # and how often — never whole-document equality.
    try { [xml]$Document = $XmlText } catch { return $false }
    $Manager = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Manager.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
    $Expected = [ordered]@{
        "/t:Task/t:Principals/t:Principal/t:UserId" = $script:SystemSid
        "/t:Task/t:Principals/t:Principal/t:LogonType" = "ServiceAccount"
        "/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:Interval" = "PT1M"
        "/t:Task/t:Settings/t:Enabled" = "true"
        "/t:Task/t:Settings/t:MultipleInstancesPolicy" = "IgnoreNew"
        "/t:Task/t:Actions/t:Exec/t:Command" = $script:PowerShellPath
        "/t:Task/t:Actions/t:Exec/t:Arguments" = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -Dispatch'
        "/t:Task/t:Actions/t:Exec/t:WorkingDirectory" = $WorkingDirectory
    }
    foreach ($Path in $Expected.Keys) {
        $Nodes = @($Document.SelectNodes($Path, $Manager))
        if ($Nodes.Count -ne 1 -or [string]$Nodes[0].InnerText -cne [string]$Expected[$Path]) { return $false }
    }
    if (@($Document.SelectNodes("/t:Task/t:Actions/*", $Manager)).Count -ne 1) { return $false }
    if ($XmlText -match '(?i)(<Password>|S4U|InteractiveToken)') { return $false }
    return $true
}
function Test-LaneTaskSddl([string]$Sddl, [string]$OwnerSid) {
    # The owner must hold an allow ACE (read + execute, so the task can be
    # started), SYSTEM and Administrators theirs; the service may re-encode
    # generic rights, so masks are compared for inclusion, not equality.
    if ($script:Fixture) { return $Sddl -ceq (Get-TaskSddl $OwnerSid) }
    try { $Descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl) } catch { return $false }
    $Seen = @{}
    foreach ($Ace in @($Descriptor.DiscretionaryAcl)) {
        if ($Ace -isnot [Security.AccessControl.CommonAce]) { continue }
        if ($Ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed) { continue }
        $Seen[[string]$Ace.SecurityIdentifier.Value] = [int]$Ace.AccessMask
    }
    foreach ($Required in @($script:SystemSid, "S-1-5-32-544", $OwnerSid)) {
        if (-not $Seen.ContainsKey($Required)) { return $false }
    }
    return $true
}
function Write-ProtectedBytes([string]$Path, [byte[]]$Bytes, [string]$Sddl) {
    $Temporary = Join-Path (Split-Path -Parent $Path) (".lane-" + [Guid]::NewGuid().ToString("n"))
    [IO.File]::WriteAllBytes($Temporary, $Bytes)
    [IO.File]::Move($Temporary, $Path, $true)
    if ($Sddl.Length -gt 0) { & $script:Native.SetFileSddl $Path $Sddl }
}

# --- status -------------------------------------------------------------------
function Get-LaneState {
    $Paths = Get-LanePaths
    $Result = [ordered]@{ State = "drifted"; Detail = "-"; Identity = $null; Token = "-" }
    if (-not $script:Fixture -and -not $script:Native.IsWindows) { $Result.State = "unsupported"; $Result.Detail = "not windows"; return [pscustomobject]$Result }
    if (-not $script:Fixture) { $Result.Token = if (& $script:Native.IsElevated) { "elevated" } else { "limited" } }
    if (-not [IO.File]::Exists($Paths.Identity) -and -not [IO.File]::Exists($Paths.Script)) {
        $Result.State = "needs_one_time_approval"; return [pscustomobject]$Result
    }
    try { $Identity = Read-Identity $Paths.Identity } catch { $Result.Detail = "identity record unreadable"; return [pscustomobject]$Result }
    $Result.Identity = $Identity
    if (-not [IO.File]::Exists($Paths.Script) -or (Get-Sha256File $Paths.Script) -cne $Identity.'lane-sha256') {
        $Result.Detail = "installed lane script missing or digest differs from identity"; return [pscustomobject]$Result
    }
    foreach ($Directory in @($Paths.Ingress, $Paths.Results, $Paths.Claims, $Paths.Journal)) {
        if (-not [IO.Directory]::Exists($Directory)) { $Result.Detail = "queue directory missing: $Directory"; return [pscustomobject]$Result }
    }
    # The task runs this copy as LocalSystem: an ACL that lets anyone but
    # SYSTEM/Administrators write the script, the identity, the module, the
    # claims or the journal is arbitrary SYSTEM execution, so it is drift.
    foreach ($Protected in @(@($Paths.Claims, $false), @($Paths.Journal, $false), @($Paths.Root, $true), @($Paths.Script, $true), @($Paths.Identity, $true), @($Paths.Module, $true))) {
        $Path = $Protected[0]
        if (-not ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))) { continue }
        $Sddl = ""
        try { $Sddl = & $script:Native.ReadSddl $Path } catch { $Sddl = "" }
        if (-not (Test-ProtectedAcl $Sddl $Identity.'owner-sid' $Protected[1])) {
            $Result.Detail = "protected ACL drifted: $Path"; return [pscustomobject]$Result
        }
    }
    $Task = & $script:Native.ReadTask
    if ($null -eq $Task) { $Result.Detail = "scheduled task missing"; return [pscustomobject]$Result }
    if (-not (Test-LaneTaskXml $Task.Xml $Paths.Script $Paths.Root)) { $Result.Detail = "scheduled task definition drifted"; return [pscustomobject]$Result }
    if (-not (Test-LaneTaskSddl $Task.Sddl $Identity.'owner-sid')) { $Result.Detail = "scheduled task security drifted"; return [pscustomobject]$Result }
    if (-not $script:Fixture -and -not [IO.File]::Exists((Join-Path $Paths.Module "Microsoft.WinGet.Client.psd1"))) {
        $Result.Detail = "winget client module missing"; return [pscustomobject]$Result
    }
    if ($Identity.activation -cne "passed") {
        # Installed by the elevated child but not yet proven from the owner's
        # own token: only a lane.probe.v1 is dispatched until it is, and the
        # SYSTEM side flips this flag when that probe completes.
        $Result.State = "canary_pending"; $Result.Detail = "the owner's enrollment probe has not completed"
        return [pscustomobject]$Result
    }
    $Result.State = "ready"
    return [pscustomobject]$Result
}
function Invoke-Status {
    $State = Get-LaneState
    $Identity = $State.Identity
    $Lines = @("lane-status|1", "state|$($State.State)", "platform|windows",
        "host-id|$(if ($Identity) { $Identity.'host-id' } else { '-' })",
        "owner-sid|$(if ($Identity) { $Identity.'owner-sid' } else { '-' })",
        "owner-name|$(if ($Identity) { $Identity.'owner-name' } else { '-' })",
        "lane-version|$(if ($Identity) { $Identity.'lane-version' } else { '-' })",
        "lane-sha256|$(if ($Identity) { $Identity.'lane-sha256' } else { '-' })",
        "plugin-root|$(if ($Identity) { $Identity.'plugin-root' } else { '-' })",
        "interop-token|$($State.Token)", "detail|$($State.Detail)",
        "next-command|$(if ($State.State -cin @('needs_one_time_approval', 'drifted')) { 'roundhouse privilege-enroll HOST' } else { '-' })",
        "end-status|")
    Write-Record $Lines
    switch ($State.State) { "ready" { return 0 } "needs_one_time_approval" { return 75 } "unsupported" { return 69 } default { return 74 } }
}

# --- enrollment ---------------------------------------------------------------
function Get-ScriptSelf { return [IO.Path]::GetFullPath($PSCommandPath) }
function Get-PluginVersionBeside([string]$ScriptPath) {
    $Manifest = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptPath)) ".codex-plugin\plugin.json"
    if (-not [IO.File]::Exists($Manifest)) { throw "plugin_manifest_missing" }
    $Version = [string](Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json).version
    if (-not (Test-PluginVersion $Version)) { throw "plugin_version_invalid" }
    return $Version
}
function Get-PluginRootBeside([string]$ScriptPath, [string]$Version) {
    $VersionDirectory = Split-Path -Parent (Split-Path -Parent $ScriptPath)
    if ((Split-Path -Leaf $VersionDirectory) -cne $Version) { return "-" }
    return Split-Path -Parent $VersionDirectory
}
function Write-Journal([string]$Kind, [string]$RequestId, [string]$ActionId, [string]$PackageId, [string]$State, [string]$Reason, [string]$RequestSha, [string]$ResultSha) {
    $Paths = Get-LanePaths
    $Line = "event|$(Get-UnixNow)|$Kind|$RequestId|$ActionId|$PackageId|$State|$Reason|$RequestSha|$ResultSha`n"
    [IO.File]::AppendAllText($Paths.JournalLog, $Line, $script:Ascii)
}
function Install-Lane([string]$TargetHost, [string]$Sid, [string]$Root, [string]$SelfPath) {
    $Paths = Get-LanePaths
    $Version = Get-PluginVersionBeside $SelfPath
    if ($Root.Length -lt 1) { $Root = Get-PluginRootBeside $SelfPath $Version }
    if ($Root -cne "-" -and -not (Test-WindowsAbsolutePath $Root) -and -not $script:Fixture) { throw "invalid_plugin_root" }
    foreach ($Directory in @($Paths.Root, $Paths.Ingress, $Paths.Results, $Paths.Claims, $Paths.Journal)) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }
    & $script:Native.SetDirectorySddl $Paths.Root (Get-OwnerReadSddl $Sid)
    & $script:Native.SetDirectorySddl $Paths.Ingress (Get-IngressSddl $Sid)
    & $script:Native.SetDirectorySddl $Paths.Results (Get-OwnerReadSddl $Sid)
    & $script:Native.SetDirectorySddl $Paths.Claims (Get-ProtectedSddl)
    & $script:Native.SetDirectorySddl $Paths.Journal (Get-ProtectedSddl)
    $ScriptBytes = [IO.File]::ReadAllBytes($SelfPath)
    Write-ProtectedBytes $Paths.Script $ScriptBytes (Get-OwnerReadSddl $Sid)
    $Sha = Get-Sha256Bytes $ScriptBytes
    $LockPath = Join-Path (Split-Path -Parent (Split-Path -Parent $SelfPath)) "references\windows-winget-provider.lock"
    if (-not [IO.File]::Exists($LockPath)) { throw "winget_module_lock_missing" }
    Write-ProtectedBytes $Paths.ModuleLock ([IO.File]::ReadAllBytes($LockPath)) ""
    & $script:Native.InstallModule $Paths.ModuleLock $Paths.Module (Join-Path $Paths.Claims ".module-stage")
    if ([IO.Directory]::Exists($Paths.Module)) { & $script:Native.SetDirectorySddl $Paths.Module (Get-OwnerReadSddl $Sid) }
    $Identity = @{ "host-id" = $TargetHost; "platform" = "windows"; "owner-sid" = $Sid
        "owner-name" = (& $script:Native.CurrentName); "plugin-root" = $Root; "marketplace" = "novotnyllc"
        "plugin" = "roundhouse"; "lane-version" = $Version; "lane-sha256" = $Sha; "enrolled-at" = [string](Get-UnixNow)
        "activation" = "pending" }
    Write-ProtectedBytes $Paths.Identity (Render-Identity $Identity) (Get-OwnerReadSddl $Sid)
    [void](Read-Identity $Paths.Identity)
    if (-not [IO.File]::Exists($Paths.JournalLog)) { [IO.File]::WriteAllBytes($Paths.JournalLog, [byte[]]@()) }
    & $script:Native.RegisterTask (Get-LaneTaskXml $Paths.Script $Paths.Root) (Get-TaskSddl $Sid)
    $State = Get-LaneState
    if ($State.State -cne "canary_pending") { throw "enrollment_not_ready:$($State.Detail)" }
    # The canary request is NOT submitted here: a file created under the
    # elevated token is owned by Administrators, which the dispatcher refuses.
    # The unelevated launcher submits it after the receipt (Invoke-Enroll);
    # until that probe completes the identity stays `activation|pending`,
    # status is `canary_pending`, and nothing but a probe is dispatched.
    Write-Journal "enrollment" "-" "-" "-" "staged" "version=$Version;activation=pending" "-" "-"
    return [pscustomobject]@{ Version = $Version; Sha256 = $Sha; PluginRoot = $Root }
}
function Remove-Lane {
    $Paths = Get-LanePaths
    & $script:Native.UnregisterTask
    foreach ($Path in @($Paths.Script, $Paths.Identity)) { if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) } }
    foreach ($Directory in @($Paths.Ingress, $Paths.Results, $Paths.Claims, (Join-Path $Paths.Root "winget"))) {
        if ([IO.Directory]::Exists($Directory)) { [IO.Directory]::Delete($Directory, $true) }
    }
}
function Invoke-OwnerCanary([string]$TargetHost) {
    # The owner's own probe through the queue: the one request that may run
    # while the lane is canary_pending, and the one that activates it. Writes
    # the failed enrollment record itself; returns $true only on completion.
    $Probe = Submit-Request "lane.probe.v1" "-" "-" "-" "-" "enroll-canary" "-" "-" 120
    if ($Probe.state -ceq "completed") { return $true }
    # The installed pieces stay `activation|pending`: status reports
    # canary_pending, the dispatcher executes nothing but a probe, and
    # re-running privilege-enroll retries without another consent.
    Write-Record @("lane-enrollment|1", "state|failed", "reason|enrollment_canary_failed:$($Probe.reason)",
        "platform|windows", "lane-state|canary_pending", "next-command|roundhouse privilege-enroll $TargetHost", "end-enrollment|")
    return $false
}
function Get-EnrolledRecord([object]$Identity, [string]$TargetHost) {
    return [string[]]@("lane-enrollment|1", "state|enrolled", "reason|one_time_approval_complete", "platform|windows",
        "host-id|$TargetHost", "owner-sid|$($Identity.'owner-sid')", "lane-version|$($Identity.'lane-version')",
        "lane-sha256|$($Identity.'lane-sha256')", "plugin-root|$($Identity.'plugin-root')",
        "canary|task-registered,probe-completed", "end-enrollment|")
}
function Invoke-Enroll {
    if (-not (Test-Token $HostId)) { throw "invalid_host_id" }
    if (-not $script:Fixture -and -not $script:Native.IsWindows) { throw "unsupported_context" }
    if (-not $script:Fixture -and (& $script:Native.IsSystem)) { throw "enroll_as_the_owner_not_system" }
    $Self = Get-ScriptSelf
    if (-not $Elevated) {
        $Sid = & $script:Native.CurrentSid
        if ($Sid -cmatch '-500$') { throw "built_in_administrator_forbidden" }
        $Pending = Get-LaneState
        if ($Pending.State -ceq "canary_pending" -and $null -ne $Pending.Identity -and
            $Pending.Identity.'owner-sid' -ceq $Sid -and $Pending.Identity.'lane-version' -ceq (Get-PluginVersionBeside $Self)) {
            # Everything is installed at this version; only the owner's probe
            # is missing, and that needs no consent at all.
            if (-not (Invoke-OwnerCanary $HostId)) { return 74 }
            Write-Record (Get-EnrolledRecord $Pending.Identity $HostId)
            return 0
        }
        if (-not $script:Fixture -and -not (& $script:Native.IsElevated)) {
            # The one approval: re-launch this script elevated. UAC consent is a
            # GUI dialog on the console; the receipt file carries the outcome back.
            $Receipt = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-lane-enroll-" + [Guid]::NewGuid().ToString("n") + ".receipt")
            $Arguments = @("-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ('"' + $Self + '"'),
                "-Enroll", "-Elevated", "-HostId", $HostId, "-OwnerSid", $Sid, "-ReceiptPath", ('"' + $Receipt + '"'))
            if ($PluginRoot.Length -gt 0) { $Arguments += @("-PluginRoot", ('"' + $PluginRoot + '"')) }
            $ExitCode = 75
            try { $ExitCode = & $script:Native.Elevate $Arguments } catch {
                Write-Record @("lane-enrollment|1", "state|needs_one_time_approval", "reason|uac_consent_not_granted",
                    "platform|windows", "next-command|roundhouse privilege-enroll $HostId", "end-enrollment|")
                return 75
            }
            if ([IO.File]::Exists($Receipt)) {
                $ReceiptText = [IO.File]::ReadAllText($Receipt)
                [IO.File]::Delete($Receipt)
                if ($ExitCode -eq 0 -and $ReceiptText.Contains("`nstate|enrolled`n")) {
                    # Canary from the owner's own limited token: the file this
                    # writes has the owner as NTFS owner, exactly like a request
                    # arriving through drvfs will.
                    if (-not (Invoke-OwnerCanary $HostId)) { return 74 }
                    $ReceiptText = $script:Ascii.GetString((ConvertTo-CanonicalAsciiBytes (Get-EnrolledRecord (Read-Identity (Get-LanePaths).Identity) $HostId)))
                }
                [Console]::Out.Write($ReceiptText)
            } else {
                # No receipt means the canary never ran and the lane, if it was
                # installed at all, is still pending: that is a failure
                # whatever the child's exit status said.
                Write-Record @("lane-enrollment|1", "state|failed", "reason|elevated_enrollment_left_no_receipt", "platform|windows",
                    "next-command|roundhouse privilege-enroll $HostId", "end-enrollment|")
                return 74
            }
            return $ExitCode
        }
        $OwnerSid = $Sid
    }
    if (-not (Test-Sid $OwnerSid) -or $OwnerSid -ceq $script:SystemSid) { throw "invalid_owner_sid" }
    if (-not $script:Fixture) {
        if (-not (& $script:Native.IsElevated)) { throw "elevated_context_required" }
        if ((& $script:Native.CurrentSid) -cne $OwnerSid) { throw "elevated_token_is_not_the_owner" }
    }
    $Outcome = $null; $Code = 0
    try {
        $Installed = Install-Lane $HostId $OwnerSid $PluginRoot $Self
        $Outcome = @("lane-enrollment|1", "state|enrolled", "reason|one_time_approval_complete", "platform|windows",
            "host-id|$HostId", "owner-sid|$OwnerSid", "lane-version|$($Installed.Version)", "lane-sha256|$($Installed.Sha256)",
            "plugin-root|$($Installed.PluginRoot)", "canary|task-registered", "end-enrollment|")
    } catch {
        $Reason = ([string]$_.Exception.Message) -replace '[^A-Za-z0-9_:.-]', '_'
        try { Remove-Lane } catch { }
        $Outcome = @("lane-enrollment|1", "state|failed", "reason|$Reason", "platform|windows", "end-enrollment|")
        $Code = 74
    }
    $Bytes = ConvertTo-CanonicalAsciiBytes $Outcome
    if ($ReceiptPath.Length -gt 0) { [IO.File]::WriteAllBytes($ReceiptPath, $Bytes) }
    [Console]::Out.Write($script:Ascii.GetString($Bytes))
    return $Code
}
function Invoke-Revoke {
    if (-not $script:Fixture -and -not (& $script:Native.IsElevated)) { throw "elevated_context_required" }
    Remove-Lane
    Write-Journal "revoke" "-" "-" "-" "revoked" "lane_removed" "-" "-"
    Write-Record @("lane-revocation|1", "state|revoked", "reason|task_script_identity_and_queue_removed", "journal|retained", "end-revocation|")
    return 0
}

# --- dispatch -----------------------------------------------------------------
function Get-RequestsInLastHour {
    $Paths = Get-LanePaths
    if (-not [IO.File]::Exists($Paths.JournalLog)) { return 0 }
    $Since = (Get-UnixNow) - 3600
    $Count = 0
    foreach ($Line in [IO.File]::ReadAllLines($Paths.JournalLog)) {
        $Parts = $Line.Split('|')
        if ($Parts.Count -ge 4 -and $Parts[0] -ceq "event" -and $Parts[2] -ceq "request" -and (Test-UInt $Parts[1]) -and [int64]$Parts[1] -ge $Since) { $Count++ }
    }
    return $Count
}
function Remove-ExpiredClaims {
    $Paths = Get-LanePaths
    $Cutoff = [DateTime]::UtcNow.AddSeconds(-$script:RetainSeconds)
    foreach ($Entry in @(Get-ChildItem -LiteralPath $Paths.Claims -Directory -Filter "request-*" -ErrorAction SilentlyContinue)) {
        if ($Entry.LastWriteTimeUtc -lt $Cutoff) { [IO.Directory]::Delete($Entry.FullName, $true) }
    }
    foreach ($Entry in @(Get-ChildItem -LiteralPath $Paths.Results -File -Filter "request-*.result" -ErrorAction SilentlyContinue)) {
        if ($Entry.LastWriteTimeUtc -lt $Cutoff) { [IO.File]::Delete($Entry.FullName) }
    }
}
function Publish-Result([hashtable]$Values, [object]$Identity) {
    $Paths = Get-LanePaths
    $Bytes = Render-Result $Values
    $Claim = Join-Path $Paths.Claims $Values['request-id']
    [void][IO.Directory]::CreateDirectory($Claim)
    [IO.File]::WriteAllBytes((Join-Path $Claim "result"), $Bytes)
    Write-ProtectedBytes (Join-Path $Paths.Results ($Values['request-id'] + ".result")) $Bytes (Get-ResultFileSddl $Identity.'owner-sid')
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 8192 "result"
    Write-Journal "request" $Values['request-id'] $Values['action-id'] $Values.package $Values.state $Values.reason `
        $Values['request-sha256'] (Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines[0..19]))
    return $Values.state
}
function Set-LaneActivation([object]$Identity) {
    # Rewrites lane.identity with activation|passed. The owner's status probe
    # reads that file without FILE_SHARE_DELETE, so the rename behind
    # Write-ProtectedBytes can hit a transient sharing violation; retry
    # briefly rather than leave the probe without a result.
    $Paths = Get-LanePaths
    $Activated = @{}
    foreach ($Name in $script:IdentityFields) { $Activated[$Name] = $Identity[$Name] }
    $Activated.activation = "passed"
    for ($Attempt = 0; ; $Attempt++) {
        try { Write-ProtectedBytes $Paths.Identity (Render-Identity $Activated) ""; break }
        catch { if ($Attempt -ge 4) { throw "identity_activation_write_failed" }; Start-Sleep -Milliseconds 200 }
    }
    $Identity.activation = "passed"
}
function Invoke-DispatchOne([IO.FileInfo]$Entry, [object]$Identity, [string]$LaneSha) {
    $Paths = Get-LanePaths
    $Id = [IO.Path]::GetFileNameWithoutExtension($Entry.Name)
    $Started = Get-UnixNow
    $Values = @{ "request-id" = $Id; "host-id" = $Identity.'host-id'; "plan-id" = "-"; "plan-sha256" = "-"; "operation-index" = "-"
        "action-id" = "-"; "package" = "-"; "version" = "-"; "state" = "rejected"; "reason" = "-"; "native-exit" = "-"
        "pre-state-sha256" = "-"; "post-state-sha256" = "-"; "started-at" = [string]$Started; "finished-at" = "-"
        "lane-version" = $Identity.'lane-version'; "lane-sha256" = $LaneSha; "request-sha256" = "-" }
    if (-not (Test-RequestId $Id)) { [IO.File]::Delete($Entry.FullName); return "rejected" }
    $Claim = Join-Path $Paths.Claims $Id
    if ([IO.Directory]::Exists($Claim)) {
        # Journaled and dropped; the original published result stays so a
        # lookup still answers with what actually happened.
        [IO.File]::Delete($Entry.FullName)
        Write-Journal "request" $Id "-" "-" "rejected" "replayed_request" "-" "-"
        return "rejected"
    }
    [void][IO.Directory]::CreateDirectory($Claim)
    $Held = Join-Path $Claim "request"
    # Move before read: once below the SYSTEM-only claim directory the owner
    # can no longer replace the bytes. The owner check reads the NTFS owner of
    # the moved file, which the rename preserved.
    $Reason = ""
    try {
        if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $Reason = "request_not_regular_file" }
        else {
            [IO.File]::Move($Entry.FullName, $Held)
            $HeldInfo = [IO.FileInfo]::new($Held)
            if (($HeldInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $Reason = "request_not_regular_file" }
            elseif ($HeldInfo.Length -gt $script:MaximumRequestBytes) { $Reason = "request_too_large" }
            elseif ((& $script:Native.FileOwnerSid $Held) -cne $Identity.'owner-sid') { $Reason = "request_not_owned_by_enrolled_owner" }
        }
    } catch { $Reason = "request_unclaimable" }
    $Parsed = $null
    if ($Reason.Length -eq 0) {
        try { $Parsed = Read-Request ([IO.File]::ReadAllBytes($Held)) } catch { $Reason = "invalid_request_record" }
    }
    if ($Reason.Length -eq 0) {
        $Fields = $Parsed.Fields
        foreach ($Name in @("plan-id", "plan-sha256", "operation-index", "action-id", "package", "version")) { $Values[$Name] = $Fields[$Name] }
        $Values['request-sha256'] = $Parsed.Sha256
        $Now = Get-UnixNow
        [int64]$Created = [int64]$Fields.'created-at'; [int64]$Expires = [int64]$Fields.'expires-at'
        if ($Fields.'request-id' -cne $Id) { $Reason = "request_id_mismatch" }
        elseif ($Fields.'host-id' -cne $Identity.'host-id') { $Reason = "host_id_mismatch" }
        elseif ($Fields.owner -cne $Identity.'owner-sid') { $Reason = "owner_mismatch" }
        elseif ($Fields.'action-id' -cnotin $script:Actions) { $Reason = "unknown_action_for_platform" }
        elseif ($Identity.activation -cne "passed" -and $Fields.'action-id' -cne "lane.probe.v1") { $Reason = "lane_not_activated" }
        elseif (-not (Test-ActionParameters $Fields)) { $Reason = "invalid_action_parameters" }
        elseif ($Created -gt ($Now + $script:MaximumFutureSkew) -or ($Now - $Created) -gt $script:MaximumRequestAge -or
            $Expires -le $Now -or $Expires -le $Created -or ($Expires - $Created) -gt $script:MaximumRequestTtl) { $Reason = "stale_request" }
        elseif ((Get-RequestsInLastHour) -ge $script:MaximumRequestsPerHour) { $Reason = "rate_limited" }
    }
    if ($Reason.Length -gt 0) {
        $Values.reason = $Reason; $Values['finished-at'] = [string](Get-UnixNow)
        return Publish-Result $Values $Identity
    }
    $Outcome = Invoke-LaneAction $Parsed.Fields $Identity $Claim
    if ($Outcome.state -ceq "completed" -and $Parsed.Fields.'action-id' -ceq "lane.probe.v1" -and $Identity.activation -cne "passed") {
        # The owner's own request reached SYSTEM and came back: the lane is
        # proven end to end from the token every real request will use.
        Set-LaneActivation $Identity
        Write-Journal "activation" $Id "lane.probe.v1" "-" "completed" "owner_probe_passed" "-" "-"
    }
    foreach ($Name in @("state", "reason", "native-exit", "pre-state-sha256", "post-state-sha256")) { $Values[$Name] = $Outcome[$Name] }
    $Values['finished-at'] = [string](Get-UnixNow)
    return Publish-Result $Values $Identity
}
function Invoke-Dispatch {
    $Paths = Get-LanePaths
    if (-not $script:Fixture) {
        if (-not (& $script:Native.IsSystem)) { throw "dispatch_requires_localsystem" }
        if ((Get-ScriptSelf) -cne $Paths.Script) { throw "dispatch_runs_only_from_the_installed_copy" }
    }
    $Identity = Read-Identity $Paths.Identity
    $LaneSha = Get-Sha256File $Paths.Script
    if ($LaneSha -cne $Identity.'lane-sha256') { throw "installed_script_digest_drifted" }
    $Mutex = [Threading.Mutex]::new($false, "Global\RoundhouseLaneV1")
    if (-not $Mutex.WaitOne(0)) { Write-Record @("lane-dispatch|1", "drained|0", "reason|busy", "end-dispatch|"); return 75 }
    try {
        Remove-ExpiredClaims
        $Counts = @{ drained = 0; completed = 0; rejected = 0; failed = 0 }
        foreach ($Entry in @(Get-ChildItem -LiteralPath $Paths.Ingress -File -Filter "request-*.request" -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($Counts.drained -ge $script:MaximumRequestsPerDispatch) { break }
            $Counts.drained++
            $State = Invoke-DispatchOne $Entry $Identity $LaneSha
            switch ($State) { "completed" { $Counts.completed++ } "rejected" { $Counts.rejected++ } default { $Counts.failed++ } }
        }
        Write-Record @("lane-dispatch|1", "drained|$($Counts.drained)", "completed|$($Counts.completed)",
            "rejected|$($Counts.rejected)", "failed|$($Counts.failed)", "lane-version|$($Identity.'lane-version')", "end-dispatch|")
        return 0
    } finally { $Mutex.ReleaseMutex(); $Mutex.Dispose() }
}

# --- actions ------------------------------------------------------------------
function Invoke-LaneAction([object]$Fields, [object]$Identity, [string]$Claim) {
    $Outcome = @{ state = "failed"; reason = "-"; "native-exit" = "-"; "pre-state-sha256" = "-"; "post-state-sha256" = "-" }
    try {
        switch ($Fields.'action-id') {
            "lane.probe.v1" { $Outcome.state = "completed"; $Outcome.reason = "probe_completed"; $Outcome['native-exit'] = "0" }
            "winget.inventory-machine.v1" { Invoke-WinGetInventory $Outcome }
            "winget.install-machine-package.v1" { Invoke-WinGetMutation $Fields $Outcome $false }
            "winget.upgrade-machine-package.v1" { Invoke-WinGetMutation $Fields $Outcome $true }
            "lane.self-upgrade.v1" { Invoke-SelfUpgrade $Fields $Identity $Claim $Outcome }
            default { $Outcome.state = "rejected"; $Outcome.reason = "unknown_action" }
        }
    } catch {
        if ($Outcome.state -ceq "failed" -and $Outcome.reason -ceq "-") { $Outcome.reason = "native_operation_failed" }
    }
    return $Outcome
}
function Import-LaneWinGetModule {
    if ($script:Fixture) { return }
    $Paths = Get-LanePaths
    if (-not [IO.File]::Exists($Paths.ModuleLock)) { throw "winget_module_lock_missing" }
    Assert-WinGetModuleTree $Paths.Module (Read-WinGetModuleLock ([IO.File]::ReadAllBytes($Paths.ModuleLock)))
    & $script:Native.ImportModule (Join-Path $Paths.Module "Microsoft.WinGet.Client.psd1")
}
function Invoke-WinGetInventory([hashtable]$Outcome) {
    Import-LaneWinGetModule
    $Packages = @(& $script:Native.WinGetInventory)
    $Lines = @("winget-machine-inventory|1")
    foreach ($Entry in ($Packages | Sort-Object Id)) { $Lines += "package|$($Entry.Id)|$($Entry.InstalledVersion)" }
    $Lines += "end-inventory|"
    $Outcome['post-state-sha256'] = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines)
    $Outcome['native-exit'] = "0"; $Outcome.state = "completed"; $Outcome.reason = "inventory_verified"
}
function Invoke-WinGetMutation([object]$Fields, [hashtable]$Outcome, [bool]$Upgrade) {
    Import-LaneWinGetModule
    $Id = $Fields.package; $SourceName = $Fields.source; $Wanted = $Fields.version
    $Found = @(& $script:Native.WinGetFind $Id $SourceName)
    if ($Found.Count -ne 1 -or $Found[0].Id -cne $Id) { $Outcome.state = "rejected"; $Outcome.reason = "package_unknown_to_source"; return }
    $Installed = @(& $script:Native.WinGetInstalled $Id $SourceName)
    $InstalledVersion = if ($Installed.Count -eq 1) { [string]$Installed[0].InstalledVersion } else { "-" }
    if ($Wanted -cne "-" -and @($Found[0].AvailableVersions) -cnotcontains $Wanted) { $Outcome.state = "rejected"; $Outcome.reason = "version_not_available"; return }
    if ($Upgrade) {
        if ($Installed.Count -ne 1) { $Outcome.state = "rejected"; $Outcome.reason = "package_not_installed"; return }
        if ($InstalledVersion -ceq $Wanted) { $Outcome.state = "completed"; $Outcome.reason = "already_at_version"; $Outcome['native-exit'] = "0"; return }
    } elseif ($Installed.Count -eq 1 -and ($Wanted -ceq "-" -or $InstalledVersion -ceq $Wanted)) {
        $Outcome.state = "completed"; $Outcome.reason = "already_installed"; $Outcome['native-exit'] = "0"; return
    }
    $Outcome['pre-state-sha256'] = Get-Sha256Text "winget|$Id|$SourceName|$InstalledVersion|$Wanted"
    $Mutation = if ($Upgrade) { @(& $script:Native.WinGetUpgrade $Id $SourceName $Wanted) } else { @(& $script:Native.WinGetInstall $Id $SourceName $Wanted) }
    $StatusText = if ($Mutation.Count -eq 1) { ([string]$Mutation[0].Status).ToLowerInvariant() } else { "no-result" }
    $Outcome['native-exit'] = if ($Mutation.Count -eq 1) { ([string]$Mutation[0].InstallerErrorCode) } else { "-" }
    $After = @(& $script:Native.WinGetInstalled $Id $SourceName)
    $AfterVersion = if ($After.Count -eq 1) { [string]$After[0].InstalledVersion } else { "-" }
    $Outcome['post-state-sha256'] = Get-Sha256Text "winget|$Id|$SourceName|$AfterVersion"
    if ($StatusText -cne "ok") { $Outcome.state = "failed"; $Outcome.reason = "provider_status_$StatusText"; return }
    if ($AfterVersion -ceq "-" -or ($Wanted -cne "-" -and $AfterVersion -cne $Wanted)) { $Outcome.state = "partial"; $Outcome.reason = "post_state_mismatch"; return }
    $Outcome.state = "completed"; $Outcome.reason = if ($Upgrade) { "package_upgraded" } else { "package_installed" }
}
function Compare-PluginVersion([string]$Left, [string]$Right) {
    $L = $Left.Split('.') | ForEach-Object { [int]$_ }; $R = $Right.Split('.') | ForEach-Object { [int]$_ }
    for ($i = 0; $i -lt 3; $i++) { if ($L[$i] -ne $R[$i]) { return $L[$i].CompareTo($R[$i]) } }
    return 0
}
function Invoke-SelfUpgrade([object]$Fields, [object]$Identity, [string]$Claim, [hashtable]$Outcome) {
    $Paths = Get-LanePaths
    $Wanted = $Fields.version
    if ($Identity.'plugin-root' -ceq "-") { $Outcome.state = "rejected"; $Outcome.reason = "self_upgrade_unavailable_no_plugin_root"; return }
    if ((Compare-PluginVersion $Wanted $Identity.'lane-version') -le 0) { $Outcome.state = "rejected"; $Outcome.reason = "version_not_newer"; return }
    $Candidate = Join-Path $Identity.'plugin-root' $Wanted
    if (-not [IO.Directory]::Exists($Candidate)) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_version_missing"; return }
    $Stage = Join-Path $Claim "candidate"
    if ([IO.Directory]::Exists($Stage)) { [IO.Directory]::Delete($Stage, $true) }
    # Copy the whole candidate below the SYSTEM-only claim first; everything
    # after this line reads the copy, never the owner's tree.
    Copy-Item -LiteralPath $Candidate -Destination $Stage -Recurse -Force
    foreach ($Entry in @(Get-ChildItem -LiteralPath $Stage -Recurse -Force)) {
        if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_contains_reparse_points"; return }
    }
    $ManifestPath = Join-Path $Stage "integrity.json"
    if (-not [IO.File]::Exists($ManifestPath)) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_integrity_manifest_missing"; return }
    try { $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json } catch { $Outcome.state = "rejected"; $Outcome.reason = "candidate_integrity_manifest_invalid"; return }
    if ($Manifest.plugin -cne "roundhouse" -or $Manifest.marketplace -cne $Identity.marketplace -or [string]$Manifest.version -cne $Wanted -or
        $Manifest.schema -cne "roundhouse.integrity") { $Outcome.state = "rejected"; $Outcome.reason = "candidate_integrity_identity_mismatch"; return }
    $Listed = $null
    foreach ($Entry in @($Manifest.files)) {
        $Relative = [string]$Entry.path
        if ($Relative -match '(^|/)\.\.(/|$)' -or $Relative.StartsWith("/")) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_manifest_path_invalid"; return }
        $Path = Join-Path $Stage ($Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not [IO.File]::Exists($Path)) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_file_missing"; return }
        if ((Get-Sha256File $Path) -cne [string]$Entry.sha256) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_file_digest_mismatch"; return }
        if ($Relative -ceq "scripts/$($script:ScriptName)") { $Listed = [string]$Entry.sha256 }
    }
    $NewScript = Join-Path $Stage ("scripts\" + $script:ScriptName)
    if ($null -eq $Listed -or -not [IO.File]::Exists($NewScript)) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_lane_missing"; return }
    $NewSha = Get-Sha256File $NewScript
    if ($NewSha -cne $Listed -or $NewSha -cne $Fields.'payload-sha256') { $Outcome.state = "rejected"; $Outcome.reason = "candidate_lane_digest_mismatch"; return }
    try { Get-PluginVersionBeside $NewScript | Out-Null } catch { $Outcome.state = "rejected"; $Outcome.reason = "candidate_manifest_version_mismatch"; return }
    if ((Get-PluginVersionBeside $NewScript) -cne $Wanted) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_manifest_version_mismatch"; return }
    $Tokens = $null; $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($NewScript, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -gt 0) { $Outcome.state = "rejected"; $Outcome.reason = "candidate_does_not_parse"; return }
    $Outcome['pre-state-sha256'] = Get-Sha256Text "lane|$($Identity.'lane-version')|$($Identity.'lane-sha256')"
    Write-ProtectedBytes $Paths.Script ([IO.File]::ReadAllBytes($NewScript)) ""
    $NewIdentity = @{}
    foreach ($Name in $script:IdentityFields) { $NewIdentity[$Name] = $Identity[$Name] }
    $NewIdentity['lane-version'] = $Wanted; $NewIdentity['lane-sha256'] = $NewSha
    Write-ProtectedBytes $Paths.Identity (Render-Identity $NewIdentity) ""
    [IO.Directory]::Delete($Stage, $true)
    $Outcome['post-state-sha256'] = Get-Sha256Text "lane|$Wanted|$NewSha"
    $Outcome['native-exit'] = "0"; $Outcome.state = "completed"; $Outcome.reason = "lane_upgraded"
}

# --- request (owner side) -----------------------------------------------------
function Submit-Request([string]$ActionId, [string]$PackageId, [string]$WantedVersion, [string]$SourceName,
    [string]$Payload, [string]$Plan, [string]$PlanDigest, [string]$Index, [int]$WaitSeconds, [string]$FixedId = "") {
    $Paths = Get-LanePaths
    $State = Get-LaneState
    if ($State.State -cne "ready" -and -not ($State.State -ceq "canary_pending" -and $ActionId -ceq "lane.probe.v1")) {
        return [ordered]@{ state = "rejected"; reason = "lane_$($State.State)"; 'request-id' = "-" }
    }
    $Identity = $State.Identity
    $Sid = & $script:Native.CurrentSid
    if ($Sid -cne $Identity.'owner-sid') { throw "only_the_enrolled_owner_can_submit" }
    $Id = if ($FixedId.Length -gt 0) { $FixedId } else { "request-" + (-join ((1..32) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })) }
    if (-not (Test-RequestId $Id)) { throw "invalid_request_id" }
    if ([IO.File]::Exists((Join-Path $Paths.Results "$Id.result")) -or [IO.File]::Exists((Join-Path $Paths.Ingress "$Id.request"))) {
        return [ordered]@{ state = "rejected"; reason = "replayed_request"; 'request-id' = $Id }
    }
    $Created = Get-UnixNow
    $Values = @{ "request-id" = $Id; "host-id" = $Identity.'host-id'; "owner" = $Sid; "plan-id" = $Plan; "plan-sha256" = $PlanDigest
        "operation-index" = $Index; "action-id" = $ActionId; "package" = $PackageId; "version" = $WantedVersion; "source" = $SourceName
        "payload-sha256" = $Payload; "created-at" = [string]$Created; "expires-at" = [string]($Created + $script:MaximumRequestTtl) }
    $Bytes = Render-Request $Values
    $Parsed = Read-Request $Bytes
    if ($Parsed.Fields.'action-id' -cnotin $script:Actions -or -not (Test-ActionParameters $Parsed.Fields)) { throw "invalid_request_arguments" }
    $Temporary = Join-Path $Paths.Ingress (".$Id.tmp")
    [IO.File]::WriteAllBytes($Temporary, $Bytes)
    [IO.File]::Move($Temporary, (Join-Path $Paths.Ingress "$Id.request"), $true)
    try { & $script:Native.StartTask } catch { }
    $ResultPath = Join-Path $Paths.Results "$Id.result"
    $Deadline = (Get-UnixNow) + $WaitSeconds
    while (-not [IO.File]::Exists($ResultPath) -and (Get-UnixNow) -lt $Deadline) {
        Start-Sleep -Seconds 1
        if (((Get-UnixNow) % 60) -eq 0) { try { & $script:Native.StartTask } catch { } }
    }
    if (-not [IO.File]::Exists($ResultPath)) {
        $Pending = Join-Path $Paths.Ingress "$Id.request"
        if ([IO.File]::Exists($Pending)) {
            [IO.File]::Delete($Pending)
            return [ordered]@{ state = "rejected"; reason = "lane_dispatch_unavailable"; 'request-id' = $Id }
        }
        # Claimed by SYSTEM but not yet answered (a long install): the outcome
        # is unknown, not refused; -Lookup returns it later.
        return [ordered]@{ state = "partial"; reason = "claimed_result_pending_use_lookup"; 'request-id' = $Id }
    }
    $Result = Read-Result ([IO.File]::ReadAllBytes($ResultPath))
    if ($Result.'request-id' -cne $Id) { throw "published_result_answers_a_different_request" }
    $Result['bytes'] = [IO.File]::ReadAllBytes($ResultPath)
    return $Result
}
function Compare-WinGetVersion([string]$Left, [string]$Right) {
    # Highest available version: numeric dotted compare when both parse as
    # [Version], ordinal otherwise (the SYSTEM side re-checks availability).
    $L = $null; $R = $null
    if ([Version]::TryParse($Left, [ref]$L) -and [Version]::TryParse($Right, [ref]$R)) { return $L.CompareTo($R) }
    return [StringComparer]::Ordinal.Compare($Left, $Right)
}
function Get-CandidateRecord([string]$Id, [string]$SourceName) {
    # The owner-side view of a package's installed and highest available
    # versions (`-` when unknown), through the lane's pinned WinGet client
    # module under the user's own token — never by parsing winget.exe's
    # table. The controller seals its precondition against this and rechecks
    # it right before submitting; the SYSTEM side checks availability again.
    if (-not (Test-WinGetId $Id) -or $SourceName -cnotin @("winget", "msstore")) { throw "invalid_candidate_arguments" }
    $Installed = "-"; $Available = "-"
    try {
        Import-LaneWinGetModule
        $Have = @(& $script:Native.WinGetInstalled $Id $SourceName)
        if ($Have.Count -eq 1 -and (Test-VersionToken ([string]$Have[0].InstalledVersion))) { $Installed = [string]$Have[0].InstalledVersion }
        $Found = @(& $script:Native.WinGetFind $Id $SourceName)
        if ($Found.Count -eq 1) {
            foreach ($Version in @($Found[0].AvailableVersions)) {
                if (-not (Test-VersionToken ([string]$Version))) { continue }
                if ($Available -ceq "-" -or (Compare-WinGetVersion ([string]$Version) $Available) -gt 0) { $Available = [string]$Version }
            }
        }
    } catch { $Installed = "-"; $Available = "-" }
    return [string[]]@("lane-candidate|1", "package|$Id", "installed|$Installed", "candidate|$Available", "end-candidate|")
}
function Invoke-Candidate {
    Write-Record (Get-CandidateRecord $Package $Source)
    return 0
}
function Invoke-Lookup {
    if (-not (Test-RequestId $RequestId)) { throw "invalid_request_id" }
    $Paths = Get-LanePaths
    $ResultPath = Join-Path $Paths.Results "$RequestId.result"
    if (-not [IO.File]::Exists($ResultPath)) { throw "no_published_result" }
    $Result = Read-Result ([IO.File]::ReadAllBytes($ResultPath))
    [Console]::Out.Write($script:Ascii.GetString([IO.File]::ReadAllBytes($ResultPath)))
    switch ($Result.state) { "completed" { return 0 } "rejected" { return 65 } "partial" { return 71 } default { return 70 } }
}
function Invoke-Request {
    if ($Wait -lt 0 -or $Wait -gt 3600) { throw "invalid_wait" }
    $Result = Submit-Request $Action $Package $Version $Source $PayloadSha256 $PlanId $PlanSha256 $OperationIndex $Wait $RequestId
    if ($Result.Contains('bytes')) { [Console]::Out.Write($script:Ascii.GetString($Result['bytes'])) }
    else {
        Write-Record @("lane-result|1", "request-id|$($Result['request-id'])", "host-id|-", "plan-id|$PlanId", "plan-sha256|$PlanSha256",
            "operation-index|$OperationIndex", "action-id|$Action", "package|$Package", "version|$Version", "state|$($Result.state)",
            "reason|$($Result.reason)", "native-exit|-", "pre-state-sha256|-", "post-state-sha256|-", "started-at|$(Get-UnixNow)",
            "finished-at|$(Get-UnixNow)", "lane-version|-", "lane-sha256|-", "request-sha256|-", "end-result|", "result-sha256|-")
        if ($Result.state -ceq "partial") { return 71 }
        return 75
    }
    switch ($Result.state) { "completed" { return 0 } "rejected" { return 65 } "partial" { return 71 } default { return 70 } }
}

# --- self-test ----------------------------------------------------------------
function New-FixtureNative([hashtable]$World) {
    return [pscustomobject]@{
        IsWindows = $true
        CurrentSid = { return $World.Sid }.GetNewClosure()
        CurrentName = { return "FIXTURE\owner" }
        IsSystem = { return $false }
        IsElevated = { return $true }
        FileOwnerSid = { param([string]$Path) if ($World.ForeignOwner.Contains((Split-Path -Leaf $Path))) { return "S-1-5-21-9-9-9-9999" }; return $World.Sid }.GetNewClosure()
        SetDirectorySddl = { param([string]$Path, [string]$Sddl) $World.Sddl[$Path] = $Sddl }.GetNewClosure()
        SetFileSddl = { param([string]$Path, [string]$Sddl) $World.Sddl[$Path] = $Sddl }.GetNewClosure()
        ReadSddl = { param([string]$Path) if ($World.Sddl.ContainsKey($Path)) { return $World.Sddl[$Path] }; return "" }.GetNewClosure()
        RegisterTask = { param([string]$Xml, [string]$Sddl) $World.Task = @{ Xml = $Xml; Sddl = $Sddl } }.GetNewClosure()
        ReadTask = { if ($null -eq $World.Task) { return $null }; return [pscustomobject]$World.Task }.GetNewClosure()
        UnregisterTask = { $World.Task = $null }.GetNewClosure()
        StartTask = { $Previous = $script:QuietRecords; $script:QuietRecords = $true; try { [void](Invoke-Dispatch) } finally { $script:QuietRecords = $Previous } }
        InstallModule = { param([string]$LockPath, [string]$Destination, [string]$Scratch) [void][IO.Directory]::CreateDirectory($Destination); $World.ModuleLock = $LockPath }.GetNewClosure()
        ImportModule = { param([string]$ManifestPath) }
        WinGetFind = { param([string]$Id, [string]$Source) if ($World.Catalog.ContainsKey("$Id|$Source")) { return @([pscustomobject]@{ Id = $Id; Source = $Source; AvailableVersions = $World.Catalog["$Id|$Source"] }) }; return @() }.GetNewClosure()
        WinGetInstalled = { param([string]$Id, [string]$Source) if ($World.Installed.ContainsKey($Id)) { return @([pscustomobject]@{ Id = $Id; InstalledVersion = $World.Installed[$Id] }) }; return @() }.GetNewClosure()
        WinGetInventory = { return @($World.Installed.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; InstalledVersion = $World.Installed[$_] } }) }.GetNewClosure()
        WinGetInstall = { param([string]$Id, [string]$Source, [string]$Version)
            $World.Calls += "install|$Id|$Source|$Version"
            if ($World.Fail) { return @([pscustomobject]@{ Id = $Id; Status = "InstallError"; InstallerErrorCode = 1603 }) }
            $World.Installed[$Id] = if ($Version -cne "-") { $Version } else { @($World.Catalog["$Id|$Source"])[-1] }
            return @([pscustomobject]@{ Id = $Id; Status = "Ok"; InstallerErrorCode = 0 }) }.GetNewClosure()
        WinGetUpgrade = { param([string]$Id, [string]$Source, [string]$Version)
            $World.Calls += "upgrade|$Id|$Source|$Version"
            $World.Installed[$Id] = $Version
            return @([pscustomobject]@{ Id = $Id; Status = "Ok"; InstallerErrorCode = 0 }) }.GetNewClosure()
        Elevate = { param([string[]]$Arguments) throw "fixture_never_elevates" }
    }
}
function Assert-SelfTest([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "privilege-lane-windows self-test failed: $Message" } }
function Invoke-FixtureRequest([string]$ActionId, [string]$PackageId, [string]$WantedVersion, [string]$SourceName, [string]$Payload = "-") {
    return Submit-Request $ActionId $PackageId $WantedVersion $SourceName $Payload "plan-0123456789abcdef" (Get-Sha256Text "plan") "2" 5
}
function Write-FixtureRequest([string]$Root, [hashtable]$Overrides) {
    $Paths = Get-LanePaths
    $Id = "request-" + (-join ((1..32) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) }))
    $Now = Get-UnixNow
    $Values = @{ "request-id" = $Id; "host-id" = "test-host"; "owner" = "S-1-5-21-1-2-3-1001"; "plan-id" = "fleet-run"; "plan-sha256" = "-"
        "operation-index" = "-"; "action-id" = "lane.probe.v1"; "package" = "-"; "version" = "-"; "source" = "-"; "payload-sha256" = "-"
        "created-at" = [string]$Now; "expires-at" = [string]($Now + 60) }
    foreach ($Key in $Overrides.Keys) { $Values[$Key] = $Overrides[$Key] }
    $Bytes = Render-Request $Values
    if ($Overrides.ContainsKey("tamper")) { $Bytes[$Bytes.Count - 2] = [byte][char]'0' }
    [IO.File]::WriteAllBytes((Join-Path $Paths.Ingress "$Id.request"), $Bytes)
    return $Id
}
function Invoke-SelfTest {
    $Temp = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-lane-selftest-" + [Guid]::NewGuid().ToString("n"))
    [void][IO.Directory]::CreateDirectory($Temp)
    try {
        $Version = Get-PluginVersionBeside (Get-ScriptSelf)
        $Next = ($Version.Split('.')[0..1] + @([int]$Version.Split('.')[2] + 1)) -join "."
        $World = @{ Sid = "S-1-5-21-1-2-3-1001"; Task = $null; Sddl = @{}; ForeignOwner = @(); ModuleLock = $null
            Catalog = @{ "Example.Tool|winget" = @("1.0.0", "1.1.0", "2.0.0"); "Example.Store|msstore" = @("3.0") }
            Installed = @{ "Example.Tool" = "1.0.0" }; Calls = @(); Fail = $false }
        $script:Fixture = $true
        $script:QuietRecords = $true
        $script:Native = New-FixtureNative $World
        $script:LaneRoot = Join-Path $Temp "ProgramData\Roundhouse-Lane"
        # A fixture plugin cache: current version (the script's own tree) and a
        # newer candidate with an integrity manifest, for self-upgrade.
        $PluginRoot = Join-Path $Temp "cache\roundhouse"
        foreach ($V in @($Version, $Next)) {
            [void][IO.Directory]::CreateDirectory((Join-Path $PluginRoot "$V\scripts"))
            [void][IO.Directory]::CreateDirectory((Join-Path $PluginRoot "$V\.codex-plugin"))
            [void][IO.Directory]::CreateDirectory((Join-Path $PluginRoot "$V\references"))
            Copy-Item -LiteralPath (Get-ScriptSelf) -Destination (Join-Path $PluginRoot "$V\scripts\$($script:ScriptName)")
            Set-Content -LiteralPath (Join-Path $PluginRoot "$V\.codex-plugin\plugin.json") -Value ('{ "name": "roundhouse", "version": "' + $V + '" }') -NoNewline
            Set-Content -LiteralPath (Join-Path $PluginRoot "$V\references\windows-winget-provider.lock") -Value "winget-module-lock|1`nmodule|Microsoft.WinGet.Client`nversion|1.29.280`npackage-url|https://www.powershellgallery.com/x`npackage-sha256|$('a' * 64)`nmanifest|Microsoft.WinGet.Client.psd1|$('b' * 64)`nfile|Microsoft.WinGet.Client.psd1|$('b' * 64)`nend-lock|`n" -NoNewline
        }
        Add-Content -LiteralPath (Join-Path $PluginRoot "$Next\scripts\$($script:ScriptName)") -Value "`n# self-test upgrade candidate"
        $WriteManifest = {
            param([string]$Dir, [string]$V)
            $Files = @()
            foreach ($Rel in @(".codex-plugin/plugin.json", "scripts/$($script:ScriptName)")) {
                $Files += @{ path = $Rel; sha256 = (Get-Sha256File (Join-Path $Dir ($Rel.Replace('/', [IO.Path]::DirectorySeparatorChar)))) }
            }
            @{ files = $Files; marketplace = "novotnyllc"; plugin = "roundhouse"; schema = "roundhouse.integrity"; schema_version = 1; version = $V } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Dir "integrity.json")
        }
        & $WriteManifest (Join-Path $PluginRoot $Next) $Next
        $Self = Join-Path $PluginRoot "$Version\scripts\$($script:ScriptName)"
        # The enrollment helpers take the installed copy's location from
        # $PSCommandPath; point them at the fixture cache copy instead.
        Set-Item -Path function:Get-ScriptSelf -Value ([ScriptBlock]::Create("return '$($Self.Replace("'", "''"))'"))

        Assert-SelfTest ((Get-LaneState).State -ceq "needs_one_time_approval") "pre-enrollment state"
        $Installed = Install-Lane "test-host" $World.Sid $PluginRoot $Self
        Assert-SelfTest ($Installed.Version -ceq $Version) "enrolled version"
        $Paths = Get-LanePaths
        Assert-SelfTest ((Get-LaneState).State -ceq "canary_pending") "installed but not yet activated"
        # Nothing but a probe is dispatched while pending.
        $Early = Submit-Request "winget.inventory-machine.v1" "-" "-" "-" "-" "early" "-" "-" 5
        Assert-SelfTest ($Early.state -ceq "rejected" -and $Early.reason -ceq "lane_canary_pending") "non-probe refused while pending: $($Early.reason)"
        # A failed owner canary (the file arrives with a foreign owner) leaves
        # the lane pending, never ready, and journals nothing as complete.
        $World.ForeignOwner = @("request")
        Assert-SelfTest (-not (Invoke-OwnerCanary "test-host")) "owner canary reports failure"
        $World.ForeignOwner = @()
        Assert-SelfTest ((Get-LaneState).State -ceq "canary_pending") "failed canary keeps the lane pending"
        Assert-SelfTest (-not ([IO.File]::ReadAllText($Paths.JournalLog)).Contains("|activation|")) "failed canary did not activate"
        Assert-SelfTest (Invoke-OwnerCanary "test-host") "owner-side canary"
        Assert-SelfTest ((Read-Identity $Paths.Identity).activation -ceq "passed" -and (Get-LaneState).State -ceq "ready") "probe activated the lane"
        Assert-SelfTest (([IO.File]::ReadAllText($Paths.JournalLog)).Contains("|activation|")) "activation journaled"
        Assert-SelfTest ([IO.File]::Exists((Get-LanePaths).ModuleLock)) "module lock copied into the lane root"
        Assert-SelfTest ((Get-LaneState).State -ceq "ready") "post-enrollment state"
        Assert-SelfTest ($World.Sddl[$Paths.Ingress] -ceq (Get-IngressSddl $World.Sid)) "ingress ACL"
        Assert-SelfTest ($World.Sddl[$Paths.Claims] -ceq (Get-ProtectedSddl)) "claims ACL"
        Assert-SelfTest ($World.Task.Sddl -ceq (Get-TaskSddl $World.Sid)) "task security"
        Assert-SelfTest ($World.Task.Xml -match '<UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType>' -and $World.Task.Xml -notmatch 'S4U|InteractiveToken|<Password>') "task principal is LocalSystem without S4U"
        Assert-SelfTest ($World.Task.Xml -match '-Dispatch</Arguments>') "task action"
        Assert-SelfTest ([IO.File]::Exists($Paths.JournalLog)) "journal created"
        # Catalog is closed: argv shapes, foreign actions and surplus fields never reach the queue.
        foreach ($Bad in @(@("winget.install-machine-package.v1", "Example.Tool; del /q C:\", "-", "winget"),
                @("apt.upgrade-package.v1", "curl", "1.0", "-"), @("winget.inventory-machine.v1", "Example.Tool", "-", "-"),
                @("winget.install-machine-package.v1", "Example.Tool", "-", "evil-source"))) {
            $Rejected = $false
            try { [void](Invoke-FixtureRequest $Bad[0] $Bad[1] $Bad[2] $Bad[3]) } catch { $Rejected = $true }
            Assert-SelfTest $Rejected "closed catalog: $($Bad -join ' ')"
        }
        # WinGet actions through the fixture provider.
        $CandidateLines = Get-CandidateRecord "Example.Tool" "winget"
        Assert-SelfTest (($CandidateLines -join "`n") -ceq "lane-candidate|1`npackage|Example.Tool`ninstalled|1.0.0`ncandidate|2.0.0`nend-candidate|") "candidate record: $($CandidateLines -join ' ')"
        $CandidateLines = Get-CandidateRecord "Example.Missing" "winget"
        Assert-SelfTest (($CandidateLines -join "`n").Contains("installed|-`ncandidate|-")) "unknown candidate record"
        $R = Invoke-FixtureRequest "winget.inventory-machine.v1" "-" "-" "-"
        Assert-SelfTest ($R.state -ceq "completed" -and $R.reason -ceq "inventory_verified" -and $R.'plan-id' -ceq "plan-0123456789abcdef" -and $R.'operation-index' -ceq "2") "inventory result"
        $R = Invoke-FixtureRequest "winget.upgrade-machine-package.v1" "Example.Tool" "1.1.0" "winget"
        Assert-SelfTest ($R.state -ceq "completed" -and $R.reason -ceq "package_upgraded" -and $World.Installed["Example.Tool"] -ceq "1.1.0") "upgrade result: $($R.reason)"
        Assert-SelfTest ($World.Calls -contains "upgrade|Example.Tool|winget|1.1.0") "upgrade provider call"
        $LookupBytes = [IO.File]::ReadAllBytes((Join-Path $Paths.Results ($R.'request-id' + ".result")))
        Assert-SelfTest ((Read-Result $LookupBytes).reason -ceq "package_upgraded") "result lookup"
        $R = Invoke-FixtureRequest "winget.upgrade-machine-package.v1" "Example.Tool" "9.9.9" "winget"
        Assert-SelfTest ($R.state -ceq "rejected" -and $R.reason -ceq "version_not_available") "unavailable version"
        $R = Invoke-FixtureRequest "winget.install-machine-package.v1" "Example.Store" "-" "msstore"
        Assert-SelfTest ($R.state -ceq "completed" -and $World.Installed["Example.Store"] -ceq "3.0") "store install"
        $R = Invoke-FixtureRequest "winget.install-machine-package.v1" "Example.Missing" "-" "winget"
        Assert-SelfTest ($R.state -ceq "rejected" -and $R.reason -ceq "package_unknown_to_source") "unknown package"
        $World.Fail = $true
        $R = Invoke-FixtureRequest "winget.install-machine-package.v1" "Example.Tool" "2.0.0" "winget"
        Assert-SelfTest ($R.state -ceq "failed" -and $R.reason -ceq "provider_status_installerror" -and $R.'native-exit' -ceq "1603") "provider failure: $($R.reason)"
        $World.Fail = $false
        # Dispatcher rejections, by name.
        $Id = Write-FixtureRequest $Temp @{ owner = "S-1-5-21-9-9-9-9999" }
        [void](Invoke-Dispatch)
        Assert-SelfTest ((Read-Result ([IO.File]::ReadAllBytes((Join-Path $Paths.Results "$Id.result")))).reason -ceq "owner_mismatch") "owner mismatch"
        $Id = Write-FixtureRequest $Temp @{ "host-id" = "other-host" }
        [void](Invoke-Dispatch)
        Assert-SelfTest ((Read-Result ([IO.File]::ReadAllBytes((Join-Path $Paths.Results "$Id.result")))).reason -ceq "host_id_mismatch") "host mismatch"
        $Id = Write-FixtureRequest $Temp @{ "created-at" = [string]((Get-UnixNow) - 7200); "expires-at" = [string]((Get-UnixNow) - 3600) }
        [void](Invoke-Dispatch)
        Assert-SelfTest ((Read-Result ([IO.File]::ReadAllBytes((Join-Path $Paths.Results "$Id.result")))).reason -ceq "stale_request") "stale request"
        $Id = Write-FixtureRequest $Temp @{ "action-id" = "apt.update-metadata.v1" }
        [void](Invoke-Dispatch)
        Assert-SelfTest ((Read-Result ([IO.File]::ReadAllBytes((Join-Path $Paths.Results "$Id.result")))).reason -ceq "unknown_action_for_platform") "foreign action"
        $Id = Write-FixtureRequest $Temp @{ tamper = $true }
        [void](Invoke-Dispatch)
        Assert-SelfTest ((Read-Result ([IO.File]::ReadAllBytes((Join-Path $Paths.Results "$Id.result")))).reason -ceq "invalid_request_record") "digest tamper"
        $World.ForeignOwner = @("request")
        $Id = Write-FixtureRequest $Temp @{}
        [void](Invoke-Dispatch)
        Assert-SelfTest ((Read-Result ([IO.File]::ReadAllBytes((Join-Path $Paths.Results "$Id.result")))).reason -ceq "request_not_owned_by_enrolled_owner") "NTFS owner"
        $World.ForeignOwner = @()
        # Replay: a claimed id is never executed twice.
        $World.Calls = @()
        $Replay = Join-Path $Paths.Ingress "$Id.request"
        [IO.File]::WriteAllBytes($Replay, (Render-Request @{ "request-id" = $Id; "host-id" = "test-host"; "owner" = $World.Sid; "plan-id" = "fleet-run"; "plan-sha256" = "-"; "operation-index" = "-"; "action-id" = "winget.install-machine-package.v1"; "package" = "Example.Tool"; "version" = "2.0.0"; "source" = "winget"; "payload-sha256" = "-"; "created-at" = [string](Get-UnixNow); "expires-at" = [string]((Get-UnixNow) + 60) }))
        [void](Invoke-Dispatch)
        Assert-SelfTest ((Read-Result ([IO.File]::ReadAllBytes((Join-Path $Paths.Results "$Id.result")))).reason -ceq "request_not_owned_by_enrolled_owner" -and $World.Calls.Count -eq 0) "replay keeps the original result"
        Assert-SelfTest (([IO.File]::ReadAllText($Paths.JournalLog)) -match "\|request\|$Id\|-\|-\|rejected\|replayed_request\|") "replay journaled"
        # Rate limit.
        $Saved = [IO.File]::ReadAllText($Paths.JournalLog)
        for ($i = 0; $i -lt $script:MaximumRequestsPerHour; $i++) { Write-Journal "request" ("request-" + ("{0:x32}" -f $i)) "lane.probe.v1" "-" "completed" "probe_completed" "-" "-" }
        $R = Invoke-FixtureRequest "lane.probe.v1" "-" "-" "-"
        Assert-SelfTest ($R.state -ceq "rejected" -and $R.reason -ceq "rate_limited") "rate limit"
        [IO.File]::WriteAllText($Paths.JournalLog, $Saved)
        # Self-upgrade: same version, wrong digest, tampered candidate, then success.
        $NextScript = Join-Path $PluginRoot "$Next\scripts\$($script:ScriptName)"
        $NextSha = Get-Sha256File $NextScript
        $R = Invoke-FixtureRequest "lane.self-upgrade.v1" "-" $Version "-" $NextSha
        Assert-SelfTest ($R.state -ceq "rejected" -and $R.reason -ceq "version_not_newer") "self-upgrade same version"
        $R = Invoke-FixtureRequest "lane.self-upgrade.v1" "-" $Next "-" (Get-Sha256Text "wrong")
        Assert-SelfTest ($R.state -ceq "rejected" -and $R.reason -ceq "candidate_lane_digest_mismatch") "self-upgrade wrong digest: $($R.reason)"
        Add-Content -LiteralPath $NextScript -Value "# tamper"
        $R = Invoke-FixtureRequest "lane.self-upgrade.v1" "-" $Next "-" $NextSha
        Assert-SelfTest ($R.state -ceq "rejected" -and $R.reason -ceq "candidate_file_digest_mismatch") "self-upgrade tampered: $($R.reason)"
        & $WriteManifest (Join-Path $PluginRoot $Next) $Next
        $NextSha = Get-Sha256File $NextScript
        $R = Invoke-FixtureRequest "lane.self-upgrade.v1" "-" $Next "-" $NextSha
        Assert-SelfTest ($R.state -ceq "completed" -and $R.reason -ceq "lane_upgraded") "self-upgrade: $($R.reason)"
        Assert-SelfTest ((Get-Sha256File $Paths.Script) -ceq $NextSha -and (Read-Identity $Paths.Identity).'lane-version' -ceq $Next) "upgraded identity"
        Assert-SelfTest ((Get-LaneState).State -ceq "ready") "state after upgrade"
        # ACL drift on a protected path is drift, even with the bytes intact.
        $SavedSddl = $World.Sddl[$Paths.Script]
        $World.Sddl[$Paths.Script] = "O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;$($World.Sid))"
        Assert-SelfTest ((Get-LaneState).State -ceq "drifted" -and (Get-LaneState).Detail.Contains("protected ACL drifted")) "owner-writable script is drift"
        $World.Sddl[$Paths.Script] = $SavedSddl
        Assert-SelfTest ((Get-LaneState).State -ceq "ready") "restored ACL is ready again"
        # A request SYSTEM already claimed but has not answered is pending, not rejected.
        $Claimed = "request-" + ("{0:x32}" -f 777)
        [void][IO.Directory]::CreateDirectory((Join-Path $Paths.Claims $Claimed))
        $Pending = Submit-Request "lane.probe.v1" "-" "-" "-" "-" "pending" "-" "-" 0 $Claimed
        Assert-SelfTest ($Pending.state -ceq "partial" -and $Pending.reason -ceq "claimed_result_pending_use_lookup") "claimed timeout is pending: $($Pending.reason)"
        # Drift: a modified installed script is never dispatched.
        Add-Content -LiteralPath $Paths.Script -Value "# drift"
        Assert-SelfTest ((Get-LaneState).State -ceq "drifted") "drift detection"
        $Threw = $false; try { [void](Invoke-Dispatch) } catch { $Threw = $true }
        Assert-SelfTest $Threw "dispatch refuses a drifted script"
        # Revocation keeps the journal only.
        Remove-Lane
        Assert-SelfTest ($null -eq $World.Task -and -not [IO.File]::Exists($Paths.Script) -and [IO.File]::Exists($Paths.JournalLog)) "revocation"
        Assert-SelfTest ((Get-LaneState).State -ceq "needs_one_time_approval") "state after revoke"
        $script:QuietRecords = $false
        Write-Output "PASS: privilege-lane-windows fixture-safe self-check"
    } finally {
        if ([IO.Directory]::Exists($Temp)) { [IO.Directory]::Delete($Temp, $true) }
    }
}

if ($SelfTest) { Invoke-SelfTest; return }
$script:Native = New-NativeBoundary
if (-not $IsWindows) {
    if ($Status) { Write-Record @("lane-status|1", "state|unsupported", "platform|$(if ($IsMacOS) { 'macos' } else { 'linux' })", "detail|not windows", "end-status|"); exit 69 }
    throw "unsupported_context"
}
$script:LaneRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) $script:LaneDirectoryName
$ExitCode = 0
if ($Status) { $ExitCode = Invoke-Status }
elseif ($Enroll) { $ExitCode = Invoke-Enroll }
elseif ($Revoke) { $ExitCode = Invoke-Revoke }
elseif ($Dispatch) { $ExitCode = Invoke-Dispatch }
elseif ($Request) { $ExitCode = Invoke-Request }
elseif ($Lookup) { $ExitCode = Invoke-Lookup }
elseif ($Candidate) { $ExitCode = Invoke-Candidate }
exit $ExitCode
