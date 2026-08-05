[CmdletBinding(DefaultParameterSetName = "Preview")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Preview")]
    [Parameter(Mandatory = $true, ParameterSetName = "Run")][string]$ChallengePath,
    [Parameter(Mandatory = $true, ParameterSetName = "Preview")]
    [Parameter(Mandatory = $true, ParameterSetName = "Run")][string]$TrustRecordPath,
    [Parameter(Mandatory = $true, ParameterSetName = "Preview")][switch]$Preview,
    [Parameter(Mandatory = $true, ParameterSetName = "Run")][switch]$Run,
    [Parameter(Mandatory = $true, ParameterSetName = "Run")][string]$Confirmation,
    [Parameter(Mandatory = $true, ParameterSetName = "Run")][string]$RawEvidencePath,
    [Parameter(Mandatory = $true, ParameterSetName = "Run")][string]$ControlledSmbProbePath,
    [Parameter(Mandatory = $true, ParameterSetName = "Run")][string]$ControlledEfsProbePath,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Ascii = [Text.Encoding]::ASCII
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:ProtectedDirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
$script:ProtectedFileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"

function Get-Sha256Bytes([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $Hasher.Dispose() }
}

function Get-Sha256Utf8Text([string]$Text) { return Get-Sha256Bytes $script:Utf8.GetBytes($Text) }
function Test-Digest([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }
function Test-Thumbprint([string]$Value) { return $Value -cmatch '^[0-9A-F]{40}$' }
function Test-UInt([string]$Value) { return $Value -cmatch '^(0|[1-9][0-9]{0,18})$' }
function Test-WindowsAbsolutePath([string]$Value) {
    return $Value -cmatch '^[A-Za-z]:\\[^|\r\n]{1,2048}$' -and $Value -notmatch '(?:^|\\)\.\.(?:\\|$)'
}

function Get-ChrootAccessEvidenceContract([string]$RequestSid) {
    if ($RequestSid -cnotmatch '^S-[0-9]+(?:-[0-9]+){1,14}$') { throw "invalid_request_sid" }
    $DirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x001200a0;;;$RequestSid)"
    return [pscustomobject]@{
        RequestSid = $RequestSid
        ChrootPathSha256 = Get-Sha256Utf8Text "C:\PROGRAMDATA\MACHINEUTILITIES\CHROOT"
        ChrootDirectorySddlSha256 = Get-Sha256Utf8Text $DirectorySddl
        SlotDirectorySddlSha256 = Get-Sha256Utf8Text $DirectorySddl
        SlotFileSddlSha256 = Get-Sha256Utf8Text `
            "O:${RequestSid}G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;$RequestSid)"
        ResultsDirectorySddlSha256 = Get-Sha256Utf8Text $DirectorySddl
        ResultFileSddlSha256 = Get-Sha256Utf8Text `
            "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00120089;;;$RequestSid)"
    }
}

function ConvertTo-CanonicalAsciiBytes([string[]]$Lines) {
    foreach ($Line in $Lines) {
        if ($Line -notmatch '^[\x20-\x7e]*$' -or $Line.Contains("`r") -or $Line.Contains("`n")) {
            throw "non_ascii_record"
        }
    }
    return $script:Ascii.GetBytes(($Lines -join "`n") + "`n")
}

function ConvertFrom-CanonicalAsciiBytes([byte[]]$Bytes, [int]$MaximumBytes, [string]$Label) {
    if ($Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or $Bytes[-1] -ne 10) {
        throw "invalid_$Label"
    }
    foreach ($Byte in $Bytes) {
        if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { throw "invalid_$Label" }
    }
    $Text = $script:Ascii.GetString($Bytes)
    if ($Text.Contains("`r") -or $script:Ascii.GetBytes($Text).Count -ne $Bytes.Count) { throw "invalid_$Label" }
    return [string[]]@($Text.TrimEnd("`n").Split("`n"))
}

function Read-FixedFields([string[]]$Lines, [string[]]$Names, [string]$Header,
        [string]$Trailer, [string]$Label) {
    if ($Lines.Count -ne ($Names.Count + 2) -or $Lines[0] -cne $Header -or $Lines[-1] -cne $Trailer) {
        throw "invalid_$Label"
    }
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Fields.Contains($Parts[0])) {
            throw "invalid_$Label"
        }
        $Fields[$Parts[0]] = $Parts[1]
    }
    return $Fields
}

function Read-HeldBytes([string]$Path, [int]$MaximumBytes) {
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($Stream.Length -lt 1 -or $Stream.Length -gt $MaximumBytes) { throw "bounded_file_invalid" }
        [byte[]]$Bytes = [byte[]]::new([int]$Stream.Length); $Offset = 0
        while ($Offset -lt $Bytes.Count) {
            $Read = $Stream.Read($Bytes, $Offset, $Bytes.Count - $Offset)
            if ($Read -eq 0) { throw "bounded_file_invalid" }
            $Offset += $Read
        }
        return $Bytes
    } finally { $Stream.Dispose() }
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes, [string]$NewFileSddl = "") {
    $Directory = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($Directory)
    $Temporary = Join-Path $Directory ("." + [IO.Path]::GetFileName($Path) + "." + [Guid]::NewGuid().ToString("N"))
    try {
        $Stream = [IO.File]::Open($Temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
        if (-not [string]::IsNullOrEmpty($NewFileSddl)) {
            Set-ExactSddl $Temporary $NewFileSddl
            Assert-ExactSddl $Temporary $NewFileSddl
        }
        [IO.File]::Move($Temporary, $Path, $false)
        if (-not [string]::IsNullOrEmpty($NewFileSddl)) { Assert-ExactSddl $Path $NewFileSddl }
    } finally { if ([IO.File]::Exists($Temporary)) { [IO.File]::Delete($Temporary) } }
}

function Assert-ExactSddl([string]$Path, [string]$ExpectedSddl) {
    $Expected = [Security.AccessControl.RawSecurityDescriptor]::new($ExpectedSddl)
    $ObservedAcl = Get-Acl -LiteralPath $Path
    $Observed = [Security.AccessControl.RawSecurityDescriptor]::new(
        $ObservedAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
    [byte[]]$ExpectedBytes = [byte[]]::new($Expected.BinaryLength)
    [byte[]]$ObservedBytes = [byte[]]::new($Observed.BinaryLength)
    $Expected.GetBinaryForm($ExpectedBytes, 0); $Observed.GetBinaryForm($ObservedBytes, 0)
    if ((Get-Sha256Bytes $ExpectedBytes) -cne (Get-Sha256Bytes $ObservedBytes)) { throw "canary_acl_drift" }
}

function Set-ExactSddl([string]$Path, [string]$Sddl) {
    $Item = Get-Item -LiteralPath $Path -Force
    $Security = if ($Item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() }
        else { [Security.AccessControl.FileSecurity]::new() }
    $Security.SetSecurityDescriptorSddlForm($Sddl); Set-Acl -LiteralPath $Path -AclObject $Security
    Assert-ExactSddl $Path $Sddl
}

function Assert-RegularAbsolutePath([string]$Path, [string]$Label) {
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or -not [IO.File]::Exists($Path)) { throw "${Label}_missing" }
    $Item = Get-Item -LiteralPath $Path -Force
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "${Label}_drift"
    }
}

