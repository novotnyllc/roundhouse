[CmdletBinding(DefaultParameterSetName = "Status")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Status")][switch]$Status,
    [Parameter(Mandatory = $true, ParameterSetName = "Preview")][switch]$Preview,
    [Parameter(Mandatory = $true, ParameterSetName = "Install")][switch]$Install,
    [Parameter(Mandatory = $true, ParameterSetName = "Repair")][switch]$Repair,
    [Parameter(Mandatory = $true, ParameterSetName = "Verify")][switch]$Verify,
    [Parameter(Mandatory = $true, ParameterSetName = "PreviewRevoke")][switch]$PreviewRevoke,
    [Parameter(Mandatory = $true, ParameterSetName = "Revoke")][switch]$Revoke,
    [Parameter(ParameterSetName = "PreviewRevoke")]
    [Parameter(ParameterSetName = "Revoke")][switch]$Emergency,
    [Parameter(Mandatory = $true, ParameterSetName = "Install")]
    [Parameter(Mandatory = $true, ParameterSetName = "Repair")]
    [Parameter(Mandatory = $true, ParameterSetName = "Revoke")]
    [ValidatePattern('^[0-9a-f]{64}$')][string]$Confirmation,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Ascii = [Text.Encoding]::ASCII
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:RequestAccountName = "MachineUtilitiesRequest"
$script:EndpointPrincipal = "machine-utilities-windows"
$script:SystemTaskName = "MachineUtilitiesBrokerV1"
$script:ProfileTaskName = "MachineUtilitiesProfileV1"
$script:TaskSddl = "O:SYG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
$script:SlotQuotaBytes = [int64]68157440
$script:SlotWarningBytes = [int64]67108864
$script:FirewallRuleName = "Machine Utilities Windows SFTP v1"
$script:FirewallRuleId = "MachineUtilities-Windows-Sftp-v1"
$script:FirewallRuleGroup = "Machine Utilities"
$script:ManagedBlockBegin = "# BEGIN MACHINE-UTILITIES WINDOWS-SFTP v1"
$script:ManagedBlockEnd = "# END MACHINE-UTILITIES WINDOWS-SFTP v1"
$script:MaximumIntentBytes = 32768
$script:MaximumReceiptBytes = 65536
$script:MaximumCaBytes = 16384
$script:MaximumKrlBytes = 16777216
$script:MaximumBrokerResultBytes = 4096
$script:MaximumBrokerReadinessBytes = 65536
$script:ClockSkewSeconds = 300
$script:DrainTimeoutSeconds = 600
$script:AuditReservationBytes = 1048576
$script:TerminalReservationBytes = 65536
$script:ReservationFillByte = [byte]0xA5
$script:ContractVersion = "1"

function Get-Sha256Bytes([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $Hasher.Dispose() }
}

function Test-FixedTimeBytesEqual([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    [int]$Difference = $Left.Count -bxor $Right.Count
    [int]$Count = [Math]::Max($Left.Count, $Right.Count)
    for ($Index = 0; $Index -lt $Count; $Index++) {
        [int]$LeftByte = 0; [int]$RightByte = 0
        if ($Index -lt $Left.Count) { $LeftByte = $Left[$Index] }
        if ($Index -lt $Right.Count) { $RightByte = $Right[$Index] }
        $Difference = $Difference -bor ($LeftByte -bxor $RightByte)
    }
    return $Difference -eq 0
}

function Get-Sha256Text([string]$Text) { return Get-Sha256Bytes $script:Ascii.GetBytes($Text) }

function Test-Digest([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }
function Test-Thumbprint([string]$Value) { return $Value -cmatch '^(?:[0-9A-F]{40}|[0-9A-F]{64})$' }
function Test-Sid([string]$Value) {
    return $Value -cmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -and $Value -cnotmatch '-500$'
}
function Test-Token([string]$Value) {
    return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:+@,-]{0,255}$'
}
function Test-HostName([string]$Value) {
    return $Value.Length -le 253 -and $Value -cmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'
}
function Test-FleetDomain([string]$Value) {
    return (Test-HostName $Value) -and $Value.Contains('.')
}
function Test-UInt([string]$Value) { return $Value -cmatch '^(0|[1-9][0-9]{0,18})$' }
function Test-PositiveUInt([string]$Value) { return $Value -cmatch '^[1-9][0-9]{0,18}$' }
function Test-SshFingerprint([string]$Value) {
    return $Value -cmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'
}

function ConvertFrom-CanonicalAsciiBytes([byte[]]$Bytes, [int]$MaximumBytes, [string]$Label) {
    if ($Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or $Bytes[-1] -ne 10) {
        throw "invalid_$Label"
    }
    foreach ($Byte in $Bytes) {
        if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { throw "invalid_$Label" }
    }
    $Text = $script:Ascii.GetString($Bytes)
    if ($Text.Contains("`r") -or $Text.Contains("`0")) { throw "invalid_$Label" }
    return [string[]]@($Text.Substring(0, $Text.Length - 1).Split("`n"))
}

function ConvertTo-CanonicalAsciiBytes([string[]]$Lines) {
    foreach ($Line in $Lines) {
        if ($Line -cnotmatch '\A[\x20-\x7e]*\z') { throw "non_ascii_record" }
    }
    return $script:Ascii.GetBytes(($Lines -join "`n") + "`n")
}

function Read-FixedFields(
    [string[]]$Lines,
    [string[]]$Names,
    [string]$Header,
    [string]$Trailer,
    [string]$Label
) {
    if ($Lines.Count -ne $Names.Count + 2 -or $Lines[0] -cne $Header -or $Lines[-1] -cne $Trailer) {
        throw "invalid_$Label"
    }
    $Result = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or
            $Parts[1].Length -gt 4096 -or $Result.Contains($Parts[0])) {
            throw "invalid_$Label"
        }
        $Result[$Parts[0]] = $Parts[1]
    }
    return $Result
}

function Get-ControllerIntentFieldNames {
    return [string[]]@(
        "schema-version", "operation", "host", "fleet-domain", "request-account", "request-sid",
        "endpoint-principal", "trust-mode", "primary-ca-fingerprint", "primary-ca-generation",
        "previous-ca-fingerprint", "previous-ca-generation", "ca-public-sha256", "krl-generation",
        "krl-sha256", "management-cidrs", "u3-epoch", "u3-generation-sha256",
        "u3-active-pointer-sha256", "u3-policy-sha256", "u3-constraints-sha256",
        "u3-winget-context-sha256", "u3-provider-lock-sha256", "u3-broker-sha256",
        "u3-native-canary-receipt-sha256", "u3-native-canary-signature-sha256",
        "u3-native-canary-evidence-sha256", "u3-system-task-xml-sha256",
        "u3-system-task-sddl-sha256", "u3-profile-task-xml-sha256",
        "u3-profile-task-sddl-sha256", "chroot-contract-sha256", "slot-acl-sha256",
        "results-acl-sha256", "quota-contract-sha256", "openssh-contract-sha256",
        "issued-at", "expires-at"
    )
}

function Test-Cidr([string]$Value) {
    $Parts = $Value.Split('/')
    if ($Parts.Count -ne 2 -or $Parts[1] -notmatch '^(0|[1-9][0-9]{0,2})$') { return $false }
    [Net.IPAddress]$Address = $null
    if (-not [Net.IPAddress]::TryParse($Parts[0], [ref]$Address)) { return $false }
    $Prefix = [int]$Parts[1]
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return $Prefix -le 32 }
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { return $Prefix -le 128 }
    return $false
}

function Read-ManagementCidrs([string]$Value) {
    if ($Value.Length -lt 1 -or $Value.Length -gt 2048) { throw "invalid_management_cidrs" }
    $Items = [string[]]@($Value.Split(','))
    if ($Items.Count -lt 1 -or $Items.Count -gt 32) { throw "invalid_management_cidrs" }
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $Previous = ""
    foreach ($Item in $Items) {
        if (-not (Test-Cidr $Item) -or -not $Seen.Add($Item) -or
            ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Item) -ge 0)) {
            throw "invalid_management_cidrs"
        }
        $Previous = $Item
    }
    return $Items
}

function Read-ControllerIntent([byte[]]$Bytes, [string]$ExpectedOperation) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes $script:MaximumIntentBytes "controller_intent"
    $Fields = Read-FixedFields $Lines (Get-ControllerIntentFieldNames) `
        "windows-sftp-controller-intent|1" "end-intent|" "controller_intent"
    if ($Fields.'schema-version' -cne $script:ContractVersion -or
        $Fields.operation -cnotin @("install", "repair") -or
        ($ExpectedOperation.Length -gt 0 -and $Fields.operation -cne $ExpectedOperation) -or
        -not (Test-HostName $Fields.host) -or -not (Test-FleetDomain $Fields.'fleet-domain') -or
        $Fields.'request-account' -cne $script:RequestAccountName -or
        $Fields.'endpoint-principal' -cne $script:EndpointPrincipal -or
        -not (Test-Sid $Fields.'request-sid') -or
        $Fields.'trust-mode' -cnotin @("single", "dual") -or
        -not (Test-SshFingerprint $Fields.'primary-ca-fingerprint') -or
        -not (Test-PositiveUInt $Fields.'primary-ca-generation') -or
        -not (Test-PositiveUInt $Fields.'krl-generation') -or
        -not (Test-PositiveUInt $Fields.'u3-epoch') -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at')) {
        throw "invalid_controller_intent"
    }
    if ($Fields.'trust-mode' -ceq "single") {
        if ($Fields.'previous-ca-fingerprint' -cne "-" -or $Fields.'previous-ca-generation' -cne "0") {
            throw "invalid_controller_intent"
        }
    } elseif (-not (Test-SshFingerprint $Fields.'previous-ca-fingerprint') -or
        -not (Test-PositiveUInt $Fields.'previous-ca-generation') -or
        $Fields.'previous-ca-fingerprint' -ceq $Fields.'primary-ca-fingerprint') {
        throw "invalid_controller_intent"
    }
    foreach ($Name in @(
        "ca-public-sha256", "krl-sha256", "u3-generation-sha256", "u3-active-pointer-sha256",
        "u3-policy-sha256", "u3-constraints-sha256", "u3-winget-context-sha256",
        "u3-provider-lock-sha256", "u3-broker-sha256", "u3-native-canary-receipt-sha256",
        "u3-native-canary-signature-sha256", "u3-native-canary-evidence-sha256",
        "u3-system-task-xml-sha256", "u3-system-task-sddl-sha256", "u3-profile-task-xml-sha256",
        "u3-profile-task-sddl-sha256", "chroot-contract-sha256", "slot-acl-sha256",
        "results-acl-sha256", "quota-contract-sha256", "openssh-contract-sha256")) {
        if (-not (Test-Digest $Fields[$Name])) { throw "invalid_controller_intent" }
    }
    [void](Read-ManagementCidrs $Fields.'management-cidrs')
    [int64]$IssuedAt = [int64]$Fields.'issued-at'
    [int64]$ExpiresAt = [int64]$Fields.'expires-at'
    if ($IssuedAt -lt 1 -or $ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 86400) {
        throw "invalid_controller_intent"
    }
    return [pscustomobject]@{
        Fields = $Fields
        Bytes = $Bytes
        Sha256 = Get-Sha256Bytes $Bytes
        IssuedAt = $IssuedAt
        ExpiresAt = $ExpiresAt
    }
}

function Read-BootstrapReceipt([byte[]]$Bytes, [string]$ExpectedStageRoot, [string]$ExpectedScriptPath) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 16384 "bootstrap_receipt"
    $Fields = Read-FixedFields $Lines @(
        "scope", "publisher-thumbprint", "release-signature-status", "bootstrap-verifier-sha256",
        "candidate-sha256", "protected-copy-sha256", "protected-copy-path", "protected-root",
        "controller-signing-thumbprint", "controller-intent-path", "controller-signature-path",
        "native-canary-signing-thumbprint", "native-canary-receipt-root"
    ) "windows-sftp-bootstrap-receipt|1" "end-bootstrap|" "bootstrap_receipt"
    if ($Fields.scope -cne "native" -or $Fields.'release-signature-status' -cne "valid" -or
        -not (Test-Thumbprint $Fields.'publisher-thumbprint') -or
        -not (Test-Thumbprint $Fields.'controller-signing-thumbprint') -or
        -not (Test-Thumbprint $Fields.'native-canary-signing-thumbprint') -or
        -not (Test-Digest $Fields.'bootstrap-verifier-sha256') -or
        -not (Test-Digest $Fields.'candidate-sha256') -or
        -not (Test-Digest $Fields.'protected-copy-sha256') -or
        $Fields.'candidate-sha256' -cne $Fields.'protected-copy-sha256' -or
        $Fields.'protected-copy-path' -cne $ExpectedScriptPath -or
        $Fields.'protected-root' -cne $ExpectedStageRoot -or
        $Fields.'controller-intent-path' -cne ($ExpectedStageRoot + "\controller.intent") -or
        $Fields.'controller-signature-path' -cne ($ExpectedStageRoot + "\controller.intent.p7s") -or
        $Fields.'native-canary-receipt-root' -cne ($ExpectedStageRoot + "\native-canary")) {
        throw "invalid_bootstrap_receipt"
    }
    return $Fields
}

function Read-ActivePointer([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1024 "active_pointer"
    $Fields = Read-FixedFields $Lines @("epoch", "generation-sha256") `
        "machine-utilities-active-generation|1" "end-generation|" "active_pointer"
    if (-not (Test-PositiveUInt $Fields.epoch) -or -not (Test-Digest $Fields.'generation-sha256')) {
        throw "invalid_active_pointer"
    }
    return $Fields
}

function Get-U3ContractDigests([string]$RequestSid) {
    $ProtectedDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    $SlotDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$RequestSid)"
    $SlotFile = "O:${RequestSid}G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;$RequestSid)"
    $ResultsDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$RequestSid)"
    $ResultFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x120089;;;$RequestSid)"
    $ChrootLines = @(
        "windows-sftp-chroot-contract|1", "chroot|C:\ProgramData\MachineUtilities\chroot",
        "request|/ingress/slot/request", "signature|/ingress/slot/request.sig",
        "payload|/ingress/slot/payload", "commit|/ingress/slot/commit",
        "results|/results/<request-id>.result", "projection|direct-non-reparse",
        "end-chroot|"
    )
    $SlotLines = @(
        "windows-sftp-slot-acl-contract|1", "slot-directory-sddl|$SlotDirectory",
        "slot-file-sddl|$SlotFile", "file-count|4", "create|denied", "delete|denied",
        "rename|denied", "list|denied", "owner-rights-write-data-only|true", "end-slot-acl|"
    )
    $ResultsLines = @(
        "windows-sftp-results-acl-contract|1", "results-directory-sddl|$ResultsDirectory",
        "result-file-sddl|$ResultFile", "create|denied", "write|denied", "delete|denied",
        "rename|denied", "list|denied", "end-results-acl|"
    )
    $QuotaLines = @(
        "windows-sftp-quota-contract|1", "request-sid|$RequestSid", "limit-bytes|$($script:SlotQuotaBytes)",
        "warning-bytes|$($script:SlotWarningBytes)", "tracking|enabled", "enforcement|enabled",
        "volume|C:\ProgramData", "end-quota|"
    )
    $OpenSshLines = @(
        "windows-sftp-openssh-contract|1", "request-account|$($script:RequestAccountName)",
        "endpoint-principal|$($script:EndpointPrincipal)", "chroot|C:\ProgramData\MachineUtilities\chroot",
        "force-command|internal-sftp", "authentication|publickey-ca-certificate",
        "password|disabled", "keyboard-interactive|disabled", "pty|disabled", "x11|disabled",
        "tcp-forwarding|disabled", "stream-local-forwarding|disabled", "agent-forwarding|disabled",
        "tunnel|disabled", "user-rc|disabled", "user-environment|disabled", "permit-open|none",
        "permit-listen|none", "authorized-principals-command|absent", "end-openssh|"
    )
    return [pscustomobject]@{
        ProtectedDirectory = $ProtectedDirectory
        SlotDirectory = $SlotDirectory
        SlotFile = $SlotFile
        ResultsDirectory = $ResultsDirectory
        ResultFile = $ResultFile
        Chroot = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $ChrootLines)
        Slot = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $SlotLines)
        Results = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $ResultsLines)
        Quota = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $QuotaLines)
        OpenSsh = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $OpenSshLines)
    }
}

function Get-MachineRegistryString([string]$SubKey, [string]$Name) {
    $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $Key = $Base.OpenSubKey($SubKey, $false)
        if ($null -eq $Key) { throw "protected_registry_value_missing" }
        try {
            $Value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $Value -or $Value -isnot [string]) { throw "protected_registry_value_missing" }
            return [string]$Value
        } finally { $Key.Dispose() }
    } finally { $Base.Dispose() }
}

function Get-NativeLayout {
    if (-not $IsWindows) { throw "unsupported_platform" }
    $SystemRoot = Get-MachineRegistryString "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "SystemRoot"
    $ProgramDataRaw = Get-MachineRegistryString `
        "SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" "ProgramData"
    if ($SystemRoot -cne 'C:\Windows' -or $ProgramDataRaw -cnotin @("%SystemDrive%\ProgramData", "C:\ProgramData")) {
        throw "unsupported_protected_layout"
    }
    $SystemDrive = $SystemRoot.Substring(0, 2)
    $ProgramData = if ($ProgramDataRaw.StartsWith("%SystemDrive%", [StringComparison]::Ordinal)) {
        $SystemDrive + $ProgramDataRaw.Substring(13)
    } else { $ProgramDataRaw }
    if ($ProgramData -cne ($SystemDrive + "\ProgramData")) { throw "unsupported_protected_layout" }
    $U3Root = $ProgramData + "\MachineUtilities"
    $U6Root = $ProgramData + "\MachineUtilities-Sftp"
    $StageRoot = $ProgramData + "\MachineUtilities-Sftp-Bootstrap"
    return [pscustomobject]@{
        ProgramData = $ProgramData
        SystemRoot = $SystemRoot
        U3Root = $U3Root
        U3State = $U3Root + "\state"
        U3ActivePointer = $U3Root + "\active.generation"
        U3BrokerLock = $U3Root + "\state\broker.lock"
        U3Drain = $U3Root + "\state\drain"
        U3Trust = $U3Root + "\trust"
        U3HostIdentity = $U3Root + "\host.identity"
        Chroot = $U3Root + "\chroot"
        Slot = $U3Root + "\chroot\ingress\slot"
        Results = $U3Root + "\chroot\results"
        U6Root = $U6Root
        U6State = $U6Root + "\state"
        Generations = $U6Root + "\generations"
        ActivePointer = $U6Root + "\state\active"
        PublicRoot = $ProgramData + "\MachineUtilities-Sftp-Public"
        StageRoot = $StageRoot
        BootstrapReceipt = $StageRoot + "\bootstrap.receipt"
        BootstrapVerifier = $StageRoot + "\bootstrap-verifier.ps1"
        ProtectedScript = $StageRoot + "\scripts\enroll-windows-sftp.ps1"
        Intent = $StageRoot + "\controller.intent"
        IntentSignature = $StageRoot + "\controller.intent.p7s"
        ControllerReceipt = $StageRoot + "\controller.receipt"
        ControllerReceiptSignature = $StageRoot + "\controller.receipt.p7s"
        RevokeIntent = $StageRoot + "\controller.revoke"
        RevokeIntentSignature = $StageRoot + "\controller.revoke.p7s"
        NativeCanaryRoot = $StageRoot + "\native-canary"
        CaPublic = $StageRoot + "\fleet-ca.pub"
        Krl = $StageRoot + "\revoked.krl"
        Sshd = $SystemRoot + "\System32\OpenSSH\sshd.exe"
        SshKeygen = $SystemRoot + "\System32\OpenSSH\ssh-keygen.exe"
        Sftp = $SystemRoot + "\System32\OpenSSH\sftp.exe"
        Ssh = $SystemRoot + "\System32\OpenSSH\ssh.exe"
        Sc = $SystemRoot + "\System32\sc.exe"
        Fsutil = $SystemRoot + "\System32\fsutil.exe"
        SshdConfig = $ProgramData + "\ssh\sshd_config"
        HostEd25519Key = $ProgramData + "\ssh\ssh_host_ed25519_key"
        HostEd25519PublicKey = $ProgramData + "\ssh\ssh_host_ed25519_key.pub"
    }
}

function Write-TransportStatus([string]$State, [string]$Reason, [string]$IntentSha256 = "-") {
    $Lines = @(
        "windows-sftp-enrollment-status|1", "state|$State", "reason|$Reason",
        "platform-boundary|windows", "transport-ready|$($State -ceq 'ready')".ToLowerInvariant(),
        "controller-trust|not-activated", "readiness-authority|local-observation-only",
        "intent-sha256|$IntentSha256", "end-status|"
    )
    [Console]::Out.Write($script:Ascii.GetString((ConvertTo-CanonicalAsciiBytes $Lines)))
}

function Read-HeldBytes([string]$Path, [int64]$MaximumBytes) {
    if ($MaximumBytes -lt 1) { throw "invalid_read_bound" }
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        if ($Stream.Length -lt 1 -or $Stream.Length -gt $MaximumBytes) { throw "bounded_file_invalid" }
        [byte[]]$Bytes = [byte[]]::new([int]$Stream.Length)
        $Offset = 0
        while ($Offset -lt $Bytes.Length) {
            $Count = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
            if ($Count -le 0) { throw "bounded_file_short_read" }
            $Offset += $Count
        }
        if ($Stream.Position -ne $Stream.Length) { throw "bounded_file_drift" }
        return $Bytes
    } finally { $Stream.Dispose() }
}

function Assert-ExactSecurityDescriptor([string]$ExpectedSddl, [string]$ObservedSddl, [string]$Label) {
    try {
        $Expected = [Security.AccessControl.RawSecurityDescriptor]::new($ExpectedSddl)
        $Observed = [Security.AccessControl.RawSecurityDescriptor]::new($ObservedSddl)
    } catch { throw "${Label}_security_descriptor_invalid" }
    [byte[]]$ExpectedBytes = [byte[]]::new($Expected.BinaryLength)
    [byte[]]$ObservedBytes = [byte[]]::new($Observed.BinaryLength)
    $Expected.GetBinaryForm($ExpectedBytes, 0)
    $Observed.GetBinaryForm($ObservedBytes, 0)
    if ((Get-Sha256Bytes $ExpectedBytes) -cne (Get-Sha256Bytes $ObservedBytes)) {
        throw "${Label}_security_descriptor_drift"
    }
}

function Get-PathSddl([string]$Path) {
    $Acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path -ErrorAction Stop
    return $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
}

function Assert-PathSddl([string]$Path, [string]$ExpectedSddl, [string]$Label = "path") {
    Assert-ExactSecurityDescriptor $ExpectedSddl (Get-PathSddl $Path) $Label
}

function Assert-NoReparseAncestors([string]$Path, [string]$Boundary) {
    $FullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $FullBoundary = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    if (-not $FullPath.Equals($FullBoundary, [StringComparison]::OrdinalIgnoreCase) -and
        -not $FullPath.StartsWith($FullBoundary + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "path_outside_protected_boundary"
    }
    $Current = $FullPath
    while ($true) {
        if ([IO.File]::Exists($Current) -or [IO.Directory]::Exists($Current)) {
            $Item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Current -Force -ErrorAction Stop
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $null -ne $Item.LinkType) { throw "reparse_path_forbidden" }
        }
        if ($Current.Equals($FullBoundary, [StringComparison]::OrdinalIgnoreCase)) { break }
        $Parent = [IO.Directory]::GetParent($Current)
        if ($null -eq $Parent) { throw "path_outside_protected_boundary" }
        $Current = $Parent.FullName.TrimEnd('\')
    }
}

function Invoke-CleanNative(
    [string]$FilePath,
    [string[]]$Arguments,
    [object]$Layout,
    [int]$TimeoutSeconds = 30,
    [int]$MaximumOutputBytes = 1048576
) {
    if (-not [IO.File]::Exists($FilePath) -or $TimeoutSeconds -lt 1 -or $MaximumOutputBytes -lt 1) {
        throw "native_invocation_invalid"
    }
    Assert-NoReparseAncestors $FilePath $Layout.SystemRoot
    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $FilePath
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    foreach ($Argument in $Arguments) {
        if ($Argument.Contains("`0") -or $Argument.Contains("`r") -or $Argument.Contains("`n")) {
            throw "native_argument_invalid"
        }
        [void]$Info.ArgumentList.Add($Argument)
    }
    $Info.Environment.Clear()
    $Info.Environment["SystemRoot"] = $Layout.SystemRoot
    $Info.Environment["WINDIR"] = $Layout.SystemRoot
    $Info.Environment["ProgramData"] = $Layout.ProgramData
    $Info.Environment["PATH"] = $Layout.SystemRoot + "\System32;" +
        $Layout.SystemRoot + "\System32\OpenSSH"
    $Info.Environment["ComSpec"] = $Layout.SystemRoot + "\System32\cmd.exe"
    $Info.Environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
    $Process = [Diagnostics.Process]::new(); $Process.StartInfo = $Info
    try {
        if (-not $Process.Start()) { throw "native_start_failed" }
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $Process.Kill($true) } catch { }
            throw "native_timeout"
        }
        $Output = $OutputTask.GetAwaiter().GetResult()
        $ErrorText = $ErrorTask.GetAwaiter().GetResult()
        if ($script:Utf8.GetByteCount($Output) + $script:Utf8.GetByteCount($ErrorText) -gt $MaximumOutputBytes) {
            throw "native_output_too_large"
        }
        return [pscustomobject]@{ ExitCode = $Process.ExitCode; StdOut = $Output; StdErr = $ErrorText }
    } finally { $Process.Dispose() }
}

function Test-DetachedCmsSignature(
    [byte[]]$Content,
    [byte[]]$Signature,
    [string]$ExpectedThumbprint,
    [int64]$IssuedAt,
    [int64]$ExpiresAt
) {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
        $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
            [Security.Cryptography.Pkcs.ContentInfo]::new($Content), $true)
        $Cms.Decode($Signature)
        $Cms.CheckSignature($true)
        if ($Cms.SignerInfos.Count -ne 1 -or $null -eq $Cms.SignerInfos[0].Certificate) { return $false }
        $Certificate = $Cms.SignerInfos[0].Certificate
        if ($Certificate.Thumbprint.ToUpperInvariant() -cne $ExpectedThumbprint) { return $false }
        $Issued = [DateTimeOffset]::FromUnixTimeSeconds($IssuedAt).UtcDateTime
        $Expires = [DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt).UtcDateTime
        return $Certificate.NotBefore.ToUniversalTime() -le $Issued -and
            $Certificate.NotAfter.ToUniversalTime() -ge $Expires
    } catch { return $false }
}

function Get-NativeCanaryFieldNames {
    return [string[]]@(
        "nonce", "host", "request-sid", "intent-sha256", "configuration-sha256",
        "firewall-contract-sha256", "host-key-fingerprint", "issued-at", "expires-at",
        "sshd-config-syntax", "sshd-effective-config", "sshd-service-automatic",
        "sshd-service-restart", "preactivation-account-disabled", "ca-certificate-auth", "exact-endpoint-principal",
        "source-address-inside", "source-address-outside", "broad-firewall-not-widened",
        "internal-sftp", "fixed-slot", "sanitized-result-read", "shell-denied", "exec-denied",
        "scp-denied", "other-subsystem-denied", "pty-denied", "environment-denied",
        "x11-denied", "tcp-forwarding-denied", "streamlocal-forwarding-denied",
        "agent-forwarding-denied", "tunnel-denied", "task-query-denied", "task-run-denied",
        "task-change-denied", "protected-state-denied", "chroot-escape-denied",
        "create-denied", "delete-denied", "rename-denied", "list-denied",
        "owner-change-denied", "dacl-change-denied", "quota-enforced",
        "openssh-y-verify", "openssh-print-pubkey", "openssh-certificate-parse",
        "krl-rejection", "dual-ca-overlap", "power-loss-recovery", "raw-evidence-sha256"
    )
}

function Read-NativeCanaryReceipt(
    [byte[]]$ReceiptBytes,
    [byte[]]$SignatureBytes,
    [byte[]]$EvidenceBytes,
    [object]$Intent,
    [string]$ExpectedThumbprint,
    [string]$ExpectedConfigurationSha256,
    [string]$ExpectedFirewallSha256,
    [string]$ExpectedHostKeyFingerprint,
    [string]$ExpectedNonce = "",
    [switch]$Fixture,
    [switch]$Historical
) {
    $Fields = Read-FixedFields `
        (ConvertFrom-CanonicalAsciiBytes $ReceiptBytes 32768 "transport_canary_receipt") `
        (Get-NativeCanaryFieldNames) "windows-sftp-native-canary|1" "end-canary|" `
        "transport_canary_receipt"
    foreach ($Name in @($Fields.Keys | Where-Object { $_ -notin @(
                "nonce", "host", "request-sid", "intent-sha256", "configuration-sha256",
                "firewall-contract-sha256", "host-key-fingerprint", "issued-at", "expires-at",
                "raw-evidence-sha256") })) {
        if ($Fields[$Name] -cne "passed") { throw "transport_native_canary_incomplete" }
    }
    if (-not (Test-Digest $Fields.nonce) -or ($ExpectedNonce.Length -gt 0 -and $Fields.nonce -cne $ExpectedNonce) -or
        $Fields.host -cne $Intent.Fields.host -or
        $Fields.'request-sid' -cne $Intent.Fields.'request-sid' -or
        $Fields.'intent-sha256' -cne $Intent.Sha256 -or
        $Fields.'configuration-sha256' -cne $ExpectedConfigurationSha256 -or
        $Fields.'firewall-contract-sha256' -cne $ExpectedFirewallSha256 -or
        $Fields.'host-key-fingerprint' -cne $ExpectedHostKeyFingerprint -or
        $Fields.'raw-evidence-sha256' -cne (Get-Sha256Bytes $EvidenceBytes) -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at')) {
        throw "transport_native_canary_provenance_invalid"
    }
    [int64]$IssuedAt = [int64]$Fields.'issued-at'
    [int64]$ExpiresAt = [int64]$Fields.'expires-at'
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($IssuedAt -lt ($Intent.IssuedAt - $script:ClockSkewSeconds) -or
        $ExpiresAt -gt ($Intent.ExpiresAt + $script:ClockSkewSeconds) -or
        $IssuedAt -gt ($Now + $script:ClockSkewSeconds) -or (-not $Historical -and $ExpiresAt -le $Now) -or
        $ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 3600 -or
        (-not $Fixture -and -not (Test-DetachedCmsSignature $ReceiptBytes $SignatureBytes `
            $ExpectedThumbprint $IssuedAt $ExpiresAt))) {
        throw "transport_native_canary_provenance_invalid"
    }
    return [pscustomobject]@{ Fields = $Fields; Sha256 = Get-Sha256Bytes $ReceiptBytes }
}

function Get-ManagedSshdBlock([string]$GenerationRoot) {
    if ($GenerationRoot -cnotmatch '^[A-Z]:\\[^\r\n#]+$') { throw "invalid_transport_generation_path" }
    $CaPath = $GenerationRoot + "\fleet-ca.pub"
    $KrlPath = $GenerationRoot + "\revoked.krl"
    $PrincipalPath = $GenerationRoot + "\authorized-principals"
    return [string[]]@(
        $script:ManagedBlockBegin,
        "TrustedUserCAKeys $CaPath",
        "RevokedKeys $KrlPath",
        "Match User $($script:RequestAccountName)",
        "    ChrootDirectory C:\ProgramData\MachineUtilities\chroot",
        "    ForceCommand internal-sftp",
        "    PubkeyAuthentication yes",
        "    AuthenticationMethods publickey",
        "    AuthorizedKeysFile none",
        "    AuthorizedPrincipalsFile $PrincipalPath",
        "    PasswordAuthentication no",
        "    KbdInteractiveAuthentication no",
        "    PermitTTY no",
        "    X11Forwarding no",
        "    AllowTcpForwarding no",
        "    AllowStreamLocalForwarding no",
        "    AllowAgentForwarding no",
        "    PermitTunnel no",
        "    GatewayPorts no",
        "    PermitOpen none",
        "    PermitListen none",
        "    PermitUserRC no",
        "    PermitUserEnvironment no",
        "Match all",
        $script:ManagedBlockEnd
    )
}

