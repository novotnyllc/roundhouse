[CmdletBinding(DefaultParameterSetName = "Task")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Task")]
    [ValidateSet("windows-system-v1")][string]$Context,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Ascii = [Text.Encoding]::ASCII
$script:BrokerProtocol = 1
$script:BrokerVersion = "1.0.0"
$script:RequestNamespace = "machine-utilities-request"
$script:MaximumRequestBytes = 16384
$script:MaximumSignatureBytes = 16384
$script:MaximumPayloadBytes = 67108864
$script:MaximumReadinessResultBytes = 65536
$script:MaximumReadinessProbeBindings = 64
$script:EmptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
$script:MaximumClockSkewSeconds = 300
$script:PollIntervalSeconds = 60
$script:MinimumRequestTtlSeconds = (2 * $script:PollIntervalSeconds) + $script:MaximumClockSkewSeconds
$script:MaximumClaims = 64
$script:ReservedClaimSlots = 8
$script:MaximumAuditBytes = 1048576
$script:AuditReservationBytes = 1048576
$script:TerminalReservationBytes = 65536
$script:TerminalResultRetentionSeconds = 86400
$script:ReservationFillByte = [byte]0xA5
$script:AuditRoot = $null
$script:PublicRoot = $null
$script:BrokerRoot = $null
$script:SlotRoot = $null
$script:ResultRoot = $null
$script:RequestSid = $null
$script:SelfTestFixture = $false
$script:InjectAuditFailureAfterCanonical = $false
$script:InjectAuditReservationFailureAfterHeader = $false
$script:InjectClaimFailureAfterReservation = $false
$script:ProtectedDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
$script:ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
$script:ProfileTaskSddl = "O:SYG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
$script:TaskSecurityInformation = 0x7

function Get-Sha256Bytes([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally { $Hasher.Dispose() }
}

function Get-Sha256Text([string]$Text) {
    return Get-Sha256Bytes $script:Ascii.GetBytes($Text)
}

function Get-Sha256Utf8Text([string]$Text) {
    return Get-Sha256Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-NormalizedTaskXml([string]$XmlText) {
    try {
        $Document = [Xml.XmlDocument]::new(); $Document.PreserveWhitespace = $false; $Document.LoadXml($XmlText)
    } catch { throw "invalid_task_xml" }
    $Settings = [Xml.XmlWriterSettings]::new(); $Settings.OmitXmlDeclaration = $true
    $Settings.Indent = $false; $Settings.NewLineHandling = [Xml.NewLineHandling]::None
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

function Get-FixedTaskXml([string]$Kind, [string]$TargetSid, [string]$ProgramData) {
    if ($Kind -cnotin @("system", "profile")) { throw "invalid_task_kind" }
    $TaskName = if ($Kind -ceq "system") { "MachineUtilitiesBrokerV1" } else { "MachineUtilitiesProfileV1" }
    $ScriptName = if ($Kind -ceq "system") { "privilege-broker-windows.ps1" } else { "profile-worker-windows.ps1" }
    $ContextName = if ($Kind -ceq "system") { "windows-system-v1" } else { "windows-user-s4u-v1" }
    $LogonType = if ($Kind -ceq "system") { "ServiceAccount" } else { "S4U" }
    $RunLevel = if ($Kind -ceq "system") { "HighestAvailable" } else { "LeastPrivilege" }
    $PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
    $EntryRoot = $ProgramData.TrimEnd('\') + "\MachineUtilities\entry"
    $ScriptPath = $EntryRoot + "\" + $ScriptName
    $Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "' +
        $ScriptPath + '" -Context ' + $ContextName
    $Triggers = if ($Kind -ceq "system") {
        '<Triggers><TimeTrigger><StartBoundary>2000-01-01T00:00:00</StartBoundary>' +
        '<Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>' +
        '<Enabled>true</Enabled></TimeTrigger></Triggers>'
    } else { '<Triggers />' }
    $StartWhenAvailable = if ($Kind -ceq "system") { "true" } else { "false" }
    return '<?xml version="1.0" encoding="UTF-16"?>' +
        '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' +
        '<RegistrationInfo><URI>\' + $TaskName + '</URI></RegistrationInfo>' +
        $Triggers + '<Principals><Principal id="Author"><UserId>' +
        [Security.SecurityElement]::Escape($TargetSid) + '</UserId><LogonType>' + $LogonType +
        '</LogonType><RunLevel>' + $RunLevel + '</RunLevel></Principal></Principals>' +
        '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' +
        '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' +
        '<AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>' + $StartWhenAvailable +
        '</StartWhenAvailable>' +
        '<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><Enabled>true</Enabled><Hidden>true</Hidden>' +
        '<RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' +
        '<Priority>7</Priority></Settings><Actions Context="Author"><Exec><Command>' +
        [Security.SecurityElement]::Escape($PowerShellPath) + '</Command><Arguments>' +
        [Security.SecurityElement]::Escape($Arguments) + '</Arguments><WorkingDirectory>' +
        [Security.SecurityElement]::Escape($EntryRoot) + '</WorkingDirectory></Exec></Actions></Task>'
}

function Get-HeldFileSha256([string]$Path, [long]$MaximumBytes = 4194304) {
    $Held = Open-ExclusiveBoundedFile $Path $MaximumBytes
    try { return Get-Sha256Bytes $Held.Bytes } finally { $Held.Stream.Dispose() }
}

function ConvertFrom-CanonicalAsciiBytes {
    param([byte[]]$Bytes, [int]$MaximumBytes, [string]$Label)
    if ($Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or $Bytes[-1] -ne 10) {
        throw "invalid_$Label"
    }
    foreach ($Byte in $Bytes) {
        if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { throw "invalid_$Label" }
    }
    $Text = $script:Ascii.GetString($Bytes)
    if ($script:Ascii.GetBytes($Text).Count -ne $Bytes.Count -or $Text.Contains("`r")) {
        throw "invalid_$Label"
    }
    return [string[]]@($Text.Substring(0, $Text.Length - 1).Split("`n"))
}

function ConvertTo-CanonicalAsciiBytes([string[]]$Lines) {
    foreach ($Line in $Lines) {
        if ($Line -notmatch '^[\x20-\x7e]*$') { throw "non_ascii_record" }
    }
    return $script:Ascii.GetBytes(($Lines -join "`n") + "`n")
}

function Read-CanonicalFields {
    param(
        [string[]]$Lines,
        [string[]]$Names,
        [string]$Header,
        [string]$Trailer,
        [string]$Label
    )
    if ($Lines.Count -ne ($Names.Count + 2) -or $Lines[0] -cne $Header -or
        $Lines[-1] -cne $Trailer) { throw "invalid_$Label" }
    $Result = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or
            $Result.Contains($Parts[0])) { throw "invalid_$Label" }
        $Result[$Parts[0]] = $Parts[1]
    }
    return $Result
}

function Test-Atom([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:+@,-]{0,255}$' }
function Test-Token([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' }
function Test-Digest([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }
function Test-Fingerprint([string]$Value) { return $Value -cmatch '^SHA256:[A-Za-z0-9+/]{43}=?$' }
function Test-UInt([string]$Value) { return $Value -cmatch '^(0|[1-9][0-9]{0,18})$' }
function Test-ResultAtomOrDash([string]$Value) {
    return $Value -ceq "-" -or (Test-Atom $Value) -or
        $Value -cmatch '^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,127}$'
}

function Test-CanonicalNonNegativeInt64([string]$Value) {
    [long]$Parsed = 0
    return (Test-UInt $Value) -and [long]::TryParse($Value, [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed) -and $Parsed -ge 0
}

function Test-CanonicalUInt32([string]$Value) {
    [uint32]$Parsed = 0
    return $Value -cmatch '^(0|[1-9][0-9]{0,9})$' -and
        [uint32]::TryParse($Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed)
}

function ConvertTo-PositiveInt32([string]$Value, [string]$Reason) {
    [int]$Parsed = 0
    if ($Value -notmatch '^[1-9][0-9]{0,9}$' -or
        -not [int]::TryParse($Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed) -or $Parsed -lt 1) {
        throw $Reason
    }
    return $Parsed
}

function Read-ActiveGenerationPointer([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 160 "active_generation"
    $Fields = Read-CanonicalFields $Lines @("epoch", "generation-sha256") `
        "machine-utilities-active-generation|1" "end-generation|" "active_generation"
    $Epoch = ConvertTo-PositiveInt32 $Fields.epoch "invalid_active_generation"
    if (-not (Test-Digest $Fields.'generation-sha256')) { throw "invalid_active_generation" }
    return [pscustomobject]@{
        Epoch = $Epoch
        Digest = [string]$Fields.'generation-sha256'
        Bytes = $Bytes
    }
}

function Get-GenerationDigest {
    param(
        [int]$Epoch,
        [string]$PolicySha256,
        [string]$ConstraintsSha256,
        [string]$ContextSha256,
        [string]$ProviderLockSha256,
        [string]$OpenSshIdentitySha256
    )
    foreach ($Digest in @($PolicySha256, $ConstraintsSha256, $ContextSha256, $ProviderLockSha256,
            $OpenSshIdentitySha256)) {
        if (-not (Test-Digest $Digest)) { throw "invalid_generation_digest_input" }
    }
    $Canonical = (@(
        "machine-utilities-generation|1"
        "epoch|$Epoch"
        "policy-sha256|$PolicySha256"
        "constraints-sha256|$ConstraintsSha256"
        "winget-context-sha256|$ContextSha256"
        "provider-lock-sha256|$ProviderLockSha256"
        "openssh-identity-sha256|$OpenSshIdentitySha256"
        "end-generation|"
    ) -join "`n") + "`n"
    return Get-Sha256Text $Canonical
}

function Read-SlotCommit([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 2048 "slot_commit"
    $Fields = Read-CanonicalFields $Lines @(
        "request-id", "request-length", "request-sha256", "signature-length",
        "signature-sha256", "payload-length", "payload-sha256"
    ) "windows-slot-commit|1" "end-commit|" "slot_commit"
    if ($Fields.'request-id' -notmatch '^request-[0-9a-f]{32}$' -or
        -not (Test-UInt $Fields.'request-length') -or -not (Test-Digest $Fields.'request-sha256') -or
        -not (Test-UInt $Fields.'signature-length') -or -not (Test-Digest $Fields.'signature-sha256') -or
        -not (Test-UInt $Fields.'payload-length') -or -not (Test-Digest $Fields.'payload-sha256')) {
        throw "invalid_slot_commit"
    }
    [long]$RequestLength = [long]::Parse($Fields.'request-length', [Globalization.CultureInfo]::InvariantCulture)
    [long]$SignatureLength = [long]::Parse($Fields.'signature-length', [Globalization.CultureInfo]::InvariantCulture)
    [long]$PayloadLength = [long]::Parse($Fields.'payload-length', [Globalization.CultureInfo]::InvariantCulture)
    if ($RequestLength -lt 1 -or $RequestLength -gt $script:MaximumRequestBytes -or
        $SignatureLength -lt 1 -or $SignatureLength -gt $script:MaximumSignatureBytes -or
        $PayloadLength -lt 0 -or $PayloadLength -gt $script:MaximumPayloadBytes) {
        throw "invalid_slot_commit"
    }
    return [pscustomobject]@{
        RequestId = [string]$Fields.'request-id'
        RequestLength = $RequestLength
        RequestSha256 = [string]$Fields.'request-sha256'
        SignatureLength = $SignatureLength
        SignatureSha256 = [string]$Fields.'signature-sha256'
        PayloadLength = $PayloadLength
        PayloadSha256 = [string]$Fields.'payload-sha256'
    }
}

function Read-BrokerRequest([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes $script:MaximumRequestBytes "request"
    $Names = @(
        "target-host-id", "request-sid", "plan-id", "request-id", "action-id", "policy-token",
        "broker-protocol", "broker-version", "broker-sha256", "policy-sha256", "constraints-sha256",
        "payload-length", "payload-sha256", "precondition-sha256", "created-at", "expires-at", "transport", "request-principal",
        "required-context", "observed-execution-principal", "console-session-state", "platform-boundary",
        "enrollment-epoch", "winget-context-sha256", "context-canary-sha256",
        "pinned-host-key-fingerprint", "node-id",
        "fleet-domain", "fleet-ca-fingerprint", "ca-generation", "node-key-fingerprint",
        "certificate-serial", "certificate-valid-after", "certificate-valid-before",
        "certificate-source-addresses", "manager-source-identity"
    )
    $Fields = Read-CanonicalFields $Lines $Names "request|1" "end-request|" "request"
    $ActionContexts = [ordered]@{
        "profile.apply-managed-bundle.v1" = "windows-user-s4u-v1"
        "profile.inventory-managed-state.v1" = "windows-user-s4u-v1"
        "winget.install-machine-package.v1" = "windows-system-v1"
        "winget.inventory-machine.v1" = "windows-system-v1"
        "winget.upgrade-machine-package.v1" = "windows-system-v1"
    }
    $IsReadiness = $Fields.'action-id' -ceq "broker.readiness.v1"
    $ExpectedContext = if ($IsReadiness) { "windows-system-v1" } else { $ActionContexts[$Fields.'action-id'] }
    $NormalDigestFields = @($Fields.'broker-sha256', $Fields.'policy-sha256',
        $Fields.'constraints-sha256', $Fields.'payload-sha256', $Fields.'precondition-sha256',
        $Fields.'winget-context-sha256', $Fields.'context-canary-sha256')
    $ReadinessDetachedFields = @($Fields.'broker-sha256', $Fields.'policy-sha256',
        $Fields.'constraints-sha256', $Fields.'precondition-sha256',
        $Fields.'winget-context-sha256', $Fields.'context-canary-sha256')
    if (-not (Test-Token $Fields.'target-host-id') -or
        $Fields.'request-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        $Fields.'plan-id' -cnotmatch '^plan-[0-9a-f]{16}$' -or
        $Fields.'request-id' -cnotmatch '^request-[0-9a-f]{32}$' -or
        (-not $IsReadiness -and $ActionContexts.Keys -cnotcontains $Fields.'action-id') -or
        $Fields.'broker-protocol' -cne [string]$script:BrokerProtocol -or
        ((-not $IsReadiness) -and $Fields.'broker-version' -cne $script:BrokerVersion) -or
        ($IsReadiness -and $Fields.'broker-version' -cne "-") -or
        ((-not $IsReadiness) -and @($NormalDigestFields | Where-Object { -not (Test-Digest $_) }).Count -ne 0) -or
        ($IsReadiness -and (@($ReadinessDetachedFields | Where-Object { $_ -cne "-" }).Count -ne 0 -or
            $Fields.'payload-sha256' -cne $script:EmptySha256)) -or
        -not (Test-UInt $Fields.'payload-length') -or
        -not (Test-UInt $Fields.'created-at') -or -not (Test-UInt $Fields.'expires-at') -or
        $Fields.transport -cne "windows-sftp" -or -not (Test-Token $Fields.'request-principal') -or
        $Fields.'required-context' -cne $ExpectedContext -or
        $Fields.'console-session-state' -cne "none" -or $Fields.'platform-boundary' -cne "windows" -or
        -not (Test-Fingerprint $Fields.'pinned-host-key-fingerprint') -or
        -not (Test-Token $Fields.'node-id') -or
        $Fields.'fleet-domain' -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$' -or
        -not (Test-Fingerprint $Fields.'fleet-ca-fingerprint') -or -not (Test-UInt $Fields.'ca-generation') -or
        -not (Test-Fingerprint $Fields.'node-key-fingerprint') -or
        -not (Test-UInt $Fields.'certificate-serial') -or
        $Fields.'certificate-valid-after' -notmatch '^[0-9]{8}T[0-9]{6}Z$' -or
        $Fields.'certificate-valid-before' -notmatch '^[0-9]{8}T[0-9]{6}Z$' -or
        ($Fields.'certificate-source-addresses' -cne "-" -and
            $Fields.'certificate-source-addresses' -notmatch '^[0-9A-Fa-f:./]+(?:,[0-9A-Fa-f:./]+){0,15}$')) {
        throw "invalid_request"
    }
    [long]$PayloadLength = [long]::Parse($Fields.'payload-length', [Globalization.CultureInfo]::InvariantCulture)
    if ($PayloadLength -gt $script:MaximumPayloadBytes) { throw "invalid_request" }
    [long]$CreatedAt = [long]::Parse($Fields.'created-at', [Globalization.CultureInfo]::InvariantCulture)
    [long]$ExpiresAt = [long]::Parse($Fields.'expires-at', [Globalization.CultureInfo]::InvariantCulture)
    if ($ExpiresAt -le $CreatedAt -or ($ExpiresAt - $CreatedAt) -lt $script:MinimumRequestTtlSeconds -or
        ($ExpiresAt - $CreatedAt) -gt 3600) { throw "invalid_request_ttl" }
    if ($IsReadiness) {
        if ($Fields.'policy-token' -cne "-" -or $Fields.'payload-length' -cne "0" -or
            $Fields.'enrollment-epoch' -cne "-" -or
            $Fields.'observed-execution-principal' -cne "LocalSystem" -or
            $Fields.'manager-source-identity' -cne "not-applicable") { throw "invalid_readiness_control" }
        $Epoch = 0
    } else {
        $Epoch = ConvertTo-PositiveInt32 $Fields.'enrollment-epoch' "invalid_request"
        # Machine inventory is the sole V1 action that is deliberately tokenless.
        # Both profile operations select an exact human-enrolled profile constraint.
        $IsTokenlessInventory = $Fields.'action-id' -ceq "winget.inventory-machine.v1"
        if (($IsTokenlessInventory -and $Fields.'policy-token' -cne "-") -or
            (-not $IsTokenlessInventory -and -not (Test-Token $Fields.'policy-token'))) { throw "invalid_policy_token" }
        $ExpectedPrincipal = if ($ExpectedContext -ceq "windows-system-v1") { "LocalSystem" } else { "enrolled-s4u-user" }
        if ($Fields.'observed-execution-principal' -cne $ExpectedPrincipal) { throw "invalid_execution_context" }
        if ($Fields.'manager-source-identity' -cne "not-applicable" -and
            -not (Test-Digest $Fields.'manager-source-identity')) { throw "invalid_manager_identity" }
    }
    if ($Fields.'required-context' -ceq "windows-system-v1" -and
        $Fields.'observed-execution-principal' -cne "LocalSystem") {
        throw "invalid_execution_context"
    }
    return [pscustomobject]@{
        Fields = $Fields
        Epoch = $Epoch
        PayloadLength = $PayloadLength
        CreatedAt = $CreatedAt
        ExpiresAt = $ExpiresAt
        IsReadiness = $IsReadiness
        Bytes = $Bytes
    }
}

function Open-ExclusiveBoundedFile([string]$Path, [long]$MaximumBytes, [switch]$Writable) {
    $Access = if ($Writable) { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, $Access,
        [IO.FileShare]::None)
    try {
        if ($Stream.Length -lt 0 -or $Stream.Length -gt $MaximumBytes) { throw "bounded_input_exceeded" }
        $Bytes = [byte[]]::new([int]$Stream.Length)
        $Offset = 0
        while ($Offset -lt $Bytes.Count) {
            $Count = $Stream.Read($Bytes, $Offset, $Bytes.Count - $Offset)
            if ($Count -eq 0) { throw "truncated_input" }
            $Offset += $Count
        }
        return [pscustomobject]@{ Stream = $Stream; Bytes = $Bytes }
    } catch {
        $Stream.Dispose()
        throw
    }
}

function Open-And-ValidateSlot([string]$SlotRoot) {
    if (-not [string]::IsNullOrWhiteSpace($script:BrokerRoot) -and
        -not [string]::IsNullOrWhiteSpace($script:PublicRoot) -and
        -not [string]::IsNullOrWhiteSpace($script:RequestSid)) {
        Assert-FixedTransportLayout $script:BrokerRoot $script:PublicRoot $script:RequestSid
    }
    $Handles = New-Object Collections.Generic.List[object]
    try {
        foreach ($Spec in @(
            @("request", $script:MaximumRequestBytes, $false), @("request.sig", $script:MaximumSignatureBytes, $false),
            @("payload", $script:MaximumPayloadBytes, $false), @("commit", 2048, $true))) {
            [void]$Handles.Add((Open-ExclusiveBoundedFile (Join-Path $SlotRoot $Spec[0]) $Spec[1] -Writable:$Spec[2]))
        }
        $Commit = Read-SlotCommit $Handles[3].Bytes
        if ($Commit.RequestLength -ne $Handles[0].Bytes.Count -or
            $Commit.RequestSha256 -cne (Get-Sha256Bytes $Handles[0].Bytes) -or
            $Commit.SignatureLength -ne $Handles[1].Bytes.Count -or
            $Commit.SignatureSha256 -cne (Get-Sha256Bytes $Handles[1].Bytes) -or
            $Commit.PayloadLength -ne $Handles[2].Bytes.Count -or
            $Commit.PayloadSha256 -cne (Get-Sha256Bytes $Handles[2].Bytes)) {
            throw "slot_digest_mismatch"
        }
        $Request = Read-BrokerRequest $Handles[0].Bytes
        if ($Commit.RequestId -cne $Request.Fields.'request-id') { throw "slot_request_mismatch" }
        if ($Commit.PayloadLength -ne $Request.PayloadLength -or
            $Commit.PayloadSha256 -cne $Request.Fields.'payload-sha256') { throw "signed_payload_binding_mismatch" }
        $IsProfileApply = $Request.Fields.'action-id' -ceq "profile.apply-managed-bundle.v1"
        if (($IsProfileApply -and $Handles[2].Bytes.Count -eq 0) -or
            (-not $IsProfileApply -and $Handles[2].Bytes.Count -ne 0)) { throw "invalid_action_payload" }
        return [pscustomobject]@{ Handles = $Handles; Commit = $Commit; Request = $Request;
            SignatureBytes = $Handles[1].Bytes; PayloadBytes = $Handles[2].Bytes }
    } catch {
        foreach ($Handle in $Handles) { $Handle.Stream.Dispose() }
        throw
    }
}

function Close-Slot([object]$Slot) {
    if ($null -ne $Slot) { foreach ($Handle in $Slot.Handles) { $Handle.Stream.Dispose() } }
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes) {
    $Directory = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($Directory)
    $Temporary = Join-Path $Directory ("." + [IO.Path]::GetFileName($Path) + "." + [Guid]::NewGuid().ToString("N"))
    try {
        $Stream = [IO.File]::Open($Temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
        [IO.File]::Move($Temporary, $Path, $true)
    } finally {
        if ([IO.File]::Exists($Temporary)) { [IO.File]::Delete($Temporary) }
    }
}

function Write-AtomicAscii([string]$Path, [string[]]$Lines) {
    Write-AtomicBytes $Path (ConvertTo-CanonicalAsciiBytes $Lines)
}

function Protect-BrokerPath([string]$Path, [bool]$Directory = $false) {
    if ($IsWindows) {
        Set-ExactSddl $Path $(if ($Directory) { $script:ProtectedDirectorySddl } else { $script:ProtectedFileSddl })
    }
}

function Assert-PhysicalReservation([string]$Path, [long]$ExpectedLength) {
    $Item = Get-Item -LiteralPath $Path -Force
    $Disallowed = [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed
    if ($Item.Length -ne $ExpectedLength -or ($Item.Attributes -band $Disallowed) -ne 0) {
        throw "audit_reservation_not_physical"
    }
}

function New-PhysicalReservation([string]$Path, [long]$Length) {
    if ($Length -lt 4096 -or [IO.File]::Exists($Path)) { throw "audit_reservation_unavailable" }
    [byte[]]$Buffer = [byte[]]::new(65536)
    for ($Index = 0; $Index -lt $Buffer.Count; $Index++) { $Buffer[$Index] = $script:ReservationFillByte }
    $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::Read, 65536, [IO.FileOptions]::WriteThrough)
    try {
        [long]$Remaining = $Length
        while ($Remaining -gt 0) {
            $Count = [int][Math]::Min($Remaining, $Buffer.Count)
            $Stream.Write($Buffer, 0, $Count); $Remaining -= $Count
        }
        $Stream.Flush($true)
    } finally { $Stream.Dispose() }
    Assert-PhysicalReservation $Path $Length
    Protect-BrokerPath $Path
}

function Consume-AuditReservation([string]$Path, [int]$Bytes) {
    if ($Bytes -lt 1 -or -not [IO.File]::Exists($Path)) { throw "audit_reservation_missing" }
    $Item = Get-Item -LiteralPath $Path -Force
    $Disallowed = [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed
    if (($Item.Attributes -band $Disallowed) -ne 0 -or $Item.Length -lt $Bytes) {
        throw "audit_reservation_missing"
    }
    $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try { $Stream.SetLength($Stream.Length - $Bytes); $Stream.Flush($true) }
    finally { $Stream.Dispose() }
}

function Reconcile-AuditReservation([string]$Path, [long]$ExpectedLength) {
    if ($ExpectedLength -lt 0 -or $ExpectedLength -gt $script:AuditReservationBytes -or
        -not [IO.File]::Exists($Path)) { throw "audit_reservation_drift" }
    $Item = Get-Item -LiteralPath $Path -Force
    $Disallowed = [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed
    if (($Item.Attributes -band $Disallowed) -ne 0 -or $Item.Length -gt $ExpectedLength) {
        throw "audit_reservation_drift"
    }
    if ($Item.Length -lt $ExpectedLength) {
        [byte[]]$Buffer = [byte[]]::new(65536)
        for ($Index = 0; $Index -lt $Buffer.Count; $Index++) { $Buffer[$Index] = $script:ReservationFillByte }
        $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write,
            [IO.FileShare]::Read, 65536, [IO.FileOptions]::WriteThrough)
        try {
            [long]$Remaining = $ExpectedLength - $Item.Length
            while ($Remaining -gt 0) {
                $Count = [int][Math]::Min($Remaining, $Buffer.Count)
                $Stream.Write($Buffer, 0, $Count); $Remaining -= $Count
            }
            $Stream.Flush($true)
        } finally { $Stream.Dispose() }
    }
    Assert-PhysicalReservation $Path $ExpectedLength
}

function Write-TerminalEvidenceInPlace([string]$Path, [byte[]]$JournalBytes) {
    if ($JournalBytes.Count -lt 1 -or $JournalBytes.Count -gt $script:TerminalReservationBytes) {
        throw "terminal_reservation_missing"
    }
    Assert-PhysicalReservation $Path $script:TerminalReservationBytes
    $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try {
        [byte[]]$Observed = [byte[]]::new($script:TerminalReservationBytes)
        $Offset = 0
        while ($Offset -lt $Observed.Count) {
            $Read = $Stream.Read($Observed, $Offset, $Observed.Count - $Offset)
            if ($Read -eq 0) { throw "terminal_reservation_drift" }
            $Offset += $Read
        }
        $Unused = $true
        foreach ($Byte in $Observed) {
            if ($Byte -ne $script:ReservationFillByte) { $Unused = $false; break }
        }
        if ($Unused) {
            $Stream.Position = 0; $Stream.Write($JournalBytes, 0, $JournalBytes.Count); $Stream.Flush($true)
        } else {
            for ($Index = 0; $Index -lt $JournalBytes.Count; $Index++) {
                if ($Observed[$Index] -ne $JournalBytes[$Index]) { throw "terminal_reservation_drift" }
            }
            for ($Index = $JournalBytes.Count; $Index -lt $Observed.Count; $Index++) {
                if ($Observed[$Index] -ne $script:ReservationFillByte) { throw "terminal_reservation_drift" }
            }
        }
    } finally { $Stream.Dispose() }
}

function Reserve-AuditEvidence([string]$AuditRoot, [object]$Request) {
    if ([string]::IsNullOrWhiteSpace($AuditRoot) -or -not [IO.Directory]::Exists($AuditRoot)) {
        throw "audit_reservation_unavailable"
    }
    $RequestId = $Request.Fields.'request-id'
    $AuditPath = Join-Path $AuditRoot ($RequestId + ".audit")
    $AuditReservePath = Join-Path $AuditRoot ($RequestId + ".audit.reserve")
    $TerminalPath = Join-Path $AuditRoot ($RequestId + ".terminal")
    if ([IO.File]::Exists($AuditPath) -or [IO.File]::Exists($AuditReservePath) -or
        [IO.File]::Exists($TerminalPath)) { throw "audit_replay_detected" }
    [byte[]]$Header = ConvertTo-CanonicalAsciiBytes @(
        "windows-broker-audit|1", "request-id|$RequestId", "plan-id|$($Request.Fields.'plan-id')",
        "action-id|$($Request.Fields.'action-id')", "enrollment-epoch|$($Request.Epoch)", "end-audit-header|")
    try {
        $Audit = [IO.FileStream]::new($AuditPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
        try { $Audit.Write($Header, 0, $Header.Count); $Audit.Flush($true) } finally { $Audit.Dispose() }
        Protect-BrokerPath $AuditPath
        New-PhysicalReservation $AuditReservePath $script:AuditReservationBytes
        if ($script:InjectAuditReservationFailureAfterHeader) {
            $script:InjectAuditReservationFailureAfterHeader = $false
            throw "injected_audit_reservation_failure"
        }
        New-PhysicalReservation $TerminalPath $script:TerminalReservationBytes
    } catch {
        foreach ($Path in @($TerminalPath, $AuditReservePath, $AuditPath)) {
            if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
        }
        throw "audit_reservation_unavailable"
    }
    return [pscustomobject]@{ AuditPath = $AuditPath; AuditReservePath = $AuditReservePath;
        TerminalPath = $TerminalPath }
}

function Write-AuditEvent([object]$Request, [string]$State, [string]$Reason, [byte[]]$JournalBytes) {
    if ([string]::IsNullOrWhiteSpace($script:AuditRoot)) { return }
    if ($script:InjectAuditFailureAfterCanonical) {
        $script:InjectAuditFailureAfterCanonical = $false
        throw "injected_post_canonical_audit_failure"
    }
    $RequestId = $Request.Fields.'request-id'
    $AuditPath = Join-Path $script:AuditRoot ($RequestId + ".audit")
    $AuditReservePath = Join-Path $script:AuditRoot ($RequestId + ".audit.reserve")
    $JournalDigest = Get-Sha256Bytes $JournalBytes
    [byte[]]$Event = ConvertTo-CanonicalAsciiBytes @(
        "windows-broker-audit-event|1", "state|$State", "reason|$Reason",
        "journal-sha256|$JournalDigest", "end-audit-event|")
    $AuditHandle = Open-ExclusiveBoundedFile $AuditPath $script:MaximumAuditBytes
    try { $AuditBytes = $AuditHandle.Bytes } finally { $AuditHandle.Stream.Dispose() }
    $AuditText = $script:Ascii.GetString($AuditBytes)
    $HeaderEnd = $AuditText.IndexOf("end-audit-header|`n", [StringComparison]::Ordinal)
    if ($HeaderEnd -lt 0) { throw "audit_state_drift" }
    $HeaderEnd += "end-audit-header|`n".Length
    $ExpectedReserveLength = $script:AuditReservationBytes - ($AuditBytes.Count - $HeaderEnd)
    Reconcile-AuditReservation $AuditReservePath $ExpectedReserveLength
    if (-not $AuditText.Contains("journal-sha256|$JournalDigest`n", [StringComparison]::Ordinal)) {
        if (($AuditBytes.Count + $Event.Count) -gt $script:MaximumAuditBytes) { throw "audit_capacity_exhausted" }
        Consume-AuditReservation $AuditReservePath $Event.Count
        $Stream = [IO.FileStream]::new($AuditPath, [IO.FileMode]::Append, [IO.FileAccess]::Write,
            [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
        try { $Stream.Write($Event, 0, $Event.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
        Reconcile-AuditReservation $AuditReservePath ($ExpectedReserveLength - $Event.Count)
    }
    if ($State -cin @("completed", "partial", "rejected", "stale")) {
        $TerminalPath = Join-Path $script:AuditRoot ($RequestId + ".terminal")
        Write-TerminalEvidenceInPlace $TerminalPath $JournalBytes
    }
}

function Get-ClaimJournalState([string]$ClaimRoot) {
    $Path = Join-Path $ClaimRoot "journal"
    if (-not [IO.File]::Exists($Path)) { return $null }
    [byte[]]$Bytes = [IO.File]::ReadAllBytes($Path)
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 65536 "journal"
    $State = @($Lines | Where-Object { $_ -cmatch '^state\|(validating|executing|verifying|completed|partial|rejected|stale)$' })
    $Reason = @($Lines | Where-Object { $_ -cmatch '^reason\|[a-z][a-z0-9_]{0,127}$' })
    if ($State.Count -ne 1 -or $Reason.Count -ne 1) { throw "replay_state_drift" }
    return [pscustomobject]@{ State = $State[0].Substring(6); Reason = $Reason[0].Substring(7); Bytes = $Bytes }
}

function Write-TerminalTombstone([string]$Path, [string[]]$Tombstone, [string]$State, [long]$Now) {
    $RetainUntil = $Tombstone[2].Split('|')
    $Updated = @($Tombstone)
    $Updated[2] = "retain-until|$([Math]::Max([long]$RetainUntil[1], $Now + $script:TerminalResultRetentionSeconds))"
    $Updated[4] = "state|$State"
    Write-AtomicAscii $Path $Updated
    Protect-BrokerPath $Path
    return $Updated
}

function Compact-ReplayAndAudit([string]$ReplayRoot, [string]$JournalRoot, [string]$AuditRoot, [long]$Now) {
    foreach ($Stage in @([IO.Directory]::EnumerateDirectories($ReplayRoot, ".claim-*"))) {
        [IO.Directory]::Delete($Stage, $true)
    }
    $Claims = @{}
    foreach ($ClaimRoot in @([IO.Directory]::EnumerateDirectories($ReplayRoot, "request-*"))) {
        $RequestId = [IO.Path]::GetFileName($ClaimRoot)
        $Claims[$RequestId] = $ClaimRoot
        $TombstonePath = Join-Path $ClaimRoot "tombstone"
        if (-not [IO.File]::Exists($TombstonePath)) { throw "replay_state_drift" }
        $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($TombstonePath)) 2048 "tombstone"
        if ($Lines.Count -ne 6 -or $Lines[0] -cne "windows-tombstone|1" -or
            $Lines[1] -cne "request-id|$RequestId" -or $Lines[5] -cne "end-tombstone|") {
            throw "replay_state_drift"
        }
        $Until = $Lines[2].Split('|'); $State = $Lines[4].Split('|')
        if ($Until.Count -ne 2 -or $Until[0] -cne "retain-until" -or -not (Test-UInt $Until[1]) -or
            $State.Count -ne 2 -or $State[0] -cne "state" -or
            $State[1] -cnotin @("validating", "executing", "verifying", "completed", "partial", "rejected", "stale")) {
            throw "replay_state_drift"
        }
        $TombstoneState = $State[1]
        $Journal = Get-ClaimJournalState $ClaimRoot
        if ($null -eq $Journal) { throw "replay_state_drift" }
        if ($Journal.State -cin @("completed", "partial", "rejected", "stale")) {
            if ($TombstoneState -cnotin @("completed", "partial", "rejected", "stale")) {
                $Lines = @(Write-TerminalTombstone $TombstonePath $Lines $Journal.State $Now)
                $Until = $Lines[2].Split('|')
                $TombstoneState = $Journal.State
            } elseif ($TombstoneState -cne $Journal.State) {
                throw "replay_state_drift"
            }
        } elseif ($TombstoneState -cin @("completed", "partial", "rejected", "stale")) {
            throw "replay_state_drift"
        }
        if ($TombstoneState -cin @("completed", "partial", "rejected", "stale") -and [long]$Until[1] -le $Now) {
            $TransportAcl = $null
            if (-not [string]::IsNullOrWhiteSpace($script:ResultRoot)) {
                $TransportAcl = Get-TransportAclContract $script:RequestSid
                Assert-FixedResultProjection $script:BrokerRoot $script:PublicRoot $TransportAcl
            }
            $ProtectedJournal = Join-Path $JournalRoot ($RequestId + ".result")
            if ([IO.File]::Exists($ProtectedJournal)) {
                Assert-NonReparsePath $ProtectedJournal $script:BrokerRoot
                if ($IsWindows) { Assert-ExactSddl $ProtectedJournal $script:ProtectedFileSddl }
                [IO.File]::Delete($ProtectedJournal)
            }
            foreach ($Suffix in @(".audit", ".audit.reserve", ".terminal")) {
                $Evidence = Join-Path $AuditRoot ($RequestId + $Suffix)
                if ([IO.File]::Exists($Evidence)) { [IO.File]::Delete($Evidence) }
            }
            if (-not [string]::IsNullOrWhiteSpace($script:ResultRoot)) {
                $PublicResult = Join-Path $script:ResultRoot ($RequestId + ".result")
                if ([IO.File]::Exists($PublicResult)) {
                    Assert-PhysicalTransportFile $PublicResult 4096 $TransportAcl.ResultFile
                    Assert-SanitizedTransportResult $PublicResult $RequestId
                    [IO.File]::Delete($PublicResult)
                }
                $ReadinessResult = Join-Path $script:ResultRoot ($RequestId + ".readiness")
                if ([IO.File]::Exists($ReadinessResult)) {
                    Assert-PhysicalTransportFile $ReadinessResult $script:MaximumReadinessResultBytes `
                        $TransportAcl.ResultFile
                    Assert-SanitizedReadinessResult $ReadinessResult $RequestId
                    [IO.File]::Delete($ReadinessResult)
                }
                Assert-FixedResultProjection $script:BrokerRoot $script:PublicRoot $TransportAcl
            }
            [IO.Directory]::Delete($ClaimRoot, $true)
            [void]$Claims.Remove($RequestId)
        }
    }
    foreach ($Evidence in @([IO.Directory]::EnumerateFiles($AuditRoot, "request-*.*"))) {
        $Name = [IO.Path]::GetFileName($Evidence)
        if ($Name -cnotmatch '^(request-[0-9a-f]{32})\.(audit|audit\.reserve|terminal)$') {
            throw "audit_state_drift"
        }
        if (-not $Claims.ContainsKey($Matches[1])) { [IO.File]::Delete($Evidence) }
    }
    foreach ($ProtectedJournal in @([IO.Directory]::EnumerateFiles($JournalRoot, "request-*.result"))) {
        $Name = [IO.Path]::GetFileName($ProtectedJournal)
        if ($Name -cnotmatch '^(request-[0-9a-f]{32})\.result$') { throw "journal_state_drift" }
        Assert-NonReparsePath $ProtectedJournal $script:BrokerRoot
        if ($IsWindows) { Assert-ExactSddl $ProtectedJournal $script:ProtectedFileSddl }
        if (-not $Claims.ContainsKey($Matches[1])) { [IO.File]::Delete($ProtectedJournal) }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ResultRoot)) {
        $TransportAcl = Get-TransportAclContract $script:RequestSid
        Assert-FixedResultProjection $script:BrokerRoot $script:PublicRoot $TransportAcl
        foreach ($Projection in @([IO.Directory]::EnumerateFiles($script:ResultRoot, "request-*.*"))) {
            $Name = [IO.Path]::GetFileName($Projection)
            if ($Name -cnotmatch '^(request-[0-9a-f]{32})\.(result|readiness)$') {
                throw "transport_unknown_entry"
            }
            if (-not $Claims.ContainsKey($Matches[1])) { [IO.File]::Delete($Projection) }
        }
        Assert-FixedResultProjection $script:BrokerRoot $script:PublicRoot $TransportAcl
    }
}

function Copy-ClaimedBytes([string]$Path, [byte[]]$Bytes, [string]$ExpectedDigest) {
    Write-AtomicBytes $Path $Bytes
    $Copied = [IO.File]::ReadAllBytes($Path)
    if ($Copied.Count -ne $Bytes.Count -or (Get-Sha256Bytes $Copied) -cne $ExpectedDigest) {
        throw "protected_copy_mismatch"
    }
}

function New-Claim {
    param([string]$ReplayRoot, [string]$JournalRoot, [object]$Slot, [long]$Now)
    Compact-ReplayAndAudit $ReplayRoot $JournalRoot $script:AuditRoot $Now
    $Claims = @([IO.Directory]::EnumerateDirectories($ReplayRoot, "request-*", [IO.SearchOption]::TopDirectoryOnly))
    if ($Claims.Count -ge ($script:MaximumClaims - $script:ReservedClaimSlots)) { throw "claim_capacity_exhausted" }
    $RequestId = $Slot.Request.Fields.'request-id'
    $Destination = Join-Path $ReplayRoot $RequestId
    if ([IO.Directory]::Exists($Destination)) { throw "replayed_request" }
    $AuditReservation = $null
    $Stage = $null
    try {
        $AuditReservation = Reserve-AuditEvidence $script:AuditRoot $Slot.Request
        if ($script:InjectClaimFailureAfterReservation) {
            $script:InjectClaimFailureAfterReservation = $false
            throw "injected_claim_failure_after_reservation"
        }
        $Stage = Join-Path $ReplayRoot (".claim-" + $RequestId + "." + [Guid]::NewGuid().ToString("N"))
        [void][IO.Directory]::CreateDirectory($Stage)
        Protect-BrokerPath $Stage $true
        Copy-ClaimedBytes (Join-Path $Stage "request") $Slot.Request.Bytes $Slot.Commit.RequestSha256
        Copy-ClaimedBytes (Join-Path $Stage "request.sig") $Slot.SignatureBytes $Slot.Commit.SignatureSha256
        Copy-ClaimedBytes (Join-Path $Stage "payload") $Slot.PayloadBytes $Slot.Commit.PayloadSha256
        foreach ($Name in @("request", "request.sig", "payload")) { Protect-BrokerPath (Join-Path $Stage $Name) }
        $RetainUntil = $Slot.Request.ExpiresAt + $script:MaximumClockSkewSeconds
        Write-AtomicAscii (Join-Path $Stage "tombstone") @(
            "windows-tombstone|1", "request-id|$RequestId", "retain-until|$RetainUntil",
            "enrollment-epoch|$($Slot.Request.Epoch)", "state|validating", "end-tombstone|")
        Protect-BrokerPath (Join-Path $Stage "tombstone")
        Write-Journal $Stage $JournalRoot $Slot.Request "validating" "claim_reserved" @{}
        [IO.Directory]::Move($Stage, $Destination)
        # The slot's durable commit is consumed only after the moved claim, its
        # tombstone, and the initial journal have been re-opened and verified at
        # their final protected location.
        Assert-DurableClaim $Destination $Slot
        return $Destination
    } catch {
        if (-not [IO.Directory]::Exists($Destination)) {
            if ($null -ne $AuditReservation) {
                foreach ($Path in @($AuditReservation.AuditPath, $AuditReservation.AuditReservePath,
                        $AuditReservation.TerminalPath)) {
                    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
                }
            }
        }
        throw
    } finally {
        if ($null -ne $Stage -and [IO.Directory]::Exists($Stage)) { [IO.Directory]::Delete($Stage, $true) }
    }
}

function Assert-DurableClaim([string]$ClaimRoot, [object]$Slot) {
    $Request = $Slot.Request
    $RequestId = $Request.Fields.'request-id'
    if ([IO.Path]::GetFileName($ClaimRoot) -cne $RequestId -or
        [string]::IsNullOrWhiteSpace($script:BrokerRoot)) { throw "claim_durability_drift" }
    Assert-NonReparsePath $ClaimRoot $script:BrokerRoot
    if ($IsWindows) { Assert-ExactSddl $ClaimRoot $script:ProtectedDirectorySddl }
    foreach ($Path in @($ClaimRoot, (Join-Path $ClaimRoot "request"), (Join-Path $ClaimRoot "request.sig"),
            (Join-Path $ClaimRoot "payload"), (Join-Path $ClaimRoot "tombstone"),
            (Join-Path $ClaimRoot "journal"))) {
        if (-not ([IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path))) { throw "claim_durability_drift" }
        Assert-NonReparsePath $Path $script:BrokerRoot
        if ($IsWindows -and $Path -cne $ClaimRoot) { Assert-ExactSddl $Path $script:ProtectedFileSddl }
    }
    foreach ($Binding in @(
            @("request", $Slot.Commit.RequestSha256, $script:MaximumRequestBytes),
            @("request.sig", $Slot.Commit.SignatureSha256, $script:MaximumSignatureBytes),
            @("payload", $Slot.Commit.PayloadSha256, $script:MaximumPayloadBytes))) {
        $Path = Join-Path $ClaimRoot $Binding[0]
        $Bytes = [IO.File]::ReadAllBytes($Path)
        if ($Bytes.Count -gt [long]$Binding[2] -or (Get-Sha256Bytes $Bytes) -cne $Binding[1]) {
            throw "claim_durability_drift"
        }
    }
    $Tombstone = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes((Join-Path $ClaimRoot "tombstone"))) `
        2048 "tombstone"
    if ($Tombstone.Count -ne 6 -or $Tombstone[0] -cne "windows-tombstone|1" -or
        $Tombstone[1] -cne "request-id|$RequestId" -or $Tombstone[5] -cne "end-tombstone|") {
        throw "claim_durability_drift"
    }
    $RetainUntil = $Tombstone[2].Split('|'); $Epoch = $Tombstone[3].Split('|'); $State = $Tombstone[4].Split('|')
    if ($RetainUntil.Count -ne 2 -or $RetainUntil[0] -cne "retain-until" -or -not (Test-UInt $RetainUntil[1]) -or
        $Epoch.Count -ne 2 -or $Epoch[0] -cne "enrollment-epoch" -or $Epoch[1] -cne [string]$Request.Epoch -or
        $State.Count -ne 2 -or $State[0] -cne "state") { throw "claim_durability_drift" }
    $Journal = Get-ClaimJournalState $ClaimRoot
    if ($State[1] -cne $Journal.State) { throw "claim_durability_drift" }
}

function Consume-ClaimedSlotCommit([object]$Slot, [string]$ClaimRoot) {
    Assert-DurableClaim $ClaimRoot $Slot
    $CommitStream = $Slot.Handles[3].Stream
    if (-not $CommitStream.CanWrite -or $CommitStream.Length -lt 1) { throw "slot_commit_rotation_failed" }
    $CommitStream.SetLength(0); $CommitStream.Flush($true)
    if ($CommitStream.Length -ne 0) { throw "slot_commit_rotation_failed" }
}

function Consume-ExistingClaimedSlotCommit([string]$ReplayRoot, [object]$Slot) {
    $ClaimRoot = Join-Path $ReplayRoot $Slot.Request.Fields.'request-id'
    if (-not [IO.Directory]::Exists($ClaimRoot)) { return $false }
    Assert-DurableClaim $ClaimRoot $Slot
    Consume-ClaimedSlotCommit $Slot $ClaimRoot
    return $true
}

function Write-Journal {
    param([string]$ClaimRoot, [string]$JournalRoot, [object]$Request, [string]$State,
        [string]$Reason, [hashtable]$NativeEvidence)
    if ($State -cnotin @("validating", "executing", "verifying", "completed", "partial", "rejected", "stale") -or
        $Reason -cnotmatch '^[a-z][a-z0-9_]{0,127}$') { throw "invalid_journal_state" }
    $Fields = $Request.Fields
    $Lines = @(
        "windows-broker-result|1", "broker-protocol|$script:BrokerProtocol", "state|$State", "reason|$Reason",
        "request-id|$($Fields.'request-id')", "plan-id|$($Fields.'plan-id')", "action-id|$($Fields.'action-id')",
        "originating-node-id|$($Fields.'node-id')", "node-key-fingerprint|$($Fields.'node-key-fingerprint')",
        "certificate-serial|$($Fields.'certificate-serial')", "fleet-ca-fingerprint|$($Fields.'fleet-ca-fingerprint')",
        "ca-generation|$($Fields.'ca-generation')", "transport|$($Fields.transport)",
        "request-principal|$($Fields.'request-principal')", "required-context|$($Fields.'required-context')",
        "observed-execution-principal|$($Fields.'observed-execution-principal')", "console-session-state|none",
        "platform-boundary|windows", "enrollment-epoch|$($Request.Epoch)",
        "policy-sha256|$($Fields.'policy-sha256')", "constraints-sha256|$($Fields.'constraints-sha256')",
        "winget-context-sha256|$($Fields.'winget-context-sha256')",
        "context-canary-sha256|$($Fields.'context-canary-sha256')",
        "precondition-sha256|$($Fields.'precondition-sha256')",
        "native-state-sha256|$(if ($NativeEvidence.ContainsKey('state')) { $NativeEvidence.state } else { '-' })",
        "native-result-sha256|$(if ($NativeEvidence.ContainsKey('result')) { $NativeEvidence.result } else { '-' })",
        "end-result|"
    )
    [byte[]]$JournalBytes = ConvertTo-CanonicalAsciiBytes $Lines
    $ClaimJournal = Join-Path $ClaimRoot "journal"
    $Prior = Get-ClaimJournalState $ClaimRoot
    if ($null -ne $Prior -and $Prior.State -cin @("completed", "partial", "rejected", "stale")) {
        if ($Prior.State -cne $State -or (Get-Sha256Bytes $Prior.Bytes) -cne (Get-Sha256Bytes $JournalBytes)) {
            throw "terminal_state_absorbing"
        }
        Write-AuditEvent $Request $State $Reason $Prior.Bytes
        return
    }
    Write-AtomicBytes $ClaimJournal $JournalBytes
    Protect-BrokerPath $ClaimJournal
    [void][IO.Directory]::CreateDirectory($JournalRoot)
    Write-AtomicBytes (Join-Path $JournalRoot ($Fields.'request-id' + ".result")) $JournalBytes
    Protect-BrokerPath (Join-Path $JournalRoot ($Fields.'request-id' + ".result"))
    if ($State -cin @("completed", "partial", "rejected", "stale")) {
        $TombstonePath = Join-Path $ClaimRoot "tombstone"
        $Old = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($TombstonePath)) 2048 "tombstone"
        [void](Write-TerminalTombstone $TombstonePath $Old $State ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
    }
    Write-AuditEvent $Request $State $Reason $JournalBytes
}

function Read-LiveProcessIdentity([string]$Path, [string]$ExpectedRequestId) {
    if ($IsWindows) { Assert-ExactSddl $Path $script:ProtectedFileSddl }
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 4096 "live_process_identity"
    $Fields = Read-CanonicalFields $Lines @(
        "request-id", "job-name", "pid", "thread-id", "creation-filetime",
        "executable-path-sha256", "executable-sha256", "state", "exit-code"
    ) "windows-live-process|1" "end-live-process|" "live_process_identity"
    [uint32]$Pid = 0; [uint32]$ThreadId = 0; [uint64]$CreationFileTime = 0
    if ($Fields.'request-id' -cne $ExpectedRequestId -or
        $Fields.'job-name' -cnotmatch '^Global\\MachineUtilitiesBroker-request-[0-9a-f]{32}$' -or
        -not [uint32]::TryParse($Fields.pid, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$Pid) -or $Pid -eq 0 -or
        -not [uint32]::TryParse($Fields.'thread-id', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$ThreadId) -or $ThreadId -eq 0 -or
        -not [uint64]::TryParse($Fields.'creation-filetime', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$CreationFileTime) -or $CreationFileTime -eq 0 -or
        -not (Test-Digest $Fields.'executable-path-sha256') -or
        -not (Test-Digest $Fields.'executable-sha256') -or
        $Fields.state -cnotin @("launch-pending", "active", "recovering", "terminal") -or
        ($Fields.'exit-code' -cne "-" -and $Fields.'exit-code' -notmatch '^-?(0|[1-9][0-9]{0,9})$') -or
        (($Fields.state -ceq "terminal") -ne ($Fields.'exit-code' -cne "-"))) {
        throw "invalid_live_process_identity"
    }
    return [pscustomobject]@{ Fields = $Fields; Lines = $Lines; Pid = $Pid; ThreadId = $ThreadId;
        CreationFileTime = $CreationFileTime }
}

function Set-LiveProcessIdentityState([string]$Path, [object]$Identity, [string]$State) {
    if ($State -cnotin @("active", "recovering")) { throw "invalid_live_process_identity" }
    $Updated = @($Identity.Lines)
    $Updated[8] = "state|$State"
    $Updated[9] = "exit-code|-"
    Write-AtomicAscii $Path $Updated
    Protect-BrokerPath $Path
}

function Get-MissingProfileInstanceDisposition([string]$IdentityState) {
    if ($IdentityState -cnotin @("queued", "active", "recovering")) {
        throw "invalid_profile_operation_identity"
    }
    return [pscustomobject]@{ State = "partial"; Reason = "orphaned_profile_result" }
}

function Read-ProfileActivePointer([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 512 "profile_pointer"
    $Fields = Read-CanonicalFields $Lines @("request-id", "handoff-sha256") `
        "windows-profile-active|1" "end-active|" "profile_pointer"
    if ($Fields.'request-id' -notmatch '^request-[0-9a-f]{32}$' -or
        -not (Test-Digest $Fields.'handoff-sha256')) { throw "invalid_profile_pointer" }
    return [pscustomobject]@{ RequestId = [string]$Fields.'request-id';
        HandoffSha256 = [string]$Fields.'handoff-sha256' }
}

function Remove-MatchingProfileActivePointer([string]$Path, [string]$RequestId) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $false }
    $Pointer = Read-ProfileActivePointer $Path
    if ($Pointer.RequestId -cne $RequestId) { return $false }
    [IO.File]::Delete($Path)
    return $true
}

function Remove-ReadinessProbeArtifacts([string]$ActivePointerPath, [string]$ProbeId,
    [string]$ProbeIdentityPath) {
    [void](Remove-MatchingProfileActivePointer $ActivePointerPath $ProbeId)
    if (-not [IO.File]::Exists($ActivePointerPath) -and -not [string]::IsNullOrWhiteSpace($ProbeIdentityPath) -and
        [IO.File]::Exists($ProbeIdentityPath)) { [IO.File]::Delete($ProbeIdentityPath) }
}

function Assert-ProfileActivePointerAvailable([string]$Path) {
    if ([IO.File]::Exists($Path)) {
        [void](Read-ProfileActivePointer $Path)
        throw "profile_handoff_active"
    }
}

function Get-NativeRepairAction([string]$IdentityState, [int]$Inspection) {
    if ($IdentityState -cnotin @("launch-pending", "active", "recovering") -or
        $Inspection -notin @(0, 1, 2, 3)) { throw "invalid_live_process_identity" }
    if ($Inspection -eq 3) { return "drift" }
    if ($Inspection -eq 0) { return "terminal" }
    if ($IdentityState -ceq "launch-pending" -and $Inspection -eq 1) { return "resume-and-recover" }
    return "recover"
}

function Repair-ConservativeClaims([string]$ReplayRoot, [string]$JournalRoot, [string]$PublicRoot = "",
    [string]$ProfilePointerPath = "", [scriptblock]$ProfileInstanceInspector = $null) {
    $RecoveringClaims = 0
    foreach ($ClaimRoot in [IO.Directory]::EnumerateDirectories($ReplayRoot, "request-*")) {
        $RequestPath = Join-Path $ClaimRoot "request"
        $JournalPath = Join-Path $ClaimRoot "journal"
        if (-not [IO.File]::Exists($RequestPath) -or -not [IO.File]::Exists($JournalPath)) {
            throw "replay_state_drift"
        }
        $Request = Read-BrokerRequest ([IO.File]::ReadAllBytes($RequestPath))
        $IsProfileRequest = -not $Request.Fields.'action-id'.StartsWith("winget.", [StringComparison]::Ordinal)
        $Journal = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($JournalPath)) 65536 "journal"
        $StateLine = @($Journal | Where-Object { $_ -clike "state|*" })
        if ($StateLine.Count -ne 1) { throw "replay_state_drift" }
        $State = $StateLine[0].Substring(6)
        $LiveIdentityPath = Join-Path $ClaimRoot "live.identity"
        $ProfileIdentityPath = Join-Path $ClaimRoot "profile-live.identity"
        $ProfileIdentityRequestId = $Request.Fields.'request-id'
        $ProfilePointerRequestId = $ProfileIdentityRequestId
        $ProbeIdentities = @([IO.Directory]::EnumerateFiles($ClaimRoot, "profile-probe-*.identity"))
        if ($ProbeIdentities.Count -gt 1 -or
            ($ProbeIdentities.Count -eq 1 -and [IO.File]::Exists($ProfileIdentityPath))) {
            throw "live_identity_state_drift"
        }
        if ($ProbeIdentities.Count -eq 1) {
            if (-not $Request.IsReadiness) { throw "live_identity_state_drift" }
            $ProbeMatch = [regex]::Match([IO.Path]::GetFileName($ProbeIdentities[0]),
                '^profile-probe-(request-[0-9a-f]{32})\.identity$')
            if (-not $ProbeMatch.Success) { throw "live_identity_state_drift" }
            $ProfileIdentityPath = $ProbeIdentities[0]
            $ProfileIdentityRequestId = $ProbeMatch.Groups[1].Value
            $ProfilePointerRequestId = $ProfileIdentityRequestId
        }
        if ($State -cin @("validating")) {
            if ([IO.File]::Exists($LiveIdentityPath) -or [IO.File]::Exists($ProfileIdentityPath)) {
                throw "live_identity_state_drift"
            }
            Write-Journal $ClaimRoot $JournalRoot $Request "stale" "broker_died_before_native" @{}
        } elseif ($State -cin @("executing", "verifying")) {
            $HasNativeIdentity = [IO.File]::Exists($LiveIdentityPath)
            $HasProfileIdentity = [IO.File]::Exists($ProfileIdentityPath)
            if ($HasNativeIdentity -and $HasProfileIdentity) { throw "live_identity_state_drift" }
            if (-not $HasNativeIdentity -and -not $HasProfileIdentity) {
                if ($IsProfileRequest) {
                    # The queued identity is durable before Task.Run. Its absence proves the explicit
                    # scheduler launch was not crossed, so this request must never be replayed.
                    Write-Journal $ClaimRoot $JournalRoot $Request "stale" "broker_died_before_profile_run" @{}
                } else {
                    Write-Journal $ClaimRoot $JournalRoot $Request "partial" "orphaned_native_state" @{}
                }
            } elseif ($HasNativeIdentity) {
                $Identity = Read-LiveProcessIdentity $LiveIdentityPath $Request.Fields.'request-id'
                if ($Identity.Fields.state -ceq "terminal") {
                    Write-Journal $ClaimRoot $JournalRoot $Request "partial" "orphaned_native_result" @{}
                } else {
                    Initialize-ProcessContainmentTypes
                    $Inspection = [MachineUtilitiesJob]::Inspect($Identity.Fields.'job-name', $Identity.Pid,
                        $Identity.CreationFileTime)
                    $RepairAction = Get-NativeRepairAction $Identity.Fields.state $Inspection
                    if ($RepairAction -ceq "drift") { throw "live_process_identity_drift" }
                    if ($RepairAction -ceq "terminal") {
                        Write-Journal $ClaimRoot $JournalRoot $Request "partial" "orphaned_native_result" @{}
                    } else {
                        if ($RepairAction -ceq "resume-and-recover") {
                            [void][MachineUtilitiesSuspendedProcess]::ResumeIdentifiedThread(
                                $Identity.Pid, $Identity.ThreadId)
                        }
                        # Inspection 2 means the identified leader already exited while a descendant
                        # keeps the named job live. That is proof the launch crossed Resume even if the
                        # active-state rewrite was interrupted; preserve the descendant operation.
                        Set-LiveProcessIdentityState $LiveIdentityPath $Identity "recovering"
                        Write-Journal $ClaimRoot $JournalRoot $Request "executing" "native_recovering" @{}
                        if (-not $Request.IsReadiness -and -not [string]::IsNullOrWhiteSpace($PublicRoot)) {
                            Write-PublicResult $PublicRoot "active" $Request "executing" "native_recovering"
                        }
                        $RecoveringClaims++
                    }
                }
            } else {
                $Identity = Read-ProfileOperationIdentity $ProfileIdentityPath $ProfileIdentityRequestId
                if ($Identity.Fields.state -ceq "terminal") {
                    Write-Journal $ClaimRoot $JournalRoot $Request "partial" "orphaned_profile_result" @{}
                } else {
                    $LiveInstance = if ($null -eq $ProfileInstanceInspector) {
                        Get-ProfileTaskLiveInstance $Identity.Fields.'instance-guid'
                    } else { & $ProfileInstanceInspector $Identity.Fields.'instance-guid' }
                    if ($null -eq $LiveInstance) {
                        # Queued is deliberately written before the scheduler RPC. A crash can occur
                        # after submission and after a short task has already exited but before the
                        # instance GUID is durable, so absence of a live instance never proves that
                        # no profile mutation occurred.
                        $Disposition = Get-MissingProfileInstanceDisposition $Identity.Fields.state
                        Write-Journal $ClaimRoot $JournalRoot $Request $Disposition.State $Disposition.Reason @{}
                    } else {
                        Set-ProfileOperationIdentityState $ProfileIdentityPath $Identity $LiveInstance "recovering"
                        Write-Journal $ClaimRoot $JournalRoot $Request "executing" "profile_operation_recovering" @{}
                        if (-not $Request.IsReadiness -and -not [string]::IsNullOrWhiteSpace($PublicRoot)) {
                            Write-PublicResult $PublicRoot "active" $Request "executing" `
                                "profile_operation_recovering"
                        }
                        $RecoveringClaims++
                    }
                }
            }
        } elseif ($State -cin @("completed", "partial", "rejected", "stale")) {
            $Observed = Get-ClaimJournalState $ClaimRoot
            Write-AtomicBytes (Join-Path $JournalRoot ($Request.Fields.'request-id' + ".result")) $Observed.Bytes
            Write-AuditEvent $Request $Observed.State $Observed.Reason $Observed.Bytes
        }
        if (-not $Request.IsReadiness -and -not [string]::IsNullOrWhiteSpace($PublicRoot)) {
            $Terminal = Get-ClaimJournalState $ClaimRoot
            if ($null -ne $Terminal -and $Terminal.State -cin @("completed", "partial", "rejected", "stale")) {
                Write-PublicResult $PublicRoot "last" $Request $Terminal.State $Terminal.Reason `
                    (Get-Sha256Bytes $Terminal.Bytes)
            }
        }
        $Terminal = Get-ClaimJournalState $ClaimRoot
        if (-not [string]::IsNullOrWhiteSpace($ProfilePointerPath) -and
            $IsProfileRequest -and
            $null -ne $Terminal -and $Terminal.State -cin @("completed", "partial", "rejected", "stale")) {
            [void](Remove-MatchingProfileActivePointer $ProfilePointerPath $ProfilePointerRequestId)
        }
    }
    if ($RecoveringClaims -gt 1) { throw "multiple_live_operations" }
    return $RecoveringClaims -eq 1
}

function Get-HelperRequestBytes([object]$Request, [string]$ProviderLockSha256) {
    if (-not (Test-Digest $Request.Fields.'winget-context-sha256') -or
        -not (Test-Digest $ProviderLockSha256)) {
        throw "invalid_helper_request_binding"
    }
    $Fields = $Request.Fields
    return ConvertTo-CanonicalAsciiBytes @(
        "winget-helper-request|1", "request-id|$($Fields.'request-id')", "action-id|$($Fields.'action-id')",
        "policy-token|$($Fields.'policy-token')", "enrollment-epoch|$($Request.Epoch)",
        "policy-sha256|$($Fields.'policy-sha256')", "constraints-sha256|$($Fields.'constraints-sha256')",
        "winget-context-sha256|$($Fields.'winget-context-sha256')",
        "provider-lock-sha256|$ProviderLockSha256", "precondition-sha256|$($Fields.'precondition-sha256')",
        "end-request|")
}

function Get-ReadinessProbeRequestId([object]$ControlRequest, [string]$ActionId, [string]$PolicyToken) {
    if ($ControlRequest.Fields.'request-id' -cnotmatch '^request-[0-9a-f]{32}$' -or
        -not (Test-Token $ActionId) -or ($PolicyToken -cne "-" -and -not (Test-Token $PolicyToken))) {
        throw "invalid_readiness_probe_binding"
    }
    $Digest = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes @(
        "machine-utilities-readiness-probe-id|1", "control-request-id|$($ControlRequest.Fields.'request-id')",
        "action-id|$ActionId", "policy-token|$PolicyToken", "end-probe-id|"))
    return "request-" + $Digest.Substring(0, 32)
}

function New-ReadinessProbeRequest([object]$ControlRequest, [object]$Generation, [string]$ActionId,
    [string]$PolicyToken, [string]$Context, [string]$PreconditionSha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    [string]$ProbeRequestId = "") {
    if ($ActionId -cnotin @("profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1",
            "winget.install-machine-package.v1", "winget.inventory-machine.v1", "winget.upgrade-machine-package.v1") -or
        $Context -cnotin @("windows-system-v1", "windows-user-s4u-v1") -or
        ($ActionId -ceq "winget.inventory-machine.v1" -and $PolicyToken -cne "-") -or
        ($ActionId -cne "winget.inventory-machine.v1" -and -not (Test-Token $PolicyToken)) -or
        -not (Test-Digest $PreconditionSha256)) { throw "invalid_readiness_probe_binding" }
    if ([string]::IsNullOrWhiteSpace($ProbeRequestId)) { $ProbeRequestId = $ControlRequest.Fields.'request-id' }
    if ($ProbeRequestId -cnotmatch '^request-[0-9a-f]{32}$') { throw "invalid_readiness_probe_binding" }
    $Fields = [ordered]@{
        "request-id" = $ProbeRequestId
        "action-id" = $ActionId
        "policy-token" = $PolicyToken
        "policy-sha256" = $Generation.Digests.Policy
        "constraints-sha256" = $Generation.Digests.Constraints
        "winget-context-sha256" = $Generation.Digests.Context
        "payload-sha256" = $script:EmptySha256
        "precondition-sha256" = $PreconditionSha256
        "manager-source-identity" = "not-applicable"
    }
    return [pscustomobject]@{
        Fields = $Fields; Epoch = [int]$Generation.Epoch; PayloadLength = 0; IsReadinessProbe = $true
    }
}

function Get-EnabledWinGetReadinessBindings([object]$Generation) {
    $PolicyLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Policy)) 65536 "policy"
    $ConstraintLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Constraints)) 4194304 "constraints"
    $Actions = @("winget.install-machine-package.v1", "winget.inventory-machine.v1", "winget.upgrade-machine-package.v1")
    $Bindings = New-Object Collections.Generic.List[object]
    foreach ($Action in $Actions) {
        $Matches = @($PolicyLines | Where-Object {
            $Parts = $_.Split('|'); $Parts.Count -eq 6 -and $Parts[0] -ceq "action" -and $Parts[1] -ceq $Action
        })
        if ($Matches.Count -ne 1) { throw "invalid_readiness_policy" }
        $Policy = $Matches[0].Split('|')
        if ($Policy[2] -cne "windows-system-v1" -or $Policy[3] -cnotin @("enabled", "disabled") -or
            -not (Test-Token $Policy[4]) -or -not (Test-Digest $Policy[5])) { throw "invalid_readiness_policy" }
        if ($Policy[3] -cne "enabled") { continue }
        if ($Action -ceq "winget.inventory-machine.v1") {
            [void]$Bindings.Add([pscustomobject]@{ Action = $Action; Token = "-"; Context = "windows-system-v1" })
            continue
        }
        $Prefix = if ($Action -ceq "winget.install-machine-package.v1") { "winget-install" } else { "winget-upgrade" }
        $ExpectedCount = if ($Prefix -ceq "winget-install") { 14 } else { 16 }
        $Tokens = @{}
        foreach ($Line in $ConstraintLines) {
            $Parts = $Line.Split('|')
            if ($Parts.Count -lt 2 -or $Parts[0] -cne $Prefix -or $Parts[1] -cne $Action) { continue }
            if ($Parts.Count -ne $ExpectedCount -or -not (Test-Token $Parts[2]) -or $Tokens.ContainsKey($Parts[2])) {
                throw "invalid_readiness_constraints"
            }
            $Tokens[$Parts[2]] = $true
            [void]$Bindings.Add([pscustomobject]@{ Action = $Action; Token = $Parts[2]; Context = "windows-system-v1" })
        }
        if ($Tokens.Count -eq 0) { throw "readiness_enabled_action_without_token" }
    }
    if ($Bindings.Count -gt $script:MaximumReadinessProbeBindings) { throw "readiness_probe_capacity_exceeded" }
    return @($Bindings | Sort-Object @{ Expression = { "$($_.Action)|$($_.Token)" }; Ascending = $true })
}

function Get-EnabledProfileReadinessBindings([object]$Generation) {
    $PolicyLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Policy)) 65536 "policy"
    $ConstraintLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Constraints)) 4194304 "constraints"
    $Actions = New-Object Collections.Generic.List[string]
    foreach ($Action in @("profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1")) {
        $Matches = @($PolicyLines | Where-Object {
            $Parts = $_.Split('|'); $Parts.Count -eq 6 -and $Parts[0] -ceq "action" -and $Parts[1] -ceq $Action
        })
        if ($Matches.Count -ne 1) { throw "invalid_readiness_policy" }
        $Policy = $Matches[0].Split('|')
        if ($Policy[2] -cne "windows-user-s4u-v1" -or $Policy[3] -cnotin @("enabled", "disabled") -or
            $Policy[4] -cne "profile-bundle-set-sha256" -or -not (Test-Digest $Policy[5])) {
            throw "invalid_readiness_policy"
        }
        if ($Policy[3] -ceq "enabled") { [void]$Actions.Add($Action) }
    }
    if ($Actions.Count -eq 0) { return @() }
    $Tokens = New-Object Collections.Generic.List[string]; $Seen = @{}
    foreach ($Line in $ConstraintLines) {
        $Parts = $Line.Split('|')
        if ($Parts[0] -cne "profile") { continue }
        if ($Parts.Count -ne 9 -or -not (Test-Token $Parts[1]) -or $Seen.ContainsKey($Parts[1]) -or
            $Parts[2] -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
            @($Parts[3], $Parts[4], $Parts[5] | Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
            $Parts[6] -cnotin @("managed-only", "managed-and-prune") -or
            -not (Test-UInt $Parts[7]) -or -not (Test-UInt $Parts[8])) { throw "invalid_readiness_constraints" }
        $Seen[$Parts[1]] = $true; [void]$Tokens.Add($Parts[1])
    }
    if ($Tokens.Count -eq 0) { throw "readiness_enabled_action_without_token" }
    $Bindings = New-Object Collections.Generic.List[object]
    foreach ($Action in $Actions) {
        foreach ($Token in $Tokens) {
            [void]$Bindings.Add([pscustomobject]@{ Action = $Action; Token = $Token; Context = "windows-user-s4u-v1" })
        }
    }
    if ($Bindings.Count -gt $script:MaximumReadinessProbeBindings) { throw "readiness_probe_capacity_exceeded" }
    return @($Bindings | Sort-Object @{ Expression = { "$($_.Action)|$($_.Token)" }; Ascending = $true })
}

function Read-WinGetPreconditionProbe([byte[]]$Bytes, [object]$Request, [int]$ExitCode) {
    if ($ExitCode -ne 0) { throw "winget_precondition_probe_failed" }
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "winget_precondition_probe"
    $Expected = @(
        "winget-precondition-probe|1", "request-id|$($Request.Fields.'request-id')",
        "action-id|$($Request.Fields.'action-id')", "policy-token|$($Request.Fields.'policy-token')",
        "precondition-sha256|")
    if ($Lines.Count -ne 6 -or $Lines[0] -cne $Expected[0] -or $Lines[1] -cne $Expected[1] -or
        $Lines[2] -cne $Expected[2] -or $Lines[3] -cne $Expected[3] -or $Lines[-1] -cne "end-precondition-probe|") {
        throw "invalid_winget_precondition_probe"
    }
    $Parts = $Lines[4].Split('|')
    if ($Parts.Count -ne 2 -or $Parts[0] -cne "precondition-sha256" -or -not (Test-Digest $Parts[1])) {
        throw "invalid_winget_precondition_probe"
    }
    return [pscustomobject]@{ PreconditionSha256 = $Parts[1]; Sha256 = Get-Sha256Bytes $Bytes }
}

function Read-WinGetProviderContext([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 16384 "winget_provider_context"
    $Fields = Read-CanonicalFields $Lines @(
        "state-identifier", "source-id", "source-name", "source-type", "source-argument",
        "source-argument-sha256", "source-origin", "source-trust", "source-explicit",
        "source-last-update-min-unix", "deployment-file-set-sha256", "app-installer-identity-sha256"
    ) "winget-provider-context|1" "end-context|" "winget_provider_context"
    [long]$LastUpdateMinimum = 0
    $SourceArgument = [string]$Fields.'source-argument'
    $Uri = $null
    try { $Uri = [Uri]::new($SourceArgument, [UriKind]::Absolute) } catch { throw "invalid_winget_provider_context" }
    if ($Fields.'state-identifier' -cnotmatch '^machine-utilities-e[1-9][0-9]{0,9}-[0-9a-f]{64}$' -or
        -not (Test-Atom $Fields.'source-id') -or -not (Test-Atom $Fields.'source-name') -or
        $Fields.'source-type' -cnotin @("Microsoft.Rest", "Microsoft.PreIndexed.Package") -or
        $SourceArgument -notmatch '^[\x21-\x7e]{1,2048}$' -or
        -not $Uri.IsAbsoluteUri -or -not $SourceArgument.Equals($Uri.AbsoluteUri, [StringComparison]::Ordinal) -or
        $Uri.Scheme -cne "https" -or $Uri.UserInfo.Length -ne 0 -or
        $Uri.Query.Length -ne 0 -or $Uri.Fragment.Length -ne 0 -or $Uri.Port -ne 443 -or
        [Uri]::CheckHostName($Uri.Host) -notin @([UriHostNameType]::Dns, [UriHostNameType]::IPv4,
            [UriHostNameType]::IPv6) -or
        -not (Test-Digest $Fields.'source-argument-sha256') -or
        (Get-Sha256Utf8Text $SourceArgument) -cne $Fields.'source-argument-sha256' -or
        $Fields.'source-origin' -cnotin @("predefined", "user") -or
        $Fields.'source-trust' -cnotin @("none", "trusted") -or
        $Fields.'source-explicit' -cnotin @("true", "false") -or
        -not (Test-CanonicalNonNegativeInt64 $Fields.'source-last-update-min-unix') -or
        -not [long]::TryParse($Fields.'source-last-update-min-unix',
            [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture,
            [ref]$LastUpdateMinimum) -or $LastUpdateMinimum -lt 0 -or
        -not (Test-Digest $Fields.'deployment-file-set-sha256') -or
        -not (Test-Digest $Fields.'app-installer-identity-sha256')) {
        throw "invalid_winget_provider_context"
    }
    return [pscustomobject]@{
        StateIdentifier = [string]$Fields.'state-identifier'
        SourceId = [string]$Fields.'source-id'; SourceName = [string]$Fields.'source-name'
        SourceType = [string]$Fields.'source-type'; SourceArgument = $SourceArgument
        SourceArgumentSha256 = [string]$Fields.'source-argument-sha256'
        SourceOrigin = [string]$Fields.'source-origin'; SourceTrust = [string]$Fields.'source-trust'
        SourceExplicit = [string]$Fields.'source-explicit'; SourceLastUpdateMinimum = $LastUpdateMinimum
        DeploymentFileSetSha256 = [string]$Fields.'deployment-file-set-sha256'
        AppInstallerIdentitySha256 = [string]$Fields.'app-installer-identity-sha256'
    }
}

function Get-WinGetStateAuthoritySha256([int]$Epoch, [object]$Generation, [object]$ProviderContext) {
    return Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes @(
        "machine-utilities-winget-state-authority|1", "epoch|$Epoch",
        "policy-sha256|$($Generation.Digests.Policy)",
        "constraints-sha256|$($Generation.Digests.Constraints)",
        "provider-lock-sha256|$($Generation.Digests.ProviderLock)",
        "source-id|$($ProviderContext.SourceId)", "source-name|$($ProviderContext.SourceName)",
        "source-type|$($ProviderContext.SourceType)",
        "source-argument-sha256|$($ProviderContext.SourceArgumentSha256)",
        "source-origin|$($ProviderContext.SourceOrigin)", "source-trust|$($ProviderContext.SourceTrust)",
        "source-explicit|$($ProviderContext.SourceExplicit)",
        "source-last-update-min-unix|$($ProviderContext.SourceLastUpdateMinimum)",
        "deployment-file-set-sha256|$($ProviderContext.DeploymentFileSetSha256)",
        "app-installer-identity-sha256|$($ProviderContext.AppInstallerIdentitySha256)",
        "end-state-authority|"))
}

function Get-WinGetExpectedSettingsSha256([object]$Request, [object]$Generation) {
    $Requirements = '"scope":"machine"'
    if ($Request.Fields.'action-id' -cne "winget.inventory-machine.v1") {
        $Prefix = if ($Request.Fields.'action-id' -ceq "winget.install-machine-package.v1") {
            "winget-install"
        } elseif ($Request.Fields.'action-id' -ceq "winget.upgrade-machine-package.v1") {
            "winget-upgrade"
        } else { throw "invalid_winget_action" }
        $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Constraints)) `
            4194304 "constraints"
        $Matches = @($Lines | Where-Object {
            $Parts = $_.Split('|')
            $Parts.Count -ge 3 -and $Parts[0] -ceq $Prefix -and
                $Parts[1] -ceq $Request.Fields.'action-id' -and $Parts[2] -ceq $Request.Fields.'policy-token'
        })
        if ($Matches.Count -ne 1) { throw "invalid_winget_constraints" }
        $Fields = $Matches[0].Split('|')
        $ExpectedCount = if ($Prefix -ceq "winget-install") { 14 } else { 16 }
        $InstallerTypes = if ($Fields.Count -eq $ExpectedCount) { @($Fields[10].Split(',')) } else { @() }
        $AllowedInstallerTypes = @("burn", "exe", "inno", "msi", "msix", "nullsoft", "portable", "wix", "zip")
        if ($Fields.Count -ne $ExpectedCount -or $Fields[7] -cne "machine" -or
            $Fields[8] -cnotin @("x86", "x64", "arm", "arm64", "neutral") -or
            $Fields[9] -notmatch '^[A-Za-z][A-Za-z0-9-]{1,19}$' -or $InstallerTypes.Count -lt 1 -or
            @($InstallerTypes | Where-Object { $AllowedInstallerTypes -cnotcontains $_ }).Count -ne 0 -or
            (@($InstallerTypes | Sort-Object -Unique) -join ',') -cne ($InstallerTypes -join ',')) {
            throw "invalid_winget_constraints"
        }
        $QuotedTypes = ($InstallerTypes | ForEach-Object { '"' + $_ + '"' }) -join ','
        $Requirements += ',"architectures":["' + $Fields[8] + '"],"locale":["' + $Fields[9] +
            '"],"installerTypes":[' + $QuotedTypes + ']'
    }
    $Settings = '{"$schema":"https://aka.ms/winget-settings.schema.json","source":{' +
        '"autoUpdateIntervalInMinutes":0},"interactivity":{"disable":true},"installBehavior":{' +
        '"skipDependencies":false,"requirements":{' + $Requirements + '}},"experimentalFeatures":{"resume":false}}'
    return Get-Sha256Bytes ([Text.Encoding]::UTF8.GetBytes($Settings))
}

function Read-WinGetModuleLock([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "winget_module_lock"
    if ($Lines.Count -lt 10 -or $Lines[0] -cne "winget-module-lock|1" -or
        $Lines[-1] -cne "end-lock|") { throw "invalid_winget_module_lock" }
    $Scalar = [ordered]@{}; $Files = [ordered]@{}; $Signatures = [ordered]@{}
    foreach ($Line in @($Lines | Select-Object -Skip 1 | Select-Object -SkipLast 1)) {
        $Parts = $Line.Split('|')
        if ($Parts.Count -lt 2) { throw "invalid_winget_module_lock" }
        switch -CaseSensitive ($Parts[0]) {
            { $_ -cin @("module", "version", "package-url", "package-sha256") } {
                if ($Parts.Count -ne 2 -or $Scalar.Contains($_)) { throw "invalid_winget_module_lock" }
                $Scalar[$_] = $Parts[1]
            }
            "manifest" {
                if ($Parts.Count -ne 3 -or $Scalar.Contains("manifest") -or -not (Test-Digest $Parts[2])) {
                    throw "invalid_winget_module_lock"
                }
                $Scalar.manifest = $Parts[1]; $Scalar.'manifest-sha256' = $Parts[2]
            }
            "signature" {
                if ($Parts.Count -ne 3 -or $Parts[2] -cne "Microsoft Corporation" -or
                    $Signatures.Contains($Parts[1])) { throw "invalid_winget_module_lock" }
                $Signatures[$Parts[1]] = $Parts[2]
            }
            "file" {
                if ($Parts.Count -ne 3 -or $Files.Contains($Parts[1]) -or -not (Test-Digest $Parts[2])) {
                    throw "invalid_winget_module_lock"
                }
                $Files[$Parts[1]] = $Parts[2]
            }
            default { throw "invalid_winget_module_lock" }
        }
    }
    foreach ($Name in @("module", "version", "package-url", "package-sha256", "manifest", "manifest-sha256")) {
        if (-not $Scalar.Contains($Name)) { throw "invalid_winget_module_lock" }
    }
    if ($Scalar.module -cne "Microsoft.WinGet.Client" -or $Scalar.version -cne "1.29.280" -or
        -not (Test-Digest $Scalar.'package-sha256') -or $Scalar.manifest -cne "Microsoft.WinGet.Client.psd1" -or
        $Files.Count -lt 1 -or -not $Files.Contains($Scalar.manifest) -or
        $Files[$Scalar.manifest] -cne $Scalar.'manifest-sha256') { throw "invalid_winget_module_lock" }
    foreach ($Path in @($Files.Keys) + @($Signatures.Keys)) {
        if ($Path -notmatch '^[A-Za-z0-9._/\[\]-]+$' -or $Path.Contains('\') -or
            [IO.Path]::IsPathRooted($Path) -or $Path -match '(^|/)\.\.?(?:/|$)' -or
            ($Signatures.Contains($Path) -and -not $Files.Contains($Path))) {
            throw "invalid_winget_module_lock"
        }
    }
    return [pscustomobject]@{ Module = $Scalar.module; Version = $Scalar.version
        Manifest = $Scalar.manifest; Files = $Files; Signatures = $Signatures }
}

function Open-ProtectedWinGetModule([string]$Root, [object]$Generation, [switch]$Import) {
    $Lock = Read-WinGetModuleLock ([IO.File]::ReadAllBytes($Generation.Files.ProviderLock))
    $ModuleRoot = Join-Path $Generation.Root "winget/Microsoft.WinGet.Client"
    Assert-NonReparsePath $ModuleRoot $Root
    $Observed = [ordered]@{}
    foreach ($Path in [IO.Directory]::EnumerateFiles($ModuleRoot, "*", [IO.SearchOption]::AllDirectories)) {
        Assert-NonReparsePath $Path $Root
        $Relative = [IO.Path]::GetRelativePath($ModuleRoot, $Path).Replace('\', '/')
        if ($Observed.Contains($Relative)) { throw "winget_module_file_set_mismatch" }
        $Observed[$Relative] = Get-HeldFileSha256 $Path 268435456
    }
    if ($Observed.Count -ne $Lock.Files.Count) { throw "winget_module_file_set_mismatch" }
    foreach ($Entry in $Lock.Files.GetEnumerator()) {
        if (-not $Observed.Contains($Entry.Key) -or $Observed[$Entry.Key] -cne $Entry.Value) {
            throw "winget_module_file_hash_mismatch"
        }
    }
    $FileSetBytes = ConvertTo-CanonicalAsciiBytes (@("winget-module-files|1") + @(
        $Lock.Files.GetEnumerator() | ForEach-Object { "file|$($_.Key)|$($_.Value)" }) + @("end-files|"))
    $IdentityBytes = ConvertTo-CanonicalAsciiBytes (@("winget-module-publishers|1") + @(
        $Lock.Signatures.GetEnumerator() | ForEach-Object { "signature|$($_.Key)|$($_.Value)" }) + @("end-publishers|"))
    $FileSetSha256 = Get-Sha256Bytes $FileSetBytes
    $IdentitySha256 = Get-Sha256Bytes $IdentityBytes
    if ($Generation.ProviderContext.DeploymentFileSetSha256 -cne $FileSetSha256 -or
        $Generation.ProviderContext.AppInstallerIdentitySha256 -cne $IdentitySha256) {
        throw "deployment_identity_drift"
    }
    $ManifestPath = Join-Path $ModuleRoot $Lock.Manifest
    if ($Import) {
        Remove-Module -Name $Lock.Module -Force -ErrorAction SilentlyContinue
        Import-Module -Name $ManifestPath -Force -ErrorAction Stop
        $Loaded = @(Get-Module -Name $Lock.Module)
        if ($Loaded.Count -ne 1 -or [string]$Loaded[0].Version -cne $Lock.Version -or
            -not [IO.Path]::GetFullPath($Loaded[0].Path).Equals([IO.Path]::GetFullPath($ManifestPath),
                [StringComparison]::OrdinalIgnoreCase)) { throw "winget_module_identity_drift" }
        $Sources = @(Microsoft.WinGet.Client\Get-WinGetSource -Name $Generation.ProviderContext.SourceName -ErrorAction Stop)
        if ($Sources.Count -ne 1 -or $Sources[0].Name -cne $Generation.ProviderContext.SourceName -or
            $Sources[0].Type -cne $Generation.ProviderContext.SourceType -or
            $Sources[0].Argument -cne $Generation.ProviderContext.SourceArgument -or
            (Get-Sha256Utf8Text ([string]$Sources[0].Argument)) -cne
                $Generation.ProviderContext.SourceArgumentSha256 -or
            ([string]$Sources[0].TrustLevel).ToLowerInvariant() -cne $Generation.ProviderContext.SourceTrust -or
            ([bool]$Sources[0].Explicit).ToString().ToLowerInvariant() -cne
                $Generation.ProviderContext.SourceExplicit) { throw "winget_source_evidence_mismatch" }
    }
    return [pscustomobject]@{ Lock = $Lock; ManifestPath = $ManifestPath; FileSetSha256 = $FileSetSha256
        IdentitySha256 = $IdentitySha256; Version = $Lock.Version }
}

function Get-WinGetModuleConstraint([object]$Request, [object]$Generation) {
    if ($Request.Fields.'action-id' -ceq "winget.inventory-machine.v1") { return $null }
    [void](Get-WinGetExpectedSettingsSha256 $Request $Generation)
    $Prefix = if ($Request.Fields.'action-id' -ceq "winget.install-machine-package.v1") {
        "winget-install"
    } elseif ($Request.Fields.'action-id' -ceq "winget.upgrade-machine-package.v1") {
        "winget-upgrade"
    } else { throw "invalid_winget_action" }
    $Matches = @(ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Constraints)) `
        4194304 "constraints" | Where-Object {
            $Parts = $_.Split('|'); $Parts.Count -ge 3 -and $Parts[0] -ceq $Prefix -and
                $Parts[1] -ceq $Request.Fields.'action-id' -and $Parts[2] -ceq $Request.Fields.'policy-token'
        })
    if ($Matches.Count -ne 1) { throw "invalid_winget_constraints" }
    $Fields = $Matches[0].Split('|')
    if ($Fields[8] -ceq "neutral") { throw "unsupported_architecture" }
    if ($Fields[10].Contains(',')) { throw "unsupported_installer_type_set" }
    return $Fields
}

function Get-WinGetSourceStateSha256([object]$Context) {
    return Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes @(
        "source-state|2", "source|$($Context.SourceId)|$($Context.SourceName)|$($Context.SourceType)|" +
            "$($Context.SourceArgumentSha256)|$($Context.SourceOrigin)|$($Context.SourceTrust)|$($Context.SourceExplicit)",
        "end-source-state|"))
}

function Get-WinGetPackageStateSha256([string]$PackageId, [string]$InstalledVersion,
    [string]$CandidateVersion, [string]$Architecture, [string]$Locale, [string]$InstallerType,
    [string]$SourceStateSha256) {
    foreach ($Value in @($PackageId, $InstalledVersion, $CandidateVersion, $Architecture, $Locale, $InstallerType)) {
        if (-not (Test-ResultAtomOrDash $Value)) { throw "invalid_winget_package_state" }
    }
    if (-not (Test-Digest $SourceStateSha256)) { throw "invalid_winget_package_state" }
    return Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes @(
        "winget-package-state|1",
        "package|$PackageId|$InstalledVersion|$CandidateVersion|machine|$Architecture|$Locale|$InstallerType",
        "source-state-sha256|$SourceStateSha256", "end-package-state|"))
}

function Resolve-WinGetModulePackage([object]$Generation, [string[]]$Constraint) {
    $Id = $Constraint[3]; $Source = $Constraint[4]
    $Found = @(Microsoft.WinGet.Client\Find-WinGetPackage -Id $Id -Source $Source `
        -MatchOption EqualsCaseInsensitive -ErrorAction Stop)
    if ($Found.Count -ne 1 -or $Found[0].Id -cne $Id -or $Found[0].Source -cne $Source) {
        throw "ambiguous_package"
    }
    $Installed = @(Microsoft.WinGet.Client\Get-WinGetPackage -Id $Id -Source $Source `
        -MatchOption EqualsCaseInsensitive -ErrorAction Stop)
    if ($Installed.Count -gt 1 -or ($Installed.Count -eq 1 -and $Installed[0].Id -cne $Id)) {
        throw "installed_state_drift"
    }
    $InstalledVersion = if ($Installed.Count -eq 1) { [string]$Installed[0].InstalledVersion } else { "-" }
    if ($Constraint[0] -ceq "winget-install") {
        $Candidate = $Constraint[11]
        if ($Found[0].AvailableVersions -cnotcontains $Candidate) { throw "unsupported_version" }
    } else {
        if ($Installed.Count -ne 1) { throw "package_state_drift" }
        $Candidate = $null; $SelectedInfo = $null
        foreach ($Version in @($Found[0].AvailableVersions)) {
            if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9.+:_~-]{0,127}$') { continue }
            $Info = $Found[0].GetPackageVersionInfo($Version)
            if ($Info.CompareToVersion($Constraint[11]) -ceq "Lesser" -or
                $Info.CompareToVersion($Constraint[12]) -ceq "Greater") { continue }
            [int]$Major = 0
            if ($Version -notmatch '^([0-9]{1,10})(?:[.+:_~-]|$)' -or
                -not [int]::TryParse($Matches[1], [ref]$Major) -or $Major -gt [int]$Constraint[13]) { continue }
            if ($null -eq $SelectedInfo -or $SelectedInfo.CompareToVersion($Version) -ceq "Lesser") {
                $Candidate = $Version; $SelectedInfo = $Info
            }
        }
        if ($null -eq $Candidate -or $Installed[0].CompareToVersion($Candidate) -cne "Lesser") {
            throw "unsupported_version"
        }
    }
    $SourceState = Get-WinGetSourceStateSha256 $Generation.ProviderContext
    $PreState = Get-WinGetPackageStateSha256 $Id $InstalledVersion $Candidate $Constraint[8] `
        $Constraint[9] $Constraint[10] $SourceState
    return [pscustomobject]@{ Found = $Found[0]; InstalledVersion = $InstalledVersion
        CandidateVersion = $Candidate; PreStateSha256 = $PreState; SourceStateSha256 = $SourceState }
}

function Get-WinGetModulePrecondition([string]$Root, [object]$Request, [object]$Generation) {
    [void](Open-ProtectedWinGetModule $Root $Generation -Import)
    $Constraint = Get-WinGetModuleConstraint $Request $Generation
    if ($null -eq $Constraint) { return Get-WinGetSourceStateSha256 $Generation.ProviderContext }
    return (Resolve-WinGetModulePackage $Generation $Constraint).PreStateSha256
}

function Invoke-WinGetModuleOperation([string]$Root, [object]$Request, [object]$Generation,
    [ref]$LaunchCommitted) {
    $Attestation = Open-ProtectedWinGetModule $Root $Generation -Import
    $Context = $Generation.ProviderContext
    $Constraint = Get-WinGetModuleConstraint $Request $Generation
    $Packages = New-Object Collections.Generic.List[string]
    $SourceState = Get-WinGetSourceStateSha256 $Context
    $PreState = $SourceState; $PostState = $SourceState
    $ProviderStatus = "not-applicable"; $ExtendedError = "-"; $InstallerError = "-"
    $RebootRequired = $false; $State = "completed"; $Reason = "inventory_verified"
    if ($null -eq $Constraint) {
        $ConstraintLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Constraints)) `
            4194304 "constraints"
        $Seen = @{}; $Index = 0
        foreach ($Line in $ConstraintLines) {
            $Fields = $Line.Split('|')
            if ($Fields.Count -lt 11 -or $Fields[0] -cnotin @("winget-install", "winget-upgrade")) { continue }
            $Key = "$($Fields[3])|$($Fields[4])"
            if ($Seen.ContainsKey($Key)) { continue }; $Seen[$Key] = $true
            $Installed = @(Microsoft.WinGet.Client\Get-WinGetPackage -Id $Fields[3] -Source $Fields[4] `
                -MatchOption EqualsCaseInsensitive -ErrorAction Stop)
            if ($Installed.Count -gt 1) { throw "installed_state_drift" }
            if ($Installed.Count -eq 1) {
                foreach ($Value in @($Fields[3], [string]$Installed[0].InstalledVersion)) {
                    if (-not (Test-ResultAtomOrDash $Value)) { throw "invalid_winget_inventory" }
                }
                [void]$Packages.Add("package|$Index|-|$($Fields[3])|$($Installed[0].InstalledVersion)|-|machine|-|-|-|-")
                [void]$Packages.Add("post-package|$Index|$($Installed[0].InstalledVersion)|machine")
                $Index++
            }
        }
    } else {
        $Resolution = Resolve-WinGetModulePackage $Generation $Constraint
        $PreState = $Resolution.PreStateSha256
        if ($Request.Fields.'precondition-sha256' -cne $PreState) { throw "invalid_precondition" }
        $Parameters = [ordered]@{
            Id = $Constraint[3]; Version = $Resolution.CandidateVersion; Source = $Constraint[4]
            MatchOption = "EqualsCaseInsensitive"; Scope = "System"; Architecture = $Constraint[8]
            Locale = $Constraint[9]; InstallerType = $Constraint[10]; Mode = "Silent"
            Confirm = $false; ErrorAction = "Stop"
        }
        $LaunchCommitted.Value = $true
        $Mutation = if ($Constraint[0] -ceq "winget-install") {
            @(Microsoft.WinGet.Client\Install-WinGetPackage @Parameters)
        } else { @(Microsoft.WinGet.Client\Update-WinGetPackage @Parameters) }
        if ($Mutation.Count -ne 1 -or $Mutation[0].Id -cne $Constraint[3] -or
            $Mutation[0].Source -cne $Constraint[4]) { throw "provider_failure" }
        $ProviderStatus = ([string]$Mutation[0].Status).ToLowerInvariant()
        $InstallerError = ([uint32]$Mutation[0].InstallerErrorCode).ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        $ExtendedError = "0x" + ([uint32]$Mutation[0].ExtendedErrorCode.HResult).ToString("x8")
        $RebootRequired = [bool]$Mutation[0].RebootRequired
        if (-not $Mutation[0].Succeeded()) { throw "provider_failure" }
        $Post = @(Microsoft.WinGet.Client\Get-WinGetPackage -Id $Constraint[3] -Source $Constraint[4] `
            -MatchOption EqualsCaseInsensitive -ErrorAction Stop)
        $PostVersion = if ($Post.Count -eq 1) { [string]$Post[0].InstalledVersion } else { "-" }
        $PostState = Get-WinGetPackageStateSha256 $Constraint[3] $PostVersion `
            $Resolution.CandidateVersion $Constraint[8] $Constraint[9] $Constraint[10] $SourceState
        if ($PostVersion -cne $Resolution.CandidateVersion) {
            $State = "partial"; $Reason = "post_state_unverified"
        } elseif ($RebootRequired) {
            $State = "partial"; $Reason = "reboot_required"
        } else { $Reason = "post_state_verified" }
        [void]$Packages.Add("package|0|$($Request.Fields.'policy-token')|$($Constraint[3])|" +
            "$($Resolution.InstalledVersion)|$($Resolution.CandidateVersion)|machine|$($Constraint[8])|" +
            "$($Constraint[9])|$($Constraint[10])|-")
        [void]$Packages.Add("post-package|0|$PostVersion|machine")
    }
    $SourceLine = "source|$($Context.SourceId)|$($Context.SourceName)|$($Context.SourceType)|" +
        "$($Context.SourceArgumentSha256)|$($Context.SourceOrigin)|$($Context.SourceTrust)|" +
        "$($Context.SourceExplicit)|$($Context.SourceLastUpdateMinimum)"
    $Lines = @(
        "winget-helper-result|1", "request-id|$($Request.Fields.'request-id')",
        "action-id|$($Request.Fields.'action-id')", "state|$State", "reason|$Reason",
        "provider-lock-sha256|$($Generation.Digests.ProviderLock)",
        "deployment-file-set-sha256|$($Attestation.FileSetSha256)",
        "app-installer-identity-sha256|$($Attestation.IdentitySha256)",
        "provider-version|$($Attestation.Version)", "state-identifier-sha256|-",
        "provider-runtime-roots-sha256|$($Attestation.FileSetSha256)", "settings-sha256|-", $SourceLine,
        "dependency-authority|module-managed", "installer-hash-authority|module-default-manifest-hash",
        "dependency-closure|not-exposed-by-module", "dependency-provenance|not-exposed-by-module",
        "windows-features|module-managed", "package-count|$([int]($Packages.Count / 2))"
    ) + @($Packages) + @(
        "provider-status|$ProviderStatus", "provider-extended-error|$ExtendedError",
        "provider-installer-error|$InstallerError", "reboot-required|$($RebootRequired.ToString().ToLowerInvariant())",
        "pre-state-sha256|$PreState", "post-state-sha256|$PostState", "end-result|")
    $Bytes = ConvertTo-CanonicalAsciiBytes $Lines
    return [pscustomobject]@{ State = $State; Reason = $Reason; Bytes = $Bytes
        Sha256 = Get-Sha256Bytes $Bytes }
}

function Read-WinGetSourceEvidence([string]$Line, [object]$ProviderContext, [bool]$AllowAbsent) {
    if ($Line -ceq "source|-|-|-|-|-|-|-|-") {
        if (-not $AllowAbsent) { throw "winget_source_evidence_missing" }
        return $null
    }
    $Parts = $Line.Split('|'); [long]$LastUpdate = 0
    if ($Parts.Count -ne 9 -or $Parts[0] -cne "source" -or
        -not (Test-Atom $Parts[1]) -or -not (Test-Atom $Parts[2]) -or -not (Test-Atom $Parts[3]) -or
        -not (Test-Digest $Parts[4]) -or -not (Test-Atom $Parts[5]) -or -not (Test-Atom $Parts[6]) -or
        $Parts[7] -cnotin @("true", "false") -or -not (Test-CanonicalNonNegativeInt64 $Parts[8]) -or
        -not [long]::TryParse($Parts[8], [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$LastUpdate) -or $LastUpdate -lt 0 -or
        $Parts[1] -cne $ProviderContext.SourceId -or $Parts[2] -cne $ProviderContext.SourceName -or
        $Parts[3] -cne $ProviderContext.SourceType -or $Parts[4] -cne $ProviderContext.SourceArgumentSha256 -or
        $Parts[5] -cne $ProviderContext.SourceOrigin -or $Parts[6] -cne $ProviderContext.SourceTrust -or
        $Parts[7] -cne $ProviderContext.SourceExplicit -or $LastUpdate -lt $ProviderContext.SourceLastUpdateMinimum) {
        throw "winget_source_evidence_mismatch"
    }
    return [pscustomobject]@{
        Line = $Line
        SourceId = [string]$Parts[1]
        SourceName = [string]$Parts[2]
        SourceType = [string]$Parts[3]
        SourceArgumentSha256 = [string]$Parts[4]
        SourceOrigin = [string]$Parts[5]
        SourceTrust = [string]$Parts[6]
        SourceExplicit = [string]$Parts[7]
        LastUpdate = $LastUpdate
    }
}

function Assert-WinGetSourceContinuity([object]$HelperSource, [object]$ProvisionSource,
    [object]$ProviderContext, [bool]$AllowAbsent) {
    if ($null -eq $HelperSource) {
        if (-not $AllowAbsent) { throw "helper_result_binding_mismatch" }
        return
    }
    if ($null -eq $ProvisionSource) { throw "helper_result_binding_mismatch" }
    foreach ($Name in @("SourceId", "SourceName", "SourceType", "SourceArgumentSha256",
        "SourceOrigin", "SourceTrust", "SourceExplicit")) {
        if ([string]$HelperSource.$Name -cne [string]$ProvisionSource.$Name) {
            throw "helper_result_binding_mismatch"
        }
    }
    if ([long]$HelperSource.LastUpdate -lt [long]$ProvisionSource.LastUpdate -or
        [long]$HelperSource.LastUpdate -lt [long]$ProviderContext.SourceLastUpdateMinimum) {
        throw "helper_result_binding_mismatch"
    }
}

function Assert-WinGetHelperExitState([string]$State, [int]$ExitCode) {
    $Expected = switch -CaseSensitive ($State) { "completed" { 0 } "partial" { 2 } "rejected" { 3 }
        default { throw "invalid_helper_result" } }
    if ($ExitCode -ne $Expected) { throw "helper_exit_state_mismatch" }
}

function Read-WinGetProvisionRequest([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 2048 "winget_provision_request"
    $Fields = Read-CanonicalFields $Lines @(
        "enrollment-epoch", "generation-sha256", "policy-sha256", "constraints-sha256",
        "winget-context-sha256", "provider-lock-sha256"
    ) "winget-provider-provision-request|1" "end-provision-request|" "winget_provision_request"
    $Epoch = ConvertTo-PositiveInt32 $Fields.'enrollment-epoch' "invalid_winget_provision_request"
    foreach ($Name in @("generation-sha256", "policy-sha256", "constraints-sha256",
        "winget-context-sha256", "provider-lock-sha256")) {
        if (-not (Test-Digest $Fields[$Name])) { throw "invalid_winget_provision_request" }
    }
    return [pscustomobject]@{ Epoch = $Epoch; Fields = $Fields; Bytes = $Bytes }
}

function Read-WinGetProvisionResult([byte[]]$Bytes, [object]$ProvisionRequest,
    [object]$Generation, [int]$ExitCode) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "winget_provision_result"
    if ($Lines.Count -ne 14 -or $Lines[0] -cne "winget-provider-provision-result|1" -or
        $Lines[-1] -cne "end-provision-result|") { throw "invalid_winget_provision_result" }
    $Names = @("state", "reason", "enrollment-epoch", "generation-sha256", "provider-lock-sha256",
        "deployment-file-set-sha256", "app-installer-identity-sha256", "provider-version",
        "state-identifier-sha256", "provider-runtime-roots-sha256", "settings-sha256")
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index]) { throw "invalid_winget_provision_result" }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if ($Fields.state -cnotin @("completed", "partial", "rejected") -or -not (Test-Atom $Fields.reason) -or
        $Fields.'enrollment-epoch' -cne [string]$ProvisionRequest.Epoch) {
        throw "invalid_winget_provision_result"
    }
    Assert-WinGetHelperExitState $Fields.state $ExitCode
    foreach ($Name in @("generation-sha256", "provider-lock-sha256", "deployment-file-set-sha256",
        "app-installer-identity-sha256", "state-identifier-sha256", "provider-runtime-roots-sha256",
        "settings-sha256")) {
        if ($Fields[$Name] -cne "-" -and -not (Test-Digest $Fields[$Name])) {
            throw "invalid_winget_provision_result"
        }
    }
    if ($Fields.'provider-version' -cne "-" -and $Fields.'provider-version' -cne "1.29.280") {
        throw "invalid_winget_provision_result"
    }
    $Expected = [ordered]@{
        'generation-sha256' = $Generation.GenerationDigest
        'provider-lock-sha256' = $Generation.Digests.ProviderLock
        'deployment-file-set-sha256' = $Generation.ProviderContext.DeploymentFileSetSha256
        'app-installer-identity-sha256' = $Generation.ProviderContext.AppInstallerIdentitySha256
        'provider-version' = "1.29.280"
        'state-identifier-sha256' = Get-Sha256Utf8Text $Generation.ProviderContext.StateIdentifier
        'settings-sha256' = Get-WinGetExpectedSettingsSha256 ([pscustomobject]@{ Fields = [ordered]@{
            'action-id' = 'winget.inventory-machine.v1'; 'policy-token' = '-' } }) $Generation
    }
    foreach ($Name in $Expected.Keys) {
        if ($Fields[$Name] -cne "-" -and $Fields[$Name] -cne $Expected[$Name]) {
            throw "winget_provision_result_binding_mismatch"
        }
    }
    $Source = Read-WinGetSourceEvidence $Lines[12] $Generation.ProviderContext ($Fields.state -cne "completed")
    if ($Fields.state -ceq "completed") {
        if ($Fields.reason -ceq "module_state_verified") {
            if ($Fields.'state-identifier-sha256' -cne "-" -or $Fields.'settings-sha256' -cne "-" -or
                $Fields.'provider-runtime-roots-sha256' -cne $Fields.'deployment-file-set-sha256') {
                throw "winget_provision_result_binding_mismatch"
            }
            foreach ($Name in @('generation-sha256', 'provider-lock-sha256',
                'deployment-file-set-sha256', 'app-installer-identity-sha256', 'provider-version')) {
                if ($Fields[$Name] -ceq "-") { throw "winget_provision_result_binding_mismatch" }
            }
        } elseif ($Fields.reason -ceq "provider_state_provisioned") {
            foreach ($Name in @($Expected.Keys) + @('provider-runtime-roots-sha256')) {
                if ($Fields[$Name] -ceq "-") { throw "winget_provision_result_binding_mismatch" }
            }
        } else { throw "winget_provision_result_binding_mismatch" }
    }
    return [pscustomobject]@{ State = [string]$Fields.state; Reason = [string]$Fields.reason
        Fields = $Fields; SourceLine = $Lines[12]; Source = $Source; Bytes = $Bytes
        Sha256 = Get-Sha256Bytes $Bytes }
}

function Read-HelperResult([byte[]]$Bytes, [object]$Request, [object]$Generation,
    [object]$ProvisionReceipt, [int]$ExitCode) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "helper_result"
    if ($Lines.Count -lt 26 -or $Lines[0] -cne "winget-helper-result|1" -or $Lines[-1] -cne "end-result|") {
        throw "invalid_helper_result"
    }
    $FixedNames = @("request-id", "action-id", "state", "reason", "provider-lock-sha256",
        "deployment-file-set-sha256", "app-installer-identity-sha256", "provider-version",
        "state-identifier-sha256", "provider-runtime-roots-sha256", "settings-sha256")
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $FixedNames.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $FixedNames[$Index]) { throw "invalid_helper_result" }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if ($Fields.'request-id' -cne $Request.Fields.'request-id' -or
        $Fields.'action-id' -cne $Request.Fields.'action-id' -or
        $Fields.state -cnotin @("completed", "partial", "rejected") -or -not (Test-Atom $Fields.reason)) {
        throw "helper_result_binding_mismatch"
    }
    Assert-WinGetHelperExitState $Fields.state $ExitCode
    foreach ($Name in @("provider-lock-sha256", "deployment-file-set-sha256",
        "app-installer-identity-sha256", "state-identifier-sha256", "provider-runtime-roots-sha256",
        "settings-sha256")) {
        if ($Fields[$Name] -cne "-" -and -not (Test-Digest $Fields[$Name])) { throw "invalid_helper_result" }
    }
    if (-not (Test-ResultAtomOrDash $Fields.'provider-version')) {
        throw "invalid_helper_result"
    }
    $ExpectedSettings = Get-WinGetExpectedSettingsSha256 $Request $Generation
    $Expected = [ordered]@{
        'provider-lock-sha256' = $ProvisionReceipt.Fields.'provider-lock-sha256'
        'deployment-file-set-sha256' = $ProvisionReceipt.Fields.'deployment-file-set-sha256'
        'app-installer-identity-sha256' = $ProvisionReceipt.Fields.'app-installer-identity-sha256'
        'provider-version' = $ProvisionReceipt.Fields.'provider-version'
        'state-identifier-sha256' = $ProvisionReceipt.Fields.'state-identifier-sha256'
        'provider-runtime-roots-sha256' = $ProvisionReceipt.Fields.'provider-runtime-roots-sha256'
        'settings-sha256' = $ExpectedSettings
    }
    foreach ($Name in $Expected.Keys) {
        if ($Fields[$Name] -cne "-" -and $Fields[$Name] -cne $Expected[$Name]) {
            throw "helper_result_binding_mismatch"
        }
    }
    $RequireCompleteEvidence = $Fields.state -cin @("completed", "partial")
    if ($RequireCompleteEvidence) {
        foreach ($Name in $Expected.Keys) {
            if ($Fields[$Name] -cne $Expected[$Name]) { throw "helper_result_binding_mismatch" }
        }
    }
    $Source = Read-WinGetSourceEvidence $Lines[12] $Generation.ProviderContext (-not $RequireCompleteEvidence)
    Assert-WinGetSourceContinuity $Source $ProvisionReceipt.Source $Generation.ProviderContext `
        (-not $RequireCompleteEvidence)
    $AuthorityLines = @(
        "dependency-authority|source-delegated-all", "installer-hash-authority|provider-enforced-manifest-hash",
        "dependency-closure|not-exposed-by-provider", "dependency-provenance|not-exposed-by-provider",
        "windows-features|root-installer-provider-managed")
    for ($Index = 0; $Index -lt $AuthorityLines.Count; $Index++) {
        if ($Lines[13 + $Index] -cne $AuthorityLines[$Index]) { throw "invalid_helper_result" }
    }
    if (-not $Lines[18].StartsWith("package-count|", [StringComparison]::Ordinal)) {
        throw "invalid_helper_result"
    }
    $PackageCountText = $Lines[18].Substring("package-count|".Length); [int]$PackageCount = 0
    if ($PackageCountText -notmatch '^(0|[1-9][0-9]{0,9})$' -or
        -not [int]::TryParse($PackageCountText, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$PackageCount)) { throw "invalid_helper_result" }
    if ($Lines.Count -ne (26 + (2 * $PackageCount))) { throw "invalid_helper_result" }
    for ($Index = 0; $Index -lt $PackageCount; $Index++) {
        $Package = $Lines[19 + (2 * $Index)].Split('|')
        $PostPackage = $Lines[20 + (2 * $Index)].Split('|')
        if ($Package.Count -ne 11 -or $Package[0] -cne "package" -or $Package[1] -cne [string]$Index -or
            $Package[6] -cne "machine" -or $Package[7] -cnotin @("x86", "x64", "arm", "arm64", "neutral", "-") -or
            $Package[8] -notmatch '^(-|[A-Za-z][A-Za-z0-9-]{1,19})$' -or
            @($Package[2..5] + $Package[9..10] | Where-Object { -not (Test-ResultAtomOrDash $_) }).Count -ne 0 -or
            $PostPackage.Count -ne 4 -or $PostPackage[0] -cne "post-package" -or
            $PostPackage[1] -cne [string]$Index -or
            -not (Test-ResultAtomOrDash $PostPackage[2]) -or $PostPackage[3] -cne "machine") {
            throw "invalid_helper_result"
        }
        if ($Request.Fields.'action-id' -cne "winget.inventory-machine.v1" -and
            $Package[2] -cne $Request.Fields.'policy-token') { throw "helper_result_binding_mismatch" }
    }
    if ($Request.Fields.'action-id' -cne "winget.inventory-machine.v1" -and $PackageCount -gt 1) {
        throw "invalid_helper_result"
    }
    if ($RequireCompleteEvidence -and $Request.Fields.'action-id' -cne "winget.inventory-machine.v1" -and
        $PackageCount -ne 1) { throw "helper_result_binding_mismatch" }
    $TailIndex = 19 + (2 * $PackageCount)
    $TailNames = @("provider-status", "provider-extended-error", "provider-installer-error",
        "reboot-required", "pre-state-sha256", "post-state-sha256")
    for ($Index = 0; $Index -lt $TailNames.Count; $Index++) {
        $Parts = $Lines[$TailIndex + $Index].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $TailNames[$Index]) { throw "invalid_helper_result" }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if (-not (Test-ResultAtomOrDash $Fields.'provider-status') -or
        $Fields.'provider-extended-error' -notmatch '^(-|0x[0-9a-f]{8})$' -or
        ($Fields.'provider-installer-error' -cne "-" -and
            -not (Test-CanonicalUInt32 $Fields.'provider-installer-error')) -or
        $Fields.'reboot-required' -cnotin @("true", "false") -or
        ($Fields.'pre-state-sha256' -cne "-" -and -not (Test-Digest $Fields.'pre-state-sha256')) -or
        ($Fields.'post-state-sha256' -cne "-" -and -not (Test-Digest $Fields.'post-state-sha256')) -or
        ($Fields.'pre-state-sha256' -cne "-" -and
            $Fields.'pre-state-sha256' -cne $Request.Fields.'precondition-sha256')) {
        throw "helper_result_binding_mismatch"
    }
    if ($RequireCompleteEvidence -and $Fields.'pre-state-sha256' -cne $Request.Fields.'precondition-sha256') {
        throw "helper_result_binding_mismatch"
    }
    if ($Fields.state -ceq "completed") {
        $ExpectedReason = if ($Request.Fields.'action-id' -ceq "winget.inventory-machine.v1") {
            "inventory_verified"
        } else { "post_state_verified" }
        if ($Fields.reason -cne $ExpectedReason -or -not (Test-Digest $Fields.'post-state-sha256') -or
            ($Request.Fields.'action-id' -ceq "winget.inventory-machine.v1" -and
                $Fields.'post-state-sha256' -cne $Fields.'pre-state-sha256')) {
            throw "helper_result_binding_mismatch"
        }
    }
    return [pscustomobject]@{ State = [string]$Fields.state; Reason = [string]$Fields.reason
        Fields = $Fields; Source = $Source; Sha256 = Get-Sha256Bytes $Bytes }
}

function Get-WinGetProvisionRequestBytes([int]$Epoch, [object]$Generation) {
    return ConvertTo-CanonicalAsciiBytes @(
        "winget-provider-provision-request|1", "enrollment-epoch|$Epoch",
        "generation-sha256|$($Generation.GenerationDigest)",
        "policy-sha256|$($Generation.Digests.Policy)",
        "constraints-sha256|$($Generation.Digests.Constraints)",
        "winget-context-sha256|$($Generation.Digests.Context)",
        "provider-lock-sha256|$($Generation.Digests.ProviderLock)", "end-provision-request|")
}

function Get-WinGetProvisionReceiptPath([string]$StateRoot, [int]$Epoch, [string]$GenerationDigest) {
    if ($Epoch -lt 1 -or -not (Test-Digest $GenerationDigest)) { throw "invalid_winget_provision_binding" }
    return Join-Path $StateRoot "winget-provider.e$Epoch-$GenerationDigest.receipt"
}

function Get-WinGetResultExitCode([byte[]]$Bytes, [string]$Header, [string]$Label) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 $Label
    if ($Lines.Count -lt 2 -or $Lines[0] -cne $Header) { throw "invalid_$Label" }
    $ExitCode = switch ($Lines[1]) {
        "state|completed" { 0 }
        "state|partial" { 2 }
        "state|rejected" { 3 }
        default { throw "invalid_$Label" }
    }
    return $ExitCode
}

function Get-WinGetProvisionReceipt([string]$Root, [string]$StateRoot, [object]$Request,
    [object]$Generation) {
    $ExpectedClaimBytes = Get-WinGetProvisionRequestBytes $Request.Epoch $Generation
    $ClaimPath = Join-Path $StateRoot "winget-provider.e$($Request.Epoch)-$($Generation.GenerationDigest).claimed"
    if (-not [IO.File]::Exists($ClaimPath)) { throw "winget_provider_provision_required" }
    Assert-NonReparsePath $ClaimPath $Root
    if ($IsWindows) { Assert-ExactSddl $ClaimPath $script:ProtectedFileSddl }
    $Claim = Open-ExclusiveBoundedFile $ClaimPath 2048
    try {
        if ((Get-Sha256Bytes $Claim.Bytes) -cne (Get-Sha256Bytes $ExpectedClaimBytes)) {
            throw "winget_provision_marker_binding_mismatch"
        }
    } finally { $Claim.Stream.Dispose() }
    $Path = Get-WinGetProvisionReceiptPath $StateRoot $Request.Epoch $Generation.GenerationDigest
    if (-not [IO.File]::Exists($Path)) { throw "winget_provider_provision_required" }
    Assert-NonReparsePath $Path $Root
    if ($IsWindows) { Assert-ExactSddl $Path $script:ProtectedFileSddl }
    $Held = Open-ExclusiveBoundedFile $Path 1048576
    try { $Bytes = $Held.Bytes } finally { $Held.Stream.Dispose() }
    $ProvisionRequest = Read-WinGetProvisionRequest $ExpectedClaimBytes
    $ExitCode = Get-WinGetResultExitCode $Bytes "winget-provider-provision-result|1" "winget_provision_result"
    $Receipt = Read-WinGetProvisionResult $Bytes $ProvisionRequest $Generation $ExitCode
    if ($Receipt.State -cne "completed") { throw "winget_provider_provision_recovery_required" }
    return $Receipt
}

function Invoke-WinGetProvisionMarker([string]$Root, [string]$StateRoot, [string]$MarkerPath) {
    Assert-NonReparsePath $MarkerPath $Root
    if ($IsWindows) { Assert-ExactSddl $MarkerPath $script:ProtectedFileSddl }
    $Held = Open-ExclusiveBoundedFile $MarkerPath 2048
    try { $MarkerBytes = $Held.Bytes; $Provision = Read-WinGetProvisionRequest $MarkerBytes }
    finally { $Held.Stream.Dispose() }
    $BindingRequest = [pscustomobject]@{ Epoch = $Provision.Epoch; Fields = [ordered]@{
        'policy-sha256' = $Provision.Fields.'policy-sha256'
        'constraints-sha256' = $Provision.Fields.'constraints-sha256'
        'winget-context-sha256' = $Provision.Fields.'winget-context-sha256'
    } }
    $Generation = Get-ProtectedGeneration $Root $BindingRequest
    if ($Provision.Fields.'generation-sha256' -cne $Generation.GenerationDigest -or
        $Provision.Fields.'provider-lock-sha256' -cne $Generation.Digests.ProviderLock -or
        (Get-Sha256Bytes $MarkerBytes) -cne
            (Get-Sha256Bytes (Get-WinGetProvisionRequestBytes $Provision.Epoch $Generation))) {
        throw "winget_provision_marker_binding_mismatch"
    }
    $ReceiptPath = Get-WinGetProvisionReceiptPath $StateRoot $Provision.Epoch $Generation.GenerationDigest
    $ClaimPath = Join-Path $StateRoot "winget-provider.e$($Provision.Epoch)-$($Generation.GenerationDigest).claimed"
    if ([IO.File]::Exists($ReceiptPath)) {
        $Existing = Get-WinGetProvisionReceipt $Root $StateRoot `
            ([pscustomobject]@{ Epoch = $Provision.Epoch }) $Generation
        [IO.File]::Delete($MarkerPath)
        return $Existing
    }
    if ([IO.File]::Exists($ClaimPath)) { throw "winget_provider_provision_recovery_required" }
    [IO.File]::Move($MarkerPath, $ClaimPath)
    Protect-BrokerPath $ClaimPath
    Assert-NonReparsePath $ClaimPath $Root
    $Claim = Open-ExclusiveBoundedFile $ClaimPath 2048
    try {
        if ((Get-Sha256Bytes $Claim.Bytes) -cne (Get-Sha256Bytes $MarkerBytes)) {
            throw "winget_provision_marker_binding_mismatch"
        }
        $ClaimBytes = $Claim.Bytes
    } finally { $Claim.Stream.Dispose() }
    $Attestation = Open-ProtectedWinGetModule $Root $Generation -Import
    $Context = $Generation.ProviderContext
    $SourceLine = "source|$($Context.SourceId)|$($Context.SourceName)|$($Context.SourceType)|" +
        "$($Context.SourceArgumentSha256)|$($Context.SourceOrigin)|$($Context.SourceTrust)|" +
        "$($Context.SourceExplicit)|$($Context.SourceLastUpdateMinimum)"
    $ReceiptBytes = ConvertTo-CanonicalAsciiBytes @(
        "winget-provider-provision-result|1", "state|completed", "reason|module_state_verified",
        "enrollment-epoch|$($Provision.Epoch)", "generation-sha256|$($Generation.GenerationDigest)",
        "provider-lock-sha256|$($Generation.Digests.ProviderLock)",
        "deployment-file-set-sha256|$($Attestation.FileSetSha256)",
        "app-installer-identity-sha256|$($Attestation.IdentitySha256)",
        "provider-version|$($Attestation.Version)", "state-identifier-sha256|-",
        "provider-runtime-roots-sha256|$($Attestation.FileSetSha256)", "settings-sha256|-",
        $SourceLine, "end-provision-result|")
    $Result = Read-WinGetProvisionResult $ReceiptBytes $Provision $Generation 0
    Write-AtomicBytes $ReceiptPath $ReceiptBytes
    Protect-BrokerPath $ReceiptPath
    if ($IsWindows) { Assert-ExactSddl $ReceiptPath $script:ProtectedFileSddl }
    return $Result
}

function Write-PublicResult([string]$PublicRoot, [string]$Kind, [object]$Request,
    [string]$State, [string]$Reason, [string]$ProtectedResultSha256 = "-") {
    if (($null -ne $Request.PSObject.Properties["IsReadiness"] -and $Request.IsReadiness) -or
        $Kind -cnotin @("active", "last") -or $State -cnotmatch '^[a-z][a-z0-9_-]{0,31}$' -or
        $Reason -cnotmatch '^[a-z][a-z0-9_]{0,127}$' -or
        ($ProtectedResultSha256 -cne "-" -and -not (Test-Digest $ProtectedResultSha256)) -or
        ($Kind -ceq "last" -and -not (Test-Digest $ProtectedResultSha256)) -or
        ($Kind -ceq "active" -and $ProtectedResultSha256 -cne "-") -or
        [string]::IsNullOrWhiteSpace($script:BrokerRoot) -or
        [string]::IsNullOrWhiteSpace($script:ResultRoot) -or
        -not [IO.Path]::GetFullPath($PublicRoot).Equals([IO.Path]::GetFullPath($script:PublicRoot),
            [StringComparison]::OrdinalIgnoreCase) -or
        $Request.Fields.'request-sid' -cne $script:RequestSid) { throw "invalid_public_result" }
    Assert-FixedTransportLayout $script:BrokerRoot $PublicRoot $script:RequestSid
    $Lines = @(
        "windows-broker-public|1", "state|$State", "reason|$Reason",
        "request-id|$($Request.Fields.'request-id')", "plan-id|$($Request.Fields.'plan-id')",
        "action-id|$($Request.Fields.'action-id')", "enrollment-epoch|$($Request.Epoch)",
        "protected-result-sha256|$ProtectedResultSha256", "end-public|")
    $Bytes = ConvertTo-CanonicalAsciiBytes $Lines
    if ($Bytes.Count -gt 4096) { throw "public_result_exceeded" }
    Write-AtomicBytes (Join-Path $PublicRoot $Kind) $Bytes
    if ($Kind -ceq "last") {
        Assert-FixedTransportLayout $script:BrokerRoot $PublicRoot $script:RequestSid
        $ResultPath = Join-Path $script:ResultRoot ($Request.Fields.'request-id' + ".result")
        Write-AtomicBytes $ResultPath $Bytes
        if ($IsWindows) { Set-ExactSddl $ResultPath (Get-TransportAclContract $script:RequestSid).ResultFile }
        Assert-FixedTransportLayout $script:BrokerRoot $PublicRoot $script:RequestSid
    }
}

function Write-BrokerReadinessResult([object]$Request, [object]$Generation, [string]$BrokerSha256,
    [string[]]$ActionRows, [string[]]$ProfileRows, [bool]$ProfileTaskReady = $false,
    [string]$State = "ready", [string]$Reason = "fresh_probes_verified") {
    if ($null -eq $Request.PSObject.Properties["IsReadiness"] -or -not $Request.IsReadiness -or
        $Request.Fields.'request-id' -cnotmatch '^request-[0-9a-f]{32}$' -or
        -not (Test-Digest $BrokerSha256) -or $ActionRows.Count -gt $script:MaximumReadinessProbeBindings -or
        $ProfileRows.Count -gt $script:MaximumReadinessProbeBindings) { throw "invalid_readiness_result" }
    if ($State -ceq "unavailable") {
        if ($Reason -cne "fresh_probe_failed" -or $ProfileTaskReady) { throw "invalid_readiness_result" }
        $Lines = @("windows-broker-readiness-result|1", "request-id|$($Request.Fields.'request-id')",
            "state|unavailable", "reason|fresh_probe_failed", "end-readiness|")
    } elseif ($State -ceq "ready") {
        $HasProfileActions = @($ActionRows | Where-Object {
                $_.StartsWith("action|profile.", [StringComparison]::Ordinal)
            }).Count -gt 0
        if ($Reason -cne "fresh_probes_verified" -or $ActionRows.Count -lt 1 -or
            $ProfileTaskReady -ne $HasProfileActions -or
            $ProfileTaskReady -ne ($ProfileRows.Count -gt 0) -or
            (@($ActionRows | Sort-Object) -join "`n") -cne ($ActionRows -join "`n") -or
            (@($ProfileRows | Sort-Object) -join "`n") -cne ($ProfileRows -join "`n")) {
            throw "invalid_readiness_result"
        }
        $ObservedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $ExpiresAt = $ObservedAt + $script:MaximumClockSkewSeconds
        $Lines = @(
            "windows-broker-readiness-result|1", "request-id|$($Request.Fields.'request-id')", "state|ready",
            "reason|fresh_probes_verified", "broker-protocol|$script:BrokerProtocol", "broker-version|$script:BrokerVersion",
            "broker-sha256|$BrokerSha256", "policy-version|1", "policy-sha256|$($Generation.Digests.Policy)",
            "constraint-version|1", "constraints-sha256|$($Generation.Digests.Constraints)",
            "generation|$($Generation.Epoch)", "generation-sha256|$($Generation.GenerationDigest)",
            "winget-context-version|1", "winget-context-sha256|$($Generation.Digests.Context)",
            "provider-lock-sha256|$($Generation.Digests.ProviderLock)", "request-sid|$($Request.Fields.'request-sid')",
            "request-principal|$($Request.Fields.'request-principal')", "system-task-ready|true",
            "profile-task-ready|$($ProfileTaskReady.ToString().ToLowerInvariant())", "transport-ready|true",
            "native-canary-ready|true",
            "observed-at|$ObservedAt", "expires-at|$ExpiresAt", "action-count|$($ActionRows.Count)") +
            @($ActionRows) + @("profile-constraint-count|$($ProfileRows.Count)") + @($ProfileRows) + @("end-readiness|")
    } else { throw "invalid_readiness_result" }
    [byte[]]$Bytes = ConvertTo-CanonicalAsciiBytes $Lines
    if ($Bytes.Count -gt $script:MaximumReadinessResultBytes) { throw "readiness_result_exceeded" }
    $ResultPath = Join-Path $script:ResultRoot ($Request.Fields.'request-id' + ".readiness")
    if ([IO.File]::Exists($ResultPath)) { throw "readiness_result_replay" }
    Assert-FixedTransportLayout $script:BrokerRoot $script:PublicRoot $script:RequestSid
    Write-AtomicBytes $ResultPath $Bytes
    if ($IsWindows) { Set-ExactSddl $ResultPath (Get-TransportAclContract $script:RequestSid).ResultFile }
    Assert-FixedTransportLayout $script:BrokerRoot $script:PublicRoot $script:RequestSid
}

function Write-PublicDrainStatus([string]$PublicRoot, [string]$Reason) {
    if ($Reason -cnotin @("no_claimable_submission", "request_rejected")) { throw "invalid_drain_status" }
    Assert-FixedTransportLayout $script:BrokerRoot $PublicRoot $script:RequestSid
    Write-AtomicAscii (Join-Path $PublicRoot "drain.status") @(
        "windows-broker-drain-status|1", "state|draining", "reason|$Reason", "end-drain-status|")
}

function Get-FixedProcessEnvironment {
    if ([string]::IsNullOrWhiteSpace($script:ProcessTempRoot)) { throw "fixed_environment_unavailable" }
    [void][IO.Directory]::CreateDirectory($script:ProcessTempRoot)
    $Environment = [ordered]@{
        "TEMP" = $script:ProcessTempRoot
        "TMP" = $script:ProcessTempRoot
        "DOTNET_CLI_HOME" = $script:ProcessTempRoot
        "DOTNET_EnableDiagnostics" = "0"
        "POWERSHELL_TELEMETRY_OPTOUT" = "1"
    }
    if ($IsWindows) {
        $WindowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $ProgramData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        if (-not [IO.Path]::IsPathFullyQualified($WindowsRoot) -or
            -not [IO.Path]::IsPathFullyQualified($ProgramData)) { throw "fixed_environment_unavailable" }
        $SystemProfile = Join-Path $WindowsRoot "System32\config\systemprofile"
        $Environment["SystemRoot"] = $WindowsRoot
        $Environment["WINDIR"] = $WindowsRoot
        $Environment["SystemDrive"] = [IO.Path]::GetPathRoot($WindowsRoot).TrimEnd('\')
        $Environment["ProgramData"] = $ProgramData
        $Environment["USERPROFILE"] = $SystemProfile
        $Environment["LOCALAPPDATA"] = Join-Path $SystemProfile "AppData\Local"
        $Environment["APPDATA"] = Join-Path $SystemProfile "AppData\Roaming"
        $Environment["PATH"] = Join-Path $WindowsRoot "System32"
    } else {
        # Fixture-only portability. Production reaches this function only on Windows.
        $Environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    }
    return $Environment
}

function Initialize-ProcessContainmentTypes {
    if (-not $IsWindows -or ("MachineUtilitiesJob" -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public static class MachineUtilitiesProcessSupport {
  public static async Task<byte[]> ReadBoundedAsync(Stream input, int maximum) {
    using (var output = new MemoryStream()) {
      var buffer = new byte[8192]; bool exceeded=false;
      while (true) {
        int read = await input.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
        if (read == 0) break;
        if (output.Length + read > maximum) exceeded=true;
        else if (!exceeded) output.Write(buffer, 0, read);
      }
      if (exceeded) throw new InvalidDataException("native_output_exceeded");
      return output.ToArray();
    }
  }
}

public sealed class MachineUtilitiesSuspendedProcess : IDisposable {
  const uint CREATE_SUSPENDED = 0x00000004, CREATE_NO_WINDOW = 0x08000000,
    CREATE_UNICODE_ENVIRONMENT = 0x00000400, STARTF_USESTDHANDLES = 0x00000100,
    HANDLE_FLAG_INHERIT = 0x00000001, WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258,
    STILL_ACTIVE = 259;
  [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES {
    public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct STARTUPINFO {
    public int cb; public string lpReserved, lpDesktop, lpTitle; public uint dwX, dwY, dwXSize,
      dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow,
      cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION {
    public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId;
  }
  [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low, High; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CreatePipe(
    out IntPtr readPipe, out IntPtr writePipe, ref SECURITY_ATTRIBUTES attributes, uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(
    IntPtr handle, uint mask, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(
    string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
    bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory,
    ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(
    IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenThread(
    uint access, bool inheritHandle, uint threadId);
  [DllImport("kernel32.dll")] static extern uint GetProcessIdOfThread(IntPtr thread);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

  IntPtr process, thread; bool resumed;
  public uint ProcessId { get; private set; }
  public uint ThreadId { get; private set; }
  public FileStream StandardInput { get; private set; }
  public FileStream StandardOutput { get; private set; }
  public FileStream StandardError { get; private set; }
  public IntPtr ProcessHandle { get { return process; } }
  public ulong CreationFileTime {
    get { FILETIME c, e, k, u; if (!GetProcessTimes(process, out c, out e, out k, out u))
        throw new Win32Exception(Marshal.GetLastWin32Error()); return ((ulong)c.High << 32) | c.Low; }
  }
  static string Quote(string value) {
    if (value.Length > 0 && value.IndexOfAny(new [] {' ', '\t', '"'}) < 0) return value;
    var b = new StringBuilder("\""); int slashes = 0;
    foreach (char ch in value) {
      if (ch == '\\') { slashes++; continue; }
      if (ch == '"') { b.Append('\\', (slashes * 2) + 1); b.Append('"'); slashes = 0; continue; }
      b.Append('\\', slashes); slashes = 0; b.Append(ch);
    }
    b.Append('\\', slashes * 2); b.Append('"'); return b.ToString();
  }
  static void Close(ref IntPtr handle) { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
  public static MachineUtilitiesSuspendedProcess Create(string file, string[] arguments,
      System.Collections.IDictionary environment, string currentDirectory) {
    IntPtr stdinRead=IntPtr.Zero, stdinWrite=IntPtr.Zero, stdoutRead=IntPtr.Zero,
      stdoutWrite=IntPtr.Zero, stderrRead=IntPtr.Zero, stderrWrite=IntPtr.Zero, environmentBlock=IntPtr.Zero;
    var security = new SECURITY_ATTRIBUTES { nLength=Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)),
      bInheritHandle=1 };
    try {
      if (!CreatePipe(out stdinRead, out stdinWrite, ref security, 0) ||
          !CreatePipe(out stdoutRead, out stdoutWrite, ref security, 0) ||
          !CreatePipe(out stderrRead, out stderrWrite, ref security, 0))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      if (!SetHandleInformation(stdinWrite, HANDLE_FLAG_INHERIT, 0) ||
          !SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0) ||
          !SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      var pairs = new System.Collections.Generic.List<string>();
      foreach (System.Collections.DictionaryEntry pair in environment)
        pairs.Add(Convert.ToString(pair.Key, System.Globalization.CultureInfo.InvariantCulture) + "=" +
          Convert.ToString(pair.Value, System.Globalization.CultureInfo.InvariantCulture));
      pairs.Sort(StringComparer.OrdinalIgnoreCase);
      environmentBlock = Marshal.StringToHGlobalUni(string.Join("\0", pairs.ToArray()) + "\0\0");
      var command = new StringBuilder(Quote(file));
      foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
      var startup = new STARTUPINFO { cb=Marshal.SizeOf(typeof(STARTUPINFO)),
        dwFlags=STARTF_USESTDHANDLES, hStdInput=stdinRead, hStdOutput=stdoutWrite, hStdError=stderrWrite };
      PROCESS_INFORMATION info;
      if (!CreateProcessW(file, command, IntPtr.Zero, IntPtr.Zero, true,
          CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, environmentBlock,
          currentDirectory, ref startup, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
      Close(ref stdinRead); Close(ref stdoutWrite); Close(ref stderrWrite);
      var result = new MachineUtilitiesSuspendedProcess { process=info.hProcess, thread=info.hThread,
        ProcessId=info.dwProcessId, ThreadId=info.dwThreadId };
      try {
        result.StandardInput = new FileStream(new SafeFileHandle(stdinWrite, true), FileAccess.Write, 4096, false);
        stdinWrite=IntPtr.Zero;
        result.StandardOutput = new FileStream(new SafeFileHandle(stdoutRead, true), FileAccess.Read, 4096, false);
        stdoutRead=IntPtr.Zero;
        result.StandardError = new FileStream(new SafeFileHandle(stderrRead, true), FileAccess.Read, 4096, false);
        stderrRead=IntPtr.Zero;
        return result;
      } catch { result.TerminateBeforeResume(); result.Dispose(); throw; }
    } finally {
      if (environmentBlock != IntPtr.Zero) Marshal.FreeHGlobal(environmentBlock);
      Close(ref stdinRead); Close(ref stdinWrite); Close(ref stdoutRead); Close(ref stdoutWrite);
      Close(ref stderrRead); Close(ref stderrWrite);
    }
  }
  public void Resume() { if (resumed || ResumeThread(thread) != 1) {
      int error=Marshal.GetLastWin32Error(); TerminateProcess(process, 0xDEAD); throw new Win32Exception(error); }
    resumed=true; Close(ref thread); }
  public bool WaitForExit(int milliseconds) { uint result=WaitForSingleObject(process, (uint)milliseconds);
    if (result==WAIT_OBJECT_0) return true; if (result==WAIT_TIMEOUT) return false;
    throw new Win32Exception(Marshal.GetLastWin32Error()); }
  public int ExitCode { get { uint code; if (!GetExitCodeProcess(process, out code) || code==STILL_ACTIVE)
      throw new InvalidOperationException("process_not_terminal"); return unchecked((int)code); } }
  public static int ResumeIdentifiedThread(uint processId, uint threadId) {
    IntPtr identified = OpenThread(0x0002, false, threadId);
    if (identified == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    try {
      if (GetProcessIdOfThread(identified) != processId) throw new InvalidOperationException("thread_identity_drift");
      uint prior = ResumeThread(identified);
      if (prior == UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
      if (prior > 1) throw new InvalidOperationException("thread_suspend_count_drift");
      return (int)prior;
    } finally { CloseHandle(identified); }
  }
  public void TerminateBeforeResume() { if (!resumed && process!=IntPtr.Zero) TerminateProcess(process, 0xDEAD); }
  public void Dispose() { if (StandardInput!=null) StandardInput.Dispose(); if (StandardOutput!=null) StandardOutput.Dispose();
    if (StandardError!=null) StandardError.Dispose(); Close(ref thread); Close(ref process); }
}

public sealed class MachineUtilitiesJob : IDisposable {
  const int JobObjectBasicAccountingInformation = 1;
  const int JobObjectExtendedLimitInformation = 9;
  const uint JOB_OBJECT_QUERY = 0x0004, SYNCHRONIZE = 0x00100000,
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258;
  IntPtr handle;

  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
    public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS {
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
  }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
  }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
    public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
    public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
  }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr OpenJobObject(uint access, bool inheritHandle, string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(
    uint access, bool inheritHandle, uint processId);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(
    IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(
    IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool DuplicateHandle(
    IntPtr sourceProcess, IntPtr sourceHandle, IntPtr targetProcess, out IntPtr targetHandle,
    uint desiredAccess, bool inheritHandle, uint options);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(
    IntPtr process, IntPtr job, out bool result);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(
    IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(
    IntPtr job, int infoClass, out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info, uint length, IntPtr returned);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low, High; }

  public MachineUtilitiesJob(string name) {
    handle = CreateJobObject(IntPtr.Zero, name);
    if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    if (Marshal.GetLastWin32Error() == 183) { CloseHandle(handle); handle=IntPtr.Zero;
      throw new InvalidOperationException("job_identity_replay"); }
    var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, ref limits,
      (uint)Marshal.SizeOf(limits))) throw new Win32Exception(Marshal.GetLastWin32Error());
  }
  public void Assign(IntPtr process) {
    if (!AssignProcessToJobObject(handle, process)) throw new Win32Exception(Marshal.GetLastWin32Error());
    bool member; if (!IsProcessInJob(process, handle, out member) || !member)
      throw new Win32Exception(Marshal.GetLastWin32Error());
  }
  public void InstallSurvivalHandle(IntPtr process) {
    IntPtr remote;
    if (!DuplicateHandle(GetCurrentProcess(), handle, process, out remote,
        JOB_OBJECT_QUERY | SYNCHRONIZE, false, 0))
      throw new Win32Exception(Marshal.GetLastWin32Error());
  }
  public uint ActiveProcesses {
    get {
      JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
      if (!QueryInformationJobObject(handle, JobObjectBasicAccountingInformation, out info,
        (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)), IntPtr.Zero))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      return info.ActiveProcesses;
    }
  }
  // 1 = identified leader is live in the job; 2 = job is still live through descendants;
  // 0 = terminal; 3 = a live PID or named job no longer matches the durable identity.
  public static int Inspect(string name, uint processId, ulong creationFileTime) {
    IntPtr job = OpenJobObject(JOB_OBJECT_QUERY, false, name);
    IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, processId);
    try {
      bool processLive=false, processMatches=false;
      if (process != IntPtr.Zero) {
        FILETIME c, e, k, u;
        if (!GetProcessTimes(process, out c, out e, out k, out u))
          throw new Win32Exception(Marshal.GetLastWin32Error());
        ulong observed=((ulong)c.High << 32) | c.Low;
        uint wait=WaitForSingleObject(process, 0);
        if (wait!=WAIT_OBJECT_0 && wait!=WAIT_TIMEOUT) throw new Win32Exception(Marshal.GetLastWin32Error());
        processLive=wait==WAIT_TIMEOUT; processMatches=observed==creationFileTime;
      }
      if (job == IntPtr.Zero) return processLive && processMatches ? 3 : 0;
      JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
      if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, out info,
          (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)), IntPtr.Zero))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      if (processLive) {
        if (!processMatches) return 3;
        bool member; if (!IsProcessInJob(process, job, out member))
          throw new Win32Exception(Marshal.GetLastWin32Error());
        return member ? 1 : 3;
      }
      return info.ActiveProcesses==0 ? 0 : 2;
    } finally {
      if (process != IntPtr.Zero) CloseHandle(process);
      if (job != IntPtr.Zero) CloseHandle(job);
    }
  }
  public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}
'@
}

function Write-LiveProcessIdentity {
    param([string]$Path, [string]$RequestId, [string]$JobName, [object]$Process,
        [string]$ExecutablePath, [string]$ExecutableSha256, [string]$State, [string]$ExitCode = "-")
    if ($RequestId -notmatch '^request-[0-9a-f]{32}$' -or
        $State -cnotin @("launch-pending", "active", "recovering", "terminal") -or
        -not (Test-Digest $ExecutableSha256) -or ($ExitCode -cne "-" -and $ExitCode -notmatch '^-?[0-9]{1,10}$')) {
        throw "invalid_live_process_identity"
    }
    Write-AtomicAscii $Path @(
        "windows-live-process|1", "request-id|$RequestId", "job-name|$JobName",
        "pid|$($Process.ProcessId)", "thread-id|$($Process.ThreadId)",
        "creation-filetime|$($Process.CreationFileTime)",
        "executable-path-sha256|$(Get-Sha256Utf8Text $ExecutablePath.ToUpperInvariant())",
        "executable-sha256|$ExecutableSha256", "state|$State", "exit-code|$ExitCode",
        "end-live-process|")
    Protect-BrokerPath $Path
}

function Invoke-FixedProcess {
    param([string]$FilePath, [string[]]$Arguments, [byte[]]$InputBytes,
        [int]$MaximumOutputBytes = 1048576, [int]$TimeoutMilliseconds = 3600000,
        [string]$LiveIdentityPath = "", [string]$StableJobName = "", [object]$LifecycleRequest = $null,
        [string]$ClaimRoot = "", [string]$JournalRoot = "", [string]$PublicRoot = "",
        [object]$LaunchCommitted = $null)
    if (-not [IO.Path]::IsPathFullyQualified($FilePath) -or $TimeoutMilliseconds -lt 1) {
        throw "invalid_fixed_process"
    }
    if ($IsWindows) {
        if ($null -ne $LaunchCommitted -and $LaunchCommitted -isnot [Management.Automation.PSReference]) {
            throw "invalid_fixed_process_lifecycle"
        }
        if (($null -eq $LifecycleRequest) -ne [string]::IsNullOrWhiteSpace($LiveIdentityPath) -or
            ($null -ne $LifecycleRequest -and ([string]::IsNullOrWhiteSpace($StableJobName) -or
                [string]::IsNullOrWhiteSpace($ClaimRoot) -or [string]::IsNullOrWhiteSpace($JournalRoot) -or
                [string]::IsNullOrWhiteSpace($PublicRoot)))) { throw "invalid_fixed_process_lifecycle" }
        Initialize-ProcessContainmentTypes
        $NativeProcess = $null; $Job = $null; $OutputTask = $null; $ErrorTask = $null
        $Resumed = $false; $Recovering = $false
        $ExecutableSha256 = Get-HeldFileSha256 $FilePath 134217728
        try {
            $JobName = if ([string]::IsNullOrWhiteSpace($StableJobName)) {
                "Local\MachineUtilitiesEphemeral-" + [Guid]::NewGuid().ToString("N")
            } else { $StableJobName }
            $Job = [MachineUtilitiesJob]::new($JobName)
            $NativeProcess = [MachineUtilitiesSuspendedProcess]::Create(
                $FilePath, $Arguments, (Get-FixedProcessEnvironment), (Split-Path -Parent $FilePath))
            $Job.Assign($NativeProcess.ProcessHandle)
            $Job.InstallSurvivalHandle($NativeProcess.ProcessHandle)
            if ($null -ne $LifecycleRequest) {
                Write-LiveProcessIdentity $LiveIdentityPath $LifecycleRequest.Fields.'request-id' $JobName `
                    $NativeProcess $FilePath $ExecutableSha256 "launch-pending"
            }
            $OutputTask = [MachineUtilitiesProcessSupport]::ReadBoundedAsync(
                $NativeProcess.StandardOutput, $MaximumOutputBytes)
            $ErrorTask = [MachineUtilitiesProcessSupport]::ReadBoundedAsync(
                $NativeProcess.StandardError, 65536)
            $NativeProcess.StandardInput.Write($InputBytes, 0, $InputBytes.Count)
            $NativeProcess.StandardInput.Close()
            $NativeProcess.Resume(); $Resumed = $true
            if ($null -ne $LaunchCommitted) { $LaunchCommitted.Value = $true }
            if ($null -ne $LifecycleRequest) {
                Write-LiveProcessIdentity $LiveIdentityPath $LifecycleRequest.Fields.'request-id' $JobName `
                    $NativeProcess $FilePath $ExecutableSha256 "active"
                Write-Journal $ClaimRoot $JournalRoot $LifecycleRequest "executing" "native_launch_committed" @{}
                Write-PublicResult $PublicRoot "active" $LifecycleRequest "executing" "native_launch_committed"
            }
            $Deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
            while (-not $NativeProcess.WaitForExit(100)) {
                if (-not $Recovering -and [DateTime]::UtcNow -ge $Deadline) {
                    $Recovering = $true
                    if ($null -ne $LifecycleRequest) {
                        Write-LiveProcessIdentity $LiveIdentityPath $LifecycleRequest.Fields.'request-id' $JobName `
                            $NativeProcess $FilePath $ExecutableSha256 "recovering"
                        Write-Journal $ClaimRoot $JournalRoot $LifecycleRequest "executing" "native_recovering" @{}
                        Write-PublicResult $PublicRoot "active" $LifecycleRequest "executing" "native_recovering"
                    }
                }
            }
            while ($Job.ActiveProcesses -ne 0) {
                if (-not $Recovering -and [DateTime]::UtcNow -ge $Deadline) {
                    $Recovering = $true
                    if ($null -ne $LifecycleRequest) {
                        Write-LiveProcessIdentity $LiveIdentityPath $LifecycleRequest.Fields.'request-id' $JobName `
                            $NativeProcess $FilePath $ExecutableSha256 "recovering"
                        Write-Journal $ClaimRoot $JournalRoot $LifecycleRequest "executing" "native_recovering" @{}
                        Write-PublicResult $PublicRoot "active" $LifecycleRequest "executing" "native_recovering"
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            [byte[]]$OutputBytes = $OutputTask.GetAwaiter().GetResult()
            [void]$ErrorTask.GetAwaiter().GetResult()
            $ExitCode = $NativeProcess.ExitCode
            if ($null -ne $LifecycleRequest) {
                Write-LiveProcessIdentity $LiveIdentityPath $LifecycleRequest.Fields.'request-id' $JobName `
                    $NativeProcess $FilePath $ExecutableSha256 "terminal" ([string]$ExitCode)
            }
            return [pscustomobject]@{ ExitCode = $ExitCode; Bytes = $OutputBytes;
                ProcessId = $NativeProcess.ProcessId; CreationFileTime = $NativeProcess.CreationFileTime;
                JobName = $JobName; RecoveryThresholdExceeded = $Recovering }
        } catch {
            $OriginalFailure = $_
            if ($null -ne $NativeProcess -and -not $Resumed) {
                $NativeProcess.TerminateBeforeResume()
            } elseif ($null -ne $NativeProcess -and $Resumed) {
                try {
                    if (-not $Recovering -and $null -ne $LifecycleRequest) {
                        $Recovering = $true
                        Write-LiveProcessIdentity $LiveIdentityPath $LifecycleRequest.Fields.'request-id' $JobName `
                            $NativeProcess $FilePath $ExecutableSha256 "recovering"
                        Write-Journal $ClaimRoot $JournalRoot $LifecycleRequest "executing" "native_recovering" @{}
                        Write-PublicResult $PublicRoot "active" $LifecycleRequest "executing" "native_recovering"
                    }
                    while (-not $NativeProcess.WaitForExit(1000)) { }
                    while ($null -ne $Job -and $Job.ActiveProcesses -ne 0) { Start-Sleep -Seconds 1 }
                    if ($null -ne $OutputTask) { try { [void]$OutputTask.GetAwaiter().GetResult() } catch { } }
                    if ($null -ne $ErrorTask) { try { [void]$ErrorTask.GetAwaiter().GetResult() } catch { } }
                    if ($null -ne $LifecycleRequest) {
                        Write-LiveProcessIdentity $LiveIdentityPath $LifecycleRequest.Fields.'request-id' $JobName `
                            $NativeProcess $FilePath $ExecutableSha256 "terminal" ([string]$NativeProcess.ExitCode)
                    }
                } catch { }
            }
            throw $OriginalFailure
        } finally {
            if ($null -ne $Job) { $Job.Dispose() }
            if ($null -ne $NativeProcess) { $NativeProcess.Dispose() }
        }
    }

    # Fixture-only path. Production always uses the suspended CreateProcess/job path above.
    $Start = [Diagnostics.ProcessStartInfo]::new()
    $Start.FileName = $FilePath
    $Start.UseShellExecute = $false
    $Start.CreateNoWindow = $true
    $Start.RedirectStandardInput = $true
    $Start.RedirectStandardOutput = $true
    $Start.RedirectStandardError = $true
    $Start.WorkingDirectory = Split-Path -Parent $FilePath
    foreach ($Argument in $Arguments) { [void]$Start.ArgumentList.Add($Argument) }
    $Start.Environment.Clear()
    foreach ($Entry in (Get-FixedProcessEnvironment).GetEnumerator()) {
        $Start.Environment[[string]$Entry.Key] = [string]$Entry.Value
    }
    $Process = [Diagnostics.Process]::new(); $Process.StartInfo = $Start
    $Job = $null
    $FixtureOutput = $null
    try {
        if (-not $Process.Start()) { throw "native_process_start_failed" }
        $Process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Count)
        $Process.StandardInput.Close()
        $FixtureOutput = [IO.MemoryStream]::new()
        $OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($FixtureOutput)
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        $Deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while (-not $Process.WaitForExit(100)) {
            if ($OutputTask.IsFaulted -or $ErrorTask.IsFaulted) { throw "native_output_exceeded" }
            if ([DateTime]::UtcNow -ge $Deadline) { throw "native_process_timeout" }
        }
        [void]$OutputTask.GetAwaiter().GetResult()
        $ErrorTask.GetAwaiter().GetResult() | Out-Null
        if ($FixtureOutput.Length -gt $MaximumOutputBytes) { throw "native_output_exceeded" }
        [byte[]]$OutputBytes = $FixtureOutput.ToArray()
        return [pscustomobject]@{ ExitCode = $Process.ExitCode; Bytes = $OutputBytes }
    } catch {
        if (-not $Process.HasExited) { $Process.Kill($true) }
        try { [void]$Process.WaitForExit(5000) } catch { }
        throw
    } finally {
        if ($null -ne $Job) { $Job.Dispose() }
        if ($null -ne $FixtureOutput) { $FixtureOutput.Dispose() }
        $Process.Dispose()
    }
}

function Get-AsciiProcessText([object]$Result, [string]$Reason) {
    if ($Result.ExitCode -ne 0 -or $Result.Bytes.Count -gt 1048576) { throw $Reason }
    foreach ($Byte in $Result.Bytes) {
        if ($Byte -notin @(9, 10, 13) -and ($Byte -lt 32 -or $Byte -gt 126)) { throw $Reason }
    }
    return $script:Ascii.GetString($Result.Bytes)
}

function Read-ProtectedHostIdentity([string]$Path) {
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 4096 "host_identity"
    $Fields = Read-CanonicalFields $Lines @(
        "host-id", "request-sid", "request-principal", "fleet-domain",
        "fleet-ca-fingerprint", "ca-generation", "previous-ca-fingerprint",
        "previous-ca-generation", "host-key-fingerprint"
    ) "windows-host-identity|1" "end-identity|" "host_identity"
    if (-not (Test-Token $Fields.'host-id') -or
        $Fields.'request-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-Token $Fields.'request-principal') -or
        $Fields.'fleet-domain' -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$' -or
        -not (Test-Fingerprint $Fields.'fleet-ca-fingerprint') -or
        -not (Test-UInt $Fields.'ca-generation') -or $Fields.'ca-generation' -ceq "0" -or
        -not (Test-Fingerprint $Fields.'host-key-fingerprint')) { throw "invalid_host_identity" }
    if ($Fields.'previous-ca-fingerprint' -ceq "-") {
        if ($Fields.'previous-ca-generation' -cne "0") { throw "invalid_host_identity" }
    } elseif (-not (Test-Fingerprint $Fields.'previous-ca-fingerprint') -or
        -not (Test-UInt $Fields.'previous-ca-generation') -or $Fields.'previous-ca-generation' -ceq "0" -or
        $Fields.'previous-ca-fingerprint' -ceq $Fields.'fleet-ca-fingerprint') {
        throw "invalid_host_identity"
    }
    return $Fields
}

function Get-ProtectedCaFingerprintSet([object]$HostIdentity) {
    if (-not (Test-Fingerprint $HostIdentity.'fleet-ca-fingerprint') -or
        -not (Test-UInt $HostIdentity.'ca-generation') -or $HostIdentity.'ca-generation' -ceq "0") {
        throw "invalid_host_identity"
    }
    $Fingerprints = [Collections.Generic.List[string]]::new()
    [void]$Fingerprints.Add($HostIdentity.'fleet-ca-fingerprint')
    if ($HostIdentity.'previous-ca-fingerprint' -ceq "-") {
        if ($HostIdentity.'previous-ca-generation' -cne "0") { throw "invalid_host_identity" }
    } elseif (-not (Test-Fingerprint $HostIdentity.'previous-ca-fingerprint') -or
        -not (Test-UInt $HostIdentity.'previous-ca-generation') -or
        $HostIdentity.'previous-ca-generation' -ceq "0" -or
        $HostIdentity.'previous-ca-fingerprint' -ceq $HostIdentity.'fleet-ca-fingerprint') {
        throw "invalid_host_identity"
    } else {
        [void]$Fingerprints.Add($HostIdentity.'previous-ca-fingerprint')
    }
    return [string[]]@($Fingerprints.ToArray() | Sort-Object -CaseSensitive)
}

function Test-ProtectedCaMembership([object]$HostIdentity, [string]$Fingerprint, [string]$Generation) {
    if (-not (Test-Fingerprint $Fingerprint) -or -not (Test-UInt $Generation) -or $Generation -ceq "0") {
        return $false
    }
    [void](Get-ProtectedCaFingerprintSet $HostIdentity)
    return ($Fingerprint -ceq $HostIdentity.'fleet-ca-fingerprint' -and
            $Generation -ceq $HostIdentity.'ca-generation') -or
        ($HostIdentity.'previous-ca-fingerprint' -cne "-" -and
            $Fingerprint -ceq $HostIdentity.'previous-ca-fingerprint' -and
            $Generation -ceq $HostIdentity.'previous-ca-generation')
}

function Assert-ProtectedFleetCaFingerprintText(
    [string]$Text,
    [object]$HostIdentity,
    [string]$RequestedFingerprint
) {
    $Expected = [string[]]@(Get-ProtectedCaFingerprintSet $HostIdentity)
    if (-not (Test-Fingerprint $RequestedFingerprint) -or $RequestedFingerprint -cnotin $Expected) {
        throw "fleet_ca_drift"
    }
    $Observed = [Collections.Generic.List[string]]::new()
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($Line in @($Text -split '\r?\n' | Where-Object { $_.Length -gt 0 })) {
        $Match = [regex]::Match($Line,
            '^\d+\s+(SHA256:[A-Za-z0-9+/]{43}=?)(?:\s+.+)?\s+\([A-Za-z0-9-]+\)$')
        if (-not $Match.Success -or -not (Test-Fingerprint $Match.Groups[1].Value) -or
            -not $Seen.Add($Match.Groups[1].Value)) { throw "fleet_ca_drift" }
        [void]$Observed.Add($Match.Groups[1].Value)
    }
    $ObservedSorted = [string[]]@($Observed.ToArray() | Sort-Object -CaseSensitive)
    if ($ObservedSorted.Count -lt 1 -or
        ($ObservedSorted -join "`n") -cne ($Expected -join "`n")) { throw "fleet_ca_drift" }
}

function Assert-ExactSddl([string]$Path, [string]$ExpectedSddl) {
    if ($script:SelfTestFixture) { return }
    $Expected = [Security.AccessControl.RawSecurityDescriptor]::new($ExpectedSddl)
    $ObservedAcl = Get-Acl -LiteralPath $Path
    $Observed = [Security.AccessControl.RawSecurityDescriptor]::new(
        $ObservedAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
    [byte[]]$ExpectedBytes = [byte[]]::new($Expected.BinaryLength)
    [byte[]]$ObservedBytes = [byte[]]::new($Observed.BinaryLength)
    $Expected.GetBinaryForm($ExpectedBytes, 0); $Observed.GetBinaryForm($ObservedBytes, 0)
    if ((Get-Sha256Bytes $ExpectedBytes) -cne (Get-Sha256Bytes $ObservedBytes)) { throw "slot_acl_drift" }
}

function Get-FixedTransportPaths([string]$Root, [string]$PublicRoot) {
    $ChrootRoot = Join-Path $Root "chroot"
    $IngressRoot = Join-Path $ChrootRoot "ingress"
    return [pscustomobject]@{
        Chroot = $ChrootRoot
        Ingress = $IngressRoot
        Slot = Join-Path $IngressRoot "slot"
        Results = Join-Path $ChrootRoot "results"
        LegacyIngress = Join-Path $Root "ingress"
        LegacyResults = Join-Path $PublicRoot "results"
    }
}

function Get-TransportAclContract([string]$RequestSid) {
    if ($RequestSid -cnotmatch '^S-[0-9]+(?:-[0-9]+){1,14}$') { throw "invalid_request_sid" }
    $DirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x001200a0;;;$RequestSid)"
    $SlotFileSddl = "O:${RequestSid}G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;$RequestSid)"
    $ResultFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00120089;;;$RequestSid)"
    return [pscustomobject]@{
        RequestSid = $RequestSid
        ChrootDirectory = $DirectorySddl
        SlotDirectory = $DirectorySddl
        SlotFile = $SlotFileSddl
        ResultsDirectory = $DirectorySddl
        ResultFile = $ResultFileSddl
        ChrootPathSha256 = Get-Sha256Utf8Text "C:\PROGRAMDATA\MACHINEUTILITIES\CHROOT"
        ChrootDirectorySddlSha256 = Get-Sha256Utf8Text $DirectorySddl
        SlotDirectorySddlSha256 = Get-Sha256Utf8Text $DirectorySddl
        SlotFileSddlSha256 = Get-Sha256Utf8Text $SlotFileSddl
        ResultsDirectorySddlSha256 = Get-Sha256Utf8Text $DirectorySddl
        ResultFileSddlSha256 = Get-Sha256Utf8Text $ResultFileSddl
    }
}

function Assert-ExactTransportEntries([string]$Path, [string[]]$ExpectedNames) {
    if (-not [IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) {
        throw "transport_directory_type_drift"
    }
    $Observed = @([IO.Directory]::EnumerateFileSystemEntries(
        $Path, "*", [IO.SearchOption]::TopDirectoryOnly) | ForEach-Object { [IO.Path]::GetFileName($_) })
    if (@(Compare-Object @($ExpectedNames | Sort-Object) @($Observed | Sort-Object) -CaseSensitive).Count -ne 0) {
        throw "transport_unknown_entry"
    }
}

function Assert-PhysicalTransportDirectory([string]$Path, [string]$ExpectedSddl) {
    if (-not [IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) {
        throw "transport_directory_type_drift"
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "transport_directory_reparse"
    }
    if ($IsWindows -and -not $script:SelfTestFixture) { Assert-ExactSddl $Path $ExpectedSddl }
}

function Assert-PhysicalTransportFile([string]$Path, [long]$MaximumBytes, [string]$ExpectedSddl,
        [object]$HeldStream = $null) {
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { throw "transport_file_type_drift" }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0 -or
        $Item.Length -lt 0 -or $Item.Length -gt $MaximumBytes) { throw "transport_file_type_drift" }
    if ($IsWindows) {
        Initialize-BrokerProfileNativeTypes
        if ($null -eq $HeldStream) {
            [MachineUtilitiesBrokerProfileNative]::AssertSingleLinkRegularFile($Path, $Path)
            if (-not $script:SelfTestFixture) { Assert-ExactSddl $Path $ExpectedSddl }
        } else {
            [MachineUtilitiesBrokerProfileNative]::AssertHeldSingleLinkRegularFile(
                $HeldStream.SafeFileHandle, $Path)
        }
    }
}

function Assert-SanitizedTransportResult([string]$Path, [string]$ExpectedRequestId) {
    $Fields = Read-CanonicalFields (ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 4096 `
        "transport_result") @("state", "reason", "request-id", "plan-id", "action-id",
        "enrollment-epoch", "protected-result-sha256") "windows-broker-public|1" "end-public|" `
        "transport_result"
    if ($ExpectedRequestId -cnotmatch '^request-[0-9a-f]{32}$' -or
        $Fields.'request-id' -cne $ExpectedRequestId -or
        $Fields.state -cnotmatch '^[a-z][a-z0-9_-]{0,31}$' -or
        $Fields.reason -cnotmatch '^[a-z][a-z0-9_]{0,127}$' -or
        -not (Test-UInt $Fields.'enrollment-epoch') -or
        -not (Test-Digest $Fields.'protected-result-sha256')) { throw "transport_result_drift" }
}

function Assert-SanitizedReadinessResult([string]$Path, [string]$ExpectedRequestId) {
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) $script:MaximumReadinessResultBytes `
        "readiness_result"
    if ($ExpectedRequestId -cnotmatch '^request-[0-9a-f]{32}$' -or
        $Lines.Count -lt 5 -or $Lines[0] -cne "windows-broker-readiness-result|1" -or
        $Lines[-1] -cne "end-readiness|") { throw "readiness_result_drift" }
    if ($Lines.Count -eq 5) {
        if ($Lines[1] -cne "request-id|$ExpectedRequestId" -or $Lines[2] -cne "state|unavailable" -or
            $Lines[3] -cne "reason|fresh_probe_failed") { throw "readiness_result_drift" }
        return
    }
    $Names = @(
        "request-id", "state", "reason", "broker-protocol", "broker-version", "broker-sha256",
        "policy-version", "policy-sha256", "constraint-version", "constraints-sha256", "generation",
        "generation-sha256", "winget-context-version", "winget-context-sha256", "provider-lock-sha256", "request-sid",
        "request-principal", "system-task-ready", "profile-task-ready", "transport-ready",
        "native-canary-ready", "observed-at", "expires-at", "action-count")
    if ($Lines.Count -lt ($Names.Count + 4)) { throw "readiness_result_drift" }
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Fields.Contains($Parts[0])) {
            throw "readiness_result_drift"
        }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if ($Fields.'request-id' -cne $ExpectedRequestId -or $Fields.state -cne "ready" -or
        $Fields.reason -cne "fresh_probes_verified" -or
        $Fields.'broker-protocol' -cne [string]$script:BrokerProtocol -or -not (Test-Atom $Fields.'broker-version') -or
        @($Fields.'broker-sha256', $Fields.'policy-sha256', $Fields.'constraints-sha256',
            $Fields.'generation-sha256', $Fields.'winget-context-sha256', $Fields.'provider-lock-sha256' |
            Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
        -not (Test-UInt $Fields.'policy-version') -or -not (Test-UInt $Fields.'constraint-version') -or
        -not (Test-UInt $Fields.'winget-context-version') -or
        -not (Test-UInt $Fields.generation) -or $Fields.'request-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-Token $Fields.'request-principal') -or
        @($Fields.'system-task-ready', $Fields.'transport-ready', $Fields.'native-canary-ready' |
            Where-Object { $_ -cne "true" }).Count -ne 0 -or
        $Fields.'profile-task-ready' -cnotin @("true", "false") -or
        -not (Test-UInt $Fields.'observed-at') -or -not (Test-UInt $Fields.'expires-at') -or
        -not (Test-UInt $Fields.'action-count')) { throw "readiness_result_drift" }
    [long]$ObservedAt = [long]$Fields.'observed-at'; [long]$ExpiresAt = [long]$Fields.'expires-at'
    [int]$ActionCount = [int]$Fields.'action-count'
    if ($ExpiresAt -le $ObservedAt -or ($ExpiresAt - $ObservedAt) -gt $script:MaximumClockSkewSeconds -or
        $ActionCount -lt 1 -or $ActionCount -gt $script:MaximumReadinessProbeBindings) {
        throw "readiness_result_drift"
    }
    $ActionRows = @($Lines | Select-Object -Skip ($Names.Count + 1) -First $ActionCount)
    $Previous = ""; $Seen = @{}; $HasProfileAction = $false
    foreach ($Line in $ActionRows) {
        $Parts = $Line.Split('|')
        if ($Parts.Count -ne 5 -or $Parts[0] -cne "action" -or
            $Parts[1] -cnotin @("profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1",
                "winget.install-machine-package.v1", "winget.inventory-machine.v1", "winget.upgrade-machine-package.v1") -or
            $Parts[2] -cnotin @("windows-system-v1", "windows-user-s4u-v1") -or
            ($Parts[1].StartsWith("profile.", [StringComparison]::Ordinal) -and $Parts[2] -cne "windows-user-s4u-v1") -or
            ($Parts[1].StartsWith("winget.", [StringComparison]::Ordinal) -and $Parts[2] -cne "windows-system-v1") -or
            (($Parts[1] -ceq "winget.inventory-machine.v1") -and $Parts[3] -cne "-") -or
            (($Parts[1] -cne "winget.inventory-machine.v1") -and -not (Test-Token $Parts[3])) -or
            -not (Test-Digest $Parts[4]) -or
            ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0) -or
            $Seen.ContainsKey("$($Parts[1])|$($Parts[3])")) { throw "readiness_result_drift" }
        if ($Parts[1].StartsWith("profile.", [StringComparison]::Ordinal)) { $HasProfileAction = $true }
        $Seen["$($Parts[1])|$($Parts[3])"] = $true; $Previous = $Line
    }
    $ProfileCountIndex = $Names.Count + 1 + $ActionCount
    if ($ProfileCountIndex -ge ($Lines.Count - 1)) { throw "readiness_result_drift" }
    $ProfileCountParts = $Lines[$ProfileCountIndex].Split('|')
    if ($ProfileCountParts.Count -ne 2 -or $ProfileCountParts[0] -cne "profile-constraint-count" -or
        -not (Test-UInt $ProfileCountParts[1])) { throw "readiness_result_drift" }
    [int]$ProfileCount = [int]$ProfileCountParts[1]
    if ($ProfileCount -gt $script:MaximumReadinessProbeBindings -or
        $Lines.Count -ne ($ProfileCountIndex + $ProfileCount + 2) -or
        ($Fields.'profile-task-ready' -ceq "true") -ne $HasProfileAction -or
        ($Fields.'profile-task-ready' -ceq "true") -ne ($ProfileCount -gt 0)) {
        throw "readiness_result_drift"
    }
    $Previous = ""; $Seen = @{}
    for ($Index = 0; $Index -lt $ProfileCount; $Index++) {
        $Line = $Lines[$ProfileCountIndex + 1 + $Index]; $Parts = $Line.Split('|')
        if ($Parts.Count -ne 10 -or $Parts[0] -cne "profile-constraint" -or -not (Test-Token $Parts[1]) -or
            $Parts[2] -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
            @($Parts[3], $Parts[4], $Parts[5], $Parts[9] | Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
            $Parts[6] -cnotin @("managed-only", "managed-and-prune") -or
            -not (Test-UInt $Parts[7]) -or -not (Test-UInt $Parts[8]) -or
            ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0) -or
            $Seen.ContainsKey($Parts[1])) { throw "readiness_result_drift" }
        $Seen[$Parts[1]] = $true; $Previous = $Line
    }
}

function Assert-FixedResultProjection([string]$Root, [string]$PublicRoot, [object]$Acl) {
    $Paths = Get-FixedTransportPaths $Root $PublicRoot
    Assert-PhysicalTransportDirectory $Paths.Results $Acl.ResultsDirectory
    foreach ($Entry in @([IO.Directory]::EnumerateFileSystemEntries(
            $Paths.Results, "*", [IO.SearchOption]::TopDirectoryOnly))) {
        $Name = [IO.Path]::GetFileName($Entry)
        $Normal = [regex]::Match($Name, '^(request-[0-9a-f]{32})\.result$')
        $Readiness = [regex]::Match($Name, '^(request-[0-9a-f]{32})\.readiness$')
        if ($Normal.Success) {
            Assert-PhysicalTransportFile $Entry 4096 $Acl.ResultFile
            Assert-SanitizedTransportResult $Entry $Normal.Groups[1].Value
        } elseif ($Readiness.Success) {
            Assert-PhysicalTransportFile $Entry $script:MaximumReadinessResultBytes $Acl.ResultFile
            Assert-SanitizedReadinessResult $Entry $Readiness.Groups[1].Value
        } else { throw "transport_unknown_entry" }
    }
    if ([IO.Directory]::Exists($Paths.LegacyIngress) -or [IO.File]::Exists($Paths.LegacyIngress) -or
        [IO.Directory]::Exists($Paths.LegacyResults) -or [IO.File]::Exists($Paths.LegacyResults)) {
        throw "legacy_transport_projection_live"
    }
}

function Assert-FixedTransportLayout([string]$Root, [string]$PublicRoot, [string]$RequestSid,
        [object]$HeldSlot = $null) {
    $Paths = Get-FixedTransportPaths $Root $PublicRoot
    $Acl = Get-TransportAclContract $RequestSid
    Assert-PhysicalTransportDirectory $Paths.Chroot $Acl.ChrootDirectory
    Assert-ExactTransportEntries $Paths.Chroot @("ingress", "results")
    Assert-PhysicalTransportDirectory $Paths.Ingress $Acl.ChrootDirectory
    Assert-ExactTransportEntries $Paths.Ingress @("slot")
    Assert-PhysicalTransportDirectory $Paths.Slot $Acl.SlotDirectory
    $SlotNames = [string[]]@("request", "request.sig", "payload", "commit")
    Assert-ExactTransportEntries $Paths.Slot $SlotNames
    $MaximumByName = @{ request = 16384L; 'request.sig' = 16384L; payload = 67108864L; commit = 2048L }
    for ($Index = 0; $Index -lt $SlotNames.Count; $Index++) {
        $HeldStream = if ($null -eq $HeldSlot) { $null } else {
            if ($null -eq $HeldSlot.Handles -or $HeldSlot.Handles.Count -ne 4) { throw "transport_slot_handle_drift" }
            $HeldSlot.Handles[$Index].Stream
        }
        Assert-PhysicalTransportFile (Join-Path $Paths.Slot $SlotNames[$Index]) `
            $MaximumByName[$SlotNames[$Index]] $Acl.SlotFile $HeldStream
    }
    Assert-FixedResultProjection $Root $PublicRoot $Acl
}

function Assert-SignedRequest {
    param([string]$Root, [object]$Slot, [string]$ProcessingRoot, [object]$Generation)
    $Request = $Slot.Request; $Fields = $Request.Fields
    $TrustRoot = Join-Path $Root "trust"
    $AllowedSigners = Join-Path $TrustRoot "allowed_signers"
    $RevokedKrl = Join-Path $TrustRoot "revoked.krl"
    $FleetCa = Join-Path $TrustRoot "fleet-ca.pub"
    $HostIdentityPath = Join-Path $Root "host.identity"
    foreach ($Path in @($TrustRoot, $AllowedSigners, $RevokedKrl, $FleetCa, $HostIdentityPath)) {
        Assert-NonReparsePath $Path $Root
    }
    $HostIdentity = Read-ProtectedHostIdentity $HostIdentityPath
    if ($Fields.'target-host-id' -cne $HostIdentity.'host-id' -or
        $Fields.'request-sid' -cne $HostIdentity.'request-sid' -or
        $Fields.'request-principal' -cne $HostIdentity.'request-principal' -or
        $Fields.'fleet-domain' -cne $HostIdentity.'fleet-domain' -or
        -not (Test-ProtectedCaMembership $HostIdentity $Fields.'fleet-ca-fingerprint' `
            $Fields.'ca-generation') -or
        $Fields.'pinned-host-key-fingerprint' -cne $HostIdentity.'host-key-fingerprint') {
        throw "host_identity_mismatch"
    }
    Assert-FixedTransportLayout $Root $script:PublicRoot $HostIdentity.'request-sid' $Slot
    $SshKeygen = [string]$Generation.OpenSshIdentity.path
    if ([string]::IsNullOrWhiteSpace($SshKeygen)) { throw "system_openssh_identity_invalid" }
    [void][IO.Directory]::CreateDirectory($ProcessingRoot)
    $SignaturePath = Join-Path $ProcessingRoot ("signature-" + [Guid]::NewGuid().ToString("N"))
    try {
        Copy-ClaimedBytes $SignaturePath $Slot.SignatureBytes $Slot.Commit.SignatureSha256
        $SigningPrincipal = $Fields.'node-id' + "@" + $Fields.'fleet-domain'
        $Verified = Invoke-FixedProcess $SshKeygen @(
            "-Y", "verify", "-f", $AllowedSigners, "-I", $SigningPrincipal,
            "-n", $script:RequestNamespace, "-s", $SignaturePath, "-r", $RevokedKrl, "-O", "print-pubkey"
        ) $Request.Bytes 65536
        $VerifyText = Get-AsciiProcessText $Verified "signature_verification_failed"
        $CertificateMatches = [regex]::Matches($VerifyText,
            '(?m)^ssh-ed25519-cert-v01@openssh\.com [A-Za-z0-9+/=]+(?: [A-Za-z0-9._@+-]+)?\r?$')
        if ($CertificateMatches.Count -ne 1) { throw "printed_certificate_mismatch" }
        $CertificateText = $CertificateMatches[0].Value.TrimEnd("`r") + "`n"
        $CertificateBytes = $script:Ascii.GetBytes($CertificateText)
        $FingerprintText = Get-AsciiProcessText (Invoke-FixedProcess $SshKeygen @("-lf", "-", "-E", "sha256") `
            $CertificateBytes 8192) "certificate_fingerprint_failed"
        $NodeFingerprint = [regex]::Match($FingerprintText, 'SHA256:[A-Za-z0-9+/]{43}=?').Value
        $Details = Get-AsciiProcessText (Invoke-FixedProcess $SshKeygen @("-Lf", "-") $CertificateBytes 65536) `
            "certificate_parse_failed"
        $CaFingerprint = [regex]::Match(
            [regex]::Match($Details, '(?m)^\s*Signing CA:.*$').Value,
            'SHA256:[A-Za-z0-9+/]{43}=?').Value
        $KeyId = [regex]::Match($Details, '(?m)^\s*Key ID:\s*"([^"]+)"\s*$').Groups[1].Value
        $Serial = [regex]::Match($Details, '(?m)^\s*Serial:\s*([0-9]+)\s*$').Groups[1].Value
        $Validity = [regex]::Match($Details,
            '(?m)^\s*Valid:\s*from\s+([0-9T:-]+)\s+to\s+([0-9T:-]+)\s*$')
        if (-not $Validity.Success) { throw "certificate_identity_mismatch" }
        $After = [DateTime]::Parse($Validity.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
        $Before = [DateTime]::Parse($Validity.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
        $Principals = New-Object Collections.Generic.List[string]
        $Sources = New-Object Collections.Generic.List[string]
        $Section = ""; $ExtensionsCleared = $false
        foreach ($Line in $Details.Split("`n")) {
            if ($Line -match '^\s*Principals:') { $Section = "principals"; continue }
            if ($Line -match '^\s*Critical Options:') { $Section = "critical"; continue }
            if ($Line -match '^\s*Extensions:\s*\(none\)\s*$') { $ExtensionsCleared = $true; $Section = ""; continue }
            if ($Line -match '^\s*Extensions:') { $Section = "extensions"; continue }
            $Trimmed = $Line.Trim()
            if ($Section -ceq "principals" -and $Trimmed -and $Trimmed -cne "(none)") {
                [void]$Principals.Add($Trimmed)
            } elseif ($Section -ceq "critical" -and $Trimmed -and $Trimmed -cne "(none)") {
                if ($Trimmed -notmatch '^source-address\s+(.+)$') { throw "certificate_critical_option_mismatch" }
                foreach ($Source in $Matches[1].Split(',')) { [void]$Sources.Add($Source) }
            } elseif ($Section -ceq "extensions" -and $Trimmed -and $Trimmed -cne "(none)") {
                throw "certificate_extension_mismatch"
            }
        }
        if ($Details -match '(?m)^\s*Extensions:\s*$' -and $Details -match '(?m)^\s+\(none\)\s*$') {
            $ExtensionsCleared = $true
        }
        $ExpectedPrincipals = @($SigningPrincipal, "machine-utilities-posix", "machine-utilities-windows" | Sort-Object)
        $ExpectedSources = if ($Fields.'certificate-source-addresses' -ceq "-") { @() }
            else { @($Fields.'certificate-source-addresses'.Split(',') | Sort-Object) }
        if ($NodeFingerprint -cne $Fields.'node-key-fingerprint' -or
            $CaFingerprint -cne $Fields.'fleet-ca-fingerprint' -or $KeyId -cne $SigningPrincipal -or
            -not (Test-ProtectedCaMembership $HostIdentity $CaFingerprint $Fields.'ca-generation') -or
            $Serial -cne $Fields.'certificate-serial' -or $After -cne $Fields.'certificate-valid-after' -or
            $Before -cne $Fields.'certificate-valid-before' -or -not $ExtensionsCleared -or
            (@($Principals | Sort-Object) -join "`n") -cne ($ExpectedPrincipals -join "`n") -or
            (@($Sources | Sort-Object) -join "`n") -cne ($ExpectedSources -join "`n")) {
            throw "certificate_identity_mismatch"
        }
        $CaText = Get-AsciiProcessText (Invoke-FixedProcess $SshKeygen @("-lf", $FleetCa, "-E", "sha256") `
            ([byte[]]@()) 8192) "fleet_ca_verification_failed"
        Assert-ProtectedFleetCaFingerprintText $CaText $HostIdentity $Fields.'fleet-ca-fingerprint'
    } finally {
        if ([IO.File]::Exists($SignaturePath)) { [IO.File]::Delete($SignaturePath) }
    }
}

function Assert-SystemContext {
    if (-not $IsWindows) { throw "unsupported_context" }
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { if (-not $Identity.IsSystem) { throw "unsupported_context" } } finally { $Identity.Dispose() }
}

function Assert-NonReparsePath([string]$Path, [string]$StopAt) {
    $Current = [IO.Path]::GetFullPath($Path)
    $Boundary = [IO.Path]::GetFullPath($StopAt).TrimEnd([IO.Path]::DirectorySeparatorChar)
    while ($true) {
        $Item = Get-Item -LiteralPath $Current -Force
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "protected_path_drift" }
        if ($IsWindows -and -not $script:SelfTestFixture) {
            $Acl = Get-Acl -LiteralPath $Current
            if ([string]$Acl.Owner -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
                throw "protected_path_drift"
            }
            foreach ($Rule in $Acl.Access) {
                if ($Rule.AccessControlType -eq "Allow" -and
                    ($Rule.FileSystemRights -band ([Security.AccessControl.FileSystemRights]::Write -bor
                        [Security.AccessControl.FileSystemRights]::Modify -bor
                        [Security.AccessControl.FileSystemRights]::FullControl -bor
                        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                        [Security.AccessControl.FileSystemRights]::TakeOwnership)) -ne 0 -and
                    [string]$Rule.IdentityReference -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
                    throw "protected_path_drift"
                }
            }
        }
        if ($Current.TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq $Boundary) { break }
        $Parent = [IO.Directory]::GetParent($Current)
        if ($null -eq $Parent -or -not $Current.StartsWith($Boundary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "protected_path_drift"
        }
        $Current = $Parent.FullName
    }
}

function Get-ProtectedOpenSshIdentity([string]$Path, [string]$Root) {
    Assert-NonReparsePath $Path $Root
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 4096 "openssh_identity"
    $Fields = Read-CanonicalFields $Lines @("path", "sha256", "publisher-thumbprint", "y-verify-capability",
        "print-pubkey-capability", "certificate-parse-capability") `
        "windows-openssh-identity|1" "end-openssh-identity|" "openssh_identity"
    $ExpectedPath = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
    if (-not [IO.Path]::GetFullPath($Fields.path).Equals([IO.Path]::GetFullPath($ExpectedPath),
            [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Digest $Fields.sha256) -or
        $Fields.'publisher-thumbprint' -notmatch '^(?:[0-9A-F]{40}|[0-9A-F]{64})$' -or
        @($Fields.'y-verify-capability', $Fields.'print-pubkey-capability',
            $Fields.'certificate-parse-capability' | Where-Object { $_ -cne "native-canary-required" }).Count -ne 0) {
        throw "system_openssh_identity_invalid"
    }
    Assert-NonReparsePath $ExpectedPath $env:WINDIR
    if ((Get-HeldFileSha256 $ExpectedPath 16777216) -cne $Fields.sha256) {
        throw "system_openssh_identity_drift"
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $ExpectedPath
    if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Thumbprint.ToUpperInvariant() -cne $Fields.'publisher-thumbprint') {
        throw "system_openssh_identity_drift"
    }
    return $Fields
}

function Get-ProtectedGeneration([string]$Root, [object]$Request) {
    $IsReadiness = $null -ne $Request.PSObject.Properties["IsReadiness"] -and [bool]$Request.IsReadiness
    $PointerPath = Join-Path $Root "active.generation"
    Assert-NonReparsePath $PointerPath $Root
    $PointerBytes = [IO.File]::ReadAllBytes($PointerPath)
    $Pointer = Read-ActiveGenerationPointer $PointerBytes
    if (-not $IsReadiness -and $Pointer.Epoch -ne $Request.Epoch) { throw "generation_mismatch" }
    $GenerationRoot = Join-Path (Join-Path $Root "generations") ([string]$Pointer.Epoch)
    Assert-NonReparsePath $GenerationRoot $Root
    $Files = [ordered]@{
        Policy = Join-Path $GenerationRoot "policy.actions"
        Constraints = Join-Path $GenerationRoot "policy.constraints"
        Context = Join-Path $GenerationRoot "winget.context"
        ProviderLock = Join-Path $GenerationRoot "windows-winget-provider.lock"
        OpenSshIdentity = Join-Path $GenerationRoot "openssh.identity"
    }
    foreach ($Path in $Files.Values) { Assert-NonReparsePath $Path $Root }
    $Digests = [ordered]@{}
    foreach ($Name in $Files.Keys) { $Digests[$Name] = Get-Sha256Bytes ([IO.File]::ReadAllBytes($Files[$Name])) }
    if (-not $IsReadiness -and ($Digests.Policy -cne $Request.Fields.'policy-sha256' -or
        $Digests.Constraints -cne $Request.Fields.'constraints-sha256' -or
        $Digests.Context -cne $Request.Fields.'winget-context-sha256')) { throw "active_state_drift" }
    $ExpectedGeneration = Get-GenerationDigest $Pointer.Epoch $Digests.Policy $Digests.Constraints `
        $Digests.Context $Digests.ProviderLock $Digests.OpenSshIdentity
    if ($ExpectedGeneration -cne $Pointer.Digest) { throw "active_state_drift" }
    $ProviderContext = Read-WinGetProviderContext ([IO.File]::ReadAllBytes($Files.Context))
    $OpenSshIdentity = Get-ProtectedOpenSshIdentity $Files.OpenSshIdentity $Root
    $Generation = [pscustomobject]@{
        PointerPath = $PointerPath; PointerBytes = $PointerBytes; Epoch = $Pointer.Epoch; GenerationDigest = $Pointer.Digest
        Root = $GenerationRoot; Files = $Files; Digests = $Digests; ProviderContext = $ProviderContext
        OpenSshIdentity = $OpenSshIdentity
    }
    $StateAuthority = Get-WinGetStateAuthoritySha256 $Pointer.Epoch $Generation $ProviderContext
    if ($ProviderContext.StateIdentifier -cne "machine-utilities-e$($Pointer.Epoch)-$StateAuthority") {
        throw "active_state_drift"
    }
    return $Generation
}

function Test-NativeCanaryDetachedSignature([byte[]]$ReceiptBytes, [byte[]]$SignatureBytes,
    [string]$ExpectedThumbprint) {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
        $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
            [Security.Cryptography.Pkcs.ContentInfo]::new($ReceiptBytes), $true)
        $Cms.Decode($SignatureBytes); $Cms.CheckSignature($true)
        return $Cms.SignerInfos.Count -eq 1 -and $null -ne $Cms.SignerInfos[0].Certificate -and
            $Cms.SignerInfos[0].Certificate.Thumbprint.ToUpperInvariant() -ceq $ExpectedThumbprint
    } catch { return $false }
}

function Assert-NativeCanaryReceipt([string]$Path, [object]$Request, [string]$GenerationDigest, [string]$Root,
    [int]$GenerationEpoch = $Request.Epoch, [switch]$Fixture) {
    if (-not $Fixture) { Assert-NonReparsePath $Path $Root }
    [byte[]]$ReceiptBytes = [IO.File]::ReadAllBytes($Path)
    $Lines = ConvertFrom-CanonicalAsciiBytes $ReceiptBytes 16384 "native_canary"
    $Names = @(
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
        "authoritative-result", "reboot-recovery", "raw-evidence-sha256")
    $Fields = Read-CanonicalFields $Lines $Names "windows-native-canary-receipt|3" "end-canary|" "native_canary"
    $IsReadiness = $null -ne $Request.PSObject.Properties["IsReadiness"] -and [bool]$Request.IsReadiness
    $Access = Get-TransportAclContract $Request.Fields.'request-sid'
    if ($Fields.nonce -cnotmatch '^[0-9a-f]{64}$' -or
        $Fields.host -cne [Environment]::MachineName.ToUpperInvariant() -or
        $Fields.epoch -cne [string]$GenerationEpoch -or $Fields.'generation-sha256' -cne $GenerationDigest -or
        @($Fields.'runner-path-sha256', $Fields.'runner-sha256', $Fields.'human-preview-sha256',
            $Fields.'human-confirmation-sha256', $Fields.'raw-evidence-sha256' |
            Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
        $Fields.'runner-publisher-thumbprint' -cnotmatch '^(?:[0-9A-F]{40}|[0-9A-F]{64})$' -or
        $Fields.'clock-skew-bound-seconds' -cne [string]$script:MaximumClockSkewSeconds -or
        $Fields.'request-sid' -cne $Access.RequestSid -or
        $Fields.'chroot-path-sha256' -cne $Access.ChrootPathSha256 -or
        $Fields.'chroot-directory-sddl-sha256' -cne $Access.ChrootDirectorySddlSha256 -or
        $Fields.'slot-directory-sddl-sha256' -cne $Access.SlotDirectorySddlSha256 -or
        $Fields.'slot-file-sddl-sha256' -cne $Access.SlotFileSddlSha256 -or
        $Fields.'results-directory-sddl-sha256' -cne $Access.ResultsDirectorySddlSha256 -or
        $Fields.'result-file-sddl-sha256' -cne $Access.ResultFileSddlSha256 -or
        (-not $IsReadiness -and $Request.Fields.'context-canary-sha256' -cne (Get-Sha256Bytes $ReceiptBytes))) {
        throw "native_canary_generation_mismatch"
    }
    foreach ($Name in @($Names[19..($Names.Count - 2)] | Where-Object {
                $_ -notin @("profile-efs-capability", "profile-efs-denied") })) {
        if ($Fields[$Name] -cne "passed") { throw "native_canary_incomplete" }
    }
    if ($Fields.'profile-efs-capability' -ceq "supported") {
        if ($Fields.'profile-efs-denied' -cne "passed") { throw "native_canary_incomplete" }
    } elseif ($Fields.'profile-efs-capability' -ceq "not-supported") {
        if ($Fields.'profile-efs-denied' -cne "not-supported") { throw "native_canary_incomplete" }
    } else { throw "native_canary_incomplete" }
    if (-not $Fixture) {
        $SignaturePath = $Path + ".p7s"
        $EvidencePath = Join-Path (Split-Path -Parent $Path) "native-canary.evidence"
        Assert-NonReparsePath $SignaturePath $Root; Assert-NonReparsePath $EvidencePath $Root
        [byte[]]$SignatureBytes = [IO.File]::ReadAllBytes($SignaturePath)
        [byte[]]$EvidenceBytes = [IO.File]::ReadAllBytes($EvidencePath)
        if ($SignatureBytes.Count -gt 65536 -or $EvidenceBytes.Count -gt 1048576 -or
            (Get-Sha256Bytes $EvidenceBytes) -cne $Fields.'raw-evidence-sha256' -or
            -not (Test-NativeCanaryDetachedSignature $ReceiptBytes $SignatureBytes `
                $Fields.'runner-publisher-thumbprint')) {
            throw "native_canary_provenance_invalid"
        }
    }
}

function Get-ProfileAuthorization([object]$Generation, [object]$Request, [byte[]]$PayloadBytes,
    [switch]$ReadinessProbe) {
    $PolicyLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Policy)) 65536 "policy"
    $ConstraintLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Generation.Files.Constraints)) 4194304 "constraints"
    $Action = $Request.Fields.'action-id'
    $PolicyMatches = @($PolicyLines | Where-Object { $_ -like "action|$Action|*" })
    if ($PolicyMatches.Count -ne 1) { throw "invalid_policy" }
    $Policy = $PolicyMatches[0].Split('|')
    if ($Policy.Count -ne 6 -or $Policy[2] -cne "windows-user-s4u-v1" -or $Policy[3] -cne "enabled" -or
        $Policy[4] -cne "profile-bundle-set-sha256" -or -not (Test-Digest $Policy[5])) {
        throw "action_not_enabled"
    }
    $ProfileLines = @($ConstraintLines | Select-Object -Skip 1 | Where-Object { $_ -like "profile|*" })
    if ($ProfileLines.Count -lt 1 -or
        (Get-Sha256Text (($ProfileLines -join "`n") + "`n")) -cne $Policy[5]) { throw "invalid_profile_constraints" }
    if ($Action -cnotin @("profile.inventory-managed-state.v1", "profile.apply-managed-bundle.v1") -or
        -not (Test-Token $Request.Fields.'policy-token')) { throw "profile_policy_token_not_found" }
    $Candidates = @($ProfileLines | Where-Object {
        $Parts = $_.Split('|')
        $Parts.Count -eq 9 -and $Parts[1] -ceq $Request.Fields.'policy-token'
    })
    if ($Candidates.Count -ne 1) { throw "profile_policy_token_not_found" }
    $Fields = $Candidates[0].Split('|')
    [int]$MaxEntries = 0; [long]$MaxBytes = 0
    if (-not (Test-Token $Fields[1]) -or $Fields[2] -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-Digest $Fields[3]) -or -not (Test-Digest $Fields[4]) -or -not (Test-Digest $Fields[5]) -or
        $Fields[6] -cnotin @("managed-only", "managed-and-prune") -or
        -not [int]::TryParse($Fields[7], [ref]$MaxEntries) -or $MaxEntries -lt 1 -or $MaxEntries -gt 100000 -or
        -not [long]::TryParse($Fields[8], [ref]$MaxBytes) -or $MaxBytes -lt 1 -or $MaxBytes -gt 1073741824 -or
        ($Request.Fields.'manager-source-identity' -cne $Fields[4] -and
            (-not $ReadinessProbe -or $Request.Fields.'manager-source-identity' -cne "not-applicable"))) {
        throw "invalid_profile_constraints"
    }
    $EntryMapPath = Join-Path $Generation.Root ("profiles/entry-maps/" + $Fields[4] + ".map")
    Assert-NonReparsePath $EntryMapPath (Split-Path -Parent $Generation.Root)
    [byte[]]$EntryMapBytes = [IO.File]::ReadAllBytes($EntryMapPath)
    if ((Get-Sha256Bytes $EntryMapBytes) -cne $Fields[4]) { throw "profile_entry_map_drift" }
    $EntryMap = Read-BrokerProfileEntryMap $EntryMapBytes
    $MarketplaceSetPath = Join-Path $Generation.Root ("profiles/marketplace-sets/" + $Fields[5] + ".set")
    Assert-NonReparsePath $MarketplaceSetPath (Split-Path -Parent $Generation.Root)
    [byte[]]$MarketplaceSetBytes = [IO.File]::ReadAllBytes($MarketplaceSetPath)
    if ((Get-Sha256Bytes $MarketplaceSetBytes) -cne $Fields[5]) { throw "profile_marketplace_set_drift" }
    $MarketplaceSet = Read-BrokerMarketplaceSet $MarketplaceSetBytes
    Assert-BrokerMarketplaceAuthorization $EntryMap $MarketplaceSet
    $IsApply = $Action -ceq "profile.apply-managed-bundle.v1"
    $PayloadDigest = Get-Sha256Bytes $PayloadBytes
    if ($ReadinessProbe) {
        if ($Request.PayloadLength -ne 0 -or $PayloadBytes.Count -ne 0 -or
            $Request.Fields.'payload-sha256' -cne $script:EmptySha256) {
            throw "profile_readiness_payload_binding_mismatch"
        }
    } elseif ($Request.PayloadLength -ne $PayloadBytes.Count -or
        $Request.Fields.'payload-sha256' -cne $PayloadDigest -or
        ($IsApply -and ($PayloadBytes.Count -lt 17 -or $PayloadBytes.Count -gt $MaxBytes)) -or
        (-not $IsApply -and ($PayloadBytes.Count -ne 0 -or
            $PayloadDigest -cne (Get-Sha256Bytes ([byte[]]@())))) -or
        $Request.Fields.'precondition-sha256' -ceq $PayloadDigest) {
        throw "profile_payload_binding_mismatch"
    }
    return [pscustomobject]@{ Token = $Fields[1]; TargetSid = $Fields[2]; ProfileRootId = $Fields[3]
        EntryMapSha256 = $Fields[4]; MarketplaceSetSha256 = $Fields[5]; DeleteMode = $Fields[6]
        MaxEntries = $MaxEntries; MaxBytes = $MaxBytes; EntryMapPath = $EntryMapPath; EntryMapBytes = $EntryMapBytes
        EntryMap = $EntryMap; MarketplaceSetPath = $MarketplaceSetPath; MarketplaceSetBytes = $MarketplaceSetBytes
        MarketplaceSet = $MarketplaceSet; BundleSha256 = $PayloadDigest; BundleLength = $PayloadBytes.Count }
}

function Test-BrokerManagedProfilePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 512 -or $Path.StartsWith('/') -or
        $Path.StartsWith('\') -or $Path.Contains('\') -or $Path.Contains(':') -or $Path.Contains("`0") -or
        $Path.Contains('//')) { return $false }
    $Reserved = '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$'
    foreach ($Segment in $Path.Split('/')) {
        if ($Segment -in @("", ".", "..") -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ') -or
            $Segment -match $Reserved -or $Segment -notmatch '^[A-Za-z0-9._@+ -]+$') { return $false }
    }
    $Folded = $Path.ToLowerInvariant(); $Segments = $Path.Split('/')
    $StandaloneSkillFile = $Segments.Count -ge 4 -and
        $Segments[0].ToLowerInvariant() -ceq ".codex" -and
        $Segments[1].ToLowerInvariant() -ceq "skills" -and
        $Segments[2] -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    return $Folded.StartsWith(".codex/machine-utilities/managed/") -or
        $Folded.StartsWith(".codex/machine-utilities/marketplace-stage/") -or
        $StandaloneSkillFile -or
        $Folded -match '^\.codex/settings(?:\.[a-z0-9._-]+)?\.json$' -or
        $Folded -match '^\.codex/config(?:\.[a-z0-9._-]+)?\.toml$' -or
        $Folded -ceq ".claude/settings.json"
}

function Get-BrokerCompiledProfileContract([string]$Path, [string]$Handler) {
    if (-not (Test-BrokerManagedProfilePath $Path)) { throw "invalid_profile_entry_map" }
    $Folded = $Path.ToLowerInvariant()
    switch ($Handler) {
        "json-scalar" {
            if ($Folded -ceq ".claude/settings.json") {
                return [pscustomobject]@{ Artifact = "claude-code-settings"; Manager = "claude";
                    LogicalIdentity = "claude-settings" }
            }
            if ($Folded -notmatch '^\.codex/settings(?:\.[a-z0-9._-]+)?\.json$') { throw "invalid_profile_entry_map" }
            return [pscustomobject]@{ Artifact = "codex-settings"; Manager = "codex"; LogicalIdentity = "codex-settings" }
        }
        "toml-scalar" {
            if ($Folded -notmatch '^\.codex/config(?:\.[a-z0-9._-]+)?\.toml$') { throw "invalid_profile_entry_map" }
            return [pscustomobject]@{ Artifact = "codex-settings"; Manager = "codex"; LogicalIdentity = "codex-settings" }
        }
        "standalone-skill-file" {
            $Parts = $Path.Split('/')
            if ($Parts.Count -lt 4 -or $Parts[0].ToLowerInvariant() -cne ".codex" -or
                $Parts[1].ToLowerInvariant() -cne "skills" -or
                $Parts[2] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
                throw "invalid_profile_entry_map"
            }
            $Skill = $Parts[2].ToLowerInvariant()
            return [pscustomobject]@{ Artifact = $Skill; Manager = "standalone"
                LogicalIdentity = "standalone-skill-file:$(Get-Sha256Text $Folded)" }
        }
        "marketplace-desired-record" {
            if ($Folded -cne ".codex/machine-utilities/managed/marketplace.desired") { throw "invalid_profile_entry_map" }
            return [pscustomobject]@{ Artifact = "marketplace-desired"; Manager = "fleet-agents";
                LogicalIdentity = "marketplace-desired" }
        }
        "marketplace-file" {
            $Parts = $Path.Split('/')
            if (-not $Folded.StartsWith(".codex/machine-utilities/marketplace-stage/") -or
                $Parts.Count -lt 5 -or -not (Test-Token $Parts[3])) { throw "invalid_profile_entry_map" }
            $Marketplace = $Parts[3].ToLowerInvariant()
            return [pscustomobject]@{ Artifact = $Marketplace; Manager = "fleet-agents";
                LogicalIdentity = "marketplace-file:$(Get-Sha256Text $Folded)" }
        }
        "managed-file" {
            $Parts = $Path.Split('/')
            if (-not $Folded.StartsWith(".codex/machine-utilities/managed/") -or $Parts.Count -lt 5 -or
                -not (Test-Token $Parts[3])) { throw "invalid_profile_entry_map" }
            $Artifact = $Parts[3].ToLowerInvariant()
            return [pscustomobject]@{ Artifact = $Artifact; Manager = "machine-utilities";
                LogicalIdentity = "managed-file:$(Get-Sha256Text $Folded)" }
        }
    }
    throw "invalid_profile_entry_map"
}

function Read-BrokerProfileEntryMap([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 4194304 "profile_entry_map"
    if ($Lines.Count -lt 2 -or $Lines[0] -cne "profile-entry-map|1" -or $Lines[-1] -cne "end-entry-map|") {
        throw "invalid_profile_entry_map"
    }
    $Entries = New-Object Collections.Generic.List[object]
    $Previous = ""; $Seen = @{}
    foreach ($Line in @($Lines | Select-Object -Skip 1 | Select-Object -SkipLast 1)) {
        $Parts = $Line.Split('|')
        if ($Parts.Count -ne 6 -or $Parts[0] -cne "entry" -or
            ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0) -or
            -not (Test-Atom $Parts[3]) -or -not (Test-Atom $Parts[4]) -or -not (Test-Atom $Parts[5])) {
            throw "invalid_profile_entry_map"
        }
        $Contract = Get-BrokerCompiledProfileContract $Parts[1] $Parts[2]
        if ($Parts[3] -cne $Contract.Artifact -or $Parts[4] -cne $Contract.Manager -or
            $Parts[5] -cne $Contract.LogicalIdentity) { throw "invalid_profile_entry_map" }
        $Key = $Parts[1].ToLowerInvariant()
        if ($Seen.ContainsKey($Key)) { throw "invalid_profile_entry_map" }
        $Seen[$Key] = $true; $Previous = $Line
        [void]$Entries.Add([pscustomobject]@{ Path = $Parts[1]; Handler = $Parts[2]; Artifact = $Parts[3];
            Manager = $Parts[4]; LogicalIdentity = $Parts[5] })
    }
    return [pscustomobject]@{ Entries = $Entries; Digest = Get-Sha256Bytes $Bytes }
}

function Read-BrokerMarketplaceSet([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 4194304 "profile_marketplace_set"
    if ($Lines.Count -lt 2 -or $Lines[0] -cne "profile-marketplace-set|1" -or
        $Lines[-1] -cne "end-marketplace-set|") { throw "invalid_profile_marketplace_set" }
    $Files = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $Plugins = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $InsensitivePlugins = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Records = New-Object Collections.Generic.List[object]
    $Previous = ""
    foreach ($Line in @($Lines | Select-Object -Skip 1 | Select-Object -SkipLast 1)) {
        if (($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0) -or
            $Line.Length -gt 2048) { throw "invalid_profile_marketplace_set" }
        $Parts = $Line.Split('|')
        if ($Parts[0] -ceq "file") {
            if ($Parts.Count -ne 3 -or -not (Test-Digest $Parts[2])) {
                throw "invalid_profile_marketplace_set"
            }
            $Contract = Get-BrokerCompiledProfileContract $Parts[1] "marketplace-file"
            if ($Files.ContainsKey($Parts[1])) { throw "invalid_profile_marketplace_set" }
            $Record = [pscustomobject]@{ Kind = "file"; Path = $Parts[1]; Sha256 = $Parts[2]
                Marketplace = $Contract.Artifact; Line = $Line }
            $Files.Add($Parts[1], $Record); [void]$Records.Add($Record)
        } elseif ($Parts[0] -ceq "plugin") {
            if ($Parts.Count -ne 4 -or
                $Parts[1] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                $Parts[2] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                -not (Test-Digest $Parts[3]) -or -not $Plugins.Add($Line) -or
                -not $InsensitivePlugins.Add("$($Parts[1])@$($Parts[2])")) {
                throw "invalid_profile_marketplace_set"
            }
            [void]$Records.Add([pscustomobject]@{ Kind = "plugin"; Plugin = $Parts[1]
                Marketplace = $Parts[2]; Sha256 = $Parts[3]; Line = $Line })
        } else { throw "invalid_profile_marketplace_set" }
        $Previous = $Line
    }
    return [pscustomobject]@{ Files = $Files; Plugins = $Plugins; Records = $Records.ToArray()
        PluginCount = $Plugins.Count; Digest = Get-Sha256Bytes $Bytes }
}

function Assert-BrokerMarketplaceAuthorization([object]$EntryMap, [object]$MarketplaceSet) {
    $MarketplaceEntries = @($EntryMap.Entries | Where-Object {
        $_.Handler -in @("marketplace-file", "marketplace-desired-record") })
    if (($MarketplaceEntries.Count -eq 0 -and $MarketplaceSet.Records.Count -ne 0) -or
        ($MarketplaceEntries.Count -ne 0 -and $MarketplaceSet.Records.Count -eq 0)) {
        throw "profile_marketplace_set_binding_mismatch"
    }
    $MapFiles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in @($MarketplaceEntries | Where-Object { $_.Handler -ceq "marketplace-file" })) {
        $MapFiles.Add($Entry.Path, $Entry)
        if (-not $MarketplaceSet.Files.ContainsKey($Entry.Path) -or
            $MarketplaceSet.Files[$Entry.Path].Path -cne $Entry.Path) {
            throw "profile_marketplace_set_binding_mismatch"
        }
    }
    foreach ($Record in $MarketplaceSet.Files.Values) {
        if (-not $MapFiles.ContainsKey($Record.Path) -or $MapFiles[$Record.Path].Path -cne $Record.Path) {
            throw "profile_marketplace_set_binding_mismatch"
        }
    }
    $DesiredEntries = @($MarketplaceEntries | Where-Object { $_.Handler -ceq "marketplace-desired-record" })
    if (($DesiredEntries.Count -eq 0 -and $MarketplaceSet.PluginCount -ne 0) -or
        ($DesiredEntries.Count -ne 1 -and $MarketplaceSet.PluginCount -ne 0) -or
        ($DesiredEntries.Count -eq 1 -and $MarketplaceSet.PluginCount -eq 0)) {
        throw "profile_marketplace_set_binding_mismatch"
    }
    $Marketplaces = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Record in $MarketplaceSet.Files.Values) { [void]$Marketplaces.Add($Record.Marketplace) }
    foreach ($Record in @($MarketplaceSet.Records | Where-Object { $_.Kind -ceq "plugin" })) {
        if (-not $Marketplaces.Contains($Record.Marketplace)) {
            throw "profile_marketplace_set_binding_mismatch"
        }
    }
}

function Get-BrokerProfileStateDigest([string]$ProfileRootId, [object[]]$States) {
    $Lines = New-Object Collections.Generic.List[string]
    [void]$Lines.Add("profile-live-state|1"); [void]$Lines.Add("profile-root-id|$ProfileRootId")
    foreach ($State in $States) {
        [void]$Lines.Add("entry|$($State.Path)|$($State.Presence)|$($State.Digest)|$($State.Manager)")
    }
    [void]$Lines.Add("end-live-state|")
    return Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines.ToArray())
}

function Initialize-BrokerProfileNativeTypes {
    if ("MachineUtilitiesBrokerProfileNative" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class MachineUtilitiesBrokerHeldDirectory : IDisposable
{
    public SafeFileHandle Handle { get; private set; }
    public string FinalPath { get; private set; }
    public uint VolumeSerial { get; private set; }
    public ulong FileId { get; private set; }
    internal MachineUtilitiesBrokerHeldDirectory(SafeFileHandle handle, string finalPath, uint volume, ulong fileId)
    { Handle = handle; FinalPath = finalPath; VolumeSerial = volume; FileId = fileId; }
    public void Dispose() { if (Handle != null) Handle.Dispose(); }
}

public sealed class MachineUtilitiesBrokerRegularFile
{
    public bool Exists { get; internal set; }
    public byte[] Bytes { get; internal set; }
}

public static class MachineUtilitiesBrokerProfileNative
{
    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, char[] path, uint length, uint flags);

    static string FinalPath(SafeFileHandle handle)
    {
        char[] buffer = new char[32768];
        uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
        if (length == 0 || length >= buffer.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "profile_final_path_failed");
        string value = new string(buffer, 0, (int)length);
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + value.Substring(8);
        return value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ? value.Substring(4) : value;
    }

    static BY_HANDLE_FILE_INFORMATION Information(SafeFileHandle handle)
    {
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(handle, out info))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "profile_path_information_failed");
        return info;
    }

    public static MachineUtilitiesBrokerHeldDirectory OpenDirectory(string path)
    {
        SafeFileHandle handle = CreateFileW(path, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose();
            throw new Win32Exception(error, "profile_directory_open_failed"); }
        try
        {
            BY_HANDLE_FILE_INFORMATION info = Information(handle);
            if ((info.FileAttributes & 0x10) == 0 || (info.FileAttributes & 0x400) != 0)
                throw new InvalidOperationException("profile_reparse_or_collision");
            return new MachineUtilitiesBrokerHeldDirectory(handle, FinalPath(handle), info.VolumeSerialNumber,
                ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow);
        }
        catch { handle.Dispose(); throw; }
    }

    public static MachineUtilitiesBrokerRegularFile ReadRegularFile(string path, string rootFinalPath)
    {
        SafeFileHandle handle = CreateFileW(path, 0x80000080, 5, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error(); handle.Dispose();
            if (error == 2 || error == 3)
                return new MachineUtilitiesBrokerRegularFile { Exists = false, Bytes = new byte[0] };
            throw new Win32Exception(error, "profile_file_open_failed");
        }
        using (handle)
        {
            BY_HANDLE_FILE_INFORMATION info = Information(handle);
            if ((info.FileAttributes & 0x410) != 0 || info.NumberOfLinks != 1)
                throw new InvalidOperationException("invalid_live_profile_state");
            string root = Path.GetFullPath(rootFinalPath).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!Path.GetFullPath(FinalPath(handle)).StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("profile_path_escape");
            using (FileStream stream = new FileStream(handle, FileAccess.Read))
            using (MemoryStream output = new MemoryStream())
            { stream.CopyTo(output); return new MachineUtilitiesBrokerRegularFile { Exists = true, Bytes = output.ToArray() }; }
        }
    }

    public static void AssertSingleLinkRegularFile(string path, string expectedPath)
    {
        SafeFileHandle handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose();
            throw new Win32Exception(error, "transport_file_open_failed"); }
        using (handle) { AssertHeldSingleLinkRegularFile(handle, expectedPath); }
    }

    public static void AssertHeldSingleLinkRegularFile(SafeFileHandle handle, string expectedPath)
    {
        BY_HANDLE_FILE_INFORMATION info = Information(handle);
        if ((info.FileAttributes & 0x410) != 0 || info.NumberOfLinks != 1)
            throw new InvalidOperationException("transport_file_link_drift");
        if (!Path.GetFullPath(FinalPath(handle)).Equals(Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("transport_file_path_drift");
    }
}
'@
}

function Get-BrokerProfilePathForSid([string]$Sid) {
    $Raw = Get-ItemPropertyValue -LiteralPath `
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" `
        -Name ProfileImagePath -ErrorAction Stop
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Raw)).TrimEnd('\')
}

function Get-BrokerProfileRootId([object]$RootHandle, [string]$TargetSid) {
    return Get-Sha256Utf8Text ("profile-root-identity|1`ntarget-sid|$TargetSid`nfinal-path|$($RootHandle.FinalPath.ToUpperInvariant())" +
        "`nvolume-serial|$($RootHandle.VolumeSerial.ToString('x8'))`nfile-id|$($RootHandle.FileId.ToString('x16'))`nend-profile-root|`n")
}

function New-BrokerProfileSession([object]$Authorization) {
    Initialize-BrokerProfileNativeTypes
    $RootPath = Get-BrokerProfilePathForSid $Authorization.TargetSid
    $RootHandle = [MachineUtilitiesBrokerProfileNative]::OpenDirectory($RootPath)
    if ((Get-BrokerProfileRootId $RootHandle $Authorization.TargetSid) -cne $Authorization.ProfileRootId -or
        -not $RootHandle.FinalPath.Equals($RootPath, [StringComparison]::OrdinalIgnoreCase)) {
        $RootHandle.Dispose(); throw "profile_root_identity_drift"
    }
    $Handles = New-Object Collections.Generic.List[object]; [void]$Handles.Add($RootHandle)
    $ByPath = @{}; $ByPath[$RootPath.ToLowerInvariant()] = $RootHandle
    return [pscustomobject]@{ RootPath = $RootPath; RootHandle = $RootHandle; Handles = $Handles; ByPath = $ByPath }
}

function Close-BrokerProfileSession([object]$Session) {
    if ($null -eq $Session) { return }
    for ($Index = $Session.Handles.Count - 1; $Index -ge 0; $Index--) { $Session.Handles[$Index].Dispose() }
}

function Get-BrokerProfileState([object]$Session, [object]$Entry) {
    $Segments = $Entry.Path.Split('/'); $Current = $Session.RootPath; $Missing = $false
    for ($Index = 0; $Index -lt $Segments.Count - 1; $Index++) {
        $Current = Join-Path $Current $Segments[$Index]
        $Key = [IO.Path]::GetFullPath($Current).ToLowerInvariant()
        if ($Session.ByPath.ContainsKey($Key)) { continue }
        if ([IO.File]::Exists($Current)) { throw "profile_path_collision" }
        if (-not [IO.Directory]::Exists($Current)) { $Missing = $true; break }
        $Handle = [MachineUtilitiesBrokerProfileNative]::OpenDirectory($Current)
        if (-not $Handle.FinalPath.Equals([IO.Path]::GetFullPath($Current), [StringComparison]::OrdinalIgnoreCase)) {
            $Handle.Dispose(); throw "profile_ancestor_identity_drift"
        }
        [void]$Session.Handles.Add($Handle); $Session.ByPath[$Key] = $Handle
    }
    if ($Missing) { return [pscustomobject]@{ Path = $Entry.Path; Presence = "absent"; Digest = "-"; Manager = "-" } }
    $Path = [IO.Path]::GetFullPath((Join-Path $Session.RootPath ($Entry.Path.Replace('/', '\'))))
    if ([IO.Directory]::Exists($Path)) { throw "profile_path_collision" }
    $Observed = [MachineUtilitiesBrokerProfileNative]::ReadRegularFile($Path, $Session.RootHandle.FinalPath)
    if (-not $Observed.Exists) { return [pscustomobject]@{ Path = $Entry.Path; Presence = "absent"; Digest = "-"; Manager = "-" } }
    return [pscustomobject]@{ Path = $Entry.Path; Presence = "present"; Digest = Get-Sha256Bytes $Observed.Bytes;
        Manager = (Get-BrokerCompiledProfileContract $Entry.Path $Entry.Handler).Manager }
}

function Get-BrokerProfileStates([object]$Session, [object]$EntryMap) {
    $States = New-Object Collections.Generic.List[object]
    foreach ($Entry in $EntryMap.Entries) { [void]$States.Add((Get-BrokerProfileState $Session $Entry)) }
    return $States.ToArray()
}

function Set-ExactSddl([string]$Path, [string]$Sddl) {
    if ($script:SelfTestFixture) { return }
    $Item = Get-Item -LiteralPath $Path -Force
    $Security = if ($Item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() }
        else { [Security.AccessControl.FileSecurity]::new() }
    $Security.SetSecurityDescriptorSddlForm($Sddl); Set-Acl -LiteralPath $Path -AclObject $Security
    Assert-ExactSddl $Path $Sddl
}

function Publish-ProfileHandoff([string]$Root, [object]$Request, [object]$Authorization, [byte[]]$BundleBytes,
    [switch]$ReadinessProbe) {
    $HandoffRoot = Join-Path $Root "profile/handoff"
    $ActivePath = Join-Path $HandoffRoot "active"
    Assert-ProfileActivePointerAvailable $ActivePath
    $RequestId = $Request.Fields.'request-id'; $Destination = Join-Path $HandoffRoot $RequestId
    if ([IO.Directory]::Exists($Destination)) { throw "profile_handoff_replay" }
    if ($ReadinessProbe -and ($BundleBytes.Count -ne 0 -or $Authorization.BundleLength -ne 0 -or
        $Authorization.BundleSha256 -cne $script:EmptySha256)) { throw "invalid_profile_readiness_handoff" }
    $ActionId = if ($ReadinessProbe) { "profile.readiness-probe.v1" } else { $Request.Fields.'action-id' }
    $Precondition = if ($ReadinessProbe) { $script:EmptySha256 } else { $Request.Fields.'precondition-sha256' }
    $Stage = Join-Path $HandoffRoot ("." + $RequestId + "." + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($Stage)
    try {
        Copy-ClaimedBytes (Join-Path $Stage "bundle") $BundleBytes $Authorization.BundleSha256
        Copy-ClaimedBytes (Join-Path $Stage "entry.map") $Authorization.EntryMapBytes $Authorization.EntryMapSha256
        Copy-ClaimedBytes (Join-Path $Stage "marketplace.set") $Authorization.MarketplaceSetBytes `
            $Authorization.MarketplaceSetSha256
        $HandoffLines = @(
            "windows-profile-handoff|1", "request-id|$RequestId", "action-id|$ActionId",
            "policy-token|$($Request.Fields.'policy-token')", "target-sid|$($Authorization.TargetSid)",
            "profile-root-id|$($Authorization.ProfileRootId)", "bundle-length|$($Authorization.BundleLength)",
            "bundle-sha256|$($Authorization.BundleSha256)", "entry-map-sha256|$($Authorization.EntryMapSha256)",
            "marketplace-set-sha256|$($Authorization.MarketplaceSetSha256)",
            "max-entries|$($Authorization.MaxEntries)", "max-bytes|$($Authorization.MaxBytes)",
            "delete-mode|$($Authorization.DeleteMode)",
            "request-precondition-sha256|$Precondition", "end-handoff|")
        [byte[]]$HandoffBytes = ConvertTo-CanonicalAsciiBytes $HandoffLines
        Write-AtomicBytes (Join-Path $Stage "handoff") $HandoffBytes
        [IO.File]::WriteAllBytes((Join-Path $Stage "result"), [byte[]]@())
        $Sid = $Authorization.TargetSid
        $DirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$Sid)"
        $ReadSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;$Sid)"
        $ResultSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100116;;;$Sid)"
        Set-ExactSddl $Stage $DirectorySddl
        foreach ($Name in @("bundle", "entry.map", "marketplace.set", "handoff")) {
            Set-ExactSddl (Join-Path $Stage $Name) $ReadSddl
        }
        Set-ExactSddl (Join-Path $Stage "result") $ResultSddl
        [IO.Directory]::Move($Stage, $Destination)
        Write-AtomicAscii $ActivePath @(
            "windows-profile-active|1", "request-id|$RequestId", "handoff-sha256|$(Get-Sha256Bytes $HandoffBytes)",
            "end-active|")
        Set-ExactSddl $ActivePath $ReadSddl
        return $Destination
    } finally { if ([IO.Directory]::Exists($Stage)) { [IO.Directory]::Delete($Stage, $true) } }
}

function Assert-ExactTaskSecurityDescriptor([string]$ExpectedSddl, [string]$ObservedSddl,
    [switch]$Fixture) {
    if ($Fixture -and -not $IsWindows) {
        if ($ExpectedSddl -cne $ObservedSddl) { throw "task_security_drift" }
        return
    }
    try {
        $Expected = [Security.AccessControl.RawSecurityDescriptor]::new($ExpectedSddl)
        $Observed = [Security.AccessControl.RawSecurityDescriptor]::new($ObservedSddl)
    } catch { throw "task_security_drift" }
    [byte[]]$ExpectedBytes = [byte[]]::new($Expected.BinaryLength)
    [byte[]]$ObservedBytes = [byte[]]::new($Observed.BinaryLength)
    $Expected.GetBinaryForm($ExpectedBytes, 0); $Observed.GetBinaryForm($ObservedBytes, 0)
    if ([Convert]::ToBase64String($ExpectedBytes) -cne [Convert]::ToBase64String($ObservedBytes)) {
        throw "task_security_drift"
    }
}

function Read-RegisteredTaskSecurityDescriptor([object]$Task) {
    return [string]$Task.GetSecurityDescriptor($script:TaskSecurityInformation)
}

function Assert-ProfileTask([string]$TargetSid, [string]$ProgramData) {
    $Service = $null; $Folder = $null; $Task = $null
    try {
        $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
        $Folder = $Service.GetFolder("\")
        foreach ($Contract in @(
            [pscustomobject]@{ Name = "MachineUtilitiesBrokerV1"; Kind = "system"; Sid = "S-1-5-18" },
            [pscustomobject]@{ Name = "MachineUtilitiesProfileV1"; Kind = "profile"; Sid = $TargetSid })) {
            $ObservedXml = Export-ScheduledTask -TaskName $Contract.Name -TaskPath "\" -ErrorAction Stop
            $ExpectedXml = Get-FixedTaskXml $Contract.Kind $Contract.Sid $ProgramData
            if ((Get-NormalizedTaskXml $ObservedXml) -cne (Get-NormalizedTaskXml $ExpectedXml)) {
                throw "task_contract_drift"
            }
            $Task = $Folder.GetTask($Contract.Name)
            Assert-ExactTaskSecurityDescriptor $script:ProfileTaskSddl `
                (Read-RegisteredTaskSecurityDescriptor $Task)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Task); $Task = $null
        }
    } finally {
        foreach ($ComObject in @($Task, $Folder, $Service)) {
            if ($null -ne $ComObject -and [Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
            }
        }
    }
}

function Write-ProfileOperationIdentity {
    param([string]$Path, [string]$RequestId, [string]$ResultPath, [string]$InstanceId,
        [string]$State, [string]$LastTaskResult = "-")
    if ($RequestId -cnotmatch '^request-[0-9a-f]{32}$' -or
        ($InstanceId -cne "-" -and $InstanceId -cnotmatch '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$') -or
        $State -cnotin @("queued", "active", "recovering", "terminal") -or
        ($LastTaskResult -cne "-" -and $LastTaskResult -notmatch '^-?(0|[1-9][0-9]{0,9})$') -or
        (($State -ceq "terminal") -ne ($LastTaskResult -cne "-"))) {
        throw "invalid_profile_operation_identity"
    }
    Write-AtomicAscii $Path @(
        "windows-profile-operation|1", "request-id|$RequestId", "task-name|MachineUtilitiesProfileV1",
        "instance-guid|$InstanceId", "result-path-sha256|$(Get-Sha256Utf8Text $ResultPath.ToUpperInvariant())",
        "state|$State", "last-task-result|$LastTaskResult", "end-profile-operation|")
    Protect-BrokerPath $Path
}

function Read-ProfileOperationIdentity([string]$Path, [string]$ExpectedRequestId) {
    if ($IsWindows) { Assert-ExactSddl $Path $script:ProtectedFileSddl }
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 2048 "profile_operation_identity"
    $Fields = Read-CanonicalFields $Lines @(
        "request-id", "task-name", "instance-guid", "result-path-sha256", "state", "last-task-result"
    ) "windows-profile-operation|1" "end-profile-operation|" "profile_operation_identity"
    if ($Fields.'request-id' -cne $ExpectedRequestId -or
        $Fields.'task-name' -cne "MachineUtilitiesProfileV1" -or
        ($Fields.'instance-guid' -cne "-" -and
            $Fields.'instance-guid' -cnotmatch '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$') -or
        -not (Test-Digest $Fields.'result-path-sha256') -or
        $Fields.state -cnotin @("queued", "active", "recovering", "terminal") -or
        ($Fields.'last-task-result' -cne "-" -and
            $Fields.'last-task-result' -notmatch '^-?(0|[1-9][0-9]{0,9})$') -or
        (($Fields.state -ceq "terminal") -ne ($Fields.'last-task-result' -cne "-"))) {
        throw "invalid_profile_operation_identity"
    }
    return [pscustomobject]@{ Fields = $Fields; Lines = $Lines }
}

function Set-ProfileOperationIdentityState([string]$Path, [object]$Identity, [string]$InstanceId,
        [string]$State) {
    if ($InstanceId -cnotmatch '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $State -cnotin @("active", "recovering")) { throw "invalid_profile_operation_identity" }
    $Updated = @($Identity.Lines); $Updated[3] = "instance-guid|$InstanceId"
    $Updated[5] = "state|$State"; $Updated[6] = "last-task-result|-"
    Write-AtomicAscii $Path $Updated; Protect-BrokerPath $Path
}

function Get-ProfileTaskLiveInstance([string]$ExpectedInstanceId) {
    $Service = $null; $Folder = $null; $Task = $null
    try {
        $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
        $Folder = $Service.GetFolder("\"); $Task = $Folder.GetTask("MachineUtilitiesProfileV1")
        $Instances = New-Object Collections.Generic.List[string]
        foreach ($Observed in @($Task.GetInstances(0))) {
            try {
                $ObservedId = ([Guid]::Parse(([string]$Observed.InstanceGuid).Trim('{}'))).ToString("D")
                [void]$Instances.Add($ObservedId)
            } finally {
                if ($null -ne $Observed -and [Runtime.InteropServices.Marshal]::IsComObject($Observed)) {
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Observed)
                }
            }
        }
        if ($ExpectedInstanceId -ceq "-") {
            if ($Instances.Count -gt 1) { throw "profile_task_instance_drift" }
            if ($Instances.Count -eq 1) { return $Instances[0] }
            return $null
        }
        if ($Instances.Contains($ExpectedInstanceId)) { return $ExpectedInstanceId }
        return $null
    } finally {
        foreach ($ComObject in @($Task, $Folder, $Service)) {
            if ($null -ne $ComObject -and [Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
            }
        }
    }
}

function Invoke-ProfileTaskInstance {
    param([string]$ResultPath, [string]$IdentityPath, [object]$Request,
        [string]$ClaimRoot, [string]$JournalRoot, [string]$PublicRoot, [ref]$LaunchCommitted,
        [switch]$ReadinessProbe, [string]$IdentityRequestId = "")
    if ([string]::IsNullOrWhiteSpace($IdentityRequestId)) { $IdentityRequestId = $Request.Fields.'request-id' }
    if ($IdentityRequestId -cnotmatch '^request-[0-9a-f]{32}$' -or
        (-not $ReadinessProbe -and $IdentityRequestId -cne $Request.Fields.'request-id')) {
        throw "invalid_profile_operation_identity"
    }
    $Before = Get-ScheduledTaskInfo -TaskName "MachineUtilitiesProfileV1" -TaskPath "\"
    $Service = $null; $Folder = $null; $Task = $null; $Instance = $null
    $InstanceId = "-"; $Recovering = $false
    try {
        $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
        $Folder = $Service.GetFolder("\"); $Task = $Folder.GetTask("MachineUtilitiesProfileV1")
        Write-ProfileOperationIdentity $IdentityPath $IdentityRequestId $ResultPath "-" "queued"
        # Crossing into the scheduler RPC is the conservative commit boundary. The call can launch
        # and complete before returning an instance object, so any failure from this point is partial.
        $LaunchCommitted.Value = $true
        $Instance = $Task.Run($null)
        $InstanceId = ([Guid]::Parse(([string]$Instance.InstanceGuid).Trim('{}'))).ToString("D")
        $Identity = Read-ProfileOperationIdentity $IdentityPath $IdentityRequestId
        Set-ProfileOperationIdentityState $IdentityPath $Identity $InstanceId "active"
        $LaunchReason = if ($ReadinessProbe) { "readiness_profile_probe_committed" } else { "profile_launch_committed" }
        Write-Journal $ClaimRoot $JournalRoot $Request "executing" $LaunchReason @{}
        if (-not $ReadinessProbe) { Write-PublicResult $PublicRoot "active" $Request "executing" $LaunchReason }
        $Deadline = [DateTime]::UtcNow.AddMinutes(10)
        do {
            $StillRunning = $false
            foreach ($Observed in @($Task.GetInstances(0))) {
                try {
                    $ObservedId = ([Guid]::Parse(([string]$Observed.InstanceGuid).Trim('{}'))).ToString("D")
                    if ($ObservedId -ceq $InstanceId) { $StillRunning = $true }
                } finally { if ($null -ne $Observed) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Observed) } }
            }
            if (-not $StillRunning) { break }
            if (-not $Recovering -and [DateTime]::UtcNow -ge $Deadline) {
                $Recovering = $true
                $Identity = Read-ProfileOperationIdentity $IdentityPath $IdentityRequestId
                Set-ProfileOperationIdentityState $IdentityPath $Identity $InstanceId "recovering"
                $RecoverReason = if ($ReadinessProbe) { "readiness_profile_probe_recovering" } else { "profile_operation_recovering" }
                Write-Journal $ClaimRoot $JournalRoot $Request "executing" $RecoverReason @{}
                if (-not $ReadinessProbe) { Write-PublicResult $PublicRoot "active" $Request "executing" $RecoverReason }
            }
            Start-Sleep -Seconds 1
        } while ($true)
        $After = Get-ScheduledTaskInfo -TaskName "MachineUtilitiesProfileV1" -TaskPath "\"
        if ($After.LastRunTime -le $Before.LastRunTime -or $After.LastTaskResult -notin @(0, 3) -or
            -not [IO.File]::Exists($ResultPath) -or (Get-Item -LiteralPath $ResultPath).Length -lt 1) {
            throw "profile_task_failed"
        }
        Write-ProfileOperationIdentity $IdentityPath $IdentityRequestId $ResultPath $InstanceId `
            "terminal" ([string][int]$After.LastTaskResult)
        return [pscustomobject]@{ InstanceId = $InstanceId; LastRunTime = $After.LastRunTime;
            ExitCode = [int]$After.LastTaskResult; RecoveryThresholdExceeded = $Recovering }
    } catch {
        $OriginalFailure = $_
        if ([IO.File]::Exists($IdentityPath)) {
            try {
                $Identity = Read-ProfileOperationIdentity $IdentityPath $IdentityRequestId
                if ($InstanceId -ceq "-") {
                    $ObservedInstance = Get-ProfileTaskLiveInstance "-"
                    if ($null -ne $ObservedInstance) {
                        $InstanceId = $ObservedInstance; $LaunchCommitted.Value = $true
                    }
                }
                if ($LaunchCommitted.Value -and $InstanceId -cne "-") {
                    Set-ProfileOperationIdentityState $IdentityPath $Identity $InstanceId "recovering"
                    $RecoverReason = if ($ReadinessProbe) { "readiness_profile_probe_recovering" } else { "profile_operation_recovering" }
                    Write-Journal $ClaimRoot $JournalRoot $Request "executing" $RecoverReason @{}
                    if (-not $ReadinessProbe) { Write-PublicResult $PublicRoot "active" $Request "executing" $RecoverReason }
                    while ($true) {
                        $ObservedInstance = $null
                        try { $ObservedInstance = Get-ProfileTaskLiveInstance $InstanceId } catch { }
                        if ($null -eq $ObservedInstance) { break }
                        Start-Sleep -Seconds 1
                    }
                    try {
                        $AfterFailure = Get-ScheduledTaskInfo -TaskName "MachineUtilitiesProfileV1" -TaskPath "\"
                        Write-ProfileOperationIdentity $IdentityPath $IdentityRequestId $ResultPath `
                            $InstanceId "terminal" ([string][int]$AfterFailure.LastTaskResult)
                    } catch { }
                }
            } catch {
                if ($LaunchCommitted.Value) {
                    # The task may still own machine state. An unverifiable terminal condition is fail-closed:
                    # keep this broker instance alive instead of allowing a new claim to overlap it.
                    while ($true) { Start-Sleep -Seconds 60 }
                }
            }
        }
        throw $OriginalFailure
    } finally {
        foreach ($ComObject in @($Instance, $Task, $Folder, $Service)) {
            if ($null -ne $ComObject -and [Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
            }
        }
    }
}

function Read-ProfileUnsupportedContextResult([byte[]]$Bytes, [object]$Request, [object]$Authorization) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "profile_context_result"
    $Expected = @(
        "windows-profile-context-result|1", "request-id|$($Request.Fields.'request-id')",
        "action-id|$($Request.Fields.'action-id')", "target-sid|$($Authorization.TargetSid)",
        "profile-root-id|$($Authorization.ProfileRootId)", "state|rejected", "reason|unsupported_context",
        "end-result|")
    if ($Lines.Count -ne $Expected.Count) { throw "invalid_profile_context_result" }
    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        if ($Lines[$Index] -cne $Expected[$Index]) { throw "invalid_profile_context_result" }
    }
    return [pscustomobject]@{ State = "rejected"; Reason = "unsupported_context";
        Sha256 = Get-Sha256Bytes $Bytes; PostStateSha256 = "-" }
}

function Read-ProfileTaskResult([byte[]]$Bytes, [object]$Request, [object]$Authorization,
    [object[]]$ObservedStates) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "profile_result"
    if ($Lines.Count -ne (21 + $Authorization.EntryMap.Entries.Count) -or
        $Lines[0] -cne "windows-profile-result|2" -or $Lines[-1] -cne "end-result|" -or
        $ObservedStates.Count -ne $Authorization.EntryMap.Entries.Count) {
        throw "invalid_profile_result"
    }
    $PostState = Get-BrokerProfileStateDigest $Authorization.ProfileRootId $ObservedStates
    $Reason = if ($Request.Fields.'action-id' -ceq "profile.inventory-managed-state.v1") {
        "inventory_verified"
    } else { "post_state_verified" }
    $Expected = @(
        "request-id|$($Request.Fields.'request-id')", "action-id|$($Request.Fields.'action-id')",
        "target-sid|$($Authorization.TargetSid)", "profile-root-id|$($Authorization.ProfileRootId)",
        "context-integrity|medium_or_lower", "context-elevated|false", "context-administrators|disabled",
        "context-dangerous-privileges|none", "context-authenticated-smb|unavailable",
        "context-programdata-write|denied", "context-task-write|denied", "context-service-control|denied",
        "context-hklm-write|denied", "context-other-profile-write|denied",
        "pre-state-sha256|$($Request.Fields.'precondition-sha256')", "post-state-sha256|$PostState",
        "state|completed", "reason|$Reason", "entry-count|$($Authorization.EntryMap.Entries.Count)")
    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        if ($Lines[$Index + 1] -cne $Expected[$Index]) { throw "profile_result_binding_mismatch" }
    }
    for ($Index = 0; $Index -lt $ObservedStates.Count; $Index++) {
        $State = $ObservedStates[$Index]
        $ExpectedEntry = "entry|$Index|$($State.Path)|$($State.Presence)|$($State.Digest)|$($State.Manager)"
        if ($Lines[20 + $Index] -cne $ExpectedEntry) { throw "profile_post_state_mismatch" }
    }
    return [pscustomobject]@{ State = "completed"; Reason = $Reason; Sha256 = Get-Sha256Bytes $Bytes;
        PostStateSha256 = $PostState }
}

function Assert-ProfileReadinessResult([byte[]]$Bytes, [object]$Request, [object]$Authorization,
    [object[]]$ObservedStates) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "profile_precondition_probe"
    $PostState = Get-BrokerProfileStateDigest $Authorization.ProfileRootId $ObservedStates
    $Expected = @(
        "windows-profile-precondition-probe|1", "request-id|$($Request.Fields.'request-id')",
        "action-id|profile.readiness-probe.v1", "policy-token|$($Authorization.Token)",
        "target-sid|$($Authorization.TargetSid)", "profile-root-id|$($Authorization.ProfileRootId)",
        "entry-map-sha256|$($Authorization.EntryMapSha256)",
        "marketplace-set-sha256|$($Authorization.MarketplaceSetSha256)",
        "post-state-sha256|$PostState", "entry-count|$($Authorization.EntryMap.Entries.Count)", "end-probe|")
    if ($Lines.Count -ne $Expected.Count) { throw "invalid_profile_precondition_probe" }
    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        if ($Lines[$Index] -cne $Expected[$Index]) { throw "profile_precondition_probe_binding_mismatch" }
    }
    return [pscustomobject]@{ PostStateSha256 = $PostState; Sha256 = Get-Sha256Bytes $Bytes }
}

function Assert-ProfileReadinessHandoffAcl([string]$HandoffRoot, [object]$Authorization) {
    if (-not $IsWindows) { return }
    $Sid = $Authorization.TargetSid
    $DirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$Sid)"
    $ReadSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;$Sid)"
    $ResultSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100116;;;$Sid)"
    Assert-ExactSddl $HandoffRoot $DirectorySddl
    foreach ($Name in @("bundle", "entry.map", "marketplace.set", "handoff")) {
        Assert-ExactSddl (Join-Path $HandoffRoot $Name) $ReadSddl
    }
    Assert-ExactSddl (Join-Path $HandoffRoot "result") $ResultSddl
}

function Invoke-BrokerReadinessProbes {
    param([string]$Root, [string]$StateRoot, [string]$ProgramData, [object]$Request,
        [object]$Generation, [string]$ClaimRoot, [string]$JournalRoot, [string]$PublicRoot)
    if ($null -eq $Request.PSObject.Properties["IsReadiness"] -or -not $Request.IsReadiness) {
        throw "invalid_readiness_control"
    }
    $WinGetBindings = Get-EnabledWinGetReadinessBindings $Generation
    $ProfileBindings = Get-EnabledProfileReadinessBindings $Generation
    $AllBindingCount = $WinGetBindings.Count + $ProfileBindings.Count
    if ($AllBindingCount -lt 1 -or $AllBindingCount -gt $script:MaximumReadinessProbeBindings) {
        throw "readiness_probe_capacity_exceeded"
    }
    $ActionRows = New-Object Collections.Generic.List[string]
    $ProfileRows = New-Object Collections.Generic.List[string]
    if ($WinGetBindings.Count -gt 0) {
        foreach ($Binding in $WinGetBindings) {
            $ProbeRequest = New-ReadinessProbeRequest $Request $Generation $Binding.Action $Binding.Token `
                $Binding.Context $script:EmptySha256
            $Precondition = Get-WinGetModulePrecondition $Root $ProbeRequest $Generation
            [void]$ActionRows.Add("action|$($Binding.Action)|$($Binding.Context)|$($Binding.Token)|$Precondition")
        }
    }
    $ProfileRowsByToken = @{}
    foreach ($Binding in $ProfileBindings) {
        $ProbeId = Get-ReadinessProbeRequestId $Request $Binding.Action $Binding.Token
        $ProbeRequest = New-ReadinessProbeRequest $Request $Generation $Binding.Action $Binding.Token `
            $Binding.Context ("0" * 64) $ProbeId
        $Authorization = Get-ProfileAuthorization $Generation $ProbeRequest ([byte[]]@()) -ReadinessProbe
        Assert-ProfileTask $Authorization.TargetSid $ProgramData
        $ProfileSession = $null; $HandoffRoot = $null; $ProbeIdentityPath = $null
        try {
            $HandoffRoot = Join-Path (Join-Path $Root "profile/handoff") $ProbeId
            $ProbeIdentityPath = Join-Path $ClaimRoot ("profile-probe-" + $ProbeId + ".identity")
            Write-ProfileOperationIdentity $ProbeIdentityPath $ProbeId (Join-Path $HandoffRoot "result") "-" "queued"
            $HandoffRoot = Publish-ProfileHandoff $Root $ProbeRequest $Authorization ([byte[]]@()) -ReadinessProbe
            Assert-ProfileReadinessHandoffAcl $HandoffRoot $Authorization
            Write-Journal $ClaimRoot $JournalRoot $Request "executing" "readiness_profile_probe_pending" @{}
            $ProbeLaunchCommitted = $false
            $TaskEvidence = Invoke-ProfileTaskInstance (Join-Path $HandoffRoot "result") `
                $ProbeIdentityPath $Request $ClaimRoot $JournalRoot $PublicRoot ([ref]$ProbeLaunchCommitted) `
                -ReadinessProbe -IdentityRequestId $ProbeId
            if ($TaskEvidence.ExitCode -ne 0) { throw "profile_precondition_probe_failed" }
            Assert-ProfileReadinessHandoffAcl $HandoffRoot $Authorization
            $ResultHandle = Open-ExclusiveBoundedFile (Join-Path $HandoffRoot "result") 4096
            try {
                $ProfileSession = New-BrokerProfileSession $Authorization
                $ObservedStates = Get-BrokerProfileStates $ProfileSession $Authorization.EntryMap
                $Probe = Assert-ProfileReadinessResult $ResultHandle.Bytes $ProbeRequest $Authorization $ObservedStates
            } finally { $ResultHandle.Stream.Dispose() }
            [void]$ActionRows.Add("action|$($Binding.Action)|$($Binding.Context)|$($Binding.Token)|$($Probe.PostStateSha256)")
            if (-not $ProfileRowsByToken.ContainsKey($Binding.Token)) {
                $ProfileRowsByToken[$Binding.Token] = "profile-constraint|$($Authorization.Token)|$($Authorization.TargetSid)|" +
                    "$($Authorization.ProfileRootId)|$($Authorization.EntryMapSha256)|$($Authorization.MarketplaceSetSha256)|" +
                    "$($Authorization.DeleteMode)|$($Authorization.MaxEntries)|$($Authorization.MaxBytes)|$($Probe.PostStateSha256)"
            }
        } finally {
            Close-BrokerProfileSession $ProfileSession
            if ($null -ne $HandoffRoot) {
                $ActivePointer = Join-Path $Root "profile/handoff/active"
                Remove-ReadinessProbeArtifacts $ActivePointer $ProbeId $ProbeIdentityPath
            }
        }
    }
    if ($ActionRows.Count -ne $AllBindingCount -or $ActionRows.Count -gt $script:MaximumReadinessProbeBindings) {
        throw "readiness_probe_incomplete"
    }
    foreach ($Row in @($ProfileRowsByToken.Values | Sort-Object)) { [void]$ProfileRows.Add($Row) }
    return [pscustomobject]@{ ActionRows = [string[]]@($ActionRows | Sort-Object)
        ProfileRows = [string[]]@($ProfileRows | Sort-Object)
        ProfileTaskReady = ($ProfileBindings.Count -gt 0) }
}

function Get-BrokerStartupDisposition([bool]$ProvisionMarkerPresent, [bool]$HostIdentityPresent) {
    if ($ProvisionMarkerPresent) { return "provision-only" }
    if (-not $HostIdentityPresent) { throw "host_identity_missing" }
    return "transport"
}

function Invoke-SelfTest {
    $Root = Join-Path ([IO.Path]::GetTempPath()) ("machine-utilities-windows-broker-" + [Guid]::NewGuid().ToString("N"))
    $script:SelfTestFixture = $true
    try {
        Initialize-BrokerProfileNativeTypes
        $PublicRoot = Join-Path $Root "public"
        $TransportPaths = Get-FixedTransportPaths $Root $PublicRoot
        $SlotRoot = $TransportPaths.Slot
        $ReplayRoot = Join-Path $Root "replay"
        $JournalRoot = Join-Path $Root "journal"
        $AuditRoot = Join-Path $Root "audit"
        [void][IO.Directory]::CreateDirectory($SlotRoot)
        [void][IO.Directory]::CreateDirectory($TransportPaths.Results)
        [void][IO.Directory]::CreateDirectory($PublicRoot)
        [void][IO.Directory]::CreateDirectory($ReplayRoot)
        [void][IO.Directory]::CreateDirectory($JournalRoot)
        [void][IO.Directory]::CreateDirectory($AuditRoot)
        $script:AuditRoot = $AuditRoot
        $script:BrokerRoot = $Root
        $script:PublicRoot = $PublicRoot
        $script:SlotRoot = $SlotRoot
        $script:ResultRoot = $TransportPaths.Results
        $script:RequestSid = "S-1-5-21-1-2-3-2001"
        $script:ProcessTempRoot = Join-Path $Root "process-temp"
        $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ((Get-BrokerStartupDisposition $true $false) -cne "provision-only") {
            throw "provision-only startup self-test failed"
        }
        $MissingHostRejected = $false
        try { [void](Get-BrokerStartupDisposition $false $false) } catch { $MissingHostRejected = $true }
        if (-not $MissingHostRejected) { throw "host identity startup self-test failed" }
        $HostIdentityFixturePath = Join-Path $Root "fixture-host.identity"
        [IO.File]::WriteAllBytes($HostIdentityFixturePath, (ConvertTo-CanonicalAsciiBytes @(
            "windows-host-identity|1", "host-id|fixture-host",
            "request-sid|S-1-5-21-1-2-3-2001", "request-principal|mu-request",
            "fleet-domain|example.invalid", "fleet-ca-fingerprint|SHA256:$('B' * 43)",
            "ca-generation|2", "previous-ca-fingerprint|SHA256:$('D' * 43)",
            "previous-ca-generation|1", "host-key-fingerprint|SHA256:$('A' * 43)",
            "end-identity|")))
        $HostIdentityFixture = Read-ProtectedHostIdentity $HostIdentityFixturePath
        if (-not (Test-ProtectedCaMembership $HostIdentityFixture ("SHA256:" + ("B" * 43)) "2") -or
            -not (Test-ProtectedCaMembership $HostIdentityFixture ("SHA256:" + ("D" * 43)) "1") -or
            (Test-ProtectedCaMembership $HostIdentityFixture ("SHA256:" + ("E" * 43)) "1") -or
            (Test-ProtectedCaMembership $HostIdentityFixture ("SHA256:" + ("D" * 43)) "2")) {
            throw "dual CA membership self-test failed"
        }
        $DualCaText = "256 SHA256:$('D' * 43) previous (ED25519)`n" +
            "256 SHA256:$('B' * 43) primary (ED25519)`n"
        Assert-ProtectedFleetCaFingerprintText $DualCaText $HostIdentityFixture ("SHA256:" + ("D" * 43))
        foreach ($RejectedCaText in @(
                "256 SHA256:$('B' * 43) primary (ED25519)`n",
                ($DualCaText + "256 SHA256:$('E' * 43) outside (ED25519)`n"),
                ($DualCaText + "256 SHA256:$('D' * 43) duplicate (ED25519)`n"))) {
            $CaSetRejected = $false
            try {
                Assert-ProtectedFleetCaFingerprintText $RejectedCaText $HostIdentityFixture `
                    ("SHA256:" + ("D" * 43))
            } catch { $CaSetRejected = $_.Exception.Message -eq "fleet_ca_drift" }
            if (-not $CaSetRejected) { throw "protected CA set rejection self-test failed" }
        }
        $OutsideCaRejected = $false
        try {
            Assert-ProtectedFleetCaFingerprintText $DualCaText $HostIdentityFixture `
                ("SHA256:" + ("E" * 43))
        } catch { $OutsideCaRejected = $_.Exception.Message -eq "fleet_ca_drift" }
        if (-not $OutsideCaRejected) { throw "outside protected CA self-test failed" }
        [IO.File]::Delete($HostIdentityFixturePath)
        $Digest = "a" * 64
        [xml]$SystemTaskXml = Get-FixedTaskXml "system" "S-1-5-18" "C:\ProgramData"
        [xml]$ProfileTaskXml = Get-FixedTaskXml "profile" "S-1-5-21-1-2-3-1001" "C:\ProgramData"
        foreach ($TaskXmlDocument in @($SystemTaskXml, $ProfileTaskXml)) {
            $TaskXmlNamespace = [Xml.XmlNamespaceManager]::new($TaskXmlDocument.NameTable)
            $TaskXmlNamespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
            if (@($TaskXmlDocument.SelectNodes("/t:Task/t:Triggers", $TaskXmlNamespace)).Count -ne 1 -or
                @($TaskXmlDocument.SelectNodes("/t:Task/t:Settings/t:MultipleInstancesPolicy[text()='IgnoreNew']",
                    $TaskXmlNamespace)).Count -ne 1 -or
                @($TaskXmlDocument.SelectNodes("/t:Task/t:Settings/t:ExecutionTimeLimit[text()='PT0S']",
                    $TaskXmlNamespace)).Count -ne 1) { throw "fixed task XML self-test failed" }
        }
        $SystemTaskNamespace = [Xml.XmlNamespaceManager]::new($SystemTaskXml.NameTable)
        $SystemTaskNamespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
        $ProfileTaskNamespace = [Xml.XmlNamespaceManager]::new($ProfileTaskXml.NameTable)
        $ProfileTaskNamespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
        if (@($SystemTaskXml.SelectNodes("/t:Task/t:Triggers/t:TimeTrigger", $SystemTaskNamespace)).Count -ne 1 -or
            @($SystemTaskXml.SelectNodes("/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:Interval[text()='PT1M']",
                $SystemTaskNamespace)).Count -ne 1 -or
            @($ProfileTaskXml.SelectNodes("/t:Task/t:Triggers/*", $ProfileTaskNamespace)).Count -ne 0 -or
            @($ProfileTaskXml.SelectNodes("//t:TimeTrigger|//t:Repetition", $ProfileTaskNamespace)).Count -ne 0 -or
            @($ProfileTaskXml.SelectNodes("/t:Task/t:Settings/t:StartWhenAvailable[text()='false']",
                $ProfileTaskNamespace)).Count -ne 1) { throw "task-kind trigger self-test failed" }
        $TaskDescriptorFixture = [pscustomobject]@{
            Descriptor = $script:ProfileTaskSddl
            GetFlags = [Collections.Generic.List[int]]::new()
        }
        $TaskDescriptorFixture | Add-Member -MemberType ScriptMethod -Name GetSecurityDescriptor -Value {
            param([int]$Flags)
            [void]$this.GetFlags.Add($Flags); return $this.Descriptor
        }
        Assert-ExactTaskSecurityDescriptor $script:ProfileTaskSddl `
            (Read-RegisteredTaskSecurityDescriptor $TaskDescriptorFixture) -Fixture
        if ($TaskDescriptorFixture.GetFlags.Count -ne 1 -or $TaskDescriptorFixture.GetFlags[0] -ne 0x7) {
            throw "broker task descriptor read flags self-test failed"
        }
        foreach ($BrokerTaskDescriptorDrift in @(
                $script:ProfileTaskSddl.Replace("O:SY", "O:BA"),
                $script:ProfileTaskSddl.Replace("G:BA", "G:SY"),
                ($script:ProfileTaskSddl + "(A;;FR;;;S-1-5-21-1-2-3-1001)"),
                ($script:ProfileTaskSddl + "(A;;FR;;;S-1-5-21-1-2-3-2001)"))) {
            $BrokerTaskDescriptorDriftRejected = $false
            try {
                Assert-ExactTaskSecurityDescriptor $script:ProfileTaskSddl $BrokerTaskDescriptorDrift -Fixture
            }
            catch { $BrokerTaskDescriptorDriftRejected = $_.Exception.Message -eq "task_security_drift" }
            if (-not $BrokerTaskDescriptorDriftRejected) {
                throw "broker task descriptor drift self-test failed"
            }
        }
        $RequestLines = @(
            "request|1", "target-host-id|fixture-host", "request-sid|S-1-5-21-1-2-3-2001",
            "plan-id|plan-0123456789abcdef", "request-id|request-0123456789abcdef0123456789abcdef",
            "action-id|winget.inventory-machine.v1", "policy-token|-", "broker-protocol|1",
            "broker-version|1.0.0", "broker-sha256|$Digest", "policy-sha256|$Digest",
            "constraints-sha256|$Digest", "payload-length|0",
            "payload-sha256|$(Get-Sha256Bytes ([byte[]]@()))", "precondition-sha256|$Digest", "created-at|$Now",
            "expires-at|$($Now + $script:MinimumRequestTtlSeconds)", "transport|windows-sftp", "request-principal|mu-request",
            "required-context|windows-system-v1", "observed-execution-principal|LocalSystem",
            "console-session-state|none", "platform-boundary|windows", "enrollment-epoch|7",
            "winget-context-sha256|$('3' * 64)", "context-canary-sha256|$Digest",
            "pinned-host-key-fingerprint|SHA256:$('A' * 43)",
            "node-id|fixture-node", "fleet-domain|example.invalid", "fleet-ca-fingerprint|SHA256:$('B' * 43)",
            "ca-generation|2", "node-key-fingerprint|SHA256:$('C' * 43)", "certificate-serial|42",
            "certificate-valid-after|20260101T000000Z", "certificate-valid-before|20270101T000000Z",
            "certificate-source-addresses|-", "manager-source-identity|not-applicable", "end-request|")
        $BoundaryRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $RequestLines)
        if (($BoundaryRequest.ExpiresAt - $BoundaryRequest.CreatedAt) -ne 420) {
            throw "minimum request TTL boundary self-test failed"
        }
        foreach ($BadTtl in @(419, 3601)) {
            $BadTtlLines = @($RequestLines | ForEach-Object {
                if ($_ -like "expires-at|*") { "expires-at|$($Now + $BadTtl)" } else { $_ }
            })
            $Rejected = $false
            try { [void](Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $BadTtlLines)) }
            catch { $Rejected = $_.Exception.Message -eq "invalid_request_ttl" }
            if (-not $Rejected) { throw "request TTL bound self-test failed" }
        }
        $NonCanonicalAction = @($RequestLines | ForEach-Object {
            if ($_ -ceq "action-id|winget.inventory-machine.v1") {
                "action-id|WINGET.INVENTORY-MACHINE.V1"
            } else { $_ }
        })
        $NonCanonicalActionRejected = $false
        try { [void](Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $NonCanonicalAction)) }
        catch { $NonCanonicalActionRejected = $_.Exception.Message -eq "invalid_request" }
        if (-not $NonCanonicalActionRejected) { throw "canonical action-id self-test failed" }
        [byte[]]$RequestBytes = ConvertTo-CanonicalAsciiBytes $RequestLines
        [byte[]]$SignatureBytes = ConvertTo-CanonicalAsciiBytes @(
            "-----BEGIN SSH SIGNATURE-----", "fixture", "-----END SSH SIGNATURE-----")
        [byte[]]$PayloadBytes = @()
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "request"), $RequestBytes)
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "request.sig"), $SignatureBytes)
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "payload"), $PayloadBytes)
        $CommitLines = @(
            "windows-slot-commit|1", "request-id|request-0123456789abcdef0123456789abcdef",
            "request-length|$($RequestBytes.Count)", "request-sha256|$(Get-Sha256Bytes $RequestBytes)",
            "signature-length|$($SignatureBytes.Count)", "signature-sha256|$(Get-Sha256Bytes $SignatureBytes)",
            "payload-length|0", "payload-sha256|$(Get-Sha256Bytes $PayloadBytes)", "end-commit|")
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "commit"), (ConvertTo-CanonicalAsciiBytes $CommitLines))
        $TransportAclFixture = Get-TransportAclContract $script:RequestSid
        if ($TransportAclFixture.SlotFile -cne
                "O:S-1-5-21-1-2-3-2001G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;S-1-5-21-1-2-3-2001)" -or
            $TransportAclFixture.ResultFile -cne
                "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00120089;;;S-1-5-21-1-2-3-2001)") {
            throw "transport ACL contract self-test failed"
        }
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "dynamic"), [byte[]]@())
        $UnknownSlotRejected = $false
        try { Assert-FixedTransportLayout $Root $PublicRoot $script:RequestSid }
        catch { $UnknownSlotRejected = $_.Exception.Message -eq "transport_unknown_entry" }
        if (-not $UnknownSlotRejected) { throw "transport unknown slot self-test failed" }
        [IO.File]::Delete((Join-Path $SlotRoot "dynamic"))
        [void][IO.Directory]::CreateDirectory($TransportPaths.LegacyIngress)
        $LegacyProjectionRejected = $false
        try { Assert-FixedTransportLayout $Root $PublicRoot $script:RequestSid }
        catch { $LegacyProjectionRejected = $_.Exception.Message -eq "legacy_transport_projection_live" }
        if (-not $LegacyProjectionRejected) { throw "transport legacy projection self-test failed" }
        [IO.Directory]::Delete($TransportPaths.LegacyIngress, $false)
        $Slot = Open-And-ValidateSlot $SlotRoot
        try {
            $MutationRejected = $false
            try { [IO.File]::Open((Join-Path $SlotRoot "request"), [IO.FileMode]::Open,
                    [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite).Dispose() } catch { $MutationRejected = $true }
            if (-not $MutationRejected) { throw "exclusive claim self-test failed" }
            $ClaimRoot = New-Claim $ReplayRoot $JournalRoot $Slot $Now
            Assert-DurableClaim $ClaimRoot $Slot
            if ((Get-Item -LiteralPath (Join-Path $SlotRoot "commit") -Force).Length -eq 0) {
                throw "claim retired commit before durable marker self-test failed"
            }
        } finally { Close-Slot $Slot }
        if (-not [IO.File]::Exists((Join-Path $ClaimRoot "request"))) { throw "claim copy self-test failed" }
        $ReservationPath = Join-Path $AuditRoot "request-0123456789abcdef0123456789abcdef.terminal"
        if ((Get-Item -LiteralPath $ReservationPath).Length -ne $script:TerminalReservationBytes) {
            throw "terminal audit reservation self-test failed"
        }
        $ReplayRejected = $false
        $Slot = Open-And-ValidateSlot $SlotRoot
        try { [void](New-Claim $ReplayRoot $JournalRoot $Slot $Now) } catch { $ReplayRejected = $_.Exception.Message -eq "replayed_request" } finally { Close-Slot $Slot }
        if (-not $ReplayRejected) { throw "replay self-test failed" }
        $Slot = Open-And-ValidateSlot $SlotRoot
        try { Consume-ClaimedSlotCommit $Slot $ClaimRoot } finally { Close-Slot $Slot }
        if ((Get-Item -LiteralPath (Join-Path $SlotRoot "commit") -Force).Length -ne 0) {
            throw "durable claim commit rotation self-test failed"
        }
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "commit"), (ConvertTo-CanonicalAsciiBytes $CommitLines))
        $Slot = Open-And-ValidateSlot $SlotRoot
        try {
            if (-not (Consume-ExistingClaimedSlotCommit $ReplayRoot $Slot)) {
                throw "durable claim recovery self-test failed"
            }
        } finally { Close-Slot $Slot }
        if ((Get-Item -LiteralPath (Join-Path $SlotRoot "commit") -Force).Length -ne 0) {
            throw "durable claim recovery rotation self-test failed"
        }

        foreach ($ProfileLaunchState in @("queued", "active", "recovering")) {
            $ProfileOrphan = Get-MissingProfileInstanceDisposition $ProfileLaunchState
            if ($ProfileOrphan.State -cne "partial" -or
                $ProfileOrphan.Reason -cne "orphaned_profile_result") {
                throw "profile scheduler crash-window self-test failed"
            }
        }
        $NonCanonicalRepairRejected = $false
        try { [void](Get-NativeRepairAction "ACTIVE" 1) }
        catch { $NonCanonicalRepairRejected = $_.Exception.Message -eq "invalid_live_process_identity" }
        if (-not $NonCanonicalRepairRejected) { throw "canonical recovery state self-test failed" }
        foreach ($NativeRepairVector in @(
                @("launch-pending", 1, "resume-and-recover"),
                @("launch-pending", 2, "recover"),
                @("active", 2, "recover"),
                @("recovering", 0, "terminal"),
                @("active", 3, "drift"))) {
            if ((Get-NativeRepairAction $NativeRepairVector[0] $NativeRepairVector[1]) -cne
                $NativeRepairVector[2]) { throw "native descendant recovery self-test failed" }
        }

        [void](Repair-ConservativeClaims $ReplayRoot $JournalRoot)
        $Recovered = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes((Join-Path $ClaimRoot "journal"))) 65536 "journal"
        if ($Recovered -notcontains "state|stale" -or $Recovered -notcontains "reason|broker_died_before_native") {
            throw "conservative recovery self-test failed"
        }
        if ((Get-Item -LiteralPath $ReservationPath).Length -ne $script:TerminalReservationBytes -or
            ([IO.File]::ReadAllText((Join-Path $AuditRoot "request-0123456789abcdef0123456789abcdef.audit"), $script:Ascii) |
                Select-String -Pattern 'windows-broker-audit-event\|1' -AllMatches).Matches.Count -lt 2) {
            throw "append audit terminalization self-test failed"
        }
        $FailureRequestLines = @($RequestLines)
        $FailureRequestLines[[Array]::IndexOf($FailureRequestLines,
            "request-id|request-0123456789abcdef0123456789abcdef")] =
            "request-id|request-1123456789abcdef0123456789abcdef"
        $FailureRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $FailureRequestLines)
        $FailureClaim = Join-Path $ReplayRoot $FailureRequest.Fields.'request-id'
        [void][IO.Directory]::CreateDirectory($FailureClaim)
        Write-AtomicBytes (Join-Path $FailureClaim "request") $FailureRequest.Bytes
        Write-AtomicAscii (Join-Path $FailureClaim "tombstone") @(
            "windows-tombstone|1", "request-id|$($FailureRequest.Fields.'request-id')",
            "retain-until|$($Now + 180)", "enrollment-epoch|7", "state|validating", "end-tombstone|")
        [void](Reserve-AuditEvidence $AuditRoot $FailureRequest)
        Write-Journal $FailureClaim $JournalRoot $FailureRequest "validating" "claim_reserved" @{}
        $script:InjectAuditFailureAfterCanonical = $true
        $Injected = $false
        try { Write-Journal $FailureClaim $JournalRoot $FailureRequest "completed" "post_state_verified" @{} }
        catch { $Injected = $_.Exception.Message -eq "injected_post_canonical_audit_failure" }
        $Absorbing = $false
        try { Write-Journal $FailureClaim $JournalRoot $FailureRequest "partial" "broker_exception_after_native" @{} }
        catch { $Absorbing = $_.Exception.Message -eq "terminal_state_absorbing" }
        if (-not $Injected -or -not $Absorbing -or (Get-ClaimJournalState $FailureClaim).State -cne "completed") {
            throw "terminal absorption self-test failed"
        }
        [void](Repair-ConservativeClaims $ReplayRoot $JournalRoot)
        if ((Get-Item -LiteralPath (Join-Path $AuditRoot ($FailureRequest.Fields.'request-id' + ".terminal"))).Length -ne
            $script:TerminalReservationBytes) { throw "terminal audit repair self-test failed" }
        Write-AtomicAscii (Join-Path $FailureClaim "tombstone") @(
            "windows-tombstone|1", "request-id|$($FailureRequest.Fields.'request-id')",
            "retain-until|$($Now + 180)", "enrollment-epoch|7", "state|validating", "end-tombstone|")
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot $Now
        $RecoveredTombstone = ConvertFrom-CanonicalAsciiBytes (
            [IO.File]::ReadAllBytes((Join-Path $FailureClaim "tombstone"))) 2048 "tombstone"
        if ($RecoveredTombstone[4] -cne "state|completed") {
            throw "terminal tombstone crash recovery self-test failed"
        }
        Write-AtomicAscii (Join-Path $FailureClaim "tombstone") @(
            "windows-tombstone|1", "request-id|$($FailureRequest.Fields.'request-id')",
            "retain-until|$($Now - 1)", "enrollment-epoch|7", "state|validating", "end-tombstone|")
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot $Now
        $RecoveredTombstone = ConvertFrom-CanonicalAsciiBytes (
            [IO.File]::ReadAllBytes((Join-Path $FailureClaim "tombstone"))) 2048 "tombstone"
        [long]$RecoveredRetainUntil = [long]$RecoveredTombstone[2].Split('|')[1]
        if ($RecoveredTombstone[4] -cne "state|completed" -or
            $RecoveredRetainUntil -lt ($Now + $script:TerminalResultRetentionSeconds)) {
            throw "terminal tombstone retention recovery self-test failed"
        }
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot ($RecoveredRetainUntil - 1)
        if (-not [IO.Directory]::Exists($FailureClaim)) {
            throw "terminal tombstone retention window self-test failed"
        }
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot $RecoveredRetainUntil
        if ([IO.Directory]::Exists($FailureClaim) -or
            [IO.File]::Exists((Join-Path $AuditRoot ($FailureRequest.Fields.'request-id' + ".audit")))) {
            throw "bounded audit compaction self-test failed"
        }
        $OrphanRequestLines = @($RequestLines)
        $OrphanRequestLines[[Array]::IndexOf($OrphanRequestLines,
            "request-id|request-0123456789abcdef0123456789abcdef")] =
            "request-id|request-2123456789abcdef0123456789abcdef"
        $OrphanRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $OrphanRequestLines)
        [void](Reserve-AuditEvidence $AuditRoot $OrphanRequest)
        $OrphanProtectedJournal = Join-Path $JournalRoot ($OrphanRequest.Fields.'request-id' + ".result")
        Write-AtomicBytes $OrphanProtectedJournal ([byte[]]@())
        Protect-BrokerPath $OrphanProtectedJournal
        Write-PublicResult $PublicRoot "last" $OrphanRequest "stale" "broker_died_before_native" $Digest
        $OrphanPublicResult = Join-Path $TransportPaths.Results ($OrphanRequest.Fields.'request-id' + ".result")
        $OrphanReadinessResult = Join-Path $TransportPaths.Results `
            ($OrphanRequest.Fields.'request-id' + ".readiness")
        Write-AtomicAscii $OrphanReadinessResult @(
            "windows-broker-readiness-result|1", "request-id|$($OrphanRequest.Fields.'request-id')",
            "state|unavailable", "reason|fresh_probe_failed", "end-readiness|")
        if ($IsWindows) {
            Set-ExactSddl $OrphanReadinessResult (Get-TransportAclContract $script:RequestSid).ResultFile
        }
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot $Now
        if ([IO.File]::Exists((Join-Path $AuditRoot ($OrphanRequest.Fields.'request-id' + ".terminal"))) -or
            [IO.File]::Exists($OrphanProtectedJournal) -or [IO.File]::Exists($OrphanPublicResult) -or
            [IO.File]::Exists($OrphanReadinessResult)) {
            throw "orphan audit reservation self-test failed"
        }
        $ReservationFailureLines = @($RequestLines)
        $ReservationFailureLines[[Array]::IndexOf($ReservationFailureLines,
            "request-id|request-0123456789abcdef0123456789abcdef")] =
            "request-id|request-3123456789abcdef0123456789abcdef"
        $ReservationFailureRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $ReservationFailureLines)
        $script:InjectAuditReservationFailureAfterHeader = $true
        $ReservationFailureRejected = $false
        try { [void](Reserve-AuditEvidence $AuditRoot $ReservationFailureRequest) }
        catch { $ReservationFailureRejected = $_.Exception.Message -eq "audit_reservation_unavailable" }
        if (-not $ReservationFailureRejected -or
            @([IO.Directory]::EnumerateFiles($AuditRoot, "request-3123456789abcdef0123456789abcdef.*")).Count -ne 0) {
            throw "audit reservation cleanup self-test failed"
        }
        $ClaimFailureLines = @($RequestLines)
        $ClaimFailureLines[[Array]::IndexOf($ClaimFailureLines,
            "request-id|request-0123456789abcdef0123456789abcdef")] =
            "request-id|request-4123456789abcdef0123456789abcdef"
        $ClaimFailureRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $ClaimFailureLines)
        $script:InjectClaimFailureAfterReservation = $true
        $ClaimFailureRejected = $false
        try { [void](New-Claim $ReplayRoot $JournalRoot ([pscustomobject]@{ Request = $ClaimFailureRequest }) $Now) }
        catch { $ClaimFailureRejected = $_.Exception.Message -eq "injected_claim_failure_after_reservation" }
        if (-not $ClaimFailureRejected -or
            @([IO.Directory]::EnumerateFiles($AuditRoot, "request-4123456789abcdef0123456789abcdef.*")).Count -ne 0 -or
            @([IO.Directory]::EnumerateDirectories($ReplayRoot, ".claim-request-4123456789abcdef0123456789abcdef.*")).Count -ne 0) {
            throw "claim reservation cleanup self-test failed"
        }
        $Request = Read-BrokerRequest $RequestBytes
        $FixtureWinGetContextDigest = "3" * 64
        $HelperBytes = Get-HelperRequestBytes $Request ("b" * 64)
        $HelperLines = ConvertFrom-CanonicalAsciiBytes $HelperBytes 4096 "helper_request"
        if ($HelperLines.Count -ne 11 -or
            $HelperLines[7] -cne "winget-context-sha256|$FixtureWinGetContextDigest" -or
            $HelperLines[7] -ceq "winget-context-sha256|$($Request.Fields.'context-canary-sha256')" -or
            $HelperLines[8] -cne ("provider-lock-sha256|" + ("b" * 64))) {
            throw "helper stdin contract self-test failed"
        }
        $VectorAuthority = "2b048d26707cdbfdfb379b025237d5bfccb259bdc5fc5d621f3138f39dbd6a87"
        $ProviderContextBytes = ConvertTo-CanonicalAsciiBytes @(
            "winget-provider-context|1", "state-identifier|machine-utilities-e7-$VectorAuthority",
            "source-id|catalog-id", "source-name|catalog-name", "source-type|Microsoft.PreIndexed.Package",
            "source-argument|https://example.invalid/catalog",
            "source-argument-sha256|84be0dc1f120ab994c9b03c3ad0a4b13a641b2196e290d46130dabcdece68006",
            "source-origin|predefined", "source-trust|trusted", "source-explicit|true",
            "source-last-update-min-unix|1700000000", "deployment-file-set-sha256|$('b' * 64)",
            "app-installer-identity-sha256|$('c' * 64)", "end-context|")
        $ProviderContext = Read-WinGetProviderContext $ProviderContextBytes
        $ExplicitDefaultPortRejected = $false
        $ExplicitDefaultPortArgument = "https://example.invalid:443/catalog"
        try {
            [void](Read-WinGetProviderContext (ConvertTo-CanonicalAsciiBytes @(
                "winget-provider-context|1", "state-identifier|machine-utilities-e7-$VectorAuthority",
                "source-id|catalog-id", "source-name|catalog-name", "source-type|Microsoft.PreIndexed.Package",
                "source-argument|$ExplicitDefaultPortArgument",
                "source-argument-sha256|$(Get-Sha256Utf8Text $ExplicitDefaultPortArgument)",
                "source-origin|predefined", "source-trust|trusted", "source-explicit|true",
                "source-last-update-min-unix|1700000000", "deployment-file-set-sha256|$('b' * 64)",
                "app-installer-identity-sha256|$('c' * 64)", "end-context|")))
        } catch { $ExplicitDefaultPortRejected = $_.Exception.Message -eq "invalid_winget_provider_context" }
        if (-not $ExplicitDefaultPortRejected) { throw "WinGet explicit-default-port self-test failed" }
        $FixtureGeneration = [pscustomobject]@{
            GenerationDigest = ("5" * 64); ProviderContext = $ProviderContext
            Digests = [ordered]@{ Policy = ("1" * 64); Constraints = ("2" * 64)
                Context = ("3" * 64); ProviderLock = ("4" * 64) }
            Files = [ordered]@{}
        }
        if ((Get-WinGetStateAuthoritySha256 7 $FixtureGeneration $ProviderContext) -cne $VectorAuthority) {
            throw "WinGet state authority parity self-test failed"
        }
        $SettingsSha256 = Get-WinGetExpectedSettingsSha256 $Request $FixtureGeneration
        $StateIdentifierSha256 = Get-Sha256Utf8Text $ProviderContext.StateIdentifier
        $SourceLine = "source|catalog-id|catalog-name|Microsoft.PreIndexed.Package|" +
            "84be0dc1f120ab994c9b03c3ad0a4b13a641b2196e290d46130dabcdece68006|" +
            "predefined|trusted|true|1700000000"
        $ProvisionRequest = Read-WinGetProvisionRequest (Get-WinGetProvisionRequestBytes 7 $FixtureGeneration)
        $ProvisionResultBytes = ConvertTo-CanonicalAsciiBytes @(
            "winget-provider-provision-result|1", "state|completed", "reason|provider_state_provisioned",
            "enrollment-epoch|7", "generation-sha256|$('5' * 64)", "provider-lock-sha256|$('4' * 64)",
            "deployment-file-set-sha256|$('b' * 64)", "app-installer-identity-sha256|$('c' * 64)",
            "provider-version|1.29.280", "state-identifier-sha256|$StateIdentifierSha256",
            "provider-runtime-roots-sha256|$('d' * 64)", "settings-sha256|$SettingsSha256", $SourceLine,
            "end-provision-result|")
        $ProvisionReceipt = Read-WinGetProvisionResult $ProvisionResultBytes $ProvisionRequest $FixtureGeneration 0
        $NonCanonicalProvisionState = $script:Ascii.GetBytes(
            $script:Ascii.GetString($ProvisionResultBytes).Replace("state|completed", "state|COMPLETED"))
        $NonCanonicalProvisionRejected = $false
        try { [void](Read-WinGetProvisionResult $NonCanonicalProvisionState $ProvisionRequest $FixtureGeneration 0) }
        catch { $NonCanonicalProvisionRejected = $_.Exception.Message -eq "invalid_winget_provision_result" }
        if (-not $NonCanonicalProvisionRejected) { throw "canonical provision result self-test failed" }
        $HelperResult = ConvertTo-CanonicalAsciiBytes @(
            "winget-helper-result|1", "request-id|$($Request.Fields.'request-id')",
            "action-id|winget.inventory-machine.v1", "state|completed", "reason|inventory_verified",
            "provider-lock-sha256|$('4' * 64)", "deployment-file-set-sha256|$('b' * 64)",
            "app-installer-identity-sha256|$('c' * 64)", "provider-version|1.29.280",
            "state-identifier-sha256|$StateIdentifierSha256", "provider-runtime-roots-sha256|$('d' * 64)",
            "settings-sha256|$SettingsSha256", $SourceLine, "dependency-authority|source-delegated-all",
            "installer-hash-authority|provider-enforced-manifest-hash", "dependency-closure|not-exposed-by-provider",
            "dependency-provenance|not-exposed-by-provider", "windows-features|root-installer-provider-managed",
            "package-count|0", "provider-status|not-applicable", "provider-extended-error|-",
            "provider-installer-error|-", "reboot-required|false",
            "pre-state-sha256|$($Request.Fields.'precondition-sha256')",
            "post-state-sha256|$($Request.Fields.'precondition-sha256')", "end-result|")
        $ParsedResult = Read-HelperResult $HelperResult $Request $FixtureGeneration $ProvisionReceipt 0
        if ($ParsedResult.State -cne "completed") { throw "helper result contract self-test failed" }
        $AdvancedSourceLine = $SourceLine.Replace("|1700000000", "|1700000001")
        $AdvancedHelperResult = $script:Ascii.GetBytes(
            $script:Ascii.GetString($HelperResult).Replace($SourceLine, $AdvancedSourceLine))
        $AdvancedParsedResult = Read-HelperResult $AdvancedHelperResult $Request $FixtureGeneration `
            $ProvisionReceipt 0
        if ($AdvancedParsedResult.Source.LastUpdate -ne 1700000001) {
            throw "monotonic WinGet source self-test failed"
        }
        $AdvancedProvisionResult = $script:Ascii.GetBytes(
            $script:Ascii.GetString($ProvisionResultBytes).Replace($SourceLine, $AdvancedSourceLine))
        $AdvancedProvisionReceipt = Read-WinGetProvisionResult $AdvancedProvisionResult $ProvisionRequest `
            $FixtureGeneration 0
        $RollbackRejected = $false
        try {
            [void](Read-HelperResult $HelperResult $Request $FixtureGeneration $AdvancedProvisionReceipt 0)
        } catch { $RollbackRejected = $_.Exception.Message -eq "helper_result_binding_mismatch" }
        if (-not $RollbackRejected) { throw "WinGet source rollback self-test failed" }
        foreach ($InvalidSourceLine in @(
                $SourceLine.Replace("catalog-id", "other-id"),
                $SourceLine.Replace("catalog-name", "other-catalog"),
                $SourceLine.Replace("Microsoft.PreIndexed.Package", "Microsoft.Rest"),
                $SourceLine.Replace(
                    "84be0dc1f120ab994c9b03c3ad0a4b13a641b2196e290d46130dabcdece68006", ('0' * 64)),
                $SourceLine.Replace("|predefined|", "|configured|"),
                $SourceLine.Replace("|trusted|", "|untrusted|"),
                $SourceLine.Replace("|true|", "|false|"),
                $SourceLine.Replace("|1700000000", "|1699999999"),
                $SourceLine.Replace("|1700000000", "|-1"),
                $SourceLine.Replace("|1700000000", "|not-a-number"),
                $SourceLine.Replace("|1700000000", "|9223372036854775808"))) {
            $InvalidHelperResult = $script:Ascii.GetBytes(
                $script:Ascii.GetString($HelperResult).Replace($SourceLine, $InvalidSourceLine))
            $InvalidSourceRejected = $false
            try { [void](Read-HelperResult $InvalidHelperResult $Request $FixtureGeneration $ProvisionReceipt 0) }
            catch {
                $InvalidSourceRejected = $_.Exception.Message -cin @(
                    "winget_source_evidence_mismatch", "helper_result_binding_mismatch")
            }
            if (-not $InvalidSourceRejected) { throw "invalid WinGet source continuity self-test failed" }
        }
        $NonCanonicalHelperState = $script:Ascii.GetBytes(
            $script:Ascii.GetString($HelperResult).Replace("state|completed", "state|COMPLETED"))
        $NonCanonicalHelperRejected = $false
        try { [void](Read-HelperResult $NonCanonicalHelperState $Request $FixtureGeneration $ProvisionReceipt 0) }
        catch { $NonCanonicalHelperRejected = $_.Exception.Message -eq "helper_result_binding_mismatch" }
        if (-not $NonCanonicalHelperRejected) { throw "canonical helper result self-test failed" }
        $ExitMismatchRejected = $false
        try { [void](Read-HelperResult $HelperResult $Request $FixtureGeneration $ProvisionReceipt 2) }
        catch { $ExitMismatchRejected = $_.Exception.Message -eq "helper_exit_state_mismatch" }
        if (-not $ExitMismatchRejected) { throw "helper exit-state self-test failed" }

        $PointerDigest = Get-GenerationDigest 7 $Digest $Digest $Digest ("b" * 64) $Digest
        $Pointer = Read-ActiveGenerationPointer (ConvertTo-CanonicalAsciiBytes @(
            "machine-utilities-active-generation|1", "epoch|7", "generation-sha256|$PointerDigest", "end-generation|"))
        if ($Pointer.Epoch -ne 7 -or $Pointer.Digest -cne $PointerDigest) { throw "pointer self-test failed" }
        $NativeCanaryPath = Join-Path $Root "native-canary.receipt"
        $NativeCanaryAccess = Get-TransportAclContract $Request.Fields.'request-sid'
        $NativeCanaryLines = @(
            "windows-native-canary-receipt|3", "nonce|$('9' * 64)",
            "host|$([Environment]::MachineName.ToUpperInvariant())", "epoch|7", "generation-sha256|$PointerDigest",
            "runner-path-sha256|$('1' * 64)", "runner-sha256|$('2' * 64)",
            "runner-publisher-thumbprint|$('D' * 40)", "issued-at|1", "expires-at|2",
            "human-preview-sha256|$('3' * 64)", "human-confirmation-sha256|$('4' * 64)",
            "clock-skew-bound-seconds|300", "request-sid|$($NativeCanaryAccess.RequestSid)",
            "chroot-path-sha256|$($NativeCanaryAccess.ChrootPathSha256)",
            "chroot-directory-sddl-sha256|$($NativeCanaryAccess.ChrootDirectorySddlSha256)",
            "slot-directory-sddl-sha256|$($NativeCanaryAccess.SlotDirectorySddlSha256)",
            "slot-file-sddl-sha256|$($NativeCanaryAccess.SlotFileSddlSha256)",
            "results-directory-sddl-sha256|$($NativeCanaryAccess.ResultsDirectorySddlSha256)",
            "result-file-sddl-sha256|$($NativeCanaryAccess.ResultFileSddlSha256)",
            "system-task-logged-off|passed", "profile-task-logged-off|passed", "profile-token-limited|passed",
            "profile-no-network|passed", "profile-authenticated-smb-denied|passed",
            "profile-efs-capability|supported", "profile-efs-denied|passed",
            "chroot-physical-layout|passed", "chroot-effective-access|passed", "slot-write-data-only|passed",
            "slot-create-list-rename-denied|passed", "slot-owner-rights|passed", "slot-quota|passed",
            "result-read-only|passed", "result-non-list|passed", "request-no-task-rights|passed",
            "claim-copy-race|passed", "openssh-y-verify|passed",
            "openssh-print-pubkey|passed", "openssh-certificate-parse|passed", "winget-system-inventory|passed",
            "winget-corrupt-hash|passed", "winget-dangerous-options|passed",
            "profile-path-containment|passed", "authoritative-result|passed", "reboot-recovery|passed",
            "raw-evidence-sha256|$('5' * 64)",
            "end-canary|")
        [byte[]]$NativeCanaryBytes = ConvertTo-CanonicalAsciiBytes $NativeCanaryLines
        [IO.File]::WriteAllBytes($NativeCanaryPath, $NativeCanaryBytes)
        $Request.Fields['context-canary-sha256'] = Get-Sha256Bytes $NativeCanaryBytes
        Assert-NativeCanaryReceipt $NativeCanaryPath $Request $PointerDigest $Root -Fixture
        $BadAccessCanaryLines = @($NativeCanaryLines | ForEach-Object {
            if ($_ -like "slot-file-sddl-sha256|*") { "slot-file-sddl-sha256|$('6' * 64)" } else { $_ }
        })
        [byte[]]$BadAccessCanaryBytes = ConvertTo-CanonicalAsciiBytes $BadAccessCanaryLines
        [IO.File]::WriteAllBytes($NativeCanaryPath, $BadAccessCanaryBytes)
        $Request.Fields['context-canary-sha256'] = Get-Sha256Bytes $BadAccessCanaryBytes
        $BadAccessCanaryRejected = $false
        try { Assert-NativeCanaryReceipt $NativeCanaryPath $Request $PointerDigest $Root -Fixture }
        catch { $BadAccessCanaryRejected = $_.Exception.Message -eq "native_canary_generation_mismatch" }
        if (-not $BadAccessCanaryRejected) { throw "native canary access contract self-test failed" }
        $BadEfsCanaryLines = @($NativeCanaryLines | ForEach-Object {
            if ($_ -ceq "profile-efs-capability|supported") { "profile-efs-capability|not-supported" } else { $_ }
        })
        [byte[]]$BadEfsCanaryBytes = ConvertTo-CanonicalAsciiBytes $BadEfsCanaryLines
        [IO.File]::WriteAllBytes($NativeCanaryPath, $BadEfsCanaryBytes)
        $Request.Fields['context-canary-sha256'] = Get-Sha256Bytes $BadEfsCanaryBytes
        $BadEfsCanaryRejected = $false
        try { Assert-NativeCanaryReceipt $NativeCanaryPath $Request $PointerDigest $Root -Fixture }
        catch { $BadEfsCanaryRejected = $_.Exception.Message -eq "native_canary_incomplete" }
        if (-not $BadEfsCanaryRejected) { throw "EFS native canary self-test failed" }

        $SavedProxy = [Environment]::GetEnvironmentVariable("HTTP_PROXY", "Process")
        try {
            [Environment]::SetEnvironmentVariable("HTTP_PROXY", "http://hostile.invalid", "Process")
            $PwshPath = (Get-Process -Id $PID).Path
            $EnvironmentResult = Invoke-FixedProcess $PwshPath @(
                "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                '[Console]::Write([string]$env:HTTP_PROXY)') ([byte[]]@()) 128 10000
            if ($EnvironmentResult.Bytes.Count -ne 0) { throw "fixed environment self-test failed" }
            if ($IsWindows) {
                $TimeoutResult = Invoke-FixedProcess $PwshPath @(
                    "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 1") `
                    ([byte[]]@()) 128 100
                if (-not $TimeoutResult.RecoveryThresholdExceeded -or $TimeoutResult.ExitCode -ne 0) {
                    throw "contained recovery self-test failed"
                }
            } else {
                $TimeoutRejected = $false
                try {
                    [void](Invoke-FixedProcess $PwshPath @(
                        "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 1") `
                        ([byte[]]@()) 128 100)
                } catch { $TimeoutRejected = $_.Exception.Message -eq "native_process_timeout" }
                if (-not $TimeoutRejected) { throw "contained timeout self-test failed" }
            }
        } finally { [Environment]::SetEnvironmentVariable("HTTP_PROXY", $SavedProxy, "Process") }

        $BadCommit = @($CommitLines); $BadCommit[2] = "request-length|1"
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "commit"), (ConvertTo-CanonicalAsciiBytes $BadCommit))
        $MismatchRejected = $false
        try { $BadSlot = Open-And-ValidateSlot $SlotRoot; Close-Slot $BadSlot } catch { $MismatchRejected = $true }
        if (-not $MismatchRejected) { throw "slot mismatch self-test failed" }

        [byte[]]$SubstitutedPayload = $script:Ascii.GetBytes("x")
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "payload"), $SubstitutedPayload)
        $BoundCommit = @($CommitLines)
        $BoundCommit[6] = "payload-length|1"
        $BoundCommit[7] = "payload-sha256|$(Get-Sha256Bytes $SubstitutedPayload)"
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "commit"), (ConvertTo-CanonicalAsciiBytes $BoundCommit))
        $SignedBindingRejected = $false
        try { $BadSlot = Open-And-ValidateSlot $SlotRoot; Close-Slot $BadSlot } catch { $SignedBindingRejected = $true }
        if (-not $SignedBindingRejected) { throw "signed payload binding self-test failed" }
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "payload"), $PayloadBytes)
        [IO.File]::WriteAllBytes((Join-Path $SlotRoot "commit"), (ConvertTo-CanonicalAsciiBytes $CommitLines))

        $BadRequest = @($RequestLines)
        $RequiredContextIndex = [Array]::IndexOf($BadRequest, "required-context|windows-system-v1")
        if ($RequiredContextIndex -lt 0) { throw "self-test fixture drift" }
        $BadRequest[$RequiredContextIndex] = "required-context|windows-user-s4u-v1"
        $ContextRejected = $false
        try { [void](Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $BadRequest)) } catch { $ContextRejected = $true }
        if (-not $ContextRejected) { throw "context fallback self-test failed" }

        $ProfileInventoryRequestLines = @($RequestLines | ForEach-Object {
            if ($_ -ceq "action-id|winget.inventory-machine.v1") { "action-id|profile.inventory-managed-state.v1" }
            elseif ($_ -ceq "policy-token|-") { "policy-token|fixture-profile-token" }
            elseif ($_ -ceq "required-context|windows-system-v1") { "required-context|windows-user-s4u-v1" }
            elseif ($_ -ceq "observed-execution-principal|LocalSystem") {
                "observed-execution-principal|enrolled-s4u-user"
            } else { $_ }
        })
        $ProfileInventoryRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $ProfileInventoryRequestLines)
        if ($ProfileInventoryRequest.Fields.'policy-token' -cne "fixture-profile-token") {
            throw "profile inventory token self-test failed"
        }
        $NewProfileRecoveryClaim = {
            param([object]$RecoveryRequest, [string]$InitialState, [string]$InitialReason)
            $RecoveryClaim = Join-Path $ReplayRoot $RecoveryRequest.Fields.'request-id'
            [void][IO.Directory]::CreateDirectory($RecoveryClaim)
            Write-AtomicBytes (Join-Path $RecoveryClaim "request") $RecoveryRequest.Bytes
            Write-AtomicAscii (Join-Path $RecoveryClaim "tombstone") @(
                "windows-tombstone|1", "request-id|$($RecoveryRequest.Fields.'request-id')",
                "retain-until|$($Now + 180)", "enrollment-epoch|$($RecoveryRequest.Epoch)",
                "state|$InitialState", "end-tombstone|")
            [void](Reserve-AuditEvidence $AuditRoot $RecoveryRequest)
            Write-Journal $RecoveryClaim $JournalRoot $RecoveryRequest $InitialState $InitialReason @{}
            return $RecoveryClaim
        }
        $ProfilePointerRoot = Join-Path $Root "profile/handoff"
        [void][IO.Directory]::CreateDirectory($ProfilePointerRoot)
        $ProfilePointerPath = Join-Path $ProfilePointerRoot "active"
        $BeforeRunLines = @($ProfileInventoryRequestLines | ForEach-Object {
            if ($_ -ceq "request-id|request-0123456789abcdef0123456789abcdef") {
                "request-id|request-5123456789abcdef0123456789abcdef"
            } else { $_ }
        })
        $BeforeRunRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $BeforeRunLines)
        $BeforeRunClaim = & $NewProfileRecoveryClaim $BeforeRunRequest "executing" "profile_launch_pending"
        $BeforeRunResultRoot = Join-Path $ProfilePointerRoot $BeforeRunRequest.Fields.'request-id'
        [void][IO.Directory]::CreateDirectory($BeforeRunResultRoot)
        $BeforeRunResultPath = Join-Path $BeforeRunResultRoot "result"
        [IO.File]::WriteAllBytes($BeforeRunResultPath, [byte[]]@())
        Write-AtomicAscii $ProfilePointerPath @(
            "windows-profile-active|1", "request-id|$($BeforeRunRequest.Fields.'request-id')",
            "handoff-sha256|$('7' * 64)", "end-active|")
        $BeforeRunInspection = [pscustomobject]@{ Count = 0 }
        $NoLiveProfileInstance = {
            param([string]$InstanceId)
            $BeforeRunInspection.Count++; return $null
        }.GetNewClosure()
        [void](Repair-ConservativeClaims $ReplayRoot $JournalRoot "" $ProfilePointerPath $NoLiveProfileInstance)
        $BeforeRunTerminal = Get-ClaimJournalState $BeforeRunClaim
        if ($BeforeRunTerminal.State -cne "stale" -or
            $BeforeRunTerminal.Reason -cne "broker_died_before_profile_run" -or
            [IO.File]::Exists($ProfilePointerPath) -or
            [IO.File]::Exists((Join-Path $BeforeRunClaim "profile-live.identity")) -or
            (Get-Item -LiteralPath $BeforeRunResultPath).Length -ne 0 -or $BeforeRunInspection.Count -ne 0) {
            throw "profile pointer pre-run crash recovery self-test failed"
        }
        $AfterRunLines = @($ProfileInventoryRequestLines | ForEach-Object {
            if ($_ -ceq "request-id|request-0123456789abcdef0123456789abcdef") {
                "request-id|request-6123456789abcdef0123456789abcdef"
            } else { $_ }
        })
        $AfterRunRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $AfterRunLines)
        $AfterRunClaim = & $NewProfileRecoveryClaim $AfterRunRequest "executing" "profile_launch_pending"
        Write-ProfileOperationIdentity (Join-Path $AfterRunClaim "profile-live.identity") `
            $AfterRunRequest.Fields.'request-id' (Join-Path $ProfilePointerRoot "result-after-run") "-" "queued"
        Write-AtomicAscii $ProfilePointerPath @(
            "windows-profile-active|1", "request-id|$($AfterRunRequest.Fields.'request-id')",
            "handoff-sha256|$('8' * 64)", "end-active|")
        $AfterRunInspection = [pscustomobject]@{ Count = 0 }
        $NoLiveAfterRun = {
            param([string]$InstanceId)
            $AfterRunInspection.Count++; return $null
        }.GetNewClosure()
        [void](Repair-ConservativeClaims $ReplayRoot $JournalRoot "" $ProfilePointerPath $NoLiveAfterRun)
        $AfterRunTerminal = Get-ClaimJournalState $AfterRunClaim
        $AfterRunIdentity = Read-ProfileOperationIdentity (Join-Path $AfterRunClaim "profile-live.identity") `
            $AfterRunRequest.Fields.'request-id'
        if ($AfterRunTerminal.State -cne "partial" -or
            $AfterRunTerminal.Reason -cne "orphaned_profile_result" -or
            $AfterRunIdentity.Fields.state -cne "queued" -or
            [IO.File]::Exists($ProfilePointerPath) -or $AfterRunInspection.Count -ne 1) {
            throw "profile explicit-run crash no-replay self-test failed"
        }
        $ReadinessCrashLines = @($RequestLines | ForEach-Object {
            if ($_ -ceq "request-id|request-0123456789abcdef0123456789abcdef") {
                "request-id|request-7123456789abcdef0123456789abcdef"
            } elseif ($_ -ceq "action-id|winget.inventory-machine.v1") { "action-id|broker.readiness.v1" }
            elseif ($_ -ceq "broker-version|1.0.0") { "broker-version|-" }
            elseif ($_ -ceq "broker-sha256|$Digest") { "broker-sha256|-" }
            elseif ($_ -ceq "policy-sha256|$Digest") { "policy-sha256|-" }
            elseif ($_ -ceq "constraints-sha256|$Digest") { "constraints-sha256|-" }
            elseif ($_ -ceq "precondition-sha256|$Digest") { "precondition-sha256|-" }
            elseif ($_ -ceq "enrollment-epoch|7") { "enrollment-epoch|-" }
            elseif ($_ -ceq "winget-context-sha256|$('3' * 64)") { "winget-context-sha256|-" }
            elseif ($_ -ceq "context-canary-sha256|$Digest") { "context-canary-sha256|-" }
            else { $_ }
        })
        $ReadinessCrashRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $ReadinessCrashLines)
        $ReadinessProbeId = Get-ReadinessProbeRequestId $ReadinessCrashRequest `
            "profile.inventory-managed-state.v1" "fixture-profile-token"
        $ReadinessCrashClaim = & $NewProfileRecoveryClaim $ReadinessCrashRequest `
            "executing" "readiness_profile_probe_pending"
        $ReadinessProbeRoot = Join-Path $ProfilePointerRoot $ReadinessProbeId
        [void][IO.Directory]::CreateDirectory($ReadinessProbeRoot)
        [IO.File]::WriteAllBytes((Join-Path $ReadinessProbeRoot "result"), [byte[]]@())
        $ReadinessProbeIdentityPath = Join-Path $ReadinessCrashClaim ("profile-probe-" + $ReadinessProbeId + ".identity")
        Write-ProfileOperationIdentity $ReadinessProbeIdentityPath $ReadinessProbeId `
            (Join-Path $ReadinessProbeRoot "result") "-" "queued"
        Write-AtomicAscii $ProfilePointerPath @(
            "windows-profile-active|1", "request-id|$ReadinessProbeId",
            "handoff-sha256|$('a' * 64)", "end-active|")
        $ReadinessProbeInspection = [pscustomobject]@{ Count = 0 }
        $NoReadinessProbeInstance = {
            param([string]$InstanceId)
            $ReadinessProbeInspection.Count++; return $null
        }.GetNewClosure()
        [void](Repair-ConservativeClaims $ReplayRoot $JournalRoot $PublicRoot $ProfilePointerPath `
            $NoReadinessProbeInstance)
        $ReadinessCrashTerminal = Get-ClaimJournalState $ReadinessCrashClaim
        $RecoveredProbeIdentity = Read-ProfileOperationIdentity $ReadinessProbeIdentityPath $ReadinessProbeId
        $ReadinessNormalResultPath = Join-Path $TransportPaths.Results `
            ($ReadinessCrashRequest.Fields.'request-id' + ".result")
        if ($ReadinessCrashTerminal.State -cne "partial" -or
            $ReadinessCrashTerminal.Reason -cne "orphaned_profile_result" -or
            $RecoveredProbeIdentity.Fields.'request-id' -cne $ReadinessProbeId -or
            [IO.File]::Exists($ProfilePointerPath) -or [IO.File]::Exists($ReadinessNormalResultPath) -or
            $ReadinessProbeInspection.Count -ne 1) {
            throw "profile readiness probe crash recovery self-test failed"
        }
        $SuccessfulProbeId = "request-e123456789abcdef0123456789abcdef"
        $SuccessfulProbeIdentityPath = Join-Path $Root ("profile-probe-" + $SuccessfulProbeId + ".identity")
        Write-ProfileOperationIdentity $SuccessfulProbeIdentityPath $SuccessfulProbeId `
            (Join-Path $Root "successful-probe-result") "-" "queued"
        Write-AtomicAscii $ProfilePointerPath @(
            "windows-profile-active|1", "request-id|$SuccessfulProbeId",
            "handoff-sha256|$('b' * 64)", "end-active|")
        Remove-ReadinessProbeArtifacts $ProfilePointerPath $SuccessfulProbeId $SuccessfulProbeIdentityPath
        if ([IO.File]::Exists($ProfilePointerPath) -or [IO.File]::Exists($SuccessfulProbeIdentityPath)) {
            throw "profile readiness probe success cleanup self-test failed"
        }
        $UnknownPointerRequestId = "request-f123456789abcdef0123456789abcdef"
        Write-AtomicAscii $ProfilePointerPath @(
            "windows-profile-active|1", "request-id|$UnknownPointerRequestId",
            "handoff-sha256|$('9' * 64)", "end-active|")
        if (Remove-MatchingProfileActivePointer $ProfilePointerPath $AfterRunRequest.Fields.'request-id') {
            throw "mismatched profile pointer deletion self-test failed"
        }
        $StalePointerBlocked = $false
        try { Assert-ProfileActivePointerAvailable $ProfilePointerPath }
        catch { $StalePointerBlocked = $_.Exception.Message -eq "profile_handoff_active" }
        if (-not $StalePointerBlocked -or -not [IO.File]::Exists($ProfilePointerPath) -or
            (Read-ProfileActivePointer $ProfilePointerPath).RequestId -cne $UnknownPointerRequestId) {
            throw "stale profile pointer reuse self-test failed"
        }
        [IO.File]::Delete($ProfilePointerPath)
        $TokenlessProfileRequestLines = @($ProfileInventoryRequestLines | ForEach-Object {
            if ($_ -ceq "policy-token|fixture-profile-token") { "policy-token|-" } else { $_ }
        })
        $TokenlessProfileRejected = $false
        try { [void](Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $TokenlessProfileRequestLines)) }
        catch { $TokenlessProfileRejected = $_.Exception.Message -eq "invalid_policy_token" }
        if (-not $TokenlessProfileRejected) { throw "tokenless profile inventory self-test failed" }

        $ProfileMapBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-entry-map|1",
            "entry|.codex/settings.json|json-scalar|codex-settings|codex|codex-settings",
            "end-entry-map|")
        $ProfileMap = Read-BrokerProfileEntryMap $ProfileMapBytes
        $SkillMapLines = @(
            ".codex/skills/demo/SKILL.md", ".codex/skills/demo/assets/icon.bin",
            ".codex/skills/demo/scripts/check.ps1") | ForEach-Object {
                $Contract = Get-BrokerCompiledProfileContract $_ "standalone-skill-file"
                "entry|$_|standalone-skill-file|$($Contract.Artifact)|$($Contract.Manager)|$($Contract.LogicalIdentity)"
            }
        $SkillMap = Read-BrokerProfileEntryMap (ConvertTo-CanonicalAsciiBytes (@(
            "profile-entry-map|1") + $SkillMapLines + @("end-entry-map|")))
        if ($SkillMap.Entries.Count -ne 3 -or @($SkillMap.Entries.LogicalIdentity | Sort-Object -Unique).Count -ne 3 -or
            @($SkillMap.Entries | Where-Object { $_.Artifact -cne "demo" -or $_.Manager -cne "standalone" }).Count -ne 0) {
            throw "multi-file standalone skill self-test failed"
        }
        $EmptyMarketplaceSet = Read-BrokerMarketplaceSet (ConvertTo-CanonicalAsciiBytes @(
            "profile-marketplace-set|1", "end-marketplace-set|"))
        Assert-BrokerMarketplaceAuthorization $ProfileMap $EmptyMarketplaceSet
        $MarketplacePath = ".codex/machine-utilities/marketplace-stage/acme/plugin/SKILL.md"
        $MarketplaceDigest = "6" * 64
        $MarketplaceLogical = "marketplace-file:$(Get-Sha256Text $MarketplacePath.ToLowerInvariant())"
        $MarketplaceMap = Read-BrokerProfileEntryMap (ConvertTo-CanonicalAsciiBytes @(
            "profile-entry-map|1",
            "entry|.codex/machine-utilities/managed/marketplace.desired|marketplace-desired-record|marketplace-desired|fleet-agents|marketplace-desired",
            "entry|$MarketplacePath|marketplace-file|acme|fleet-agents|$MarketplaceLogical",
            "end-entry-map|"))
        $MarketplaceSet = Read-BrokerMarketplaceSet (ConvertTo-CanonicalAsciiBytes @(
            "profile-marketplace-set|1", "file|$MarketplacePath|$MarketplaceDigest",
            "plugin|fixture-plugin|acme|$MarketplaceDigest", "end-marketplace-set|"))
        Assert-BrokerMarketplaceAuthorization $MarketplaceMap $MarketplaceSet
        $MarketplaceSubstitutionRejected = $false
        try { Assert-BrokerMarketplaceAuthorization $ProfileMap $MarketplaceSet }
        catch { $MarketplaceSubstitutionRejected = $true }
        if (-not $MarketplaceSubstitutionRejected) { throw "marketplace set binding self-test failed" }
        $ProfileRequest = [pscustomobject]@{ Fields = [ordered]@{
            'request-id' = 'request-3123456789abcdef0123456789abcdef'
            'action-id' = 'profile.apply-managed-bundle.v1'
            'precondition-sha256' = ('8' * 64)
        } }
        $ProfileAuthorization = [pscustomobject]@{ TargetSid = 'S-1-5-21-1-2-3-1001';
            ProfileRootId = ('9' * 64); EntryMap = $ProfileMap }
        $ProfileStates = @([pscustomobject]@{ Path = '.codex/settings.json'; Presence = 'absent';
            Digest = '-'; Manager = '-' })
        $ProfilePostState = Get-BrokerProfileStateDigest $ProfileAuthorization.ProfileRootId $ProfileStates
        $ProfileResultLines = @(
            "windows-profile-result|2", "request-id|$($ProfileRequest.Fields.'request-id')",
            "action-id|$($ProfileRequest.Fields.'action-id')", "target-sid|$($ProfileAuthorization.TargetSid)",
            "profile-root-id|$($ProfileAuthorization.ProfileRootId)", "context-integrity|medium_or_lower",
            "context-elevated|false", "context-administrators|disabled", "context-dangerous-privileges|none",
            "context-authenticated-smb|unavailable", "context-programdata-write|denied", "context-task-write|denied",
            "context-service-control|denied", "context-hklm-write|denied", "context-other-profile-write|denied",
            "pre-state-sha256|$($ProfileRequest.Fields.'precondition-sha256')", "post-state-sha256|$ProfilePostState",
            "state|completed", "reason|post_state_verified", "entry-count|1",
            "entry|0|.codex/settings.json|absent|-|-", "end-result|")
        $ProfileResultBytes = ConvertTo-CanonicalAsciiBytes $ProfileResultLines
        $ParsedProfile = Read-ProfileTaskResult $ProfileResultBytes $ProfileRequest $ProfileAuthorization $ProfileStates
        if ($ParsedProfile.PostStateSha256 -cne $ProfilePostState) { throw "profile result self-test failed" }
        $UnsupportedProfileBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-context-result|1", "request-id|$($ProfileRequest.Fields.'request-id')",
            "action-id|$($ProfileRequest.Fields.'action-id')", "target-sid|$($ProfileAuthorization.TargetSid)",
            "profile-root-id|$($ProfileAuthorization.ProfileRootId)", "state|rejected", "reason|unsupported_context",
            "end-result|")
        if ((Read-ProfileUnsupportedContextResult $UnsupportedProfileBytes $ProfileRequest `
                $ProfileAuthorization).State -cne "rejected") { throw "profile context result self-test failed" }
        foreach ($Mutation in @(
            @($ProfileResultLines | ForEach-Object { if ($_ -ceq "context-elevated|false") { "context-elevated|true" } else { $_ } }),
            @($ProfileResultLines | ForEach-Object { if ($_ -like "post-state-sha256|*") { "post-state-sha256|$('7' * 64)" } else { $_ } }),
            @($ProfileResultLines[0..($ProfileResultLines.Count - 2)] + "extra|field" + "end-result|"))) {
            $Rejected = $false
            try { [void](Read-ProfileTaskResult (ConvertTo-CanonicalAsciiBytes $Mutation) $ProfileRequest `
                    $ProfileAuthorization $ProfileStates) } catch { $Rejected = $true }
            if (-not $Rejected) { throw "forged profile result self-test failed" }
        }

        $ReadinessFixtureRequest = [pscustomobject]@{
            IsReadiness = $true
            Fields = [ordered]@{
                "request-id" = "request-8123456789abcdef0123456789abcdef"
                "request-sid" = $script:RequestSid
                "request-principal" = "mu-request"
            }
        }
        $ReadinessFixtureGeneration = [pscustomobject]@{
            Epoch = 7; GenerationDigest = ("2" * 64)
            Digests = [pscustomobject]@{
                Policy = ("3" * 64); Constraints = ("4" * 64); Context = ("5" * 64)
                ProviderLock = ("6" * 64)
            }
        }
        $MachineActionRows = [string[]]@(
            "action|winget.inventory-machine.v1|windows-system-v1|-|$('7' * 64)")
        $ProfileOverclaimRejected = $false
        try {
            Write-BrokerReadinessResult -Request $ReadinessFixtureRequest `
                -Generation $ReadinessFixtureGeneration -BrokerSha256 $Digest `
                -ActionRows $MachineActionRows -ProfileRows ([string[]]@()) -ProfileTaskReady $true
        } catch { $ProfileOverclaimRejected = $_.Exception.Message -eq "invalid_readiness_result" }
        if (-not $ProfileOverclaimRejected) { throw "profile readiness overclaim writer self-test failed" }
        Write-BrokerReadinessResult -Request $ReadinessFixtureRequest `
            -Generation $ReadinessFixtureGeneration -BrokerSha256 $Digest `
            -ActionRows $MachineActionRows -ProfileRows ([string[]]@()) -ProfileTaskReady $false
        $MachineReadinessPath = Join-Path $TransportPaths.Results `
            ($ReadinessFixtureRequest.Fields.'request-id' + ".readiness")
        Assert-SanitizedReadinessResult $MachineReadinessPath $ReadinessFixtureRequest.Fields.'request-id'
        $MachineReadinessText = [IO.File]::ReadAllText($MachineReadinessPath, $script:Ascii)
        if ($MachineReadinessText -notmatch '(?m)^profile-task-ready\|false$') {
            throw "machine-only profile readiness self-test failed"
        }
        $OverclaimedReadinessPath = Join-Path $Root "overclaimed-readiness"
        [IO.File]::WriteAllBytes($OverclaimedReadinessPath, $script:Ascii.GetBytes(
            $MachineReadinessText.Replace("profile-task-ready|false", "profile-task-ready|true")))
        $ProfileOverclaimParseRejected = $false
        try {
            Assert-SanitizedReadinessResult $OverclaimedReadinessPath `
                $ReadinessFixtureRequest.Fields.'request-id'
        } catch { $ProfileOverclaimParseRejected = $_.Exception.Message -eq "readiness_result_drift" }
        if (-not $ProfileOverclaimParseRejected) { throw "profile readiness overclaim parser self-test failed" }
        [IO.File]::Delete($OverclaimedReadinessPath)

        $TerminalAdmissionNow = $Now - $script:MinimumRequestTtlSeconds - $script:MaximumClockSkewSeconds - 1
        $TerminalRetentionRequestLines = @($RequestLines | ForEach-Object {
            if ($_ -like "request-id|*") { "request-id|request-9123456789abcdef0123456789abcdef" }
            elseif ($_ -like "created-at|*") { "created-at|$TerminalAdmissionNow" }
            elseif ($_ -like "expires-at|*") {
                "expires-at|$($TerminalAdmissionNow + $script:MinimumRequestTtlSeconds)"
            } else { $_ }
        })
        $TerminalRetentionRequest = Read-BrokerRequest (ConvertTo-CanonicalAsciiBytes $TerminalRetentionRequestLines)
        [long]$OriginalAdmissionRetainUntil = $TerminalRetentionRequest.ExpiresAt + $script:MaximumClockSkewSeconds
        if ($OriginalAdmissionRetainUntil -ge $Now) { throw "terminal retention admission self-test failed" }
        $TerminalRetentionSlot = [pscustomobject]@{
            Request = $TerminalRetentionRequest; SignatureBytes = $SignatureBytes; PayloadBytes = $PayloadBytes
            Commit = [pscustomobject]@{
                RequestSha256 = (Get-Sha256Bytes $TerminalRetentionRequest.Bytes)
                SignatureSha256 = (Get-Sha256Bytes $SignatureBytes)
                PayloadSha256 = (Get-Sha256Bytes $PayloadBytes)
            }
        }
        $TerminalRetentionClaim = New-Claim $ReplayRoot $JournalRoot $TerminalRetentionSlot $TerminalAdmissionNow
        $AdmissionTombstone = ConvertFrom-CanonicalAsciiBytes (
            [IO.File]::ReadAllBytes((Join-Path $TerminalRetentionClaim "tombstone"))) 2048 "tombstone"
        if ($AdmissionTombstone[2] -cne "retain-until|$OriginalAdmissionRetainUntil") {
            throw "terminal retention admission tombstone self-test failed"
        }
        Write-Journal $TerminalRetentionClaim $JournalRoot $TerminalRetentionRequest "completed" "post_state_verified" @{}
        $TerminalTombstone = ConvertFrom-CanonicalAsciiBytes (
            [IO.File]::ReadAllBytes((Join-Path $TerminalRetentionClaim "tombstone"))) 2048 "tombstone"
        [long]$TerminalResultRetainUntil = [long]$TerminalTombstone[2].Split('|')[1]
        $TerminalJournal = Get-ClaimJournalState $TerminalRetentionClaim
        if ($TerminalTombstone[4] -cne "state|completed" -or
            $TerminalResultRetainUntil -lt ($Now + $script:TerminalResultRetentionSeconds)) {
            throw "terminal result retention self-test failed"
        }
        Write-PublicResult $PublicRoot "last" $TerminalRetentionRequest $TerminalJournal.State $TerminalJournal.Reason `
            (Get-Sha256Bytes $TerminalJournal.Bytes)
        $TerminalPublicResultPath = Join-Path $TransportPaths.Results ($TerminalRetentionRequest.Fields.'request-id' + ".result")
        $TerminalReadinessPath = Join-Path $TransportPaths.Results `
            ($TerminalRetentionRequest.Fields.'request-id' + ".readiness")
        Write-AtomicBytes $TerminalReadinessPath $script:Ascii.GetBytes($MachineReadinessText.Replace(
                $ReadinessFixtureRequest.Fields.'request-id', $TerminalRetentionRequest.Fields.'request-id'))
        if ($IsWindows) {
            Set-ExactSddl $TerminalReadinessPath (Get-TransportAclContract $script:RequestSid).ResultFile
        }
        $TerminalProtectedJournalPath = Join-Path $JournalRoot `
            ($TerminalRetentionRequest.Fields.'request-id' + ".result")
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot $Now
        if (-not [IO.Directory]::Exists($TerminalRetentionClaim) -or
            -not [IO.File]::Exists($TerminalPublicResultPath) -or
            -not [IO.File]::Exists($TerminalReadinessPath) -or
            -not [IO.File]::Exists($TerminalProtectedJournalPath) -or
            (Get-ClaimJournalState $TerminalRetentionClaim).State -cne "completed") {
            throw "terminal result retention query window self-test failed"
        }
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot ($TerminalResultRetainUntil - 1)
        if (-not [IO.Directory]::Exists($TerminalRetentionClaim) -or
            -not [IO.File]::Exists($TerminalPublicResultPath) -or
            -not [IO.File]::Exists($TerminalReadinessPath) -or
            -not [IO.File]::Exists($TerminalProtectedJournalPath)) {
            throw "terminal result retention deadline window self-test failed"
        }
        Compact-ReplayAndAudit $ReplayRoot $JournalRoot $AuditRoot $TerminalResultRetainUntil
        if ([IO.Directory]::Exists($TerminalRetentionClaim) -or
            [IO.File]::Exists($TerminalPublicResultPath) -or
            [IO.File]::Exists($TerminalReadinessPath) -or
            [IO.File]::Exists($TerminalProtectedJournalPath) -or
            [IO.File]::Exists((Join-Path $AuditRoot ($TerminalRetentionRequest.Fields.'request-id' + ".audit")))) {
            throw "terminal result retention compaction self-test failed"
        }

        Write-PublicResult $PublicRoot "last" $Request "completed" "post_state_verified" $Digest
        $PublicText = [IO.File]::ReadAllText((Join-Path $PublicRoot "last"), $script:Ascii)
        $PublicResultPath = Join-Path $TransportPaths.Results ($Request.Fields.'request-id' + ".result")
        $PublicLastDigest = Get-Sha256Bytes ([IO.File]::ReadAllBytes((Join-Path $PublicRoot "last")))
        if ($PublicText -notmatch "(?m)^protected-result-sha256\|$Digest$" -or
            -not [IO.File]::Exists($PublicResultPath) -or
            (Get-Sha256Bytes ([IO.File]::ReadAllBytes($PublicResultPath))) -cne $PublicLastDigest -or
            $PublicText -match 'policy-sha256|signature|payload|certificate-valid') {
            throw "public projection self-test failed"
        }
        Write-Output "PASS: privilege-broker-windows fixture-safe self-check"
    } finally {
        $script:SelfTestFixture = $false
        $script:AuditRoot = $null
        $script:ProcessTempRoot = $null
        if ([IO.Directory]::Exists($Root)) { [IO.Directory]::Delete($Root, $true) }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

Assert-SystemContext
$ProgramData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($ProgramData) -or -not [IO.Path]::IsPathFullyQualified($ProgramData)) {
    throw "unsupported_context"
}
$Root = Join-Path $ProgramData "MachineUtilities"
$StateRoot = Join-Path $Root "state"
$ReplayRoot = Join-Path $StateRoot "replay"
$JournalRoot = Join-Path $StateRoot "journal"
$script:AuditRoot = Join-Path $StateRoot "audit"
$ProcessingRoot = Join-Path $StateRoot "processing"
$script:ProcessTempRoot = Join-Path $ProcessingRoot "temp"
$PublicRoot = Join-Path $ProgramData "MachineUtilities-Public"
$script:PublicRoot = $PublicRoot
$script:BrokerRoot = $Root
$LockPath = Join-Path $StateRoot "broker.lock"
$ProvisionMarkerPath = Join-Path $StateRoot "winget-provider.provision"
foreach ($Path in @($Root, $StateRoot, $ReplayRoot, $JournalRoot, $script:AuditRoot, $ProcessingRoot)) {
    Assert-NonReparsePath $Path $Root
}
$HostIdentityPath = Join-Path $Root "host.identity"
if ((Get-BrokerStartupDisposition ([IO.File]::Exists($ProvisionMarkerPath)) ([IO.File]::Exists($HostIdentityPath))) -ceq
        "provision-only") {
    Assert-NonReparsePath $LockPath $Root
    $ProvisionLock = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        [void](Invoke-WinGetProvisionMarker $Root $StateRoot $ProvisionMarkerPath)
        return
    } finally { $ProvisionLock.Dispose() }
}
$TransportPaths = Get-FixedTransportPaths $Root $PublicRoot
if (-not [IO.Path]::GetFullPath($TransportPaths.Chroot).Equals(
        "C:\ProgramData\MachineUtilities\chroot", [StringComparison]::OrdinalIgnoreCase)) {
    throw "unsupported_chroot_path"
}
$SlotRoot = $TransportPaths.Slot
$script:SlotRoot = $SlotRoot
$script:ResultRoot = $TransportPaths.Results
foreach ($Path in @($TransportPaths.Chroot, $TransportPaths.Ingress, $SlotRoot, $script:ResultRoot)) {
    Assert-NonReparsePath $Path $Root
}
Assert-NonReparsePath $HostIdentityPath $Root
$StartupHostIdentity = Read-ProtectedHostIdentity $HostIdentityPath
$script:RequestSid = [string]$StartupHostIdentity.'request-sid'
Assert-FixedTransportLayout $Root $PublicRoot $script:RequestSid

$Lock = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$Slot = $null
$ClaimRoot = $null
$Request = $null
$Generation = $null
$CurrentBrokerDigest = $null
$ProfileSession = $null
$NativeCommitted = $false
$Terminalized = $false
try {
    $DrainPath = Join-Path $StateRoot "drain"
    $ProfilePointerPath = Join-Path $Root "profile/handoff/active"
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Compact-ReplayAndAudit $ReplayRoot $JournalRoot $script:AuditRoot $Now
    if (Repair-ConservativeClaims $ReplayRoot $JournalRoot $PublicRoot $ProfilePointerPath) { return }
    Assert-ProfileActivePointerAvailable $ProfilePointerPath
    if ([IO.File]::Exists($ProvisionMarkerPath)) {
        [void](Invoke-WinGetProvisionMarker $Root $StateRoot $ProvisionMarkerPath)
        return
    }
    if ([IO.File]::Exists($DrainPath)) {
        Write-PublicDrainStatus $PublicRoot "no_claimable_submission"
        try { $Slot = Open-And-ValidateSlot $SlotRoot } catch {
            # An empty or incomplete fixed slot is not a submission and needs no result.
            return
        }
        $ExpectedBrokerPath = Join-Path $Root "entry/privilege-broker-windows.ps1"
        if (-not [IO.Path]::GetFullPath($PSCommandPath).Equals([IO.Path]::GetFullPath($ExpectedBrokerPath),
                [StringComparison]::OrdinalIgnoreCase)) { throw "broker_identity_drift" }
        $CurrentBrokerDigest = Get-HeldFileSha256 $ExpectedBrokerPath
        $Generation = Get-ProtectedGeneration $Root $Slot.Request
        $CanaryPath = Join-Path $Root "native-canary.receipt"
        if (-not [IO.File]::Exists($CanaryPath)) { throw "native_canary_required" }
        Assert-NativeCanaryReceipt $CanaryPath $Slot.Request $Generation.GenerationDigest $Root $Generation.Epoch
        Assert-SignedRequest $Root $Slot (Join-Path $StateRoot "processing") $Generation
        Assert-FixedTransportLayout $Root $PublicRoot $script:RequestSid $Slot
        if (Consume-ExistingClaimedSlotCommit $ReplayRoot $Slot) {
            Close-Slot $Slot; $Slot = $null
            Write-PublicDrainStatus $PublicRoot "no_claimable_submission"
            return
        }
        $ClaimRoot = New-Claim $ReplayRoot $JournalRoot $Slot $Now
        $Request = $Slot.Request
        Consume-ClaimedSlotCommit $Slot $ClaimRoot
        Close-Slot $Slot; $Slot = $null
        if ($Request.IsReadiness) {
            Write-Journal $ClaimRoot $JournalRoot $Request "rejected" "fresh_probe_failed" @{}
            $Terminalized = $true
            Write-BrokerReadinessResult -Request $Request -Generation $Generation -BrokerSha256 $CurrentBrokerDigest `
                -ActionRows ([string[]]@()) -ProfileRows ([string[]]@()) -State "unavailable" -Reason "fresh_probe_failed"
            Write-PublicDrainStatus $PublicRoot "request_rejected"
            return
        }
        Write-Journal $ClaimRoot $JournalRoot $Request "rejected" "broker_draining" @{}
        $Terminalized = $true
        Write-PublicResult $PublicRoot "last" $Request "rejected" "broker_draining" `
            (Get-HeldFileSha256 (Join-Path $ClaimRoot "journal") 65536)
        Write-PublicDrainStatus $PublicRoot "request_rejected"
        return
    }
    $Slot = Open-And-ValidateSlot $SlotRoot
    if ($Slot.Request.CreatedAt -gt ($Now + $script:MaximumClockSkewSeconds) -or
        $Slot.Request.ExpiresAt -le $Now -or ($Now - $Slot.Request.CreatedAt) -gt $script:MaximumClockSkewSeconds) {
        throw "expired_request"
    }
    $ExpectedBrokerPath = Join-Path $Root "entry/privilege-broker-windows.ps1"
    $CurrentBrokerDigest = Get-HeldFileSha256 $ExpectedBrokerPath
    if (-not [IO.Path]::GetFullPath($PSCommandPath).Equals([IO.Path]::GetFullPath($ExpectedBrokerPath),
            [StringComparison]::OrdinalIgnoreCase) -or
        (-not $Slot.Request.IsReadiness -and $CurrentBrokerDigest -cne $Slot.Request.Fields.'broker-sha256')) {
        throw "broker_identity_drift"
    }
    $Generation = Get-ProtectedGeneration $Root $Slot.Request
    # The capability receipt is checked before the attested OpenSSH verifier is ever invoked.
    $CanaryPath = Join-Path $Root "native-canary.receipt"
    if (-not [IO.File]::Exists($CanaryPath)) { throw "native_canary_required" }
    Assert-NativeCanaryReceipt $CanaryPath $Slot.Request $Generation.GenerationDigest $Root $Generation.Epoch
    Assert-SignedRequest $Root $Slot (Join-Path $StateRoot "processing") $Generation
    Assert-FixedTransportLayout $Root $PublicRoot $script:RequestSid $Slot
    if (Consume-ExistingClaimedSlotCommit $ReplayRoot $Slot) {
        Close-Slot $Slot; $Slot = $null
        return
    }
    $ClaimRoot = New-Claim $ReplayRoot $JournalRoot $Slot $Now
    $Request = $Slot.Request
    Consume-ClaimedSlotCommit $Slot $ClaimRoot
    Close-Slot $Slot; $Slot = $null
    if ($Request.IsReadiness) {
        Write-Journal $ClaimRoot $JournalRoot $Request "executing" "fresh_probe_pending" @{}
        $Readiness = Invoke-BrokerReadinessProbes $Root $StateRoot $ProgramData $Request $Generation `
            $ClaimRoot $JournalRoot $PublicRoot
        Write-Journal $ClaimRoot $JournalRoot $Request "verifying" "fresh_probe_results_received" @{}
        $ReadinessDigest = Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes (@(
            "windows-broker-readiness-evidence|1") + @($Readiness.ActionRows) + @($Readiness.ProfileRows) +
            @("end-evidence|")))
        Write-Journal $ClaimRoot $JournalRoot $Request "completed" "fresh_probes_verified" @{ state = $ReadinessDigest }
        $Terminalized = $true
        Write-BrokerReadinessResult -Request $Request -Generation $Generation -BrokerSha256 $CurrentBrokerDigest `
            -ActionRows $Readiness.ActionRows -ProfileRows $Readiness.ProfileRows `
            -ProfileTaskReady $Readiness.ProfileTaskReady
        return
    }
    $Action = $Request.Fields.'action-id'
    if ($Action.StartsWith("winget.", [StringComparison]::Ordinal)) {
        Write-Journal $ClaimRoot $JournalRoot $Request "executing" "module_operation_pending" @{}
        Write-PublicResult $PublicRoot "active" $Request "executing" "module_operation_pending"
        $Result = Invoke-WinGetModuleOperation $Root $Request $Generation ([ref]$NativeCommitted)
        Write-Journal $ClaimRoot $JournalRoot $Request "verifying" "module_result_received" @{}
        $StateDigest = Get-Sha256Text ("state|$($Result.State)`n")
        Write-Journal $ClaimRoot $JournalRoot $Request $Result.State $Result.Reason @{
            state = $StateDigest; result = $Result.Sha256 }
        $Terminalized = $true
        Write-PublicResult $PublicRoot "last" $Request $Result.State $Result.Reason `
            (Get-HeldFileSha256 (Join-Path $ClaimRoot "journal") 65536)
        if ([IO.File]::Exists((Join-Path $PublicRoot "active"))) { [IO.File]::Delete((Join-Path $PublicRoot "active")) }
        [Console]::OpenStandardOutput().Write($Result.Bytes, 0, $Result.Bytes.Count)
        if ($Result.State -cne "completed") { exit 70 }
    } else {
        $Authorization = Get-ProfileAuthorization $Generation $Request ([IO.File]::ReadAllBytes((Join-Path $ClaimRoot "payload")) )
        Assert-ProfileTask $Authorization.TargetSid $ProgramData
        $ProfileSession = New-BrokerProfileSession $Authorization
        $HandoffRoot = Publish-ProfileHandoff $Root $Request $Authorization `
            ([IO.File]::ReadAllBytes((Join-Path $ClaimRoot "payload")))
        Write-Journal $ClaimRoot $JournalRoot $Request "executing" "profile_launch_pending" @{}
        Write-PublicResult $PublicRoot "active" $Request "executing" "profile_launch_pending"
        $TaskEvidence = Invoke-ProfileTaskInstance (Join-Path $HandoffRoot "result") `
            (Join-Path $ClaimRoot "profile-live.identity") $Request $ClaimRoot $JournalRoot $PublicRoot `
            ([ref]$NativeCommitted)
        Write-Journal $ClaimRoot $JournalRoot $Request "verifying" "profile_result_received" @{}
        $ResultHandle = Open-ExclusiveBoundedFile (Join-Path $HandoffRoot "result") 1048576
        try {
            if ($TaskEvidence.ExitCode -eq 3) {
                $ProfileResult = Read-ProfileUnsupportedContextResult $ResultHandle.Bytes $Request $Authorization
            } else {
                $ObservedStates = Get-BrokerProfileStates $ProfileSession $Authorization.EntryMap
                $ProfileResult = Read-ProfileTaskResult $ResultHandle.Bytes $Request $Authorization $ObservedStates
            }
        }
        finally { $ResultHandle.Stream.Dispose() }
        $TaskStateDigest = Get-Sha256Text ("instance-id|$($TaskEvidence.InstanceId)`nlast-run|" +
            "$($TaskEvidence.LastRunTime.ToUniversalTime().ToString('O'))`nexit-code|$($TaskEvidence.ExitCode)" +
            "`npost-state-sha256|$($ProfileResult.PostStateSha256)`n")
        Write-Journal $ClaimRoot $JournalRoot $Request $ProfileResult.State $ProfileResult.Reason @{
            state = $TaskStateDigest; result = $ProfileResult.Sha256 }
        $Terminalized = $true
        Write-PublicResult $PublicRoot "last" $Request $ProfileResult.State $ProfileResult.Reason `
            (Get-HeldFileSha256 (Join-Path $ClaimRoot "journal") 65536)
        $ActiveProfilePointer = Join-Path $Root "profile/handoff/active"
        [void](Remove-MatchingProfileActivePointer $ActiveProfilePointer $Request.Fields.'request-id')
        if ([IO.File]::Exists((Join-Path $PublicRoot "active"))) { [IO.File]::Delete((Join-Path $PublicRoot "active")) }
        [Console]::OpenStandardOutput().Write($ResultHandle.Bytes, 0, $ResultHandle.Bytes.Count)
        if ($ProfileResult.State -cne "completed") { exit 70 }
    }
} catch {
    $Failure = $_
    if ($null -ne $ClaimRoot -and $null -ne $Request) {
        try {
            $CanonicalTerminal = Get-ClaimJournalState $ClaimRoot
            if ($null -ne $CanonicalTerminal -and
                $CanonicalTerminal.State -cin @("completed", "partial", "rejected", "stale")) {
                $Terminalized = $true
                try {
                    if ($Request.IsReadiness) {
                        $ReadinessPath = Join-Path $script:ResultRoot ($Request.Fields.'request-id' + ".readiness")
                        if (-not [IO.File]::Exists($ReadinessPath) -and $null -ne $Generation -and
                            -not [string]::IsNullOrWhiteSpace($CurrentBrokerDigest)) {
                            Write-BrokerReadinessResult -Request $Request -Generation $Generation `
                                -BrokerSha256 $CurrentBrokerDigest -ActionRows ([string[]]@()) `
                                -ProfileRows ([string[]]@()) -State "unavailable" -Reason "fresh_probe_failed"
                        }
                    } else {
                        Write-PublicResult $PublicRoot "last" $Request $CanonicalTerminal.State $CanonicalTerminal.Reason `
                            (Get-Sha256Bytes $CanonicalTerminal.Bytes)
                    }
                } catch { }
            }
        } catch { }
    }
    if ($null -ne $ClaimRoot -and $null -ne $Request -and -not $Terminalized) {
        $FailureState = if ($Request.IsReadiness) { "rejected" } elseif ($NativeCommitted) { "partial" } else { "rejected" }
        $FailureReason = if ($Request.IsReadiness) { "fresh_probe_failed" } elseif ($NativeCommitted) {
            "broker_exception_after_native"
        } else { "broker_exception_before_native" }
        try {
            Write-Journal $ClaimRoot $JournalRoot $Request $FailureState $FailureReason @{}
            $Terminalized = $true
            if ($Request.IsReadiness) {
                if ($null -eq $Generation -or [string]::IsNullOrWhiteSpace($CurrentBrokerDigest)) {
                    throw "readiness_failure_unreportable"
                }
                Write-BrokerReadinessResult -Request $Request -Generation $Generation -BrokerSha256 $CurrentBrokerDigest `
                    -ActionRows ([string[]]@()) -ProfileRows ([string[]]@()) -State "unavailable" -Reason "fresh_probe_failed"
            } else {
                Write-PublicResult $PublicRoot "last" $Request $FailureState $FailureReason `
                    (Get-HeldFileSha256 (Join-Path $ClaimRoot "journal") 65536)
            }
        } catch {
            throw "terminal_audit_failed: $($Failure.Exception.Message); $($_.Exception.Message)"
        } finally {
            $PublicActivePath = Join-Path $PublicRoot "active"
            if ([IO.File]::Exists($PublicActivePath)) { [IO.File]::Delete($PublicActivePath) }
            [void](Remove-MatchingProfileActivePointer (Join-Path $Root "profile/handoff/active") `
                $Request.Fields.'request-id')
        }
    }
    throw $Failure
} finally {
    Close-Slot $Slot
    Close-BrokerProfileSession $ProfileSession
    $Lock.Dispose()
}