function Read-ChallengeBytes([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "native_canary_challenge") @(
        "nonce", "host", "epoch", "generation-sha256", "runner-path-sha256", "runner-sha256",
        "runner-publisher-thumbprint", "issued-at", "expires-at", "clock-skew-bound-seconds"
    ) "windows-native-canary-challenge|1" "end-challenge|" "native_canary_challenge"
    [long]$IssuedAt = 0; [long]$ExpiresAt = 0
    if ($Fields.nonce -cnotmatch '^[0-9a-f]{64}$' -or $Fields.host -cnotmatch '^[A-Z0-9][A-Z0-9.-]{0,254}$' -or
        $Fields.epoch -cnotmatch '^[1-9][0-9]{0,9}$' -or -not (Test-Digest $Fields.'generation-sha256') -or
        -not (Test-Digest $Fields.'runner-path-sha256') -or -not (Test-Digest $Fields.'runner-sha256') -or
        -not (Test-Thumbprint $Fields.'runner-publisher-thumbprint') -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at') -or
        -not [long]::TryParse($Fields.'issued-at', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$IssuedAt) -or
        -not [long]::TryParse($Fields.'expires-at', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$ExpiresAt) -or
        $ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 3600 -or
        $Fields.'clock-skew-bound-seconds' -cne "300") { throw "native_canary_challenge_drift" }
    return [pscustomobject]@{ Fields = $Fields; Bytes = $Bytes; IssuedAt = $IssuedAt; ExpiresAt = $ExpiresAt }
}

function Read-TrustRecordBytes([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "runner_trust") @(
        "host", "runner-path-sha256", "runner-sha256", "runner-publisher-thumbprint",
        "cms-signing-thumbprint", "receipt-root", "controlled-smb-root-sha256", "efs-probe-path-sha256"
    ) "windows-native-canary-runner-trust|1" "end-runner-trust|" "runner_trust"
    if ($Fields.host -cnotmatch '^[A-Z0-9][A-Z0-9.-]{0,254}$' -or
        -not (Test-Digest $Fields.'runner-path-sha256') -or -not (Test-Digest $Fields.'runner-sha256') -or
        -not (Test-Thumbprint $Fields.'runner-publisher-thumbprint') -or
        -not (Test-Thumbprint $Fields.'cms-signing-thumbprint') -or
        $Fields.'cms-signing-thumbprint' -cne $Fields.'runner-publisher-thumbprint' -or
        -not (Test-WindowsAbsolutePath $Fields.'receipt-root') -or
        -not (Test-Digest $Fields.'controlled-smb-root-sha256') -or
        -not (Test-Digest $Fields.'efs-probe-path-sha256')) { throw "runner_trust_drift" }
    return $Fields
}

function Get-PreviewText([object]$Challenge) {
    return (@(
        "windows-native-canary-preview|1", "host|$($Challenge.Fields.host)",
        "epoch|$($Challenge.Fields.epoch)", "generation-sha256|$($Challenge.Fields.'generation-sha256')",
        "nonce|$($Challenge.Fields.nonce)", "runner-sha256|$($Challenge.Fields.'runner-sha256')",
        "runner-publisher-thumbprint|$($Challenge.Fields.'runner-publisher-thumbprint')", "end-preview|"
    ) -join "`n") + "`n"
}

function Get-ConfirmationText([object]$Challenge) {
    $PreviewDigest = Get-Sha256Utf8Text (Get-PreviewText $Challenge)
    return "ACTIVATE $($Challenge.Fields.host) EPOCH $($Challenge.Fields.epoch) " +
        "$($Challenge.Fields.'generation-sha256'.Substring(0, 12)) CANARY $($PreviewDigest.Substring(0, 12))"
}