function Get-AuthorizedPrincipalsBytes {
    return ConvertTo-CanonicalAsciiBytes @($script:EndpointPrincipal)
}

function Set-ManagedSshdBlock([byte[]]$ExistingBytes, [string[]]$ManagedLines) {
    $ExistingLines = ConvertFrom-CanonicalAsciiBytes $ExistingBytes 4194304 "sshd_config"
    $BeginIndexes = [Collections.Generic.List[int]]::new()
    $EndIndexes = [Collections.Generic.List[int]]::new()
    for ($Index = 0; $Index -lt $ExistingLines.Count; $Index++) {
        if ($ExistingLines[$Index] -ceq $script:ManagedBlockBegin) { [void]$BeginIndexes.Add($Index) }
        if ($ExistingLines[$Index] -ceq $script:ManagedBlockEnd) { [void]$EndIndexes.Add($Index) }
        if ($ExistingLines[$Index].StartsWith("# BEGIN MACHINE-UTILITIES WINDOWS-SFTP", [StringComparison]::Ordinal) -and
            $ExistingLines[$Index] -cne $script:ManagedBlockBegin) { throw "unknown_managed_sshd_artifact" }
        if ($ExistingLines[$Index].StartsWith("# END MACHINE-UTILITIES WINDOWS-SFTP", [StringComparison]::Ordinal) -and
            $ExistingLines[$Index] -cne $script:ManagedBlockEnd) { throw "unknown_managed_sshd_artifact" }
    }
    if ($BeginIndexes.Count -ne $EndIndexes.Count -or $BeginIndexes.Count -gt 1 -or
        ($BeginIndexes.Count -eq 1 -and $BeginIndexes[0] -ge $EndIndexes[0])) {
        throw "managed_sshd_block_drift"
    }
    $Remainder = [Collections.Generic.List[string]]::new()
    if ($BeginIndexes.Count -eq 0) {
        foreach ($Line in $ExistingLines) { [void]$Remainder.Add($Line) }
    } else {
        for ($Index = 0; $Index -lt $ExistingLines.Count; $Index++) {
            if ($Index -lt $BeginIndexes[0] -or $Index -gt $EndIndexes[0]) {
                [void]$Remainder.Add($ExistingLines[$Index])
            }
        }
    }
    while ($Remainder.Count -gt 0 -and $Remainder[0].Length -eq 0) { $Remainder.RemoveAt(0) }
    $Output = [Collections.Generic.List[string]]::new()
    foreach ($Line in $ManagedLines) { [void]$Output.Add($Line) }
    [void]$Output.Add("")
    foreach ($Line in $Remainder) { [void]$Output.Add($Line) }
    return ConvertTo-CanonicalAsciiBytes $Output.ToArray()
}

function Remove-ManagedSshdBlock([byte[]]$ExistingBytes, [string[]]$ExpectedLines) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $ExistingBytes 4194304 "sshd_config"
    $Begin = @($Lines | ForEach-Object -Begin { $Index = -1 } -Process {
            $Index++; if ($_ -ceq $script:ManagedBlockBegin) { $Index }
        })
    $End = @($Lines | ForEach-Object -Begin { $Index = -1 } -Process {
            $Index++; if ($_ -ceq $script:ManagedBlockEnd) { $Index }
        })
    if ($Begin.Count -ne 1 -or $End.Count -ne 1 -or $Begin[0] -ge $End[0] -or
        ($End[0] - $Begin[0] + 1) -ne $ExpectedLines.Count) { throw "managed_sshd_block_drift" }
    for ($Offset = 0; $Offset -lt $ExpectedLines.Count; $Offset++) {
        if ($Lines[$Begin[0] + $Offset] -cne $ExpectedLines[$Offset]) { throw "managed_sshd_block_drift" }
    }
    $Output = [Collections.Generic.List[string]]::new()
    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        if ($Index -lt $Begin[0] -or $Index -gt $End[0]) { [void]$Output.Add($Lines[$Index]) }
    }
    while ($Output.Count -gt 1 -and $Output[0].Length -eq 0) { $Output.RemoveAt(0) }
    return ConvertTo-CanonicalAsciiBytes $Output.ToArray()
}

function Get-FirewallContractBytes([object]$Intent) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-firewall-contract|1", "name|$($script:FirewallRuleName)",
        "group|$($script:FirewallRuleGroup)", "direction|inbound", "action|allow",
        "protocol|tcp", "local-port|22", "service|sshd",
        "remote-addresses|$($Intent.Fields.'management-cidrs')", "profiles|any",
        "activation-order|account-then-firewall-last", "end-firewall|"
    )
}

function Get-CandidateReceiptBytes(
    [string]$Operation,
    [object]$Intent,
    [object]$Bootstrap,
    [string]$HostKeyFingerprint,
    [string]$ConfigurationSha256,
    [string]$FirewallSha256,
    [string]$ControllerSignatureSha256,
    [string]$U3State = "verified"
) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-enrollment-candidate|1", "operation|$Operation",
        "authorization|inert-unsigned-local-observation", "host|$($Intent.Fields.host)",
        "request-account|$($Intent.Fields.'request-account')", "request-sid|$($Intent.Fields.'request-sid')",
        "endpoint-principal|$($Intent.Fields.'endpoint-principal')",
        "primary-ca-fingerprint|$($Intent.Fields.'primary-ca-fingerprint')",
        "primary-ca-generation|$($Intent.Fields.'primary-ca-generation')",
        "previous-ca-fingerprint|$($Intent.Fields.'previous-ca-fingerprint')",
        "previous-ca-generation|$($Intent.Fields.'previous-ca-generation')",
        "krl-generation|$($Intent.Fields.'krl-generation')",
        "management-cidrs|$($Intent.Fields.'management-cidrs')",
        "host-key-fingerprint|$HostKeyFingerprint", "intent-sha256|$($Intent.Sha256)",
        "controller-signature-sha256|$ControllerSignatureSha256",
        "controller-signing-thumbprint|$($Bootstrap.'controller-signing-thumbprint')",
        "release-publisher-thumbprint|$($Bootstrap.'publisher-thumbprint')",
        "protected-entrypoint-sha256|$($Bootstrap.'protected-copy-sha256')",
        "u3-state|$U3State", "u3-epoch|$($Intent.Fields.'u3-epoch')",
        "u3-generation-sha256|$($Intent.Fields.'u3-generation-sha256')",
        "u3-active-pointer-sha256|$($Intent.Fields.'u3-active-pointer-sha256')",
        "u3-task-sha256|$($Intent.Fields.'u3-system-task-xml-sha256')",
        "u3-broker-sha256|$($Intent.Fields.'u3-broker-sha256')",
        "chroot-contract-sha256|$($Intent.Fields.'chroot-contract-sha256')",
        "slot-acl-sha256|$($Intent.Fields.'slot-acl-sha256')",
        "results-acl-sha256|$($Intent.Fields.'results-acl-sha256')",
        "quota-contract-sha256|$($Intent.Fields.'quota-contract-sha256')",
        "openssh-contract-sha256|$($Intent.Fields.'openssh-contract-sha256')",
        "configuration-sha256|$ConfigurationSha256", "firewall-contract-sha256|$FirewallSha256",
        "issued-at|$($Intent.Fields.'issued-at')", "expires-at|$($Intent.Fields.'expires-at')",
        "controller-signing|required-separate", "end-candidate|"
    )
}

function Get-U3NativeCanaryFieldNames {
    return [string[]]@(
        "nonce", "host", "epoch", "generation-sha256", "runner-path-sha256", "runner-sha256",
        "runner-publisher-thumbprint", "issued-at", "expires-at", "human-preview-sha256",
        "human-confirmation-sha256", "clock-skew-bound-seconds", "request-sid", "chroot-path-sha256",
        "chroot-directory-sddl-sha256", "slot-directory-sddl-sha256", "slot-file-sddl-sha256",
        "results-directory-sddl-sha256", "result-file-sddl-sha256", "system-task-logged-off",
        "profile-task-logged-off", "profile-token-limited", "profile-no-network",
        "profile-authenticated-smb-denied", "profile-efs-capability", "profile-efs-denied",
        "chroot-physical-layout", "chroot-effective-access", "slot-write-data-only",
        "slot-create-list-rename-denied", "slot-owner-rights", "slot-quota", "result-read-only",
        "result-non-list", "request-no-task-rights", "claim-copy-race", "openssh-y-verify",
        "openssh-print-pubkey", "openssh-certificate-parse", "winget-system-inventory",
        "winget-corrupt-hash", "winget-dangerous-options", "profile-path-containment",
        "authoritative-result", "reboot-recovery", "raw-evidence-sha256"
    )
}

function Get-U3NativeAccessContract([string]$RequestSid) {
    $Contracts = Get-U3ContractDigests $RequestSid
    return [pscustomobject]@{
        RequestSid = $RequestSid
        ChrootPathSha256 = Get-Sha256Bytes ($script:Utf8.GetBytes("C:\PROGRAMDATA\MACHINEUTILITIES\CHROOT"))
        ChrootDirectorySddlSha256 = Get-Sha256Bytes ($script:Utf8.GetBytes($Contracts.SlotDirectory))
        SlotDirectorySddlSha256 = Get-Sha256Bytes ($script:Utf8.GetBytes($Contracts.SlotDirectory))
        SlotFileSddlSha256 = Get-Sha256Bytes ($script:Utf8.GetBytes($Contracts.SlotFile))
        ResultsDirectorySddlSha256 = Get-Sha256Bytes ($script:Utf8.GetBytes($Contracts.ResultsDirectory))
        ResultFileSddlSha256 = Get-Sha256Bytes ($script:Utf8.GetBytes($Contracts.ResultFile))
    }
}

function Get-U3NativeGateNames {
    return [string[]]@(
        "system-task-logged-off", "profile-task-logged-off", "profile-token-limited", "profile-no-network",
        "profile-authenticated-smb-denied", "profile-efs-capability", "profile-efs-denied",
        "chroot-physical-layout", "chroot-effective-access", "slot-write-data-only",
        "slot-create-list-rename-denied", "slot-owner-rights", "slot-quota", "result-read-only",
        "result-non-list", "request-no-task-rights", "claim-copy-race", "openssh-y-verify",
        "openssh-print-pubkey", "openssh-certificate-parse", "winget-system-inventory",
        "winget-corrupt-hash", "winget-dangerous-options", "profile-path-containment",
        "authoritative-result", "reboot-recovery")
}

function Read-U3NativeRawEvidence([byte[]]$Bytes, [object]$Intent) {
    $Names = [string[]]@(
        "nonce", "host", "epoch", "generation-sha256", "controlled-smb-root-sha256",
        "controlled-smb-probe-sha256", "efs-probe-path-sha256", "captured-at", "request-sid",
        "chroot-path-sha256", "chroot-directory-sddl-sha256", "slot-directory-sddl-sha256",
        "slot-file-sddl-sha256", "results-directory-sddl-sha256", "result-file-sddl-sha256") +
        (Get-U3NativeGateNames)
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "u3_native_raw_evidence") `
        $Names "windows-native-canary-raw-evidence|2" "end-raw-evidence|" "u3_native_raw_evidence"
    $Access = Get-U3NativeAccessContract $Fields.'request-sid'
    if ($Fields.host -cne $Intent.Fields.host -or $Fields.epoch -cne $Intent.Fields.'u3-epoch' -or
        $Fields.'generation-sha256' -cne $Intent.Fields.'u3-generation-sha256' -or
        $Fields.'request-sid' -cne $Intent.Fields.'request-sid' -or -not (Test-Digest $Fields.nonce) -or
        -not (Test-Digest $Fields.'controlled-smb-root-sha256') -or
        -not (Test-Digest $Fields.'controlled-smb-probe-sha256') -or
        -not (Test-Digest $Fields.'efs-probe-path-sha256') -or -not (Test-UInt $Fields.'captured-at') -or
        $Fields.'chroot-path-sha256' -cne $Access.ChrootPathSha256 -or
        $Fields.'chroot-directory-sddl-sha256' -cne $Access.ChrootDirectorySddlSha256 -or
        $Fields.'slot-directory-sddl-sha256' -cne $Access.SlotDirectorySddlSha256 -or
        $Fields.'slot-file-sddl-sha256' -cne $Access.SlotFileSddlSha256 -or
        $Fields.'results-directory-sddl-sha256' -cne $Access.ResultsDirectorySddlSha256 -or
        $Fields.'result-file-sddl-sha256' -cne $Access.ResultFileSddlSha256) {
        throw "u3_native_raw_evidence_drift"
    }
    foreach ($Name in @((Get-U3NativeGateNames) | Where-Object {
                $_ -notin @("profile-efs-capability", "profile-efs-denied") })) {
        if ($Fields[$Name] -cne "passed") { throw "u3_native_canary_incomplete" }
    }
    if (($Fields.'profile-efs-capability' -ceq "supported" -and $Fields.'profile-efs-denied' -cne "passed") -or
        ($Fields.'profile-efs-capability' -ceq "not-supported" -and
            $Fields.'profile-efs-denied' -cne "not-supported") -or
        $Fields.'profile-efs-capability' -cnotin @("supported", "not-supported")) {
        throw "u3_native_canary_incomplete"
    }
    return $Fields
}

function Read-U3NativeCanary(
    [byte[]]$ReceiptBytes,
    [byte[]]$SignatureBytes,
    [byte[]]$EvidenceBytes,
    [object]$Intent
) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $ReceiptBytes 16384 "u3_native_canary") `
        (Get-U3NativeCanaryFieldNames) "windows-native-canary-receipt|3" "end-canary|" "u3_native_canary"
    foreach ($Name in @($Fields.Keys | Where-Object { $_ -notin @(
                "nonce", "host", "epoch", "generation-sha256", "runner-path-sha256", "runner-sha256",
                "runner-publisher-thumbprint", "issued-at", "expires-at", "human-preview-sha256",
                "human-confirmation-sha256", "clock-skew-bound-seconds", "request-sid", "chroot-path-sha256",
                "chroot-directory-sddl-sha256", "slot-directory-sddl-sha256", "slot-file-sddl-sha256",
                "results-directory-sddl-sha256", "result-file-sddl-sha256", "profile-efs-capability",
                "profile-efs-denied", "raw-evidence-sha256") })) {
        if ($Fields[$Name] -cne "passed") { throw "u3_native_canary_incomplete" }
    }
    $Access = Get-U3NativeAccessContract $Fields.'request-sid'
    $Raw = Read-U3NativeRawEvidence $EvidenceBytes $Intent
    if (($Fields.'profile-efs-capability' -ceq "supported" -and $Fields.'profile-efs-denied' -cne "passed") -or
        ($Fields.'profile-efs-capability' -ceq "not-supported" -and
            $Fields.'profile-efs-denied' -cne "not-supported") -or
        $Fields.'profile-efs-capability' -cnotin @("supported", "not-supported") -or
        -not (Test-Digest $Fields.nonce) -or -not (Test-Digest $Fields.'runner-path-sha256') -or
        -not (Test-Digest $Fields.'runner-sha256') -or -not (Test-Digest $Fields.'human-preview-sha256') -or
        -not (Test-Digest $Fields.'human-confirmation-sha256') -or
        -not (Test-Digest $Fields.'raw-evidence-sha256') -or
        -not (Test-Thumbprint $Fields.'runner-publisher-thumbprint') -or
        $Fields.'request-sid' -cne $Intent.Fields.'request-sid' -or
        $Fields.'chroot-path-sha256' -cne $Access.ChrootPathSha256 -or
        $Fields.'chroot-directory-sddl-sha256' -cne $Access.ChrootDirectorySddlSha256 -or
        $Fields.'slot-directory-sddl-sha256' -cne $Access.SlotDirectorySddlSha256 -or
        $Fields.'slot-file-sddl-sha256' -cne $Access.SlotFileSddlSha256 -or
        $Fields.'results-directory-sddl-sha256' -cne $Access.ResultsDirectorySddlSha256 -or
        $Fields.'result-file-sddl-sha256' -cne $Access.ResultFileSddlSha256 -or
        $Raw.nonce -cne $Fields.nonce -or [long]$Raw.'captured-at' -lt [long]$Fields.'issued-at' -or
        [long]$Raw.'captured-at' -gt [long]$Fields.'expires-at' -or
        $Fields.host -cne $Intent.Fields.host -or $Fields.epoch -cne $Intent.Fields.'u3-epoch' -or
        $Fields.'generation-sha256' -cne $Intent.Fields.'u3-generation-sha256' -or
        $Fields.'clock-skew-bound-seconds' -cne [string]$script:ClockSkewSeconds -or
        $Fields.'raw-evidence-sha256' -cne (Get-Sha256Bytes $EvidenceBytes) -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at')) {
        throw "u3_native_canary_invalid"
    }
    [int64]$IssuedAt = [int64]$Fields.'issued-at'
    [int64]$ExpiresAt = [int64]$Fields.'expires-at'
    foreach ($GateName in Get-U3NativeGateNames) {
        if ($Raw[$GateName] -cne $Fields[$GateName]) { throw "u3_native_canary_raw_receipt_drift" }
    }
    if ($IssuedAt -lt 1 -or $ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 3600 -or
        -not (Test-DetachedCmsSignature $ReceiptBytes $SignatureBytes `
            $Fields.'runner-publisher-thumbprint' $IssuedAt $ExpiresAt)) {
        throw "u3_native_canary_invalid"
    }
    return $Fields
}

function Get-NormalizedTaskXml([string]$XmlText) {
    try {
        $Document = [Xml.XmlDocument]::new(); $Document.PreserveWhitespace = $false; $Document.LoadXml($XmlText)
    } catch { throw "invalid_task_xml" }
    $Settings = [Xml.XmlWriterSettings]::new()
    $Settings.OmitXmlDeclaration = $true; $Settings.Indent = $false
    $Settings.NewLineHandling = [Xml.NewLineHandling]::None
    $Builder = [Text.StringBuilder]::new(); $Writer = [Xml.XmlWriter]::Create($Builder, $Settings)
    function Write-NormalizedTaskNode([Xml.XmlNode]$Node, [Xml.XmlWriter]$Target) {
        if ($Node.NodeType -eq [Xml.XmlNodeType]::Element) {
            $Target.WriteStartElement([string]$Node.Prefix, [string]$Node.LocalName, [string]$Node.NamespaceURI)
            foreach ($Attribute in @($Node.Attributes | Sort-Object NamespaceURI, LocalName)) {
                if ($Attribute.Prefix -ceq "xmlns" -or $Attribute.Name -ceq "xmlns") { continue }
                $Target.WriteAttributeString([string]$Attribute.Prefix, [string]$Attribute.LocalName,
                    [string]$Attribute.NamespaceURI, [string]$Attribute.Value)
            }
            foreach ($Child in @($Node.ChildNodes)) { Write-NormalizedTaskNode $Child $Target }
            $Target.WriteEndElement()
        } elseif ($Node.NodeType -in @([Xml.XmlNodeType]::Text, [Xml.XmlNodeType]::CDATA)) {
            $Target.WriteString([string]$Node.Value)
        }
    }
    try { Write-NormalizedTaskNode $Document.DocumentElement $Writer; $Writer.Flush() }
    finally { $Writer.Dispose() }
    return $Builder.ToString()
}

function Assert-U3TaskXmlContract([string]$XmlText, [string]$Kind, [string]$ExpectedSid, [object]$Layout) {
    try { [xml]$Document = $XmlText } catch { throw "invalid_task_xml" }
    $Namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Namespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
    $ExpectedLogon = if ($Kind -ceq "system") { "ServiceAccount" } else { "S4U" }
    $ExpectedRunLevel = if ($Kind -ceq "system") { "HighestAvailable" } else { "LeastPrivilege" }
    $ExpectedContext = if ($Kind -ceq "system") { "windows-system-v1" } else { "windows-user-s4u-v1" }
    $ExpectedScript = if ($Kind -ceq "system") { "privilege-broker-windows.ps1" } else { "profile-worker-windows.ps1" }
    $ExpectedPowerShell = "C:\Program Files\PowerShell\7\pwsh.exe"
    $ExpectedArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "' +
        $Layout.U3Root + "\entry\$ExpectedScript" + '" -Context ' + $ExpectedContext
    $Checks = [ordered]@{
        "/t:Task/t:Principals/t:Principal/t:UserId" = $ExpectedSid
        "/t:Task/t:Principals/t:Principal/t:LogonType" = $ExpectedLogon
        "/t:Task/t:Principals/t:Principal/t:RunLevel" = $ExpectedRunLevel
        "/t:Task/t:Settings/t:MultipleInstancesPolicy" = "IgnoreNew"
        "/t:Task/t:Settings/t:ExecutionTimeLimit" = "PT0S"
        "/t:Task/t:Actions/t:Exec/t:Command" = $ExpectedPowerShell
        "/t:Task/t:Actions/t:Exec/t:Arguments" = $ExpectedArguments
        "/t:Task/t:Actions/t:Exec/t:WorkingDirectory" = ($Layout.U3Root + "\entry")
    }
    foreach ($XPath in $Checks.Keys) {
        $Nodes = @($Document.SelectNodes($XPath, $Namespace))
        if ($Nodes.Count -ne 1 -or [string]$Nodes[0].InnerText -cne [string]$Checks[$XPath]) {
            throw "u3_task_contract_drift"
        }
    }
    $Triggers = @($Document.SelectNodes("/t:Task/t:Triggers/*", $Namespace))
    if ($Kind -ceq "system") {
        $Interval = @($Document.SelectNodes(
                "/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:Interval", $Namespace))
        if ($Triggers.Count -ne 1 -or $Interval.Count -ne 1 -or $Interval[0].InnerText -cne "PT1M") {
            throw "u3_task_contract_drift"
        }
    } elseif ($Kind -ceq "profile") {
        if ($Triggers.Count -ne 0) { throw "u3_task_contract_drift" }
    } else { throw "u3_task_contract_drift" }
    if (@($Document.SelectNodes("/t:Task/t:Actions/*", $Namespace)).Count -ne 1 -or
        $XmlText -match '(?i)(<Password>|InteractiveToken|cmd\.exe|winget\.exe|generations\\)') {
        throw "u3_task_contract_drift"
    }
}

function Get-U3TaskSnapshot([string]$TaskName) {
    $Service = New-Object -ComObject "Schedule.Service"
    $Service.Connect()
    $Task = $Service.GetFolder("\").GetTask("\$TaskName")
    if ($null -eq $Task) { throw "u3_task_missing" }
    $Sddl = [string]$Task.GetSecurityDescriptor(0x7)
    Assert-ExactSecurityDescriptor $script:TaskSddl $Sddl "u3_task"
    return [pscustomobject]@{
        Xml = [string]$Task.Xml
        XmlSha256 = Get-Sha256Bytes ($script:Utf8.GetBytes((Get-NormalizedTaskXml ([string]$Task.Xml))))
        SddlSha256 = Get-Sha256Text $Sddl
        Sddl = $Sddl
        Enabled = [bool]$Task.Enabled
        State = [int]$Task.State
    }
}

function Initialize-LsaReadType {
    if ("MachineUtilitiesSftpLsa" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class MachineUtilitiesSftpLsa {
  [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES {
    public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
    public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
  }
  [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING {
    public ushort Length; public ushort MaximumLength; public IntPtr Buffer;
  }
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system,
    ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr policy);
  [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountRights(IntPtr policy,
    IntPtr sid, out IntPtr rights, out uint count);
  [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
  [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
  const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;
  public static string[] GetAccountRights(byte[] sidBytes) {
    var oa = new LSA_OBJECT_ATTRIBUTES(); oa.Length = Marshal.SizeOf(oa);
    IntPtr policy; uint status = LsaOpenPolicy(IntPtr.Zero, ref oa, 0x00000800, out policy);
    if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
    GCHandle pinned = default; IntPtr memory = IntPtr.Zero;
    try {
      pinned = GCHandle.Alloc(sidBytes, GCHandleType.Pinned); uint count;
      status = LsaEnumerateAccountRights(policy, pinned.AddrOfPinnedObject(), out memory, out count);
      if (status == STATUS_OBJECT_NAME_NOT_FOUND) return new string[0];
      if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
      var result = new List<string>(); int size = Marshal.SizeOf(typeof(LSA_UNICODE_STRING));
      for (uint i = 0; i < count; i++) {
        var value = (LSA_UNICODE_STRING)Marshal.PtrToStructure(IntPtr.Add(memory, (int)i * size),
          typeof(LSA_UNICODE_STRING));
        result.Add(Marshal.PtrToStringUni(value.Buffer, value.Length / 2));
      }
      return result.ToArray();
    } finally {
      if (memory != IntPtr.Zero) LsaFreeMemory(memory);
      if (pinned.IsAllocated) pinned.Free(); LsaClose(policy);
    }
  }
}
'@
}

function Get-LsaAccountRights([string]$Sid) {
    Initialize-LsaReadType
    $Identifier = [Security.Principal.SecurityIdentifier]::new($Sid)
    [byte[]]$Bytes = [byte[]]::new($Identifier.BinaryLength)
    $Identifier.GetBinaryForm($Bytes, 0)
    return [string[]]@([MachineUtilitiesSftpLsa]::GetAccountRights($Bytes) | Sort-Object)
}

function Assert-AuthenticodePublisher([string]$Path, [string]$ExpectedThumbprint) {
    $Signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Thumbprint.ToUpperInvariant() -cne $ExpectedThumbprint) {
        throw "authenticode_publisher_mismatch"
    }
}

function Assert-SingleHardLink([string]$Path, [object]$Layout) {
    $Result = Invoke-CleanNative $Layout.Fsutil @("hardlink", "list", $Path) $Layout 30 65536
    if ($Result.ExitCode -ne 0) { throw "hardlink_identity_unavailable" }
    $Lines = [string[]]@($Result.StdOut -split '\r?\n' | Where-Object { $_.Trim().Length -gt 0 })
    if ($Lines.Count -ne 1) { throw "hardlink_forbidden" }
}

function Assert-ProtectedFile(
    [string]$Path,
    [string]$Boundary,
    [string]$ExpectedSddl,
    [int64]$MaximumBytes,
    [object]$Layout,
    [string]$Label
) {
    Assert-NoReparseAncestors $Path $Boundary
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { throw "${Label}_missing" }
    Assert-PathSddl $Path $ExpectedSddl $Label
    Assert-SingleHardLink $Path $Layout
    return Read-HeldBytes $Path $MaximumBytes
}

function Assert-ProtectedDirectory(
    [string]$Path,
    [string]$Boundary,
    [string]$ExpectedSddl,
    [string]$Label
) {
    Assert-NoReparseAncestors $Path $Boundary
    if (-not [IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) { throw "${Label}_missing" }
    Assert-PathSddl $Path $ExpectedSddl $Label
}

function Assert-AdministratorInteractiveBoundary {
    if (-not $IsWindows -or -not [Environment]::UserInteractive -or
        [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
        throw "native_human_elevation_required"
    }
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        $Identity.IsSystem) { throw "native_human_elevation_required" }
}

function Test-WslInvocation {
    foreach ($Name in @("WSL_INTEROP", "WSL_DISTRO_NAME")) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))) {
            return $true
        }
    }
    try {
        Add-Type -AssemblyName System.Management -ErrorAction Stop
        [uint32]$ProcessId = [uint32]$PID
        $Seen = [Collections.Generic.HashSet[uint32]]::new()
        for ($Depth = 0; $Depth -lt 16; $Depth++) {
            if (-not $Seen.Add($ProcessId)) { throw "windows_parent_cycle" }
            $Searcher = [Management.ManagementObjectSearcher]::new(
                "SELECT Name, ParentProcessId FROM Win32_Process WHERE ProcessId = $ProcessId")
            $Collection = $null
            $Rows = @()
            try {
                $Collection = $Searcher.Get()
                $Rows = @($Collection)
                if ($Rows.Count -eq 0) { return $false }
                if ($Rows.Count -ne 1) { throw "windows_parent_ambiguous" }
                $ProcessName = [string]$Rows[0].Properties["Name"].Value
                [uint32]$ParentProcessId = [uint32]$Rows[0].Properties["ParentProcessId"].Value
            } finally {
                foreach ($Row in $Rows) { if ($Row -is [IDisposable]) { $Row.Dispose() } }
                if ($Collection -is [IDisposable]) { $Collection.Dispose() }
                $Searcher.Dispose()
            }
            if ($ProcessName -cmatch '(?i:^(?:wsl|wslhost|wslrelay)\.exe$)') { return $true }
            if ($ParentProcessId -eq 0) { return $false }
            $ProcessId = $ParentProcessId
        }
        return $false
    } catch {
        throw "windows_parent_boundary_unavailable"
    }
}

function Import-ProtectedWindowsModule([object]$Layout, [string]$RelativeManifest) {
    $Path = $Layout.SystemRoot + "\System32\WindowsPowerShell\v1.0\Modules\" + $RelativeManifest
    Assert-NoReparseAncestors $Path $Layout.SystemRoot
    if (-not [IO.File]::Exists($Path)) { throw "protected_windows_module_missing" }
    Microsoft.PowerShell.Core\Import-Module -Name $Path -Force -ErrorAction Stop
}

function Assert-RequestAccount([object]$Layout, [string]$ExpectedSid, [string]$ExpectedState) {
    Import-ProtectedWindowsModule $Layout "Microsoft.PowerShell.LocalAccounts\Microsoft.PowerShell.LocalAccounts.psd1"
    $Account = Microsoft.PowerShell.LocalAccounts\Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    if ([string]$Account.Sid.Value -cne $ExpectedSid -or
        ($ExpectedState -ceq "disabled" -and $Account.Enabled) -or
        ($ExpectedState -ceq "enabled" -and -not $Account.Enabled) -or
        $Account.Name -cne $script:RequestAccountName) { throw "request_account_drift" }
    $Administrators = Microsoft.PowerShell.LocalAccounts\Get-LocalGroup -SID "S-1-5-32-544" -ErrorAction Stop
    $Members = @(Microsoft.PowerShell.LocalAccounts\Get-LocalGroupMember -Group $Administrators.Name -ErrorAction Stop)
    if (@($Members | Where-Object { [string]$_.Sid.Value -ceq $ExpectedSid }).Count -ne 0) {
        throw "request_account_is_administrator"
    }
    $ExpectedRights = [string[]]@(
        "SeDenyBatchLogonRight", "SeDenyInteractiveLogonRight", "SeDenyRemoteInteractiveLogonRight")
    $ObservedRights = [string[]]@(Get-LsaAccountRights $ExpectedSid)
    if (($ObservedRights -join "`n") -cne (($ExpectedRights | Sort-Object) -join "`n")) {
        throw "request_account_rights_drift"
    }
    return $Account
}

function Assert-QuotaQueryText([string]$Text, [string]$RequestSid) {
    if ($Text -notmatch '(?im)^\s*File system quotas are tracked and enforced on this volume\.\s*$') {
        throw "quota_not_enforced"
    }
    $Matching = @([regex]::Split($Text, '(?:\r?\n){2,}') | Where-Object {
            $_ -match [regex]::Escape($script:RequestAccountName) -and $_ -match [regex]::Escape($RequestSid)
        })
    if ($Matching.Count -ne 1) { throw "quota_verification_failed" }
    $Canonical = $Matching[0] -replace '[, ]', ''
    if ($Canonical -notmatch '(?im)^(?:Quota)?Threshold:67108864(?:bytes)?$' -or
        $Canonical -notmatch '(?im)^(?:Quota)?Limit:68157440(?:bytes)?$') {
        throw "quota_verification_failed"
    }
}

function Assert-FixedQuota([object]$Layout, [string]$RequestSid) {
    $VolumeRoot = [IO.Path]::GetPathRoot($Layout.ProgramData)
    $Result = Invoke-CleanNative $Layout.Fsutil @("quota", "query", $VolumeRoot) $Layout 60 4194304
    if ($Result.ExitCode -ne 0) { throw "quota_verification_failed" }
    Assert-QuotaQueryText ($Result.StdOut + "`n" + $Result.StdErr) $RequestSid
}

function Get-TaskProfileSid([string]$XmlText) {
    try { [xml]$Document = $XmlText } catch { throw "invalid_task_xml" }
    $Namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Namespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
    $Nodes = @($Document.SelectNodes("/t:Task/t:Principals/t:Principal/t:UserId", $Namespace))
    if ($Nodes.Count -ne 1 -or -not (Test-Sid ([string]$Nodes[0].InnerText))) { throw "u3_profile_sid_invalid" }
    return [string]$Nodes[0].InnerText
}

function Assert-U3NormalResult([string]$Path, [string]$ExpectedRequestId) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path $script:MaximumBrokerResultBytes) `
        $script:MaximumBrokerResultBytes "u3_result") @(
            "state", "reason", "request-id", "plan-id", "action-id", "enrollment-epoch", "protected-result-sha256") `
        "windows-broker-public|1" "end-public|" "u3_result"
    if ($ExpectedRequestId -cnotmatch '^request-[0-9a-f]{32}$' -or $Fields.'request-id' -cne $ExpectedRequestId -or
        $Fields.state -cnotmatch '^[a-z][a-z0-9_-]{0,31}$' -or $Fields.reason -cnotmatch '^[a-z][a-z0-9_]{0,127}$' -or
        -not (Test-UInt $Fields.'enrollment-epoch') -or -not (Test-Digest $Fields.'protected-result-sha256')) {
        throw "u3_result_schema_drift"
    }
}