function Read-RawEvidenceBytes([byte[]]$Bytes, [object]$Challenge, [object]$Trust) {
    $GateNames = @(
        "system-task-logged-off", "profile-task-logged-off", "profile-token-limited", "profile-no-network",
        "profile-authenticated-smb-denied", "profile-efs-capability", "profile-efs-denied",
        "chroot-physical-layout", "chroot-effective-access", "slot-write-data-only",
        "slot-create-list-rename-denied", "slot-owner-rights", "slot-quota", "result-read-only",
        "result-non-list", "request-no-task-rights", "claim-copy-race", "openssh-y-verify", "openssh-print-pubkey",
        "openssh-certificate-parse", "winget-system-inventory", "winget-corrupt-hash",
        "winget-dangerous-options", "profile-path-containment", "authoritative-result", "reboot-recovery")
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "native_canary_raw_evidence") `
        (@("nonce", "host", "epoch", "generation-sha256", "controlled-smb-root-sha256",
            "controlled-smb-probe-sha256", "efs-probe-path-sha256", "captured-at", "request-sid",
            "chroot-path-sha256", "chroot-directory-sddl-sha256", "slot-directory-sddl-sha256",
            "slot-file-sddl-sha256", "results-directory-sddl-sha256", "result-file-sddl-sha256") + $GateNames) `
        "windows-native-canary-raw-evidence|2" "end-raw-evidence|" "native_canary_raw_evidence"
    $Access = Get-ChrootAccessEvidenceContract $Fields.'request-sid'
    if ($Fields.nonce -cne $Challenge.Fields.nonce -or $Fields.host -cne $Challenge.Fields.host -or
        $Fields.epoch -cne $Challenge.Fields.epoch -or
        $Fields.'generation-sha256' -cne $Challenge.Fields.'generation-sha256' -or
        $Fields.'controlled-smb-root-sha256' -cne $Trust.'controlled-smb-root-sha256' -or
        -not (Test-Digest $Fields.'controlled-smb-probe-sha256') -or
        $Fields.'efs-probe-path-sha256' -cne $Trust.'efs-probe-path-sha256' -or
        -not (Test-UInt $Fields.'captured-at') -or [long]$Fields.'captured-at' -lt $Challenge.IssuedAt -or
        [long]$Fields.'captured-at' -gt $Challenge.ExpiresAt -or
        $Fields.'chroot-path-sha256' -cne $Access.ChrootPathSha256 -or
        $Fields.'chroot-directory-sddl-sha256' -cne $Access.ChrootDirectorySddlSha256 -or
        $Fields.'slot-directory-sddl-sha256' -cne $Access.SlotDirectorySddlSha256 -or
        $Fields.'slot-file-sddl-sha256' -cne $Access.SlotFileSddlSha256 -or
        $Fields.'results-directory-sddl-sha256' -cne $Access.ResultsDirectorySddlSha256 -or
        $Fields.'result-file-sddl-sha256' -cne $Access.ResultFileSddlSha256) {
        throw "native_canary_raw_evidence_drift"
    }
    foreach ($Name in @($GateNames | Where-Object { $_ -notin @("profile-efs-capability", "profile-efs-denied") })) {
        if ($Fields[$Name] -cne "passed") { throw "native_canary_incomplete" }
    }
    if (($Fields.'profile-efs-capability' -ceq "supported" -and $Fields.'profile-efs-denied' -cne "passed") -or
        ($Fields.'profile-efs-capability' -ceq "not-supported" -and
            $Fields.'profile-efs-denied' -cne "not-supported") -or
        $Fields.'profile-efs-capability' -cnotin @("supported", "not-supported")) {
        throw "native_canary_incomplete"
    }
    return $Fields
}

function Assert-NonExportablePrivateKey([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate) {
    if (-not $Certificate.HasPrivateKey) { throw "canary_signing_private_key_missing" }
    $PrivateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if ($null -eq $PrivateKey) { throw "canary_signing_key_unsupported" }
    try {
        if ($PrivateKey -is [Security.Cryptography.RSACng]) {
            $ExportPolicy = $PrivateKey.Key.ExportPolicy
            if ($ExportPolicy -ne [Security.Cryptography.CngExportPolicies]::None) {
                throw "canary_signing_key_exportable"
            }
        } elseif ($PrivateKey -is [Security.Cryptography.RSACryptoServiceProvider]) {
            if ($PrivateKey.CspKeyContainerInfo.Exportable) { throw "canary_signing_key_exportable" }
        } else { throw "canary_signing_key_unsupported" }
    } finally { $PrivateKey.Dispose() }
}

function Get-PinnedSigningCertificate([string]$Thumbprint) {
    $Matches = New-Object Collections.Generic.List[object]
    foreach ($StoreLocation in @("Cert:\LocalMachine\My", "Cert:\CurrentUser\My")) {
        foreach ($Certificate in @(Get-ChildItem -LiteralPath $StoreLocation -ErrorAction SilentlyContinue)) {
            if ($Certificate.Thumbprint.ToUpperInvariant() -ceq $Thumbprint) { [void]$Matches.Add($Certificate) }
        }
    }
    if ($Matches.Count -ne 1) { throw "canary_signing_certificate_ambiguous" }
    Assert-NonExportablePrivateKey $Matches[0]
    return $Matches[0]
}

function New-DetachedCmsSignature([byte[]]$Bytes,
        [Security.Cryptography.X509Certificates.X509Certificate2]$Certificate) {
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
    $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
        [Security.Cryptography.Pkcs.ContentInfo]::new($Bytes), $true)
    $Signer = [Security.Cryptography.Pkcs.CmsSigner]::new($Certificate)
    $Signer.IncludeOption = [Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
    $Cms.ComputeSignature($Signer, $true)
    return $Cms.Encode()
}

function Test-DetachedCmsSignature([byte[]]$Bytes, [byte[]]$SignatureBytes, [string]$Thumbprint) {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
        $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
            [Security.Cryptography.Pkcs.ContentInfo]::new($Bytes), $true)
        $Cms.Decode($SignatureBytes); $Cms.CheckSignature($true)
        return $Cms.SignerInfos.Count -eq 1 -and $null -ne $Cms.SignerInfos[0].Certificate -and
            $Cms.SignerInfos[0].Certificate.Thumbprint.ToUpperInvariant() -ceq $Thumbprint
    } catch { return $false }
}

function Get-NativeCanaryReceiptFieldNames {
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
        "result-non-list", "request-no-task-rights", "claim-copy-race", "openssh-y-verify", "openssh-print-pubkey",
        "openssh-certificate-parse", "winget-system-inventory", "winget-corrupt-hash",
        "winget-dangerous-options", "profile-path-containment", "authoritative-result", "reboot-recovery",
        "raw-evidence-sha256")
}