function Assert-U3ReadinessResult([string]$Path, [string]$ExpectedRequestId) {
    $Lines = ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path $script:MaximumBrokerReadinessBytes) `
        $script:MaximumBrokerReadinessBytes "u3_readiness_result"
    if ($ExpectedRequestId -cnotmatch '^request-[0-9a-f]{32}$' -or $Lines.Count -lt 5 -or
        $Lines[0] -cne "windows-broker-readiness-result|1" -or $Lines[-1] -cne "end-readiness|") {
        throw "u3_readiness_schema_drift"
    }
    if ($Lines.Count -eq 5) {
        if ($Lines[1] -cne "request-id|$ExpectedRequestId" -or $Lines[2] -cne "state|unavailable" -or
            $Lines[3] -cne "reason|fresh_probe_failed") { throw "u3_readiness_schema_drift" }
        return
    }
    $Names = @(
        "request-id", "state", "reason", "broker-protocol", "broker-version", "broker-sha256",
        "policy-version", "policy-sha256", "constraint-version", "constraints-sha256", "generation",
        "generation-sha256", "winget-context-version", "winget-context-sha256", "provider-lock-sha256",
        "request-sid", "request-principal", "system-task-ready", "profile-task-ready", "transport-ready",
        "native-canary-ready", "observed-at", "expires-at", "action-count")
    if ($Lines.Count -lt ($Names.Count + 4)) { throw "u3_readiness_schema_drift" }
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Fields.Contains($Parts[0])) {
            throw "u3_readiness_schema_drift"
        }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if ($Fields.'request-id' -cne $ExpectedRequestId -or $Fields.state -cne "ready" -or
        $Fields.reason -cne "fresh_probes_verified" -or $Fields.'broker-protocol' -cne "1" -or
        -not (Test-Token $Fields.'broker-version') -or
        @($Fields.'broker-sha256', $Fields.'policy-sha256', $Fields.'constraints-sha256',
            $Fields.'generation-sha256', $Fields.'winget-context-sha256', $Fields.'provider-lock-sha256' |
            Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
        @($Fields.'policy-version', $Fields.'constraint-version', $Fields.'winget-context-version',
            $Fields.generation, $Fields.'observed-at', $Fields.'expires-at', $Fields.'action-count' |
            Where-Object { -not (Test-UInt $_) }).Count -ne 0 -or
        -not (Test-Sid $Fields.'request-sid') -or -not (Test-Token $Fields.'request-principal') -or
        @($Fields.'system-task-ready', $Fields.'transport-ready', $Fields.'native-canary-ready' |
            Where-Object { $_ -cne "true" }).Count -ne 0 -or
        $Fields.'profile-task-ready' -cnotin @("true", "false")) {
        throw "u3_readiness_schema_drift"
    }
    [int]$ActionCount = [int]$Fields.'action-count'
    [int64]$ObservedAt = [int64]$Fields.'observed-at'; [int64]$ExpiresAt = [int64]$Fields.'expires-at'
    if ($ActionCount -lt 1 -or $ActionCount -gt 64 -or $ExpiresAt -le $ObservedAt -or
        ($ExpiresAt - $ObservedAt) -gt $script:ClockSkewSeconds) { throw "u3_readiness_schema_drift" }
    $ProfileCountIndex = $Names.Count + 1 + $ActionCount
    if ($ProfileCountIndex -ge ($Lines.Count - 1)) { throw "u3_readiness_schema_drift" }
    $HasProfileAction = $false
    for ($Index = 0; $Index -lt $ActionCount; $Index++) {
        $Parts = $Lines[$Names.Count + 1 + $Index].Split('|')
        if ($Parts.Count -ne 5 -or $Parts[0] -cne "action" -or
            $Parts[1] -cnotin @("profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1",
                "winget.install-machine-package.v1", "winget.inventory-machine.v1", "winget.upgrade-machine-package.v1") -or
            $Parts[2] -cnotin @("windows-system-v1", "windows-user-s4u-v1") -or
            ($Parts[3] -cne "-" -and -not (Test-Token $Parts[3])) -or -not (Test-Digest $Parts[4])) {
            throw "u3_readiness_schema_drift"
        }
        if ($Parts[1].StartsWith("profile.", [StringComparison]::Ordinal)) { $HasProfileAction = $true }
    }
    $ProfileCount = $Lines[$ProfileCountIndex].Split('|')
    if ($ProfileCount.Count -ne 2 -or $ProfileCount[0] -cne "profile-constraint-count" -or
        -not (Test-UInt $ProfileCount[1]) -or [int]$ProfileCount[1] -gt 64 -or
        $Lines.Count -ne ($ProfileCountIndex + [int]$ProfileCount[1] + 2)) { throw "u3_readiness_schema_drift" }
    [int]$ProfileConstraintCount = [int]$ProfileCount[1]
    if (($Fields.'profile-task-ready' -ceq "true") -ne $HasProfileAction -or
        ($Fields.'profile-task-ready' -ceq "true") -ne ($ProfileConstraintCount -gt 0)) {
        throw "u3_readiness_schema_drift"
    }
    for ($Index = 0; $Index -lt $ProfileConstraintCount; $Index++) {
        $Parts = $Lines[$ProfileCountIndex + 1 + $Index].Split('|')
        if ($Parts.Count -ne 10 -or $Parts[0] -cne "profile-constraint" -or -not (Test-Token $Parts[1]) -or
            -not (Test-Sid $Parts[2]) -or @($Parts[3], $Parts[4], $Parts[5], $Parts[9] |
                Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
            $Parts[6] -cnotin @("managed-only", "managed-and-prune") -or
            -not (Test-UInt $Parts[7]) -or -not (Test-UInt $Parts[8])) { throw "u3_readiness_schema_drift" }
    }
}

function Assert-U3Projection([object]$Layout, [string]$RequestSid, [object]$Contracts) {
    $TraverseSddl = $Contracts.SlotDirectory
    foreach ($Binding in @(
            @($Layout.Chroot, $TraverseSddl, "chroot"),
            @($Layout.Chroot + "\ingress", $TraverseSddl, "chroot_ingress"),
            @($Layout.Slot, $Contracts.SlotDirectory, "slot"),
            @($Layout.Results, $Contracts.ResultsDirectory, "results"))) {
        Assert-ProtectedDirectory $Binding[0] $Layout.U3Root $Binding[1] $Binding[2]
    }
    $ExpectedSlotNames = [string[]]@("commit", "payload", "request", "request.sig")
    $ObservedSlotNames = [string[]]@([IO.Directory]::EnumerateFileSystemEntries($Layout.Slot) |
        ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
    if (($ObservedSlotNames -join "`n") -cne ($ExpectedSlotNames -join "`n")) {
        throw "slot_artifact_set_drift"
    }
    foreach ($Name in $ExpectedSlotNames) {
        [void](Assert-ProtectedFile ($Layout.Slot + "\" + $Name) $Layout.U3Root `
            $Contracts.SlotFile $script:SlotQuotaBytes $Layout "slot_file")
    }
    foreach ($Entry in [IO.Directory]::EnumerateFileSystemEntries($Layout.Results)) {
        $Name = [IO.Path]::GetFileName($Entry)
        $Normal = [regex]::Match($Name, '^(request-[0-9a-f]{32})\.result$')
        $Readiness = [regex]::Match($Name, '^(request-[0-9a-f]{32})\.readiness$')
        if (-not [IO.File]::Exists($Entry)) { throw "unknown_result_artifact" }
        if ($Normal.Success) {
            [void](Assert-ProtectedFile $Entry $Layout.U3Root $Contracts.ResultFile $script:MaximumBrokerResultBytes $Layout "result_file")
            Assert-U3NormalResult $Entry $Normal.Groups[1].Value
        } elseif ($Readiness.Success) {
            [void](Assert-ProtectedFile $Entry $Layout.U3Root $Contracts.ResultFile $script:MaximumBrokerReadinessBytes $Layout "readiness_file")
            Assert-U3ReadinessResult $Entry $Readiness.Groups[1].Value
        } else { throw "unknown_result_artifact" }
    }
}

function Assert-U3State([object]$Layout, [object]$Intent, [string]$ExpectedAccountState = "disabled") {
    $Contracts = Get-U3ContractDigests $Intent.Fields.'request-sid'
    if ($Contracts.Chroot -cne $Intent.Fields.'chroot-contract-sha256' -or
        $Contracts.Slot -cne $Intent.Fields.'slot-acl-sha256' -or
        $Contracts.Results -cne $Intent.Fields.'results-acl-sha256' -or
        $Contracts.Quota -cne $Intent.Fields.'quota-contract-sha256' -or
        $Contracts.OpenSsh -cne $Intent.Fields.'openssh-contract-sha256') {
        throw "u3_contract_digest_mismatch"
    }
    $Account = Assert-RequestAccount $Layout $Intent.Fields.'request-sid' $ExpectedAccountState
    $ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    $PointerBytes = Assert-ProtectedFile $Layout.U3ActivePointer $Layout.U3Root $ProtectedFileSddl 1024 `
        $Layout "u3_active_pointer"
    $Pointer = Read-ActivePointer $PointerBytes
    if ((Get-Sha256Bytes $PointerBytes) -cne $Intent.Fields.'u3-active-pointer-sha256' -or
        $Pointer.epoch -cne $Intent.Fields.'u3-epoch' -or
        $Pointer.'generation-sha256' -cne $Intent.Fields.'u3-generation-sha256') {
        throw "u3_active_generation_drift"
    }
    $Generation = $Layout.U3Root + "\generations\" + $Pointer.epoch
    $GenerationBindings = [ordered]@{
        "policy.actions" = $Intent.Fields.'u3-policy-sha256'
        "policy.constraints" = $Intent.Fields.'u3-constraints-sha256'
        "winget.context" = $Intent.Fields.'u3-winget-context-sha256'
        "windows-winget-provider.lock" = $Intent.Fields.'u3-provider-lock-sha256'
    }
    foreach ($Name in $GenerationBindings.Keys) {
        $Bytes = Assert-ProtectedFile ($Generation + "\" + $Name) $Layout.U3Root $ProtectedFileSddl `
            4194304 $Layout "u3_generation_file"
        if ((Get-Sha256Bytes $Bytes) -cne $GenerationBindings[$Name]) { throw "u3_generation_file_drift" }
    }
    $BrokerBytes = Assert-ProtectedFile ($Layout.U3Root + "\entry\privilege-broker-windows.ps1") `
        $Layout.U3Root $ProtectedFileSddl 8388608 $Layout "u3_broker"
    if ((Get-Sha256Bytes $BrokerBytes) -cne $Intent.Fields.'u3-broker-sha256') { throw "u3_broker_drift" }
    $CanaryBytes = Assert-ProtectedFile ($Layout.U3Root + "\native-canary.receipt") $Layout.U3Root `
        $ProtectedFileSddl 16384 $Layout "u3_native_canary"
    $CanarySignature = Assert-ProtectedFile ($Layout.U3Root + "\native-canary.receipt.p7s") $Layout.U3Root `
        $ProtectedFileSddl 65536 $Layout "u3_native_canary_signature"
    $CanaryEvidence = Assert-ProtectedFile ($Layout.U3Root + "\native-canary.evidence") $Layout.U3Root `
        $ProtectedFileSddl 1048576 $Layout "u3_native_canary_evidence"
    if ((Get-Sha256Bytes $CanaryBytes) -cne $Intent.Fields.'u3-native-canary-receipt-sha256' -or
        (Get-Sha256Bytes $CanarySignature) -cne $Intent.Fields.'u3-native-canary-signature-sha256' -or
        (Get-Sha256Bytes $CanaryEvidence) -cne $Intent.Fields.'u3-native-canary-evidence-sha256') {
        throw "u3_native_canary_drift"
    }
    [void](Read-U3NativeCanary $CanaryBytes $CanarySignature $CanaryEvidence $Intent)
    $SystemTask = Get-U3TaskSnapshot $script:SystemTaskName
    $ProfileTask = Get-U3TaskSnapshot $script:ProfileTaskName
    $ProfileSid = Get-TaskProfileSid $ProfileTask.Xml
    Assert-U3TaskXmlContract $SystemTask.Xml "system" "S-1-5-18" $Layout
    Assert-U3TaskXmlContract $ProfileTask.Xml "profile" $ProfileSid $Layout
    if (-not $SystemTask.Enabled -or -not $ProfileTask.Enabled -or
        $SystemTask.XmlSha256 -cne $Intent.Fields.'u3-system-task-xml-sha256' -or
        (Get-Sha256Text $script:TaskSddl) -cne $Intent.Fields.'u3-system-task-sddl-sha256' -or
        $ProfileTask.XmlSha256 -cne $Intent.Fields.'u3-profile-task-xml-sha256' -or
        (Get-Sha256Text $script:TaskSddl) -cne $Intent.Fields.'u3-profile-task-sddl-sha256') {
        throw "u3_task_digest_drift"
    }
    Assert-FixedQuota $Layout $Intent.Fields.'request-sid'
    Assert-U3Projection $Layout $Intent.Fields.'request-sid' $Contracts
    return [pscustomobject]@{
        Account = $Account; Contracts = $Contracts; ProfileSid = $ProfileSid
        SystemTask = $SystemTask; ProfileTask = $ProfileTask
    }
}

function Assert-SystemProtectedPath([string]$Path, [string]$Boundary) {
    Assert-NoReparseAncestors $Path $Boundary
    if (-not [IO.File]::Exists($Path)) { throw "protected_system_file_missing" }
    $Current = [IO.Path]::GetFullPath($Path)
    $Stop = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    while ($true) {
        $Acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Current -ErrorAction Stop
        if ([string]$Acl.Owner -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
            throw "protected_system_owner_drift"
        }
        foreach ($Rule in $Acl.Access) {
            $Dangerous = [Security.AccessControl.FileSystemRights]::Write -bor
                [Security.AccessControl.FileSystemRights]::Modify -bor
                [Security.AccessControl.FileSystemRights]::FullControl -bor
                [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                [Security.AccessControl.FileSystemRights]::TakeOwnership
            if ($Rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                ($Rule.FileSystemRights -band $Dangerous) -ne 0 -and
                [string]$Rule.IdentityReference -notmatch
                    '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
                throw "protected_system_acl_drift"
            }
        }
        if ($Current.TrimEnd('\').Equals($Stop, [StringComparison]::OrdinalIgnoreCase)) { break }
        $Parent = [IO.Directory]::GetParent($Current)
        if ($null -eq $Parent) { throw "protected_system_boundary_drift" }
        $Current = $Parent.FullName
    }
}

function Get-ValidAuthenticodeThumbprint([string]$Path) {
    $Signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $Signature.SignerCertificate -or
        -not (Test-Thumbprint ($Signature.SignerCertificate.Thumbprint.ToUpperInvariant()))) {
        throw "system_binary_signature_invalid"
    }
    return $Signature.SignerCertificate.Thumbprint.ToUpperInvariant()
}

function Assert-OpenSshBinaries([object]$Layout) {
    $Digests = [ordered]@{}
    foreach ($Path in @($Layout.Sshd, $Layout.SshKeygen, $Layout.Sftp, $Layout.Ssh)) {
        Assert-SystemProtectedPath $Path $Layout.SystemRoot
        [void](Get-ValidAuthenticodeThumbprint $Path)
        $Digests[[IO.Path]::GetFileName($Path)] = Get-Sha256Bytes (Read-HeldBytes $Path 33554432)
    }
    return $Digests
}

function Get-SshFingerprints([string]$Path, [object]$Layout) {
    $Result = Invoke-CleanNative $Layout.SshKeygen @("-lf", $Path, "-E", "sha256") $Layout 30 65536
    if ($Result.ExitCode -ne 0 -or $Result.StdErr.Trim().Length -ne 0) { throw "ssh_fingerprint_failed" }
    $Fingerprints = [Collections.Generic.List[string]]::new()
    foreach ($Line in @($Result.StdOut -split '\r?\n' | Where-Object { $_.Length -gt 0 })) {
        $Match = [regex]::Match($Line, '^\d+\s+(SHA256:[A-Za-z0-9+/]{43}=?)(?:\s+.+)?\s+\([A-Za-z0-9-]+\)$')
        if (-not $Match.Success -or -not (Test-SshFingerprint $Match.Groups[1].Value)) {
            throw "ssh_fingerprint_unparseable"
        }
        [void]$Fingerprints.Add($Match.Groups[1].Value)
    }
    if ($Fingerprints.Count -lt 1) { throw "ssh_fingerprint_unparseable" }
    return [string[]]$Fingerprints.ToArray()
}

function Assert-CaAndKrl([object]$Layout, [object]$Intent, [string]$ProtectedFileSddl) {
    $CaBytes = Assert-ProtectedFile $Layout.CaPublic $Layout.StageRoot $ProtectedFileSddl `
        $script:MaximumCaBytes $Layout "fleet_ca"
    $KrlBytes = Assert-ProtectedFile $Layout.Krl $Layout.StageRoot $ProtectedFileSddl `
        $script:MaximumKrlBytes $Layout "fleet_krl"
    if ((Get-Sha256Bytes $CaBytes) -cne $Intent.Fields.'ca-public-sha256' -or
        (Get-Sha256Bytes $KrlBytes) -cne $Intent.Fields.'krl-sha256' -or
        $script:Ascii.GetString($CaBytes) -match '(?i)PRIVATE KEY') { throw "fleet_trust_digest_drift" }
    $ObservedFingerprints = [string[]]@(Get-SshFingerprints $Layout.CaPublic $Layout | Sort-Object)
    $ExpectedFingerprints = [Collections.Generic.List[string]]::new()
    [void]$ExpectedFingerprints.Add($Intent.Fields.'primary-ca-fingerprint')
    if ($Intent.Fields.'trust-mode' -ceq "dual") {
        [void]$ExpectedFingerprints.Add($Intent.Fields.'previous-ca-fingerprint')
    }
    $ExpectedSorted = [string[]]@($ExpectedFingerprints.ToArray() | Sort-Object)
    if (($ObservedFingerprints -join "`n") -cne ($ExpectedSorted -join "`n")) {
        throw "fleet_ca_fingerprint_drift"
    }
    $KrlCheck = Invoke-CleanNative $Layout.SshKeygen @("-Q", "-f", $Layout.Krl, $Layout.CaPublic) `
        $Layout 30 65536
    if ($KrlCheck.ExitCode -notin @(0, 1)) { throw "invalid_openssh_krl" }
    return [pscustomobject]@{ CaBytes = $CaBytes; KrlBytes = $KrlBytes }
}

function Get-U3AllowedSignersBytes([byte[]]$CaBytes, [string]$FleetDomain) {
    if (-not (Test-FleetDomain $FleetDomain)) { throw "invalid_u3_trust_publication" }
    $Lines = [string[]]@(ConvertFrom-CanonicalAsciiBytes $CaBytes $script:MaximumCaBytes `
        "fleet_ca_publication")
    if ($Lines.Count -lt 1 -or $Lines.Count -gt 2) { throw "invalid_u3_trust_publication" }
    $Allowed = [Collections.Generic.List[string]]::new()
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($Line in $Lines) {
        $Match = [regex]::Match($Line,
            '^(ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa) ([A-Za-z0-9+/]+={0,2})(?: [!-~]+(?: [!-~]+)*)?$')
        if (-not $Match.Success) { throw "invalid_u3_trust_publication" }
        $KeyType = $Match.Groups[1].Value; $EncodedKey = $Match.Groups[2].Value
        try { [byte[]]$DecodedKey = [Convert]::FromBase64String($EncodedKey) }
        catch { throw "invalid_u3_trust_publication" }
        if ($DecodedKey.Count -lt 1 -or $DecodedKey.Count -gt 8192 -or
            [Convert]::ToBase64String($DecodedKey) -cne $EncodedKey) {
            throw "invalid_u3_trust_publication"
        }
        $CanonicalKey = "$KeyType $EncodedKey"
        if (-not $Seen.Add($CanonicalKey)) { throw "invalid_u3_trust_publication" }
        [void]$Allowed.Add("*@$FleetDomain cert-authority $CanonicalKey")
    }
    return ConvertTo-CanonicalAsciiBytes ([string[]]@($Allowed.ToArray() | Sort-Object))
}

function Get-U3HostIdentityBytes([object]$Context) {
    $Fields = $Context.Intent.Fields
    if (-not (Test-Token $Fields.host) -or -not (Test-Sid $Fields.'request-sid') -or
        $Fields.'request-account' -cne $script:RequestAccountName -or
        $Fields.'endpoint-principal' -cne $script:EndpointPrincipal -or
        -not (Test-FleetDomain $Fields.'fleet-domain') -or
        $Fields.'trust-mode' -cnotin @("single", "dual") -or
        -not (Test-SshFingerprint $Fields.'primary-ca-fingerprint') -or
        -not (Test-PositiveUInt $Fields.'primary-ca-generation') -or
        ($Fields.'trust-mode' -ceq "single" -and
            ($Fields.'previous-ca-fingerprint' -cne "-" -or $Fields.'previous-ca-generation' -cne "0")) -or
        ($Fields.'trust-mode' -ceq "dual" -and
            (-not (Test-SshFingerprint $Fields.'previous-ca-fingerprint') -or
                -not (Test-PositiveUInt $Fields.'previous-ca-generation') -or
                $Fields.'previous-ca-fingerprint' -ceq $Fields.'primary-ca-fingerprint')) -or
        -not (Test-SshFingerprint $Context.HostKeyFingerprint)) {
        throw "invalid_u3_host_identity"
    }
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-host-identity|1", "host-id|$($Fields.host)",
        "request-sid|$($Fields.'request-sid')", "request-principal|$($script:RequestAccountName)",
        "fleet-domain|$($Fields.'fleet-domain')",
        "fleet-ca-fingerprint|$($Fields.'primary-ca-fingerprint')",
        "ca-generation|$($Fields.'primary-ca-generation')",
        "previous-ca-fingerprint|$($Fields.'previous-ca-fingerprint')",
        "previous-ca-generation|$($Fields.'previous-ca-generation')",
        "host-key-fingerprint|$($Context.HostKeyFingerprint)", "end-identity|")
}

function Get-U3TrustPublication([object]$Context) {
    $ExpectedCaCount = if ($Context.Intent.Fields.'trust-mode' -ceq "dual") { 2 } else { 1 }
    $CaLines = [string[]]@(ConvertFrom-CanonicalAsciiBytes $Context.Trust.CaBytes `
        $script:MaximumCaBytes "fleet_ca_publication")
    if ($CaLines.Count -ne $ExpectedCaCount -or
        (Get-Sha256Bytes $Context.Trust.CaBytes) -cne $Context.Intent.Fields.'ca-public-sha256' -or
        (Get-Sha256Bytes $Context.Trust.KrlBytes) -cne $Context.Intent.Fields.'krl-sha256') {
        throw "invalid_u3_trust_publication"
    }
    return [pscustomobject]@{
        HostIdentity = Get-U3HostIdentityBytes $Context
        AllowedSigners = Get-U3AllowedSignersBytes $Context.Trust.CaBytes `
            $Context.Intent.Fields.'fleet-domain'
        RevokedKrl = $Context.Trust.KrlBytes
        FleetCa = $Context.Trust.CaBytes
    }
}

function Assert-U3TrustDirectoryEntries([object]$Layout, [bool]$RequireComplete) {
    if (-not [IO.Directory]::Exists($Layout.U3Trust)) {
        if ($RequireComplete) { throw "u3_trust_missing" }
        return
    }
    $Allowed = [string[]]@("allowed_signers", "fleet-ca.pub", "revoked.krl")
    $Observed = [string[]]@([IO.Directory]::EnumerateFileSystemEntries($Layout.U3Trust) |
        ForEach-Object {
            if (-not [IO.File]::Exists($_)) { throw "unknown_u3_trust_artifact" }
            [IO.Path]::GetFileName($_)
        } | Sort-Object)
    if ($RequireComplete) {
        if (($Observed -join "`n") -cne (($Allowed | Sort-Object) -join "`n")) {
            throw "unknown_u3_trust_artifact"
        }
    } else {
        foreach ($Name in $Observed) {
            if ($Name -cnotin $Allowed) { throw "unknown_u3_trust_artifact" }
        }
    }
}

function Assert-U3PublishedTrust([object]$Context) {
    $Expected = Get-U3TrustPublication $Context
    Assert-ProtectedDirectory $Context.Layout.U3Trust $Context.Layout.U3Root `
        $Context.ProtectedDirectorySddl "u3_trust"
    Assert-U3TrustDirectoryEntries $Context.Layout $true
    foreach ($Binding in @(
            @($Context.Layout.U3HostIdentity, $Expected.HostIdentity, 4096, "u3_host_identity"),
            @($Context.Layout.U3Trust + "\allowed_signers", $Expected.AllowedSigners, 16384,
                "u3_allowed_signers"),
            @($Context.Layout.U3Trust + "\revoked.krl", $Expected.RevokedKrl,
                $script:MaximumKrlBytes, "u3_revoked_krl"),
            @($Context.Layout.U3Trust + "\fleet-ca.pub", $Expected.FleetCa,
                $script:MaximumCaBytes, "u3_fleet_ca"))) {
        $Observed = Assert-ProtectedFile $Binding[0] $Context.Layout.U3Root `
            $Context.ProtectedFileSddl ([int64]$Binding[2]) $Context.Layout $Binding[3]
        if ((Get-Sha256Bytes $Observed) -cne (Get-Sha256Bytes $Binding[1])) {
            throw "u3_trust_publication_drift"
        }
    }
}

function Publish-U3Trust([object]$Context) {
    $Expected = Get-U3TrustPublication $Context
    if ([IO.Directory]::Exists($Context.Layout.U3Trust)) {
        Assert-ProtectedDirectory $Context.Layout.U3Trust $Context.Layout.U3Root `
            $Context.ProtectedDirectorySddl "u3_trust"
        Assert-U3TrustDirectoryEntries $Context.Layout $false
    } else {
        Initialize-ProtectedDirectory $Context.Layout.U3Trust $Context.Layout.U3Root `
            $Context.ProtectedDirectorySddl
    }
    # host.identity is the broker's startup commit marker. Publish the exact authenticated
    # trust inputs first and replace identity last while the U3 drain and broker lock are held.
    foreach ($Binding in @(
            @($Context.Layout.U3Trust + "\fleet-ca.pub", $Expected.FleetCa),
            @($Context.Layout.U3Trust + "\allowed_signers", $Expected.AllowedSigners),
            @($Context.Layout.U3Trust + "\revoked.krl", $Expected.RevokedKrl),
            @($Context.Layout.U3HostIdentity, $Expected.HostIdentity))) {
        Write-AtomicProtectedBytes $Binding[0] $Binding[1] $Context.ProtectedFileSddl `
            $Context.Layout $Context.Layout.U3Root
    }
    Assert-U3PublishedTrust $Context
}

function Get-HostKeyFingerprint([object]$Layout) {
    Assert-SystemProtectedPath $Layout.HostEd25519Key $Layout.ProgramData
    $Fingerprints = [string[]]@(Get-SshFingerprints $Layout.HostEd25519Key $Layout)
    if ($Fingerprints.Count -ne 1) { throw "host_key_fingerprint_ambiguous" }
    return $Fingerprints[0]
}

function Get-CandidateContext(
    [object]$Layout,
    [string]$ExpectedOperation,
    [string]$ExpectedAccountState = "disabled"
) {
    $ProtectedDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    $ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    Assert-ProtectedDirectory $Layout.StageRoot $Layout.ProgramData $ProtectedDirectorySddl "bootstrap_root"
    $BootstrapBytes = Assert-ProtectedFile $Layout.BootstrapReceipt $Layout.StageRoot $ProtectedFileSddl `
        16384 $Layout "bootstrap_receipt"
    $Bootstrap = Read-BootstrapReceipt $BootstrapBytes $Layout.StageRoot $Layout.ProtectedScript
    $CurrentPath = [IO.Path]::GetFullPath($PSCommandPath)
    if (-not $CurrentPath.Equals([IO.Path]::GetFullPath($Layout.ProtectedScript),
            [StringComparison]::OrdinalIgnoreCase)) { throw "protected_entrypoint_required" }
    $ScriptBytes = Assert-ProtectedFile $Layout.ProtectedScript $Layout.StageRoot $ProtectedFileSddl `
        8388608 $Layout "protected_entrypoint"
    $VerifierBytes = Assert-ProtectedFile $Layout.BootstrapVerifier $Layout.StageRoot $ProtectedFileSddl `
        8388608 $Layout "bootstrap_verifier"
    if ((Get-Sha256Bytes $ScriptBytes) -cne $Bootstrap.'protected-copy-sha256' -or
        (Get-Sha256Bytes $ScriptBytes) -cne $Bootstrap.'candidate-sha256' -or
        (Get-Sha256Bytes $VerifierBytes) -cne $Bootstrap.'bootstrap-verifier-sha256') {
        throw "authenticated_bootstrap_digest_drift"
    }
    Assert-AuthenticodePublisher $Layout.ProtectedScript $Bootstrap.'publisher-thumbprint'
    Assert-AuthenticodePublisher $Layout.BootstrapVerifier $Bootstrap.'publisher-thumbprint'
    $IntentBytes = Assert-ProtectedFile $Layout.Intent $Layout.StageRoot $ProtectedFileSddl `
        $script:MaximumIntentBytes $Layout "controller_intent"
    $IntentSignature = Assert-ProtectedFile $Layout.IntentSignature $Layout.StageRoot $ProtectedFileSddl `
        65536 $Layout "controller_intent_signature"
    $Intent = Read-ControllerIntent $IntentBytes $ExpectedOperation
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($Intent.IssuedAt -gt ($Now + $script:ClockSkewSeconds) -or $Intent.ExpiresAt -le $Now -or
        -not (Test-DetachedCmsSignature $IntentBytes $IntentSignature `
            $Bootstrap.'controller-signing-thumbprint' $Intent.IssuedAt $Intent.ExpiresAt)) {
        throw "controller_intent_signature_invalid"
    }
    $HostName = [Environment]::MachineName.ToUpperInvariant()
    if ($Intent.Fields.host -cne $HostName) { throw "controller_intent_host_mismatch" }
    [void](Assert-OpenSshBinaries $Layout)
    $Trust = Assert-CaAndKrl $Layout $Intent $ProtectedFileSddl
    $U3 = Assert-U3State $Layout $Intent $ExpectedAccountState
    $GenerationRoot = $Layout.Generations + "\" + $Intent.Sha256
    $ManagedLines = Get-ManagedSshdBlock $GenerationRoot
    Assert-SystemProtectedPath $Layout.SshdConfig $Layout.ProgramData
    $ExistingConfig = Read-HeldBytes $Layout.SshdConfig 4194304
    $CandidateConfig = Set-ManagedSshdBlock $ExistingConfig $ManagedLines
    $ConfigurationSha256 = Get-Sha256Bytes $CandidateConfig
    $FirewallBytes = Get-FirewallContractBytes $Intent
    $FirewallSha256 = Get-Sha256Bytes $FirewallBytes
    $HostKeyFingerprint = Get-HostKeyFingerprint $Layout
    $ControllerSignatureSha256 = Get-Sha256Bytes $IntentSignature
    $ReceiptBytes = Get-CandidateReceiptBytes $ExpectedOperation $Intent $Bootstrap $HostKeyFingerprint `
        $ConfigurationSha256 $FirewallSha256 $ControllerSignatureSha256
    return [pscustomobject]@{
        Layout = $Layout; Bootstrap = $Bootstrap; Intent = $Intent; IntentBytes = $IntentBytes
        IntentSignatureBytes = $IntentSignature; Trust = $Trust; U3 = $U3; GenerationRoot = $GenerationRoot
        ManagedLines = $ManagedLines; ExistingConfig = $ExistingConfig; CandidateConfig = $CandidateConfig
        ConfigurationSha256 = $ConfigurationSha256; FirewallBytes = $FirewallBytes
        FirewallSha256 = $FirewallSha256; HostKeyFingerprint = $HostKeyFingerprint
        CandidateReceiptBytes = $ReceiptBytes; CandidateReceiptSha256 = Get-Sha256Bytes $ReceiptBytes
        ProtectedDirectorySddl = $ProtectedDirectorySddl; ProtectedFileSddl = $ProtectedFileSddl
    }
}

function Assert-CandidateMutationAuthority(
    [object]$Context,
    [object]$CurrentIntent,
    [byte[]]$CurrentIntentBytes,
    [byte[]]$CurrentIntentSignature,
    [int64]$Now = -1
) {
    if ($Now -lt 0) { $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    if ($CurrentIntent.Sha256 -cne $Context.Intent.Sha256 -or
        -not (Test-FixedTimeBytesEqual $CurrentIntentBytes $Context.IntentBytes) -or
        -not (Test-FixedTimeBytesEqual $CurrentIntentSignature $Context.IntentSignatureBytes) -or
        $CurrentIntent.Fields.operation -cne $Context.Intent.Fields.operation -or
        $CurrentIntent.Fields.host -cne $Context.Intent.Fields.host -or
        $CurrentIntent.Fields.'request-sid' -cne $Context.Intent.Fields.'request-sid' -or
        $CurrentIntent.IssuedAt -gt ($Now + $script:ClockSkewSeconds) -or
        $CurrentIntent.ExpiresAt -le $Now -or
        -not (Test-DetachedCmsSignature $CurrentIntentBytes $CurrentIntentSignature `
            $Context.Bootstrap.'controller-signing-thumbprint' $CurrentIntent.IssuedAt $CurrentIntent.ExpiresAt)) {
        throw "controller_intent_authority_drift"
    }
}

function Assert-CurrentCandidateMutationAuthority(
    [object]$Context,
    [string]$ExpectedAccountState,
    [int64]$Now = -1
) {
    $IntentBytes = Assert-ProtectedFile $Context.Layout.Intent $Context.Layout.StageRoot `
        $Context.ProtectedFileSddl $script:MaximumIntentBytes $Context.Layout "controller_intent"
    $IntentSignature = Assert-ProtectedFile $Context.Layout.IntentSignature $Context.Layout.StageRoot `
        $Context.ProtectedFileSddl 65536 $Context.Layout "controller_intent_signature"
    $Intent = Read-ControllerIntent $IntentBytes $Context.Intent.Fields.operation
    Assert-CandidateMutationAuthority $Context $Intent $IntentBytes $IntentSignature $Now
    if ($Intent.Fields.host -cne [Environment]::MachineName.ToUpperInvariant()) {
        throw "controller_intent_host_mismatch"
    }
    [void](Assert-RequestAccount $Context.Layout $Intent.Fields.'request-sid' $ExpectedAccountState)
}

function Assert-SshdConfiguration([object]$Layout, [object]$Context, [string]$ConfigurationPath) {
    $Syntax = Invoke-CleanNative $Layout.Sshd @("-t", "-f", $ConfigurationPath) $Layout 30 1048576
    if ($Syntax.ExitCode -ne 0) { throw "sshd_configuration_invalid" }
    $Effective = Invoke-CleanNative $Layout.Sshd @(
        "-T", "-f", $ConfigurationPath, "-C",
        "user=$($script:RequestAccountName),host=localhost,addr=127.0.0.1") $Layout 30 1048576
    if ($Effective.ExitCode -ne 0) { throw "sshd_effective_configuration_invalid" }
    $Observed = [ordered]@{}
    foreach ($Line in @($Effective.StdOut -split '\r?\n' | Where-Object { $_.Trim().Length -gt 0 })) {
        $Parts = $Line.Trim().Split(' ', 2, [StringSplitOptions]::RemoveEmptyEntries)
        if ($Parts.Count -eq 2 -and -not $Observed.Contains($Parts[0].ToLowerInvariant())) {
            $Observed[$Parts[0].ToLowerInvariant()] = $Parts[1].Trim()
        }
    }
    $Expected = [ordered]@{
        "forcecommand" = "internal-sftp"
        "chrootdirectory" = "C:\ProgramData\MachineUtilities\chroot"
        "pubkeyauthentication" = "yes"
        "passwordauthentication" = "no"
        "kbdinteractiveauthentication" = "no"
        "permittty" = "no"
        "x11forwarding" = "no"
        "allowtcpforwarding" = "no"
        "allowstreamlocalforwarding" = "no"
        "allowagentforwarding" = "no"
        "permittunnel" = "no"
        "permituserenvironment" = "no"
        "permituserrc" = "no"
    }
    foreach ($Name in $Expected.Keys) {
        if (-not $Observed.Contains($Name) -or
            -not $Observed[$Name].Equals($Expected[$Name], [StringComparison]::OrdinalIgnoreCase)) {
            throw "sshd_effective_configuration_drift"
        }
    }
    if (-not $Observed.Contains("trustedusercakeys") -or
        -not $Observed["trustedusercakeys"].Equals($Context.GenerationRoot + "\fleet-ca.pub",
            [StringComparison]::OrdinalIgnoreCase) -or
        -not $Observed.Contains("revokedkeys") -or
        -not $Observed["revokedkeys"].Equals($Context.GenerationRoot + "\revoked.krl",
            [StringComparison]::OrdinalIgnoreCase) -or
        -not $Observed.Contains("authorizedprincipalsfile") -or
        -not $Observed["authorizedprincipalsfile"].Equals($Context.GenerationRoot + "\authorized-principals",
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "sshd_effective_trust_drift"
    }
}

function Set-PathSddl([string]$Path, [string]$Sddl, [bool]$Directory) {
    if ($Directory) {
        $Security = [Security.AccessControl.DirectorySecurity]::new()
        $Security.SetSecurityDescriptorSddlForm($Sddl)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $Security)
    } else {
        $Security = [Security.AccessControl.FileSecurity]::new()
        $Security.SetSecurityDescriptorSddlForm($Sddl)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $Security)
    }
    Assert-PathSddl $Path $Sddl "managed_path"
}

function Initialize-ProtectedDirectory([string]$Path, [string]$Boundary, [string]$Sddl) {
    Assert-NoReparseAncestors ([IO.Directory]::GetParent($Path).FullName) $Boundary
    if ([IO.File]::Exists($Path)) { throw "managed_directory_type_drift" }
    if (-not [IO.Directory]::Exists($Path)) { [void][IO.Directory]::CreateDirectory($Path) }
    $Item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $Item.LinkType) {
        throw "managed_directory_reparse"
    }
    Set-PathSddl $Path $Sddl $true
}

function Write-AtomicProtectedBytes(
    [string]$Path,
    [byte[]]$Bytes,
    [string]$Sddl,
    [object]$Layout,
    [string]$Boundary
) {
    if ($Bytes.Count -lt 1) { throw "managed_file_empty" }
    $Parent = [IO.Directory]::GetParent($Path).FullName
    Assert-NoReparseAncestors $Parent $Boundary
    $Temporary = $Parent + "\.u6-" + [Guid]::NewGuid().ToString("N") + ".tmp"
    if ([IO.File]::Exists($Temporary) -or [IO.Directory]::Exists($Temporary)) { throw "temporary_path_collision" }
    $Stream = [IO.File]::Open($Temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true)
    } finally { $Stream.Dispose() }
    try {
        Set-PathSddl $Temporary $Sddl $false
        Assert-SingleHardLink $Temporary $Layout
        if ([IO.File]::Exists($Path)) {
            Assert-NoReparseAncestors $Path $Boundary
            Assert-SingleHardLink $Path $Layout
        } elseif ([IO.Directory]::Exists($Path)) { throw "managed_file_type_drift" }
        [IO.File]::Move($Temporary, $Path, $true)
        Assert-PathSddl $Path $Sddl "managed_file"
        if ((Get-Sha256Bytes (Read-HeldBytes $Path ([Math]::Max($Bytes.Count, 1)))) -cne
            (Get-Sha256Bytes $Bytes)) { throw "managed_file_write_drift" }
    } finally {
        if ([IO.File]::Exists($Temporary)) { [IO.File]::Delete($Temporary) }
    }
}

function Initialize-U6Storage([object]$Context) {
    Assert-SystemProtectedPath $Context.Layout.SshdConfig $Context.Layout.ProgramData
    foreach ($Binding in @(
            @($Context.Layout.U6Root, $Context.Layout.ProgramData),
            @($Context.Layout.U6State, $Context.Layout.U6Root),
            @($Context.Layout.Generations, $Context.Layout.U6Root))) {
        Initialize-ProtectedDirectory $Binding[0] $Binding[1] $Context.ProtectedDirectorySddl
    }
    $PublicDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)"
    Initialize-ProtectedDirectory $Context.Layout.PublicRoot $Context.Layout.ProgramData $PublicDirectorySddl
}

function Get-PublicSddl {
    return [pscustomobject]@{
        Directory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)"
        File = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x120089;;;BU)"
    }
}

function Set-RequestAccountEnabled([object]$Layout, [bool]$Enabled) {
    Import-ProtectedWindowsModule $Layout "Microsoft.PowerShell.LocalAccounts\Microsoft.PowerShell.LocalAccounts.psd1"
    if ($Enabled) {
        Microsoft.PowerShell.LocalAccounts\Enable-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    } else {
        Microsoft.PowerShell.LocalAccounts\Disable-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    }
    $Account = Microsoft.PowerShell.LocalAccounts\Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    if ([bool]$Account.Enabled -ne $Enabled) { throw "request_account_state_change_failed" }
}

function Import-NetSecurity([object]$Layout) {
    Import-ProtectedWindowsModule $Layout "NetSecurity\NetSecurity.psd1"
}

function Get-ManagedFirewallRule([object]$Layout) {
    Import-NetSecurity $Layout
    $Rules = @(NetSecurity\Get-NetFirewallRule -Name $script:FirewallRuleId -ErrorAction SilentlyContinue)
    if ($Rules.Count -gt 1) { throw "managed_firewall_ambiguous" }
    if ($Rules.Count -eq 0) { return $null }
    $Rule = $Rules[0]
    if ([string]$Rule.DisplayName -cne $script:FirewallRuleName -or
        [string]$Rule.Group -cne $script:FirewallRuleGroup) { throw "unknown_managed_firewall_artifact" }
    return $Rule
}

function Get-ManagedFirewallObservation([object]$Layout) {
    $Rule = Get-ManagedFirewallRule $Layout
    if ($null -eq $Rule) {
        return [pscustomobject]@{ Present = $false; Enabled = $false; RemoteAddresses = "-" }
    }
    $Port = @(NetSecurity\Get-NetFirewallPortFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop)
    $Address = @(NetSecurity\Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop)
    $Service = @(NetSecurity\Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop)
    if ($Port.Count -ne 1 -or $Address.Count -ne 1 -or $Service.Count -ne 1 -or
        [string]$Rule.Direction -cne "Inbound" -or [string]$Rule.Action -cne "Allow" -or
        [string]$Rule.Profile -cne "Any" -or [string]$Rule.EdgeTraversalPolicy -cne "Block" -or
        [string]$Port[0].Protocol -notin @("TCP", "6") -or [string]$Port[0].LocalPort -cne "22" -or
        [string]$Port[0].RemotePort -cne "Any" -or [string]$Address[0].LocalAddress -cne "Any" -or
        [string]$Service[0].Service -cne "sshd") { throw "managed_firewall_drift" }
    $Remote = [string[]]@($Address[0].RemoteAddress | ForEach-Object { [string]$_ } | Sort-Object)
    return [pscustomobject]@{
        Present = $true
        Enabled = ([string]$Rule.Enabled -ceq "True")
        RemoteAddresses = ($Remote -join ',')
    }
}

function Close-ManagedFirewall([object]$Layout) {
    $Rule = Get-ManagedFirewallRule $Layout
    if ($null -ne $Rule) {
        NetSecurity\Set-NetFirewallRule -InputObject $Rule -Enabled False -ErrorAction Stop | Out-Null
        if ((Get-ManagedFirewallObservation $Layout).Enabled) { throw "managed_firewall_close_failed" }
    }
}

function Remove-ManagedFirewall([object]$Layout) {
    $Rule = Get-ManagedFirewallRule $Layout
    if ($null -ne $Rule) {
        if ([string]$Rule.Enabled -ceq "True") { throw "managed_firewall_must_be_closed" }
        NetSecurity\Remove-NetFirewallRule -InputObject $Rule -ErrorAction Stop
        if ($null -ne (Get-ManagedFirewallRule $Layout)) { throw "managed_firewall_remove_failed" }
    }
}

function Install-ManagedFirewall([object]$Layout, [object]$Intent, [bool]$Enabled) {
    Close-ManagedFirewall $Layout
    Remove-ManagedFirewall $Layout
    $Cidrs = [string[]]@(Read-ManagementCidrs $Intent.Fields.'management-cidrs')
    NetSecurity\New-NetFirewallRule -Name $script:FirewallRuleId -DisplayName $script:FirewallRuleName `
        -Group $script:FirewallRuleGroup -Direction Inbound -Action Allow -Enabled False -Profile Any `
        -Protocol TCP -LocalPort 22 -RemoteAddress $Cidrs -Service "sshd" -ErrorAction Stop | Out-Null
    $Observed = Get-ManagedFirewallObservation $Layout
    if (-not $Observed.Present -or $Observed.RemoteAddresses -cne (($Cidrs | Sort-Object) -join ',')) {
        throw "managed_firewall_install_drift"
    }
    if ($Enabled) {
        $Rule = Get-ManagedFirewallRule $Layout
        NetSecurity\Set-NetFirewallRule -InputObject $Rule -Enabled True -ErrorAction Stop | Out-Null
        if (-not (Get-ManagedFirewallObservation $Layout).Enabled) { throw "managed_firewall_enable_failed" }
    }
}

function Get-SshdServiceSnapshot([object]$Layout) {
    $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $Key = $Base.OpenSubKey("SYSTEM\CurrentControlSet\Services\sshd", $false)
        if ($null -eq $Key) { throw "openssh_service_missing" }
        try {
            $Start = [int]$Key.GetValue("Start", -1)
            $Delayed = [int]$Key.GetValue("DelayedAutoStart", 0)
            $ImagePath = [string]$Key.GetValue("ImagePath", "",
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $ObjectName = [string]$Key.GetValue("ObjectName", "")
        } finally { $Key.Dispose() }
    } finally { $Base.Dispose() }
    if ($Start -notin @(2, 3, 4) -or $Delayed -notin @(0, 1) -or
        $ObjectName -cnotin @("LocalSystem", ".\LocalSystem") -or
        $ImagePath -notmatch '(?i)(?:%SystemRoot%|C:\\Windows)\\System32\\OpenSSH\\sshd\.exe') {
        throw "openssh_service_identity_drift"
    }
    $Controller = [ServiceProcess.ServiceController]::new("sshd")
    try { $Status = [string]$Controller.Status } finally { $Controller.Dispose() }
    return [pscustomobject]@{ Start = $Start; Delayed = $Delayed; Status = $Status }
}

function Set-SshdServiceAutomatic([object]$Layout) {
    $Result = Invoke-CleanNative $Layout.Sc @("config", "sshd", "start=", "auto") $Layout 30 65536
    if ($Result.ExitCode -ne 0) { throw "openssh_service_configuration_failed" }
    $Snapshot = Get-SshdServiceSnapshot $Layout
    if ($Snapshot.Start -ne 2) { throw "openssh_service_not_automatic" }
}

function Set-SshdServiceStartMode([object]$Layout, [int]$Start, [int]$Delayed) {
    $Mode = switch ($Start) { 2 { "auto" } 3 { "demand" } 4 { "disabled" } default { throw "invalid_service_start" } }
    $Result = Invoke-CleanNative $Layout.Sc @("config", "sshd", "start=", $Mode) $Layout 30 65536
    if ($Result.ExitCode -ne 0) { throw "openssh_service_restore_failed" }
    $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $Key = $Base.OpenSubKey("SYSTEM\CurrentControlSet\Services\sshd", $true)
        if ($null -eq $Key) { throw "openssh_service_restore_failed" }
        try { $Key.SetValue("DelayedAutoStart", $Delayed, [Microsoft.Win32.RegistryValueKind]::DWord) }
        finally { $Key.Dispose() }
    } finally { $Base.Dispose() }
}

function Set-SshdServiceRunning([bool]$Running) {
    $Controller = [ServiceProcess.ServiceController]::new("sshd")
    try {
        $Controller.Refresh()
        if ($Running) {
            if ($Controller.Status -eq [ServiceProcess.ServiceControllerStatus]::Stopped) { $Controller.Start() }
            $Controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(60))
        } else {
            if ($Controller.Status -notin @([ServiceProcess.ServiceControllerStatus]::Stopped,
                    [ServiceProcess.ServiceControllerStatus]::StopPending)) { $Controller.Stop() }
            $Controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
        }
    } finally { $Controller.Dispose() }
}

function Restart-SshdService {
    Set-SshdServiceRunning $false
    Set-SshdServiceRunning $true
}

function Write-SshdConfiguration([object]$Context, [byte[]]$Bytes, [string]$ExpectedCurrentSha256) {
    $Path = $Context.Layout.SshdConfig
    Assert-SystemProtectedPath $Path $Context.Layout.ProgramData
    $CurrentBytes = Read-HeldBytes $Path 4194304
    if ((Get-Sha256Bytes $CurrentBytes) -cne $ExpectedCurrentSha256) { throw "sshd_config_concurrent_drift" }
    $Sddl = Get-PathSddl $Path
    Write-AtomicProtectedBytes $Path $Bytes $Sddl $Context.Layout $Context.Layout.ProgramData
}

function New-CryptographicNonce {
    [byte[]]$Bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($Bytes)
    return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-TransactionBytes([object]$Transaction) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-transaction|1", "transaction-id|$($Transaction.Id)",
        "operation|$($Transaction.Operation)", "phase|$($Transaction.Phase)",
        "intent-sha256|$($Transaction.IntentSha256)", "candidate-sha256|$($Transaction.CandidateSha256)",
        "configuration-before-sha256|$($Transaction.ConfigurationBeforeSha256)",
        "configuration-after-sha256|$($Transaction.ConfigurationAfterSha256)",
        "u3-drain-operation|$($Transaction.DrainOperation)",
        "u3-drain-transaction-id|$($Transaction.DrainTransactionId)",
        "u3-epoch|$($Transaction.U3Epoch)",
        "prior-system-task-enabled|$($Transaction.PriorSystemTaskEnabled.ToString().ToLowerInvariant())",
        "prior-profile-task-enabled|$($Transaction.PriorProfileTaskEnabled.ToString().ToLowerInvariant())",
        "prior-system-task-xml-sha256|$($Transaction.PriorSystemTaskXmlSha256)",
        "prior-profile-task-xml-sha256|$($Transaction.PriorProfileTaskXmlSha256)",
        "prior-account-enabled|$($Transaction.PriorAccountEnabled.ToString().ToLowerInvariant())",
        "prior-firewall-present|$($Transaction.PriorFirewallPresent.ToString().ToLowerInvariant())",
        "prior-firewall-enabled|$($Transaction.PriorFirewallEnabled.ToString().ToLowerInvariant())",
        "prior-firewall-addresses|$($Transaction.PriorFirewallAddresses)",
        "prior-service-start|$($Transaction.PriorServiceStart)",
        "prior-service-delayed|$($Transaction.PriorServiceDelayed)",
        "prior-service-status|$($Transaction.PriorServiceStatus)",
        "prior-active-sha256|$($Transaction.PriorActiveSha256)",
        "snapshot-complete|$($Transaction.SnapshotComplete.ToString().ToLowerInvariant())",
        "end-transaction|"
    )
}

function Read-Transaction([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 8192 "transaction") @(
        "transaction-id", "operation", "phase", "intent-sha256", "candidate-sha256",
        "configuration-before-sha256", "configuration-after-sha256", "u3-drain-operation",
        "u3-drain-transaction-id", "u3-epoch", "prior-system-task-enabled",
        "prior-profile-task-enabled", "prior-system-task-xml-sha256",
        "prior-profile-task-xml-sha256", "prior-account-enabled",
        "prior-firewall-present", "prior-firewall-enabled", "prior-firewall-addresses",
        "prior-service-start", "prior-service-delayed", "prior-service-status", "prior-active-sha256",
        "snapshot-complete") "windows-sftp-transaction|1" "end-transaction|" "transaction"
    if (-not (Test-Digest $Fields.'transaction-id') -or
        $Fields.operation -cnotin @("install", "repair", "revoke") -or
        $Fields.phase -cnotin @("contained", "snapshotted", "staged", "configured", "restarted",
            "canary", "activated", "committed", "rolled-back") -or
        -not (Test-Digest $Fields.'intent-sha256') -or -not (Test-Digest $Fields.'candidate-sha256') -or
        -not (Test-Digest $Fields.'configuration-before-sha256') -or
        -not (Test-Digest $Fields.'configuration-after-sha256') -or
        $Fields.'u3-drain-operation' -cne (Get-U3DrainOperation $Fields.operation) -or
        $Fields.'u3-drain-transaction-id' -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        -not (Test-PositiveUInt $Fields.'u3-epoch') -or
        $Fields.'prior-system-task-enabled' -cnotin @("true", "false") -or
        $Fields.'prior-profile-task-enabled' -cnotin @("true", "false") -or
        -not (Test-Digest $Fields.'prior-system-task-xml-sha256') -or
        -not (Test-Digest $Fields.'prior-profile-task-xml-sha256') -or
        $Fields.'prior-account-enabled' -cnotin @("true", "false") -or
        $Fields.'prior-firewall-present' -cnotin @("true", "false") -or
        $Fields.'prior-firewall-enabled' -cnotin @("true", "false") -or
        $Fields.'snapshot-complete' -cnotin @("true", "false") -or
        $Fields.'prior-service-start' -cnotmatch '^[234]$' -or
        $Fields.'prior-service-delayed' -cnotmatch '^[01]$' -or
        $Fields.'prior-service-status' -cnotin @("Running", "Stopped", "Paused", "StartPending", "StopPending") -or
        ($Fields.'prior-active-sha256' -cne "-" -and -not (Test-Digest $Fields.'prior-active-sha256'))) {
        throw "invalid_transaction"
    }
    return $Fields
}

function Write-Transaction([object]$Context, [object]$Transaction) {
    Write-AtomicProtectedBytes ($Context.Layout.U6State + "\lifecycle.transaction") `
        (Get-TransactionBytes $Transaction) $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
}

function Set-TransactionPhase([object]$Context, [object]$Transaction, [string]$Phase) {
    $Transaction.Phase = $Phase
    Write-Transaction $Context $Transaction
}

function Get-ActiveRecordBytes(
    [string]$State,
    [object]$Context,
    [string]$CanaryReceiptSha256,
    [string]$CanarySignatureSha256,
    [string]$CanaryEvidenceSha256,
    [string]$ControllerReceiptSignatureSha256 = "-"
) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-active-enrollment|1", "state|$State", "host|$($Context.Intent.Fields.host)",
        "request-sid|$($Context.Intent.Fields.'request-sid')", "intent-sha256|$($Context.Intent.Sha256)",
        "intent-signature-sha256|$(Get-Sha256Bytes $Context.IntentSignatureBytes)",
        "candidate-sha256|$($Context.CandidateReceiptSha256)",
        "controller-signing-thumbprint|$($Context.Bootstrap.'controller-signing-thumbprint')",
        "native-canary-signing-thumbprint|$($Context.Bootstrap.'native-canary-signing-thumbprint')",
        "controller-receipt-signature-sha256|$ControllerReceiptSignatureSha256",
        "configuration-sha256|$($Context.ConfigurationSha256)",
        "firewall-contract-sha256|$($Context.FirewallSha256)",
        "host-key-fingerprint|$($Context.HostKeyFingerprint)",
        "canary-receipt-sha256|$CanaryReceiptSha256", "canary-signature-sha256|$CanarySignatureSha256",
        "canary-evidence-sha256|$CanaryEvidenceSha256", "issued-at|$($Context.Intent.Fields.'issued-at')",
        "expires-at|$($Context.Intent.Fields.'expires-at')", "end-enrollment|"
    )
}

function Read-ActiveRecord([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 8192 "active_enrollment") @(
        "state", "host", "request-sid", "intent-sha256", "intent-signature-sha256",
        "candidate-sha256", "controller-signing-thumbprint", "native-canary-signing-thumbprint",
        "controller-receipt-signature-sha256", "configuration-sha256", "firewall-contract-sha256",
        "host-key-fingerprint", "canary-receipt-sha256", "canary-signature-sha256",
        "canary-evidence-sha256", "issued-at", "expires-at") `
        "windows-sftp-active-enrollment|1" "end-enrollment|" "active_enrollment"
    if ($Fields.state -cnotin @("awaiting-controller-signature", "ready") -or
        -not (Test-HostName $Fields.host) -or -not (Test-Sid $Fields.'request-sid') -or
        -not (Test-Thumbprint $Fields.'controller-signing-thumbprint') -or
        -not (Test-Thumbprint $Fields.'native-canary-signing-thumbprint') -or
        -not (Test-SshFingerprint $Fields.'host-key-fingerprint') -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at')) {
        throw "invalid_active_enrollment"
    }
    foreach ($Name in @("intent-sha256", "intent-signature-sha256", "candidate-sha256",
            "configuration-sha256", "firewall-contract-sha256", "canary-receipt-sha256",
            "canary-signature-sha256", "canary-evidence-sha256")) {
        if (-not (Test-Digest $Fields[$Name])) { throw "invalid_active_enrollment" }
    }
    if (($Fields.state -ceq "ready") -ne (Test-Digest $Fields.'controller-receipt-signature-sha256')) {
        throw "invalid_active_enrollment"
    }
    return $Fields
}

function Get-ReadinessBytes([string]$State, [string]$Reason, [object]$Active) {
    $TransportReady = ($State -ceq "ready").ToString().ToLowerInvariant()
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-readiness|1", "state|$State", "reason|$Reason",
        "host|$($Active.host)", "request-sid|$($Active.'request-sid')",
        "intent-sha256|$($Active.'intent-sha256')", "candidate-sha256|$($Active.'candidate-sha256')",
        "host-key-fingerprint|$($Active.'host-key-fingerprint')", "transport-ready|$TransportReady",
        "broker-ready|observed-separately", "node-identity-ready|observed-separately",
        "action-context-ready|observed-separately", "controller-signature-ready|$TransportReady",
        "readiness-authority|controller-signed-receipt-plus-local-observation", "end-readiness|"
    )
}

function Publish-Readiness([object]$Context, [byte[]]$ActiveBytes, [byte[]]$CandidateBytes,
    [string]$State, [string]$Reason, [byte[]]$ControllerSignature = $null) {
    $Public = Get-PublicSddl
    $Active = Read-ActiveRecord $ActiveBytes
    Write-AtomicProtectedBytes ($Context.Layout.PublicRoot + "\candidate.receipt") $CandidateBytes `
        $Public.File $Context.Layout $Context.Layout.PublicRoot
    $PublicSignaturePath = $Context.Layout.PublicRoot + "\candidate.receipt.p7s"
    if ($null -ne $ControllerSignature) {
        Write-AtomicProtectedBytes $PublicSignaturePath $ControllerSignature $Public.File `
            $Context.Layout $Context.Layout.PublicRoot
    } elseif ([IO.File]::Exists($PublicSignaturePath)) {
        [void](Assert-ProtectedFile $PublicSignaturePath $Context.Layout.PublicRoot $Public.File `
            $script:MaximumReceiptBytes $Context.Layout "public_candidate_signature")
        [IO.File]::Delete($PublicSignaturePath)
    }
    Write-AtomicProtectedBytes ($Context.Layout.PublicRoot + "\readiness") `
        (Get-ReadinessBytes $State $Reason $Active) $Public.File $Context.Layout $Context.Layout.PublicRoot
}

function New-Transaction([object]$Context, [string]$Operation, [object]$Firewall,
    [object]$Service, [bool]$PriorAccountEnabled, [byte[]]$PriorActiveBytes) {
    $PriorActiveSha = if ($null -eq $PriorActiveBytes) { "-" } else { Get-Sha256Bytes $PriorActiveBytes }
    $Id = New-CryptographicNonce
    return [pscustomobject]@{
        Id = $Id; Operation = $Operation; Phase = "contained"
        IntentSha256 = $Context.Intent.Sha256; CandidateSha256 = $Context.CandidateReceiptSha256
        ConfigurationBeforeSha256 = Get-Sha256Bytes $Context.ExistingConfig
        ConfigurationAfterSha256 = $Context.ConfigurationSha256
        DrainOperation = Get-U3DrainOperation $Operation
        DrainTransactionId = "transaction-" + $Id.Substring(0, 32)
        U3Epoch = [int64]$Context.Intent.Fields.'u3-epoch'
        PriorSystemTaskEnabled = [bool]$Context.U3.SystemTask.Enabled
        PriorProfileTaskEnabled = [bool]$Context.U3.ProfileTask.Enabled
        PriorSystemTaskXmlSha256 = $Context.U3.SystemTask.XmlSha256
        PriorProfileTaskXmlSha256 = $Context.U3.ProfileTask.XmlSha256
        PriorAccountEnabled = $PriorAccountEnabled
        PriorFirewallPresent = [bool]$Firewall.Present; PriorFirewallEnabled = [bool]$Firewall.Enabled
        PriorFirewallAddresses = [string]$Firewall.RemoteAddresses
        PriorServiceStart = [int]$Service.Start; PriorServiceDelayed = [int]$Service.Delayed
        PriorServiceStatus = [string]$Service.Status; PriorActiveSha256 = $PriorActiveSha
        SnapshotComplete = $false; PriorActiveBytes = $PriorActiveBytes
    }
}

function Save-U3PublicationSnapshot([object]$Context, [string]$RollbackRoot) {
    $TrustDirectoryPresent = [IO.Directory]::Exists($Context.Layout.U3Trust)
    if ($TrustDirectoryPresent) {
        Assert-ProtectedDirectory $Context.Layout.U3Trust $Context.Layout.U3Root `
            $Context.ProtectedDirectorySddl "rollback_u3_trust_source"
        Assert-U3TrustDirectoryEntries $Context.Layout $false
    } elseif ([IO.File]::Exists($Context.Layout.U3Trust)) {
        throw "rollback_u3_trust_type_drift"
    }
    $Digests = [ordered]@{}
    foreach ($Binding in @(
            @("host-identity", $Context.Layout.U3HostIdentity, 4096),
            @("allowed-signers", $Context.Layout.U3Trust + "\allowed_signers", 16384),
            @("revoked-krl", $Context.Layout.U3Trust + "\revoked.krl", $script:MaximumKrlBytes),
            @("fleet-ca", $Context.Layout.U3Trust + "\fleet-ca.pub", $script:MaximumCaBytes))) {
        $Label = [string]$Binding[0]; $Path = [string]$Binding[1]; $Maximum = [int64]$Binding[2]
        if ([IO.Directory]::Exists($Path)) { throw "rollback_u3_source_type_drift" }
        if ([IO.File]::Exists($Path)) {
            $Bytes = Assert-ProtectedFile $Path $Context.Layout.U3Root $Context.ProtectedFileSddl `
                $Maximum $Context.Layout "rollback_u3_source"
            $Digests[$Label] = Get-Sha256Bytes $Bytes
            Write-AtomicProtectedBytes ($RollbackRoot + "\u3-" + $Label + ".data") $Bytes `
                $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        } else { $Digests[$Label] = "-" }
    }
    return [pscustomobject]@{
        TrustDirectoryPresent = $TrustDirectoryPresent
        HostIdentitySha256 = $Digests['host-identity']
        AllowedSignersSha256 = $Digests['allowed-signers']
        RevokedKrlSha256 = $Digests['revoked-krl']
        FleetCaSha256 = $Digests['fleet-ca']
    }
}

function Restore-U3PublicationSnapshot([object]$Context, [object]$Snapshot, [string]$RollbackRoot) {
    if ($Snapshot.'u3-trust-directory-present' -cnotin @("true", "false")) {
        throw "rollback_u3_snapshot_binding_drift"
    }
    foreach ($Name in @("u3-host-identity-sha256", "u3-allowed-signers-sha256",
            "u3-revoked-krl-sha256", "u3-fleet-ca-sha256")) {
        if ($Snapshot[$Name] -cne "-" -and -not (Test-Digest $Snapshot[$Name])) {
            throw "rollback_u3_snapshot_binding_drift"
        }
    }
    $PriorTrustDirectory = $Snapshot.'u3-trust-directory-present' -ceq "true"
    if ([IO.Directory]::Exists($Context.Layout.U3Trust)) {
        Assert-ProtectedDirectory $Context.Layout.U3Trust $Context.Layout.U3Root `
            $Context.ProtectedDirectorySddl "rollback_u3_trust_target"
        Assert-U3TrustDirectoryEntries $Context.Layout $false
    } elseif ([IO.File]::Exists($Context.Layout.U3Trust)) {
        throw "rollback_u3_trust_type_drift"
    } elseif ($PriorTrustDirectory) {
        Initialize-ProtectedDirectory $Context.Layout.U3Trust $Context.Layout.U3Root `
            $Context.ProtectedDirectorySddl
    }
    foreach ($Binding in @(
            @("host-identity", $Context.Layout.U3HostIdentity, "u3-host-identity-sha256", 4096),
            @("allowed-signers", $Context.Layout.U3Trust + "\allowed_signers",
                "u3-allowed-signers-sha256", 16384),
            @("revoked-krl", $Context.Layout.U3Trust + "\revoked.krl",
                "u3-revoked-krl-sha256", $script:MaximumKrlBytes),
            @("fleet-ca", $Context.Layout.U3Trust + "\fleet-ca.pub",
                "u3-fleet-ca-sha256", $script:MaximumCaBytes))) {
        $Label = [string]$Binding[0]; $Path = [string]$Binding[1]
        $DigestName = [string]$Binding[2]; $Maximum = [int64]$Binding[3]
        if ([IO.Directory]::Exists($Path)) { throw "rollback_u3_target_type_drift" }
        if ($Snapshot[$DigestName] -ceq "-") {
            if ([IO.File]::Exists($Path)) {
                [void](Assert-ProtectedFile $Path $Context.Layout.U3Root $Context.ProtectedFileSddl `
                    $Maximum $Context.Layout "rollback_u3_target")
                [IO.File]::Delete($Path)
            }
        } else {
            $Saved = Assert-ProtectedFile ($RollbackRoot + "\u3-" + $Label + ".data") `
                $Context.Layout.U6Root $Context.ProtectedFileSddl $Maximum $Context.Layout `
                "rollback_u3_saved"
            if ((Get-Sha256Bytes $Saved) -cne $Snapshot[$DigestName]) {
                throw "rollback_u3_saved_drift"
            }
            if (-not [IO.Directory]::Exists([IO.Directory]::GetParent($Path).FullName)) {
                throw "rollback_u3_parent_missing"
            }
            Write-AtomicProtectedBytes $Path $Saved $Context.ProtectedFileSddl $Context.Layout `
                $Context.Layout.U3Root
        }
    }
    if (-not $PriorTrustDirectory -and [IO.Directory]::Exists($Context.Layout.U3Trust)) {
        Assert-U3TrustDirectoryEntries $Context.Layout $false
        if (@([IO.Directory]::EnumerateFileSystemEntries($Context.Layout.U3Trust)).Count -ne 0) {
            throw "rollback_u3_trust_not_empty"
        }
        [IO.Directory]::Delete($Context.Layout.U3Trust, $false)
    }
}

function Save-RollbackSnapshot([object]$Context, [object]$Transaction) {
    $RollbackRoot = $Context.Layout.U6State + "\rollback-" + $Transaction.Id
    Initialize-ProtectedDirectory $RollbackRoot $Context.Layout.U6Root $Context.ProtectedDirectorySddl
    Write-AtomicProtectedBytes ($RollbackRoot + "\sshd-config.data") $Context.ExistingConfig `
        $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
    $ConfigSddlBase64 = [Convert]::ToBase64String($script:Utf8.GetBytes((Get-PathSddl $Context.Layout.SshdConfig)))
    if ($null -ne $Transaction.PriorActiveBytes) {
        Write-AtomicProtectedBytes ($RollbackRoot + "\active.data") $Transaction.PriorActiveBytes `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
    }
    $Public = Get-PublicSddl
    $PublicDigests = [ordered]@{}
    foreach ($Name in @("readiness", "candidate.receipt", "candidate.receipt.p7s")) {
        $PublicPath = $Context.Layout.PublicRoot + "\" + $Name
        if ([IO.File]::Exists($PublicPath)) {
            $PublicBytes = Assert-ProtectedFile $PublicPath $Context.Layout.PublicRoot $Public.File `
                $script:MaximumReceiptBytes $Context.Layout "rollback_public_source"
            $PublicDigests[$Name] = Get-Sha256Bytes $PublicBytes
            Write-AtomicProtectedBytes ($RollbackRoot + "\public-" + $Name + ".data") $PublicBytes `
                $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        } else { $PublicDigests[$Name] = "-" }
    }
    $U3Snapshot = Save-U3PublicationSnapshot $Context $RollbackRoot
    $SnapshotBytes = ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-rollback-snapshot|1", "transaction-id|$($Transaction.Id)",
        "sshd-config-sha256|$($Transaction.ConfigurationBeforeSha256)",
        "sshd-config-sddl-base64|$ConfigSddlBase64", "prior-active-sha256|$($Transaction.PriorActiveSha256)",
        "public-readiness-sha256|$($PublicDigests['readiness'])",
        "public-candidate-sha256|$($PublicDigests['candidate.receipt'])",
        "public-candidate-signature-sha256|$($PublicDigests['candidate.receipt.p7s'])",
        "u3-trust-directory-present|$($U3Snapshot.TrustDirectoryPresent.ToString().ToLowerInvariant())",
        "u3-host-identity-sha256|$($U3Snapshot.HostIdentitySha256)",
        "u3-allowed-signers-sha256|$($U3Snapshot.AllowedSignersSha256)",
        "u3-revoked-krl-sha256|$($U3Snapshot.RevokedKrlSha256)",
        "u3-fleet-ca-sha256|$($U3Snapshot.FleetCaSha256)",
        "end-snapshot|"
    )
    Write-AtomicProtectedBytes ($RollbackRoot + "\snapshot") $SnapshotBytes $Context.ProtectedFileSddl `
        $Context.Layout $Context.Layout.U6Root
    $Transaction.SnapshotComplete = $true
    Write-Transaction $Context $Transaction
    Set-TransactionPhase $Context $Transaction "snapshotted"
    return $RollbackRoot
}

function Acquire-LifecycleLock([object]$Context, [int]$TimeoutSeconds = 60) {
    Assert-ProtectedDirectory $Context.Layout.U6Root $Context.Layout.ProgramData `
        $Context.ProtectedDirectorySddl "u6_root"
    Assert-ProtectedDirectory $Context.Layout.U6State $Context.Layout.U6Root `
        $Context.ProtectedDirectorySddl "u6_state"
    $Path = $Context.Layout.U6State + "\lifecycle.lock"
    $LockBytes = ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-lifecycle-lock|1", "end-lock|")
    if (-not [IO.File]::Exists($Path)) {
        $Created = $false
        $CreationStream = $null
        try {
            $CreationStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $CreationStream.Write($LockBytes, 0, $LockBytes.Count)
            $CreationStream.Flush($true)
            $Created = $true
        } catch [IO.IOException] {
            if (-not [IO.File]::Exists($Path)) { throw }
        } finally {
            if ($null -ne $CreationStream) { $CreationStream.Dispose() }
        }
        if ($Created) { Set-PathSddl $Path $Context.ProtectedFileSddl $false }
    }
    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            Assert-NoReparseAncestors $Path $Context.Layout.U6Root
            Assert-PathSddl $Path $Context.ProtectedFileSddl "lifecycle_lock"
            Assert-SingleHardLink $Path $Context.Layout
            $Lock = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
            try {
                if ($Lock.Length -ne $LockBytes.Count) { throw "lifecycle_lock_drift" }
                [byte[]]$Observed = [byte[]]::new($LockBytes.Count)
                $Offset = 0
                while ($Offset -lt $Observed.Count) {
                    $Read = $Lock.Read($Observed, $Offset, $Observed.Count - $Offset)
                    if ($Read -le 0) { throw "lifecycle_lock_drift" }
                    $Offset += $Read
                }
                if (-not (Test-FixedTimeBytesEqual $Observed $LockBytes)) {
                    throw "lifecycle_lock_drift"
                }
                $Lock.Position = 0
                return $Lock
            } catch {
                $Lock.Dispose()
                throw
            }
        } catch [IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw "lifecycle_lock_timeout" }
            Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 100
        }
    }
}

function Get-U3DrainOperation([string]$Operation) {
    if ($Operation -cin @("install", "repair")) { return "install" }
    if ($Operation -ceq "revoke") { return "revoke" }
    throw "invalid_u3_drain_operation"
}

function Get-U3DrainBytes([object]$Containment) {
    if ($Containment.DrainOperation -cnotin @("install", "revoke") -or
        $Containment.DrainTransactionId -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        [int64]$Containment.U3Epoch -lt 1) { throw "invalid_u3_drain_marker" }
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-broker-drain|1", "operation|$($Containment.DrainOperation)",
        "transaction-id|$($Containment.DrainTransactionId)", "epoch|$($Containment.U3Epoch)",
        "state|draining", "end-drain|")
}

function Read-U3DrainBytes([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 1024 "u3_drain_marker") @(
        "operation", "transaction-id", "epoch", "state") `
        "windows-broker-drain|1" "end-drain|" "u3_drain_marker"
    if ($Fields.operation -cnotin @("install", "revoke") -or
        $Fields.'transaction-id' -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        -not (Test-PositiveUInt $Fields.epoch) -or $Fields.state -cne "draining") {
        throw "invalid_u3_drain_marker"
    }
    return $Fields
}

function Assert-U3DrainBinding([object]$Context, [object]$Containment) {
    $Expected = Get-U3DrainBytes $Containment
    $Observed = Assert-ProtectedFile $Context.Layout.U3Drain $Context.Layout.U3Root `
        $Context.ProtectedFileSddl 1024 $Context.Layout "u3_drain"
    [void](Read-U3DrainBytes $Observed)
    if ((Get-Sha256Bytes $Observed) -cne (Get-Sha256Bytes $Expected)) {
        throw "u3_drain_binding_drift"
    }
}

function Assert-U3LifecycleAvailable([object]$Context) {
    $Path = $Context.Layout.U3State + "\lifecycle.transaction"
    if (-not [IO.File]::Exists($Path)) {
        if ([IO.Directory]::Exists($Path)) { throw "u3_lifecycle_transaction_type_drift" }
        return
    }
    Assert-NoReparseAncestors $Path $Context.Layout.U3Root
    Assert-PathSddl $Path $Context.ProtectedFileSddl "u3_lifecycle_transaction"
    Assert-SingleHardLink $Path $Context.Layout
    $Item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force
    if ($Item.Length -eq 0) { return }
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path 4096) 4096 `
            "u3_lifecycle_transaction") @(
        "transaction-id", "operation", "phase", "epoch", "prior-pointer-sha256") `
        "windows-enrollment-transaction|1" "end-transaction|" "u3_lifecycle_transaction"
    if ($Fields.'transaction-id' -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        $Fields.operation -cnotin @("install", "revoke", "activate") -or
        $Fields.phase -cnotin @("committed", "rolled-back") -or
        -not (Test-PositiveUInt $Fields.epoch) -or
        ($Fields.'prior-pointer-sha256' -cne "-" -and
            -not (Test-Digest $Fields.'prior-pointer-sha256'))) {
        throw "u3_lifecycle_recovery_required"
    }
}

function Write-U3Drain([object]$Context, [object]$Containment) {
    $Expected = Get-U3DrainBytes $Containment
    if ([IO.Directory]::Exists($Context.Layout.U3Drain)) { throw "u3_drain_type_drift" }
    if ([IO.File]::Exists($Context.Layout.U3Drain)) {
        Assert-U3DrainBinding $Context $Containment
        return
    }
    Assert-U3LifecycleAvailable $Context
    Write-AtomicProtectedBytes $Context.Layout.U3Drain $Expected $Context.ProtectedFileSddl `
        $Context.Layout $Context.Layout.U3Root
    Assert-U3DrainBinding $Context $Containment
}

function Set-U3TaskEnabled([object]$Layout, [string]$TaskName, [bool]$Enabled) {
    [void](Get-U3TaskSnapshot $TaskName)
    $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
    $Task = $Service.GetFolder("\").GetTask("\$TaskName")
    if ($null -eq $Task) { throw "u3_task_missing" }
    $Task.Enabled = $Enabled
    $Observed = Get-U3TaskSnapshot $TaskName
    if ($Observed.Enabled -ne $Enabled) { throw "u3_task_state_change_failed" }
    return $Observed
}

function Acquire-U3BrokerLock([object]$Context, [int]$TimeoutSeconds = 600) {
    $Path = $Context.Layout.U3BrokerLock
    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            Assert-NoReparseAncestors $Path $Context.Layout.U3Root
            if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
                throw "u3_broker_lock_missing"
            }
            Assert-PathSddl $Path $Context.ProtectedFileSddl "u3_broker_lock"
            Assert-SingleHardLink $Path $Context.Layout
            $Lock = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
            if ($Lock.Length -ne 0) {
                $Lock.Dispose()
                throw "u3_broker_lock_drift"
            }
            return $Lock
        } catch [IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw "u3_broker_lock_timeout" }
            Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 100
        }
    }
}