function Get-ReceiptBytes([object]$Challenge, [object]$Trust, [object]$Evidence,
        [byte[]]$RawEvidenceBytes, [long]$IssuedAt) {
    $Fields = $Challenge.Fields
    $Access = Get-ChrootAccessEvidenceContract $Evidence.'request-sid'
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-native-canary-receipt|3", "nonce|$($Fields.nonce)", "host|$($Fields.host)",
        "epoch|$($Fields.epoch)", "generation-sha256|$($Fields.'generation-sha256')",
        "runner-path-sha256|$($Fields.'runner-path-sha256')", "runner-sha256|$($Fields.'runner-sha256')",
        "runner-publisher-thumbprint|$($Fields.'runner-publisher-thumbprint')", "issued-at|$IssuedAt",
        "expires-at|$($Challenge.ExpiresAt)",
        "human-preview-sha256|$(Get-Sha256Utf8Text (Get-PreviewText $Challenge))",
        "human-confirmation-sha256|$(Get-Sha256Utf8Text (Get-ConfirmationText $Challenge))",
        "clock-skew-bound-seconds|300", "request-sid|$($Access.RequestSid)",
        "chroot-path-sha256|$($Access.ChrootPathSha256)",
        "chroot-directory-sddl-sha256|$($Access.ChrootDirectorySddlSha256)",
        "slot-directory-sddl-sha256|$($Access.SlotDirectorySddlSha256)",
        "slot-file-sddl-sha256|$($Access.SlotFileSddlSha256)",
        "results-directory-sddl-sha256|$($Access.ResultsDirectorySddlSha256)",
        "result-file-sddl-sha256|$($Access.ResultFileSddlSha256)",
        "system-task-logged-off|$($Evidence.'system-task-logged-off')",
        "profile-task-logged-off|$($Evidence.'profile-task-logged-off')",
        "profile-token-limited|$($Evidence.'profile-token-limited')",
        "profile-no-network|$($Evidence.'profile-no-network')",
        "profile-authenticated-smb-denied|$($Evidence.'profile-authenticated-smb-denied')",
        "profile-efs-capability|$($Evidence.'profile-efs-capability')",
        "profile-efs-denied|$($Evidence.'profile-efs-denied')",
        "chroot-physical-layout|$($Evidence.'chroot-physical-layout')",
        "chroot-effective-access|$($Evidence.'chroot-effective-access')",
        "slot-write-data-only|$($Evidence.'slot-write-data-only')",
        "slot-create-list-rename-denied|$($Evidence.'slot-create-list-rename-denied')",
        "slot-owner-rights|$($Evidence.'slot-owner-rights')",
        "slot-quota|$($Evidence.'slot-quota')",
        "result-read-only|$($Evidence.'result-read-only')",
        "result-non-list|$($Evidence.'result-non-list')",
        "request-no-task-rights|$($Evidence.'request-no-task-rights')",
        "claim-copy-race|$($Evidence.'claim-copy-race')",
        "openssh-y-verify|$($Evidence.'openssh-y-verify')",
        "openssh-print-pubkey|$($Evidence.'openssh-print-pubkey')",
        "openssh-certificate-parse|$($Evidence.'openssh-certificate-parse')",
        "winget-system-inventory|$($Evidence.'winget-system-inventory')",
        "winget-corrupt-hash|$($Evidence.'winget-corrupt-hash')",
        "winget-dangerous-options|$($Evidence.'winget-dangerous-options')",
        "profile-path-containment|$($Evidence.'profile-path-containment')",
        "authoritative-result|$($Evidence.'authoritative-result')",
        "reboot-recovery|$($Evidence.'reboot-recovery')",
        "raw-evidence-sha256|$(Get-Sha256Bytes $RawEvidenceBytes)", "end-canary|")
}

function Get-CanaryPublicationBytes([string]$Nonce, [byte[]]$ReceiptBytes,
        [byte[]]$SignatureBytes, [byte[]]$EvidenceBytes) {
    if ($Nonce -cnotmatch '^[0-9a-f]{64}$') { throw "invalid_canary_publication" }
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-native-canary-publication|1", "nonce|$Nonce",
        "receipt-sha256|$(Get-Sha256Bytes $ReceiptBytes)",
        "signature-sha256|$(Get-Sha256Bytes $SignatureBytes)",
        "evidence-sha256|$(Get-Sha256Bytes $EvidenceBytes)", "end-publication|")
}

function Get-CanaryPublicationRecoveryDisposition([bool]$ConsumedPresent,
        [bool]$PublicationPresent, [bool]$StagePresent, [int]$FinalPartCount) {
    if ($FinalPartCount -lt 0 -or $FinalPartCount -gt 3) { throw "invalid_canary_publication_state" }
    if ($ConsumedPresent) { return "replay" }
    if ($PublicationPresent) { return "committed" }
    if ($StagePresent) { return "resume-staging" }
    if ($FinalPartCount -eq 3) { return "reconstruct-marker" }
    if ($FinalPartCount -gt 0) { return "recovery-required" }
    return "new-publication"
}