function Enter-U3Containment([object]$Context, [object]$Containment) {
    Write-U3Drain $Context $Containment
    # Leave the signed U3 tasks runnable long enough to consume and terminalize any submission
    # that crossed the U6 gates before they closed. Once empty, disable both tasks, take the
    # broker lease, and recheck the slot and durable journals under that continuous barrier.
    Wait-U3Quiescent $Context.Layout
    [void](Set-U3TaskEnabled $Context.Layout $script:SystemTaskName $false)
    [void](Set-U3TaskEnabled $Context.Layout $script:ProfileTaskName $false)
    $Lock = Acquire-U3BrokerLock $Context
    try {
        Assert-U3DrainBinding $Context $Containment
        Wait-U3Quiescent $Context.Layout
        return [pscustomobject]@{ Lock = $Lock; Record = $Containment }
    } catch {
        $Lock.Dispose()
        throw
    }
}

function Exit-U3Containment([object]$Context, [object]$Lease) {
    Assert-U3DrainBinding $Context $Lease.Record
    Wait-U3Quiescent $Context.Layout
    $SystemTask = Set-U3TaskEnabled $Context.Layout $script:SystemTaskName `
        ([bool]$Lease.Record.PriorSystemTaskEnabled)
    $ProfileTask = Set-U3TaskEnabled $Context.Layout $script:ProfileTaskName `
        ([bool]$Lease.Record.PriorProfileTaskEnabled)
    if ($SystemTask.XmlSha256 -cne $Lease.Record.PriorSystemTaskXmlSha256 -or
        $ProfileTask.XmlSha256 -cne $Lease.Record.PriorProfileTaskXmlSha256) {
        throw "u3_task_restore_drift"
    }
    Assert-U3DrainBinding $Context $Lease.Record
    [IO.File]::Delete($Context.Layout.U3Drain)
    if ([IO.File]::Exists($Context.Layout.U3Drain) -or [IO.Directory]::Exists($Context.Layout.U3Drain)) {
        throw "u3_drain_release_failed"
    }
    $Lease.Lock.Dispose()
}

function Stage-TransportGeneration([object]$Context) {
    if ([IO.File]::Exists($Context.GenerationRoot) -or [IO.Directory]::Exists($Context.GenerationRoot)) {
        throw "transport_generation_already_exists"
    }
    Initialize-ProtectedDirectory $Context.GenerationRoot $Context.Layout.U6Root $Context.ProtectedDirectorySddl
    $Files = [ordered]@{
        "controller.intent" = $Context.IntentBytes
        "controller.intent.p7s" = $Context.IntentSignatureBytes
        "fleet-ca.pub" = $Context.Trust.CaBytes
        "revoked.krl" = $Context.Trust.KrlBytes
        "authorized-principals" = Get-AuthorizedPrincipalsBytes
        "candidate.receipt" = $Context.CandidateReceiptBytes
        "firewall.contract" = $Context.FirewallBytes
        "sshd.block" = ConvertTo-CanonicalAsciiBytes $Context.ManagedLines
    }
    foreach ($Name in $Files.Keys) {
        Write-AtomicProtectedBytes ($Context.GenerationRoot + "\" + $Name) $Files[$Name] `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
    }
    return $Files
}

function Get-NativeCanaryChallengeBytes([object]$Context, [string]$Nonce) {
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-native-canary-challenge|1", "nonce|$Nonce", "host|$($Context.Intent.Fields.host)",
        "request-sid|$($Context.Intent.Fields.'request-sid')", "intent-sha256|$($Context.Intent.Sha256)",
        "candidate-sha256|$($Context.CandidateReceiptSha256)",
        "configuration-sha256|$($Context.ConfigurationSha256)",
        "firewall-contract-sha256|$($Context.FirewallSha256)",
        "host-key-fingerprint|$($Context.HostKeyFingerprint)", "account-state|disabled-during-canary",
        "managed-firewall-state|disabled", "issued-at|$Now", "expires-at|$($Now + 3600)",
        "signing-thumbprint|$($Context.Bootstrap.'native-canary-signing-thumbprint')", "end-challenge|"
    )
}

function Wait-NativeCanary([object]$Context) {
    Assert-ProtectedDirectory $Context.Layout.NativeCanaryRoot $Context.Layout.StageRoot `
        $Context.ProtectedDirectorySddl "native_canary_root"
    $Nonce = New-CryptographicNonce
    $ChallengePath = $Context.Layout.NativeCanaryRoot + "\challenge-" + $Nonce
    Write-AtomicProtectedBytes $ChallengePath (Get-NativeCanaryChallengeBytes $Context $Nonce) `
        $Context.ProtectedFileSddl $Context.Layout $Context.Layout.StageRoot
    $ReceiptPath = $Context.Layout.NativeCanaryRoot + "\receipt-" + $Nonce + ".receipt"
    $SignaturePath = $Context.Layout.NativeCanaryRoot + "\receipt-" + $Nonce + ".p7s"
    $EvidencePath = $Context.Layout.NativeCanaryRoot + "\receipt-" + $Nonce + ".evidence"
    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds(3600)
    while (-not ([IO.File]::Exists($ReceiptPath) -and [IO.File]::Exists($SignaturePath) -and
            [IO.File]::Exists($EvidencePath))) {
        if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw "transport_native_canary_timeout" }
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds 1
    }
    $ReceiptBytes = Assert-ProtectedFile $ReceiptPath $Context.Layout.StageRoot $Context.ProtectedFileSddl `
        32768 $Context.Layout "transport_canary_receipt"
    $SignatureBytes = Assert-ProtectedFile $SignaturePath $Context.Layout.StageRoot $Context.ProtectedFileSddl `
        65536 $Context.Layout "transport_canary_signature"
    $EvidenceBytes = Assert-ProtectedFile $EvidencePath $Context.Layout.StageRoot $Context.ProtectedFileSddl `
        1048576 $Context.Layout "transport_canary_evidence"
    $Receipt = Read-NativeCanaryReceipt $ReceiptBytes $SignatureBytes $EvidenceBytes $Context.Intent `
        $Context.Bootstrap.'native-canary-signing-thumbprint' $Context.ConfigurationSha256 `
        $Context.FirewallSha256 $Context.HostKeyFingerprint $Nonce
    return [pscustomobject]@{
        Receipt = $Receipt; ReceiptBytes = $ReceiptBytes; SignatureBytes = $SignatureBytes
        EvidenceBytes = $EvidenceBytes; ChallengePath = $ChallengePath
    }
}

function Save-NativeCanary([object]$Context, [object]$Canary) {
    foreach ($Binding in @(
            @("native-canary.receipt", $Canary.ReceiptBytes),
            @("native-canary.receipt.p7s", $Canary.SignatureBytes),
            @("native-canary.evidence", $Canary.EvidenceBytes))) {
        Write-AtomicProtectedBytes ($Context.GenerationRoot + "\" + $Binding[0]) $Binding[1] `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
    }
}

function Assert-ManagedFirewall([object]$Context, [bool]$ExpectedEnabled) {
    $Observed = Get-ManagedFirewallObservation $Context.Layout
    $ExpectedAddresses = ([string[]]@(Read-ManagementCidrs $Context.Intent.Fields.'management-cidrs') |
        Sort-Object) -join ','
    if (-not $Observed.Present -or $Observed.Enabled -ne $ExpectedEnabled -or
        $Observed.RemoteAddresses -cne $ExpectedAddresses) { throw "managed_firewall_drift" }
}

function Enable-ManagedFirewall([object]$Context) {
    Assert-ManagedFirewall $Context $false
    $Rule = Get-ManagedFirewallRule $Context.Layout
    NetSecurity\Set-NetFirewallRule -InputObject $Rule -Enabled True -ErrorAction Stop | Out-Null
    Assert-ManagedFirewall $Context $true
}

function Assert-SshdServiceReady([object]$Layout) {
    $Service = Get-SshdServiceSnapshot $Layout
    if ($Service.Start -ne 2 -or $Service.Status -cne "Running") { throw "openssh_service_not_ready" }
}

function Get-GenerationExpectedNames([bool]$HasCanary, [bool]$HasControllerSignature) {
    $Names = [Collections.Generic.List[string]]::new()
    foreach ($Name in @("authorized-principals", "candidate.receipt", "controller.intent",
            "controller.intent.p7s", "firewall.contract", "fleet-ca.pub", "revoked.krl", "sshd.block")) {
        [void]$Names.Add($Name)
    }
    if ($HasCanary) {
        foreach ($Name in @("native-canary.evidence", "native-canary.receipt", "native-canary.receipt.p7s")) {
            [void]$Names.Add($Name)
        }
    }
    if ($HasControllerSignature) { [void]$Names.Add("candidate.receipt.p7s") }
    return [string[]]@($Names.ToArray() | Sort-Object)
}

function Remove-OwnedGeneration([object]$Layout, [string]$IntentSha256, [bool]$HasCanary,
    [bool]$HasControllerSignature) {
    if (-not (Test-Digest $IntentSha256)) { throw "invalid_generation_remove_target" }
    $Path = $Layout.Generations + "\" + $IntentSha256
    if (-not [IO.Directory]::Exists($Path)) { return }
    Assert-NoReparseAncestors $Path $Layout.U6Root
    if (@([IO.Directory]::EnumerateDirectories($Path)).Count -ne 0) { throw "unknown_generation_artifact" }
    $Observed = [string[]]@([IO.Directory]::EnumerateFiles($Path) |
        ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
    $Allowed = Get-GenerationExpectedNames $true $true
    foreach ($Name in $Observed) {
        if ($Name -cnotin $Allowed) { throw "unknown_generation_artifact" }
    }
    [IO.Directory]::Delete($Path, $true)
}

function Get-DrainBytes([object]$Transaction) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-drain|1", "transaction-id|$($Transaction.Id)",
        "operation|$($Transaction.Operation)", "intent-sha256|$($Transaction.IntentSha256)",
        "new-submissions|denied", "result-reads|retained", "end-drain|"
    )
}

function Restore-PreSnapshotActivation([object]$Context, [object]$Transaction) {
    Close-ManagedFirewall $Context.Layout
    Set-RequestAccountEnabled $Context.Layout $false
    $ObservedFirewall = Get-ManagedFirewallObservation $Context.Layout
    if ($ObservedFirewall.Present -ne $Transaction.PriorFirewallPresent -or
        ($ObservedFirewall.Present -and
            $ObservedFirewall.RemoteAddresses -cne $Transaction.PriorFirewallAddresses)) {
        throw "rollback_firewall_snapshot_drift"
    }
    $DrainPath = $Context.Layout.U6State + "\drain"
    if ([IO.File]::Exists($DrainPath)) { [IO.File]::Delete($DrainPath) }
    if ($Transaction.PriorAccountEnabled) { Set-RequestAccountEnabled $Context.Layout $true }
    if ($Transaction.PriorFirewallEnabled) {
        if (-not $Transaction.PriorFirewallPresent -or -not $Transaction.PriorAccountEnabled) {
            throw "rollback_activation_order_invalid"
        }
        $Rule = Get-ManagedFirewallRule $Context.Layout
        NetSecurity\Set-NetFirewallRule -InputObject $Rule -Enabled True -ErrorAction Stop | Out-Null
        $RestoredFirewall = Get-ManagedFirewallObservation $Context.Layout
        if (-not $RestoredFirewall.Enabled) { throw "rollback_firewall_restore_failed" }
    }
}

function Restore-EnrollmentSnapshot([object]$Context, [object]$Transaction, [string]$RollbackRoot) {
    Close-ManagedFirewall $Context.Layout
    Set-RequestAccountEnabled $Context.Layout $false
    $SnapshotBytes = Assert-ProtectedFile ($RollbackRoot + "\snapshot") $Context.Layout.U6Root `
        $Context.ProtectedFileSddl 8192 $Context.Layout "rollback_snapshot"
    $Snapshot = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $SnapshotBytes 8192 "rollback_snapshot") @(
        "transaction-id", "sshd-config-sha256", "sshd-config-sddl-base64", "prior-active-sha256",
        "public-readiness-sha256", "public-candidate-sha256", "public-candidate-signature-sha256",
        "u3-trust-directory-present", "u3-host-identity-sha256", "u3-allowed-signers-sha256",
        "u3-revoked-krl-sha256", "u3-fleet-ca-sha256") `
        "windows-sftp-rollback-snapshot|1" "end-snapshot|" "rollback_snapshot"
    if ($Snapshot.'transaction-id' -cne $Transaction.Id -or
        $Snapshot.'sshd-config-sha256' -cne $Transaction.ConfigurationBeforeSha256 -or
        $Snapshot.'prior-active-sha256' -cne $Transaction.PriorActiveSha256) {
        throw "rollback_snapshot_binding_drift"
    }
    foreach ($Name in @("public-readiness-sha256", "public-candidate-sha256",
            "public-candidate-signature-sha256")) {
        if ($Snapshot[$Name] -cne "-" -and -not (Test-Digest $Snapshot[$Name])) {
            throw "rollback_snapshot_binding_drift"
        }
    }
    $PriorConfig = Assert-ProtectedFile ($RollbackRoot + "\sshd-config.data") $Context.Layout.U6Root `
        $Context.ProtectedFileSddl 4194304 $Context.Layout "rollback_sshd_config"
    if ((Get-Sha256Bytes $PriorConfig) -cne $Transaction.ConfigurationBeforeSha256) {
        throw "rollback_configuration_drift"
    }
    $CurrentConfig = Read-HeldBytes $Context.Layout.SshdConfig 4194304
    $CurrentDigest = Get-Sha256Bytes $CurrentConfig
    if ($CurrentDigest -cne $Transaction.ConfigurationBeforeSha256) {
        if ($CurrentDigest -cne $Transaction.ConfigurationAfterSha256) { throw "rollback_concurrent_sshd_drift" }
        Write-SshdConfiguration $Context $PriorConfig $CurrentDigest
    }
    $Syntax = Invoke-CleanNative $Context.Layout.Sshd @("-t", "-f", $Context.Layout.SshdConfig) `
        $Context.Layout 30 1048576
    if ($Syntax.ExitCode -ne 0) { throw "rollback_sshd_configuration_invalid" }
    Set-SshdServiceStartMode $Context.Layout $Transaction.PriorServiceStart $Transaction.PriorServiceDelayed
    $PriorRunning = $Transaction.PriorServiceStatus -ceq "Running"
    Set-SshdServiceRunning $PriorRunning
    Remove-ManagedFirewall $Context.Layout
    if ($Transaction.PriorFirewallPresent) {
        if ($Transaction.PriorFirewallAddresses -ceq "-") { throw "rollback_firewall_snapshot_invalid" }
        $PriorIntent = [pscustomobject]@{ Fields = @{ "management-cidrs" = $Transaction.PriorFirewallAddresses } }
        Install-ManagedFirewall $Context.Layout $PriorIntent $false
    }
    $ActivePath = $Context.Layout.ActivePointer
    if ($Transaction.PriorActiveSha256 -ceq "-") {
        if ([IO.File]::Exists($ActivePath)) { [IO.File]::Delete($ActivePath) }
    } else {
        $PriorActive = Assert-ProtectedFile ($RollbackRoot + "\active.data") $Context.Layout.U6Root `
            $Context.ProtectedFileSddl 8192 $Context.Layout "rollback_active"
        if ((Get-Sha256Bytes $PriorActive) -cne $Transaction.PriorActiveSha256) {
            throw "rollback_active_drift"
        }
        Write-AtomicProtectedBytes $ActivePath $PriorActive $Context.ProtectedFileSddl `
            $Context.Layout $Context.Layout.U6Root
    }
    $Public = Get-PublicSddl
    foreach ($Binding in @(
            @("readiness", "public-readiness-sha256"),
            @("candidate.receipt", "public-candidate-sha256"),
            @("candidate.receipt.p7s", "public-candidate-signature-sha256"))) {
        $PublicPath = $Context.Layout.PublicRoot + "\" + $Binding[0]
        if ($Snapshot[$Binding[1]] -ceq "-") {
            if ([IO.File]::Exists($PublicPath)) {
                [void](Assert-ProtectedFile $PublicPath $Context.Layout.PublicRoot $Public.File `
                    $script:MaximumReceiptBytes $Context.Layout "rollback_public_target")
                [IO.File]::Delete($PublicPath)
            }
        } else {
            $Saved = Assert-ProtectedFile ($RollbackRoot + "\public-" + $Binding[0] + ".data") `
                $Context.Layout.U6Root $Context.ProtectedFileSddl $script:MaximumReceiptBytes `
                $Context.Layout "rollback_public_file"
            if ((Get-Sha256Bytes $Saved) -cne $Snapshot[$Binding[1]]) { throw "rollback_public_drift" }
            Write-AtomicProtectedBytes $PublicPath $Saved $Public.File $Context.Layout $Context.Layout.PublicRoot
        }
    }
    Restore-U3PublicationSnapshot $Context $Snapshot $RollbackRoot
    Remove-OwnedGeneration $Context.Layout $Transaction.IntentSha256 $true $true
    $DrainPath = $Context.Layout.U6State + "\drain"
    if ([IO.File]::Exists($DrainPath)) { [IO.File]::Delete($DrainPath) }
    if ($Transaction.PriorAccountEnabled) { Set-RequestAccountEnabled $Context.Layout $true }
    if ($Transaction.PriorFirewallPresent -and $Transaction.PriorFirewallEnabled) {
        if (-not $Transaction.PriorAccountEnabled) { throw "rollback_activation_order_invalid" }
        $Rule = Get-ManagedFirewallRule $Context.Layout
        NetSecurity\Set-NetFirewallRule -InputObject $Rule -Enabled True -ErrorAction Stop | Out-Null
    }
}

function Invoke-EnrollmentTransaction([object]$Context, [string]$Operation, [byte[]]$PriorActiveBytes) {
    if ($Confirmation -cne $Context.CandidateReceiptSha256) { throw "owner_confirmation_mismatch" }
    Initialize-U6Storage $Context
    $Lock = Acquire-LifecycleLock $Context
    $Transaction = $null; $RollbackRoot = $null
    $ContainmentStarted = $false; $U3Lease = $null
    try {
        if ((Get-Sha256Bytes (Read-HeldBytes $Context.Layout.SshdConfig 4194304)) -cne
            (Get-Sha256Bytes $Context.ExistingConfig)) { throw "enrollment_precondition_drift" }
        $ExpectedInitialState = if ([bool]$Context.U3.Account.Enabled) { "enabled" } else { "disabled" }
        [void](Assert-RequestAccount $Context.Layout $Context.Intent.Fields.'request-sid' $ExpectedInitialState)
        $PriorAccountEnabled = [bool]$Context.U3.Account.Enabled
        $PriorFirewall = Get-ManagedFirewallObservation $Context.Layout
        $PriorService = Get-SshdServiceSnapshot $Context.Layout
        if ($PriorService.Status -cnotin @("Running", "Stopped")) {
            throw "openssh_service_transition_in_progress"
        }
        $CurrentSystemTask = Get-U3TaskSnapshot $script:SystemTaskName
        $CurrentProfileTask = Get-U3TaskSnapshot $script:ProfileTaskName
        if ($CurrentSystemTask.XmlSha256 -cne $Context.Intent.Fields.'u3-system-task-xml-sha256' -or
            $CurrentProfileTask.XmlSha256 -cne $Context.Intent.Fields.'u3-profile-task-xml-sha256' -or
            -not $CurrentSystemTask.Enabled -or -not $CurrentProfileTask.Enabled) {
            throw "u3_task_precondition_drift"
        }
        $Context.U3.SystemTask = $CurrentSystemTask
        $Context.U3.ProfileTask = $CurrentProfileTask
        $TransactionPath = $Context.Layout.U6State + "\lifecycle.transaction"
        if ([IO.File]::Exists($TransactionPath)) {
            $ExistingBytes = Assert-ProtectedFile $TransactionPath $Context.Layout.U6Root `
                $Context.ProtectedFileSddl 8192 $Context.Layout "lifecycle_transaction"
            $Existing = Read-Transaction $ExistingBytes
            if ($Existing.phase -cnotin @("committed", "rolled-back")) { throw "lifecycle_recovery_required" }
            [IO.File]::Delete($TransactionPath)
        }
        $Transaction = New-Transaction $Context $Operation $PriorFirewall $PriorService `
            $PriorAccountEnabled $PriorActiveBytes
        Write-Transaction $Context $Transaction
        $ContainmentStarted = $true
        Close-ManagedFirewall $Context.Layout
        Set-RequestAccountEnabled $Context.Layout $false
        Write-AtomicProtectedBytes ($Context.Layout.U6State + "\drain") (Get-DrainBytes $Transaction) `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        $RollbackRoot = Save-RollbackSnapshot $Context $Transaction
        if ($null -ne $PriorActiveBytes) {
            $PriorActive = Read-ActiveRecord $PriorActiveBytes
            $Public = Get-PublicSddl
            Write-AtomicProtectedBytes ($Context.Layout.PublicRoot + "\readiness") `
                (Get-ReadinessBytes "draining" "transport_repair_in_progress" $PriorActive) `
                $Public.File $Context.Layout $Context.Layout.PublicRoot
        }
        $U3Lease = Enter-U3Containment $Context $Transaction
        [void](Stage-TransportGeneration $Context)
        Set-TransactionPhase $Context $Transaction "staged"
        Install-ManagedFirewall $Context.Layout $Context.Intent $false
        Set-SshdServiceAutomatic $Context.Layout
        Write-SshdConfiguration $Context $Context.CandidateConfig $Transaction.ConfigurationBeforeSha256
        Assert-SshdConfiguration $Context.Layout $Context $Context.Layout.SshdConfig
        Set-TransactionPhase $Context $Transaction "configured"
        Restart-SshdService
        Assert-SshdConfiguration $Context.Layout $Context $Context.Layout.SshdConfig
        Assert-SshdServiceReady $Context.Layout
        Assert-ManagedFirewall $Context $false
        Set-TransactionPhase $Context $Transaction "restarted"

        # The authenticated native canary proves the staged endpoint while both activation gates
        # remain closed. Its signed evidence includes the preactivation-account-disabled gate.
        $Canary = Wait-NativeCanary $Context
        [void](Assert-RequestAccount $Context.Layout $Context.Intent.Fields.'request-sid' "disabled")
        Assert-ManagedFirewall $Context $false
        Set-TransactionPhase $Context $Transaction "canary"
        Save-NativeCanary $Context $Canary
        Assert-CurrentCandidateMutationAuthority $Context "disabled"
        Publish-U3Trust $Context
        Assert-U3PublishedTrust $Context
        $ActiveBytes = Get-ActiveRecordBytes "awaiting-controller-signature" $Context `
            (Get-Sha256Bytes $Canary.ReceiptBytes) (Get-Sha256Bytes $Canary.SignatureBytes) `
            (Get-Sha256Bytes $Canary.EvidenceBytes)
        Assert-CurrentCandidateMutationAuthority $Context "disabled"
        Write-AtomicProtectedBytes $Context.Layout.ActivePointer $ActiveBytes $Context.ProtectedFileSddl `
            $Context.Layout $Context.Layout.U6Root
        Assert-CurrentCandidateMutationAuthority $Context "disabled"
        Set-RequestAccountEnabled $Context.Layout $true
        Set-TransactionPhase $Context $Transaction "activated"
        Assert-CurrentCandidateMutationAuthority $Context "enabled"
        Enable-ManagedFirewall $Context
        Assert-RequestAccount $Context.Layout $Context.Intent.Fields.'request-sid' "enabled" | Out-Null
        Assert-ManagedFirewall $Context $true
        Assert-SshdServiceReady $Context.Layout
        Assert-SshdConfiguration $Context.Layout $Context $Context.Layout.SshdConfig
        Exit-U3Containment $Context $U3Lease
        $U3Lease = $null
        [void](Assert-U3State $Context.Layout $Context.Intent "enabled")
        Assert-U3PublishedTrust $Context
        if ([IO.File]::Exists($Context.Layout.U6State + "\drain")) {
            [IO.File]::Delete($Context.Layout.U6State + "\drain")
        }
        Set-TransactionPhase $Context $Transaction "committed"
        Publish-Readiness $Context $ActiveBytes $Context.CandidateReceiptBytes `
            "awaiting-controller-signature" "candidate_receipt_requires_controller_signature"
        return $ActiveBytes
    } catch {
        $Original = $_
        if (-not $ContainmentStarted) { throw $Original }
        try {
            Close-ManagedFirewall $Context.Layout
            Set-RequestAccountEnabled $Context.Layout $false
            if ($null -ne $Transaction -and $Transaction.SnapshotComplete -and $null -ne $RollbackRoot) {
                if ($null -eq $U3Lease) { $U3Lease = Enter-U3Containment $Context $Transaction }
                Restore-EnrollmentSnapshot $Context $Transaction $RollbackRoot
                Exit-U3Containment $Context $U3Lease
                $U3Lease = $null
                Set-TransactionPhase $Context $Transaction "rolled-back"
            } elseif ($null -ne $Transaction) {
                Restore-PreSnapshotActivation $Context $Transaction
                Set-TransactionPhase $Context $Transaction "rolled-back"
            }
        } catch {
            try { Close-ManagedFirewall $Context.Layout; Set-RequestAccountEnabled $Context.Layout $false } catch { }
            throw "enrollment_failed_and_contained_rollback_drifted: $($Original.Exception.Message); $($_.Exception.Message)"
        }
        throw $Original
    } finally {
        if ($null -ne $U3Lease -and $null -ne $U3Lease.Lock) { $U3Lease.Lock.Dispose() }
        $Lock.Dispose()
    }
}

function Assert-GenerationArtifactSet([object]$Layout, [string]$GenerationRoot, [bool]$Ready,
    [bool]$AllowPendingControllerSignature = $false) {
    Assert-NoReparseAncestors $GenerationRoot $Layout.U6Root
    if (@([IO.Directory]::EnumerateDirectories($GenerationRoot)).Count -ne 0) {
        throw "unknown_generation_artifact"
    }
    $Observed = [string[]]@([IO.Directory]::EnumerateFiles($GenerationRoot) |
        ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
    $Expected = Get-GenerationExpectedNames $true $Ready
    if (($Observed -join "`n") -cne ($Expected -join "`n")) {
        $PendingExpected = Get-GenerationExpectedNames $true $true
        if (-not $AllowPendingControllerSignature -or
            ($Observed -join "`n") -cne ($PendingExpected -join "`n")) {
            throw "unknown_generation_artifact"
        }
    }
}

function Read-ActiveInstallation([object]$Layout, [string]$ExpectedAccountState = "enabled") {
    $ProtectedDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    $ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    Assert-ProtectedDirectory $Layout.U6Root $Layout.ProgramData $ProtectedDirectorySddl "u6_root"
    Assert-ProtectedDirectory $Layout.U6State $Layout.U6Root $ProtectedDirectorySddl "u6_state"
    Assert-ProtectedDirectory $Layout.Generations $Layout.U6Root $ProtectedDirectorySddl "u6_generations"
    $ActiveBytes = Assert-ProtectedFile $Layout.ActivePointer $Layout.U6Root $ProtectedFileSddl `
        8192 $Layout "active_enrollment"
    $Active = Read-ActiveRecord $ActiveBytes
    if ($Active.host -cne [Environment]::MachineName.ToUpperInvariant()) { throw "active_host_drift" }
    $GenerationRoot = $Layout.Generations + "\" + $Active.'intent-sha256'
    Assert-ProtectedDirectory $GenerationRoot $Layout.U6Root $ProtectedDirectorySddl "active_generation"
    $Ready = $Active.state -ceq "ready"
    Assert-GenerationArtifactSet $Layout $GenerationRoot $Ready (-not $Ready)
    $Read = {
        param([string]$Name, [int64]$Maximum)
        return Assert-ProtectedFile ($GenerationRoot + "\" + $Name) $Layout.U6Root $ProtectedFileSddl `
            $Maximum $Layout "active_generation_file"
    }
    $IntentBytes = & $Read "controller.intent" $script:MaximumIntentBytes
    $IntentSignature = & $Read "controller.intent.p7s" 65536
    $Intent = Read-ControllerIntent $IntentBytes ""
    if ($Intent.Sha256 -cne $Active.'intent-sha256' -or
        (Get-Sha256Bytes $IntentSignature) -cne $Active.'intent-signature-sha256' -or
        $Intent.Fields.host -cne $Active.host -or $Intent.Fields.'request-sid' -cne $Active.'request-sid' -or
        -not (Test-DetachedCmsSignature $IntentBytes $IntentSignature `
            $Active.'controller-signing-thumbprint' $Intent.IssuedAt $Intent.ExpiresAt)) {
        throw "active_intent_drift"
    }
    $CandidateBytes = & $Read "candidate.receipt" $script:MaximumReceiptBytes
    if ((Get-Sha256Bytes $CandidateBytes) -cne $Active.'candidate-sha256') { throw "active_candidate_drift" }
    $CaBytes = & $Read "fleet-ca.pub" $script:MaximumCaBytes
    $KrlBytes = & $Read "revoked.krl" $script:MaximumKrlBytes
    if ((Get-Sha256Bytes $CaBytes) -cne $Intent.Fields.'ca-public-sha256' -or
        (Get-Sha256Bytes $KrlBytes) -cne $Intent.Fields.'krl-sha256') { throw "active_trust_drift" }
    $ObservedFingerprints = [string[]]@(Get-SshFingerprints ($GenerationRoot + "\fleet-ca.pub") $Layout | Sort-Object)
    $ExpectedFingerprints = [Collections.Generic.List[string]]::new()
    [void]$ExpectedFingerprints.Add($Intent.Fields.'primary-ca-fingerprint')
    if ($Intent.Fields.'trust-mode' -ceq "dual") {
        [void]$ExpectedFingerprints.Add($Intent.Fields.'previous-ca-fingerprint')
    }
    if (($ObservedFingerprints -join "`n") -cne
        (([string[]]@($ExpectedFingerprints.ToArray() | Sort-Object)) -join "`n")) {
        throw "active_ca_fingerprint_drift"
    }
    $KrlCheck = Invoke-CleanNative $Layout.SshKeygen @(
        "-Q", "-f", ($GenerationRoot + "\revoked.krl"), ($GenerationRoot + "\fleet-ca.pub")) `
        $Layout 30 65536
    if ($KrlCheck.ExitCode -notin @(0, 1)) { throw "active_krl_drift" }
    $PrincipalBytes = & $Read "authorized-principals" 1024
    if ($script:Ascii.GetString($PrincipalBytes) -cne ($script:EndpointPrincipal + "`n")) {
        throw "active_principal_drift"
    }
    $FirewallBytes = & $Read "firewall.contract" 8192
    $FirewallSha256 = Get-Sha256Bytes $FirewallBytes
    if ($FirewallSha256 -cne $Active.'firewall-contract-sha256' -or
        $FirewallSha256 -cne (Get-Sha256Bytes (Get-FirewallContractBytes $Intent))) {
        throw "active_firewall_contract_drift"
    }
    $ManagedLines = Get-ManagedSshdBlock $GenerationRoot
    $BlockBytes = & $Read "sshd.block" 8192
    if ((Get-Sha256Bytes $BlockBytes) -cne (Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $ManagedLines))) {
        throw "active_sshd_block_drift"
    }
    $CanaryBytes = & $Read "native-canary.receipt" 32768
    $CanarySignature = & $Read "native-canary.receipt.p7s" 65536
    $CanaryEvidence = & $Read "native-canary.evidence" 1048576
    if ((Get-Sha256Bytes $CanaryBytes) -cne $Active.'canary-receipt-sha256' -or
        (Get-Sha256Bytes $CanarySignature) -cne $Active.'canary-signature-sha256' -or
        (Get-Sha256Bytes $CanaryEvidence) -cne $Active.'canary-evidence-sha256') {
        throw "active_canary_drift"
    }
    $Context = [pscustomobject]@{
        Layout = $Layout; Bootstrap = [ordered]@{
            "controller-signing-thumbprint" = $Active.'controller-signing-thumbprint'
            "native-canary-signing-thumbprint" = $Active.'native-canary-signing-thumbprint'
            "publisher-thumbprint" = "-"; "protected-copy-sha256" = "-"
        }
        Intent = $Intent; IntentBytes = $IntentBytes; IntentSignatureBytes = $IntentSignature
        GenerationRoot = $GenerationRoot; ManagedLines = $ManagedLines
        ConfigurationSha256 = $Active.'configuration-sha256'; FirewallSha256 = $FirewallSha256
        HostKeyFingerprint = $Active.'host-key-fingerprint'; CandidateReceiptBytes = $CandidateBytes
        CandidateReceiptSha256 = $Active.'candidate-sha256'; ProtectedDirectorySddl = $ProtectedDirectorySddl
        ProtectedFileSddl = $ProtectedFileSddl; Active = $Active; ActiveBytes = $ActiveBytes
        ExistingConfig = Read-HeldBytes $Layout.SshdConfig 4194304
        Trust = [pscustomobject]@{ CaBytes = $CaBytes; KrlBytes = $KrlBytes }
    }
    [void](Read-NativeCanaryReceipt $CanaryBytes $CanarySignature $CanaryEvidence $Intent `
        $Active.'native-canary-signing-thumbprint' $Active.'configuration-sha256' $FirewallSha256 `
        $Active.'host-key-fingerprint' "" -Historical)
    if ((Get-Sha256Bytes $Context.ExistingConfig) -cne $Active.'configuration-sha256') {
        throw "active_sshd_configuration_drift"
    }
    if ((Get-HostKeyFingerprint $Layout) -cne $Active.'host-key-fingerprint') { throw "active_host_key_drift" }
    [void](Assert-U3State $Layout $Intent $ExpectedAccountState)
    Assert-U3PublishedTrust $Context
    Assert-ManagedFirewall $Context $true
    Assert-SshdServiceReady $Layout
    Assert-SshdConfiguration $Layout $Context $Layout.SshdConfig
    if ($Ready) {
        $ControllerSignature = & $Read "candidate.receipt.p7s" 65536
        if ((Get-Sha256Bytes $ControllerSignature) -cne $Active.'controller-receipt-signature-sha256' -or
            -not (Test-DetachedCmsSignature $CandidateBytes $ControllerSignature `
                $Active.'controller-signing-thumbprint' ([int64]$Active.'issued-at') ([int64]$Active.'expires-at'))) {
            throw "active_controller_signature_drift"
        }
        $Context | Add-Member -NotePropertyName ControllerSignatureBytes -NotePropertyValue $ControllerSignature
    } elseif ([IO.File]::Exists($GenerationRoot + "\candidate.receipt.p7s")) {
        $PendingSignature = & $Read "candidate.receipt.p7s" 65536
        if (-not (Test-DetachedCmsSignature $CandidateBytes $PendingSignature `
                $Active.'controller-signing-thumbprint' ([int64]$Active.'issued-at') ([int64]$Active.'expires-at'))) {
            throw "pending_controller_signature_drift"
        }
        $Context | Add-Member -NotePropertyName PendingControllerSignatureBytes -NotePropertyValue $PendingSignature
    }
    return $Context
}

function Assert-CurrentActiveMutationAuthority([object]$Context, [int64]$Now = -1) {
    if ($Now -lt 0) { $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    [int64]$IssuedAt = [int64]$Context.Active.'issued-at'
    [int64]$ExpiresAt = [int64]$Context.Active.'expires-at'
    if ($Context.Active.'intent-sha256' -cne $Context.Intent.Sha256 -or
        $Context.Active.'request-sid' -cne $Context.Intent.Fields.'request-sid' -or
        [string]$IssuedAt -cne $Context.Intent.Fields.'issued-at' -or
        [string]$ExpiresAt -cne $Context.Intent.Fields.'expires-at' -or
        $IssuedAt -gt ($Now + $script:ClockSkewSeconds) -or $ExpiresAt -le $Now -or
        $ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 3600) {
        throw "historical_candidate_mutation_forbidden"
    }
}

function Assert-ReloadedActiveContext([object]$Expected, [object]$Reloaded) {
    if (-not [IO.Path]::GetFullPath($Expected.GenerationRoot).Equals(
            [IO.Path]::GetFullPath($Reloaded.GenerationRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-FixedTimeBytesEqual $Expected.ActiveBytes $Reloaded.ActiveBytes) -or
        -not (Test-FixedTimeBytesEqual $Expected.IntentBytes $Reloaded.IntentBytes) -or
        -not (Test-FixedTimeBytesEqual $Expected.IntentSignatureBytes $Reloaded.IntentSignatureBytes) -or
        -not (Test-FixedTimeBytesEqual $Expected.CandidateReceiptBytes $Reloaded.CandidateReceiptBytes)) {
        throw "active_generation_superseded"
    }
}

function Promote-ControllerReceipt([object]$Context) {
    $Lock = Acquire-LifecycleLock $Context
    try {
        if (Test-PendingLifecycle $Context.Layout) { throw "lifecycle_recovery_required" }
        $Current = Read-ActiveInstallation $Context.Layout "enabled"
        Assert-ReloadedActiveContext $Context $Current
        Assert-CurrentActiveMutationAuthority $Current
        if ($Current.Active.state -ceq "ready") {
            Publish-Readiness $Current $Current.ActiveBytes $Current.CandidateReceiptBytes "ready" `
                "controller_signed_receipt_and_local_transport_verified" $Current.ControllerSignatureBytes
            return $Current.ActiveBytes
        }
        if ($null -ne $Current.PSObject.Properties["PendingControllerSignatureBytes"]) {
            $ProtectedReceipt = $Current.CandidateReceiptBytes
            $ProtectedSignature = $Current.PendingControllerSignatureBytes
        } else {
            $ProtectedReceipt = Assert-ProtectedFile $Current.Layout.ControllerReceipt `
                $Current.Layout.StageRoot $Current.ProtectedFileSddl $script:MaximumReceiptBytes `
                $Current.Layout "controller_receipt"
            $ProtectedSignature = Assert-ProtectedFile $Current.Layout.ControllerReceiptSignature `
                $Current.Layout.StageRoot $Current.ProtectedFileSddl 65536 $Current.Layout `
                "controller_receipt_signature"
        }
        if ((Get-Sha256Bytes $ProtectedReceipt) -cne $Current.CandidateReceiptSha256 -or
            -not (Test-FixedTimeBytesEqual $ProtectedReceipt $Current.CandidateReceiptBytes) -or
            -not (Test-DetachedCmsSignature $ProtectedReceipt $ProtectedSignature `
                $Current.Active.'controller-signing-thumbprint' ([int64]$Current.Active.'issued-at') `
                ([int64]$Current.Active.'expires-at'))) { throw "controller_receipt_signature_invalid" }
        Write-AtomicProtectedBytes ($Current.GenerationRoot + "\candidate.receipt.p7s") $ProtectedSignature `
            $Current.ProtectedFileSddl $Current.Layout $Current.Layout.U6Root
        $ReadyBytes = Get-ActiveRecordBytes "ready" $Current $Current.Active.'canary-receipt-sha256' `
            $Current.Active.'canary-signature-sha256' $Current.Active.'canary-evidence-sha256' `
            (Get-Sha256Bytes $ProtectedSignature)
        Write-AtomicProtectedBytes $Current.Layout.ActivePointer $ReadyBytes $Current.ProtectedFileSddl `
            $Current.Layout $Current.Layout.U6Root
        Publish-Readiness $Current $ReadyBytes $Current.CandidateReceiptBytes "ready" `
            "controller_signed_receipt_and_local_transport_verified" $ProtectedSignature
        return $ReadyBytes
    } finally { $Lock.Dispose() }
}

function Get-RevokeIntentBytes([object]$Context, [string]$Mode, [int64]$IssuedAt) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-revoke-intent|1", "operation|revoke", "mode|$Mode",
        "authorization|inert-until-controller-signed-and-owner-confirmed", "host|$($Context.Active.host)",
        "request-sid|$($Context.Active.'request-sid')", "active-intent-sha256|$($Context.Active.'intent-sha256')",
        "active-candidate-sha256|$($Context.Active.'candidate-sha256')",
        "configuration-sha256|$($Context.Active.'configuration-sha256')",
        "firewall-contract-sha256|$($Context.Active.'firewall-contract-sha256')",
        "host-key-fingerprint|$($Context.Active.'host-key-fingerprint')",
        "primary-ca-generation|$($Context.Intent.Fields.'primary-ca-generation')",
        "previous-ca-generation|$($Context.Intent.Fields.'previous-ca-generation')",
        "krl-generation|$($Context.Intent.Fields.'krl-generation')", "issued-at|$IssuedAt",
        "expires-at|$($IssuedAt + 3600)", "containment-order|firewall-then-account",
        "owned-removal|managed-sshd-block,ca-krl-generation,managed-firewall,active-pointer",
        "u3-objects|preserved", "end-revoke|"
    )
}

function Read-ProtectedActiveAuthorization([object]$Layout) {
    $ProtectedDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    $ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    $ActiveBytes = Assert-ProtectedFile $Layout.ActivePointer $Layout.U6Root $ProtectedFileSddl `
        8192 $Layout "active_authorization"
    $Active = Read-ActiveRecord $ActiveBytes
    $GenerationRoot = $Layout.Generations + "\" + $Active.'intent-sha256'
    Assert-ProtectedDirectory $GenerationRoot $Layout.U6Root $ProtectedDirectorySddl "active_generation"
    Assert-GenerationArtifactSet $Layout $GenerationRoot ($Active.state -ceq "ready") `
        ($Active.state -cne "ready")
    $IntentBytes = Assert-ProtectedFile ($GenerationRoot + "\controller.intent") $Layout.U6Root `
        $ProtectedFileSddl $script:MaximumIntentBytes $Layout "active_intent"
    $IntentSignature = Assert-ProtectedFile ($GenerationRoot + "\controller.intent.p7s") $Layout.U6Root `
        $ProtectedFileSddl 65536 $Layout "active_intent_signature"
    $Intent = Read-ControllerIntent $IntentBytes ""
    if ($Active.host -cne [Environment]::MachineName.ToUpperInvariant() -or
        $Intent.Sha256 -cne $Active.'intent-sha256' -or
        (Get-Sha256Bytes $IntentSignature) -cne $Active.'intent-signature-sha256' -or
        $Intent.Fields.host -cne $Active.host -or
        $Intent.Fields.'request-sid' -cne $Active.'request-sid' -or
        -not (Test-DetachedCmsSignature $IntentBytes $IntentSignature `
            $Active.'controller-signing-thumbprint' $Intent.IssuedAt $Intent.ExpiresAt)) {
        throw "active_authorization_drift"
    }
    $CandidateBytes = Assert-ProtectedFile ($GenerationRoot + "\candidate.receipt") $Layout.U6Root `
        $ProtectedFileSddl $script:MaximumReceiptBytes $Layout "active_candidate"
    if ((Get-Sha256Bytes $CandidateBytes) -cne $Active.'candidate-sha256') { throw "active_authorization_drift" }
    if ($Active.state -ceq "ready") {
        $CandidateSignature = Assert-ProtectedFile ($GenerationRoot + "\candidate.receipt.p7s") $Layout.U6Root `
            $ProtectedFileSddl 65536 $Layout "active_candidate_signature"
        if ((Get-Sha256Bytes $CandidateSignature) -cne $Active.'controller-receipt-signature-sha256' -or
            -not (Test-DetachedCmsSignature $CandidateBytes $CandidateSignature `
                $Active.'controller-signing-thumbprint' ([int64]$Active.'issued-at') ([int64]$Active.'expires-at'))) {
            throw "active_authorization_drift"
        }
    }
    return [pscustomobject]@{
        Layout = $Layout; Active = $Active; ActiveBytes = $ActiveBytes; Intent = $Intent
        IntentBytes = $IntentBytes; IntentSignatureBytes = $IntentSignature
        GenerationRoot = $GenerationRoot; ManagedLines = Get-ManagedSshdBlock $GenerationRoot
        CandidateReceiptBytes = $CandidateBytes; CandidateReceiptSha256 = $Active.'candidate-sha256'
        ConfigurationSha256 = $Active.'configuration-sha256'; FirewallSha256 = $Active.'firewall-contract-sha256'
        HostKeyFingerprint = $Active.'host-key-fingerprint'; ProtectedDirectorySddl = $ProtectedDirectorySddl
        ProtectedFileSddl = $ProtectedFileSddl
    }
}

function Read-RevokeIntent([byte[]]$Bytes, [object]$Context, [string]$ExpectedMode, [switch]$Historical) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 8192 "revoke_intent") @(
        "operation", "mode", "authorization", "host", "request-sid", "active-intent-sha256",
        "active-candidate-sha256", "configuration-sha256", "firewall-contract-sha256",
        "host-key-fingerprint", "primary-ca-generation", "previous-ca-generation", "krl-generation",
        "issued-at", "expires-at", "containment-order", "owned-removal", "u3-objects") `
        "windows-sftp-revoke-intent|1" "end-revoke|" "revoke_intent"
    if ($Fields.operation -cne "revoke" -or $Fields.mode -cne $ExpectedMode -or
        $Fields.authorization -cne "inert-until-controller-signed-and-owner-confirmed" -or
        $Fields.host -cne $Context.Active.host -or $Fields.'request-sid' -cne $Context.Active.'request-sid' -or
        $Fields.'active-intent-sha256' -cne $Context.Active.'intent-sha256' -or
        $Fields.'active-candidate-sha256' -cne $Context.Active.'candidate-sha256' -or
        $Fields.'configuration-sha256' -cne $Context.Active.'configuration-sha256' -or
        $Fields.'firewall-contract-sha256' -cne $Context.Active.'firewall-contract-sha256' -or
        $Fields.'host-key-fingerprint' -cne $Context.Active.'host-key-fingerprint' -or
        $Fields.'primary-ca-generation' -cne $Context.Intent.Fields.'primary-ca-generation' -or
        $Fields.'previous-ca-generation' -cne $Context.Intent.Fields.'previous-ca-generation' -or
        $Fields.'krl-generation' -cne $Context.Intent.Fields.'krl-generation' -or
        $Fields.'containment-order' -cne "firewall-then-account" -or
        $Fields.'owned-removal' -cne
            "managed-sshd-block,ca-krl-generation,managed-firewall,active-pointer" -or
        $Fields.'u3-objects' -cne "preserved" -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at')) {
        throw "invalid_revoke_intent"
    }
    [int64]$IssuedAt = [int64]$Fields.'issued-at'; [int64]$ExpiresAt = [int64]$Fields.'expires-at'
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($IssuedAt -gt ($Now + $script:ClockSkewSeconds) -or (-not $Historical -and $ExpiresAt -le $Now) -or
        $ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 3600) { throw "revoke_intent_expired" }
    return [pscustomobject]@{ Fields = $Fields; Bytes = $Bytes; Sha256 = Get-Sha256Bytes $Bytes
        IssuedAt = $IssuedAt; ExpiresAt = $ExpiresAt }
}

function Assert-U3ProtectedJournalsTerminal([object]$Layout) {
    $ReplayRoot = $Layout.U3State + "\replay"; $AuditRoot = $Layout.U3State + "\audit"
    if (-not [IO.Directory]::Exists($ReplayRoot)) { return }
    foreach ($ClaimRoot in @([IO.Directory]::EnumerateDirectories($ReplayRoot, "request-*"))) {
        Assert-NoReparseAncestors $ClaimRoot $Layout.U3Root
        $JournalPath = $ClaimRoot + "\journal"
        if (-not [IO.File]::Exists($JournalPath)) { throw "unresolved_protected_journal" }
        $JournalBytes = Read-HeldBytes $JournalPath 65536
        $Lines = ConvertFrom-CanonicalAsciiBytes $JournalBytes 65536 "journal"
        $States = @($Lines | Where-Object { $_ -cmatch '^state\|(validating|executing|verifying|completed|partial|rejected|stale)$' })
        if ($States.Count -ne 1 -or $States[0].Substring(6) -cnotin @("completed", "partial", "rejected", "stale")) {
            throw "unresolved_protected_journal"
        }
        $RequestId = [IO.Path]::GetFileName($ClaimRoot)
        $TerminalPath = $AuditRoot + "\" + $RequestId + ".terminal"
        $AuditPath = $AuditRoot + "\" + $RequestId + ".audit"
        $AuditReservePath = $AuditRoot + "\" + $RequestId + ".audit.reserve"
        foreach ($Path in @($TerminalPath, $AuditPath, $AuditReservePath)) {
            if (-not [IO.File]::Exists($Path)) { throw "unresolved_protected_audit" }
            Assert-NoReparseAncestors $Path $Layout.U3Root
        }
        $TerminalItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $TerminalPath -Force
        $Disallowed = [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed
        $TerminalBytes = Read-HeldBytes $TerminalPath $script:TerminalReservationBytes
        if ($TerminalBytes.Count -ne $script:TerminalReservationBytes -or
            ($TerminalItem.Attributes -band $Disallowed) -ne 0) { throw "unresolved_protected_audit" }
        for ($Index = 0; $Index -lt $JournalBytes.Count; $Index++) {
            if ($TerminalBytes[$Index] -ne $JournalBytes[$Index]) { throw "unresolved_protected_audit" }
        }
        for ($Index = $JournalBytes.Count; $Index -lt $TerminalBytes.Count; $Index++) {
            if ($TerminalBytes[$Index] -ne $script:ReservationFillByte) { throw "unresolved_protected_audit" }
        }
        [byte[]]$AuditBytes = Read-HeldBytes $AuditPath 1048576
        $AuditText = $script:Ascii.GetString($AuditBytes)
        if (-not $AuditText.Contains("journal-sha256|$(Get-Sha256Bytes $JournalBytes)`n",
                [StringComparison]::Ordinal)) { throw "unresolved_protected_audit" }
        $HeaderEnd = $AuditText.IndexOf("end-audit-header|`n", [StringComparison]::Ordinal)
        if ($HeaderEnd -lt 0) { throw "unresolved_protected_audit" }
        $HeaderEnd += "end-audit-header|`n".Length
        $ExpectedReserveLength = $script:AuditReservationBytes - ($AuditBytes.Count - $HeaderEnd)
        $ReserveItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $AuditReservePath -Force
        if ($ExpectedReserveLength -lt 0 -or $ReserveItem.Length -ne $ExpectedReserveLength -or
            ($ReserveItem.Attributes -band $Disallowed) -ne 0) { throw "unresolved_protected_audit" }
        if ($ExpectedReserveLength -gt 0) {
            foreach ($Byte in (Read-HeldBytes $AuditReservePath $script:AuditReservationBytes)) {
                if ($Byte -ne $script:ReservationFillByte) { throw "unresolved_protected_audit" }
            }
        }
    }
}