function Assert-CanaryPublicationBundle([object]$Challenge, [object]$Trust, [object]$Evidence,
        [byte[]]$RawEvidenceBytes, [byte[]]$ReceiptBytes, [byte[]]$SignatureBytes,
        [byte[]]$PublicationBytes) {
    $ReceiptFields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $ReceiptBytes 16384 "receipt") `
        (Get-NativeCanaryReceiptFieldNames) "windows-native-canary-receipt|3" "end-canary|" "receipt"
    [long]$IssuedAt = 0
    if (-not [long]::TryParse($ReceiptFields.'issued-at', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$IssuedAt) -or
        $IssuedAt -lt $Challenge.IssuedAt -or $IssuedAt -gt $Challenge.ExpiresAt -or
        (Get-Sha256Bytes $ReceiptBytes) -cne
            (Get-Sha256Bytes (Get-ReceiptBytes $Challenge $Trust $Evidence $RawEvidenceBytes $IssuedAt)) -or
        -not (Test-DetachedCmsSignature $ReceiptBytes $SignatureBytes $Trust.'cms-signing-thumbprint')) {
        throw "canary_publication_drift"
    }
    $Publication = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $PublicationBytes 4096 "publication") `
        @("nonce", "receipt-sha256", "signature-sha256", "evidence-sha256") `
        "windows-native-canary-publication|1" "end-publication|" "publication"
    if ($Publication.nonce -cne $Challenge.Fields.nonce -or
        $Publication.'receipt-sha256' -cne (Get-Sha256Bytes $ReceiptBytes) -or
        $Publication.'signature-sha256' -cne (Get-Sha256Bytes $SignatureBytes) -or
        $Publication.'evidence-sha256' -cne (Get-Sha256Bytes $RawEvidenceBytes)) {
        throw "canary_publication_drift"
    }
}

function Publish-ProtectedFileExact([string]$Path, [byte[]]$Bytes, [int]$MaximumBytes) {
    if ([IO.File]::Exists($Path)) {
        Assert-RegularAbsolutePath $Path "canary_publication"
        Assert-ExactSddl $Path $script:ProtectedFileSddl
        [byte[]]$Observed = Read-HeldBytes $Path $MaximumBytes
        if ($Observed.Count -ne $Bytes.Count -or (Get-Sha256Bytes $Observed) -cne (Get-Sha256Bytes $Bytes)) {
            throw "canary_publication_drift"
        }
        return
    }
    if ([IO.Directory]::Exists($Path)) { throw "canary_publication_drift" }
    Write-AtomicBytes $Path $Bytes $script:ProtectedFileSddl
}

function Read-ProtectedCanaryPublication([string]$ReceiptPath, [string]$SignaturePath,
        [string]$EvidencePath, [string]$PublicationPath, [object]$Challenge, [object]$Trust,
        [object]$Evidence, [byte[]]$RawEvidenceBytes) {
    foreach ($Path in @($ReceiptPath, $SignaturePath, $EvidencePath, $PublicationPath)) {
        Assert-RegularAbsolutePath $Path "canary_publication"
        Assert-ExactSddl $Path $script:ProtectedFileSddl
    }
    [byte[]]$ReceiptBytes = Read-HeldBytes $ReceiptPath 16384
    [byte[]]$SignatureBytes = Read-HeldBytes $SignaturePath 65536
    [byte[]]$ObservedEvidenceBytes = Read-HeldBytes $EvidencePath 1048576
    [byte[]]$PublicationBytes = Read-HeldBytes $PublicationPath 4096
    if ($ObservedEvidenceBytes.Count -ne $RawEvidenceBytes.Count -or
        (Get-Sha256Bytes $ObservedEvidenceBytes) -cne (Get-Sha256Bytes $RawEvidenceBytes)) {
        throw "canary_publication_drift"
    }
    Assert-CanaryPublicationBundle $Challenge $Trust $Evidence $RawEvidenceBytes $ReceiptBytes `
        $SignatureBytes $PublicationBytes
    return [pscustomobject]@{ Receipt = $ReceiptBytes; Signature = $SignatureBytes
        Evidence = $ObservedEvidenceBytes; Publication = $PublicationBytes }
}

function Read-StagedCanaryPublication([string]$StagePath, [object]$Challenge, [object]$Trust,
        [object]$Evidence, [byte[]]$RawEvidenceBytes) {
    if (-not [IO.Path]::IsPathFullyQualified($StagePath) -or -not [IO.Directory]::Exists($StagePath) -or
        [IO.File]::Exists($StagePath)) { throw "canary_publication_staging_drift" }
    $StageItem = Get-Item -LiteralPath $StagePath -Force
    if (-not $StageItem.PSIsContainer -or
        ($StageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "canary_publication_staging_drift"
    }
    Assert-ExactSddl $StagePath $script:ProtectedDirectorySddl
    $ExpectedNames = [string[]]@("receipt", "p7s", "evidence", "publication")
    $ObservedEntries = @([IO.Directory]::EnumerateFileSystemEntries(
        $StagePath, "*", [IO.SearchOption]::TopDirectoryOnly))
    if ($ObservedEntries.Count -ne $ExpectedNames.Count) { throw "canary_publication_staging_drift" }
    foreach ($Name in $ExpectedNames) {
        $ExpectedPath = Join-Path $StagePath $Name
        if (-not ($ObservedEntries | Where-Object {
                [IO.Path]::GetFullPath($_) -ceq [IO.Path]::GetFullPath($ExpectedPath) })) {
            throw "canary_publication_staging_drift"
        }
    }
    return Read-ProtectedCanaryPublication (Join-Path $StagePath "receipt") `
        (Join-Path $StagePath "p7s") (Join-Path $StagePath "evidence") `
        (Join-Path $StagePath "publication") $Challenge $Trust $Evidence $RawEvidenceBytes
}

function Invoke-SelfTest {
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $Challenge = Read-ChallengeBytes (ConvertTo-CanonicalAsciiBytes @(
        "windows-native-canary-challenge|1", "nonce|$('a' * 64)", "host|FIXTURE-HOST", "epoch|7",
        "generation-sha256|$('b' * 64)", "runner-path-sha256|$('c' * 64)",
        "runner-sha256|$('d' * 64)", "runner-publisher-thumbprint|$('E' * 40)",
        "issued-at|$Now", "expires-at|$($Now + 600)", "clock-skew-bound-seconds|300", "end-challenge|"))
    $Trust = Read-TrustRecordBytes (ConvertTo-CanonicalAsciiBytes @(
        "windows-native-canary-runner-trust|1", "host|FIXTURE-HOST", "runner-path-sha256|$('c' * 64)",
        "runner-sha256|$('d' * 64)", "runner-publisher-thumbprint|$('E' * 40)",
        "cms-signing-thumbprint|$('E' * 40)", "receipt-root|C:\Fixture\Receipts",
        "controlled-smb-root-sha256|$('f' * 64)", "efs-probe-path-sha256|$('1' * 64)",
        "end-runner-trust|"))
    $GateNames = @(
        "system-task-logged-off", "profile-task-logged-off", "profile-token-limited", "profile-no-network",
        "profile-authenticated-smb-denied", "chroot-physical-layout", "chroot-effective-access",
        "slot-write-data-only", "slot-create-list-rename-denied", "slot-owner-rights", "slot-quota",
        "result-read-only", "result-non-list", "request-no-task-rights", "claim-copy-race",
        "openssh-y-verify", "openssh-print-pubkey", "openssh-certificate-parse", "winget-system-inventory",
        "winget-corrupt-hash", "winget-dangerous-options", "profile-path-containment", "authoritative-result",
        "reboot-recovery")
    $FixtureAccess = Get-ChrootAccessEvidenceContract "S-1-5-21-1-2-3-1200"
    $RawLines = @(
        "windows-native-canary-raw-evidence|2", "nonce|$('a' * 64)", "host|FIXTURE-HOST", "epoch|7",
        "generation-sha256|$('b' * 64)", "controlled-smb-root-sha256|$('f' * 64)",
        "controlled-smb-probe-sha256|$('2' * 64)", "efs-probe-path-sha256|$('1' * 64)", "captured-at|$Now",
        "request-sid|$($FixtureAccess.RequestSid)", "chroot-path-sha256|$($FixtureAccess.ChrootPathSha256)",
        "chroot-directory-sddl-sha256|$($FixtureAccess.ChrootDirectorySddlSha256)",
        "slot-directory-sddl-sha256|$($FixtureAccess.SlotDirectorySddlSha256)",
        "slot-file-sddl-sha256|$($FixtureAccess.SlotFileSddlSha256)",
        "results-directory-sddl-sha256|$($FixtureAccess.ResultsDirectorySddlSha256)",
        "result-file-sddl-sha256|$($FixtureAccess.ResultFileSddlSha256)")
    foreach ($Name in $GateNames[0..4]) { $RawLines += "$Name|passed" }
    $RawLines += @("profile-efs-capability|supported", "profile-efs-denied|passed")
    foreach ($Name in $GateNames[5..($GateNames.Count - 1)]) { $RawLines += "$Name|passed" }
    $RawLines += "end-raw-evidence|"
    [byte[]]$RawBytes = ConvertTo-CanonicalAsciiBytes $RawLines
    $Evidence = Read-RawEvidenceBytes $RawBytes $Challenge $Trust
    [byte[]]$Receipt = Get-ReceiptBytes $Challenge $Trust $Evidence $RawBytes $Now
    $ParsedReceipt = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Receipt 16384 "receipt") `
        (Get-NativeCanaryReceiptFieldNames) "windows-native-canary-receipt|3" "end-canary|" "receipt"
    if ($ParsedReceipt.nonce -cne $Challenge.Fields.nonce -or
        $ParsedReceipt.'raw-evidence-sha256' -cne (Get-Sha256Bytes $RawBytes) -or
        (Get-ConfirmationText $Challenge) -notmatch '^ACTIVATE FIXTURE-HOST EPOCH 7 ') {
        throw "runner receipt self-test failed"
    }
    $BadRaw = @($RawLines | ForEach-Object {
        if ($_ -ceq "profile-authenticated-smb-denied|passed") { "profile-authenticated-smb-denied|failed" } else { $_ }
    })
    $Rejected = $false
    try { [void](Read-RawEvidenceBytes (ConvertTo-CanonicalAsciiBytes $BadRaw) $Challenge $Trust) }
    catch { $Rejected = $_.Exception.Message -eq "native_canary_incomplete" }
    if (-not $Rejected) { throw "runner negative self-test failed" }
    $BadAccessRaw = @($RawLines | ForEach-Object {
        if ($_ -like "slot-file-sddl-sha256|*") { "slot-file-sddl-sha256|$('9' * 64)" } else { $_ }
    })
    $BadAccessRejected = $false
    try { [void](Read-RawEvidenceBytes (ConvertTo-CanonicalAsciiBytes $BadAccessRaw) $Challenge $Trust) }
    catch { $BadAccessRejected = $_.Exception.Message -eq "native_canary_raw_evidence_drift" }
    if (-not $BadAccessRejected) { throw "runner access contract self-test failed" }
    $NonCanonicalEfsRaw = @($RawLines | ForEach-Object {
        if ($_ -ceq "profile-efs-capability|supported") { "profile-efs-capability|SUPPORTED" } else { $_ }
    })
    $NonCanonicalEfsRejected = $false
    try { [void](Read-RawEvidenceBytes (ConvertTo-CanonicalAsciiBytes $NonCanonicalEfsRaw) $Challenge $Trust) }
    catch { $NonCanonicalEfsRejected = $_.Exception.Message -eq "native_canary_incomplete" }
    if (-not $NonCanonicalEfsRejected) { throw "runner EFS capability self-test failed" }

    $CrashVectors = @(
        @("after-staging-rename", $false, $false, $true, 0, "resume-staging"),
        @("after-final-evidence", $false, $false, $true, 1, "resume-staging"),
        @("after-final-signature", $false, $false, $true, 2, "resume-staging"),
        @("after-final-receipt", $false, $false, $true, 3, "resume-staging"),
        @("after-publication-marker", $false, $true, $true, 3, "committed"),
        @("legacy-all-parts-before-marker", $false, $false, $false, 3, "reconstruct-marker"),
        @("orphan-part-without-staging", $false, $false, $false, 1, "recovery-required"),
        @("after-consumed-marker", $true, $true, $false, 3, "replay"))
    foreach ($Vector in $CrashVectors) {
        if ((Get-CanaryPublicationRecoveryDisposition $Vector[1] $Vector[2] $Vector[3] $Vector[4]) -cne
            $Vector[5]) { throw "runner publication crash-boundary self-test failed: $($Vector[0])" }
    }

    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
    $Rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $Request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=MachineUtilities Fixture", $Rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $Certificate = $Request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),
            [DateTimeOffset]::UtcNow.AddMinutes(10))
        try {
            $Signature = New-DetachedCmsSignature $Receipt $Certificate
            if (-not (Test-DetachedCmsSignature $Receipt $Signature $Certificate.Thumbprint.ToUpperInvariant())) {
                throw "runner CMS self-test failed"
            }
            $PublicationTrust = [ordered]@{}
            foreach ($Name in $Trust.Keys) { $PublicationTrust[$Name] = $Trust[$Name] }
            $PublicationTrust['cms-signing-thumbprint'] = $Certificate.Thumbprint.ToUpperInvariant()
            $Publication = Get-CanaryPublicationBytes $Challenge.Fields.nonce $Receipt $Signature $RawBytes
            Assert-CanaryPublicationBundle $Challenge $PublicationTrust $Evidence $RawBytes $Receipt `
                $Signature $Publication
            $BadPublication = $script:Ascii.GetBytes(
                $script:Ascii.GetString($Publication).Replace("receipt-sha256|", "receipt-sha256|0"))
            $BadPublicationRejected = $false
            try {
                Assert-CanaryPublicationBundle $Challenge $PublicationTrust $Evidence $RawBytes $Receipt `
                    $Signature $BadPublication
            } catch { $BadPublicationRejected = $_.Exception.Message -like "*publication*" }
            if (-not $BadPublicationRejected) { throw "runner publication binding self-test failed" }
        } finally { $Certificate.Dispose() }
    } finally { $Rsa.Dispose() }
    "PASS: windows-native-canary-runner.ps1 fixture-safe self-check"
}

if ($SelfTest) { Invoke-SelfTest; return }
if (-not $IsWindows) { throw "unsupported_context" }

Assert-RegularAbsolutePath $ChallengePath "challenge"
Assert-RegularAbsolutePath $TrustRecordPath "runner_trust"
Assert-ExactSddl $ChallengePath $script:ProtectedFileSddl
Assert-ExactSddl $TrustRecordPath $script:ProtectedFileSddl
$Challenge = Read-ChallengeBytes (Read-HeldBytes $ChallengePath 4096)
$Trust = Read-TrustRecordBytes (Read-HeldBytes $TrustRecordPath 4096)
if ($Challenge.Fields.host -cne [Environment]::MachineName.ToUpperInvariant() -or
    $Trust.host -cne $Challenge.Fields.host -or
    $Trust.'runner-path-sha256' -cne $Challenge.Fields.'runner-path-sha256' -or
    $Trust.'runner-sha256' -cne $Challenge.Fields.'runner-sha256' -or
    $Trust.'runner-publisher-thumbprint' -cne $Challenge.Fields.'runner-publisher-thumbprint') {
    throw "runner_trust_drift"
}
$RunnerPathDigest = Get-Sha256Utf8Text $PSCommandPath.ToUpperInvariant()
$RunnerDigest = Get-Sha256Bytes (Read-HeldBytes $PSCommandPath 4194304)
$Authenticode = Get-AuthenticodeSignature -FilePath $PSCommandPath
if ($RunnerPathDigest -cne $Challenge.Fields.'runner-path-sha256' -or
    $RunnerDigest -cne $Challenge.Fields.'runner-sha256' -or
    $Authenticode.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    $null -eq $Authenticode.SignerCertificate -or
    $Authenticode.SignerCertificate.Thumbprint.ToUpperInvariant() -cne
        $Challenge.Fields.'runner-publisher-thumbprint') { throw "runner_identity_drift" }
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($Challenge.IssuedAt -gt ($Now + 300)) { throw "native_canary_challenge_expired" }
$ExpectedConfirmation = Get-ConfirmationText $Challenge
if ($Preview) {
    if ($Challenge.ExpiresAt -le $Now) { throw "native_canary_challenge_expired" }
    [pscustomobject][ordered]@{
        host = $Challenge.Fields.host; epoch = [long]$Challenge.Fields.epoch
        generation_sha256 = $Challenge.Fields.'generation-sha256'
        nonce = $Challenge.Fields.nonce; preview = Get-PreviewText $Challenge
        confirmation = $ExpectedConfirmation
    } | ConvertTo-Json -Depth 3
    return
}
if ($Confirmation -cne $ExpectedConfirmation) { throw "human_confirmation_mismatch" }
Assert-RegularAbsolutePath $RawEvidencePath "raw_evidence"
Assert-ExactSddl $RawEvidencePath $script:ProtectedFileSddl
[byte[]]$RawEvidenceBytes = Read-HeldBytes $RawEvidencePath 1048576
$Evidence = Read-RawEvidenceBytes $RawEvidenceBytes $Challenge $Trust
if ($ControlledSmbProbePath -notmatch '^\\\\[^\\]+\\[^\\]+\\.+$' -or
    -not [IO.File]::Exists($ControlledSmbProbePath) -or
    (Get-Sha256Utf8Text ([IO.Path]::GetDirectoryName($ControlledSmbProbePath).ToUpperInvariant())) -cne
        $Trust.'controlled-smb-root-sha256' -or
    (Get-Sha256Utf8Text $ControlledSmbProbePath.ToUpperInvariant()) -cne
        $Evidence.'controlled-smb-probe-sha256') { throw "controlled_smb_probe_drift" }
if ((Get-Sha256Utf8Text $ControlledEfsProbePath.ToUpperInvariant()) -cne $Trust.'efs-probe-path-sha256') {
    throw "controlled_efs_probe_drift"
}
if ($Evidence.'profile-efs-capability' -ceq "supported") {
    Assert-RegularAbsolutePath $ControlledEfsProbePath "controlled_efs_probe"
    if (((Get-Item -LiteralPath $ControlledEfsProbePath -Force).Attributes -band
            [IO.FileAttributes]::Encrypted) -eq 0) { throw "controlled_efs_probe_drift" }
} elseif ([IO.File]::Exists($ControlledEfsProbePath) -and
    ((Get-Item -LiteralPath $ControlledEfsProbePath -Force).Attributes -band [IO.FileAttributes]::Encrypted) -ne 0) {
    throw "controlled_efs_capability_drift"
}
$ReceiptRoot = [string]$Trust.'receipt-root'
if (-not [IO.Directory]::Exists($ReceiptRoot) -or
    ((Get-Item -LiteralPath $ReceiptRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "receipt_root_drift"
}
Assert-ExactSddl $ReceiptRoot $script:ProtectedDirectorySddl
$Stem = Join-Path $ReceiptRoot ("receipt-" + $Challenge.Fields.nonce)
$ReceiptPath = $Stem + ".receipt"; $SignaturePath = $Stem + ".p7s"
$EvidencePath = $Stem + ".evidence"; $PublicationPath = $Stem + ".publication"
$ConsumedPath = $Stem + ".consumed"; $StagePath = $Stem + ".staging"
$FinalPartPaths = @($ReceiptPath, $SignaturePath, $EvidencePath)
$PresentFinalParts = @($FinalPartPaths | Where-Object {
    [IO.File]::Exists($_) -or [IO.Directory]::Exists($_) })
$PublicationDisposition = Get-CanaryPublicationRecoveryDisposition `
    ([IO.File]::Exists($ConsumedPath) -or [IO.Directory]::Exists($ConsumedPath)) `
    ([IO.File]::Exists($PublicationPath) -or [IO.Directory]::Exists($PublicationPath)) `
    ([IO.Directory]::Exists($StagePath) -or [IO.File]::Exists($StagePath)) $PresentFinalParts.Count
if ($PublicationDisposition -ceq "replay") {
    throw "native_canary_nonce_replay"
}

$Bundle = $null
if ($PublicationDisposition -ceq "committed") {
    $Bundle = Read-ProtectedCanaryPublication $ReceiptPath $SignaturePath $EvidencePath `
        $PublicationPath $Challenge $Trust $Evidence $RawEvidenceBytes
} elseif ($PublicationDisposition -ceq "resume-staging") {
    $Bundle = Read-StagedCanaryPublication $StagePath $Challenge $Trust $Evidence $RawEvidenceBytes
} else {
    if ($PublicationDisposition -ceq "recovery-required") {
        throw "native_canary_publication_recovery_required"
    }
    if ($PublicationDisposition -ceq "reconstruct-marker") {
        foreach ($Path in $FinalPartPaths) {
            Assert-RegularAbsolutePath $Path "canary_publication"
            Assert-ExactSddl $Path $script:ProtectedFileSddl
        }
        [byte[]]$RecoveredReceipt = Read-HeldBytes $ReceiptPath 16384
        [byte[]]$RecoveredSignature = Read-HeldBytes $SignaturePath 65536
        [byte[]]$RecoveredEvidence = Read-HeldBytes $EvidencePath 1048576
        if ($RecoveredEvidence.Count -ne $RawEvidenceBytes.Count -or
            (Get-Sha256Bytes $RecoveredEvidence) -cne (Get-Sha256Bytes $RawEvidenceBytes)) {
            throw "canary_publication_drift"
        }
        [byte[]]$RecoveredPublication = Get-CanaryPublicationBytes $Challenge.Fields.nonce `
            $RecoveredReceipt $RecoveredSignature $RecoveredEvidence
        Assert-CanaryPublicationBundle $Challenge $Trust $Evidence $RawEvidenceBytes `
            $RecoveredReceipt $RecoveredSignature $RecoveredPublication
        $Bundle = [pscustomobject]@{ Receipt = $RecoveredReceipt; Signature = $RecoveredSignature
            Evidence = $RecoveredEvidence; Publication = $RecoveredPublication }
    } else {
        if ($PublicationDisposition -cne "new-publication") { throw "invalid_canary_publication_state" }
        $IssuedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($Challenge.ExpiresAt -le $IssuedAt) { throw "native_canary_challenge_expired" }
        $Certificate = Get-PinnedSigningCertificate $Trust.'cms-signing-thumbprint'
        try {
            [byte[]]$NewReceipt = Get-ReceiptBytes $Challenge $Trust $Evidence $RawEvidenceBytes $IssuedAt
            [byte[]]$NewSignature = New-DetachedCmsSignature $NewReceipt $Certificate
            if (-not (Test-DetachedCmsSignature $NewReceipt $NewSignature `
                    $Trust.'cms-signing-thumbprint')) { throw "canary_signature_verification_failed" }
            [byte[]]$NewPublication = Get-CanaryPublicationBytes $Challenge.Fields.nonce `
                $NewReceipt $NewSignature $RawEvidenceBytes
        } finally { $Certificate.Dispose() }

        $TemporaryStage = $Stem + ".staging-" + [Guid]::NewGuid().ToString("N")
        try {
            [void][IO.Directory]::CreateDirectory($TemporaryStage)
            Set-ExactSddl $TemporaryStage $script:ProtectedDirectorySddl
            Publish-ProtectedFileExact (Join-Path $TemporaryStage "receipt") $NewReceipt 16384
            Publish-ProtectedFileExact (Join-Path $TemporaryStage "p7s") $NewSignature 65536
            Publish-ProtectedFileExact (Join-Path $TemporaryStage "evidence") $RawEvidenceBytes 1048576
            Publish-ProtectedFileExact (Join-Path $TemporaryStage "publication") $NewPublication 4096
            [IO.Directory]::Move($TemporaryStage, $StagePath)
        } finally {
            if ([IO.Directory]::Exists($TemporaryStage)) { [IO.Directory]::Delete($TemporaryStage, $true) }
        }
        $Bundle = Read-StagedCanaryPublication $StagePath $Challenge $Trust $Evidence $RawEvidenceBytes
    }
}

# The publication record is the only commit marker. Each preceding write is idempotent so a crash
# at any boundary can resume from the protected staging bundle without accepting a partial result.
Publish-ProtectedFileExact $EvidencePath $Bundle.Evidence 1048576
Publish-ProtectedFileExact $SignaturePath $Bundle.Signature 65536
Publish-ProtectedFileExact $ReceiptPath $Bundle.Receipt 16384
Publish-ProtectedFileExact $PublicationPath $Bundle.Publication 4096
$CommittedBundle = Read-ProtectedCanaryPublication $ReceiptPath $SignaturePath $EvidencePath `
    $PublicationPath $Challenge $Trust $Evidence $RawEvidenceBytes
if ([IO.Directory]::Exists($StagePath)) {
    # The committed final marker is authoritative. Retire a still-exact staging directory by an
    # atomic rename before recursive cleanup, so a cleanup crash cannot poison the canonical name.
    try {
        [void](Read-StagedCanaryPublication $StagePath $Challenge $Trust $Evidence $RawEvidenceBytes)
        $RetiredStagePath = $StagePath + ".retired-" + [Guid]::NewGuid().ToString("N")
        [IO.Directory]::Move($StagePath, $RetiredStagePath)
        try { [IO.Directory]::Delete($RetiredStagePath, $true) } catch { }
    } catch { }
}
[pscustomobject][ordered]@{
    state = "receipt_ready"; receipt = $ReceiptPath; signature = $SignaturePath
    evidence = $EvidencePath; publication = $PublicationPath
    receipt_sha256 = Get-Sha256Bytes $CommittedBundle.Receipt
} | ConvertTo-Json -Depth 3