function Test-U3Quiescent([object]$Layout) {
    try {
        $Commit = [IO.File]::Open($Layout.Slot + "\commit", [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { if ($Commit.Length -ne 0) { return $false } } finally { $Commit.Dispose() }
    } catch [IO.IOException] { return $false }
    $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
    foreach ($Name in @($script:SystemTaskName, $script:ProfileTaskName)) {
        $State = [int]$Service.GetFolder("\").GetTask("\$Name").State
        if ($State -in @(2, 4)) { return $false }
    }
    try { Assert-U3ProtectedJournalsTerminal $Layout; return $true } catch { return $false }
}

function Wait-U3Quiescent([object]$Layout) {
    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($script:DrainTimeoutSeconds)
    while (-not (Test-U3Quiescent $Layout)) {
        if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw "revocation_drain_timeout" }
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds 1
    }
    Assert-U3ProtectedJournalsTerminal $Layout
}

function Get-RevokedReadinessBytes([object]$Context, [object]$RevokeIntent) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-readiness|1", "state|revoked", "reason|managed_transport_removed",
        "host|$($Context.Active.host)", "request-sid|$($Context.Active.'request-sid')",
        "intent-sha256|$($Context.Active.'intent-sha256')",
        "candidate-sha256|$($Context.Active.'candidate-sha256')",
        "host-key-fingerprint|$($Context.Active.'host-key-fingerprint')", "transport-ready|false",
        "broker-ready|observed-separately", "node-identity-ready|observed-separately",
        "action-context-ready|observed-separately", "controller-signature-ready|false",
        "readiness-authority|controller-signed-revocation-plus-local-observation",
        "revoke-intent-sha256|$($RevokeIntent.Sha256)", "end-readiness|"
    )
}

function Get-RevocationTransactionBytes([string]$Phase, [object]$Context, [object]$RevokeIntent,
    [byte[]]$RevokeSignature, [string]$ConfigurationAfterSha256, [object]$Containment) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-revocation-transaction|1", "phase|$Phase",
        "revoke-intent-sha256|$($RevokeIntent.Sha256)",
        "revoke-signature-sha256|$(Get-Sha256Bytes $RevokeSignature)",
        "active-intent-sha256|$($Context.Active.'intent-sha256')",
        "configuration-before-sha256|$($Context.Active.'configuration-sha256')",
        "configuration-after-sha256|$ConfigurationAfterSha256",
        "u3-drain-transaction-id|$($Containment.DrainTransactionId)",
        "u3-epoch|$($Containment.U3Epoch)",
        "prior-system-task-enabled|$($Containment.PriorSystemTaskEnabled.ToString().ToLowerInvariant())",
        "prior-profile-task-enabled|$($Containment.PriorProfileTaskEnabled.ToString().ToLowerInvariant())",
        "prior-system-task-xml-sha256|$($Containment.PriorSystemTaskXmlSha256)",
        "prior-profile-task-xml-sha256|$($Containment.PriorProfileTaskXmlSha256)",
        "mode|$($RevokeIntent.Fields.mode)", "end-transaction|")
}

function Read-RevocationTransaction([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "revocation_transaction") @(
        "phase", "revoke-intent-sha256", "revoke-signature-sha256", "active-intent-sha256",
        "configuration-before-sha256", "configuration-after-sha256", "u3-drain-transaction-id",
        "u3-epoch", "prior-system-task-enabled", "prior-profile-task-enabled",
        "prior-system-task-xml-sha256", "prior-profile-task-xml-sha256", "mode") `
        "windows-sftp-revocation-transaction|1" "end-transaction|" "revocation_transaction"
    if ($Fields.phase -cnotin @("contained", "drained", "configured", "finalizing", "committed") -or
        $Fields.mode -cnotin @("normal", "emergency") -or
        $Fields.'u3-drain-transaction-id' -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        -not (Test-PositiveUInt $Fields.'u3-epoch') -or
        $Fields.'prior-system-task-enabled' -cnotin @("true", "false") -or
        $Fields.'prior-profile-task-enabled' -cnotin @("true", "false")) {
        throw "invalid_revocation_transaction"
    }
    foreach ($Name in @("revoke-intent-sha256", "revoke-signature-sha256", "active-intent-sha256",
            "configuration-before-sha256", "configuration-after-sha256",
            "prior-system-task-xml-sha256", "prior-profile-task-xml-sha256")) {
        if (-not (Test-Digest $Fields[$Name])) { throw "invalid_revocation_transaction" }
    }
    return $Fields
}

function ConvertFrom-RevocationContainmentFields([object]$Fields) {
    return [pscustomobject]@{
        DrainOperation = "revoke"
        DrainTransactionId = $Fields.'u3-drain-transaction-id'
        U3Epoch = [int64]$Fields.'u3-epoch'
        PriorSystemTaskEnabled = $Fields.'prior-system-task-enabled' -ceq "true"
        PriorProfileTaskEnabled = $Fields.'prior-profile-task-enabled' -ceq "true"
        PriorSystemTaskXmlSha256 = $Fields.'prior-system-task-xml-sha256'
        PriorProfileTaskXmlSha256 = $Fields.'prior-profile-task-xml-sha256'
    }
}

function Invoke-RevokeTransaction([object]$Context, [object]$RevokeIntent, [byte[]]$RevokeSignature,
    [switch]$Resume) {
    if (-not $Resume -and $Confirmation -cne $RevokeIntent.Sha256) { throw "owner_confirmation_mismatch" }
    $Lock = Acquire-LifecycleLock $Context
    $ContainmentStarted = $false; $U3Lease = $null; $U3Containment = $null
    try {
        if (-not [IO.File]::Exists($Context.Layout.ActivePointer)) { throw "revocation_precondition_drift" }
        $ObservedActive = Assert-ProtectedFile $Context.Layout.ActivePointer $Context.Layout.U6Root `
            $Context.ProtectedFileSddl 8192 $Context.Layout "revocation_active_pointer"
        if ((Get-Sha256Bytes $ObservedActive) -cne (Get-Sha256Bytes $Context.ActiveBytes)) {
            throw "revocation_precondition_drift"
        }
        if (-not $Resume) {
            [void](Assert-RequestAccount $Context.Layout $Context.Active.'request-sid' "enabled")
        }
        $RevocationTransactionPath = $Context.Layout.U6State + "\revocation.transaction"
        $ExistingRevocation = $null
        if ($Resume) {
            if (-not [IO.File]::Exists($RevocationTransactionPath)) { throw "revocation_recovery_required" }
            $ExistingBytes = Assert-ProtectedFile $RevocationTransactionPath $Context.Layout.U6Root `
                $Context.ProtectedFileSddl 4096 $Context.Layout "revocation_transaction"
            $ExistingRevocation = Read-RevocationTransaction $ExistingBytes
            $U3Containment = ConvertFrom-RevocationContainmentFields $ExistingRevocation
        } else {
            $SystemTask = Get-U3TaskSnapshot $script:SystemTaskName
            $ProfileTask = Get-U3TaskSnapshot $script:ProfileTaskName
            if ($SystemTask.XmlSha256 -cne $Context.Intent.Fields.'u3-system-task-xml-sha256' -or
                $ProfileTask.XmlSha256 -cne $Context.Intent.Fields.'u3-profile-task-xml-sha256' -or
                -not $SystemTask.Enabled -or -not $ProfileTask.Enabled) {
                throw "u3_task_precondition_drift"
            }
            $U3Containment = [pscustomobject]@{
                DrainOperation = "revoke"
                DrainTransactionId = "transaction-" + $RevokeIntent.Sha256.Substring(0, 32)
                U3Epoch = [int64]$Context.Intent.Fields.'u3-epoch'
                PriorSystemTaskEnabled = [bool]$SystemTask.Enabled
                PriorProfileTaskEnabled = [bool]$ProfileTask.Enabled
                PriorSystemTaskXmlSha256 = $SystemTask.XmlSha256
                PriorProfileTaskXmlSha256 = $ProfileTask.XmlSha256
            }
        }
        Assert-SystemProtectedPath $Context.Layout.SshdConfig $Context.Layout.ProgramData
        $CurrentAtStart = Read-HeldBytes $Context.Layout.SshdConfig 4194304
        $CurrentAtStartSha = Get-Sha256Bytes $CurrentAtStart
        if ($CurrentAtStartSha -ceq $Context.Active.'configuration-sha256') {
            $RemovedConfig = Remove-ManagedSshdBlock $CurrentAtStart $Context.ManagedLines
        } elseif ($Resume -and
            $ExistingRevocation.'configuration-after-sha256' -ceq $CurrentAtStartSha) {
            $RemovedConfig = $CurrentAtStart
        } else { throw "revocation_sshd_configuration_drift" }
        $RemovedConfigSha = Get-Sha256Bytes $RemovedConfig
        if ($Resume -and ($ExistingRevocation.'active-intent-sha256' -cne
                $Context.Active.'intent-sha256' -or
            $ExistingRevocation.'revoke-intent-sha256' -cne $RevokeIntent.Sha256 -or
            $ExistingRevocation.'revoke-signature-sha256' -cne (Get-Sha256Bytes $RevokeSignature) -or
            $ExistingRevocation.'configuration-before-sha256' -cne
                $Context.Active.'configuration-sha256' -or
            $ExistingRevocation.'configuration-after-sha256' -cne $RemovedConfigSha -or
            $ExistingRevocation.mode -cne $RevokeIntent.Fields.mode)) {
            throw "revocation_recovery_required"
        }
        Write-AtomicProtectedBytes ($Context.Layout.U6State + "\revocation.intent") $RevokeIntent.Bytes `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        Write-AtomicProtectedBytes ($Context.Layout.U6State + "\revocation.intent.p7s") $RevokeSignature `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        Write-AtomicProtectedBytes $RevocationTransactionPath `
            (Get-RevocationTransactionBytes "contained" $Context $RevokeIntent $RevokeSignature `
                $RemovedConfigSha $U3Containment) `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        $ContainmentStarted = $true
        Close-ManagedFirewall $Context.Layout
        Set-RequestAccountEnabled $Context.Layout $false
        $DrainBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-sftp-revocation-drain|1", "revoke-intent-sha256|$($RevokeIntent.Sha256)",
            "mode|$($RevokeIntent.Fields.mode)", "new-submissions|denied", "local-status-reads|retained",
            "end-drain|")
        Write-AtomicProtectedBytes ($Context.Layout.U6State + "\drain") $DrainBytes `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        $Public = Get-PublicSddl
        Write-AtomicProtectedBytes ($Context.Layout.PublicRoot + "\readiness") `
            (Get-ReadinessBytes "draining" "transport_revocation_in_progress" $Context.Active) `
            $Public.File $Context.Layout $Context.Layout.PublicRoot
        $U3Lease = Enter-U3Containment $Context $U3Containment
        Write-AtomicProtectedBytes $RevocationTransactionPath `
            (Get-RevocationTransactionBytes "drained" $Context $RevokeIntent $RevokeSignature `
                $RemovedConfigSha $U3Containment) `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        $CurrentConfig = Read-HeldBytes $Context.Layout.SshdConfig 4194304
        if ((Get-Sha256Bytes $CurrentConfig) -cne $Context.Active.'configuration-sha256' -and
            (Get-Sha256Bytes $CurrentConfig) -cne $RemovedConfigSha) {
            throw "revocation_sshd_configuration_drift"
        }
        if ((Get-Sha256Bytes $CurrentConfig) -ceq $Context.Active.'configuration-sha256') {
            Write-SshdConfiguration $Context $RemovedConfig $Context.Active.'configuration-sha256'
        }
        $Syntax = Invoke-CleanNative $Context.Layout.Sshd @("-t", "-f", $Context.Layout.SshdConfig) `
            $Context.Layout 30 1048576
        if ($Syntax.ExitCode -ne 0) { throw "revoked_sshd_configuration_invalid" }
        Restart-SshdService
        Remove-ManagedFirewall $Context.Layout
        Write-AtomicProtectedBytes $RevocationTransactionPath `
            (Get-RevocationTransactionBytes "configured" $Context $RevokeIntent $RevokeSignature `
                $RemovedConfigSha $U3Containment) `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        $RevokedBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-sftp-revoked-enrollment|1", "host|$($Context.Active.host)",
            "request-sid|$($Context.Active.'request-sid')", "active-intent-sha256|$($Context.Active.'intent-sha256')",
            "revoke-intent-sha256|$($RevokeIntent.Sha256)",
            "revoke-signature-sha256|$(Get-Sha256Bytes $RevokeSignature)",
            "mode|$($RevokeIntent.Fields.mode)", "account-state|disabled", "firewall-state|absent",
            "u3-objects|preserved", "end-revoked|")
        Write-AtomicProtectedBytes ($Context.Layout.U6State + "\revoked") $RevokedBytes `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        Write-AtomicProtectedBytes ($Context.Layout.PublicRoot + "\readiness") `
            (Get-RevokedReadinessBytes $Context $RevokeIntent) $Public.File $Context.Layout `
            $Context.Layout.PublicRoot
        Write-AtomicProtectedBytes $RevocationTransactionPath `
            (Get-RevocationTransactionBytes "finalizing" $Context $RevokeIntent $RevokeSignature `
                $RemovedConfigSha $U3Containment) `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
        $FinalActive = Assert-ProtectedFile $Context.Layout.ActivePointer $Context.Layout.U6Root `
            $Context.ProtectedFileSddl 8192 $Context.Layout "revocation_active_pointer"
        if ((Get-Sha256Bytes $FinalActive) -cne (Get-Sha256Bytes $Context.ActiveBytes)) {
            throw "revocation_precondition_drift"
        }
        [IO.File]::Delete($Context.Layout.ActivePointer)
        Remove-OwnedGeneration $Context.Layout $Context.Active.'intent-sha256' $true `
            ($Context.Active.state -ceq "ready")
        Exit-U3Containment $Context $U3Lease
        $U3Lease = $null
        if ([IO.File]::Exists($Context.Layout.U6State + "\drain")) {
            [IO.File]::Delete($Context.Layout.U6State + "\drain")
        }
        Write-AtomicProtectedBytes $RevocationTransactionPath `
            (Get-RevocationTransactionBytes "committed" $Context $RevokeIntent $RevokeSignature `
                $RemovedConfigSha $U3Containment) `
            $Context.ProtectedFileSddl $Context.Layout $Context.Layout.U6Root
    } catch {
        if ($ContainmentStarted) {
            try { Close-ManagedFirewall $Context.Layout; Set-RequestAccountEnabled $Context.Layout $false } catch { }
        }
        throw
    } finally {
        if ($null -ne $U3Lease -and $null -ne $U3Lease.Lock) { $U3Lease.Lock.Dispose() }
        $Lock.Dispose()
    }
}

function ConvertFrom-TransactionFields([object]$Fields) {
    return [pscustomobject]@{
        Id = $Fields.'transaction-id'; Operation = $Fields.operation; Phase = $Fields.phase
        IntentSha256 = $Fields.'intent-sha256'; CandidateSha256 = $Fields.'candidate-sha256'
        ConfigurationBeforeSha256 = $Fields.'configuration-before-sha256'
        ConfigurationAfterSha256 = $Fields.'configuration-after-sha256'
        DrainOperation = $Fields.'u3-drain-operation'
        DrainTransactionId = $Fields.'u3-drain-transaction-id'
        U3Epoch = [int64]$Fields.'u3-epoch'
        PriorSystemTaskEnabled = $Fields.'prior-system-task-enabled' -ceq "true"
        PriorProfileTaskEnabled = $Fields.'prior-profile-task-enabled' -ceq "true"
        PriorSystemTaskXmlSha256 = $Fields.'prior-system-task-xml-sha256'
        PriorProfileTaskXmlSha256 = $Fields.'prior-profile-task-xml-sha256'
        PriorAccountEnabled = $Fields.'prior-account-enabled' -ceq "true"
        PriorFirewallPresent = $Fields.'prior-firewall-present' -ceq "true"
        PriorFirewallEnabled = $Fields.'prior-firewall-enabled' -ceq "true"
        PriorFirewallAddresses = $Fields.'prior-firewall-addresses'
        PriorServiceStart = [int]$Fields.'prior-service-start'
        PriorServiceDelayed = [int]$Fields.'prior-service-delayed'
        PriorServiceStatus = $Fields.'prior-service-status'
        PriorActiveSha256 = $Fields.'prior-active-sha256'
        SnapshotComplete = $Fields.'snapshot-complete' -ceq "true"
    }
}

function Resolve-StaleEnrollmentTransaction([object]$Layout) {
    $TransactionPath = $Layout.U6State + "\lifecycle.transaction"
    if (-not [IO.File]::Exists($TransactionPath)) { return }
    $ProtectedDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    $ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    $LockPath = $Layout.U6State + "\lifecycle.lock"
    if (-not [IO.File]::Exists($LockPath)) { throw "lifecycle_recovery_required" }
    $LockContext = [pscustomobject]@{
        Layout = $Layout; ProtectedDirectorySddl = $ProtectedDirectorySddl
        ProtectedFileSddl = $ProtectedFileSddl
    }
    $Lock = Acquire-LifecycleLock $LockContext
    $U3Lease = $null
    try {
        $Fields = Read-Transaction (Assert-ProtectedFile $TransactionPath $Layout.U6Root $ProtectedFileSddl `
            8192 $Layout "stale_transaction")
        if ($Fields.phase -cin @("committed", "rolled-back")) { return }
        Close-ManagedFirewall $Layout
        Set-RequestAccountEnabled $Layout $false
        $Transaction = ConvertFrom-TransactionFields $Fields
        $Context = [pscustomobject]@{
            Layout = $Layout; ProtectedDirectorySddl = $ProtectedDirectorySddl
            ProtectedFileSddl = $ProtectedFileSddl
            GenerationRoot = $Layout.Generations + "\" + $Fields.'intent-sha256'
            ExistingConfig = [byte[]]@()
        }
        if ($Fields.'snapshot-complete' -cne "true") {
            Restore-PreSnapshotActivation $Context $Transaction
            Set-TransactionPhase $Context $Transaction "rolled-back"
            return
        }
        $U3Lease = Enter-U3Containment $Context $Transaction
        Restore-EnrollmentSnapshot $Context $Transaction ($Layout.U6State + "\rollback-" + $Transaction.Id)
        Exit-U3Containment $Context $U3Lease
        $U3Lease = $null
        Set-TransactionPhase $Context $Transaction "rolled-back"
    } catch {
        try { Close-ManagedFirewall $Layout; Set-RequestAccountEnabled $Layout $false } catch { }
        throw "lifecycle_recovery_required: $($_.Exception.Message)"
    } finally {
        if ($null -ne $U3Lease -and $null -ne $U3Lease.Lock) { $U3Lease.Lock.Dispose() }
        $Lock.Dispose()
    }
}

function Get-RevocationTransactionBytesFromFields([object]$Fields, [string]$Phase) {
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-revocation-transaction|1", "phase|$Phase",
        "revoke-intent-sha256|$($Fields.'revoke-intent-sha256')",
        "revoke-signature-sha256|$($Fields.'revoke-signature-sha256')",
        "active-intent-sha256|$($Fields.'active-intent-sha256')",
        "configuration-before-sha256|$($Fields.'configuration-before-sha256')",
        "configuration-after-sha256|$($Fields.'configuration-after-sha256')",
        "u3-drain-transaction-id|$($Fields.'u3-drain-transaction-id')",
        "u3-epoch|$($Fields.'u3-epoch')",
        "prior-system-task-enabled|$($Fields.'prior-system-task-enabled')",
        "prior-profile-task-enabled|$($Fields.'prior-profile-task-enabled')",
        "prior-system-task-xml-sha256|$($Fields.'prior-system-task-xml-sha256')",
        "prior-profile-task-xml-sha256|$($Fields.'prior-profile-task-xml-sha256')",
        "mode|$($Fields.mode)", "end-transaction|")
}

function Resolve-StaleRevocation([object]$Layout) {
    $Path = $Layout.U6State + "\revocation.transaction"
    if (-not [IO.File]::Exists($Path)) { return }
    $ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
    $Fields = Read-RevocationTransaction (Assert-ProtectedFile $Path $Layout.U6Root $ProtectedFileSddl `
        4096 $Layout "revocation_transaction")
    if ($Fields.phase -ceq "committed") { return }
    if ($Fields.phase -ceq "finalizing") {
        $LockContext = [pscustomobject]@{
            Layout = $Layout
            ProtectedDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
            ProtectedFileSddl = $ProtectedFileSddl
        }
        $Lock = Acquire-LifecycleLock $LockContext
        $U3Lease = $null
        try {
            Close-ManagedFirewall $Layout
            Set-RequestAccountEnabled $Layout $false
            $U3Lease = Enter-U3Containment $LockContext `
                (ConvertFrom-RevocationContainmentFields $Fields)
            [void](Assert-ProtectedFile ($Layout.U6State + "\revoked") $Layout.U6Root `
                $ProtectedFileSddl 4096 $Layout "revoked_enrollment")
            if ([IO.File]::Exists($Layout.ActivePointer)) {
                $ActiveBytes = Assert-ProtectedFile $Layout.ActivePointer $Layout.U6Root `
                    $ProtectedFileSddl 8192 $Layout "revocation_active_pointer"
                $Active = Read-ActiveRecord $ActiveBytes
                if ($Active.'intent-sha256' -cne $Fields.'active-intent-sha256') {
                    throw "revocation_recovery_required"
                }
                [IO.File]::Delete($Layout.ActivePointer)
            }
            Remove-OwnedGeneration $Layout $Fields.'active-intent-sha256' $true $true
            Exit-U3Containment $LockContext $U3Lease
            $U3Lease = $null
            if ([IO.File]::Exists($Layout.U6State + "\drain")) { [IO.File]::Delete($Layout.U6State + "\drain") }
            Write-AtomicProtectedBytes $Path (Get-RevocationTransactionBytesFromFields $Fields "committed") `
                $ProtectedFileSddl $Layout $Layout.U6Root
        } finally {
            if ($null -ne $U3Lease -and $null -ne $U3Lease.Lock) { $U3Lease.Lock.Dispose() }
            $Lock.Dispose()
        }
        return
    }
    Close-ManagedFirewall $Layout
    Set-RequestAccountEnabled $Layout $false
    $Context = Read-ProtectedActiveAuthorization $Layout
    $IntentBytes = Assert-ProtectedFile ($Layout.U6State + "\revocation.intent") $Layout.U6Root `
        $ProtectedFileSddl 8192 $Layout "stored_revoke_intent"
    $SignatureBytes = Assert-ProtectedFile ($Layout.U6State + "\revocation.intent.p7s") $Layout.U6Root `
        $ProtectedFileSddl 65536 $Layout "stored_revoke_signature"
    $RevokeIntent = Read-RevokeIntent $IntentBytes $Context $Fields.mode -Historical
    if ($RevokeIntent.Sha256 -cne $Fields.'revoke-intent-sha256' -or
        (Get-Sha256Bytes $SignatureBytes) -cne $Fields.'revoke-signature-sha256' -or
        -not (Test-DetachedCmsSignature $IntentBytes $SignatureBytes `
            $Context.Active.'controller-signing-thumbprint' $RevokeIntent.IssuedAt $RevokeIntent.ExpiresAt)) {
        throw "revocation_recovery_required"
    }
    Invoke-RevokeTransaction $Context $RevokeIntent $SignatureBytes -Resume
}

function Assert-Fixture([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "self_test_failed_$Label" }
}

function Assert-FixtureThrows([scriptblock]$Action, [string]$Label) {
    $Threw = $false
    try { & $Action } catch { $Threw = $true }
    if (-not $Threw) { throw "self_test_failed_$Label" }
}

function New-FixtureIntent([int64]$IssuedAt) {
    $RequestSid = "S-1-5-21-1-2-3-1001"
    $Contracts = Get-U3ContractDigests $RequestSid
    $Fields = [ordered]@{
        "schema-version" = "1"; "operation" = "install"; "host" = "FIXTURE-HOST"
        "fleet-domain" = "example.invalid"; "request-account" = $script:RequestAccountName
        "request-sid" = $RequestSid; "endpoint-principal" = $script:EndpointPrincipal
        "trust-mode" = "single"; "primary-ca-fingerprint" = ("SHA256:" + ("A" * 43))
        "primary-ca-generation" = "7"; "previous-ca-fingerprint" = "-"; "previous-ca-generation" = "0"
        "ca-public-sha256" = ("a" * 64); "krl-generation" = "9"; "krl-sha256" = ("b" * 64)
        "management-cidrs" = "10.0.0.0/8,2001:db8::/32"; "u3-epoch" = "11"
        "u3-generation-sha256" = ("c" * 64); "u3-active-pointer-sha256" = ("d" * 64)
        "u3-policy-sha256" = ("e" * 64); "u3-constraints-sha256" = ("f" * 64)
        "u3-winget-context-sha256" = ("1" * 64); "u3-provider-lock-sha256" = ("2" * 64)
        "u3-broker-sha256" = ("3" * 64); "u3-native-canary-receipt-sha256" = ("4" * 64)
        "u3-native-canary-signature-sha256" = ("5" * 64); "u3-native-canary-evidence-sha256" = ("6" * 64)
        "u3-system-task-xml-sha256" = ("7" * 64); "u3-system-task-sddl-sha256" = ("8" * 64)
        "u3-profile-task-xml-sha256" = ("9" * 64); "u3-profile-task-sddl-sha256" = ("0" * 64)
        "chroot-contract-sha256" = $Contracts.Chroot; "slot-acl-sha256" = $Contracts.Slot
        "results-acl-sha256" = $Contracts.Results; "quota-contract-sha256" = $Contracts.Quota
        "openssh-contract-sha256" = $Contracts.OpenSsh; "issued-at" = [string]$IssuedAt
        "expires-at" = [string]($IssuedAt + 3600)
    }
    $Lines = [Collections.Generic.List[string]]::new(); [void]$Lines.Add("windows-sftp-controller-intent|1")
    foreach ($Name in Get-ControllerIntentFieldNames) { [void]$Lines.Add("$Name|$($Fields[$Name])") }
    [void]$Lines.Add("end-intent|")
    $Bytes = ConvertTo-CanonicalAsciiBytes $Lines.ToArray()
    return Read-ControllerIntent $Bytes "install"
}

function New-FixtureCertificate {
    $Rsa = [Security.Cryptography.RSA]::Create(2048)
    $Request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=MachineUtilities Fixture", $Rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $Request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
    return $Request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(2))
}

function New-FixtureCmsSignature([byte[]]$Bytes, [object]$Certificate) {
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
    $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
        [Security.Cryptography.Pkcs.ContentInfo]::new($Bytes), $true)
    $Signer = [Security.Cryptography.Pkcs.CmsSigner]::new(
        [Security.Cryptography.Pkcs.SubjectIdentifierType]::IssuerAndSerialNumber, $Certificate)
    $Signer.IncludeOption = [Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $Cms.ComputeSignature($Signer)
    return $Cms.Encode()
}

function New-U3FixtureRawEvidence([object]$Intent, [int64]$CapturedAt) {
    $Access = Get-U3NativeAccessContract $Intent.Fields.'request-sid'
    $Fields = [ordered]@{
        "nonce" = ("a" * 64); "host" = $Intent.Fields.host; "epoch" = $Intent.Fields.'u3-epoch'
        "generation-sha256" = $Intent.Fields.'u3-generation-sha256'; "controlled-smb-root-sha256" = ("b" * 64)
        "controlled-smb-probe-sha256" = ("c" * 64); "efs-probe-path-sha256" = ("d" * 64)
        "captured-at" = [string]$CapturedAt; "request-sid" = $Intent.Fields.'request-sid'
        "chroot-path-sha256" = $Access.ChrootPathSha256
        "chroot-directory-sddl-sha256" = $Access.ChrootDirectorySddlSha256
        "slot-directory-sddl-sha256" = $Access.SlotDirectorySddlSha256
        "slot-file-sddl-sha256" = $Access.SlotFileSddlSha256
        "results-directory-sddl-sha256" = $Access.ResultsDirectorySddlSha256
        "result-file-sddl-sha256" = $Access.ResultFileSddlSha256
    }
    foreach ($Name in Get-U3NativeGateNames) {
        $Fields[$Name] = if ($Name -in @("profile-efs-capability", "profile-efs-denied")) {
            "not-supported"
        } else { "passed" }
    }
    $Names = [string[]]@("nonce", "host", "epoch", "generation-sha256", "controlled-smb-root-sha256",
        "controlled-smb-probe-sha256", "efs-probe-path-sha256", "captured-at", "request-sid",
        "chroot-path-sha256", "chroot-directory-sddl-sha256", "slot-directory-sddl-sha256",
        "slot-file-sddl-sha256", "results-directory-sddl-sha256", "result-file-sddl-sha256") +
        (Get-U3NativeGateNames)
    $Lines = [Collections.Generic.List[string]]::new(); [void]$Lines.Add("windows-native-canary-raw-evidence|2")
    foreach ($Name in $Names) { [void]$Lines.Add("$Name|$($Fields[$Name])") }
    [void]$Lines.Add("end-raw-evidence|")
    return [pscustomobject]@{ Bytes = ConvertTo-CanonicalAsciiBytes $Lines.ToArray(); Fields = $Fields }
}

function New-U3FixtureReceipt([object]$Intent, [object]$Raw, [object]$Certificate, [int64]$IssuedAt) {
    $Access = Get-U3NativeAccessContract $Intent.Fields.'request-sid'
    $Fields = [ordered]@{
        "nonce" = $Raw.Fields.nonce; "host" = $Intent.Fields.host; "epoch" = $Intent.Fields.'u3-epoch'
        "generation-sha256" = $Intent.Fields.'u3-generation-sha256'; "runner-path-sha256" = ("e" * 64)
        "runner-sha256" = ("f" * 64); "runner-publisher-thumbprint" = $Certificate.Thumbprint.ToUpperInvariant()
        "issued-at" = [string]$IssuedAt; "expires-at" = [string]($IssuedAt + 600)
        "human-preview-sha256" = ("1" * 64); "human-confirmation-sha256" = ("2" * 64)
        "clock-skew-bound-seconds" = "300"; "request-sid" = $Intent.Fields.'request-sid'
        "chroot-path-sha256" = $Access.ChrootPathSha256
        "chroot-directory-sddl-sha256" = $Access.ChrootDirectorySddlSha256
        "slot-directory-sddl-sha256" = $Access.SlotDirectorySddlSha256
        "slot-file-sddl-sha256" = $Access.SlotFileSddlSha256
        "results-directory-sddl-sha256" = $Access.ResultsDirectorySddlSha256
        "result-file-sddl-sha256" = $Access.ResultFileSddlSha256
        "raw-evidence-sha256" = Get-Sha256Bytes $Raw.Bytes
    }
    foreach ($Name in Get-U3NativeGateNames) { $Fields[$Name] = $Raw.Fields[$Name] }
    $Lines = [Collections.Generic.List[string]]::new(); [void]$Lines.Add("windows-native-canary-receipt|3")
    foreach ($Name in Get-U3NativeCanaryFieldNames) { [void]$Lines.Add("$Name|$($Fields[$Name])") }
    [void]$Lines.Add("end-canary|")
    $Bytes = ConvertTo-CanonicalAsciiBytes $Lines.ToArray()
    return [pscustomobject]@{ Bytes = $Bytes; Signature = New-FixtureCmsSignature $Bytes $Certificate }
}

function New-TransportFixtureReceipt([object]$Intent, [object]$Certificate, [int64]$IssuedAt) {
    $Evidence = ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-native-canary-evidence|1", "fixture|true", "end-evidence|")
    $Fields = [ordered]@{
        "nonce" = ("b" * 64); "host" = $Intent.Fields.host
        "request-sid" = $Intent.Fields.'request-sid'; "intent-sha256" = $Intent.Sha256
        "configuration-sha256" = ("c" * 64); "firewall-contract-sha256" = ("d" * 64)
        "host-key-fingerprint" = ("SHA256:" + ("B" * 43)); "issued-at" = [string]$IssuedAt
        "expires-at" = [string]($IssuedAt + 600); "raw-evidence-sha256" = Get-Sha256Bytes $Evidence
    }
    foreach ($Name in Get-NativeCanaryFieldNames) {
        if (-not $Fields.Contains($Name)) { $Fields[$Name] = "passed" }
    }
    $Lines = [Collections.Generic.List[string]]::new()
    [void]$Lines.Add("windows-sftp-native-canary|1")
    foreach ($Name in Get-NativeCanaryFieldNames) { [void]$Lines.Add("$Name|$($Fields[$Name])") }
    [void]$Lines.Add("end-canary|")
    $Bytes = ConvertTo-CanonicalAsciiBytes $Lines.ToArray()
    return [pscustomobject]@{
        Bytes = $Bytes; Signature = New-FixtureCmsSignature $Bytes $Certificate; Evidence = $Evidence
        ConfigurationSha256 = $Fields.'configuration-sha256'
        FirewallSha256 = $Fields.'firewall-contract-sha256'
        HostKeyFingerprint = $Fields.'host-key-fingerprint'; Nonce = $Fields.nonce
    }
}

function Get-FixtureActivationEvents([string]$FaultPhase, [bool]$PriorEnabled) {
    $Events = [Collections.Generic.List[string]]::new()
    $Account = $false; $Firewall = $false
    try {
        foreach ($Phase in @("contained", "snapshotted", "staged", "configured", "restarted")) {
            [void]$Events.Add($Phase); if ($FaultPhase -ceq $Phase) { throw "fault" }
        }
        [void]$Events.Add("canary"); if ($FaultPhase -ceq "canary") { throw "fault" }
        [void]$Events.Add("u3-trust-published"); if ($FaultPhase -ceq "u3-trust-published") { throw "fault" }
        [void]$Events.Add("active-pointer"); if ($FaultPhase -ceq "active-pointer") { throw "fault" }
        $Account = $true; [void]$Events.Add("account-enabled")
        if ($FaultPhase -ceq "account-enabled") { throw "fault" }
        $Firewall = $true; [void]$Events.Add("firewall-enabled")
        if ($FaultPhase -ceq "firewall-enabled") { throw "fault" }
    } catch {
        $Firewall = $false; [void]$Events.Add("rollback-firewall-closed")
        $Account = $false; [void]$Events.Add("rollback-account-disabled")
        if ($PriorEnabled) {
            $Account = $true; [void]$Events.Add("rollback-account-restored")
            $Firewall = $true; [void]$Events.Add("rollback-firewall-restored-last")
        }
    }
    return [pscustomobject]@{ Events = $Events.ToArray(); Account = $Account; Firewall = $Firewall }
}

function Invoke-SelfTest {
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $Intent = New-FixtureIntent $Now
    Assert-Fixture ($Intent.Sha256 -ceq (Get-Sha256Bytes $Intent.Bytes)) "intent_hash"
    Assert-FixtureThrows { [void](Read-ControllerIntent ($Intent.Bytes[0..($Intent.Bytes.Count - 2)]) "install") } `
        "intent_requires_newline"
    $CrBytes = [byte[]]@($Intent.Bytes[0..10] + 13 + $Intent.Bytes[11..($Intent.Bytes.Count - 1)])
    Assert-FixtureThrows { [void](Read-ControllerIntent $CrBytes "install") } "intent_rejects_cr"
    Assert-FixtureThrows { [void](Read-ManagementCidrs "2001:db8::/32,10.0.0.0/8") } "cidr_order"
    Assert-FixtureThrows { [void](ConvertTo-CanonicalAsciiBytes @("fixture`n")) } `
        "producer_rejects_newline"
    $AuthorizedPrincipals = $script:Ascii.GetString((Get-AuthorizedPrincipalsBytes))
    Assert-Fixture ($AuthorizedPrincipals -ceq "$($script:EndpointPrincipal)`n" -and
        $AuthorizedPrincipals -cne "$($script:RequestAccountName)`n") "u6_endpoint_principal_mapping"

    $Contracts = Get-U3ContractDigests $Intent.Fields.'request-sid'
    Assert-Fixture ($Contracts.SlotFile -ceq
        "O:$($Intent.Fields.'request-sid')G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;$($Intent.Fields.'request-sid'))") `
        "slot_write_data_only"
    $Access = Get-U3NativeAccessContract $Intent.Fields.'request-sid'
    Assert-Fixture ($Access.ChrootPathSha256 -ceq
        (Get-Sha256Bytes ($script:Utf8.GetBytes("C:\PROGRAMDATA\MACHINEUTILITIES\CHROOT")))) "chroot_hash"

    $ContainmentFixture = [pscustomobject]@{
        DrainOperation = "install"; DrainTransactionId = "transaction-" + ("a" * 32); U3Epoch = 11
        PriorSystemTaskEnabled = $true; PriorProfileTaskEnabled = $true
        PriorSystemTaskXmlSha256 = ("1" * 64); PriorProfileTaskXmlSha256 = ("2" * 64)
    }
    $DrainFields = Read-U3DrainBytes (Get-U3DrainBytes $ContainmentFixture)
    Assert-Fixture ($DrainFields.operation -ceq "install" -and $DrainFields.epoch -ceq "11" -and
        $DrainFields.'transaction-id' -ceq ("transaction-" + ("a" * 32)) -and
        (Get-U3DrainOperation "repair") -ceq "install") "u3_drain_binding"
    $BadDrainBytes = $script:Ascii.GetBytes(
        ($script:Ascii.GetString((Get-U3DrainBytes $ContainmentFixture))).Replace(
            "state|draining", "state|released"))
    Assert-FixtureThrows { [void](Read-U3DrainBytes $BadDrainBytes) } "u3_drain_state_rejected"

    $FixtureCa = ConvertTo-CanonicalAsciiBytes @("ssh-ed25519 AQID fixture-ca")
    $FixtureAllowed = Get-U3AllowedSignersBytes $FixtureCa $Intent.Fields.'fleet-domain'
    Assert-Fixture ($script:Ascii.GetString($FixtureAllowed) -ceq
        "*@example.invalid cert-authority ssh-ed25519 AQID`n") "u3_allowed_signers_exact"
    $DuplicateCa = ConvertTo-CanonicalAsciiBytes @(
        "ssh-ed25519 AQID fixture-a", "ssh-ed25519 AQID fixture-b")
    Assert-FixtureThrows { [void](Get-U3AllowedSignersBytes $DuplicateCa $Intent.Fields.'fleet-domain') } `
        "u3_allowed_signers_duplicate_rejected"
    $IdentityContext = [pscustomobject]@{
        Intent = $Intent; HostKeyFingerprint = ("SHA256:" + ("B" * 43))
    }
    $IdentityText = $script:Ascii.GetString((Get-U3HostIdentityBytes $IdentityContext))
    Assert-Fixture ($IdentityText.Contains(
            "request-sid|$($Intent.Fields.'request-sid')`n", [StringComparison]::Ordinal) -and
        $IdentityText.Contains("request-principal|MachineUtilitiesRequest`n", [StringComparison]::Ordinal) -and
        $IdentityText.Contains("previous-ca-fingerprint|-`nprevious-ca-generation|0`n",
            [StringComparison]::Ordinal)) `
        "u3_identity_signed_sid_binding"
    $DualIdentityBytes = $script:Ascii.GetBytes(
        ($script:Ascii.GetString($Intent.Bytes)).Replace("trust-mode|single", "trust-mode|dual").Replace(
            "previous-ca-fingerprint|-`nprevious-ca-generation|0",
            "previous-ca-fingerprint|SHA256:$('C' * 43)`nprevious-ca-generation|6"))
    $DualIdentityIntent = Read-ControllerIntent $DualIdentityBytes "install"
    $DualIdentityText = $script:Ascii.GetString((Get-U3HostIdentityBytes ([pscustomobject]@{
        Intent = $DualIdentityIntent; HostKeyFingerprint = ("SHA256:" + ("B" * 43))
    })))
    Assert-Fixture ($DualIdentityText.Contains(
            "fleet-ca-fingerprint|SHA256:$('A' * 43)`nca-generation|7`n" +
            "previous-ca-fingerprint|SHA256:$('C' * 43)`nprevious-ca-generation|6`n",
            [StringComparison]::Ordinal)) "u3_identity_dual_ca_overlap"

    $AuthorityActive = [ordered]@{
        "intent-sha256" = $Intent.Sha256; "request-sid" = $Intent.Fields.'request-sid'
        "issued-at" = [string]$Now; "expires-at" = [string]($Now + 3600)
    }
    $AuthorityContext = [pscustomobject]@{ Active = $AuthorityActive; Intent = $Intent }
    Assert-CurrentActiveMutationAuthority $AuthorityContext $Now
    $ExpiredActive = [ordered]@{
        "intent-sha256" = $Intent.Sha256; "request-sid" = $Intent.Fields.'request-sid'
        "issued-at" = [string]($Now - 3601); "expires-at" = [string]($Now - 1)
    }
    Assert-FixtureThrows {
        Assert-CurrentActiveMutationAuthority ([pscustomobject]@{ Active = $ExpiredActive; Intent = $Intent }) $Now
    } "historical_candidate_expired_rejected"
    $MismatchedSidActive = [ordered]@{
        "intent-sha256" = $Intent.Sha256; "request-sid" = "S-1-5-21-1-2-3-2002"
        "issued-at" = [string]$Now; "expires-at" = [string]($Now + 3600)
    }
    Assert-FixtureThrows {
        Assert-CurrentActiveMutationAuthority `
            ([pscustomobject]@{ Active = $MismatchedSidActive; Intent = $Intent }) $Now
    } "historical_candidate_sid_mismatch_rejected"

    $ReloadRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "fixture-generation-a")
    $ExpectedReload = [pscustomobject]@{
        GenerationRoot = $ReloadRoot; ActiveBytes = [byte[]]@(1, 2, 3)
        IntentBytes = [byte[]]@(4, 5, 6); IntentSignatureBytes = [byte[]]@(7, 8, 9)
        CandidateReceiptBytes = [byte[]]@(10, 11, 12)
    }
    $MatchingReload = [pscustomobject]@{
        GenerationRoot = $ReloadRoot; ActiveBytes = [byte[]]@(1, 2, 3)
        IntentBytes = [byte[]]@(4, 5, 6); IntentSignatureBytes = [byte[]]@(7, 8, 9)
        CandidateReceiptBytes = [byte[]]@(10, 11, 12)
    }
    Assert-ReloadedActiveContext $ExpectedReload $MatchingReload
    $SupersededReload = [pscustomobject]@{
        GenerationRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), "fixture-generation-b")
        ActiveBytes = [byte[]]@(1, 2, 3); IntentBytes = [byte[]]@(4, 5, 6)
        IntentSignatureBytes = [byte[]]@(7, 8, 9); CandidateReceiptBytes = [byte[]]@(10, 11, 12)
    }
    Assert-FixtureThrows { Assert-ReloadedActiveContext $ExpectedReload $SupersededReload } `
        "superseded_active_generation_rejected"

    $ReadinessRequestId = "request-0123456789abcdef0123456789abcdef"
    $ReadinessLines = @(
        "windows-broker-readiness-result|1", "request-id|$ReadinessRequestId", "state|ready",
        "reason|fresh_probes_verified", "broker-protocol|1", "broker-version|1.0.0",
        "broker-sha256|$('a' * 64)", "policy-version|1", "policy-sha256|$('b' * 64)",
        "constraint-version|1", "constraints-sha256|$('c' * 64)", "generation|11",
        "generation-sha256|$('d' * 64)", "winget-context-version|1",
        "winget-context-sha256|$('e' * 64)", "provider-lock-sha256|$('f' * 64)",
        "request-sid|$($Intent.Fields.'request-sid')", "request-principal|MachineUtilitiesRequest",
        "system-task-ready|true", "profile-task-ready|false", "transport-ready|true",
        "native-canary-ready|true", "observed-at|$Now", "expires-at|$($Now + $script:ClockSkewSeconds)",
        "action-count|1", "action|winget.inventory-machine.v1|windows-system-v1|-|$('1' * 64)",
        "profile-constraint-count|0", "end-readiness|")
    $ReadinessPath = [IO.Path]::Combine([IO.Path]::GetTempPath(),
        "machine-utilities-readiness-" + [Guid]::NewGuid().ToString("N"))
    try {
        [IO.File]::WriteAllBytes($ReadinessPath, (ConvertTo-CanonicalAsciiBytes $ReadinessLines))
        Assert-U3ReadinessResult $ReadinessPath $ReadinessRequestId
        $FalseReadyText = [IO.File]::ReadAllText($ReadinessPath, $script:Ascii).Replace(
            "profile-task-ready|false", "profile-task-ready|true")
        [IO.File]::WriteAllBytes($ReadinessPath, $script:Ascii.GetBytes($FalseReadyText))
        Assert-FixtureThrows { Assert-U3ReadinessResult $ReadinessPath $ReadinessRequestId } `
            "profile_task_readiness_overclaim_rejected"
    } finally {
        if ([IO.File]::Exists($ReadinessPath)) { [IO.File]::Delete($ReadinessPath) }
    }

    $ExistingConfig = ConvertTo-CanonicalAsciiBytes @("Port 22", "Subsystem sftp sftp-server.exe")
    $Block = Get-ManagedSshdBlock "C:\ProgramData\MachineUtilities-Sftp\generations\$('a' * 64)"
    $ManagedConfig = Set-ManagedSshdBlock $ExistingConfig $Block
    Assert-Fixture (($script:Ascii.GetString($ManagedConfig).Split($script:ManagedBlockBegin).Count - 1) -eq 1) `
        "managed_block_single"
    $RemovedConfig = Remove-ManagedSshdBlock $ManagedConfig $Block
    Assert-Fixture ((Get-Sha256Bytes $RemovedConfig) -ceq (Get-Sha256Bytes $ExistingConfig)) "managed_block_roundtrip"
    $UnknownMarker = ConvertTo-CanonicalAsciiBytes @("# BEGIN MACHINE-UTILITIES WINDOWS-SFTP v2", "Port 22")
    Assert-FixtureThrows { [void](Set-ManagedSshdBlock $UnknownMarker $Block) } "unknown_marker"

    $Certificate = New-FixtureCertificate
    try {
        $IntentSignature = New-FixtureCmsSignature $Intent.Bytes $Certificate
        $CandidateAuthorityContext = [pscustomobject]@{
            Intent = $Intent; IntentBytes = $Intent.Bytes; IntentSignatureBytes = $IntentSignature
            Bootstrap = [ordered]@{
                "controller-signing-thumbprint" = $Certificate.Thumbprint.ToUpperInvariant()
            }
        }
        Assert-CandidateMutationAuthority $CandidateAuthorityContext $Intent $Intent.Bytes `
            $IntentSignature $Now
        Assert-FixtureThrows {
            Assert-CandidateMutationAuthority $CandidateAuthorityContext $Intent $Intent.Bytes `
                $IntentSignature ($Now + 3601)
        } "expired_candidate_mutation_authority_rejected"

        $Raw = New-U3FixtureRawEvidence $Intent $Now
        $Receipt = New-U3FixtureReceipt $Intent $Raw $Certificate $Now
        [void](Read-U3NativeCanary $Receipt.Bytes $Receipt.Signature $Raw.Bytes $Intent)
        $V2Receipt = [byte[]]$Receipt.Bytes.Clone()
        $V2Text = $script:Ascii.GetString($V2Receipt).Replace(
            "windows-native-canary-receipt|3", "windows-native-canary-receipt|2")
        Assert-FixtureThrows { [void](Read-U3NativeCanary $script:Ascii.GetBytes($V2Text) `
                $Receipt.Signature $Raw.Bytes $Intent) } "receipt_v2_rejected"
        $BadRawText = $script:Ascii.GetString($Raw.Bytes).Replace("slot-write-data-only|passed",
            "slot-write-data-only|failed")
        Assert-FixtureThrows { [void](Read-U3NativeRawEvidence $script:Ascii.GetBytes($BadRawText) $Intent) } `
            "raw_gate_rejected"
        Assert-Fixture (Test-DetachedCmsSignature $Receipt.Bytes $Receipt.Signature `
            $Certificate.Thumbprint.ToUpperInvariant() $Now ($Now + 600)) "cms_signature"
        $Tampered = [byte[]]$Receipt.Bytes.Clone(); $Tampered[10] = $Tampered[10] -bxor 1
        Assert-Fixture (-not (Test-DetachedCmsSignature $Tampered $Receipt.Signature `
            $Certificate.Thumbprint.ToUpperInvariant() $Now ($Now + 600))) "cms_tamper"

        $Transport = New-TransportFixtureReceipt $Intent $Certificate $Now
        [void](Read-NativeCanaryReceipt $Transport.Bytes $Transport.Signature $Transport.Evidence `
            $Intent $Certificate.Thumbprint.ToUpperInvariant() $Transport.ConfigurationSha256 `
            $Transport.FirewallSha256 $Transport.HostKeyFingerprint $Transport.Nonce)
        $BadTransportText = $script:Ascii.GetString($Transport.Bytes).Replace(
            "preactivation-account-disabled|passed", "preactivation-account-disabled|failed")
        $BadTransportBytes = $script:Ascii.GetBytes($BadTransportText)
        $BadTransportSignature = New-FixtureCmsSignature $BadTransportBytes $Certificate
        Assert-FixtureThrows { [void](Read-NativeCanaryReceipt $BadTransportBytes `
                $BadTransportSignature $Transport.Evidence $Intent `
                $Certificate.Thumbprint.ToUpperInvariant() $Transport.ConfigurationSha256 `
                $Transport.FirewallSha256 $Transport.HostKeyFingerprint $Transport.Nonce) } `
            "transport_preactivation_gate_rejected"
    } finally { $Certificate.Dispose() }

    foreach ($Phase in @("contained", "snapshotted", "staged", "configured", "restarted",
            "account-enabled", "canary", "u3-trust-published", "active-pointer", "firewall-enabled")) {
        $InstallModel = Get-FixtureActivationEvents $Phase $false
        Assert-Fixture (-not $InstallModel.Account -and -not $InstallModel.Firewall) "install_fault_$Phase"
        $RepairModel = Get-FixtureActivationEvents $Phase $true
        Assert-Fixture ($RepairModel.Account -and $RepairModel.Firewall -and
            $RepairModel.Events[-1] -ceq "rollback-firewall-restored-last") "repair_fault_$Phase"
    }
    $SuccessModel = Get-FixtureActivationEvents "-" $false
    Assert-Fixture ($SuccessModel.Events[-1] -ceq "firewall-enabled" -and
        [Array]::IndexOf($SuccessModel.Events, "account-enabled") -gt
        [Array]::IndexOf($SuccessModel.Events, "active-pointer") -and
        [Array]::IndexOf($SuccessModel.Events, "active-pointer") -gt
        [Array]::IndexOf($SuccessModel.Events, "u3-trust-published") -and
        [Array]::IndexOf($SuccessModel.Events, "u3-trust-published") -gt
        [Array]::IndexOf($SuccessModel.Events, "canary")) "activation_order"

    $TransactionFixture = [pscustomobject]@{
        Id = ("a" * 64); Operation = "install"; Phase = "activated"; IntentSha256 = ("b" * 64)
        CandidateSha256 = ("c" * 64); ConfigurationBeforeSha256 = ("d" * 64)
        ConfigurationAfterSha256 = ("e" * 64); PriorAccountEnabled = $false
        DrainOperation = "install"; DrainTransactionId = "transaction-" + ("a" * 32); U3Epoch = 11
        PriorSystemTaskEnabled = $true; PriorProfileTaskEnabled = $true
        PriorSystemTaskXmlSha256 = ("1" * 64); PriorProfileTaskXmlSha256 = ("2" * 64)
        PriorFirewallPresent = $false; PriorFirewallEnabled = $false; PriorFirewallAddresses = "-"
        PriorServiceStart = 3; PriorServiceDelayed = 0; PriorServiceStatus = "Stopped"
        PriorActiveSha256 = "-"; SnapshotComplete = $true
    }
    $ParsedTransaction = Read-Transaction (Get-TransactionBytes $TransactionFixture)
    Assert-Fixture ($ParsedTransaction.phase -ceq "activated" -and
        $ParsedTransaction.'snapshot-complete' -ceq "true" -and
        $ParsedTransaction.'u3-drain-operation' -ceq "install" -and
        $ParsedTransaction.'u3-drain-transaction-id' -ceq ("transaction-" + ("a" * 32))) `
        "transaction_roundtrip"

    $RevocationFixtureContext = [pscustomobject]@{ Active = [ordered]@{
            "intent-sha256" = ("b" * 64); "configuration-sha256" = ("c" * 64) } }
    $RevocationFixtureIntent = [pscustomobject]@{
        Sha256 = ("d" * 64); Fields = [ordered]@{ mode = "emergency" } }
    $ParsedRevocation = Read-RevocationTransaction (Get-RevocationTransactionBytes "drained" `
        $RevocationFixtureContext $RevocationFixtureIntent ($script:Ascii.GetBytes("fixture")) `
        ("e" * 64) $ContainmentFixture)
    Assert-Fixture ($ParsedRevocation.phase -ceq "drained" -and
        $ParsedRevocation.'u3-drain-transaction-id' -ceq $ContainmentFixture.DrainTransactionId -and
        $ParsedRevocation.'prior-system-task-xml-sha256' -ceq
            $ContainmentFixture.PriorSystemTaskXmlSha256) "revocation_containment_roundtrip"

    [Console]::Out.WriteLine("enroll-windows-sftp self-test: ok")
}

function Write-CandidatePreview([byte[]]$CandidateBytes) {
    $Digest = Get-Sha256Bytes $CandidateBytes
    [Console]::Out.Write($script:Ascii.GetString($CandidateBytes))
    [Console]::Out.Write($script:Ascii.GetString((ConvertTo-CanonicalAsciiBytes @(
        "windows-sftp-owner-confirmation|1", "candidate-sha256|$Digest",
        "confirmation-argument|$Digest", "end-confirmation|"))))
}

function Test-PendingLifecycle([object]$Layout) {
    foreach ($Binding in @(
            @($Layout.U6State + "\lifecycle.transaction", "lifecycle"),
            @($Layout.U6State + "\revocation.transaction", "revocation"))) {
        if (-not [IO.File]::Exists($Binding[0])) { continue }
        if ($Binding[1] -ceq "lifecycle") {
            $Fields = Read-Transaction (Read-HeldBytes $Binding[0] 8192)
            if ($Fields.phase -cnotin @("committed", "rolled-back")) { return $true }
        } else {
            $Fields = Read-RevocationTransaction (Read-HeldBytes $Binding[0] 4096)
            if ($Fields.phase -cne "committed") { return $true }
        }
    }
    return $false
}

function Write-PublicStatus([object]$Layout) {
    $ReadinessPath = $Layout.PublicRoot + "\readiness"
    if (-not [IO.File]::Exists($ReadinessPath)) {
        Write-TransportStatus "needs_human_enrollment" "no_managed_windows_sftp_transport"
        return
    }
    $Bytes = Read-HeldBytes $ReadinessPath 16384
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 16384 "public_readiness"
    if ($Lines.Count -lt 4 -or $Lines[0] -cne "windows-sftp-readiness|1" -or
        $Lines[-1] -cne "end-readiness|" -or
        @($Lines | Where-Object { $_ -cmatch '^state\|(ready|awaiting-controller-signature|revoked|draining|drifted)$' }).Count -ne 1) {
        throw "public_readiness_drift"
    }
    [Console]::Out.Write($script:Ascii.GetString($Bytes))
}

function Write-FailureStatus([string]$Message) {
    $Reason = ($Message.Split(':')[0] -replace '[^A-Za-z0-9_]', '_').ToLowerInvariant()
    if ($Reason -in @("unsupported_platform", "unsupported_protected_layout",
            "unsupported_security_boundary", "windows_parent_boundary_unavailable")) {
        Write-TransportStatus "unsupported" $Reason; return 69
    }
    if ($Reason -in @("chroot_missing", "chroot_ingress_missing", "slot_missing", "results_missing",
            "u3_contract_digest_mismatch")) {
        Write-TransportStatus "unsupported" "u3_chroot_projection_unavailable"; return 69
    }
    if ($Reason -match 'human_elevation|required_entrypoint') {
        Write-TransportStatus "needs_human_enrollment" $Reason; return 77
    }
    if ($Reason -match 'recovery_required|drain_timeout|(?:lifecycle|u3_broker)_lock_timeout|rollback_drifted') {
        Write-TransportStatus "recovery_required" $Reason; return 75
    }
    if ($Reason -match 'confirmation|controller_|invalid_|expired|candidate|revoke_intent') {
        Write-TransportStatus "rejected" $Reason; return 65
    }
    Write-TransportStatus "drifted" $Reason
    return 74
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { [Console]::Error.WriteLine($_.Exception.ToString()); exit 1 }
}

if (-not $IsWindows) {
    Write-TransportStatus "unsupported" "unsupported_security_boundary"
    exit 69
}

try {
    if (Test-WslInvocation) { throw "unsupported_security_boundary" }
    $Layout = Get-NativeLayout
    switch ($PSCmdlet.ParameterSetName) {
        "Status" {
            Write-PublicStatus $Layout
        }
        "Preview" {
            Assert-AdministratorInteractiveBoundary
            if ([IO.Directory]::Exists($Layout.U6State) -and (Test-PendingLifecycle $Layout)) {
                throw "lifecycle_recovery_required"
            }
            $StagedIntent = Read-ControllerIntent (Read-HeldBytes $Layout.Intent $script:MaximumIntentBytes) ""
            if ($StagedIntent.Fields.operation -ceq "install") {
                if ([IO.File]::Exists($Layout.ActivePointer)) { throw "active_enrollment_already_exists" }
                $Context = Get-CandidateContext $Layout "install" "disabled"
            } else {
                $Prior = Read-ActiveInstallation $Layout "enabled"
                $Context = Get-CandidateContext $Layout "repair" "enabled"
                if ($Context.Intent.Sha256 -ceq $Prior.Intent.Sha256) { throw "repair_generation_not_new" }
            }
            Write-CandidatePreview $Context.CandidateReceiptBytes
        }
        "Install" {
            Assert-AdministratorInteractiveBoundary
            if ([IO.Directory]::Exists($Layout.U6State)) {
                Resolve-StaleRevocation $Layout
                Resolve-StaleEnrollmentTransaction $Layout
            }
            if ([IO.File]::Exists($Layout.ActivePointer)) { throw "active_enrollment_already_exists" }
            $Context = Get-CandidateContext $Layout "install" "disabled"
            [void](Invoke-EnrollmentTransaction $Context "install" $null)
            Write-TransportStatus "awaiting_controller_signature" `
                "candidate_receipt_requires_controller_signature" $Context.Intent.Sha256
        }
        "Repair" {
            Assert-AdministratorInteractiveBoundary
            if ([IO.Directory]::Exists($Layout.U6State)) {
                Resolve-StaleRevocation $Layout
                Resolve-StaleEnrollmentTransaction $Layout
            }
            $Prior = Read-ActiveInstallation $Layout "enabled"
            $Context = Get-CandidateContext $Layout "repair" "enabled"
            if ($Context.Intent.Sha256 -ceq $Prior.Intent.Sha256) { throw "repair_generation_not_new" }
            [void](Invoke-EnrollmentTransaction $Context "repair" $Prior.ActiveBytes)
            Write-TransportStatus "awaiting_controller_signature" `
                "candidate_receipt_requires_controller_signature" $Context.Intent.Sha256
        }
        "Verify" {
            Assert-AdministratorInteractiveBoundary
            if (Test-PendingLifecycle $Layout) { throw "lifecycle_recovery_required" }
            $Context = Read-ActiveInstallation $Layout "enabled"
            [void](Promote-ControllerReceipt $Context)
            Write-PublicStatus $Layout
        }
        "PreviewRevoke" {
            Assert-AdministratorInteractiveBoundary
            if (Test-PendingLifecycle $Layout) { throw "lifecycle_recovery_required" }
            $Context = Read-ProtectedActiveAuthorization $Layout
            $Mode = if ($Emergency) { "emergency" } else { "normal" }
            Write-CandidatePreview (Get-RevokeIntentBytes $Context $Mode `
                ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
        }
        "Revoke" {
            Assert-AdministratorInteractiveBoundary
            if ([IO.File]::Exists($Layout.U6State + "\revocation.transaction")) {
                $Pending = Read-RevocationTransaction (Read-HeldBytes `
                    ($Layout.U6State + "\revocation.transaction") 4096)
                if ($Pending.phase -cne "committed") {
                    Resolve-StaleRevocation $Layout
                    Write-PublicStatus $Layout
                    break
                }
            }
            Resolve-StaleEnrollmentTransaction $Layout
            $Context = Read-ProtectedActiveAuthorization $Layout
            $Mode = if ($Emergency) { "emergency" } else { "normal" }
            $RevokeBytes = Assert-ProtectedFile $Layout.RevokeIntent $Layout.StageRoot `
                $Context.ProtectedFileSddl 8192 $Layout "revoke_intent"
            $RevokeSignature = Assert-ProtectedFile $Layout.RevokeIntentSignature $Layout.StageRoot `
                $Context.ProtectedFileSddl 65536 $Layout "revoke_intent_signature"
            $RevokeIntent = Read-RevokeIntent $RevokeBytes $Context $Mode
            if (-not (Test-DetachedCmsSignature $RevokeBytes $RevokeSignature `
                    $Context.Active.'controller-signing-thumbprint' $RevokeIntent.IssuedAt $RevokeIntent.ExpiresAt)) {
                throw "controller_revoke_signature_invalid"
            }
            Invoke-RevokeTransaction $Context $RevokeIntent $RevokeSignature
            Write-PublicStatus $Layout
        }
        default { throw "invalid_parameter_set" }
    }
    exit 0
} catch {
    $ExitCode = Write-FailureStatus $_.Exception.Message
    exit $ExitCode
}
