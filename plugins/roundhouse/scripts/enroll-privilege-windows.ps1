[CmdletBinding(DefaultParameterSetName = "Status")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Status")][switch]$Status,
    [Parameter(Mandatory = $true, ParameterSetName = "Preview")][switch]$Preview,
    [Parameter(Mandatory = $true, ParameterSetName = "Install")][switch]$Install,
    [Parameter(Mandatory = $true, ParameterSetName = "ActivateNativeCanary")][switch]$ActivateNativeCanary,
    [Parameter(Mandatory = $true, ParameterSetName = "Revoke")][switch]$Revoke,
    [Parameter(Mandatory = $true, ParameterSetName = "Install")]
    [Parameter(Mandatory = $true, ParameterSetName = "ActivateNativeCanary")]
    [Parameter(Mandatory = $true, ParameterSetName = "Revoke")][string]$Confirmation,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Ascii = [Text.Encoding]::ASCII
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:BrokerVersion = "1.0.0"
$script:RequestAccountName = "RoundhouseRequest"
$script:SystemTaskName = "RoundhouseBrokerV1"
$script:ProfileTaskName = "RoundhouseProfileV1"
$script:TaskSddl = "O:SYG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
$script:TaskCreateOrUpdate = 0x6
$script:TaskDontAddPrincipalAce = 0x10
$script:TaskSecurityInformation = 0x7
$script:TaskLogonServiceAccount = 0x5
$script:SlotQuotaBytes = 68157440
$script:SlotWarningBytes = 67108864
$script:ProvisionPollTimeoutSeconds = 3660
$script:TaskQuiesceTimeoutSeconds = 600
$script:ClockSkewBoundSeconds = 300
$script:PollIntervalSeconds = 60
$script:AuditReservationBytes = 1048576
$script:TerminalReservationBytes = 65536
$script:ReservationFillByte = [byte]0xA5
$script:SelfTestFixture = $false

function Get-Sha256Bytes([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $Hasher.Dispose() }
}

function Get-Sha256Text([string]$Text) { return Get-Sha256Bytes $script:Ascii.GetBytes($Text) }
function Get-Sha256Utf8Text([string]$Text) { return Get-Sha256Bytes $script:Utf8.GetBytes($Text) }
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
function Get-NormalizedTaskXmlSha256([string]$XmlText) {
    return Get-Sha256Utf8Text (Get-NormalizedTaskXml $XmlText)
}
function Get-TaskXmlWithEnabledState([string]$XmlText, [bool]$Enabled) {
    try { [xml]$Document = $XmlText } catch { throw "invalid_task_xml" }
    $Namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Namespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
    $EnabledNodes = @($Document.SelectNodes("/t:Task/t:Settings/t:Enabled", $Namespace))
    if ($EnabledNodes.Count -ne 1 -or [string]$EnabledNodes[0].InnerText -cnotin @("true", "false")) {
        throw "invalid_task_xml"
    }
    $EnabledNodes[0].InnerText = $Enabled.ToString().ToLowerInvariant()
    return $Document.OuterXml
}
function Test-Digest([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }
function Test-Atom([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:+@,-]{0,255}$' }
function Test-UInt([string]$Value) { return $Value -cmatch '^(0|[1-9][0-9]{0,18})$' }
function Test-WindowsAbsolutePath([string]$Path) {
    return $Path -cmatch '^[A-Za-z]:\\[^:*?"<>|\r\n]+$' -and $Path -notmatch '(?:^|\\)\.\.?(?:\\|$)'
}

function ConvertFrom-CanonicalAsciiBytes([byte[]]$Bytes, [int]$MaximumBytes, [string]$Label) {
    if ($Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or $Bytes[-1] -ne 10) { throw "invalid_$Label" }
    foreach ($Byte in $Bytes) { if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { throw "invalid_$Label" } }
    $Text = $script:Ascii.GetString($Bytes)
    if ($Text.Contains("`r")) { throw "invalid_$Label" }
    return [string[]]@($Text.Substring(0, $Text.Length - 1).Split("`n"))
}

function ConvertTo-CanonicalAsciiBytes([string[]]$Lines) {
    foreach ($Line in $Lines) { if ($Line -notmatch '^[\x20-\x7e]*$') { throw "non_ascii_record" } }
    return $script:Ascii.GetBytes(($Lines -join "`n") + "`n")
}

function Read-FixedFields([string[]]$Lines, [string[]]$Names, [string]$Header, [string]$Trailer, [string]$Label) {
    if ($Lines.Count -ne $Names.Count + 2 -or $Lines[0] -cne $Header -or $Lines[-1] -cne $Trailer) {
        throw "invalid_$Label"
    }
    $Result = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Result.Contains($Parts[0])) {
            throw "invalid_$Label"
        }
        $Result[$Parts[0]] = $Parts[1]
    }
    return $Result
}

function Read-BootstrapReceipt([byte[]]$Bytes, [string]$ExpectedStageRoot) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "bootstrap_receipt"
    $Fields = Read-FixedFields $Lines @(
        "scope", "publisher-thumbprint", "release-signature-status", "bootstrap-verifier-sha256", "candidate-sha256",
        "protected-copy-sha256", "protected-copy-path", "manifest-sha256", "protected-root",
        "native-canary-runner-path", "native-canary-runner-sha256", "native-canary-publisher-thumbprint",
        "native-canary-receipt-root"
    ) "windows-bootstrap-receipt|1" "end-bootstrap|" "bootstrap_receipt"
    if ($Fields.scope -cne "native" -or $Fields.'release-signature-status' -cne "valid" -or
        $Fields.'publisher-thumbprint' -notmatch '^(?:[0-9A-F]{40}|[0-9A-F]{64})$' -or
        @($Fields.'bootstrap-verifier-sha256', $Fields.'candidate-sha256', $Fields.'protected-copy-sha256', $Fields.'manifest-sha256' |
            Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
        $Fields.'candidate-sha256' -cne $Fields.'protected-copy-sha256' -or
        $Fields.'protected-copy-path' -cne ($ExpectedStageRoot.TrimEnd('\') + "\scripts\enroll-privilege-windows.ps1") -or
        $Fields.'protected-root' -cne $ExpectedStageRoot -or
        -not (Test-WindowsAbsolutePath $Fields.'native-canary-runner-path') -or
        -not (Test-WindowsAbsolutePath $Fields.'native-canary-receipt-root') -or
        -not (Test-Digest $Fields.'native-canary-runner-sha256') -or
        $Fields.'native-canary-publisher-thumbprint' -notmatch '^(?:[0-9A-F]{40}|[0-9A-F]{64})$' -or
        [IO.Path]::GetFullPath($Fields.'native-canary-runner-path').StartsWith(
            [IO.Path]::GetFullPath($ExpectedStageRoot), [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFullPath($Fields.'native-canary-receipt-root').StartsWith(
            [IO.Path]::GetFullPath($ExpectedStageRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "invalid_bootstrap_receipt"
    }
    return $Fields
}

function Read-EnrollmentManifest([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 8192 "enrollment_manifest"
    $Fields = Read-FixedFields $Lines @(
        "epoch", "broker-version", "catalog-version", "policy-sha256", "constraints-sha256",
        "winget-context-sha256", "provider-lock-sha256", "file-set-sha256", "target-profile-sid"
    ) "windows-enrollment-manifest|1" "end-manifest|" "enrollment_manifest"
    [int]$Epoch = 0
    if ($Fields.epoch -notmatch '^[1-9][0-9]{0,9}$' -or
        -not [int]::TryParse($Fields.epoch, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$Epoch) -or $Epoch -lt 1 -or
        $Fields.'broker-version' -cne $script:BrokerVersion -or $Fields.'catalog-version' -cne "1" -or
        @($Fields.'policy-sha256', $Fields.'constraints-sha256', $Fields.'winget-context-sha256',
            $Fields.'provider-lock-sha256', $Fields.'file-set-sha256' | Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
        $Fields.'target-profile-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        $Fields.'target-profile-sid' -match '-500$') { throw "invalid_enrollment_manifest" }
    return [pscustomobject]@{ Fields = $Fields; Epoch = $Epoch; Bytes = $Bytes }
}

function Read-ReleaseFiles([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "release_files"
    if ($Lines.Count -lt 2 -or $Lines[0] -cne "windows-enrollment-files|1" -or $Lines[-1] -cne "end-files|") {
        throw "invalid_release_files"
    }
    $Files = New-Object Collections.Generic.List[object]
    $Seen = @{}; $PreviousPath = ""
    foreach ($Line in @($Lines | Select-Object -Skip 1 | Select-Object -SkipLast 1)) {
        $Parts = $Line.Split('|')
        if ($Parts.Count -ne 3 -or $Parts[0] -cne "file" -or
            $Parts[1] -notmatch '^[A-Za-z0-9._/-]+$' -or $Parts[1].Contains('\') -or
            [IO.Path]::IsPathRooted($Parts[1]) -or $Parts[1] -match '(^|/)\.\.?(?:/|$)' -or
            ($Parts[1] -cnotin @("scripts/enroll-privilege-windows.ps1", "scripts/privilege-broker-windows.ps1",
                    "scripts/profile-worker-windows.ps1", "scripts/register-profile-task-windows.ps1") -and
                -not $Parts[1].StartsWith("generation/", [StringComparison]::Ordinal)) -or
            -not (Test-Digest $Parts[2]) -or [StringComparer]::Ordinal.Compare($PreviousPath, $Parts[1]) -ge 0 -or
            $Seen.ContainsKey($Parts[1])) { throw "invalid_release_files" }
        $Seen[$Parts[1]] = $true; $PreviousPath = $Parts[1]
        [void]$Files.Add([pscustomobject]@{ Path = $Parts[1]; Sha256 = $Parts[2] })
    }
    foreach ($Required in @(
        "scripts/privilege-broker-windows.ps1", "scripts/profile-worker-windows.ps1",
        "scripts/enroll-privilege-windows.ps1", "scripts/register-profile-task-windows.ps1",
        "generation/policy.actions", "generation/policy.constraints", "generation/winget.context",
        "generation/windows-winget-provider.lock")) {
        if (-not $Seen.ContainsKey($Required)) { throw "missing_release_file" }
    }
    return [pscustomobject]@{ Files = $Files; Digest = Get-Sha256Bytes $Bytes }
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
        $Scalar.'package-url' -cne "https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/1.29.280" -or
        -not (Test-Digest $Scalar.'package-sha256') -or
        $Scalar.manifest -cne "Microsoft.WinGet.Client.psd1" -or $Files.Count -lt 1 -or
        -not $Files.Contains($Scalar.manifest) -or
        $Files[$Scalar.manifest] -cne $Scalar.'manifest-sha256') { throw "invalid_winget_module_lock" }
    foreach ($Path in @($Files.Keys) + @($Signatures.Keys)) {
        if ($Path -notmatch '^[A-Za-z0-9._/\[\]-]+$' -or $Path.Contains('\') -or
            [IO.Path]::IsPathRooted($Path) -or $Path -match '(^|/)\.\.?(?:/|$)' -or
            ($Signatures.Contains($Path) -and -not $Files.Contains($Path))) {
            throw "invalid_winget_module_lock"
        }
    }
    return [pscustomobject]@{ Module = $Scalar.module; Version = $Scalar.version
        PackageUrl = $Scalar.'package-url'; PackageSha256 = $Scalar.'package-sha256'
        Manifest = $Scalar.manifest; Files = $Files; Signatures = $Signatures }
}

function Install-ProtectedWinGetModule([string]$GenerationStage, [string]$TransactionRoot) {
    $LockPath = Join-Path $GenerationStage "windows-winget-provider.lock"
    $Lock = Read-WinGetModuleLock (Read-HeldBytes $LockPath 1048576)
    $Scratch = Join-Path $TransactionRoot "winget-module"
    if ([IO.Directory]::Exists($Scratch)) { [IO.Directory]::Delete($Scratch, $true) }
    [void][IO.Directory]::CreateDirectory($Scratch)
    $Archive = Join-Path $Scratch "Microsoft.WinGet.Client.zip"
    $Expanded = Join-Path $Scratch "expanded"
    Invoke-WebRequest -Uri $Lock.PackageUrl -OutFile $Archive -UseBasicParsing
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        $Lock.PackageSha256) { throw "winget_module_package_hash_mismatch" }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Expanded
    $Observed = [ordered]@{}
    foreach ($Path in [IO.Directory]::EnumerateFiles($Expanded, "*", [IO.SearchOption]::AllDirectories)) {
        $Relative = [IO.Path]::GetRelativePath($Expanded, $Path).Replace('\', '/')
        if ($Observed.Contains($Relative)) { throw "winget_module_file_set_mismatch" }
        $Observed[$Relative] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($Observed.Count -ne $Lock.Files.Count) { throw "winget_module_file_set_mismatch" }
    foreach ($Entry in $Lock.Files.GetEnumerator()) {
        if (-not $Observed.Contains($Entry.Key) -or $Observed[$Entry.Key] -cne $Entry.Value) {
            throw "winget_module_file_hash_mismatch"
        }
    }
    foreach ($Relative in $Lock.Signatures.Keys) {
        $Signature = Get-AuthenticodeSignature -FilePath (Join-Path $Expanded $Relative)
        if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
            $null -eq $Signature.SignerCertificate -or
            $Signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
            throw "winget_module_signature_invalid"
        }
    }
    $Destination = Join-Path $GenerationStage "winget/Microsoft.WinGet.Client"
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
    [IO.Directory]::Move($Expanded, $Destination)
}

function Get-ProfileRootIdentityRecord([string]$Sid, [string]$FinalPath, [uint32]$VolumeSerial, [uint64]$FileId) {
    if ($Sid -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-WindowsAbsolutePath $FinalPath)) { throw "invalid_profile_root_identity" }
    return Get-Sha256Utf8Text ("profile-root-identity|1`ntarget-sid|$Sid`nfinal-path|$($FinalPath.ToUpperInvariant())" +
        "`nvolume-serial|$($VolumeSerial.ToString('x8'))`nfile-id|$($FileId.ToString('x16'))`nend-profile-root|`n")
}

function Initialize-EnrollmentProfileRootType {
    if ("RoundhouseEnrollmentProfileRoot" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class RoundhouseEnrollmentProfileRoot
{
    public string FinalPath { get; private set; }
    public uint VolumeSerial { get; private set; }
    public ulong FileId { get; private set; }

    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, char[] path, uint length, uint flags);

    public static RoundhouseEnrollmentProfileRoot Observe(string path)
    {
        SafeFileHandle handle = CreateFileW(path, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose();
            throw new Win32Exception(error, "profile_root_open_failed"); }
        using (handle)
        {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "profile_root_information_failed");
            if ((info.FileAttributes & 0x10) == 0 || (info.FileAttributes & 0x400) != 0)
                throw new InvalidOperationException("profile_root_reparse_or_collision");
            char[] buffer = new char[32768];
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
            if (length == 0 || length >= buffer.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "profile_root_final_path_failed");
            string finalPath = new string(buffer, 0, (int)length);
            if (finalPath.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) finalPath = @"\\" + finalPath.Substring(8);
            else if (finalPath.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) finalPath = finalPath.Substring(4);
            return new RoundhouseEnrollmentProfileRoot { FinalPath = finalPath,
                VolumeSerial = info.VolumeSerialNumber,
                FileId = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow };
        }
    }

    public static void AssertSingleLinkRegularFile(string path, string expectedPath)
    {
        SafeFileHandle handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose();
            throw new Win32Exception(error, "projection_file_open_failed"); }
        using (handle)
        {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "projection_file_information_failed");
            if ((info.FileAttributes & 0x410) != 0 || info.NumberOfLinks != 1)
                throw new InvalidOperationException("projection_file_link_drift");
            char[] buffer = new char[32768];
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
            if (length == 0 || length >= buffer.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "projection_file_final_path_failed");
            string finalPath = new string(buffer, 0, (int)length);
            if (finalPath.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) finalPath = @"\\" + finalPath.Substring(8);
            else if (finalPath.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) finalPath = finalPath.Substring(4);
            if (!Path.GetFullPath(finalPath).Equals(Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("projection_file_path_drift");
        }
    }
}
'@
}

function Get-TargetProfileRootEvidence([string]$TargetSid) {
    try {
        $ProfileKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TargetSid"
        $RawPath = [string](Get-ItemPropertyValue -LiteralPath $ProfileKey -Name ProfileImagePath -ErrorAction Stop)
        if ([string]::IsNullOrWhiteSpace($RawPath)) { throw "profile_root_unavailable" }
        $ProfilePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($RawPath)).TrimEnd('\')
        if (-not (Test-WindowsAbsolutePath $ProfilePath) -or -not [IO.Directory]::Exists($ProfilePath)) {
            throw "profile_root_unavailable"
        }
        Initialize-EnrollmentProfileRootType
        $Observed = [RoundhouseEnrollmentProfileRoot]::Observe($ProfilePath)
        if (-not (Test-WindowsAbsolutePath $Observed.FinalPath) -or
            -not $Observed.FinalPath.Equals($ProfilePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "profile_root_identity_drift"
        }
        return [pscustomobject]@{ ProfilePath = $ProfilePath; FinalPath = $Observed.FinalPath
            ProfileRootId = (Get-ProfileRootIdentityRecord $TargetSid $Observed.FinalPath $Observed.VolumeSerial $Observed.FileId) }
    } catch { throw "unsupported_context" }
}

function Assert-ProfileRootEvidenceMatch([object]$Expected, [object]$Observed) {
    if (-not $Expected.ProfilePath.Equals($Observed.ProfilePath, [StringComparison]::OrdinalIgnoreCase) -or
        -not $Expected.FinalPath.Equals($Observed.FinalPath, [StringComparison]::OrdinalIgnoreCase) -or
        $Expected.ProfileRootId -cne $Observed.ProfileRootId) { throw "profile_root_identity_drift" }
}

function Assert-ProfileReceiptPath([string]$ProfileRoot, [string]$ReceiptPath) {
    $Root = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
    $Current = [IO.Path]::GetFullPath($ReceiptPath)
    if (-not $Current.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "profile_task_registration_drift"
    }
    while ($true) {
        $Item = Get-Item -LiteralPath $Current -Force
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "profile_task_registration_drift"
        }
        if ($Current.TrimEnd('\') -ceq $Root) { break }
        $Parent = [IO.Directory]::GetParent($Current)
        if ($null -eq $Parent) { throw "profile_task_registration_drift" }
        $Current = $Parent.FullName
    }
}

function Read-ProfileTaskRegistrationReceipt([byte[]]$Bytes, [object]$Expected) {
    try { $Document = [Text.Json.JsonDocument]::Parse($script:Utf8.GetString($Bytes)) }
    catch { throw "invalid_profile_task_registration" }
    try {
        if ($Document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw "invalid_profile_task_registration"
        }
        $Required = @("schema", "schema_version", "task_name", "target_sid", "context", "task_xml_sha256",
            "password_supplied", "profile_root_id", "profile_root_path_sha256", "registered_at")
        $Properties = @{}
        foreach ($Property in $Document.RootElement.EnumerateObject()) {
            if ($Property.Name -cnotin $Required -or $Properties.ContainsKey($Property.Name)) {
                throw "invalid_profile_task_registration"
            }
            $Properties[$Property.Name] = $Property.Value
        }
        if ($Properties.Count -ne $Required.Count -or
            @($Required | Where-Object { -not $Properties.ContainsKey($_) }).Count -ne 0 -or
            $Properties.schema.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $Properties.schema.GetString() -cne "roundhouse.profile-task-registration" -or
            $Properties.schema_version.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
            $Properties.schema_version.GetInt32() -ne 1 -or
            $Properties.task_name.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $Properties.task_name.GetString() -cne $script:ProfileTaskName -or
            $Properties.target_sid.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $Properties.target_sid.GetString() -cne $Expected.TargetSid -or
            $Properties.context.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $Properties.context.GetString() -cne "windows-user-s4u-v1" -or
            $Properties.password_supplied.ValueKind -ne [Text.Json.JsonValueKind]::False -or
            $Properties.task_xml_sha256.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $Properties.profile_root_id.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $Properties.profile_root_path_sha256.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $Properties.registered_at.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            -not (Test-Digest $Properties.task_xml_sha256.GetString()) -or
            -not (Test-Digest $Properties.profile_root_id.GetString()) -or
            -not (Test-Digest $Properties.profile_root_path_sha256.GetString()) -or
            $Properties.registered_at.GetString() -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' -or
            $Properties.task_xml_sha256.GetString() -cne (Get-NormalizedTaskXmlSha256 $Expected.TaskXml) -or
            $Properties.profile_root_id.GetString() -cne $Expected.ProfileRootId -or
            $Properties.profile_root_path_sha256.GetString() -cne (Get-Sha256Utf8Text $Expected.FinalPath.ToUpperInvariant())) {
            throw "invalid_profile_task_registration"
        }
        return [pscustomobject]@{ TargetSid = $Expected.TargetSid; ProfileRootId = $Expected.ProfileRootId
            ProfilePath = $Expected.ProfilePath; FinalPath = $Expected.FinalPath; TaskXml = $Expected.TaskXml }
    } finally { $Document.Dispose() }
}

function Get-VerifiedProfileTaskRegistration([string]$TargetSid, [string]$ProgramData, [string]$PowerShellPath,
    [switch]$Disabled) {
    $RootEvidence = Get-TargetProfileRootEvidence $TargetSid
    $ReceiptPath = Join-Path $RootEvidence.FinalPath "AppData\Local\Roundhouse\profile-task-registration.json"
    if (-not [IO.File]::Exists($ReceiptPath)) { throw "profile_task_registration_required" }
    try { Assert-ProfileReceiptPath $RootEvidence.FinalPath $ReceiptPath }
    catch [System.UnauthorizedAccessException] { throw "unsupported_context" }
    catch [System.IO.IOException] { throw "unsupported_context" }
    catch { throw "profile_task_registration_drift" }
    try { $ReceiptBytes = Read-HeldBytes $ReceiptPath 16384 }
    catch [System.UnauthorizedAccessException] { throw "unsupported_context" }
    catch [System.IO.IOException] { throw "unsupported_context" }
    catch [System.Security.Cryptography.CryptographicException] { throw "unsupported_context" }
    catch { throw "unsupported_context" }
    try {
        $TaskXml = Export-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction Stop
        Assert-TaskContract $TaskXml "profile" $TargetSid $ProgramData $PowerShellPath -Disabled:$Disabled
    } catch { throw "profile_task_registration_drift" }
    $CurrentRootEvidence = Get-TargetProfileRootEvidence $TargetSid
    Assert-ProfileRootEvidenceMatch $RootEvidence $CurrentRootEvidence
    try {
        $ReceiptTaskXml = if ($Disabled) { Get-ProfileTaskXml $TargetSid $ProgramData $PowerShellPath }
            else { $TaskXml }
        return Read-ProfileTaskRegistrationReceipt $ReceiptBytes ([pscustomobject]@{
                TargetSid = $TargetSid; ProfileRootId = $CurrentRootEvidence.ProfileRootId
                ProfilePath = $CurrentRootEvidence.ProfilePath; FinalPath = $CurrentRootEvidence.FinalPath
                TaskXml = $ReceiptTaskXml })
    } catch { throw "profile_task_registration_drift" }
}

function Read-ProfileConstraintRecords([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 4194304 "constraints"
    $Header = $Lines[0].Split('|')
    if ($Lines.Count -lt 1 -or $Header.Count -ne 4 -or $Header[0] -cne "constraints" -or $Header[1] -cne "1" -or
        $Header[2] -notmatch '^generation=[1-9][0-9]{0,9}$' -or $Header[3] -notmatch '^policy-sha256=[0-9a-f]{64}$') {
        throw "invalid_profile_constraints"
    }
    $Records = New-Object Collections.Generic.List[object]
    foreach ($Line in @($Lines | Select-Object -Skip 1)) {
        if (-not $Line.StartsWith("profile|", [StringComparison]::Ordinal)) { continue }
        $Parts = $Line.Split('|')
        if ($Parts.Count -ne 9 -or -not (Test-Atom $Parts[1]) -or
            $Parts[2] -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
            @($Parts[3..5] | Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
            $Parts[6] -cnotin @("managed-only", "managed-and-prune") -or -not (Test-UInt $Parts[7]) -or
            -not (Test-UInt $Parts[8])) { throw "invalid_profile_constraints" }
        [void]$Records.Add([pscustomobject]@{ Token = $Parts[1]; TargetSid = $Parts[2];
            ProfileRootId = $Parts[3]; EntryMapSha256 = $Parts[4]; MarketplaceSetSha256 = $Parts[5] })
    }
    return $Records.ToArray()
}

function Assert-ProfileReleaseArtifactCompleteness([object]$ReleaseFiles, [byte[]]$ConstraintsBytes,
    [string]$TargetSid, [string]$ProfileRootId) {
    $ByPath = @{}
    foreach ($File in $ReleaseFiles.Files) { $ByPath[$File.Path] = $File.Sha256 }
    $Records = @(Read-ProfileConstraintRecords $ConstraintsBytes)
    foreach ($Record in $Records) {
        if ($Record.TargetSid -cne $TargetSid -or $Record.ProfileRootId -cne $ProfileRootId) {
            throw "profile_root_identity_drift"
        }
        foreach ($Binding in @(
            @("generation/profiles/entry-maps/$($Record.EntryMapSha256).map", $Record.EntryMapSha256),
            @("generation/profiles/marketplace-sets/$($Record.MarketplaceSetSha256).set", $Record.MarketplaceSetSha256))) {
            if (-not $ByPath.ContainsKey($Binding[0]) -or $ByPath[$Binding[0]] -cne $Binding[1]) {
                throw "missing_profile_release_artifact"
            }
        }
    }
    return $Records
}

function Assert-StagedProfileArtifacts([string]$GenerationRoot, [object[]]$Records, [string]$Root,
    [string]$ProtectedFileSddl, [switch]$Fixture) {
    foreach ($Record in $Records) {
        foreach ($Binding in @(
            @((Join-Path $GenerationRoot "profiles/entry-maps/$($Record.EntryMapSha256).map"), $Record.EntryMapSha256),
            @((Join-Path $GenerationRoot "profiles/marketplace-sets/$($Record.MarketplaceSetSha256).set"), $Record.MarketplaceSetSha256))) {
            if (-not [IO.File]::Exists($Binding[0])) { throw "missing_profile_release_artifact" }
            $Item = Get-Item -LiteralPath $Binding[0] -Force
            if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (Get-Sha256Bytes (Read-HeldBytes $Binding[0] 4194304)) -cne $Binding[1]) {
                throw "profile_release_artifact_drift"
            }
            if (-not $Fixture) {
                Assert-ProtectedWindowsPath $Binding[0] $Root
                Assert-PathSddl $Binding[0] $ProtectedFileSddl
            }
        }
    }
}

function Get-GenerationDigest([object]$Manifest, [string]$OpenSshIdentitySha256) {
    if (-not (Test-Digest $OpenSshIdentitySha256)) { throw "invalid_generation_digest_input" }
    return Get-Sha256Text ((@(
        "roundhouse-generation|1", "epoch|$($Manifest.Epoch)",
        "policy-sha256|$($Manifest.Fields.'policy-sha256')",
        "constraints-sha256|$($Manifest.Fields.'constraints-sha256')",
        "winget-context-sha256|$($Manifest.Fields.'winget-context-sha256')",
        "provider-lock-sha256|$($Manifest.Fields.'provider-lock-sha256')",
        "openssh-identity-sha256|$OpenSshIdentitySha256", "end-generation|") -join "`n") + "`n")
}

function Get-ConfirmationText([string]$Operation, [string]$HostName, [int]$Epoch, [string]$ManifestDigest) {
    $Verb = $Operation.ToUpperInvariant()
    return "$Verb $HostName EPOCH $Epoch $($ManifestDigest.Substring(0, 12))"
}

function New-CryptographicNonce {
    [byte[]]$Bytes = [byte[]]::new(32)
    $Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $Generator.GetBytes($Bytes) } finally { $Generator.Dispose() }
    return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes, [string]$NewFileSddl = "") {
    $Directory = Split-Path -Parent $Path; [void][IO.Directory]::CreateDirectory($Directory)
    $Temporary = Join-Path $Directory ("." + [IO.Path]::GetFileName($Path) + "." + [Guid]::NewGuid().ToString("N"))
    $ReplacementSddl = $NewFileSddl
    if ([string]::IsNullOrEmpty($ReplacementSddl) -and $IsWindows -and [IO.File]::Exists($Path)) {
        $ReplacementSddl = (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]::All)
    }
    try {
        $Stream = [IO.File]::Open($Temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
        if (-not [string]::IsNullOrEmpty($ReplacementSddl)) {
            Set-PathSddl $Temporary $ReplacementSddl
            Assert-PathSddl $Temporary $ReplacementSddl
        }
        [IO.File]::Move($Temporary, $Path, $true)
        if (-not [string]::IsNullOrEmpty($ReplacementSddl)) { Assert-PathSddl $Path $ReplacementSddl }
    } finally { if ([IO.File]::Exists($Temporary)) { [IO.File]::Delete($Temporary) } }
}

function Write-AtomicAscii([string]$Path, [string[]]$Lines) { Write-AtomicBytes $Path (ConvertTo-CanonicalAsciiBytes $Lines) }

function Write-Transaction([string]$Path, [string]$Id, [string]$Operation, [string]$Phase,
    [int]$Epoch, [string]$PriorPointerSha256) {
    if ($Id -cnotmatch '^transaction-[0-9a-f]{32}$' -or $Epoch -lt 1 -or
        $Operation -cnotin @("install", "revoke", "activate") -or
        $Phase -cnotin @("intent", "snapshotted", "prepared", "mutating", "activated", "committed", "rolled-back") -or
        -not (Test-TransactionPhaseAllowed $Operation $Phase) -or
        ($PriorPointerSha256 -cne "-" -and -not (Test-Digest $PriorPointerSha256))) { throw "invalid_transaction" }
    Write-AtomicAscii $Path @(
        "windows-enrollment-transaction|1", "transaction-id|$Id", "operation|$Operation", "phase|$Phase",
        "epoch|$Epoch", "prior-pointer-sha256|$PriorPointerSha256", "end-transaction|")
}

function Test-TransactionPhaseAllowed([string]$Operation, [string]$Phase) {
    switch -CaseSensitive ($Operation) {
        "install" { return $Phase -cin @("intent", "snapshotted", "prepared", "mutating", "activated", "committed", "rolled-back") }
        "revoke" { return $Phase -cin @("intent", "snapshotted", "mutating", "committed", "rolled-back") }
        "activate" { return $Phase -cin @("intent", "snapshotted", "committed", "rolled-back") }
        default { return $false }
    }
}

function Read-Transaction([string]$Path) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 4096 "transaction") `
        @("transaction-id", "operation", "phase", "epoch", "prior-pointer-sha256") `
        "windows-enrollment-transaction|1" "end-transaction|" "transaction"
    if ($Fields.'transaction-id' -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        $Fields.operation -cnotin @("install", "revoke", "activate") -or
        $Fields.phase -cnotin @("intent", "snapshotted", "prepared", "mutating", "activated", "committed", "rolled-back") -or
        -not (Test-TransactionPhaseAllowed $Fields.operation $Fields.phase) -or
        -not (Test-UInt $Fields.epoch) -or [long]$Fields.epoch -lt 1 -or
        ($Fields.'prior-pointer-sha256' -cne "-" -and -not (Test-Digest $Fields.'prior-pointer-sha256'))) {
        throw "invalid_transaction"
    }
    return $Fields
}

function Read-DrainMarker([string]$Path) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($Path)) 1024 "drain_marker") `
        @("operation", "transaction-id", "epoch", "state") `
        "windows-broker-drain|1" "end-drain|" "drain_marker"
    if ($Fields.operation -cnotin @("install", "revoke") -or
        $Fields.'transaction-id' -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        -not (Test-UInt $Fields.epoch) -or $Fields.state -cne "draining") {
        throw "invalid_drain_marker"
    }
    return $Fields
}

function Write-DrainMarker([string]$Path, [string]$Operation, [string]$TransactionId, [int]$Epoch) {
    if ($Operation -cnotin @("install", "revoke") -or $TransactionId -cnotmatch '^transaction-[0-9a-f]{32}$' -or
        $Epoch -lt 1) { throw "invalid_drain_marker" }
    Write-AtomicAscii $Path @(
        "windows-broker-drain|1", "operation|$Operation", "transaction-id|$TransactionId",
        "epoch|$Epoch", "state|draining", "end-drain|")
}

function Get-MissingLifecycleTransactionAction([bool]$DrainPresent) {
    if ($DrainPresent) { return "recovery-required" }
    return "none"
}

function Test-LifecycleDrainBinding([object]$Transaction, [object]$Drain) {
    if ($null -eq $Transaction -or $null -eq $Drain -or $Transaction.operation -ceq "activate") { return $false }
    return $Drain.'transaction-id' -ceq $Transaction.'transaction-id' -and
        $Drain.operation -ceq $Transaction.operation -and $Drain.epoch -ceq $Transaction.epoch
}

function Assert-LifecycleQuiescenceBinding([string]$TransactionPath, [string]$DrainPath,
    [object]$ExpectedTransaction) {
    $ObservedTransaction = Read-Transaction $TransactionPath
    foreach ($Field in @("transaction-id", "operation", "phase", "epoch", "prior-pointer-sha256")) {
        if ($ObservedTransaction[$Field] -cne $ExpectedTransaction[$Field]) {
            throw "lifecycle_quiescence_binding_drift"
        }
    }
    if (-not [IO.File]::Exists($DrainPath)) { throw "lifecycle_quiescence_binding_drift" }
    $ObservedDrain = Read-DrainMarker $DrainPath
    if (-not (Test-LifecycleDrainBinding $ObservedTransaction $ObservedDrain)) {
        throw "lifecycle_quiescence_binding_drift"
    }
}

function Acquire-LifecycleLock([string]$Path, [int]$TimeoutMilliseconds = 3600000) {
    $Deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        try {
            return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $Deadline) { throw "broker_drain_timeout" }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Assert-ProtectedJournalsTerminal([string]$ReplayRoot, [string]$AuditRoot) {
    if (-not [IO.Directory]::Exists($ReplayRoot)) { return }
    foreach ($ClaimRoot in @([IO.Directory]::EnumerateDirectories($ReplayRoot, "request-*"))) {
        $JournalPath = Join-Path $ClaimRoot "journal"
        if (-not [IO.File]::Exists($JournalPath)) { throw "unresolved_protected_journal" }
        $JournalBytes = Read-HeldBytes $JournalPath 65536
        $Lines = ConvertFrom-CanonicalAsciiBytes $JournalBytes 65536 "journal"
        $States = @($Lines | Where-Object { $_ -cmatch '^state\|(validating|executing|verifying|completed|partial|rejected|stale)$' })
        if ($States.Count -ne 1 -or $States[0].Substring(6) -cnotin @("completed", "partial", "rejected", "stale")) {
            throw "unresolved_protected_journal"
        }
        $RequestId = [IO.Path]::GetFileName($ClaimRoot)
        $TerminalPath = Join-Path $AuditRoot ($RequestId + ".terminal")
        $AuditPath = Join-Path $AuditRoot ($RequestId + ".audit")
        $AuditReservePath = Join-Path $AuditRoot ($RequestId + ".audit.reserve")
        if (-not [IO.File]::Exists($TerminalPath) -or -not [IO.File]::Exists($AuditPath) -or
            -not [IO.File]::Exists($AuditReservePath)) {
            throw "unresolved_protected_audit"
        }
        $TerminalItem = Get-Item -LiteralPath $TerminalPath -Force
        $Disallowed = [IO.FileAttributes]::SparseFile -bor [IO.FileAttributes]::Compressed
        $TerminalBytes = Read-HeldBytes $TerminalPath $script:TerminalReservationBytes
        if ($TerminalBytes.Count -ne $script:TerminalReservationBytes -or
            ($TerminalItem.Attributes -band $Disallowed) -ne 0) {
            throw "unresolved_protected_audit"
        }
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
        $ReserveItem = Get-Item -LiteralPath $AuditReservePath -Force
        if ($ExpectedReserveLength -lt 0 -or $ReserveItem.Length -ne $ExpectedReserveLength -or
            ($ReserveItem.Attributes -band $Disallowed) -ne 0) { throw "unresolved_protected_audit" }
        if ($ExpectedReserveLength -gt 0) {
            foreach ($Byte in (Read-HeldBytes $AuditReservePath $script:AuditReservationBytes)) {
                if ($Byte -ne $script:ReservationFillByte) { throw "unresolved_protected_audit" }
            }
        }
    }
}

function Copy-VerifiedFile([string]$Source, [string]$Destination, [string]$ExpectedDigest) {
    $Item = Get-Item -LiteralPath $Source -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $Item.PSIsContainer) { throw "release_file_link" }
    $SourceStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        if ($SourceStream.Length -gt 268435456) { throw "release_file_too_large" }
        [byte[]]$Bytes = [byte[]]::new([int]$SourceStream.Length)
        $Offset = 0
        while ($Offset -lt $Bytes.Count) {
            $Read = $SourceStream.Read($Bytes, $Offset, $Bytes.Count - $Offset)
            if ($Read -eq 0) { throw "release_file_truncated" }
            $Offset += $Read
        }
        if ((Get-Sha256Bytes $Bytes) -cne $ExpectedDigest) { throw "release_file_digest_mismatch" }
        Write-AtomicBytes $Destination $Bytes
        $DestinationStream = [IO.File]::Open($Destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            [byte[]]$Copied = [byte[]]::new([int]$DestinationStream.Length)
            $Offset = 0
            while ($Offset -lt $Copied.Count) {
                $Read = $DestinationStream.Read($Copied, $Offset, $Copied.Count - $Offset)
                if ($Read -eq 0) { throw "protected_copy_truncated" }
                $Offset += $Read
            }
            if ((Get-Sha256Bytes $Copied) -cne $ExpectedDigest) { throw "protected_copy_mismatch" }
        } finally { $DestinationStream.Dispose() }
    } finally { $SourceStream.Dispose() }
}

function Assert-ProtectedWindowsPath([string]$Path, [string]$Boundary) {
    $Current = [IO.Path]::GetFullPath($Path)
    $Stop = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    while ($true) {
        $Item = Get-Item -LiteralPath $Current -Force
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "protected_path_reparse" }
        if (-not $script:SelfTestFixture) {
            $Acl = Get-Acl -LiteralPath $Current
            if ([string]$Acl.Owner -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
                throw "protected_path_owner_drift"
            }
            foreach ($Rule in $Acl.Access) {
                if ($Rule.AccessControlType -eq "Allow" -and
                    ($Rule.FileSystemRights -band ([Security.AccessControl.FileSystemRights]::Write -bor
                        [Security.AccessControl.FileSystemRights]::Modify -bor
                        [Security.AccessControl.FileSystemRights]::FullControl -bor
                        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                        [Security.AccessControl.FileSystemRights]::TakeOwnership)) -ne 0 -and
                    [string]$Rule.IdentityReference -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
                    throw "protected_path_acl_drift"
                }
            }
        }
        if ($Current.TrimEnd('\') -ceq $Stop) { break }
        $Parent = [IO.Directory]::GetParent($Current)
        if ($null -eq $Parent -or -not $Current.StartsWith($Stop, [StringComparison]::OrdinalIgnoreCase)) {
            throw "protected_path_boundary_drift"
        }
        $Current = $Parent.FullName
    }
}

function Read-HeldBytes([string]$Path, [int]$MaximumBytes) {
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        if ($Stream.Length -gt $MaximumBytes) { throw "bounded_input_exceeded" }
        [byte[]]$Bytes = [byte[]]::new([int]$Stream.Length)
        $Offset = 0
        while ($Offset -lt $Bytes.Count) {
            $Read = $Stream.Read($Bytes, $Offset, $Bytes.Count - $Offset)
            if ($Read -eq 0) { throw "truncated_input" }
            $Offset += $Read
        }
        return $Bytes
    } finally { $Stream.Dispose() }
}

function Get-AclBlueprint([string]$RequestSid, [string]$TargetProfileSid = "S-1-5-18") {
    if ($RequestSid -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        $TargetProfileSid -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$') { throw "invalid_request_sid" }
    return [pscustomobject]@{
        RequestSid = $RequestSid
        ProtectedDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        ProtectedFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)"
        ProtectedTraverseDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$TargetProfileSid)"
        ProfileWorkerFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;$TargetProfileSid)"
        ChrootDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x001200a0;;;$RequestSid)"
        SlotDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x001200a0;;;$RequestSid)"
        SlotFile = "O:${RequestSid}G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;$RequestSid)"
        ResultsDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x001200a0;;;$RequestSid)"
        ResultFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00120089;;;$RequestSid)"
        PublicDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)"
        Task = $script:TaskSddl
        InheritanceProtected = $true
        OwnerRightsSid = "S-1-3-4"
    }
}

function Get-ChrootProjectionPaths([string]$Root, [string]$PublicRoot) {
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

function Assert-ExactDirectoryEntries([string]$Path, [string[]]$ExpectedNames,
        [switch]$AllowMissingExpected) {
    if (-not [IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) {
        throw "projection_directory_type_drift"
    }
    $Observed = @([IO.Directory]::EnumerateFileSystemEntries(
        $Path, "*", [IO.SearchOption]::TopDirectoryOnly) | ForEach-Object { [IO.Path]::GetFileName($_) })
    if (@($Observed | Where-Object { $_ -cnotin $ExpectedNames }).Count -ne 0 -or
        (-not $AllowMissingExpected -and
            @(Compare-Object @($ExpectedNames | Sort-Object) @($Observed | Sort-Object) -CaseSensitive).Count -ne 0)) {
        throw "projection_unknown_entry"
    }
}

function Assert-PhysicalProjectionDirectory([string]$Path, [string]$Boundary,
        [string]$ExpectedSddl = "") {
    if (-not [IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) {
        throw "projection_directory_type_drift"
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "projection_directory_reparse"
    }
    if ($IsWindows) {
        Assert-ProtectedWindowsPath $Path $Boundary
        if (-not [string]::IsNullOrEmpty($ExpectedSddl)) { Assert-PathSddl $Path $ExpectedSddl }
    }
}

function Assert-PhysicalProjectionFile([string]$Path, [string]$Boundary, [long]$MaximumBytes,
        [string]$ExpectedSddl = "") {
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        throw "projection_file_type_drift"
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0 -or
        $Item.Length -lt 0 -or $Item.Length -gt $MaximumBytes) { throw "projection_file_type_drift" }
    if ($IsWindows) {
        Initialize-EnrollmentProfileRootType
        [RoundhouseEnrollmentProfileRoot]::AssertSingleLinkRegularFile($Path, $Path)
        if (-not [string]::IsNullOrEmpty($ExpectedSddl)) { Assert-PathSddl $Path $ExpectedSddl }
    }
}

function Assert-SanitizedProjectionResult([string]$Path, [string]$ExpectedRequestId) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path 4096) 4096 `
        "projection_result") @("state", "reason", "request-id", "plan-id", "action-id",
        "enrollment-epoch", "protected-result-sha256") "windows-broker-public|1" "end-public|" `
        "projection_result"
    if ($ExpectedRequestId -cnotmatch '^request-[0-9a-f]{32}$' -or
        $Fields.'request-id' -cne $ExpectedRequestId -or
        $Fields.state -cnotmatch '^[a-z][a-z0-9_-]{0,31}$' -or
        $Fields.reason -cnotmatch '^[a-z][a-z0-9_]{0,127}$' -or
        -not (Test-UInt $Fields.'enrollment-epoch') -or
        -not (Test-Digest $Fields.'protected-result-sha256')) {
        throw "projection_result_drift"
    }
}

function Assert-FixedSlotProjection([string]$SlotRoot, [string]$Boundary, [object]$Acl,
        [switch]$AllowPartial, [switch]$Legacy) {
    $Names = [string[]]@("request", "request.sig", "payload", "commit")
    Assert-PhysicalProjectionDirectory $SlotRoot $Boundary `
        $(if ($Legacy) {
            "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$($Acl.RequestSid))"
        } else { $Acl.SlotDirectory })
    Assert-ExactDirectoryEntries $SlotRoot $Names -AllowMissingExpected:$AllowPartial
    $MaximumByName = @{ request = 16384L; 'request.sig' = 16384L; payload = 67108864L; commit = 2048L }
    foreach ($Name in $Names) {
        $Path = Join-Path $SlotRoot $Name
        if ($AllowPartial -and -not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { continue }
        $ExpectedSddl = if ($Legacy) {
            "O:$($Acl.RequestSid)G:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100116;;;$($Acl.RequestSid))(A;;0x00100116;;;OW)"
        } else { $Acl.SlotFile }
        Assert-PhysicalProjectionFile $Path $Boundary $MaximumByName[$Name] $ExpectedSddl
    }
}

function Assert-ResultsProjection([string]$ResultsRoot, [string]$Boundary, [object]$Acl,
        [switch]$AllowPartial, [switch]$Legacy) {
    Assert-PhysicalProjectionDirectory $ResultsRoot $Boundary $(if ($Legacy) { $Acl.PublicDirectory } else {
        $Acl.ResultsDirectory })
    foreach ($Entry in @([IO.Directory]::EnumerateFileSystemEntries(
            $ResultsRoot, "*", [IO.SearchOption]::TopDirectoryOnly))) {
        $Name = [IO.Path]::GetFileName($Entry)
        if ($Name -cnotmatch '^(request-[0-9a-f]{32})\.result$') { throw "projection_unknown_entry" }
        Assert-PhysicalProjectionFile $Entry $Boundary 4096 $(if ($Legacy) { "" } else { $Acl.ResultFile })
        if ($Legacy -and $IsWindows) { Assert-ProtectedWindowsPath $Entry $Boundary }
        Assert-SanitizedProjectionResult $Entry $Matches[1]
    }
}

function Assert-ChrootProjection([string]$Root, [string]$PublicRoot, [object]$Acl,
        [switch]$RequireLegacyAbsent) {
    $Paths = Get-ChrootProjectionPaths $Root $PublicRoot
    Assert-PhysicalProjectionDirectory $Paths.Chroot $Root $Acl.ChrootDirectory
    Assert-ExactDirectoryEntries $Paths.Chroot @("ingress", "results")
    Assert-PhysicalProjectionDirectory $Paths.Ingress $Root $Acl.ChrootDirectory
    Assert-ExactDirectoryEntries $Paths.Ingress @("slot")
    Assert-FixedSlotProjection $Paths.Slot $Root $Acl
    Assert-ResultsProjection $Paths.Results $Root $Acl
    if ($RequireLegacyAbsent -and
        ([IO.Directory]::Exists($Paths.LegacyIngress) -or [IO.File]::Exists($Paths.LegacyIngress) -or
         [IO.Directory]::Exists($Paths.LegacyResults) -or [IO.File]::Exists($Paths.LegacyResults))) {
        throw "legacy_projection_still_live"
    }
}

function Copy-ProjectionFileExact([string]$Source, [string]$Destination, [long]$MaximumBytes) {
    [byte[]]$Bytes = Read-HeldBytes $Source $MaximumBytes
    [IO.File]::WriteAllBytes($Destination, $Bytes)
    if ((Get-Sha256Bytes (Read-HeldBytes $Destination $MaximumBytes)) -cne (Get-Sha256Bytes $Bytes)) {
        throw "projection_copy_drift"
    }
}

function Remove-StagedProjectionDirectory([string]$Path, [ValidateSet("ingress", "results")][string]$Kind,
        [string]$Boundary) {
    if (-not [IO.Directory]::Exists($Path) -and -not [IO.File]::Exists($Path)) { return }
    if ([IO.File]::Exists($Path)) { throw "projection_restore_type_drift" }
    Assert-PhysicalProjectionDirectory $Path $Boundary
    if ($Kind -ceq "ingress") {
        Assert-ExactDirectoryEntries $Path @("slot") -AllowMissingExpected
        $Slot = Join-Path $Path "slot"
        if ([IO.File]::Exists($Slot)) { throw "projection_restore_type_drift" }
        if ([IO.Directory]::Exists($Slot)) {
            Assert-PhysicalProjectionDirectory $Slot $Boundary
            Assert-ExactDirectoryEntries $Slot @("request", "request.sig", "payload", "commit") -AllowMissingExpected
            foreach ($File in @([IO.Directory]::EnumerateFiles($Slot, "*", [IO.SearchOption]::TopDirectoryOnly))) {
                Assert-PhysicalProjectionFile $File $Boundary 67108864
            }
            if (@([IO.Directory]::EnumerateDirectories($Slot, "*", [IO.SearchOption]::TopDirectoryOnly)).Count -ne 0) {
                throw "projection_restore_type_drift"
            }
        }
    } else {
        foreach ($Entry in @([IO.Directory]::EnumerateFileSystemEntries(
                $Path, "*", [IO.SearchOption]::TopDirectoryOnly))) {
            if ([IO.Path]::GetFileName($Entry) -cnotmatch '^request-[0-9a-f]{32}\.result$') {
                throw "projection_unknown_entry"
            }
            Assert-PhysicalProjectionFile $Entry $Boundary 4096
        }
    }
    [IO.Directory]::Delete($Path, $true)
}

function Stage-ChrootProjection([string]$Root, [string]$PublicRoot, [string]$RollbackRoot,
        [object]$Acl) {
    $Paths = Get-ChrootProjectionPaths $Root $PublicRoot
    Assert-PhysicalProjectionDirectory $Paths.Chroot $Root
    Assert-ExactDirectoryEntries $Paths.Chroot @("ingress", "results") -AllowMissingExpected
    if (([IO.Directory]::Exists($Paths.LegacyIngress) -or [IO.File]::Exists($Paths.LegacyIngress)) -and
        ([IO.Directory]::Exists($Paths.Ingress) -or [IO.File]::Exists($Paths.Ingress))) {
        throw "projection_layout_collision"
    }
    if (([IO.Directory]::Exists($Paths.LegacyResults) -or [IO.File]::Exists($Paths.LegacyResults)) -and
        ([IO.Directory]::Exists($Paths.Results) -or [IO.File]::Exists($Paths.Results))) {
        throw "projection_layout_collision"
    }
    if ([IO.Directory]::Exists($Paths.Ingress) -or [IO.Directory]::Exists($Paths.Results)) {
        Assert-PhysicalProjectionDirectory $Paths.Chroot $Root $Acl.ChrootDirectory
    }
    if ([IO.Directory]::Exists($Paths.Ingress)) {
        Assert-PhysicalProjectionDirectory $Paths.Ingress $Root $Acl.ChrootDirectory
        Assert-ExactDirectoryEntries $Paths.Ingress @("slot")
        Assert-FixedSlotProjection $Paths.Slot $Root $Acl
    }
    if ([IO.Directory]::Exists($Paths.Results)) {
        Assert-ResultsProjection $Paths.Results $Root $Acl
    }
    $BackupRoot = Join-Path $RollbackRoot "legacy-projection"
    if ([IO.Directory]::Exists($BackupRoot) -or [IO.File]::Exists($BackupRoot)) {
        throw "projection_backup_collision"
    }
    $HadLegacy = [IO.Directory]::Exists($Paths.LegacyIngress) -or [IO.Directory]::Exists($Paths.LegacyResults)
    if ($HadLegacy) {
        [void][IO.Directory]::CreateDirectory($BackupRoot)
        Set-PathSddl $BackupRoot $Acl.ProtectedDirectory
        Assert-PathSddl $BackupRoot $Acl.ProtectedDirectory
    }
    if ([IO.Directory]::Exists($Paths.LegacyIngress)) {
        Assert-PhysicalProjectionDirectory $Paths.LegacyIngress $Root $Acl.ProtectedDirectory
        Assert-ExactDirectoryEntries $Paths.LegacyIngress @("slot")
        $LegacyAcl = [pscustomobject]@{ RequestSid = $Acl.RequestSid; SlotDirectory = ""; SlotFile = "" }
        Assert-FixedSlotProjection (Join-Path $Paths.LegacyIngress "slot") $Root $LegacyAcl -Legacy
        [IO.Directory]::Move($Paths.LegacyIngress, (Join-Path $BackupRoot "ingress"))
    } elseif ([IO.File]::Exists($Paths.LegacyIngress)) { throw "projection_layout_collision" }
    if ([IO.Directory]::Exists($Paths.LegacyResults)) {
        Assert-ResultsProjection $Paths.LegacyResults $PublicRoot $Acl -Legacy
        [IO.Directory]::Move($Paths.LegacyResults, (Join-Path $BackupRoot "results"))
    } elseif ([IO.File]::Exists($Paths.LegacyResults)) { throw "projection_layout_collision" }

    if ([IO.Directory]::Exists($BackupRoot)) {
        $ExpectedBackupNames = [Collections.Generic.List[string]]::new()
        if ([IO.Directory]::Exists((Join-Path $BackupRoot "ingress"))) { [void]$ExpectedBackupNames.Add("ingress") }
        if ([IO.Directory]::Exists((Join-Path $BackupRoot "results"))) { [void]$ExpectedBackupNames.Add("results") }
        Assert-ExactDirectoryEntries $BackupRoot $ExpectedBackupNames.ToArray()
        if ($ExpectedBackupNames.Contains("ingress")) {
            $LegacyAcl = [pscustomobject]@{ RequestSid = $Acl.RequestSid; SlotDirectory = ""; SlotFile = "" }
            Assert-PhysicalProjectionDirectory (Join-Path $BackupRoot "ingress") $Root $Acl.ProtectedDirectory
            Assert-ExactDirectoryEntries (Join-Path $BackupRoot "ingress") @("slot")
            Assert-FixedSlotProjection (Join-Path $BackupRoot "ingress/slot") $Root $LegacyAcl -Legacy
        }
        if ($ExpectedBackupNames.Contains("results")) {
            Assert-ResultsProjection (Join-Path $BackupRoot "results") $Root $Acl -Legacy
        }
    }

    if (-not [IO.Directory]::Exists($Paths.Ingress)) {
        [void][IO.Directory]::CreateDirectory($Paths.Slot)
        $BackupIngress = Join-Path $BackupRoot "ingress"
        if ([IO.Directory]::Exists($BackupIngress)) {
            foreach ($Name in @("request", "request.sig", "payload", "commit")) {
                Copy-ProjectionFileExact (Join-Path $BackupIngress "slot/$Name") (Join-Path $Paths.Slot $Name) `
                    $(if ($Name -ceq "payload") { 67108864L } elseif ($Name -ceq "commit") { 2048L } else { 16384L })
            }
        } else {
            foreach ($Name in @("request", "request.sig", "payload", "commit")) {
                [IO.File]::WriteAllBytes((Join-Path $Paths.Slot $Name), [byte[]]@())
            }
        }
    }
    if (-not [IO.Directory]::Exists($Paths.Results)) {
        [void][IO.Directory]::CreateDirectory($Paths.Results)
        $BackupResults = Join-Path $BackupRoot "results"
        if ([IO.Directory]::Exists($BackupResults)) {
            foreach ($File in @([IO.Directory]::EnumerateFiles(
                    $BackupResults, "*", [IO.SearchOption]::TopDirectoryOnly))) {
                Copy-ProjectionFileExact $File (Join-Path $Paths.Results ([IO.Path]::GetFileName($File))) 4096
            }
        }
    }
    foreach ($Directory in @($Paths.Chroot, $Paths.Ingress)) { Set-PathSddl $Directory $Acl.ChrootDirectory }
    Set-PathSddl $Paths.Slot $Acl.SlotDirectory
    foreach ($Name in @("request", "request.sig", "payload", "commit")) {
        Set-PathSddl (Join-Path $Paths.Slot $Name) $Acl.SlotFile
    }
    Set-PathSddl $Paths.Results $Acl.ResultsDirectory
    foreach ($File in @([IO.Directory]::EnumerateFiles($Paths.Results, "*", [IO.SearchOption]::TopDirectoryOnly))) {
        Set-PathSddl $File $Acl.ResultFile
    }
    Assert-ChrootProjection $Root $PublicRoot $Acl -RequireLegacyAbsent
}

function Get-ChrootProjectionRollbackPairs([object]$Paths, [string]$Root, [string]$PublicRoot,
        [string]$BackupRoot) {
    return @(
        [pscustomobject]@{ LegacyLabel = "ingress"; NestedLabel = "chroot-ingress";
            Source = $Paths.LegacyIngress; Destination = $Paths.Ingress; Backup = (Join-Path $BackupRoot "ingress");
            Kind = "ingress"; NestedBoundary = $Root; LegacySourceBoundary = $Root; BackupBoundary = $Root },
        [pscustomobject]@{ LegacyLabel = "public-results"; NestedLabel = "chroot-results";
            Source = $Paths.LegacyResults; Destination = $Paths.Results; Backup = (Join-Path $BackupRoot "results");
            Kind = "results"; NestedBoundary = $Root; LegacySourceBoundary = $PublicRoot; BackupBoundary = $Root }
    )
}

function Restore-ChrootProjectionMigration([object]$DirectorySnapshot, [string]$Root,
        [string]$PublicRoot, [string]$RollbackRoot, [object]$Acl = $null,
        [switch]$RequireStagedExact) {
    $Paths = Get-ChrootProjectionPaths $Root $PublicRoot
    $BackupRoot = Join-Path $RollbackRoot "legacy-projection"
    if ($RequireStagedExact) {
        if ($null -eq $Acl) { throw "projection_restore_acl_missing" }
        Assert-ChrootProjection $Root $PublicRoot $Acl -RequireLegacyAbsent
    }
    $Pairs = Get-ChrootProjectionRollbackPairs $Paths $Root $PublicRoot $BackupRoot
    foreach ($Pair in $Pairs) {
        $PriorLegacy = $DirectorySnapshot[$Pair.LegacyLabel].State -ceq "present"
        $PriorNested = $DirectorySnapshot[$Pair.NestedLabel].State -ceq "present"
        $SourceExists = [IO.Directory]::Exists($Pair.Source)
        $BackupExists = [IO.Directory]::Exists($Pair.Backup)
        if ([IO.File]::Exists($Pair.Source) -or [IO.File]::Exists($Pair.Backup) -or
            ($SourceExists -and $BackupExists)) { throw "projection_restore_ambiguous" }
        if ($BackupExists) {
            if ($null -eq $Acl) { throw "projection_restore_acl_missing" }
            if ($Pair.Kind -ceq "ingress") {
                $LegacyAcl = [pscustomobject]@{ RequestSid = $Acl.RequestSid; SlotDirectory = ""; SlotFile = "" }
                Assert-PhysicalProjectionDirectory $Pair.Backup $Pair.BackupBoundary $Acl.ProtectedDirectory
                Assert-ExactDirectoryEntries $Pair.Backup @("slot")
                Assert-FixedSlotProjection (Join-Path $Pair.Backup "slot") $Pair.BackupBoundary $LegacyAcl -Legacy
            } else { Assert-ResultsProjection $Pair.Backup $Pair.BackupBoundary $Acl -Legacy }
        }
        if ($SourceExists) {
            if ($null -eq $Acl) { throw "projection_restore_acl_missing" }
            if ($Pair.Kind -ceq "ingress") {
                $LegacyAcl = [pscustomobject]@{ RequestSid = $Acl.RequestSid; SlotDirectory = ""; SlotFile = "" }
                Assert-PhysicalProjectionDirectory $Pair.Source $Pair.LegacySourceBoundary $Acl.ProtectedDirectory
                Assert-ExactDirectoryEntries $Pair.Source @("slot")
                Assert-FixedSlotProjection (Join-Path $Pair.Source "slot") $Pair.LegacySourceBoundary $LegacyAcl -Legacy
            } else { Assert-ResultsProjection $Pair.Source $Pair.LegacySourceBoundary $Acl -Legacy }
        }
        if ($PriorLegacy -and -not $PriorNested) {
            if (-not $SourceExists -and -not $BackupExists) { throw "projection_restore_missing" }
            if ([IO.Directory]::Exists($Pair.Destination) -or [IO.File]::Exists($Pair.Destination)) {
                Remove-StagedProjectionDirectory $Pair.Destination $Pair.Kind $Pair.NestedBoundary
            }
            if ($BackupExists) { [IO.Directory]::Move($Pair.Backup, $Pair.Source) }
        } elseif (-not $PriorLegacy -and -not $PriorNested) {
            if ($BackupExists -or $SourceExists) { throw "projection_restore_ambiguous" }
            if ([IO.Directory]::Exists($Pair.Destination) -or [IO.File]::Exists($Pair.Destination)) {
                Remove-StagedProjectionDirectory $Pair.Destination $Pair.Kind $Pair.NestedBoundary
            }
        } elseif (-not $PriorLegacy -and $PriorNested) {
            if ($BackupExists -or $SourceExists -or -not [IO.Directory]::Exists($Pair.Destination)) {
                throw "projection_restore_ambiguous"
            }
        } else {
            if ($BackupExists -or -not $SourceExists -or -not [IO.Directory]::Exists($Pair.Destination)) {
                throw "projection_restore_ambiguous"
            }
        }
    }
    if ([IO.Directory]::Exists($BackupRoot)) {
        Assert-ExactDirectoryEntries $BackupRoot @() -AllowMissingExpected
        [IO.Directory]::Delete($BackupRoot, $false)
    } elseif ([IO.File]::Exists($BackupRoot)) { throw "projection_restore_ambiguous" }
}

function Write-PublicReadiness([string]$PublicRoot, [string]$Lifecycle, [object]$Manifest,
    [string]$BrokerDigest, [string]$GenerationDigest, [string]$RequestAccountState,
    [bool]$TaskReady, [bool]$ProfileTaskReady, [bool]$NativeCanaryReady = $false,
    [string]$RequestSid = "-", [string]$ContextCanaryDigest = "-") {
    $RequestPrincipal = if ($RequestAccountState -ceq "absent") { "-" } else { $script:RequestAccountName }
    if ($Lifecycle -cnotin @("needs_human_enrollment", "needs_native_canary", "needs_transport_enrollment",
            "recovery_required", "drifted", "revoked") -or
        $RequestAccountState -cnotin @("absent", "disabled") -or
        ($RequestSid -cne "-" -and $RequestSid -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$') -or
        ($ContextCanaryDigest -cne "-" -and -not (Test-Digest $ContextCanaryDigest)) -or
        ($NativeCanaryReady -ne ($ContextCanaryDigest -cne "-")) -or
        ($Lifecycle -ceq "needs_native_canary" -and $NativeCanaryReady) -or
        ($Lifecycle -ceq "needs_transport_enrollment" -and
            (-not $NativeCanaryReady -or -not $TaskReady -or -not $ProfileTaskReady)) -or
        ($RequestAccountState -ceq "absent" -and ($RequestSid -cne "-" -or $RequestPrincipal -cne "-")) -or
        ($RequestAccountState -cne "absent" -and $RequestPrincipal -cne $script:RequestAccountName)) {
        throw "invalid_public_readiness"
    }
    $Epoch = if ($null -eq $Manifest) { "-" } else { [string]$Manifest.Epoch }
    $PolicyDigest = if ($null -eq $Manifest) { "-" } else { [string]$Manifest.Fields.'policy-sha256' }
    $ConstraintsDigest = if ($null -eq $Manifest) { "-" } else { [string]$Manifest.Fields.'constraints-sha256' }
    $WinGetContextDigest = if ($null -eq $Manifest) { "-" } else {
        [string]$Manifest.Fields.'winget-context-sha256'
    }
    # Static lifecycle output was an unauthenticated snapshot and is deliberately
    # retired.  Fresh readiness is available only through signed broker.readiness.v1
    # requests on the fixed SFTP slot; clear a legacy snapshot on every lifecycle pass.
    $ReadinessPath = Join-Path $PublicRoot "readiness"
    if ([IO.File]::Exists($ReadinessPath)) { [IO.File]::Delete($ReadinessPath) }
}

function Read-NativeCanaryChallenge([byte[]]$Bytes, [object]$Manifest, [string]$GenerationDigest,
    [object]$BootstrapReceipt) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "native_canary_challenge") @(
        "nonce", "host", "epoch", "generation-sha256", "runner-path-sha256", "runner-sha256",
        "runner-publisher-thumbprint", "issued-at", "expires-at", "clock-skew-bound-seconds"
    ) "windows-native-canary-challenge|1" "end-challenge|" "native_canary_challenge"
    if ($Fields.nonce -cnotmatch '^[0-9a-f]{64}$' -or $Fields.host -cne [Environment]::MachineName.ToUpperInvariant() -or
        $Fields.epoch -cne [string]$Manifest.Epoch -or $Fields.'generation-sha256' -cne $GenerationDigest -or
        $Fields.'runner-path-sha256' -cne (Get-Sha256Utf8Text $BootstrapReceipt.'native-canary-runner-path'.ToUpperInvariant()) -or
        $Fields.'runner-sha256' -cne $BootstrapReceipt.'native-canary-runner-sha256' -or
        $Fields.'runner-publisher-thumbprint' -cne $BootstrapReceipt.'native-canary-publisher-thumbprint' -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at') -or
        $Fields.'clock-skew-bound-seconds' -cne [string]$script:ClockSkewBoundSeconds) {
        throw "native_canary_challenge_drift"
    }
    [long]$IssuedAt = [long]::Parse($Fields.'issued-at', [Globalization.CultureInfo]::InvariantCulture)
    [long]$ExpiresAt = [long]::Parse($Fields.'expires-at', [Globalization.CultureInfo]::InvariantCulture)
    if ($ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 3600) { throw "native_canary_challenge_drift" }
    return [pscustomobject]@{ Fields = $Fields; Bytes = $Bytes; IssuedAt = $IssuedAt; ExpiresAt = $ExpiresAt }
}

function Test-NativeCanaryDetachedSignature([byte[]]$ReceiptBytes, [byte[]]$SignatureBytes,
    [string]$ExpectedThumbprint) {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
        $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
            [Security.Cryptography.Pkcs.ContentInfo]::new($ReceiptBytes), $true)
        $Cms.Decode($SignatureBytes); $Cms.CheckSignature($true)
        if ($Cms.SignerInfos.Count -ne 1 -or $null -eq $Cms.SignerInfos[0].Certificate) { return $false }
        return $Cms.SignerInfos[0].Certificate.Thumbprint.ToUpperInvariant() -ceq $ExpectedThumbprint
    } catch { return $false }
}

function Get-NativeCanaryPreview([object]$Challenge) {
    return (@(
        "windows-native-canary-preview|1", "host|$($Challenge.Fields.host)", "epoch|$($Challenge.Fields.epoch)",
        "generation-sha256|$($Challenge.Fields.'generation-sha256')", "nonce|$($Challenge.Fields.nonce)",
        "runner-sha256|$($Challenge.Fields.'runner-sha256')",
        "runner-publisher-thumbprint|$($Challenge.Fields.'runner-publisher-thumbprint')", "end-preview|"
    ) -join "`n") + "`n"
}

function Get-NativeCanaryConfirmation([object]$Challenge) {
    $PreviewDigest = Get-Sha256Utf8Text (Get-NativeCanaryPreview $Challenge)
    return "ACTIVATE $($Challenge.Fields.host) EPOCH $($Challenge.Fields.epoch) " +
        "$($Challenge.Fields.'generation-sha256'.Substring(0, 12)) CANARY $($PreviewDigest.Substring(0, 12))"
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
        "result-non-list", "request-no-task-rights", "claim-copy-race", "openssh-y-verify",
        "openssh-print-pubkey", "openssh-certificate-parse", "winget-system-inventory",
        "winget-corrupt-hash", "winget-dangerous-options", "profile-path-containment",
        "authoritative-result", "reboot-recovery", "raw-evidence-sha256")
}

function Get-NativeCanaryAccessContract([string]$RequestSid) {
    $Acl = Get-AclBlueprint $RequestSid
    return [pscustomobject]@{
        RequestSid = $RequestSid
        ChrootPathSha256 = Get-Sha256Utf8Text "C:\PROGRAMDATA\ROUNDHOUSE\CHROOT"
        ChrootDirectorySddlSha256 = Get-Sha256Utf8Text $Acl.ChrootDirectory
        SlotDirectorySddlSha256 = Get-Sha256Utf8Text $Acl.SlotDirectory
        SlotFileSddlSha256 = Get-Sha256Utf8Text $Acl.SlotFile
        ResultsDirectorySddlSha256 = Get-Sha256Utf8Text $Acl.ResultsDirectory
        ResultFileSddlSha256 = Get-Sha256Utf8Text $Acl.ResultFile
    }
}

function Read-NativeCanaryReceiptFields([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 16384 "native_canary") `
        (Get-NativeCanaryReceiptFieldNames) "windows-native-canary-receipt|3" "end-canary|" "native_canary"
    $Access = Get-NativeCanaryAccessContract $Fields.'request-sid'
    if ($Fields.'chroot-path-sha256' -cne $Access.ChrootPathSha256 -or
        $Fields.'chroot-directory-sddl-sha256' -cne $Access.ChrootDirectorySddlSha256 -or
        $Fields.'slot-directory-sddl-sha256' -cne $Access.SlotDirectorySddlSha256 -or
        $Fields.'slot-file-sddl-sha256' -cne $Access.SlotFileSddlSha256 -or
        $Fields.'results-directory-sddl-sha256' -cne $Access.ResultsDirectorySddlSha256 -or
        $Fields.'result-file-sddl-sha256' -cne $Access.ResultFileSddlSha256) {
        throw "native_canary_access_contract_drift"
    }
    foreach ($Name in @($Fields.Keys | Where-Object { $_ -notin @(
                "nonce", "host", "epoch", "generation-sha256", "runner-path-sha256", "runner-sha256",
                "runner-publisher-thumbprint", "issued-at", "expires-at", "human-preview-sha256",
                "human-confirmation-sha256", "clock-skew-bound-seconds", "request-sid", "chroot-path-sha256",
                "chroot-directory-sddl-sha256", "slot-directory-sddl-sha256", "slot-file-sddl-sha256",
                "results-directory-sddl-sha256", "result-file-sddl-sha256", "profile-efs-capability",
                "profile-efs-denied", "raw-evidence-sha256") })) {
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

function Read-NativeCanaryPublication([byte[]]$Bytes, [string]$ExpectedNonce,
        [byte[]]$ReceiptBytes, [byte[]]$SignatureBytes, [byte[]]$EvidenceBytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "native_canary_publication") `
        @("nonce", "receipt-sha256", "signature-sha256", "evidence-sha256") `
        "windows-native-canary-publication|1" "end-publication|" "native_canary_publication"
    if ($ExpectedNonce -cnotmatch '^[0-9a-f]{64}$' -or $Fields.nonce -cne $ExpectedNonce -or
        $Fields.'receipt-sha256' -cne (Get-Sha256Bytes $ReceiptBytes) -or
        $Fields.'signature-sha256' -cne (Get-Sha256Bytes $SignatureBytes) -or
        $Fields.'evidence-sha256' -cne (Get-Sha256Bytes $EvidenceBytes)) {
        throw "native_canary_publication_drift"
    }
    return $Fields
}

function Read-NativeCanaryConsumed([byte[]]$Bytes, [string]$ExpectedNonce,
        [string]$ExpectedReceiptSha256) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "native_canary_consumed") `
        @("nonce", "receipt-sha256") "windows-native-canary-consumed|1" "end-consumed|" `
        "native_canary_consumed"
    if ($ExpectedNonce -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Digest $ExpectedReceiptSha256) -or
        $Fields.nonce -cne $ExpectedNonce -or $Fields.'receipt-sha256' -cne $ExpectedReceiptSha256) {
        throw "native_canary_consumed_drift"
    }
    return $Fields
}

function Read-NativeCanaryReceipt([byte[]]$Bytes, [byte[]]$SignatureBytes, [byte[]]$RawEvidenceBytes,
    [object]$Manifest, [string]$GenerationDigest, [object]$Challenge, [object]$BootstrapReceipt,
    [string]$Confirmation, [string]$ExpectedRequestSid = "", [switch]$Fixture) {
    $Fields = Read-NativeCanaryReceiptFields $Bytes
    $ExpectedConfirmation = Get-NativeCanaryConfirmation $Challenge
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($Fixture -and [string]::IsNullOrEmpty($ExpectedRequestSid)) {
        $ExpectedRequestSid = $Fields.'request-sid'
    }
    if ($ExpectedRequestSid -cnotmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        $Fields.'request-sid' -cne $ExpectedRequestSid -or $Confirmation -cne $ExpectedConfirmation -or
        $Fields.nonce -cne $Challenge.Fields.nonce -or $Fields.host -cne $Challenge.Fields.host -or
        $Fields.epoch -cne [string]$Manifest.Epoch -or $Fields.'generation-sha256' -cne $GenerationDigest -or
        $Fields.'runner-path-sha256' -cne $Challenge.Fields.'runner-path-sha256' -or
        $Fields.'runner-sha256' -cne $BootstrapReceipt.'native-canary-runner-sha256' -or
        $Fields.'runner-publisher-thumbprint' -cne $BootstrapReceipt.'native-canary-publisher-thumbprint' -or
        $Fields.'human-preview-sha256' -cne (Get-Sha256Utf8Text (Get-NativeCanaryPreview $Challenge)) -or
        $Fields.'human-confirmation-sha256' -cne (Get-Sha256Utf8Text $ExpectedConfirmation) -or
        $Fields.'clock-skew-bound-seconds' -cne [string]$script:ClockSkewBoundSeconds -or
        -not (Test-UInt $Fields.'issued-at') -or -not (Test-UInt $Fields.'expires-at') -or
        [long]$Fields.'issued-at' -lt $Challenge.IssuedAt -or [long]$Fields.'expires-at' -gt $Challenge.ExpiresAt -or
        [long]$Fields.'issued-at' -gt $Now -or [long]$Fields.'expires-at' -le $Now -or
        $Fields.'raw-evidence-sha256' -cne (Get-Sha256Bytes $RawEvidenceBytes) -or
        (-not $Fixture -and -not (Test-NativeCanaryDetachedSignature $Bytes $SignatureBytes `
            $BootstrapReceipt.'native-canary-publisher-thumbprint'))) {
        throw "native_canary_provenance_invalid"
    }
    return $Fields
}

function Get-WinGetProvisionRequestBytes([object]$Manifest, [string]$GenerationDigest) {
    if (-not (Test-Digest $GenerationDigest)) { throw "invalid_winget_provision_binding" }
    return ConvertTo-CanonicalAsciiBytes @(
        "winget-provider-provision-request|1", "enrollment-epoch|$($Manifest.Epoch)",
        "generation-sha256|$GenerationDigest", "policy-sha256|$($Manifest.Fields.'policy-sha256')",
        "constraints-sha256|$($Manifest.Fields.'constraints-sha256')",
        "winget-context-sha256|$($Manifest.Fields.'winget-context-sha256')",
        "provider-lock-sha256|$($Manifest.Fields.'provider-lock-sha256')", "end-provision-request|")
}

function Get-WinGetProvisionPaths([string]$StateRoot, [int]$Epoch, [string]$GenerationDigest) {
    if ($Epoch -lt 1 -or -not (Test-Digest $GenerationDigest)) { throw "invalid_winget_provision_binding" }
    $Name = "winget-provider.e$Epoch-$GenerationDigest"
    return [pscustomobject]@{ Marker = (Join-Path $StateRoot "winget-provider.provision")
        Claim = (Join-Path $StateRoot ($Name + ".claimed")); Receipt = (Join-Path $StateRoot ($Name + ".receipt")) }
}

function Get-WinGetProvisionEvidencePathState([string]$Path, [string]$Root, [string]$ProtectedFileSddl,
    [switch]$Fixture) {
    try { $Attributes = [IO.File]::GetAttributes($Path) }
    catch [System.IO.FileNotFoundException] { return "absent" }
    catch [System.IO.DirectoryNotFoundException] { return "absent" }
    catch { throw "winget_provision_evidence_path_drift" }
    if (($Attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) {
        throw "winget_provision_evidence_path_drift"
    }
    try { $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch { throw "winget_provision_evidence_path_drift" }
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "winget_provision_evidence_path_drift"
    }
    if (-not $Fixture) {
        Assert-ProtectedWindowsPath $Path $Root
        Assert-PathSddl $Path $ProtectedFileSddl
    }
    return "file"
}

function Assert-WinGetProvisionEvidenceAbsent([object]$Paths, [string]$Root, [string]$ProtectedFileSddl,
    [switch]$Fixture) {
    foreach ($Path in @($Paths.Marker, $Paths.Claim, $Paths.Receipt)) {
        if ((Get-WinGetProvisionEvidencePathState $Path $Root $ProtectedFileSddl -Fixture:$Fixture) -ne "absent") {
            throw "winget_provider_provision_recovery_required"
        }
    }
}

function Read-WinGetProvisionContext([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 16384 "winget_provider_context"
    $Fields = Read-FixedFields $Lines @(
        "state-identifier", "source-id", "source-name", "source-type", "source-argument",
        "source-argument-sha256", "source-origin", "source-trust", "source-explicit",
        "source-last-update-min-unix", "deployment-file-set-sha256", "app-installer-identity-sha256"
    ) "winget-provider-context|1" "end-context|" "winget_provider_context"
    [long]$LastUpdate = 0
    $SourceArgument = [string]$Fields.'source-argument'
    $Uri = $null
    try { $Uri = [Uri]::new($SourceArgument, [UriKind]::Absolute) }
    catch { throw "invalid_winget_provider_context" }
    if ($Fields.'state-identifier' -cnotmatch '^roundhouse-e[1-9][0-9]{0,9}-[0-9a-f]{64}$' -or
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
        $Fields.'source-origin' -cnotin @("predefined", "user") -or $Fields.'source-trust' -cnotin @("none", "trusted") -or
        $Fields.'source-explicit' -cnotin @("true", "false") -or -not (Test-UInt $Fields.'source-last-update-min-unix') -or
        -not [long]::TryParse($Fields.'source-last-update-min-unix', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$LastUpdate) -or $LastUpdate -lt 0 -or
        -not (Test-Digest $Fields.'deployment-file-set-sha256') -or
        -not (Test-Digest $Fields.'app-installer-identity-sha256')) { throw "invalid_winget_provider_context" }
    return [pscustomobject]@{ StateIdentifier = $Fields.'state-identifier'; SourceId = $Fields.'source-id'
        SourceName = $Fields.'source-name'; SourceType = $Fields.'source-type'
        SourceArgumentSha256 = $Fields.'source-argument-sha256'; SourceOrigin = $Fields.'source-origin'
        SourceTrust = $Fields.'source-trust'; SourceExplicit = $Fields.'source-explicit'
        SourceLastUpdateMinimum = $LastUpdate; DeploymentFileSetSha256 = $Fields.'deployment-file-set-sha256'
        AppInstallerIdentitySha256 = $Fields.'app-installer-identity-sha256' }
}

function Get-WinGetProvisionSettingsSha256 {
    return Get-Sha256Utf8Text '{"$schema":"https://aka.ms/winget-settings.schema.json","source":{"autoUpdateIntervalInMinutes":0},"interactivity":{"disable":true},"installBehavior":{"skipDependencies":false,"requirements":{"scope":"machine"}},"experimentalFeatures":{"resume":false}}'
}

function Assert-WinGetProvisionSourceEvidence([string]$Line, [object]$Context, [bool]$AllowAbsent) {
    if ($Line -ceq "source|-|-|-|-|-|-|-|-") {
        if (-not $AllowAbsent) { throw "winget_provision_result_binding_mismatch" }
        return
    }
    $Parts = $Line.Split('|'); [long]$LastUpdate = 0
    if ($Parts.Count -ne 9 -or $Parts[0] -cne "source" -or -not (Test-Atom $Parts[1]) -or
        -not (Test-Atom $Parts[2]) -or -not (Test-Atom $Parts[3]) -or -not (Test-Digest $Parts[4]) -or
        -not (Test-Atom $Parts[5]) -or -not (Test-Atom $Parts[6]) -or $Parts[7] -cnotin @("true", "false") -or
        -not (Test-UInt $Parts[8]) -or -not [long]::TryParse($Parts[8], [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$LastUpdate) -or $LastUpdate -lt $Context.SourceLastUpdateMinimum -or
        $Parts[1] -cne $Context.SourceId -or $Parts[2] -cne $Context.SourceName -or
        $Parts[3] -cne $Context.SourceType -or $Parts[4] -cne $Context.SourceArgumentSha256 -or
        $Parts[5] -cne $Context.SourceOrigin -or $Parts[6] -cne $Context.SourceTrust -or
        $Parts[7] -cne $Context.SourceExplicit) { throw "winget_provision_result_binding_mismatch" }
}

function Read-WinGetProvisionReceipt([byte[]]$Bytes, [object]$Manifest, [string]$GenerationDigest,
    [object]$Context) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 1048576 "winget_provision_result"
    if ($Lines.Count -ne 14 -or $Lines[0] -cne "winget-provider-provision-result|1" -or
        $Lines[-1] -cne "end-provision-result|") { throw "invalid_winget_provision_result" }
    $Names = @(
        "state", "reason", "enrollment-epoch", "generation-sha256", "provider-lock-sha256",
        "deployment-file-set-sha256", "app-installer-identity-sha256", "provider-version",
        "state-identifier-sha256", "provider-runtime-roots-sha256", "settings-sha256"
    )
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Fields.Contains($Parts[0])) {
            throw "invalid_winget_provision_result"
        }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if ($Fields.state -cnotin @("completed", "partial", "rejected") -or -not (Test-Atom $Fields.reason) -or
        $Fields.'enrollment-epoch' -cne [string]$Manifest.Epoch) { throw "invalid_winget_provision_result" }
    foreach ($Name in @("generation-sha256", "provider-lock-sha256", "deployment-file-set-sha256",
        "app-installer-identity-sha256", "state-identifier-sha256", "provider-runtime-roots-sha256", "settings-sha256")) {
        if ($Fields[$Name] -cne "-" -and -not (Test-Digest $Fields[$Name])) { throw "invalid_winget_provision_result" }
    }
    if ($Fields.'provider-version' -cne "-" -and $Fields.'provider-version' -cne "1.29.280") {
        throw "invalid_winget_provision_result"
    }
    $Expected = [ordered]@{
        'generation-sha256' = $GenerationDigest
        'provider-lock-sha256' = $Manifest.Fields.'provider-lock-sha256'
        'deployment-file-set-sha256' = $Context.DeploymentFileSetSha256
        'app-installer-identity-sha256' = $Context.AppInstallerIdentitySha256
        'provider-version' = "1.29.280"
        'state-identifier-sha256' = Get-Sha256Utf8Text $Context.StateIdentifier
        'settings-sha256' = Get-WinGetProvisionSettingsSha256
    }
    foreach ($Name in $Expected.Keys) {
        if ($Fields[$Name] -cne "-" -and $Fields[$Name] -cne $Expected[$Name]) {
            throw "winget_provision_result_binding_mismatch"
        }
    }
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
            foreach ($Name in $Expected.Keys) {
                if ($Fields[$Name] -cne $Expected[$Name]) { throw "winget_provision_result_binding_mismatch" }
            }
            if (-not (Test-Digest $Fields.'provider-runtime-roots-sha256')) {
                throw "winget_provision_result_binding_mismatch"
            }
        } else { throw "winget_provision_result_binding_mismatch" }
    }
    Assert-WinGetProvisionSourceEvidence $Lines[12] $Context ($Fields.state -cne "completed")
    return [pscustomobject]@{ State = $Fields.state; Reason = $Fields.reason; Bytes = $Bytes }
}

function Wait-WinGetProvisionReceipt([string]$Root, [object]$Paths, [byte[]]$ExpectedClaimBytes,
    [object]$Manifest, [string]$GenerationDigest, [object]$Context, [string]$ProtectedFileSddl) {
    $Deadline = [DateTime]::UtcNow.AddSeconds($script:ProvisionPollTimeoutSeconds)
    while ($true) {
        $MarkerState = Get-WinGetProvisionEvidencePathState $Paths.Marker $Root $ProtectedFileSddl
        $ClaimState = Get-WinGetProvisionEvidencePathState $Paths.Claim $Root $ProtectedFileSddl
        $ReceiptState = Get-WinGetProvisionEvidencePathState $Paths.Receipt $Root $ProtectedFileSddl
        if ($ReceiptState -ceq "file") {
            if ($ClaimState -cne "file") { throw "winget_provision_receipt_binding_mismatch" }
            $ClaimBytes = Read-HeldBytes $Paths.Claim 2048
            if ((Get-Sha256Bytes $ClaimBytes) -cne (Get-Sha256Bytes $ExpectedClaimBytes)) {
                throw "winget_provision_marker_binding_mismatch"
            }
            return Read-WinGetProvisionReceipt (Read-HeldBytes $Paths.Receipt 1048576) $Manifest $GenerationDigest $Context
        }
        if ([DateTime]::UtcNow -ge $Deadline) {
            if ($ClaimState -ceq "file") { throw "winget_provider_provision_recovery_required" }
            throw "winget_provider_provision_timeout"
        }
        Start-Sleep -Seconds 1
    }
}

function Get-WinGetProvisionDisposition([object]$Receipt) {
    switch -CaseSensitive ($Receipt.State) {
        "completed" {
            if ($Receipt.Reason -cnotin @("module_state_verified", "provider_state_provisioned")) {
                throw "winget_provision_result_binding_mismatch"
            }
            return "continue"
        }
        "rejected" { return "rollback" }
        "partial" { return "preserve" }
        default { throw "invalid_winget_provision_result" }
    }
}

function Assert-CompletedWinGetProvision([string]$Root, [object]$Paths, [byte[]]$ExpectedClaimBytes,
    [object]$Manifest, [string]$GenerationDigest, [object]$Context, [string]$ProtectedFileSddl,
    [switch]$Fixture) {
    if ((Get-WinGetProvisionEvidencePathState $Paths.Marker $Root $ProtectedFileSddl -Fixture:$Fixture) -ne "absent" -or
        (Get-WinGetProvisionEvidencePathState $Paths.Claim $Root $ProtectedFileSddl -Fixture:$Fixture) -ne "file" -or
        (Get-WinGetProvisionEvidencePathState $Paths.Receipt $Root $ProtectedFileSddl -Fixture:$Fixture) -ne "file") {
        throw "winget_provider_provision_recovery_required"
    }
    if ((Get-Sha256Bytes (Read-HeldBytes $Paths.Claim 2048)) -cne (Get-Sha256Bytes $ExpectedClaimBytes)) {
        throw "winget_provision_marker_binding_mismatch"
    }
    $Receipt = Read-WinGetProvisionReceipt (Read-HeldBytes $Paths.Receipt 1048576) $Manifest `
        $GenerationDigest $Context
    if ((Get-WinGetProvisionDisposition $Receipt) -cne "continue") {
        throw "winget_provider_provision_recovery_required"
    }
    return $Receipt
}

function Remove-UnclaimedWinGetProvisionMarker([string]$Root, [object]$Paths, [byte[]]$ExpectedMarkerBytes,
    [string]$ProtectedFileSddl) {
    $MarkerState = Get-WinGetProvisionEvidencePathState $Paths.Marker $Root $ProtectedFileSddl
    $ClaimState = Get-WinGetProvisionEvidencePathState $Paths.Claim $Root $ProtectedFileSddl
    $ReceiptState = Get-WinGetProvisionEvidencePathState $Paths.Receipt $Root $ProtectedFileSddl
    if ($MarkerState -cne "file" -or $ClaimState -ceq "file" -or $ReceiptState -ceq "file") {
        return
    }
    if ((Get-Sha256Bytes (Read-HeldBytes $Paths.Marker 2048)) -cne (Get-Sha256Bytes $ExpectedMarkerBytes)) {
        throw "winget_provision_marker_binding_mismatch"
    }
    [IO.File]::Delete($Paths.Marker)
}

function Read-ActivePointer([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 160 "active_generation") `
        @("epoch", "generation-sha256") "roundhouse-active-generation|1" "end-generation|" "active_generation"
    if ($Fields.epoch -notmatch '^[1-9][0-9]{0,9}$' -or -not (Test-Digest $Fields.'generation-sha256')) {
        throw "invalid_active_generation"
    }
    return $Fields
}

function Assert-ElevatedHumanContext {
    if (-not $IsWindows -or -not [Environment]::UserInteractive) { throw "interactive_windows_elevation_required" }
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        if ($Identity.IsSystem) { throw "human_administrator_required" }
        $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
        if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "human_administrator_required"
        }
    } finally { $Identity.Dispose() }
}

function Set-PathSddl([string]$Path, [string]$Sddl) {
    if ($script:SelfTestFixture) { return }
    $Item = Get-Item -LiteralPath $Path -Force
    $Security = if ($Item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() }
        else { [Security.AccessControl.FileSecurity]::new() }
    $Security.SetSecurityDescriptorSddlForm($Sddl)
    Set-Acl -LiteralPath $Path -AclObject $Security
    $Observed = Get-Acl -LiteralPath $Path
    $ExpectedDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    $ObservedDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
        $Observed.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
    [byte[]]$ExpectedBytes = [byte[]]::new($ExpectedDescriptor.BinaryLength)
    [byte[]]$ObservedBytes = [byte[]]::new($ObservedDescriptor.BinaryLength)
    $ExpectedDescriptor.GetBinaryForm($ExpectedBytes, 0); $ObservedDescriptor.GetBinaryForm($ObservedBytes, 0)
    if ((Get-Sha256Bytes $ExpectedBytes) -cne (Get-Sha256Bytes $ObservedBytes)) { throw "acl_verification_failed" }
}

function Get-SystemTaskXml([string]$ProgramData, [string]$PowerShellPath) {
    $BrokerPath = $ProgramData.TrimEnd('\') + "\Roundhouse\entry\privilege-broker-windows.ps1"
    $EntryRoot = $ProgramData.TrimEnd('\') + "\Roundhouse\entry"
    $EscapedCommand = [Security.SecurityElement]::Escape($PowerShellPath)
    $EscapedBroker = [Security.SecurityElement]::Escape(
        ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "' + $BrokerPath +
        '" -Context windows-system-v1'))
    $EscapedWorking = [Security.SecurityElement]::Escape($EntryRoot)
    return '<?xml version="1.0" encoding="UTF-16"?>' +
        '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' +
        '<RegistrationInfo><URI>\RoundhouseBrokerV1</URI></RegistrationInfo>' +
        '<Triggers><TimeTrigger><StartBoundary>2000-01-01T00:00:00</StartBoundary>' +
        '<Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>' +
        '<Enabled>true</Enabled></TimeTrigger></Triggers>' +
        '<Principals><Principal id="Author"><UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType>' +
        '<RunLevel>HighestAvailable</RunLevel></Principal></Principals>' +
        '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' +
        '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' +
        '<AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>' +
        '<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><Enabled>true</Enabled><Hidden>true</Hidden>' +
        '<RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' +
        '<Priority>7</Priority></Settings><Actions Context="Author"><Exec><Command>' + $EscapedCommand +
        '</Command><Arguments>' + $EscapedBroker + '</Arguments><WorkingDirectory>' + $EscapedWorking +
        '</WorkingDirectory></Exec></Actions></Task>'
}

function Get-ProfileTaskXml([string]$TargetSid, [string]$ProgramData, [string]$PowerShellPath) {
    $WorkerPath = $ProgramData.TrimEnd('\') + "\Roundhouse\entry\profile-worker-windows.ps1"
    $EntryRoot = $ProgramData.TrimEnd('\') + "\Roundhouse\entry"
    $EscapedCommand = [Security.SecurityElement]::Escape($PowerShellPath)
    $EscapedWorker = [Security.SecurityElement]::Escape(
        ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "' + $WorkerPath +
        '" -Context windows-user-s4u-v1'))
    $EscapedWorking = [Security.SecurityElement]::Escape($EntryRoot)
    return '<?xml version="1.0" encoding="UTF-16"?>' +
        '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' +
        '<RegistrationInfo><URI>\RoundhouseProfileV1</URI></RegistrationInfo>' +
        '<Triggers />' +
        '<Principals><Principal id="Author"><UserId>' + [Security.SecurityElement]::Escape($TargetSid) +
        '</UserId><LogonType>S4U</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>' +
        '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' +
        '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' +
        '<AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>false</StartWhenAvailable>' +
        '<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><Enabled>true</Enabled><Hidden>true</Hidden>' +
        '<RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' +
        '<Priority>7</Priority></Settings><Actions Context="Author"><Exec><Command>' + $EscapedCommand +
        '</Command><Arguments>' + $EscapedWorker + '</Arguments><WorkingDirectory>' + $EscapedWorking +
        '</WorkingDirectory></Exec></Actions></Task>'
}

function Assert-TaskContract([string]$XmlText, [string]$Kind, [string]$ExpectedSid,
    [string]$ProgramData, [string]$PowerShellPath, [switch]$Disabled) {
    try { [xml]$Document = $XmlText } catch { throw "invalid_task_xml" }
    $Namespace = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Namespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
    $Context = if ($Kind -ceq "system") { "windows-system-v1" } else { "windows-user-s4u-v1" }
    $ScriptName = if ($Kind -ceq "system") { "privilege-broker-windows.ps1" } else { "profile-worker-windows.ps1" }
    $ExpectedLogon = if ($Kind -ceq "system") { "ServiceAccount" } else { "S4U" }
    $ExpectedRunLevel = if ($Kind -ceq "system") { "HighestAvailable" } else { "LeastPrivilege" }
    $ExpectedArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "' +
        ($ProgramData.TrimEnd('\') + "\Roundhouse\entry\$ScriptName") + '" -Context ' + $Context
    $Checks = [ordered]@{
        "/t:Task/t:Principals/t:Principal/t:UserId" = $ExpectedSid
        "/t:Task/t:Principals/t:Principal/t:LogonType" = $ExpectedLogon
        "/t:Task/t:Principals/t:Principal/t:RunLevel" = $ExpectedRunLevel
        "/t:Task/t:Settings/t:MultipleInstancesPolicy" = "IgnoreNew"
        "/t:Task/t:Settings/t:StartWhenAvailable" = $(if ($Kind -ceq "system") { "true" } else { "false" })
        "/t:Task/t:Settings/t:Enabled" = $(if ($Disabled) { "false" } else { "true" })
        "/t:Task/t:Settings/t:ExecutionTimeLimit" = "PT0S"
        "/t:Task/t:Actions/t:Exec/t:Command" = $PowerShellPath
        "/t:Task/t:Actions/t:Exec/t:Arguments" = $ExpectedArguments
        "/t:Task/t:Actions/t:Exec/t:WorkingDirectory" = ($ProgramData.TrimEnd('\') + "\Roundhouse\entry")
    }
    foreach ($Path in $Checks.Keys) {
        $Nodes = @($Document.SelectNodes($Path, $Namespace))
        if ($Nodes.Count -ne 1 -or [string]$Nodes[0].InnerText -cne [string]$Checks[$Path]) { throw "task_contract_drift" }
    }
    $TriggerChildren = @($Document.SelectNodes("/t:Task/t:Triggers/*", $Namespace))
    if ($Kind -ceq "system") {
        foreach ($TriggerCheck in ([ordered]@{
                "/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:Interval" = "PT1M"
                "/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:StopAtDurationEnd" = "false"
                "/t:Task/t:Triggers/t:TimeTrigger/t:Enabled" = "true" }).GetEnumerator()) {
            $Nodes = @($Document.SelectNodes($TriggerCheck.Key, $Namespace))
            if ($Nodes.Count -ne 1 -or [string]$Nodes[0].InnerText -cne $TriggerCheck.Value) {
                throw "task_contract_drift"
            }
        }
        if ($TriggerChildren.Count -ne 1) { throw "task_contract_drift" }
    } elseif ($Kind -ceq "profile") {
        if ($TriggerChildren.Count -ne 0 -or
            @($Document.SelectNodes("//t:TimeTrigger|//t:Repetition", $Namespace)).Count -ne 0) {
            throw "task_contract_drift"
        }
    } else { throw "task_contract_drift" }
    if (@($Document.SelectNodes("/t:Task/t:Triggers", $Namespace)).Count -ne 1 -or
        @($Document.SelectNodes("/t:Task/t:Actions/*", $Namespace)).Count -ne 1 -or
        $XmlText -match '(?i)(<Password>|InteractiveToken|cmd\.exe|winget\.exe|generations\\)') {
        throw "task_contract_drift"
    }
    $ExpectedXml = if ($Kind -ceq "system") { Get-SystemTaskXml $ProgramData $PowerShellPath }
        else { Get-ProfileTaskXml $ExpectedSid $ProgramData $PowerShellPath }
    if ($Disabled) { $ExpectedXml = Get-TaskXmlWithEnabledState $ExpectedXml $false }
    if ((Get-NormalizedTaskXml $XmlText) -cne (Get-NormalizedTaskXml $ExpectedXml)) {
        throw "task_contract_drift"
    }
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

function Set-RegisteredTaskSecurityDescriptor([object]$Task, [string]$Sddl, [switch]$Fixture) {
    $Task.SetSecurityDescriptor($Sddl, $script:TaskDontAddPrincipalAce)
    Assert-ExactTaskSecurityDescriptor $Sddl (Read-RegisteredTaskSecurityDescriptor $Task) -Fixture:$Fixture
}

function Set-ProtectedTaskSecurity([string]$TaskName) {
    $Service = New-Object -ComObject "Schedule.Service"
    $Service.Connect()
    $Task = $Service.GetFolder("\").GetTask("\$TaskName")
    Set-RegisteredTaskSecurityDescriptor $Task $script:TaskSddl
}

function Register-ProtectedSystemTask([string]$Xml) {
    $Service = New-Object -ComObject "Schedule.Service"
    $Service.Connect()
    $Flags = $script:TaskCreateOrUpdate -bor $script:TaskDontAddPrincipalAce
    $Task = $Service.GetFolder("\").RegisterTask($script:SystemTaskName, $Xml, $Flags,
        "S-1-5-18", $null, $script:TaskLogonServiceAccount, $null)
    if ($null -eq $Task) { throw "system_task_registration_failed" }
}

function Get-TaskSecurity([string]$TaskName) {
    $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
    $Task = $Service.GetFolder("\").GetTask("\$TaskName")
    return Read-RegisteredTaskSecurityDescriptor $Task
}

function Assert-ProtectedTaskSecurity([string]$TaskName) {
    Assert-ExactTaskSecurityDescriptor $script:TaskSddl (Get-TaskSecurity $TaskName)
}

function Get-TaskQuiescenceDisposition([string[]]$States, [bool]$DeadlineExpired) {
    foreach ($State in $States) {
        if ($State -cin @("Running", "Queued")) {
            if ($DeadlineExpired) { throw "scheduled_task_quiescence_timeout" }
            return "wait"
        }
        if ($State -cne "Disabled") { throw "scheduled_task_disable_failed" }
    }
    return "ready"
}

function Disable-BrokerTasks {
    $TaskNames = @($script:SystemTaskName, $script:ProfileTaskName)
    $Present = [Collections.Generic.List[string]]::new()
    foreach ($TaskName in $TaskNames) {
        if ($null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue)) {
            Disable-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction Stop | Out-Null
            [void]$Present.Add($TaskName)
        }
    }
    return [string[]]$Present.ToArray()
}

function Get-BrokerTaskStateObservation([string[]]$ExpectedPresent) {
    $TaskNames = @($script:SystemTaskName, $script:ProfileTaskName)
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($ExpectedTaskName in $ExpectedPresent) {
        if (-not $Seen.Add($ExpectedTaskName) -or $ExpectedTaskName -cnotin $TaskNames) {
            throw "invalid_task_quiescence_set"
        }
    }
    $States = [Collections.Generic.List[string]]::new()
    foreach ($TaskName in $TaskNames) {
        $Task = Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
        $Expected = $ExpectedPresent -ccontains $TaskName
        if (($null -ne $Task) -ne $Expected) { throw "scheduled_task_identity_drift" }
        if ($null -ne $Task) { [void]$States.Add([string]$Task.State) }
    }
    return [pscustomobject]@{ States = [string[]]$States.ToArray() }
}

function Wait-BrokerTasksQuiescent([string[]]$ExpectedPresent,
    [int]$TimeoutSeconds = $script:TaskQuiesceTimeoutSeconds) {
    if ($TimeoutSeconds -lt 1) { throw "invalid_task_quiescence_timeout" }
    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $Observation = Get-BrokerTaskStateObservation $ExpectedPresent
        $Disposition = Get-TaskQuiescenceDisposition $Observation.States `
            ([DateTimeOffset]::UtcNow -ge $Deadline)
        if ($Disposition -ceq "ready") { return }
        Start-Sleep -Milliseconds 250
    }
}

function Assert-BrokerTasksQuiescent([string[]]$ExpectedPresent) {
    $Observation = Get-BrokerTaskStateObservation $ExpectedPresent
    if ((Get-TaskQuiescenceDisposition $Observation.States $true) -cne "ready") {
        throw "scheduled_task_quiescence_drift"
    }
}

function Restore-Task([string]$TaskName, [string]$Xml, [string]$Sddl) {
    if ([string]::IsNullOrEmpty($Xml)) {
        if ($null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath "\" -Confirm:$false
        }
        return
    }
    Register-ScheduledTask -TaskName $TaskName -TaskPath "\" -Xml $Xml -Force | Out-Null
    if (-not [string]::IsNullOrEmpty($Sddl)) {
        $Service = New-Object -ComObject "Schedule.Service"; $Service.Connect()
        $Task = $Service.GetFolder("\").GetTask("\$TaskName")
        Set-RegisteredTaskSecurityDescriptor $Task $Sddl
    }
}

function Save-RollbackFile([string]$Path, [string]$RollbackRoot, [string]$Label) {
    if ([IO.File]::Exists($Path)) {
        [byte[]]$Bytes = Read-HeldBytes $Path 268435456
        $SddlBase64 = if ($IsWindows) {
            $Sddl = (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm(
                [Security.AccessControl.AccessControlSections]::All)
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sddl))
        } else { "-" }
        Write-AtomicBytes (Join-Path $RollbackRoot ($Label + ".data")) $Bytes
        Write-AtomicAscii (Join-Path $RollbackRoot ($Label + ".meta")) @(
            "rollback-file|2", "state|present", "length|$($Bytes.Count)",
            "sha256|$(Get-Sha256Bytes $Bytes)", "sddl-base64|$SddlBase64", "end-file|")
    } else {
        Write-AtomicAscii (Join-Path $RollbackRoot ($Label + ".meta")) @(
            "rollback-file|2", "state|absent", "length|0", "sha256|-", "sddl-base64|-", "end-file|")
    }
}

function Restore-RollbackFile([string]$Path, [string]$RollbackRoot, [string]$Label) {
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes((Join-Path $RollbackRoot ($Label + ".meta")))) 4096 "rollback_file"
    $Fields = Read-FixedFields $Lines @("state", "length", "sha256", "sddl-base64") `
        "rollback-file|2" "end-file|" "rollback_file"
    [int]$Length = 0
    if ($Fields.state -cnotin @("present", "absent") -or
        -not [int]::TryParse($Fields.length, [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$Length) -or $Length -lt 0 -or
        (($Fields.state -ceq "present") -ne (Test-Digest $Fields.sha256)) -or
        ($IsWindows -and $Fields.state -ceq "present" -and $Fields.'sddl-base64' -ceq "-") -or
        ($Fields.state -ceq "absent" -and ($Length -ne 0 -or $Fields.sha256 -cne "-" -or
            $Fields.'sddl-base64' -cne "-"))) { throw "rollback_metadata_drift" }
    if ($Fields.state -ceq "present") {
        [byte[]]$Bytes = [IO.File]::ReadAllBytes((Join-Path $RollbackRoot ($Label + ".data")))
        if ($Bytes.Count -ne $Length -or (Get-Sha256Bytes $Bytes) -cne $Fields.sha256) {
            throw "rollback_metadata_drift"
        }
        Write-AtomicBytes $Path $Bytes
        if ($IsWindows -and $Fields.'sddl-base64' -cne "-") {
            try { $Sddl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Fields.'sddl-base64')) }
            catch { throw "rollback_metadata_drift" }
            Set-PathSddl $Path $Sddl; Assert-PathSddl $Path $Sddl
        }
        if ((Get-Sha256Bytes (Read-HeldBytes $Path ([Math]::Max(1, $Length)))) -cne $Fields.sha256) {
            throw "rollback_restore_drift"
        }
    } else {
        if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
        if ([IO.File]::Exists($Path)) { throw "rollback_restore_drift" }
    }
}

function Get-RollbackFileState([string]$RollbackRoot, [string]$Label) {
    $MetaPath = Join-Path $RollbackRoot ($Label + ".meta")
    if (-not [IO.File]::Exists($MetaPath)) { throw "rollback_metadata_missing" }
    $Lines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($MetaPath)) 4096 "rollback_file"
    $Fields = Read-FixedFields $Lines @("state", "length", "sha256", "sddl-base64") `
        "rollback-file|2" "end-file|" "rollback_file"
    if ($Fields.state -cnotin @("present", "absent")) { throw "rollback_metadata_drift" }
    return $Fields.state
}

function Get-LifecycleRollbackLabels {
    return [string[]]@(
        "drain", "active-pointer", "entry-broker", "entry-profile", "entry-enroll", "entry-register",
        "enrollment-mutations", "public-policy", "public-constraints", "public-readiness",
        "native-canary", "native-canary-signature", "native-canary-evidence", "native-canary-challenge")
}

function Get-ActivationRollbackLabels {
    return [string[]]@("native-canary", "native-canary-signature", "native-canary-evidence", "public-readiness")
}

function Get-ActivationRollbackSetSha256([string]$RollbackRoot) {
    $Lines = New-Object Collections.Generic.List[string]
    foreach ($Label in Get-ActivationRollbackLabels) {
        $MetaPath = Join-Path $RollbackRoot ($Label + ".meta")
        if (-not [IO.File]::Exists($MetaPath)) { throw "activation_rollback_schema_drift" }
        [byte[]]$Meta = Read-HeldBytes $MetaPath 4096
        $State = Get-RollbackFileState $RollbackRoot $Label
        $DataDigest = "-"
        if ($State -ceq "present") {
            $DataPath = Join-Path $RollbackRoot ($Label + ".data")
            if (-not [IO.File]::Exists($DataPath)) { throw "activation_rollback_schema_drift" }
            $DataDigest = Get-Sha256Bytes (Read-HeldBytes $DataPath 268435456)
        }
        [void]$Lines.Add("snapshot|$Label|$(Get-Sha256Bytes $Meta)|$DataDigest")
    }
    return Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines.ToArray())
}

function Write-ActivationRecoverySnapshot([string]$Path, [string]$TransactionId, [int]$Epoch,
        [string]$PriorPointerSha256, [string]$RollbackRoot) {
    if ($TransactionId -cnotmatch '^transaction-[0-9a-f]{32}$' -or $Epoch -lt 1 -or
        -not (Test-Digest $PriorPointerSha256) -or -not [IO.Directory]::Exists($RollbackRoot)) {
        throw "activation_rollback_schema_drift"
    }
    Write-AtomicAscii $Path @(
        "windows-activation-recovery-snapshot|1", "transaction-id|$TransactionId", "epoch|$Epoch",
        "prior-pointer-sha256|$PriorPointerSha256",
        "rollback-set-sha256|$(Get-ActivationRollbackSetSha256 $RollbackRoot)",
        "end-activation-snapshot|")
}

function Read-ActivationRecoverySnapshot([string]$Path, [object]$Transaction, [string]$RollbackRoot) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path 4096) 4096 `
            "activation_snapshot") @("transaction-id", "epoch", "prior-pointer-sha256", "rollback-set-sha256") `
        "windows-activation-recovery-snapshot|1" "end-activation-snapshot|" "activation_snapshot"
    if ($Fields.'transaction-id' -cne $Transaction.'transaction-id' -or
        $Fields.epoch -cne $Transaction.epoch -or
        $Fields.'prior-pointer-sha256' -cne $Transaction.'prior-pointer-sha256' -or
        -not (Test-Digest $Fields.'rollback-set-sha256') -or
        $Fields.'rollback-set-sha256' -cne (Get-ActivationRollbackSetSha256 $RollbackRoot)) {
        throw "activation_rollback_schema_drift"
    }
    return $Fields
}

function Assert-ActivationRollbackSchema([string]$RollbackRoot) {
    if (-not [IO.Directory]::Exists($RollbackRoot) -or
        @([IO.Directory]::EnumerateDirectories($RollbackRoot, "*", [IO.SearchOption]::TopDirectoryOnly)).Count -ne 0) {
        throw "activation_rollback_schema_drift"
    }
    $ExpectedFiles = New-Object Collections.Generic.List[string]
    foreach ($Label in Get-ActivationRollbackLabels) {
        [void]$ExpectedFiles.Add($Label + ".meta")
        if ((Get-RollbackFileState $RollbackRoot $Label) -ceq "present") {
            [void]$ExpectedFiles.Add($Label + ".data")
        }
    }
    [void]$ExpectedFiles.Add("activation.snapshot")
    $ObservedFiles = @([IO.Directory]::EnumerateFiles(
        $RollbackRoot, "*", [IO.SearchOption]::TopDirectoryOnly) | ForEach-Object { [IO.Path]::GetFileName($_) })
    if (@(Compare-Object @($ExpectedFiles | Sort-Object) @($ObservedFiles | Sort-Object) -CaseSensitive).Count -ne 0) {
        throw "activation_rollback_schema_drift"
    }
}

function Get-LifecycleDirectoryBindings([string]$Root, [string]$StateRoot, [string]$PublicRoot) {
    return @(
        [pscustomobject]@{ Label = "root"; Path = $Root; Boundary = $Root },
        [pscustomobject]@{ Label = "entry"; Path = (Join-Path $Root "entry"); Boundary = $Root },
        [pscustomobject]@{ Label = "generations"; Path = (Join-Path $Root "generations"); Boundary = $Root },
        [pscustomobject]@{ Label = "chroot"; Path = (Join-Path $Root "chroot"); Boundary = $Root },
        [pscustomobject]@{ Label = "chroot-ingress"; Path = (Join-Path $Root "chroot/ingress"); Boundary = $Root },
        [pscustomobject]@{ Label = "chroot-ingress-slot"; Path = (Join-Path $Root "chroot/ingress/slot"); Boundary = $Root },
        [pscustomobject]@{ Label = "chroot-results"; Path = (Join-Path $Root "chroot/results"); Boundary = $Root },
        [pscustomobject]@{ Label = "ingress"; Path = (Join-Path $Root "ingress"); Boundary = $Root },
        [pscustomobject]@{ Label = "ingress-slot"; Path = (Join-Path $Root "ingress/slot"); Boundary = $Root },
        [pscustomobject]@{ Label = "state"; Path = $StateRoot; Boundary = $Root },
        [pscustomobject]@{ Label = "state-replay"; Path = (Join-Path $StateRoot "replay"); Boundary = $Root },
        [pscustomobject]@{ Label = "state-journal"; Path = (Join-Path $StateRoot "journal"); Boundary = $Root },
        [pscustomobject]@{ Label = "state-audit"; Path = (Join-Path $StateRoot "audit"); Boundary = $Root },
        [pscustomobject]@{ Label = "state-processing"; Path = (Join-Path $StateRoot "processing"); Boundary = $Root },
        [pscustomobject]@{ Label = "state-results"; Path = (Join-Path $StateRoot "results"); Boundary = $Root },
        [pscustomobject]@{ Label = "profile"; Path = (Join-Path $Root "profile"); Boundary = $Root },
        [pscustomobject]@{ Label = "profile-handoff"; Path = (Join-Path $Root "profile/handoff"); Boundary = $Root },
        [pscustomobject]@{ Label = "public"; Path = $PublicRoot; Boundary = $PublicRoot },
        [pscustomobject]@{ Label = "public-results"; Path = (Join-Path $PublicRoot "results"); Boundary = $PublicRoot })
}

function Write-LifecycleDirectorySnapshot([string]$Path, [string]$Root, [string]$StateRoot,
        [string]$PublicRoot) {
    $Lines = New-Object Collections.Generic.List[string]
    [void]$Lines.Add("windows-lifecycle-directory-snapshot|2")
    foreach ($Binding in Get-LifecycleDirectoryBindings $Root $StateRoot $PublicRoot) {
        $State = "absent"; $SddlBase64 = "-"
        if ([IO.File]::Exists($Binding.Path)) { throw "directory_snapshot_type_drift" }
        if ([IO.Directory]::Exists($Binding.Path)) {
            $Item = Get-Item -LiteralPath $Binding.Path -Force
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "directory_snapshot_type_drift"
            }
            $State = "present"
            if ($IsWindows) {
                $Sddl = (Get-Acl -LiteralPath $Binding.Path).GetSecurityDescriptorSddlForm(
                    [Security.AccessControl.AccessControlSections]::All)
                $SddlBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sddl))
            }
        }
        [void]$Lines.Add("directory|$($Binding.Label)|$State|$SddlBase64")
    }
    [void]$Lines.Add("end-directory-snapshot|")
    Write-AtomicAscii $Path $Lines.ToArray()
}

function Read-LifecycleDirectorySnapshot([string]$Path, [string]$Root, [string]$StateRoot,
        [string]$PublicRoot) {
    $AllBindings = @(Get-LifecycleDirectoryBindings $Root $StateRoot $PublicRoot)
    $Lines = ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path 65536) 65536 "directory_snapshot"
    $Bindings = $AllBindings
    if ($Lines[0] -ceq "windows-lifecycle-directory-snapshot|1") {
        $Bindings = @($AllBindings | Where-Object {
            $_.Label -notin @("chroot-ingress", "chroot-ingress-slot", "chroot-results") })
    } elseif ($Lines[0] -cne "windows-lifecycle-directory-snapshot|2") {
        throw "directory_snapshot_drift"
    }
    if ($Lines.Count -ne ($Bindings.Count + 2) -or $Lines[-1] -cne "end-directory-snapshot|") {
        throw "directory_snapshot_drift"
    }
    $Records = [ordered]@{}
    for ($Index = 0; $Index -lt $Bindings.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        $Binding = $Bindings[$Index]
        if ($Parts.Count -ne 4 -or $Parts[0] -cne "directory" -or
            $Parts[1] -cne $Binding.Label -or $Parts[2] -cnotin @("present", "absent") -or
            ($Parts[2] -ceq "absent" -and $Parts[3] -cne "-") -or
            ($IsWindows -and $Parts[2] -ceq "present" -and $Parts[3] -ceq "-")) {
            throw "directory_snapshot_drift"
        }
        $Sddl = "-"
        if ($Parts[3] -cne "-") {
            try {
                $Sddl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Parts[3]))
                [void][Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
            } catch { throw "directory_snapshot_drift" }
        }
        $Records[$Binding.Label] = [pscustomobject]@{
            Label = $Binding.Label; Path = $Binding.Path; Boundary = $Binding.Boundary
            State = $Parts[2]; Sddl = $Sddl
        }
    }
    foreach ($Binding in @($AllBindings | Where-Object { -not $Records.Contains($_.Label) })) {
        $Records[$Binding.Label] = [pscustomobject]@{
            Label = $Binding.Label; Path = $Binding.Path; Boundary = $Binding.Boundary
            State = "absent"; Sddl = "-"
        }
    }
    return $Records
}

function Restore-LifecycleDirectorySnapshot([object]$Records, [string]$Root) {
    $RecordList = @($Records.Values)
    foreach ($Record in @($RecordList | Where-Object { $_.State -ceq "absent" } |
            Sort-Object { $_.Path.Length } -Descending)) {
        if ([IO.File]::Exists($Record.Path)) { throw "directory_restore_type_drift" }
        if ([IO.Directory]::Exists($Record.Path)) {
            Assert-ProtectedWindowsPath $Record.Path $Record.Boundary
            if (@([IO.Directory]::EnumerateFileSystemEntries($Record.Path)).Count -ne 0) {
                throw "directory_restore_not_empty"
            }
            [IO.Directory]::Delete($Record.Path, $false)
        }
    }
    foreach ($Record in @($RecordList | Where-Object { $_.State -ceq "present" } |
            Sort-Object { $_.Path.Length } -Descending)) {
        if (-not [IO.Directory]::Exists($Record.Path) -or [IO.File]::Exists($Record.Path) -or
            $Record.Sddl -ceq "-") { throw "directory_restore_type_drift" }
        Assert-ProtectedWindowsPath $Record.Path $Record.Boundary
        Set-PathSddl $Record.Path $Record.Sddl
        Assert-PathSddl $Record.Path $Record.Sddl
    }
}

function Get-LifecycleRollbackSetSha256([string]$RollbackRoot) {
    $Lines = New-Object Collections.Generic.List[string]
    foreach ($Label in Get-LifecycleRollbackLabels) {
        $MetaPath = Join-Path $RollbackRoot ($Label + ".meta")
        if (-not [IO.File]::Exists($MetaPath)) { throw "rollback_metadata_missing" }
        [byte[]]$Meta = Read-HeldBytes $MetaPath 4096
        $State = Get-RollbackFileState $RollbackRoot $Label
        $DataDigest = "-"
        if ($State -ceq "present") {
            $DataPath = Join-Path $RollbackRoot ($Label + ".data")
            if (-not [IO.File]::Exists($DataPath)) { throw "rollback_metadata_missing" }
            $DataDigest = Get-Sha256Bytes (Read-HeldBytes $DataPath 268435456)
        }
        [void]$Lines.Add("snapshot|$Label|$(Get-Sha256Bytes $Meta)|$DataDigest")
    }
    return Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines.ToArray())
}

function Get-OptionalTextSha256([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return "-" }
    return Get-Sha256Utf8Text $Value
}

function ConvertTo-OptionalTextBase64([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return "-" }
    return [Convert]::ToBase64String($script:Utf8.GetBytes($Value))
}

function ConvertFrom-OptionalTextBase64([string]$Value, [string]$ExpectedSha256,
    [int]$MaximumBytes, [string]$Label) {
    if ($MaximumBytes -lt 1) { throw "invalid_$Label" }
    if ($ExpectedSha256 -ceq "-") {
        if ($Value -cne "-") { throw "invalid_$Label" }
        return ""
    }
    if (-not (Test-Digest $ExpectedSha256) -or $Value -ceq "-" -or
        $Value -cnotmatch '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$') {
        throw "invalid_$Label"
    }
    try { [byte[]]$Bytes = [Convert]::FromBase64String($Value) }
    catch { throw "invalid_$Label" }
    if ($Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or
        (Get-Sha256Bytes $Bytes) -cne $ExpectedSha256) { throw "invalid_$Label" }
    try { return $script:Utf8.GetString($Bytes) }
    catch { throw "invalid_$Label" }
}

function Write-LifecycleRecoverySnapshot {
    param([string]$Path, [string]$TransactionId, [string]$Operation, [int]$Epoch,
        [string]$PriorPointerSha256, [string]$RollbackRoot, [object]$PriorAccount,
        [string]$PriorSystemTaskXml, [string]$PriorSystemTaskSddl,
        [string]$PriorProfileTaskXml, [string]$PriorProfileTaskSddl,
        [string]$TargetSid, [string]$ProgramData, [bool]$GenerationWasPresent,
        [string]$DirectorySnapshotSha256)
    if (-not (Test-Digest $DirectorySnapshotSha256)) { throw "invalid_directory_snapshot_digest" }
    foreach ($TaskBinding in @(
            @($PriorSystemTaskXml, $PriorSystemTaskSddl),
            @($PriorProfileTaskXml, $PriorProfileTaskSddl))) {
        $Xml = [string]$TaskBinding[0]; $Sddl = [string]$TaskBinding[1]
        if ([string]::IsNullOrEmpty($Xml) -ne [string]::IsNullOrEmpty($Sddl) -or
            $script:Utf8.GetByteCount($Xml) -gt 32768 -or $script:Utf8.GetByteCount($Sddl) -gt 8192) {
            throw "invalid_recovery_task_snapshot"
        }
        if (-not [string]::IsNullOrEmpty($Xml)) {
            try {
                [void](Get-TaskXmlWithEnabledState $Xml $false)
                [void][Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
            } catch { throw "invalid_recovery_task_snapshot" }
        }
    }
    $AccountPresent = $null -ne $PriorAccount
    $AccountSid = if ($AccountPresent) { [string]$PriorAccount.Sid.Value } else { "-" }
    $AccountEnabled = if ($AccountPresent) { ([bool]$PriorAccount.Enabled).ToString().ToLowerInvariant() } else { "false" }
    $RequestRights = if ($AccountPresent) { @(Get-LsaAccountRights $AccountSid) } else { @() }
    $TargetRights = @(Get-LsaAccountRights $TargetSid)
    $Quota = if ($AccountPresent) { Get-QuotaSnapshot $ProgramData $script:RequestAccountName $AccountSid } else { $null }
    Write-AtomicAscii $Path @(
        "windows-lifecycle-recovery-snapshot|2", "transaction-id|$TransactionId", "operation|$Operation",
        "epoch|$Epoch", "prior-pointer-sha256|$PriorPointerSha256",
        "rollback-set-sha256|$(Get-LifecycleRollbackSetSha256 $RollbackRoot)",
        "directory-snapshot-sha256|$DirectorySnapshotSha256",
        "account-present|$($AccountPresent.ToString().ToLowerInvariant())", "account-enabled|$AccountEnabled",
        "account-sid|$AccountSid", "request-rights-sha256|$(Get-Sha256Utf8Text ((@($RequestRights | Sort-Object) -join "`n") + "`n"))",
        "target-sid|$TargetSid", "target-rights-sha256|$(Get-Sha256Utf8Text ((@($TargetRights | Sort-Object) -join "`n") + "`n"))",
        "quota-volume|$(if ($null -eq $Quota) { "-" } else { $Quota.Volume })",
        "quota-state|$(if ($null -eq $Quota) { "-" } else { $Quota.State })",
        "quota-entry|$(if ($null -eq $Quota) { "-" } else { $Quota.Entry })",
        "quota-threshold|$(if ($null -eq $Quota) { "-" } else { $Quota.Threshold })",
        "quota-limit|$(if ($null -eq $Quota) { "-" } else { $Quota.Limit })",
        "system-task-xml-sha256|$(Get-OptionalTextSha256 $PriorSystemTaskXml)",
        "system-task-xml-base64|$(ConvertTo-OptionalTextBase64 $PriorSystemTaskXml)",
        "system-task-sddl-sha256|$(Get-OptionalTextSha256 $PriorSystemTaskSddl)",
        "system-task-sddl-base64|$(ConvertTo-OptionalTextBase64 $PriorSystemTaskSddl)",
        "profile-task-xml-sha256|$(Get-OptionalTextSha256 $PriorProfileTaskXml)",
        "profile-task-xml-base64|$(ConvertTo-OptionalTextBase64 $PriorProfileTaskXml)",
        "profile-task-sddl-sha256|$(Get-OptionalTextSha256 $PriorProfileTaskSddl)",
        "profile-task-sddl-base64|$(ConvertTo-OptionalTextBase64 $PriorProfileTaskSddl)",
        "generation-was-present|$($GenerationWasPresent.ToString().ToLowerInvariant())", "end-recovery-snapshot|")
}

function Read-LifecycleRecoverySnapshot([string]$Path, [object]$Transaction, [string]$RollbackRoot) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path 65536) 65536 "recovery_snapshot") @(
        "transaction-id", "operation", "epoch", "prior-pointer-sha256", "rollback-set-sha256",
        "directory-snapshot-sha256",
        "account-present", "account-enabled", "account-sid", "request-rights-sha256", "target-sid",
        "target-rights-sha256", "quota-volume", "quota-state", "quota-entry", "quota-threshold", "quota-limit",
        "system-task-xml-sha256", "system-task-xml-base64", "system-task-sddl-sha256",
        "system-task-sddl-base64", "profile-task-xml-sha256", "profile-task-xml-base64",
        "profile-task-sddl-sha256", "profile-task-sddl-base64", "generation-was-present") `
        "windows-lifecycle-recovery-snapshot|2" "end-recovery-snapshot|" "recovery_snapshot"
    if ($Fields.'transaction-id' -cne $Transaction.'transaction-id' -or
        $Fields.operation -cne $Transaction.operation -or $Fields.epoch -cne $Transaction.epoch -or
        $Fields.'prior-pointer-sha256' -cne $Transaction.'prior-pointer-sha256' -or
        -not (Test-Digest $Fields.'rollback-set-sha256') -or
        $Fields.'rollback-set-sha256' -cne (Get-LifecycleRollbackSetSha256 $RollbackRoot) -or
        -not (Test-Digest $Fields.'directory-snapshot-sha256') -or
        $Fields.'account-present' -cnotin @("true", "false") -or $Fields.'account-enabled' -cnotin @("true", "false") -or
        (($Fields.'account-present' -ceq "true") -ne ($Fields.'account-sid' -match '^S-[0-9]+(?:-[0-9]+){1,14}$')) -or
        ($Fields.'account-present' -ceq "false" -and
            ($Fields.'account-enabled' -cne "false" -or $Fields.'account-sid' -cne "-" -or
             @($Fields.'quota-volume', $Fields.'quota-state', $Fields.'quota-entry',
                $Fields.'quota-threshold', $Fields.'quota-limit' | Where-Object { $_ -cne "-" }).Count -ne 0)) -or
        ($Fields.'account-present' -ceq "true" -and
            ($Fields.'quota-volume' -notmatch '^[A-Za-z]:\\$' -or
             $Fields.'quota-state' -cnotin @("disabled", "tracking", "enforced") -or
             $Fields.'quota-entry' -cnotin @("absent", "present") -or
             ($Fields.'quota-entry' -ceq "absent" -and
                ($Fields.'quota-threshold' -cne "-" -or $Fields.'quota-limit' -cne "-")) -or
             ($Fields.'quota-entry' -ceq "present" -and
                ($Fields.'quota-threshold' -notmatch '^(0|[1-9][0-9]{0,19})$' -or
                 $Fields.'quota-limit' -notmatch '^(0|[1-9][0-9]{0,19})$')))) -or
        -not (Test-Digest $Fields.'request-rights-sha256') -or
        $Fields.'target-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-Digest $Fields.'target-rights-sha256') -or
        $Fields.'generation-was-present' -cnotin @("true", "false")) { throw "recovery_snapshot_drift" }
    foreach ($Name in @("system-task-xml-sha256", "system-task-sddl-sha256",
            "profile-task-xml-sha256", "profile-task-sddl-sha256")) {
        if ($Fields[$Name] -cne "-" -and -not (Test-Digest $Fields[$Name])) { throw "recovery_snapshot_drift" }
    }
    $Fields["system-task-xml"] = ConvertFrom-OptionalTextBase64 $Fields.'system-task-xml-base64' `
        $Fields.'system-task-xml-sha256' 32768 "recovery_snapshot"
    $Fields["system-task-sddl"] = ConvertFrom-OptionalTextBase64 $Fields.'system-task-sddl-base64' `
        $Fields.'system-task-sddl-sha256' 8192 "recovery_snapshot"
    $Fields["profile-task-xml"] = ConvertFrom-OptionalTextBase64 $Fields.'profile-task-xml-base64' `
        $Fields.'profile-task-xml-sha256' 32768 "recovery_snapshot"
    $Fields["profile-task-sddl"] = ConvertFrom-OptionalTextBase64 $Fields.'profile-task-sddl-base64' `
        $Fields.'profile-task-sddl-sha256' 8192 "recovery_snapshot"
    foreach ($Prefix in @("system-task", "profile-task")) {
        $Xml = [string]$Fields[$Prefix + "-xml"]
        $Sddl = [string]$Fields[$Prefix + "-sddl"]
        if ([string]::IsNullOrEmpty($Xml) -ne [string]::IsNullOrEmpty($Sddl)) {
            throw "recovery_snapshot_drift"
        }
        if (-not [string]::IsNullOrEmpty($Xml)) {
            try {
                [void](Get-TaskXmlWithEnabledState $Xml $false)
                [void][Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
            } catch { throw "recovery_snapshot_drift" }
        }
    }
    return $Fields
}

function Write-PreparedLifecycleState([string]$Path, [string]$TransactionId, [int]$Epoch,
        [string]$GenerationStage) {
    Write-AtomicAscii $Path @(
        "windows-lifecycle-prepared-state|1", "transaction-id|$TransactionId", "epoch|$Epoch",
        "generation-stage|$GenerationStage", "generation-stage-sha256|$(Get-Sha256Utf8Text $GenerationStage.ToUpperInvariant())",
        "end-prepared-state|")
}

function Read-PreparedLifecycleState([string]$Path, [object]$Transaction, [string]$Root) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path 4096) 4096 "prepared_state") `
        @("transaction-id", "epoch", "generation-stage", "generation-stage-sha256") `
        "windows-lifecycle-prepared-state|1" "end-prepared-state|" "prepared_state"
    $ExpectedParent = Join-Path $Root "generations"
    if ($Fields.'transaction-id' -cne $Transaction.'transaction-id' -or $Fields.epoch -cne $Transaction.epoch -or
        -not [IO.Path]::GetDirectoryName($Fields.'generation-stage').Equals($ExpectedParent,
            [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Fields.'generation-stage') -cnotmatch ('^\.' + [regex]::Escape($Fields.epoch) + '\.[0-9a-f]{32}$') -or
        $Fields.'generation-stage-sha256' -cne (Get-Sha256Utf8Text $Fields.'generation-stage'.ToUpperInvariant())) {
        throw "prepared_state_drift"
    }
    return $Fields
}

function Publish-LifecycleRecoveryRequired([string]$PublicRoot, [object]$Manifest, [string]$PublicSddl) {
    [void][IO.Directory]::CreateDirectory($PublicRoot)
    Set-PathSddl $PublicRoot $PublicSddl
    $Account = Get-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue
    if ($null -ne $Account -and $Account.Enabled) {
        Disable-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
        $Account = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
        if ($Account.Enabled) { throw "recovery_request_account_disable_failed" }
    }
    $AccountState = if ($null -eq $Account) { "absent" } else { "disabled" }
    $RequestSid = if ($null -eq $Account) { "-" } else { [string]$Account.Sid.Value }
    Write-PublicReadiness $PublicRoot "recovery_required" $Manifest "-" "-" $AccountState $false $false `
        -RequestSid $RequestSid
}

function Assert-LifecyclePointerState([string]$PointerPath, [string]$ExpectedDigest) {
    if ($ExpectedDigest -ceq "-") {
        if ([IO.File]::Exists($PointerPath)) { throw "lifecycle_final_state_drift" }
    } else {
        if (-not [IO.File]::Exists($PointerPath) -or
            (Get-Sha256Bytes (Read-HeldBytes $PointerPath 160)) -cne $ExpectedDigest) {
            throw "lifecycle_final_state_drift"
        }
    }
}

function Assert-TerminalLifecycleState([object]$Transaction, [string]$Root, [string]$StateRoot,
        [string]$PublicRoot) {
    $PointerPath = Join-Path $Root "active.generation"
    if ($Transaction.phase -ceq "rolled-back") {
        Assert-LifecyclePointerState $PointerPath $Transaction.'prior-pointer-sha256'
        return
    }
    if ($Transaction.operation -ceq "revoke") {
        Assert-LifecyclePointerState $PointerPath "-"
        if ($null -ne (Get-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\" -ErrorAction SilentlyContinue) -or
            $null -ne (Get-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction SilentlyContinue) -or
            $null -ne (Get-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue)) {
            throw "lifecycle_final_state_drift"
        }
        $Readiness = $script:Ascii.GetString((Read-HeldBytes (Join-Path $PublicRoot "readiness") 4096))
        if (-not $Readiness.Contains("lifecycle|revoked`n", [StringComparison]::Ordinal)) {
            throw "lifecycle_final_state_drift"
        }
        $ProjectionPaths = Get-ChrootProjectionPaths $Root $PublicRoot
        foreach ($RetiredPath in @($ProjectionPaths.Chroot, $ProjectionPaths.LegacyIngress,
                $ProjectionPaths.LegacyResults)) {
            if ([IO.Directory]::Exists($RetiredPath) -or [IO.File]::Exists($RetiredPath)) {
                throw "lifecycle_final_state_drift"
            }
        }
        return
    }
    $TerminalAccount = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    if ($TerminalAccount.Enabled) { throw "lifecycle_final_state_drift" }
    $TerminalAcl = Get-AclBlueprint ([string]$TerminalAccount.Sid.Value)
    Assert-ChrootProjection $Root $PublicRoot $TerminalAcl -RequireLegacyAbsent
    $Pointer = Read-ActivePointer (Read-HeldBytes $PointerPath 160)
    if ($Pointer.epoch -cne [string]$Transaction.epoch) { throw "lifecycle_final_state_drift" }
    $ReadinessText = $script:Ascii.GetString((Read-HeldBytes (Join-Path $PublicRoot "readiness") 4096))
    if ($Transaction.operation -ceq "activate") {
        $CanaryDigest = $null
        foreach ($Path in @((Join-Path $Root "native-canary.receipt"),
                (Join-Path $Root "native-canary.receipt.p7s"), (Join-Path $Root "native-canary.evidence"))) {
            if (-not [IO.File]::Exists($Path)) { throw "lifecycle_final_state_drift" }
            if ($Path -ceq (Join-Path $Root "native-canary.receipt")) {
                $CanaryDigest = Get-Sha256Bytes (Read-HeldBytes $Path 16384)
            }
        }
        if (-not $ReadinessText.Contains("native-canary-ready|true`n", [StringComparison]::Ordinal) -or
            -not $ReadinessText.Contains("context-canary-sha256|$CanaryDigest`n", [StringComparison]::Ordinal)) {
            throw "lifecycle_final_state_drift"
        }
    } elseif (-not ($ReadinessText.Contains("lifecycle|needs_native_canary`n", [StringComparison]::Ordinal) -or
            $ReadinessText.Contains("lifecycle|needs_transport_enrollment`n", [StringComparison]::Ordinal))) {
        throw "lifecycle_final_state_drift"
    }
}

function Complete-CommittedActivationFinalization {
    param([object]$Transaction, [string]$Root, [string]$StateRoot, [object]$Manifest,
        [object]$BootstrapReceipt, [object]$LifecycleAcl)
    if ($Transaction.operation -cne "activate" -or $Transaction.phase -cne "committed" -or
        $null -eq $BootstrapReceipt) { throw "native_canary_finalization_drift" }

    $Pointer = Read-ActivePointer (Read-HeldBytes (Join-Path $Root "active.generation") 160)
    $LocalReceiptPath = Join-Path $Root "native-canary.receipt"
    $LocalSignaturePath = Join-Path $Root "native-canary.receipt.p7s"
    $LocalEvidencePath = Join-Path $Root "native-canary.evidence"
    foreach ($Path in @($LocalReceiptPath, $LocalSignaturePath, $LocalEvidencePath)) {
        Assert-ProtectedWindowsPath $Path $Root
        Assert-PathSddl $Path $LifecycleAcl.ProtectedFile
    }
    [byte[]]$LocalReceiptBytes = Read-HeldBytes $LocalReceiptPath 16384
    [byte[]]$LocalSignatureBytes = Read-HeldBytes $LocalSignaturePath 65536
    [byte[]]$LocalEvidenceBytes = Read-HeldBytes $LocalEvidencePath 1048576
    $ReceiptFields = Read-NativeCanaryReceiptFields $LocalReceiptBytes
    $FinalRequestAccount = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    $FinalRequestSid = [string]$FinalRequestAccount.Sid.Value
    [long]$IssuedAt = 0; [long]$ExpiresAt = 0
    if ($ReceiptFields.nonce -cnotmatch '^[0-9a-f]{64}$' -or
        $FinalRequestAccount.Enabled -or $ReceiptFields.'request-sid' -cne $FinalRequestSid -or
        $ReceiptFields.host -cne [Environment]::MachineName.ToUpperInvariant() -or
        $ReceiptFields.epoch -cne [string]$Transaction.epoch -or
        $ReceiptFields.epoch -cne [string]$Manifest.Epoch -or
        $ReceiptFields.'generation-sha256' -cne $Pointer.'generation-sha256' -or
        $ReceiptFields.'runner-path-sha256' -cne
            (Get-Sha256Utf8Text $BootstrapReceipt.'native-canary-runner-path'.ToUpperInvariant()) -or
        $ReceiptFields.'runner-sha256' -cne $BootstrapReceipt.'native-canary-runner-sha256' -or
        $ReceiptFields.'runner-publisher-thumbprint' -cne
            $BootstrapReceipt.'native-canary-publisher-thumbprint' -or
        $ReceiptFields.'clock-skew-bound-seconds' -cne [string]$script:ClockSkewBoundSeconds -or
        -not (Test-UInt $ReceiptFields.'issued-at') -or -not (Test-UInt $ReceiptFields.'expires-at') -or
        -not [long]::TryParse($ReceiptFields.'issued-at', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$IssuedAt) -or
        -not [long]::TryParse($ReceiptFields.'expires-at', [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$ExpiresAt) -or
        $ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 3600 -or
        -not (Test-Digest $ReceiptFields.'human-preview-sha256') -or
        -not (Test-Digest $ReceiptFields.'human-confirmation-sha256') -or
        $ReceiptFields.'raw-evidence-sha256' -cne (Get-Sha256Bytes $LocalEvidenceBytes) -or
        -not (Test-NativeCanaryDetachedSignature $LocalReceiptBytes $LocalSignatureBytes `
            $BootstrapReceipt.'native-canary-publisher-thumbprint')) {
        throw "native_canary_finalization_drift"
    }

    $ReceiptRoot = [string]$BootstrapReceipt.'native-canary-receipt-root'
    if (-not [IO.Directory]::Exists($ReceiptRoot) -or [IO.File]::Exists($ReceiptRoot)) {
        throw "native_canary_finalization_drift"
    }
    Assert-ProtectedWindowsPath $ReceiptRoot $ReceiptRoot
    Assert-PathSddl $ReceiptRoot $LifecycleAcl.ProtectedDirectory
    $ReceiptStem = Join-Path $ReceiptRoot ("receipt-" + $ReceiptFields.nonce)
    $ExternalReceiptPath = $ReceiptStem + ".receipt"
    $ExternalSignaturePath = $ReceiptStem + ".p7s"
    $ExternalEvidencePath = $ReceiptStem + ".evidence"
    $ExternalPublicationPath = $ReceiptStem + ".publication"
    $ExternalConsumedPath = $ReceiptStem + ".consumed"
    foreach ($Path in @($ExternalReceiptPath, $ExternalSignaturePath, $ExternalEvidencePath,
            $ExternalPublicationPath)) {
        Assert-ProtectedWindowsPath $Path $ReceiptRoot
        Assert-PathSddl $Path $LifecycleAcl.ProtectedFile
    }
    [byte[]]$ExternalReceiptBytes = Read-HeldBytes $ExternalReceiptPath 16384
    [byte[]]$ExternalSignatureBytes = Read-HeldBytes $ExternalSignaturePath 65536
    [byte[]]$ExternalEvidenceBytes = Read-HeldBytes $ExternalEvidencePath 1048576
    [byte[]]$ExternalPublicationBytes = Read-HeldBytes $ExternalPublicationPath 4096
    [void](Read-NativeCanaryPublication $ExternalPublicationBytes $ReceiptFields.nonce `
        $ExternalReceiptBytes $ExternalSignatureBytes $ExternalEvidenceBytes)
    foreach ($Pair in @(
            @($LocalReceiptBytes, $ExternalReceiptBytes), @($LocalSignatureBytes, $ExternalSignatureBytes),
            @($LocalEvidenceBytes, $ExternalEvidenceBytes))) {
        if ($Pair[0].Count -ne $Pair[1].Count -or
            (Get-Sha256Bytes $Pair[0]) -cne (Get-Sha256Bytes $Pair[1])) {
            throw "native_canary_finalization_drift"
        }
    }

    $ChallengePath = Join-Path $StateRoot "native-canary.challenge"
    if ([IO.Directory]::Exists($ChallengePath) -or [IO.Directory]::Exists($ExternalConsumedPath)) {
        throw "native_canary_finalization_drift"
    }
    $Challenge = $null
    if ([IO.File]::Exists($ChallengePath)) {
        Assert-ProtectedWindowsPath $ChallengePath $Root
        Assert-PathSddl $ChallengePath $LifecycleAcl.ProtectedFile
        $Challenge = Read-NativeCanaryChallenge (Read-HeldBytes $ChallengePath 4096) $Manifest `
            $Pointer.'generation-sha256' $BootstrapReceipt
        $ExpectedConfirmation = Get-NativeCanaryConfirmation $Challenge
        if ($Challenge.Fields.nonce -cne $ReceiptFields.nonce -or $IssuedAt -lt $Challenge.IssuedAt -or
            $ExpiresAt -gt $Challenge.ExpiresAt -or
            $ReceiptFields.'human-preview-sha256' -cne
                (Get-Sha256Utf8Text (Get-NativeCanaryPreview $Challenge)) -or
            $ReceiptFields.'human-confirmation-sha256' -cne
                (Get-Sha256Utf8Text $ExpectedConfirmation)) {
            throw "native_canary_finalization_drift"
        }
    }

    $ReceiptDigest = Get-Sha256Bytes $LocalReceiptBytes
    [byte[]]$ConsumedBytes = ConvertTo-CanonicalAsciiBytes @(
        "windows-native-canary-consumed|1", "nonce|$($ReceiptFields.nonce)",
        "receipt-sha256|$ReceiptDigest", "end-consumed|")
    if ([IO.File]::Exists($ExternalConsumedPath)) {
        Assert-ProtectedWindowsPath $ExternalConsumedPath $ReceiptRoot
        Assert-PathSddl $ExternalConsumedPath $LifecycleAcl.ProtectedFile
        [void](Read-NativeCanaryConsumed (Read-HeldBytes $ExternalConsumedPath 4096) `
            $ReceiptFields.nonce $ReceiptDigest)
    } else {
        if ($null -eq $Challenge) { throw "native_canary_finalization_drift" }
        Write-AtomicBytes $ExternalConsumedPath $ConsumedBytes $LifecycleAcl.ProtectedFile
        Assert-ProtectedWindowsPath $ExternalConsumedPath $ReceiptRoot
        Assert-PathSddl $ExternalConsumedPath $LifecycleAcl.ProtectedFile
        [void](Read-NativeCanaryConsumed (Read-HeldBytes $ExternalConsumedPath 4096) `
            $ReceiptFields.nonce $ReceiptDigest)
    }
    if ([IO.File]::Exists($ChallengePath)) { [IO.File]::Delete($ChallengePath) }
}

function Restore-SnapshottedOrPreparedTransaction {
    param([object]$Transaction, [string]$Root, [string]$StateRoot, [string]$PublicRoot,
        [string]$RollbackRoot, [object]$LifecycleAcl, [string]$ProgramData)
    Assert-ProtectedWindowsPath $RollbackRoot $Root
    Assert-PathSddl $RollbackRoot $LifecycleAcl.ProtectedDirectory
    foreach ($Label in Get-LifecycleRollbackLabels) {
        $MetaPath = Join-Path $RollbackRoot ($Label + ".meta")
        Assert-ProtectedWindowsPath $MetaPath $Root
        Assert-PathSddl $MetaPath $LifecycleAcl.ProtectedFile
        if ((Get-RollbackFileState $RollbackRoot $Label) -ceq "present") {
            $DataPath = Join-Path $RollbackRoot ($Label + ".data")
            Assert-ProtectedWindowsPath $DataPath $Root
            Assert-PathSddl $DataPath $LifecycleAcl.ProtectedFile
        }
    }
    foreach ($RollbackFile in @((Join-Path $RollbackRoot "directory.snapshot"),
            (Join-Path $RollbackRoot "recovery.snapshot"))) {
        Assert-ProtectedWindowsPath $RollbackFile $Root
        Assert-PathSddl $RollbackFile $LifecycleAcl.ProtectedFile
    }
    $PreparedProtectionPath = Join-Path $RollbackRoot "prepared.state"
    if ([IO.File]::Exists($PreparedProtectionPath)) {
        Assert-ProtectedWindowsPath $PreparedProtectionPath $Root
        Assert-PathSddl $PreparedProtectionPath $LifecycleAcl.ProtectedFile
    }
    if ([IO.File]::Exists((Join-Path $StateRoot "winget-provider.provision"))) {
        throw "provider_recovery_ambiguous"
    }
    $SnapshotPath = Join-Path $RollbackRoot "recovery.snapshot"
    if (-not [IO.File]::Exists($SnapshotPath)) { throw "recovery_snapshot_missing" }
    $Snapshot = Read-LifecycleRecoverySnapshot $SnapshotPath $Transaction $RollbackRoot
    $DirectorySnapshotPath = Join-Path $RollbackRoot "directory.snapshot"
    if (-not [IO.File]::Exists($DirectorySnapshotPath) -or
        (Get-Sha256Bytes (Read-HeldBytes $DirectorySnapshotPath 65536)) -cne
            $Snapshot.'directory-snapshot-sha256') { throw "directory_snapshot_drift" }
    $DirectorySnapshot = Read-LifecycleDirectorySnapshot $DirectorySnapshotPath $Root $StateRoot $PublicRoot
    $TaskBindings = @(
        [pscustomobject]@{ Name = $script:SystemTaskName; Xml = [string]$Snapshot.'system-task-xml'
            Sddl = [string]$Snapshot.'system-task-sddl' },
        [pscustomobject]@{ Name = $script:ProfileTaskName; Xml = [string]$Snapshot.'profile-task-xml'
            Sddl = [string]$Snapshot.'profile-task-sddl' })
    $ExpectedTaskNames = [Collections.Generic.List[string]]::new()
    foreach ($Binding in $TaskBindings) {
        $Task = Get-ScheduledTask -TaskName $Binding.Name -TaskPath "\" -ErrorAction SilentlyContinue
        $ExpectedPresent = -not [string]::IsNullOrEmpty($Binding.Xml)
        if ($ExpectedPresent -ne (-not [string]::IsNullOrEmpty($Binding.Sddl)) -or
            (($null -ne $Task) -ne $ExpectedPresent)) { throw "recovery_task_snapshot_drift" }
        if (-not $ExpectedPresent) { continue }
        [void]$ExpectedTaskNames.Add($Binding.Name)
        $CurrentXml = Export-ScheduledTask -TaskName $Binding.Name -TaskPath "\" -ErrorAction Stop
        $CurrentSddl = Get-TaskSecurity $Binding.Name
        $PriorNormalized = Get-NormalizedTaskXml $Binding.Xml
        $DisabledNormalized = Get-NormalizedTaskXml (Get-TaskXmlWithEnabledState $Binding.Xml $false)
        $CurrentNormalized = Get-NormalizedTaskXml $CurrentXml
        if ($CurrentNormalized -cne $PriorNormalized -and $CurrentNormalized -cne $DisabledNormalized -or
            (Get-OptionalTextSha256 $CurrentSddl) -cne (Get-OptionalTextSha256 $Binding.Sddl)) {
            throw "recovery_task_snapshot_drift"
        }
    }
    $DisabledTaskNames = @(Disable-BrokerTasks)
    if (@(Compare-Object @($ExpectedTaskNames.ToArray() | Sort-Object) `
            @($DisabledTaskNames | Sort-Object) -CaseSensitive).Count -ne 0) {
        throw "recovery_task_snapshot_drift"
    }
    # Enrollment retains the lifecycle lease. A newly triggered broker performs one non-retrying
    # File.Open(FileShare.None), so it faults immediately instead of waiting behind this drain.
    Wait-BrokerTasksQuiescent $DisabledTaskNames
    Assert-BrokerTasksQuiescent $DisabledTaskNames
    foreach ($Binding in $TaskBindings | Where-Object { -not [string]::IsNullOrEmpty($_.Xml) }) {
        $DisabledXml = Export-ScheduledTask -TaskName $Binding.Name -TaskPath "\" -ErrorAction Stop
        if ((Get-NormalizedTaskXml $DisabledXml) -cne
                (Get-NormalizedTaskXml (Get-TaskXmlWithEnabledState $Binding.Xml $false)) -or
            (Get-OptionalTextSha256 (Get-TaskSecurity $Binding.Name)) -cne
                (Get-OptionalTextSha256 $Binding.Sddl)) { throw "recovery_task_snapshot_drift" }
    }
    Assert-ProtectedJournalsTerminal (Join-Path $StateRoot "replay") (Join-Path $StateRoot "audit")
    Assert-LifecyclePointerState (Join-Path $Root "active.generation") $Transaction.'prior-pointer-sha256'

    $CurrentAccount = Get-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue
    $AccountWasPresent = $Snapshot.'account-present' -ceq "true"
    if ($AccountWasPresent) {
        if ($null -eq $CurrentAccount -or [string]$CurrentAccount.Sid.Value -cne $Snapshot.'account-sid') {
            throw "recovery_account_snapshot_drift"
        }
        $RequestRights = @(Get-LsaAccountRights $Snapshot.'account-sid')
        if ((Get-Sha256Utf8Text ((@($RequestRights | Sort-Object) -join "`n") + "`n")) -cne
            $Snapshot.'request-rights-sha256') { throw "recovery_account_rights_drift" }
        $Quota = Get-QuotaSnapshot $ProgramData $script:RequestAccountName $Snapshot.'account-sid'
        if ($Quota.Volume -cne $Snapshot.'quota-volume' -or $Quota.State -cne $Snapshot.'quota-state' -or
            $Quota.Entry -cne $Snapshot.'quota-entry' -or $Quota.Threshold -cne $Snapshot.'quota-threshold' -or
            $Quota.Limit -cne $Snapshot.'quota-limit') { throw "recovery_quota_drift" }
    } elseif ($null -ne $CurrentAccount) {
        if ($CurrentAccount.Enabled -or @(Get-LsaAccountRights ([string]$CurrentAccount.Sid.Value)).Count -ne 0) {
            throw "recovery_account_snapshot_drift"
        }
    }
    $TargetRights = @(Get-LsaAccountRights $Snapshot.'target-sid')
    if ((Get-Sha256Utf8Text ((@($TargetRights | Sort-Object) -join "`n") + "`n")) -cne
        $Snapshot.'target-rights-sha256') { throw "recovery_account_rights_drift" }

    $PreparedPath = Join-Path $RollbackRoot "prepared.state"
    $Prepared = $null
    if ([IO.File]::Exists($PreparedPath)) {
        $Prepared = Read-PreparedLifecycleState $PreparedPath $Transaction $Root
        if ([IO.Directory]::Exists($Prepared.'generation-stage')) {
            Assert-ProtectedWindowsPath $Prepared.'generation-stage' $Root
            [IO.Directory]::Delete($Prepared.'generation-stage', $true)
        }
    } elseif ($Transaction.phase -ceq "prepared") { throw "prepared_state_missing" }
    $GenerationRoot = Join-Path (Join-Path $Root "generations") $Transaction.epoch
    if ([IO.Directory]::Exists($GenerationRoot) -and $Snapshot.'generation-was-present' -ceq "false") {
        if ($null -eq $Prepared) { throw "prepared_state_missing" }
        Assert-ProtectedWindowsPath $GenerationRoot $Root
        [IO.Directory]::Delete($GenerationRoot, $true)
    } elseif (-not [IO.Directory]::Exists($GenerationRoot) -and
        $Snapshot.'generation-was-present' -ceq "true") { throw "recovery_generation_drift" }

    foreach ($SnapshotBinding in @(
        @((Join-Path $Root "active.generation"), "active-pointer"),
        @((Join-Path $Root "entry/privilege-broker-windows.ps1"), "entry-broker"),
        @((Join-Path $Root "entry/profile-worker-windows.ps1"), "entry-profile"),
        @((Join-Path $Root "entry/enroll-privilege-windows.ps1"), "entry-enroll"),
        @((Join-Path $Root "entry/register-profile-task-windows.ps1"), "entry-register"),
        @((Join-Path $StateRoot "enrollment.mutations"), "enrollment-mutations"),
        @((Join-Path $PublicRoot "policy.actions"), "public-policy"),
        @((Join-Path $PublicRoot "policy.constraints"), "public-constraints"),
        @((Join-Path $PublicRoot "readiness"), "public-readiness"),
        @((Join-Path $Root "native-canary.receipt"), "native-canary"),
        @((Join-Path $Root "native-canary.receipt.p7s"), "native-canary-signature"),
        @((Join-Path $Root "native-canary.evidence"), "native-canary-evidence"),
        @((Join-Path $StateRoot "native-canary.challenge"), "native-canary-challenge"))) {
        Restore-RollbackFile $SnapshotBinding[0] $RollbackRoot $SnapshotBinding[1]
    }
    if ($AccountWasPresent) {
        if ($Snapshot.'account-enabled' -ceq "true") { Enable-LocalUser -Name $script:RequestAccountName }
        else { Disable-LocalUser -Name $script:RequestAccountName }
        $Observed = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
        if ([bool]$Observed.Enabled -ne ($Snapshot.'account-enabled' -ceq "true")) {
            throw "recovery_account_restore_drift"
        }
    } elseif ($null -ne $CurrentAccount) {
        Remove-LocalUser -Name $script:RequestAccountName
        if ($null -ne (Get-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue)) {
            throw "recovery_account_restore_drift"
        }
    }
    $RecoveryProjectionAcl = if ($AccountWasPresent) {
        Get-AclBlueprint $Snapshot.'account-sid' $Snapshot.'target-sid'
    } else { $null }
    Restore-ChrootProjectionMigration $DirectorySnapshot $Root $PublicRoot $RollbackRoot $RecoveryProjectionAcl
    Restore-LifecycleDirectorySnapshot $DirectorySnapshot $Root
    foreach ($Binding in $TaskBindings) {
        Restore-Task $Binding.Name $Binding.Xml $Binding.Sddl
    }
    foreach ($Binding in $TaskBindings) {
        $RestoredTask = Get-ScheduledTask -TaskName $Binding.Name -TaskPath "\" -ErrorAction SilentlyContinue
        $ExpectedPresent = -not [string]::IsNullOrEmpty($Binding.Xml)
        if (($null -ne $RestoredTask) -ne $ExpectedPresent) { throw "recovery_task_restore_drift" }
        if ($ExpectedPresent -and
            ((Get-NormalizedTaskXml (Export-ScheduledTask -TaskName $Binding.Name -TaskPath "\" -ErrorAction Stop)) -cne
                (Get-NormalizedTaskXml $Binding.Xml) -or
             (Get-OptionalTextSha256 (Get-TaskSecurity $Binding.Name)) -cne
                (Get-OptionalTextSha256 $Binding.Sddl))) { throw "recovery_task_restore_drift" }
    }
    Write-Transaction (Join-Path $StateRoot "lifecycle.transaction") $Transaction.'transaction-id' `
        $Transaction.operation "rolled-back" ([int]$Transaction.epoch) $Transaction.'prior-pointer-sha256'
    Set-PathSddl (Join-Path $StateRoot "lifecycle.transaction") $LifecycleAcl.ProtectedFile
    $PriorDrainState = Get-RollbackFileState $RollbackRoot "drain"
    if ($PriorDrainState -ceq "absent") {
        $DrainPath = Join-Path $StateRoot "drain"
        if ([IO.File]::Exists($DrainPath)) { [IO.File]::Delete($DrainPath) }
    } else { Restore-RollbackFile (Join-Path $StateRoot "drain") $RollbackRoot "drain" }
    Assert-TerminalLifecycleState (Read-Transaction (Join-Path $StateRoot "lifecycle.transaction")) `
        $Root $StateRoot $PublicRoot
    [IO.Directory]::Delete($RollbackRoot, $true)
}

function Restore-SnapshottedActivationTransaction {
    param([object]$Transaction, [string]$Root, [string]$StateRoot, [string]$PublicRoot,
        [string]$RollbackRoot, [object]$Manifest, [object]$BootstrapReceipt, [object]$LifecycleAcl)
    if ($Transaction.operation -cne "activate" -or $Transaction.phase -cne "snapshotted" -or
        $Transaction.'prior-pointer-sha256' -ceq "-" -or $null -eq $BootstrapReceipt) {
        throw "activation_recovery_binding_mismatch"
    }
    Assert-ProtectedWindowsPath $RollbackRoot $Root
    Assert-PathSddl $RollbackRoot $LifecycleAcl.ProtectedDirectory
    foreach ($RollbackFile in @([IO.Directory]::EnumerateFiles(
        $RollbackRoot, "*", [IO.SearchOption]::TopDirectoryOnly))) {
        Assert-ProtectedWindowsPath $RollbackFile $Root
        Assert-PathSddl $RollbackFile $LifecycleAcl.ProtectedFile
    }
    Assert-ActivationRollbackSchema $RollbackRoot
    [void](Read-ActivationRecoverySnapshot (Join-Path $RollbackRoot "activation.snapshot") `
        $Transaction $RollbackRoot)
    Assert-LifecyclePointerState (Join-Path $Root "active.generation") $Transaction.'prior-pointer-sha256'
    $Pointer = Read-ActivePointer (Read-HeldBytes (Join-Path $Root "active.generation") 160)
    if ($Pointer.epoch -cne $Transaction.epoch) { throw "activation_recovery_binding_mismatch" }

    # A snapshotted activation has promoted no external ownership marker yet. If the independently
    # protected receipt has already been consumed, the local phase is no longer an unambiguous
    # rollback and must remain fail-closed for human recovery.
    $ChallengePath = Join-Path $StateRoot "native-canary.challenge"
    Assert-ProtectedWindowsPath $ChallengePath $Root
    Assert-PathSddl $ChallengePath $LifecycleAcl.ProtectedFile
    $Challenge = Read-NativeCanaryChallenge (Read-HeldBytes $ChallengePath 4096) $Manifest `
        $Pointer.'generation-sha256' $BootstrapReceipt
    $ReceiptRoot = [string]$BootstrapReceipt.'native-canary-receipt-root'
    Assert-ProtectedWindowsPath $ReceiptRoot $ReceiptRoot
    Assert-PathSddl $ReceiptRoot $LifecycleAcl.ProtectedDirectory
    $ConsumedPath = (Join-Path $ReceiptRoot ("receipt-" + $Challenge.Fields.nonce)) + ".consumed"
    if ([IO.File]::Exists($ConsumedPath) -or [IO.Directory]::Exists($ConsumedPath)) {
        throw "activation_recovery_ambiguous"
    }

    foreach ($SnapshotBinding in @(
        @((Join-Path $Root "native-canary.receipt"), "native-canary"),
        @((Join-Path $Root "native-canary.receipt.p7s"), "native-canary-signature"),
        @((Join-Path $Root "native-canary.evidence"), "native-canary-evidence"),
        @((Join-Path $PublicRoot "readiness"), "public-readiness"))) {
        [void](Get-RollbackFileState $RollbackRoot $SnapshotBinding[1])
        Restore-RollbackFile $SnapshotBinding[0] $RollbackRoot $SnapshotBinding[1]
    }
    $TransactionPath = Join-Path $StateRoot "lifecycle.transaction"
    Write-Transaction $TransactionPath $Transaction.'transaction-id' "activate" "rolled-back" `
        ([int]$Transaction.epoch) $Transaction.'prior-pointer-sha256'
    Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    Assert-TerminalLifecycleState (Read-Transaction $TransactionPath) $Root $StateRoot $PublicRoot
    [IO.Directory]::Delete($RollbackRoot, $true)
}

function Complete-ActivatedInstallTransaction {
    param([object]$Transaction, [string]$Root, [string]$StateRoot, [string]$PublicRoot,
        [object]$Manifest, [object]$BootstrapReceipt, [object]$LifecycleAcl)
    if ($Transaction.operation -cne "install" -or $Transaction.epoch -cne [string]$Manifest.Epoch -or
        $null -eq $BootstrapReceipt) { throw "activated_recovery_binding_mismatch" }
    $Pointer = Read-ActivePointer (Read-HeldBytes (Join-Path $Root "active.generation") 160)
    if ($Pointer.epoch -cne $Transaction.epoch) { throw "activated_recovery_binding_mismatch" }
    $GenerationDigest = $Pointer.'generation-sha256'
    $GenerationRoot = Join-Path (Join-Path $Root "generations") $Transaction.epoch
    $OpenSshIdentityDigest = Get-Sha256Bytes (Read-HeldBytes (Join-Path $GenerationRoot "openssh.identity") 4096)
    if ((Get-GenerationDigest $Manifest $OpenSshIdentityDigest) -cne $GenerationDigest) {
        throw "activated_recovery_binding_mismatch"
    }
    $Account = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    if ($Account.Enabled) { throw "request_account_must_remain_disabled" }
    $RequestSid = [string]$Account.Sid.Value
    $Acl = Get-AclBlueprint $RequestSid $Manifest.Fields.'target-profile-sid'
    Assert-ChrootProjection $Root $PublicRoot $Acl -RequireLegacyAbsent
    $ProvisionMarkerBytes = Get-WinGetProvisionRequestBytes $Manifest $GenerationDigest
    $ProvisionPaths = Get-WinGetProvisionPaths $StateRoot $Manifest.Epoch $GenerationDigest
    $ProvisionContext = Read-WinGetProvisionContext (Read-HeldBytes (Join-Path $GenerationRoot "winget.context") 16384)
    [void](Assert-CompletedWinGetProvision $Root $ProvisionPaths $ProvisionMarkerBytes $Manifest `
        $GenerationDigest $ProvisionContext $Acl.ProtectedFile)
    $PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
    Assert-TaskContract (Export-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\" -ErrorAction Stop) `
        "system" "S-1-5-18" ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) `
        $PowerShellPath
    Assert-TaskContract (Export-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction Stop) `
        "profile" $Manifest.Fields.'target-profile-sid' `
        ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) $PowerShellPath
    Assert-ProtectedTaskSecurity $script:SystemTaskName; Assert-ProtectedTaskSecurity $script:ProfileTaskName
    $ChallengePath = Join-Path $StateRoot "native-canary.challenge"
    if ([IO.File]::Exists($ChallengePath)) {
        [void](Read-NativeCanaryChallenge (Read-HeldBytes $ChallengePath 4096) $Manifest $GenerationDigest $BootstrapReceipt)
    } else {
        $ChallengeIssuedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Write-AtomicAscii $ChallengePath @(
            "windows-native-canary-challenge|1", "nonce|$(New-CryptographicNonce)",
            "host|$([Environment]::MachineName.ToUpperInvariant())", "epoch|$($Manifest.Epoch)",
            "generation-sha256|$GenerationDigest",
            "runner-path-sha256|$(Get-Sha256Utf8Text $BootstrapReceipt.'native-canary-runner-path'.ToUpperInvariant())",
            "runner-sha256|$($BootstrapReceipt.'native-canary-runner-sha256')",
            "runner-publisher-thumbprint|$($BootstrapReceipt.'native-canary-publisher-thumbprint')",
            "issued-at|$ChallengeIssuedAt", "expires-at|$($ChallengeIssuedAt + 3600)",
            "clock-skew-bound-seconds|$script:ClockSkewBoundSeconds", "end-challenge|")
        Set-PathSddl $ChallengePath $Acl.ProtectedFile
    }
    foreach ($OldCanaryPath in @((Join-Path $Root "native-canary.receipt"),
            (Join-Path $Root "native-canary.receipt.p7s"), (Join-Path $Root "native-canary.evidence"))) {
        if ([IO.File]::Exists($OldCanaryPath)) { [IO.File]::Delete($OldCanaryPath) }
    }
    $BrokerDigest = Get-Sha256Bytes (Read-HeldBytes (Join-Path $Root "entry/privilege-broker-windows.ps1") 4194304)
    Write-PublicReadiness $PublicRoot "needs_native_canary" $Manifest $BrokerDigest $GenerationDigest `
        "disabled" $true $true -RequestSid $RequestSid
    Write-Transaction (Join-Path $StateRoot "lifecycle.transaction") $Transaction.'transaction-id' `
        "install" "committed" $Manifest.Epoch $Transaction.'prior-pointer-sha256'
    Set-PathSddl (Join-Path $StateRoot "lifecycle.transaction") $LifecycleAcl.ProtectedFile
}

function Get-LifecycleRecoveryAction {
    param([string]$Phase, [string]$Operation, [bool]$DrainBound, [bool]$SnapshotComplete,
        [bool]$DurableLive, [string]$ProviderState = "none", [bool]$FinalVerified = $false)
    if (-not $DrainBound -and $Operation -ne "activate" -and $Phase -notin @("committed", "rolled-back")) {
        return "recovery-required"
    }
    if ($DurableLive) { return "recovery-required" }
    if (-not (Test-TransactionPhaseAllowed $Operation $Phase)) { return "recovery-required" }
    switch ($Phase) {
        "intent" { if ($Operation -ceq "activate") { return "rollback-activation-intent" }; return "rollback-intent" }
        "snapshotted" {
            if (-not $SnapshotComplete) { return "recovery-required" }
            if ($Operation -ceq "activate") { return "rollback-activation-snapshot" }
            return "rollback-snapshot"
        }
        "prepared" { if ($SnapshotComplete) { return "rollback-snapshot" }; return "recovery-required" }
        "mutating" { return "recovery-required" }
        "activated" {
            if ($ProviderState -ceq "terminal-success") { return "finalize-activated" }
            return "recovery-required"
        }
        "committed" { if ($FinalVerified) { return "retire-terminal" }; return "recovery-required" }
        "rolled-back" { if ($FinalVerified) { return "retire-terminal" }; return "recovery-required" }
        default { return "recovery-required" }
    }
}

function Resolve-ExistingLifecycleTransaction {
    param([string]$Root, [string]$StateRoot, [string]$PublicRoot, [object]$Manifest,
        [object]$LifecycleAcl, [object]$BootstrapReceipt = $null)
    $TransactionPath = Join-Path $StateRoot "lifecycle.transaction"
    $DrainPath = Join-Path $StateRoot "drain"
    $TransactionRoot = Join-Path $StateRoot "rollback"
    $HasTransaction = [IO.File]::Exists($TransactionPath) -and (Get-Item -LiteralPath $TransactionPath).Length -gt 0
    if (-not $HasTransaction) {
        if ((Get-MissingLifecycleTransactionAction ([IO.File]::Exists($DrainPath))) -ceq "recovery-required") {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
        return
    }
    try {
        Assert-ProtectedWindowsPath $TransactionPath $Root
        Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
        $Transaction = Read-Transaction $TransactionPath
    } catch {
        Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
        throw "lifecycle_recovery_required"
    }
    $RollbackRoot = Join-Path $TransactionRoot $Transaction.'transaction-id'
    $Drain = $null
    if ([IO.File]::Exists($DrainPath)) {
        try {
            Assert-ProtectedWindowsPath $DrainPath $Root
            Assert-PathSddl $DrainPath $LifecycleAcl.ProtectedFile
            $Drain = Read-DrainMarker $DrainPath
        } catch {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
        if (-not (Test-LifecycleDrainBinding $Transaction $Drain)) {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
    } elseif ($Transaction.phase -notin @("committed", "rolled-back") -and
        $Transaction.operation -ne "activate") {
        Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
        throw "lifecycle_recovery_required"
    }

    if ($Transaction.phase -in @("committed", "rolled-back")) {
        try { Assert-TerminalLifecycleState $Transaction $Root $StateRoot $PublicRoot }
        catch {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
        if ($Transaction.operation -ceq "activate" -and $Transaction.phase -ceq "committed") {
            try {
                Complete-CommittedActivationFinalization $Transaction $Root $StateRoot $Manifest `
                    $BootstrapReceipt $LifecycleAcl
            } catch { throw "lifecycle_recovery_required" }
        }
        if ([IO.Directory]::Exists($RollbackRoot)) {
            Assert-ProtectedWindowsPath $RollbackRoot $Root
            Assert-PathSddl $RollbackRoot $LifecycleAcl.ProtectedDirectory
            if ($Transaction.operation -cne "activate") {
                $PriorDrainState = Get-RollbackFileState $RollbackRoot "drain"
                if ($null -ne $Drain) {
                    if ($PriorDrainState -ceq "absent") { [IO.File]::Delete($DrainPath) }
                    else { Restore-RollbackFile $DrainPath $RollbackRoot "drain" }
                } elseif ($PriorDrainState -ceq "present") {
                    Restore-RollbackFile $DrainPath $RollbackRoot "drain"
                }
            }
            [IO.Directory]::Delete($RollbackRoot, $true)
        } elseif ($null -ne $Drain) {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
        return $Transaction
    }

    if ($Transaction.phase -ceq "intent") {
        try {
            Assert-LifecyclePointerState (Join-Path $Root "active.generation") `
                $Transaction.'prior-pointer-sha256'
            if ($Transaction.operation -ceq "activate") {
                if ([IO.Directory]::Exists($RollbackRoot)) {
                    Assert-ProtectedWindowsPath $RollbackRoot $Root
                    Assert-PathSddl $RollbackRoot $LifecycleAcl.ProtectedDirectory
                    [IO.Directory]::Delete($RollbackRoot, $true)
                }
                Write-Transaction $TransactionPath $Transaction.'transaction-id' "activate" "rolled-back" `
                    ([int]$Transaction.epoch) $Transaction.'prior-pointer-sha256'
                Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
                Assert-TerminalLifecycleState (Read-Transaction $TransactionPath) $Root $StateRoot $PublicRoot
                return
            }
            Assert-ProtectedWindowsPath $RollbackRoot $Root
            Assert-PathSddl $RollbackRoot $LifecycleAcl.ProtectedDirectory
            $PriorDrainState = Get-RollbackFileState $RollbackRoot "drain"
            if ($PriorDrainState -ceq "absent") {
                if ($null -ne $Drain) { [IO.File]::Delete($DrainPath) }
            } else { Restore-RollbackFile $DrainPath $RollbackRoot "drain" }
            Write-Transaction $TransactionPath $Transaction.'transaction-id' $Transaction.operation "rolled-back" `
                ([int]$Transaction.epoch) $Transaction.'prior-pointer-sha256'
            Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
            Assert-TerminalLifecycleState (Read-Transaction $TransactionPath) $Root $StateRoot $PublicRoot
            [IO.Directory]::Delete($RollbackRoot, $true)
            return
        } catch {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
    }

    if ($Transaction.phase -in @("snapshotted", "prepared")) {
        try {
            if ($Transaction.operation -ceq "activate") {
                Restore-SnapshottedActivationTransaction $Transaction $Root $StateRoot $PublicRoot `
                    $RollbackRoot $Manifest $BootstrapReceipt $LifecycleAcl
            } else {
                Restore-SnapshottedOrPreparedTransaction $Transaction $Root $StateRoot $PublicRoot `
                    $RollbackRoot $LifecycleAcl ([Environment]::GetFolderPath(
                        [Environment+SpecialFolder]::CommonApplicationData))
            }
            return
        } catch {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
    }

    if ($Transaction.phase -ceq "activated" -and $Transaction.operation -ceq "install") {
        try {
            Complete-ActivatedInstallTransaction $Transaction $Root $StateRoot $PublicRoot $Manifest `
                $BootstrapReceipt $LifecycleAcl
            return Resolve-ExistingLifecycleTransaction $Root $StateRoot $PublicRoot $Manifest $LifecycleAcl `
                $BootstrapReceipt
        } catch {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
    }

    # Mutating/activated phases may own machine/provider state. They are never replayed. Recovery
    # stays explicit unless phase-specific terminal evidence proves a unique outcome.
    Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
    throw "lifecycle_recovery_required"
}

function Assert-PathSddl([string]$Path, [string]$ExpectedSddl) {
    if ($script:SelfTestFixture) { return }
    $Expected = [Security.AccessControl.RawSecurityDescriptor]::new($ExpectedSddl)
    $ObservedAcl = Get-Acl -LiteralPath $Path
    $Observed = [Security.AccessControl.RawSecurityDescriptor]::new(
        $ObservedAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
    [byte[]]$ExpectedBytes = [byte[]]::new($Expected.BinaryLength)
    [byte[]]$ObservedBytes = [byte[]]::new($Observed.BinaryLength)
    $Expected.GetBinaryForm($ExpectedBytes, 0); $Observed.GetBinaryForm($ObservedBytes, 0)
    if ((Get-Sha256Bytes $ExpectedBytes) -cne (Get-Sha256Bytes $ObservedBytes)) { throw "acl_verification_failed" }
}

function Initialize-ProtectedLifecycleDirectory([string]$Path, [string]$Sddl) {
    if ([IO.File]::Exists($Path)) { throw "lifecycle_path_type_mismatch" }
    [void][IO.Directory]::CreateDirectory($Path)
    $Item = Get-Item -LiteralPath $Path -Force
    if (-not $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "lifecycle_path_reparse"
    }
    Set-PathSddl $Path $Sddl
    Assert-PathSddl $Path $Sddl
}

function Initialize-ProtectedLifecycleFile([string]$Path, [string]$Sddl) {
    if ([IO.Directory]::Exists($Path)) { throw "lifecycle_path_type_mismatch" }
    if (-not [IO.File]::Exists($Path)) {
        $Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $Stream.Dispose()
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if ($Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "lifecycle_path_reparse"
    }
    Set-PathSddl $Path $Sddl
    Assert-PathSddl $Path $Sddl
}

function Initialize-LsaType {
    if (-not ("RoundhouseLsa" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class RoundhouseLsa {
  [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES {
    public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
    public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
  }
  [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING {
    public ushort Length; public ushort MaximumLength; public IntPtr Buffer;
  }
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system,
    ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr policy);
  [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr policy,
    IntPtr sid, LSA_UNICODE_STRING[] rights, uint count);
  [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountRights(IntPtr policy,
    IntPtr sid, out IntPtr rights, out uint count);
  [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr policy,
    IntPtr sid, [MarshalAs(UnmanagedType.U1)] bool all, LSA_UNICODE_STRING[] rights, uint count);
  [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
  [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
  const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;
  static IntPtr OpenPolicy() {
    var oa = new LSA_OBJECT_ATTRIBUTES(); oa.Length = Marshal.SizeOf(oa);
    IntPtr policy; uint status = LsaOpenPolicy(IntPtr.Zero, ref oa, 0x00000810, out policy);
    if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
    return policy;
  }
  static LSA_UNICODE_STRING[] MakeRights(string[] values, out IntPtr[] buffers) {
    buffers = new IntPtr[values.Length]; var rights = new LSA_UNICODE_STRING[values.Length];
    for (int i = 0; i < values.Length; i++) {
      buffers[i] = Marshal.StringToHGlobalUni(values[i]);
      rights[i] = new LSA_UNICODE_STRING { Buffer = buffers[i], Length = (ushort)(values[i].Length * 2),
        MaximumLength = (ushort)((values[i].Length + 1) * 2) };
    }
    return rights;
  }
  public static void AddAccountRights(byte[] sidBytes, string[] values) {
    IntPtr policy = OpenPolicy(); GCHandle pinned = default; IntPtr[] buffers = null;
    try {
      pinned = GCHandle.Alloc(sidBytes, GCHandleType.Pinned);
      var rights = MakeRights(values, out buffers);
      uint status = LsaAddAccountRights(policy, pinned.AddrOfPinnedObject(), rights, (uint)rights.Length);
      if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
    } finally {
      if (buffers != null) foreach (IntPtr buffer in buffers) if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
      if (pinned.IsAllocated) pinned.Free(); LsaClose(policy);
    }
  }
  public static string[] GetAccountRights(byte[] sidBytes) {
    IntPtr policy = OpenPolicy(); GCHandle pinned = default; IntPtr memory = IntPtr.Zero;
    try {
      pinned = GCHandle.Alloc(sidBytes, GCHandleType.Pinned); uint count;
      uint status = LsaEnumerateAccountRights(policy, pinned.AddrOfPinnedObject(), out memory, out count);
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
  public static void RemoveAccountRights(byte[] sidBytes, string[] values, bool all) {
    IntPtr policy = OpenPolicy(); GCHandle pinned = default; IntPtr[] buffers = null;
    try {
      pinned = GCHandle.Alloc(sidBytes, GCHandleType.Pinned);
      var rights = MakeRights(values, out buffers);
      uint status = LsaRemoveAccountRights(policy, pinned.AddrOfPinnedObject(), all, rights, (uint)rights.Length);
      if (status == STATUS_OBJECT_NAME_NOT_FOUND) return;
      if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
    } finally {
      if (buffers != null) foreach (IntPtr buffer in buffers) if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
      if (pinned.IsAllocated) pinned.Free(); LsaClose(policy);
    }
  }
}
'@
    }
}

function Get-SidBytes([string]$Sid) {
    $SecurityIdentifier = [Security.Principal.SecurityIdentifier]::new($Sid)
    $SidBytes = [byte[]]::new($SecurityIdentifier.BinaryLength)
    $SecurityIdentifier.GetBinaryForm($SidBytes, 0)
    return $SidBytes
}

function Add-LsaAccountRights([string]$Sid, [string[]]$Rights) {
    Initialize-LsaType
    $SidBytes = Get-SidBytes $Sid
    [RoundhouseLsa]::AddAccountRights($SidBytes, $Rights)
}

function Get-LsaAccountRights([string]$Sid) {
    Initialize-LsaType
    return [string[]]@([RoundhouseLsa]::GetAccountRights((Get-SidBytes $Sid)) | Sort-Object)
}

function Set-LsaAccountRightsExact([string]$Sid, [string[]]$Rights) {
    Initialize-LsaType
    $SidBytes = Get-SidBytes $Sid
    [RoundhouseLsa]::RemoveAccountRights($SidBytes, [string[]]@(), $true)
    if ($Rights.Count -gt 0) { [RoundhouseLsa]::AddAccountRights($SidBytes, [string[]]@($Rights)) }
    if ((@(Get-LsaAccountRights $Sid) -join "`n") -cne (@($Rights | Sort-Object) -join "`n")) {
        throw "account_rights_restore_failed"
    }
}

function Remove-LsaAccountRights([string]$Sid, [string[]]$Rights) {
    Initialize-LsaType
    [RoundhouseLsa]::RemoveAccountRights((Get-SidBytes $Sid), [string[]]@($Rights), $false)
}

function Add-BatchLogonRight([string]$Sid) {
    Add-LsaAccountRights $Sid @("SeBatchLogonRight")
}

function Add-RequestAccountDenyRights([string]$Sid) {
    Add-LsaAccountRights $Sid @(
        "SeDenyInteractiveLogonRight", "SeDenyRemoteInteractiveLogonRight", "SeDenyBatchLogonRight")
}

function Assert-AuthenticodePublisher([string]$Path, [string]$Thumbprint) {
    $Extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($Extension -notin @(".ps1", ".exe", ".dll")) { return }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Thumbprint.ToUpperInvariant() -cne $Thumbprint) {
        throw "authenticode_publisher_mismatch"
    }
}

function Get-SystemOpenSshIdentityBytes {
    $Path = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
    Assert-ProtectedWindowsPath $Path $env:WINDIR
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Thumbprint -notmatch '^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$') {
        throw "system_openssh_publisher_invalid"
    }
    return ConvertTo-CanonicalAsciiBytes @(
        "windows-openssh-identity|1", "path|$Path",
        "sha256|$(Get-Sha256Bytes (Read-HeldBytes $Path 16777216))",
        "publisher-thumbprint|$($Signature.SignerCertificate.Thumbprint.ToUpperInvariant())",
        "y-verify-capability|native-canary-required", "print-pubkey-capability|native-canary-required",
        "certificate-parse-capability|native-canary-required", "end-openssh-identity|")
}

function Assert-SystemOpenSshIdentity([string]$Path, [string]$Root) {
    Assert-ProtectedWindowsPath $Path $Root
    $Lines = ConvertFrom-CanonicalAsciiBytes (Read-HeldBytes $Path 4096) 4096 "openssh_identity"
    $Fields = Read-FixedFields $Lines @("path", "sha256", "publisher-thumbprint", "y-verify-capability",
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
    Assert-ProtectedWindowsPath $ExpectedPath $env:WINDIR
    if ((Get-Sha256Bytes (Read-HeldBytes $ExpectedPath 16777216)) -cne $Fields.sha256) {
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

function Assert-QuotaQueryText([string]$Text, [string]$AccountName, [string]$RequestSid) {
    $Matching = @([regex]::Split($Text, '(?:\r?\n){2,}') | Where-Object {
        $_ -match [regex]::Escape($AccountName) -and $_ -match [regex]::Escape($RequestSid)
    })
    if ($Matching.Count -ne 1) { throw "quota_verification_failed" }
    $Canonical = $Matching[0] -replace '[, ]', ''
    if ($Canonical -notmatch '(?im)^(?:Quota)?Threshold:67108864(?:bytes)?$' -or
        $Canonical -notmatch '(?im)^(?:Quota)?Limit:68157440(?:bytes)?$') {
        throw "quota_verification_failed"
    }
}

function Enable-FixedSlotQuota([string]$ProgramData, [string]$AccountName, [string]$RequestSid) {
    $VolumeRoot = [IO.Path]::GetPathRoot($ProgramData)
    if ($VolumeRoot -notmatch '^[A-Za-z]:\\$') { throw "unsupported_quota_volume" }
    $DriveLetter = $VolumeRoot.Substring(0, 1)
    $Volume = Get-Volume -DriveLetter $DriveLetter
    if ($Volume.FileSystem -cne "NTFS") { throw "unsupported_quota_volume" }
    $Fsutil = Join-Path $env:WINDIR "System32\fsutil.exe"
    foreach ($Arguments in @(
        @("quota", "track", $VolumeRoot), @("quota", "enforce", $VolumeRoot),
        @("quota", "modify", $VolumeRoot, [string]$script:SlotWarningBytes,
            [string]$script:SlotQuotaBytes, ".\$AccountName"))) {
        & $Fsutil @Arguments *> $null
        if ($LASTEXITCODE -ne 0) { throw "quota_configuration_failed" }
    }
    $Observed = @(& $Fsutil quota query $VolumeRoot 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "quota_verification_failed" }
    Assert-QuotaQueryText ($Observed -join "`n") $AccountName $RequestSid
}

function Assert-FixedSlotQuota([string]$ProgramData, [string]$AccountName, [string]$RequestSid) {
    $VolumeRoot = [IO.Path]::GetPathRoot($ProgramData)
    $Fsutil = Join-Path $env:WINDIR "System32\fsutil.exe"
    $Observed = @(& $Fsutil quota query $VolumeRoot 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "quota_verification_failed" }
    Assert-QuotaQueryText ($Observed -join "`n") $AccountName $RequestSid
}

function Read-QuotaSnapshotText([string]$Text, [string]$VolumeRoot, [string]$AccountName, [string]$RequestSid) {
    $StateMatches = New-Object Collections.Generic.List[string]
    if ($Text -match '(?im)^\s*File system quotas are disabled on this volume\.\s*$') { [void]$StateMatches.Add("disabled") }
    if ($Text -match '(?im)^\s*File system quotas are tracked but not enforced on this volume\.\s*$') {
        [void]$StateMatches.Add("tracking")
    }
    if ($Text -match '(?im)^\s*File system quotas are tracked and enforced on this volume\.\s*$') {
        [void]$StateMatches.Add("enforced")
    }
    if ($StateMatches.Count -ne 1) { throw "quota_state_unparseable" }
    $Matching = @([regex]::Split($Text, '(?:\r?\n){2,}') | Where-Object {
        $_ -match [regex]::Escape($AccountName) -and $_ -match [regex]::Escape($RequestSid)
    })
    if ($Matching.Count -gt 1) { throw "quota_state_unparseable" }
    if ($Matching.Count -eq 0) {
        return [pscustomobject]@{ Volume = $VolumeRoot; State = $StateMatches[0]; Entry = "absent";
            Threshold = "-"; Limit = "-" }
    }
    $Threshold = [regex]::Match($Matching[0], '(?im)^\s*(?:Quota )?Threshold:\s*([0-9][0-9, ]*)\s*(?:bytes)?\s*$')
    $Limit = [regex]::Match($Matching[0], '(?im)^\s*(?:Quota )?Limit:\s*([0-9][0-9, ]*)\s*(?:bytes)?\s*$')
    if (-not $Threshold.Success -or -not $Limit.Success) { throw "quota_state_unparseable" }
    $ThresholdValue = $Threshold.Groups[1].Value -replace '[, ]', ''
    $LimitValue = $Limit.Groups[1].Value -replace '[, ]', ''
    [uint64]$ParsedThreshold = 0; [uint64]$ParsedLimit = 0
    if (-not [uint64]::TryParse($ThresholdValue, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$ParsedThreshold) -or
        -not [uint64]::TryParse($LimitValue, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$ParsedLimit)) {
        throw "quota_state_unparseable"
    }
    return [pscustomobject]@{ Volume = $VolumeRoot; State = $StateMatches[0]; Entry = "present";
        Threshold = [string]$ParsedThreshold; Limit = [string]$ParsedLimit }
}

function Get-QuotaSnapshot([string]$ProgramData, [string]$AccountName, [string]$RequestSid) {
    $VolumeRoot = [IO.Path]::GetPathRoot($ProgramData)
    if ($VolumeRoot -notmatch '^[A-Za-z]:\\$') { throw "unsupported_quota_volume" }
    $Fsutil = Join-Path $env:WINDIR "System32\fsutil.exe"
    $Observed = @(& $Fsutil quota query $VolumeRoot 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "quota_state_unparseable" }
    return Read-QuotaSnapshotText ($Observed -join "`n") $VolumeRoot $AccountName $RequestSid
}

function Remove-QuotaEntry([string]$RequestSid) {
    $Matches = New-Object Collections.Generic.List[object]
    foreach ($Entry in @(Get-CimInstance -ClassName Win32_DiskQuota -ErrorAction Stop)) {
        $UserText = [string]$Entry.User
        $EmbeddedSid = try { [string]$Entry.User.SID } catch { "" }
        if ($EmbeddedSid -ceq $RequestSid -or $UserText -match [regex]::Escape($RequestSid)) {
            [void]$Matches.Add($Entry)
        }
    }
    if ($Matches.Count -gt 1) { throw "quota_entry_ambiguous" }
    if ($Matches.Count -eq 1) { Remove-CimInstance -InputObject $Matches[0] -ErrorAction Stop }
}

function Restore-QuotaSnapshot([object]$Snapshot, [string]$AccountName, [string]$RequestSid) {
    $Fsutil = Join-Path $env:WINDIR "System32\fsutil.exe"
    if ($Snapshot.Entry -ceq "present") {
        & $Fsutil quota modify $Snapshot.Volume $Snapshot.Threshold $Snapshot.Limit ".\$AccountName" *> $null
        if ($LASTEXITCODE -ne 0) { throw "quota_restore_failed" }
    } else { Remove-QuotaEntry $RequestSid }
    $Mode = switch ($Snapshot.State) { "disabled" { "disable" } "tracking" { "track" } "enforced" { "enforce" }
        default { throw "quota_restore_failed" } }
    & $Fsutil quota $Mode $Snapshot.Volume *> $null
    if ($LASTEXITCODE -ne 0) { throw "quota_restore_failed" }
    $Restored = Get-QuotaSnapshot $Snapshot.Volume $AccountName $RequestSid
    if ($Restored.State -cne $Snapshot.State -or $Restored.Entry -cne $Snapshot.Entry -or
        $Restored.Threshold -cne $Snapshot.Threshold -or $Restored.Limit -cne $Snapshot.Limit) {
        throw "quota_restore_failed"
    }
}

function Write-EnrollmentMutations([string]$Path, [string]$TargetSid, [string]$RequestSid,
    [bool]$TargetBatchWasPresent, [object]$QuotaSnapshot) {
    Write-AtomicAscii $Path @(
        "windows-enrollment-mutations|1", "target-sid|$TargetSid", "request-sid|$RequestSid",
        "target-batch-was-present|$($TargetBatchWasPresent.ToString().ToLowerInvariant())",
        "quota-volume|$($QuotaSnapshot.Volume)", "quota-state|$($QuotaSnapshot.State)",
        "quota-entry|$($QuotaSnapshot.Entry)", "quota-threshold|$($QuotaSnapshot.Threshold)",
        "quota-limit|$($QuotaSnapshot.Limit)", "end-mutations|")
}

function Read-EnrollmentMutations([byte[]]$Bytes) {
    $Fields = Read-FixedFields (ConvertFrom-CanonicalAsciiBytes $Bytes 2048 "enrollment_mutations") @(
        "target-sid", "request-sid", "target-batch-was-present", "quota-volume", "quota-state", "quota-entry",
        "quota-threshold", "quota-limit") "windows-enrollment-mutations|1" "end-mutations|" "enrollment_mutations"
    if ($Fields.'target-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        $Fields.'request-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        $Fields.'target-batch-was-present' -cnotin @("true", "false") -or
        $Fields.'quota-volume' -notmatch '^[A-Za-z]:\\$' -or $Fields.'quota-state' -cnotin @("disabled", "tracking", "enforced") -or
        $Fields.'quota-entry' -cnotin @("absent", "present") -or
        ($Fields.'quota-entry' -ceq "absent" -and
            ($Fields.'quota-threshold' -cne "-" -or $Fields.'quota-limit' -cne "-")) -or
        ($Fields.'quota-entry' -ceq "present" -and
            ($Fields.'quota-threshold' -notmatch '^(0|[1-9][0-9]{0,19})$' -or
             $Fields.'quota-limit' -notmatch '^(0|[1-9][0-9]{0,19})$'))) { throw "invalid_enrollment_mutations" }
    return [pscustomobject]@{ TargetSid = $Fields.'target-sid'; RequestSid = $Fields.'request-sid';
        TargetBatchWasPresent = $Fields.'target-batch-was-present' -ceq "true"
        Quota = [pscustomobject]@{ Volume = $Fields.'quota-volume'; State = $Fields.'quota-state';
            Entry = $Fields.'quota-entry'; Threshold = $Fields.'quota-threshold'; Limit = $Fields.'quota-limit' } }
}

function Invoke-SelfTest {
    $Root = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-windows-enroll-" + [Guid]::NewGuid().ToString("N"))
    $script:SelfTestFixture = $true
    try {
        Initialize-EnrollmentProfileRootType
        $StageRoot = "C:\ProgramData\Roundhouse-Bootstrap\staged"
        $Digest = "a" * 64
        $ManifestBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-enrollment-manifest|1", "epoch|7", "broker-version|1.0.0", "catalog-version|1",
            "policy-sha256|$Digest", "constraints-sha256|$Digest", "winget-context-sha256|$Digest",
            "provider-lock-sha256|$('b' * 64)", "file-set-sha256|$('c' * 64)",
            "target-profile-sid|S-1-5-21-1-2-3-1001", "end-manifest|")
        $ReceiptBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-bootstrap-receipt|1", "scope|native", "publisher-thumbprint|$('A' * 40)",
            "release-signature-status|valid", "bootstrap-verifier-sha256|$Digest",
            "candidate-sha256|$Digest", "protected-copy-sha256|$Digest",
            "protected-copy-path|$StageRoot\scripts\enroll-privilege-windows.ps1",
            "manifest-sha256|$(Get-Sha256Bytes $ManifestBytes)", "protected-root|$StageRoot",
            "native-canary-runner-path|C:\Windows\System32\RoundhouseCanary\native-canary-runner-windows.ps1",
            "native-canary-runner-sha256|$('d' * 64)", "native-canary-publisher-thumbprint|$('D' * 40)",
            "native-canary-receipt-root|C:\ProgramData\RoundhouseCanary\receipts", "end-bootstrap|")
        $Receipt = Read-BootstrapReceipt $ReceiptBytes $StageRoot
        $Manifest = Read-EnrollmentManifest $ManifestBytes
        if ($Receipt.'manifest-sha256' -cne (Get-Sha256Bytes $ManifestBytes)) { throw "bootstrap binding self-test failed" }
        $ReleaseFileNames = @(
            "generation/policy.actions", "generation/policy.constraints", "generation/windows-winget-provider.lock",
            "generation/winget.context", "scripts/enroll-privilege-windows.ps1",
            "scripts/privilege-broker-windows.ps1", "scripts/profile-worker-windows.ps1",
            "scripts/register-profile-task-windows.ps1")
        $FixtureEntryMapBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-entry-map|1",
            "entry|.codex/settings.json|json-scalar|codex-settings|codex|codex-settings",
            "end-entry-map|")
        $FixtureMarketplaceSetBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-marketplace-set|1", "end-marketplace-set|")
        $FixtureEntryMapDigest = Get-Sha256Bytes $FixtureEntryMapBytes
        $FixtureMarketplaceSetDigest = Get-Sha256Bytes $FixtureMarketplaceSetBytes
        $FixtureProfileRootId = Get-ProfileRootIdentityRecord "S-1-5-21-1-2-3-1001" "C:\Users\Fixture" `
            ([uint32]0x12345678) ([uint64]0x1234)
        $FixtureEntryMapFile = "generation/profiles/entry-maps/$FixtureEntryMapDigest.map"
        $FixtureMarketplaceSetFile = "generation/profiles/marketplace-sets/$FixtureMarketplaceSetDigest.set"
        $FixtureProfileConstraintsBytes = ConvertTo-CanonicalAsciiBytes @(
            "constraints|1|generation=7|policy-sha256=$Digest",
            "profile|fixture-profile-token|S-1-5-21-1-2-3-1001|$FixtureProfileRootId|$FixtureEntryMapDigest|$FixtureMarketplaceSetDigest|managed-only|1|1024")
        $ReleaseFileNames = @($ReleaseFileNames + @($FixtureEntryMapFile, $FixtureMarketplaceSetFile))
        $FileLines = @("windows-enrollment-files|1") + @($ReleaseFileNames | Sort-Object |
            ForEach-Object {
                $FileDigest = if ($_ -ceq $FixtureEntryMapFile) { $FixtureEntryMapDigest }
                    elseif ($_ -ceq $FixtureMarketplaceSetFile) { $FixtureMarketplaceSetDigest }
                    else { $Digest }
                "file|$_|$FileDigest"
            }) + @("end-files|")
        $Files = Read-ReleaseFiles (ConvertTo-CanonicalAsciiBytes $FileLines)
        if ($Files.Files.Count -ne 10) { throw "release file self-test failed" }
        $FixtureProfileRecords = @(Assert-ProfileReleaseArtifactCompleteness $Files $FixtureProfileConstraintsBytes `
            "S-1-5-21-1-2-3-1001" $FixtureProfileRootId)
        if ($FixtureProfileRecords.Count -ne 1 -or $FixtureProfileRecords[0].EntryMapSha256 -cne $FixtureEntryMapDigest) {
            throw "profile release artifact self-test failed"
        }
        $FixtureGenerationRoot = Join-Path $Root "fixture-generation"
        $FixtureEntryMapPath = Join-Path $FixtureGenerationRoot "profiles/entry-maps/$FixtureEntryMapDigest.map"
        $FixtureMarketplaceSetPath = Join-Path $FixtureGenerationRoot "profiles/marketplace-sets/$FixtureMarketplaceSetDigest.set"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $FixtureEntryMapPath))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $FixtureMarketplaceSetPath))
        [IO.File]::WriteAllBytes($FixtureEntryMapPath, $FixtureEntryMapBytes)
        [IO.File]::WriteAllBytes($FixtureMarketplaceSetPath, $FixtureMarketplaceSetBytes)
        Assert-StagedProfileArtifacts $FixtureGenerationRoot $FixtureProfileRecords $Root "fixture" -Fixture
        $MissingProfileArtifactFiles = @($FileLines | Where-Object { $_ -cne "file|$FixtureMarketplaceSetFile|$FixtureMarketplaceSetDigest" })
        $MissingProfileArtifactRejected = $false
        try {
            [void](Assert-ProfileReleaseArtifactCompleteness `
                (Read-ReleaseFiles (ConvertTo-CanonicalAsciiBytes $MissingProfileArtifactFiles)) `
                $FixtureProfileConstraintsBytes "S-1-5-21-1-2-3-1001" $FixtureProfileRootId)
        } catch { $MissingProfileArtifactRejected = $_.Exception.Message -eq "missing_profile_release_artifact" }
        if (-not $MissingProfileArtifactRejected) { throw "profile release completeness self-test failed" }
        if (Test-WindowsAbsolutePath '\\server\share\Fixture') { throw "UNC profile root self-test failed" }
        $FixtureTaskXml = '<Task version="1.4"><RegistrationInfo /></Task>'
        $FixtureProfileExpected = [pscustomobject]@{
            TargetSid = "S-1-5-21-1-2-3-1001"; ProfileRootId = $FixtureProfileRootId
            ProfilePath = "C:\Users\Fixture"; FinalPath = "C:\Users\Fixture"; TaskXml = $FixtureTaskXml
        }
        $FixtureRegistrationJson = ([ordered]@{
            schema = "roundhouse.profile-task-registration"; schema_version = 1
            task_name = $script:ProfileTaskName; target_sid = $FixtureProfileExpected.TargetSid
            context = "windows-user-s4u-v1"; task_xml_sha256 = Get-NormalizedTaskXmlSha256 $FixtureTaskXml
            password_supplied = $false; profile_root_id = $FixtureProfileRootId
            profile_root_path_sha256 = Get-Sha256Utf8Text $FixtureProfileExpected.FinalPath.ToUpperInvariant()
            registered_at = "2026-08-03T00:00:00Z"
        } | ConvertTo-Json -Compress)
        $FixtureRegistration = Read-ProfileTaskRegistrationReceipt `
            ($script:Utf8.GetBytes($FixtureRegistrationJson)) $FixtureProfileExpected
        if ($FixtureRegistration.ProfileRootId -cne $FixtureProfileRootId) {
            throw "profile registration receipt self-test failed"
        }
        $ProfileReceiptDriftRejected = $false
        try {
            [void](Read-ProfileTaskRegistrationReceipt `
                ($script:Utf8.GetBytes($FixtureRegistrationJson.Replace($FixtureProfileRootId, ('e' * 64)))) `
                $FixtureProfileExpected)
        } catch { $ProfileReceiptDriftRejected = $true }
        if (-not $ProfileReceiptDriftRejected) { throw "profile registration drift self-test failed" }
        $RootSwapRejected = $false
        try {
            Assert-ProfileRootEvidenceMatch ([pscustomobject]@{
                    ProfilePath = "C:\Users\Fixture"; FinalPath = "C:\Users\Fixture"; ProfileRootId = $FixtureProfileRootId
                }) ([pscustomobject]@{
                    ProfilePath = "C:\Users\Fixture"; FinalPath = "C:\Users\Fixture"; ProfileRootId = ('f' * 64)
                })
        } catch { $RootSwapRejected = $_.Exception.Message -eq "profile_root_identity_drift" }
        if (-not $RootSwapRejected) { throw "profile root re-observation self-test failed" }
        $GenerationDigest = Get-GenerationDigest $Manifest $Digest
        if (-not (Test-Digest $GenerationDigest)) { throw "generation digest self-test failed" }
        $ExpectedConfirmation = Get-ConfirmationText "install" "FIXTURE" 7 (Get-Sha256Bytes $ManifestBytes)
        if ($ExpectedConfirmation -cne "INSTALL FIXTURE EPOCH 7 $((Get-Sha256Bytes $ManifestBytes).Substring(0, 12))") {
            throw "confirmation self-test failed"
        }
        $Blueprint = Get-AclBlueprint "S-1-5-21-1-2-3-1200"
        if ($Blueprint.OwnerRightsSid -cne "S-1-3-4" -or
            $Blueprint.ChrootDirectory -cne
                "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x001200a0;;;S-1-5-21-1-2-3-1200)" -or
            $Blueprint.SlotFile -cne
                "O:S-1-5-21-1-2-3-1200G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;S-1-5-21-1-2-3-1200)" -or
            $Blueprint.ResultFile -cne
                "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00120089;;;S-1-5-21-1-2-3-1200)" -or
            $Blueprint.SlotFile -match '0x00100116|\(A;;[^;]+;;;OW\)') {
            throw "slot OWNER RIGHTS self-test failed"
        }
        $ProjectionFixtureRoot = Join-Path $Root "projection-fixture"
        $ProjectionFixturePublic = Join-Path $Root "projection-public"
        $ProjectionPaths = Get-ChrootProjectionPaths $ProjectionFixtureRoot $ProjectionFixturePublic
        $ProjectionRollbackPairs = Get-ChrootProjectionRollbackPairs $ProjectionPaths $ProjectionFixtureRoot `
            $ProjectionFixturePublic (Join-Path $Root "projection-rollback")
        $ResultsRollbackPair = @($ProjectionRollbackPairs | Where-Object { $_.Kind -ceq "results" })
        if ($ResultsRollbackPair.Count -ne 1 -or
            $ResultsRollbackPair[0].NestedBoundary -cne $ProjectionFixtureRoot -or
            $ResultsRollbackPair[0].LegacySourceBoundary -cne $ProjectionFixturePublic -or
            $ResultsRollbackPair[0].BackupBoundary -cne $ProjectionFixtureRoot) {
            throw "projection rollback boundary self-test failed"
        }
        [void][IO.Directory]::CreateDirectory($ProjectionPaths.Slot)
        [void][IO.Directory]::CreateDirectory($ProjectionPaths.Results)
        foreach ($Name in @("request", "request.sig", "payload", "commit")) {
            [IO.File]::WriteAllBytes((Join-Path $ProjectionPaths.Slot $Name), [byte[]]@())
        }
        Assert-ChrootProjection $ProjectionFixtureRoot $ProjectionFixturePublic $Blueprint -RequireLegacyAbsent
        [IO.File]::WriteAllBytes((Join-Path $ProjectionPaths.Slot "dynamic"), [byte[]]@())
        $ProjectionUnknownRejected = $false
        try { Assert-ChrootProjection $ProjectionFixtureRoot $ProjectionFixturePublic $Blueprint -RequireLegacyAbsent }
        catch { $ProjectionUnknownRejected = $_.Exception.Message -eq "projection_unknown_entry" }
        if (-not $ProjectionUnknownRejected) { throw "projection unknown entry self-test failed" }
        [IO.File]::Delete((Join-Path $ProjectionPaths.Slot "dynamic"))
        [void][IO.Directory]::CreateDirectory($ProjectionPaths.LegacyIngress)
        $ProjectionLegacyRejected = $false
        try { Assert-ChrootProjection $ProjectionFixtureRoot $ProjectionFixturePublic $Blueprint -RequireLegacyAbsent }
        catch { $ProjectionLegacyRejected = $_.Exception.Message -eq "legacy_projection_still_live" }
        if (-not $ProjectionLegacyRejected) { throw "projection legacy path self-test failed" }
        [IO.Directory]::Delete($ProjectionFixtureRoot, $true)
        Assert-QuotaQueryText @'
File system quotas are tracked and enforced on this volume.

User Name: .\RoundhouseRequest
User SID: S-1-5-21-1-2-3-1200
Quota Threshold: 67,108,864 bytes
Quota Limit: 68,157,440 bytes
'@ "RoundhouseRequest" "S-1-5-21-1-2-3-1200"
        $LooseQuotaRejected = $false
        try { Assert-QuotaQueryText "Quota configured" "RoundhouseRequest" "S-1-5-21-1-2-3-1200" }
        catch { $LooseQuotaRejected = $true }
        if (-not $LooseQuotaRejected) { throw "quota fail-closed self-test failed" }
        $QuotaSnapshot = Read-QuotaSnapshotText @'
File system quotas are tracked but not enforced on this volume.

User Name: .\RoundhouseRequest
User SID: S-1-5-21-1-2-3-1200
Quota Threshold: 12,345 bytes
Quota Limit: 67,890 bytes
'@ "C:\" "RoundhouseRequest" "S-1-5-21-1-2-3-1200"
        if ($QuotaSnapshot.State -cne "tracking" -or $QuotaSnapshot.Threshold -cne "12345" -or
            $QuotaSnapshot.Limit -cne "67890") { throw "quota snapshot self-test failed" }
        $MutationPath = Join-Path $Root "enrollment.mutations"
        Write-EnrollmentMutations $MutationPath "S-1-5-21-1-2-3-1001" `
            "S-1-5-21-1-2-3-1200" $false $QuotaSnapshot
        $Mutation = Read-EnrollmentMutations ([IO.File]::ReadAllBytes($MutationPath))
        if ($Mutation.TargetBatchWasPresent -or $Mutation.RequestSid -cne "S-1-5-21-1-2-3-1200" -or
            $Mutation.Quota.State -cne "tracking") {
            throw "mutation rollback record self-test failed"
        }
        $TaskXml = Get-SystemTaskXml "C:\ProgramData" "C:\Program Files\PowerShell\7\pwsh.exe"
        Assert-TaskContract $TaskXml "system" "S-1-5-18" "C:\ProgramData" "C:\Program Files\PowerShell\7\pwsh.exe"
        if ($TaskXml -notmatch '<URI>\\RoundhouseBrokerV1</URI>' -or
            $TaskXml -match 'generations\\|active\.generation' -or
            ($script:TaskCreateOrUpdate -bor $script:TaskDontAddPrincipalAce) -ne 0x16 -or
            $script:TaskLogonServiceAccount -ne 0x5) { throw "fixed system task self-test failed" }
        $ProfileTaskXml = Get-ProfileTaskXml "S-1-5-21-1-2-3-1001" "C:\ProgramData" `
            "C:\Program Files\PowerShell\7\pwsh.exe"
        Assert-TaskContract $ProfileTaskXml "profile" "S-1-5-21-1-2-3-1001" "C:\ProgramData" `
            "C:\Program Files\PowerShell\7\pwsh.exe"
        if ($ProfileTaskXml -match '(?i)<TimeTrigger|<Repetition' -or
            $ProfileTaskXml -notmatch '<Triggers\s*/>' -or
            $ProfileTaskXml -notmatch '<StartWhenAvailable>false</StartWhenAvailable>' -or
            $TaskXml -notmatch '<TimeTrigger>.*<Interval>PT1M</Interval>.*</TimeTrigger>') {
            throw "task-kind trigger self-test failed"
        }
        foreach ($ProfileTaskMutation in @(
                $ProfileTaskXml.Replace('<Triggers />', '<Triggers><TimeTrigger>' +
                    '<StartBoundary>2000-01-01T00:00:00</StartBoundary><Repetition><Interval>PT1M</Interval>' +
                    '<StopAtDurationEnd>false</StopAtDurationEnd></Repetition><Enabled>true</Enabled>' +
                    '</TimeTrigger></Triggers>'),
                $ProfileTaskXml.Replace('<StartWhenAvailable>false</StartWhenAvailable>',
                    '<StartWhenAvailable>true</StartWhenAvailable>'),
                $ProfileTaskXml.Replace('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>',
                    '<ExecutionTimeLimit>PT1M</ExecutionTimeLimit>'),
                $ProfileTaskXml.Replace('</Settings>', '<RestartOnFailure><Interval>PT1M</Interval>' +
                    '<Count>3</Count></RestartOnFailure></Settings>'))) {
            $ProfileTaskMutationRejected = $false
            try {
                Assert-TaskContract $ProfileTaskMutation "profile" "S-1-5-21-1-2-3-1001" `
                    "C:\ProgramData" "C:\Program Files\PowerShell\7\pwsh.exe"
            } catch { $ProfileTaskMutationRejected = $_.Exception.Message -eq "task_contract_drift" }
            if (-not $ProfileTaskMutationRejected) { throw "profile task triggerless self-test failed" }
        }
        $NewTaskSecurityFixture = {
            param([string]$InitialSddl)
            $Fixture = [pscustomobject]@{
                Descriptor = $InitialSddl
                SetFlags = [Collections.Generic.List[int]]::new()
                GetFlags = [Collections.Generic.List[int]]::new()
                SetValues = [Collections.Generic.List[string]]::new()
            }
            $Fixture | Add-Member -MemberType ScriptMethod -Name SetSecurityDescriptor -Value {
                param([string]$Sddl, [int]$Flags)
                [void]$this.SetFlags.Add($Flags); [void]$this.SetValues.Add($Sddl); $this.Descriptor = $Sddl
            }
            $Fixture | Add-Member -MemberType ScriptMethod -Name GetSecurityDescriptor -Value {
                param([int]$Flags)
                [void]$this.GetFlags.Add($Flags); return $this.Descriptor
            }
            return $Fixture
        }
        $ForwardTask = & $NewTaskSecurityFixture "O:BAG:SYD:P(A;;FR;;;SY)"
        Set-RegisteredTaskSecurityDescriptor $ForwardTask $script:TaskSddl -Fixture
        if ($ForwardTask.SetFlags.Count -ne 1 -or $ForwardTask.SetFlags[0] -ne 0x10 -or
            $ForwardTask.GetFlags.Count -ne 1 -or $ForwardTask.GetFlags[0] -ne 0x7 -or
            $ForwardTask.SetValues[0] -cne $script:TaskSddl) {
            throw "forward task descriptor flags self-test failed"
        }
        $RollbackSddl = "O:BAG:SYD:P(A;;FA;;;SY)(A;;FR;;;BA)"
        $RollbackTask = & $NewTaskSecurityFixture $script:TaskSddl
        Set-RegisteredTaskSecurityDescriptor $RollbackTask $RollbackSddl -Fixture
        if ($RollbackTask.SetFlags.Count -ne 1 -or $RollbackTask.SetFlags[0] -ne 0x10 -or
            $RollbackTask.GetFlags.Count -ne 1 -or $RollbackTask.GetFlags[0] -ne 0x7 -or
            $RollbackTask.SetValues[0] -cne $RollbackSddl) {
            throw "rollback task descriptor flags self-test failed"
        }
        $SnapshotTask = & $NewTaskSecurityFixture $RollbackSddl
        Assert-ExactTaskSecurityDescriptor $RollbackSddl `
            (Read-RegisteredTaskSecurityDescriptor $SnapshotTask) -Fixture
        if ($SnapshotTask.GetFlags.Count -ne 1 -or $SnapshotTask.GetFlags[0] -ne 0x7) {
            throw "task descriptor snapshot flags self-test failed"
        }
        foreach ($TaskDescriptorDrift in @(
                $script:TaskSddl.Replace("O:SY", "O:BA"),
                $script:TaskSddl.Replace("G:BA", "G:SY"),
                ($script:TaskSddl + "(A;;FR;;;S-1-5-21-1-2-3-1001)"),
                ($script:TaskSddl + "(A;;FR;;;S-1-5-21-1-2-3-2001)"))) {
            $TaskDescriptorDriftRejected = $false
            try { Assert-ExactTaskSecurityDescriptor $script:TaskSddl $TaskDescriptorDrift -Fixture }
            catch { $TaskDescriptorDriftRejected = $_.Exception.Message -eq "task_security_drift" }
            if (-not $TaskDescriptorDriftRejected) { throw "task descriptor drift self-test failed" }
        }
        [xml]$DisabledTaskDocument = $TaskXml
        $DisabledTaskNamespace = [Xml.XmlNamespaceManager]::new($DisabledTaskDocument.NameTable)
        $DisabledTaskNamespace.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
        $DisabledTaskDocument.SelectSingleNode("/t:Task/t:Settings/t:Enabled", $DisabledTaskNamespace).InnerText = "false"
        Assert-TaskContract $DisabledTaskDocument.OuterXml "system" "S-1-5-18" "C:\ProgramData" `
            "C:\Program Files\PowerShell\7\pwsh.exe" -Disabled
        $TaskSnapshotBase64 = ConvertTo-OptionalTextBase64 $TaskXml
        if ((ConvertFrom-OptionalTextBase64 $TaskSnapshotBase64 (Get-OptionalTextSha256 $TaskXml) `
                32768 "recovery_snapshot") -cne $TaskXml -or
            (ConvertFrom-OptionalTextBase64 "-" "-" 32768 "recovery_snapshot") -cne "") {
            throw "task recovery snapshot roundtrip self-test failed"
        }
        foreach ($InvalidTaskSnapshot in @(
                @($TaskSnapshotBase64, ("f" * 64)), @("-", (Get-OptionalTextSha256 $TaskXml)),
                @($TaskSnapshotBase64, "-"))) {
            $TaskSnapshotRejected = $false
            try {
                [void](ConvertFrom-OptionalTextBase64 $InvalidTaskSnapshot[0] $InvalidTaskSnapshot[1] `
                    32768 "recovery_snapshot")
            } catch { $TaskSnapshotRejected = $_.Exception.Message -eq "invalid_recovery_snapshot" }
            if (-not $TaskSnapshotRejected) { throw "task recovery snapshot fail-closed self-test failed" }
        }
        if ((Get-TaskQuiescenceDisposition -States @() -DeadlineExpired $false) -cne "ready" -or
            (Get-TaskQuiescenceDisposition -States @("Disabled", "Disabled") -DeadlineExpired $false) -cne "ready" -or
            (Get-TaskQuiescenceDisposition -States @("Running", "Disabled") -DeadlineExpired $false) -cne "wait" -or
            (Get-TaskQuiescenceDisposition -States @("Queued") -DeadlineExpired $false) -cne "wait") {
            throw "scheduled task natural quiescence self-test failed"
        }
        foreach ($InvalidQuiescence in @(@("Running", $true, "scheduled_task_quiescence_timeout"),
                @("disabled", $false, "scheduled_task_disable_failed"),
                @("Ready", $false, "scheduled_task_disable_failed"))) {
            $QuiescenceRejected = $false
            try {
                [void](Get-TaskQuiescenceDisposition -States @($InvalidQuiescence[0]) `
                    -DeadlineExpired ([bool]$InvalidQuiescence[1]))
            } catch { $QuiescenceRejected = $_.Exception.Message -eq $InvalidQuiescence[2] }
            if (-not $QuiescenceRejected) { throw "scheduled task fail-closed quiescence self-test failed" }
        }

        $StateRoot = Join-Path $Root "state"; [void][IO.Directory]::CreateDirectory($StateRoot)
        $TransactionPath = Join-Path $StateRoot "lifecycle.transaction"
        $TransactionId = "transaction-" + [Guid]::NewGuid().ToString("N")
        Write-Transaction $TransactionPath $TransactionId "install" "intent" 7 "-"
        Write-Transaction $TransactionPath $TransactionId "install" "snapshotted" 7 "-"
        $Observed = Read-Transaction $TransactionPath
        if ($Observed.phase -cne "snapshotted") { throw "transaction phase self-test failed" }
        $DrainPath = Join-Path $StateRoot "drain"
        Write-DrainMarker $DrainPath "install" $TransactionId 7
        $LifecyclePath = Join-Path $StateRoot "broker.lock"
        $Lease = Acquire-LifecycleLock $LifecyclePath 1000
        $SecondLeaseRejected = $false
        try { [void](Acquire-LifecycleLock $LifecyclePath 100) } catch {
            $SecondLeaseRejected = $_.Exception.Message -eq "broker_drain_timeout"
        } finally { $Lease.Dispose() }
        if (-not $SecondLeaseRejected) { throw "lifecycle drain lock self-test failed" }
        $ReleasedLease = Acquire-LifecycleLock $LifecyclePath 1000
        $ReleasedLease.Dispose()
        if (-not [IO.File]::Exists($DrainPath)) { throw "lifecycle drain release ordering self-test failed" }
        $ReacquiredLease = Acquire-LifecycleLock $LifecyclePath 1000
        try {
            if (-not [IO.File]::Exists($DrainPath)) { throw "lifecycle drain reacquire self-test failed" }
        } finally { $ReacquiredLease.Dispose() }
        $DrainDigestBefore = Get-Sha256Bytes ([IO.File]::ReadAllBytes($DrainPath))
        $Drain = Read-DrainMarker $DrainPath
        if ($Drain.'transaction-id' -cne $TransactionId -or $Drain.operation -cne "install" -or
            $Drain.epoch -cne "7" -or -not (Test-LifecycleDrainBinding $Observed $Drain) -or
            (Get-MissingLifecycleTransactionAction $true) -cne "recovery-required" -or
            (Get-MissingLifecycleTransactionAction $false) -cne "none") {
            throw "lifecycle drain binding self-test failed"
        }
        # Each vector names the state durable at an immediate crash boundary. Repeated phases are
        # intentional: they prove both sides of a mutation boundary dispatch to the same exact
        # recovery schema until the next phase record is durably written.
        $RecoveryVectors = @(
            @("install-after-intent-write", "intent", "install", $true, $false, $false, "none", $false, "rollback-intent"),
            @("install-before-rollback-snapshot", "intent", "install", $true, $false, $false, "none", $false, "rollback-intent"),
            @("install-after-rollback-snapshot-before-snapshotted-write", "intent", "install", $true, $true, $false, "none", $false, "rollback-intent"),
            @("install-after-snapshotted-write", "snapshotted", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-before-prepared-write", "snapshotted", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-during-prepared-state-atomic-write", "snapshotted", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-after-prepared-write-before-first-prepared-mutation", "prepared", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-after-first-prepared-mutation", "prepared", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-recovery-after-task-disable-before-natural-quiescence", "prepared", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-recovery-after-first-task-restore", "prepared", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-before-mutating-write", "prepared", "install", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("install-after-mutating-write-before-first-operation-mutation", "mutating", "install", $true, $true, $false, "none", $false, "recovery-required"),
            @("install-after-task-disable-before-natural-quiescence", "mutating", "install", $true, $true, $false, "none", $false, "recovery-required"),
            @("install-after-natural-task-quiescence", "mutating", "install", $true, $true, $false, "none", $false, "recovery-required"),
            @("install-after-first-operation-mutation", "mutating", "install", $true, $true, $false, "none", $false, "recovery-required"),
            @("install-after-profile-enable-before-activated-write", "mutating", "install", $true, $true, $false, "none", $false, "recovery-required"),
            @("install-before-activated-write", "mutating", "install", $true, $true, $false, "none", $false, "recovery-required"),
            @("install-after-activated-write-before-provider-mutation", "activated", "install", $true, $true, $false, "none", $false, "recovery-required"),
            @("install-after-provider-marker-mutation", "activated", "install", $true, $true, $false, "claimed", $false, "recovery-required"),
            @("install-provider-durable-live", "activated", "install", $true, $true, $true, "claimed", $false, "recovery-required"),
            @("install-after-provider-terminal-before-committed-write", "activated", "install", $true, $true, $false, "terminal-success", $false, "finalize-activated"),
            @("install-after-final-local-mutation-before-committed-write", "activated", "install", $true, $true, $false, "terminal-success", $false, "finalize-activated"),
            @("install-after-committed-write-before-drain-cleanup", "committed", "install", $true, $true, $false, "none", $true, "retire-terminal"),
            @("install-after-drain-cleanup", "committed", "install", $false, $true, $false, "none", $true, "retire-terminal"),
            @("install-after-rolledback-write", "rolled-back", "install", $true, $true, $false, "none", $true, "retire-terminal"),
            @("revoke-after-intent-write", "intent", "revoke", $true, $false, $false, "none", $false, "rollback-intent"),
            @("revoke-after-rollback-snapshot-before-snapshotted-write", "intent", "revoke", $true, $true, $false, "none", $false, "rollback-intent"),
            @("revoke-after-snapshotted-write", "snapshotted", "revoke", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("revoke-before-mutating-write", "snapshotted", "revoke", $true, $true, $false, "none", $false, "rollback-snapshot"),
            @("revoke-after-mutating-write-before-first-operation-mutation", "mutating", "revoke", $true, $true, $false, "none", $false, "recovery-required"),
            @("revoke-after-task-disable-before-natural-quiescence", "mutating", "revoke", $true, $true, $false, "none", $false, "recovery-required"),
            @("revoke-after-natural-task-quiescence", "mutating", "revoke", $true, $true, $false, "none", $false, "recovery-required"),
            @("revoke-after-first-operation-mutation", "mutating", "revoke", $true, $true, $false, "none", $false, "recovery-required"),
            @("revoke-after-final-operation-mutation-before-committed-write", "mutating", "revoke", $true, $true, $false, "none", $false, "recovery-required"),
            @("revoke-after-committed-write-before-drain-cleanup", "committed", "revoke", $true, $true, $false, "none", $true, "retire-terminal"),
            @("revoke-after-drain-cleanup", "committed", "revoke", $false, $true, $false, "none", $true, "retire-terminal"),
            @("activate-after-intent-write", "intent", "activate", $false, $false, $false, "none", $false, "rollback-activation-intent"),
            @("activate-during-rollback-snapshot-atomic-write", "intent", "activate", $false, $false, $false, "none", $false, "rollback-activation-intent"),
            @("activate-after-rollback-snapshot-before-snapshotted-write", "intent", "activate", $false, $true, $false, "none", $false, "rollback-activation-intent"),
            @("activate-after-snapshotted-write-before-first-local-mutation", "snapshotted", "activate", $false, $true, $false, "none", $false, "rollback-activation-snapshot"),
            @("activate-after-first-local-mutation", "snapshotted", "activate", $false, $true, $false, "none", $false, "rollback-activation-snapshot"),
            @("activate-after-final-local-mutation-before-committed-write", "snapshotted", "activate", $false, $true, $false, "none", $false, "rollback-activation-snapshot"),
            @("activate-after-committed-write-before-consumed-marker", "committed", "activate", $false, $true, $false, "none", $true, "retire-terminal"),
            @("activate-after-consumed-marker-before-challenge-retirement", "committed", "activate", $false, $true, $false, "none", $true, "retire-terminal"),
            @("activate-after-challenge-retirement", "committed", "activate", $false, $true, $false, "none", $true, "retire-terminal"))
        $RecoveryVectorNames = @($RecoveryVectors | ForEach-Object { $_[0] })
        if (@($RecoveryVectorNames | Select-Object -Unique).Count -ne $RecoveryVectorNames.Count) {
            throw "duplicate lifecycle crash-boundary fixture"
        }
        foreach ($Vector in $RecoveryVectors) {
            $Action = Get-LifecycleRecoveryAction $Vector[1] $Vector[2] $Vector[3] $Vector[4] `
                $Vector[5] $Vector[6] $Vector[7]
            if ($Action -cne $Vector[8]) { throw "lifecycle phase recovery self-test failed: $($Vector[0])" }
        }
        $AmbiguousActions = @(
            (Get-LifecycleRecoveryAction "snapshotted" "install" $true $false $false "none" $false),
            (Get-LifecycleRecoveryAction "prepared" "install" $true $true $true "none" $false),
            (Get-LifecycleRecoveryAction "activated" "install" $true $true $false "claimed" $false),
            (Get-LifecycleRecoveryAction "mutating" "install" $false $true $false "none" $false))
        foreach ($AmbiguousAction in $AmbiguousActions) {
            if ($AmbiguousAction -cne "recovery-required") { throw "lifecycle ambiguity self-test failed" }
        }
        foreach ($InvalidPhase in @(@("activate", "mutating"), @("activate", "activated"),
                @("revoke", "prepared"), @("revoke", "activated"), @("INSTALL", "intent"),
                @("install", "INTENT"))) {
            $InvalidRejected = $false
            try { Write-Transaction $TransactionPath $TransactionId $InvalidPhase[0] $InvalidPhase[1] 7 "-" }
            catch { $InvalidRejected = $_.Exception.Message -eq "invalid_transaction" }
            if (-not $InvalidRejected) { throw "operation exact transaction phase self-test failed" }
        }
        $MismatchedDrainPath = Join-Path $StateRoot "mismatched.drain"
        Write-DrainMarker $MismatchedDrainPath "install" ("transaction-" + ("f" * 32)) 7
        $MismatchedDrain = Read-DrainMarker $MismatchedDrainPath
        if ($MismatchedDrain.'transaction-id' -ceq $TransactionId -or
            (Test-LifecycleDrainBinding $Observed $MismatchedDrain) -or
            (Get-LifecycleRecoveryAction "prepared" "install" $false $true $false "none" $false) -cne
                "recovery-required" -or
            (Get-Sha256Bytes ([IO.File]::ReadAllBytes($DrainPath))) -cne $DrainDigestBefore) {
            throw "unrelated drain preservation self-test failed"
        }
        $MissingRollbackRoot = Join-Path $StateRoot "missing-rollback"; [void][IO.Directory]::CreateDirectory($MissingRollbackRoot)
        $MissingRollbackRejected = $false
        try { [void](Get-LifecycleRollbackSetSha256 $MissingRollbackRoot) }
        catch { $MissingRollbackRejected = $_.Exception.Message -eq "rollback_metadata_missing" }
        if (-not $MissingRollbackRejected) { throw "missing rollback member self-test failed" }
        Write-AtomicAscii (Join-Path $MissingRollbackRoot "legacy.meta") @(
            "rollback-file|1", "state|absent", "end-file|")
        $LegacyRollbackRejected = $false
        try { [void](Get-RollbackFileState $MissingRollbackRoot "legacy") }
        catch { $LegacyRollbackRejected = $_.Exception.Message -eq "invalid_rollback_file" }
        if (-not $LegacyRollbackRejected) { throw "ACL-free rollback metadata self-test failed" }
        $ActivationRollbackLabels = @(Get-ActivationRollbackLabels)
        if ($ActivationRollbackLabels.Count -ne 4 -or $ActivationRollbackLabels -contains "drain" -or
            @($ActivationRollbackLabels | Select-Object -Unique).Count -ne 4) {
            throw "activation rollback schema self-test failed"
        }
        $ActivationSchemaRoot = Join-Path $StateRoot "activation-rollback-schema"
        $ActivationSchemaSources = Join-Path $StateRoot "activation-rollback-sources"
        [void][IO.Directory]::CreateDirectory($ActivationSchemaRoot)
        [void][IO.Directory]::CreateDirectory($ActivationSchemaSources)
        foreach ($Label in $ActivationRollbackLabels) {
            $Source = Join-Path $ActivationSchemaSources $Label
            if ($Label -cne "native-canary-evidence") {
                Write-AtomicAscii $Source @("fixture|$Label")
            }
            Save-RollbackFile $Source $ActivationSchemaRoot $Label
        }
        $ActivationSchemaTransaction = [pscustomobject]@{
            'transaction-id' = "transaction-" + ("a" * 32)
            epoch = "7"
            'prior-pointer-sha256' = "b" * 64
        }
        Write-ActivationRecoverySnapshot (Join-Path $ActivationSchemaRoot "activation.snapshot") `
            $ActivationSchemaTransaction.'transaction-id' 7 `
            $ActivationSchemaTransaction.'prior-pointer-sha256' $ActivationSchemaRoot
        Assert-ActivationRollbackSchema $ActivationSchemaRoot
        [void](Read-ActivationRecoverySnapshot (Join-Path $ActivationSchemaRoot "activation.snapshot") `
            $ActivationSchemaTransaction $ActivationSchemaRoot)
        Write-AtomicAscii (Join-Path $ActivationSchemaRoot "unexpected.meta") @("fixture|unexpected")
        $ActivationExtraRejected = $false
        try { Assert-ActivationRollbackSchema $ActivationSchemaRoot }
        catch { $ActivationExtraRejected = $_.Exception.Message -eq "activation_rollback_schema_drift" }
        if (-not $ActivationExtraRejected) { throw "activation rollback extra member self-test failed" }
        [IO.File]::Delete((Join-Path $ActivationSchemaRoot "unexpected.meta"))
        [IO.Directory]::Delete($ActivationSchemaRoot, $true)
        [IO.Directory]::Delete($ActivationSchemaSources, $true)
        $DirectoryFixturePath = Join-Path $StateRoot "directory-snapshot.fixture"
        $DirectoryFixturePublic = Join-Path $Root "directory-public-fixture"
        Write-LifecycleDirectorySnapshot $DirectoryFixturePath $Root $StateRoot $DirectoryFixturePublic
        $DirectoryFixture = Read-LifecycleDirectorySnapshot $DirectoryFixturePath $Root $StateRoot $DirectoryFixturePublic
        if ($DirectoryFixture.Count -ne 19 -or $DirectoryFixture.root.State -cne "present" -or
            $DirectoryFixture.public.State -cne "absent") { throw "directory snapshot self-test failed" }
        $DirectoryFixtureText = $script:Ascii.GetString([IO.File]::ReadAllBytes($DirectoryFixturePath))
        [IO.File]::WriteAllBytes($DirectoryFixturePath, $script:Ascii.GetBytes(
                $DirectoryFixtureText.Replace("directory|entry|", "directory|entry-drift|")))
        $DirectoryDriftRejected = $false
        try { [void](Read-LifecycleDirectorySnapshot $DirectoryFixturePath $Root $StateRoot $DirectoryFixturePublic) }
        catch { $DirectoryDriftRejected = $_.Exception.Message -eq "directory_snapshot_drift" }
        if (-not $DirectoryDriftRejected) { throw "directory snapshot drift self-test failed" }
        [IO.File]::Delete($DirectoryFixturePath)

        $FixtureSourceArgument = "https://example.invalid/catalog"
        $FixtureSourceArgumentDigest = Get-Sha256Utf8Text $FixtureSourceArgument
        $FixtureStateIdentifier = "roundhouse-e7-" + ("d" * 64)
        $FixtureProvisionContext = Read-WinGetProvisionContext (ConvertTo-CanonicalAsciiBytes @(
            "winget-provider-context|1", "state-identifier|$FixtureStateIdentifier",
            "source-id|catalog-id", "source-name|catalog-name", "source-type|Microsoft.PreIndexed.Package",
            "source-argument|$FixtureSourceArgument", "source-argument-sha256|$FixtureSourceArgumentDigest",
            "source-origin|predefined", "source-trust|trusted", "source-explicit|true",
            "source-last-update-min-unix|1700000000", "deployment-file-set-sha256|$('b' * 64)",
            "app-installer-identity-sha256|$('c' * 64)", "end-context|"))
        $ExplicitDefaultPortRejected = $false
        $ExplicitDefaultPort = "https://example.invalid:443/catalog"
        try {
            [void](Read-WinGetProvisionContext (ConvertTo-CanonicalAsciiBytes @(
                "winget-provider-context|1", "state-identifier|$FixtureStateIdentifier",
                "source-id|catalog-id", "source-name|catalog-name", "source-type|Microsoft.PreIndexed.Package",
                "source-argument|$ExplicitDefaultPort", "source-argument-sha256|$(Get-Sha256Utf8Text $ExplicitDefaultPort)",
                "source-origin|predefined", "source-trust|trusted", "source-explicit|true",
                "source-last-update-min-unix|1700000000", "deployment-file-set-sha256|$('b' * 64)",
                "app-installer-identity-sha256|$('c' * 64)", "end-context|")))
        } catch { $ExplicitDefaultPortRejected = $_.Exception.Message -eq "invalid_winget_provider_context" }
        if (-not $ExplicitDefaultPortRejected) { throw "WinGet explicit-default-port self-test failed" }
        $FixtureProvisionMarker = Get-WinGetProvisionRequestBytes $Manifest $GenerationDigest
        $FixtureProvisionLines = ConvertFrom-CanonicalAsciiBytes $FixtureProvisionMarker 2048 "fixture_provision"
        if ($FixtureProvisionLines.Count -ne 8 -or $FixtureProvisionLines[0] -cne "winget-provider-provision-request|1") {
            throw "WinGet provision marker self-test failed"
        }
        $FixtureProvisionPaths = Get-WinGetProvisionPaths $StateRoot $Manifest.Epoch $GenerationDigest
        Assert-WinGetProvisionEvidenceAbsent $FixtureProvisionPaths $Root "fixture" -Fixture
        [void][IO.Directory]::CreateDirectory($FixtureProvisionPaths.Marker)
        $MarkerCollisionRejected = $false
        try { Assert-WinGetProvisionEvidenceAbsent $FixtureProvisionPaths $Root "fixture" -Fixture }
        catch { $MarkerCollisionRejected = $_.Exception.Message -eq "winget_provision_evidence_path_drift" }
        if (-not $MarkerCollisionRejected) { throw "WinGet provision marker collision self-test failed" }
        [IO.Directory]::Delete($FixtureProvisionPaths.Marker, $true)
        Write-AtomicBytes $FixtureProvisionPaths.Marker $FixtureProvisionMarker
        $MarkerReplayRejected = $false
        try { Assert-WinGetProvisionEvidenceAbsent $FixtureProvisionPaths $Root "fixture" -Fixture }
        catch { $MarkerReplayRejected = $_.Exception.Message -eq "winget_provider_provision_recovery_required" }
        if (-not $MarkerReplayRejected) { throw "WinGet provision marker replay self-test failed" }
        [IO.File]::Delete($FixtureProvisionPaths.Marker)
        $FixtureSourceLine = "source|catalog-id|catalog-name|Microsoft.PreIndexed.Package|$FixtureSourceArgumentDigest|" +
            "predefined|trusted|true|1700000000"
        $FixtureCompletedProvisionBytes = ConvertTo-CanonicalAsciiBytes @(
            "winget-provider-provision-result|1", "state|completed", "reason|provider_state_provisioned",
            "enrollment-epoch|7", "generation-sha256|$GenerationDigest", "provider-lock-sha256|$('b' * 64)",
            "deployment-file-set-sha256|$('b' * 64)", "app-installer-identity-sha256|$('c' * 64)",
            "provider-version|1.29.280", "state-identifier-sha256|$(Get-Sha256Utf8Text $FixtureStateIdentifier)",
            "provider-runtime-roots-sha256|$('e' * 64)", "settings-sha256|$(Get-WinGetProvisionSettingsSha256)",
            $FixtureSourceLine, "end-provision-result|")
        $FixtureCompletedProvision = Read-WinGetProvisionReceipt $FixtureCompletedProvisionBytes $Manifest `
            $GenerationDigest $FixtureProvisionContext
        if ((Get-WinGetProvisionDisposition $FixtureCompletedProvision) -cne "continue") {
            throw "WinGet completed provision self-test failed"
        }
        $FixtureModuleProvision = Read-WinGetProvisionReceipt (ConvertTo-CanonicalAsciiBytes @(
            "winget-provider-provision-result|1", "state|completed", "reason|module_state_verified",
            "enrollment-epoch|7", "generation-sha256|$GenerationDigest", "provider-lock-sha256|$('b' * 64)",
            "deployment-file-set-sha256|$('b' * 64)", "app-installer-identity-sha256|$('c' * 64)",
            "provider-version|1.29.280", "state-identifier-sha256|-",
            "provider-runtime-roots-sha256|$('b' * 64)", "settings-sha256|-",
            $FixtureSourceLine, "end-provision-result|")) $Manifest $GenerationDigest $FixtureProvisionContext
        if ((Get-WinGetProvisionDisposition $FixtureModuleProvision) -cne "continue") {
            throw "WinGet module provision self-test failed"
        }
        foreach ($StateCase in @("rejected", "partial")) {
            $FixtureNonterminalProvision = Read-WinGetProvisionReceipt (ConvertTo-CanonicalAsciiBytes @(
                "winget-provider-provision-result|1", "state|$StateCase", "reason|provider_state_$StateCase",
                "enrollment-epoch|7", "generation-sha256|-", "provider-lock-sha256|-",
                "deployment-file-set-sha256|-", "app-installer-identity-sha256|-", "provider-version|-",
                "state-identifier-sha256|-", "provider-runtime-roots-sha256|-", "settings-sha256|-",
                "source|-|-|-|-|-|-|-|-", "end-provision-result|")) $Manifest $GenerationDigest $FixtureProvisionContext
            $ExpectedDisposition = if ($StateCase -ceq "rejected") { "rollback" } else { "preserve" }
            if ((Get-WinGetProvisionDisposition $FixtureNonterminalProvision) -cne $ExpectedDisposition) {
                throw "WinGet $StateCase provision self-test failed"
            }
        }
        Write-AtomicBytes $FixtureProvisionPaths.Claim $FixtureProvisionMarker
        Write-AtomicBytes $FixtureProvisionPaths.Receipt $FixtureCompletedProvisionBytes
        [void](Assert-CompletedWinGetProvision $Root $FixtureProvisionPaths $FixtureProvisionMarker $Manifest `
            $GenerationDigest $FixtureProvisionContext "fixture" -Fixture)
        $CompletedReplayRejected = $false
        try { Assert-WinGetProvisionEvidenceAbsent $FixtureProvisionPaths $Root "fixture" -Fixture }
        catch { $CompletedReplayRejected = $_.Exception.Message -eq "winget_provider_provision_recovery_required" }
        if (-not $CompletedReplayRejected) { throw "WinGet completed provision replay self-test failed" }
        # Fixture fault recovery restores the byte-for-byte prior pointer.
        $Pointer = ConvertTo-CanonicalAsciiBytes @("roundhouse-active-generation|1", "epoch|6",
            "generation-sha256|$('d' * 64)", "end-generation|")
        $PointerPath = Join-Path $Root "active.generation"; [IO.File]::WriteAllBytes($PointerPath, $Pointer)
        $Backup = [IO.File]::ReadAllBytes($PointerPath)
        Write-AtomicAscii $PointerPath @("roundhouse-active-generation|1", "epoch|7",
            "generation-sha256|$GenerationDigest", "end-generation|")
        Write-AtomicBytes $PointerPath $Backup
        if ((Get-Sha256Bytes ([IO.File]::ReadAllBytes($PointerPath))) -cne (Get-Sha256Bytes $Pointer)) {
            throw "transaction rollback self-test failed"
        }
        $PublicRoot = Join-Path $Root "public"
        Write-PublicReadiness $PublicRoot "needs_native_canary" $Manifest $Digest $GenerationDigest "disabled" $true $true `
            -RequestSid "S-1-5-21-1-2-3-2001"
        if ([IO.File]::Exists((Join-Path $PublicRoot "readiness"))) {
            throw "static public readiness retirement self-test failed"
        }

        $BadReceipt = @($ReceiptBytes.Clone()); $BadReceipt[0] = 0
        $Rejected = $false
        try { [void](Read-BootstrapReceipt $BadReceipt $StageRoot) } catch { $Rejected = $true }
        if (-not $Rejected) { throw "bootstrap corruption self-test failed" }
        $CanaryNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $ChallengeBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-native-canary-challenge|1", "nonce|$('9' * 64)",
            "host|$([Environment]::MachineName.ToUpperInvariant())", "epoch|7",
            "generation-sha256|$GenerationDigest",
            "runner-path-sha256|$(Get-Sha256Utf8Text $Receipt.'native-canary-runner-path'.ToUpperInvariant())",
            "runner-sha256|$($Receipt.'native-canary-runner-sha256')",
            "runner-publisher-thumbprint|$($Receipt.'native-canary-publisher-thumbprint')",
            "issued-at|$CanaryNow", "expires-at|$($CanaryNow + 600)",
            "clock-skew-bound-seconds|300", "end-challenge|")
        $Challenge = Read-NativeCanaryChallenge $ChallengeBytes $Manifest $GenerationDigest $Receipt
        $CanaryConfirmation = Get-NativeCanaryConfirmation $Challenge
        [byte[]]$RawCanaryEvidence = ConvertTo-CanonicalAsciiBytes @(
            "windows-native-canary-evidence|1", "record|fixture", "end-evidence|")
        $CanaryAccess = Get-NativeCanaryAccessContract "S-1-5-21-1-2-3-1200"
        $CanaryBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-native-canary-receipt|3", "nonce|$($Challenge.Fields.nonce)",
            "host|$($Challenge.Fields.host)", "epoch|7", "generation-sha256|$GenerationDigest",
            "runner-path-sha256|$($Challenge.Fields.'runner-path-sha256')",
            "runner-sha256|$($Receipt.'native-canary-runner-sha256')",
            "runner-publisher-thumbprint|$($Receipt.'native-canary-publisher-thumbprint')",
            "issued-at|$CanaryNow", "expires-at|$($CanaryNow + 300)",
            "human-preview-sha256|$(Get-Sha256Utf8Text (Get-NativeCanaryPreview $Challenge))",
            "human-confirmation-sha256|$(Get-Sha256Utf8Text $CanaryConfirmation)",
            "clock-skew-bound-seconds|300", "request-sid|$($CanaryAccess.RequestSid)",
            "chroot-path-sha256|$($CanaryAccess.ChrootPathSha256)",
            "chroot-directory-sddl-sha256|$($CanaryAccess.ChrootDirectorySddlSha256)",
            "slot-directory-sddl-sha256|$($CanaryAccess.SlotDirectorySddlSha256)",
            "slot-file-sddl-sha256|$($CanaryAccess.SlotFileSddlSha256)",
            "results-directory-sddl-sha256|$($CanaryAccess.ResultsDirectorySddlSha256)",
            "result-file-sddl-sha256|$($CanaryAccess.ResultFileSddlSha256)",
            "system-task-logged-off|passed", "profile-task-logged-off|passed", "profile-token-limited|passed",
            "profile-no-network|passed", "profile-authenticated-smb-denied|passed",
            "profile-efs-capability|supported", "profile-efs-denied|passed",
            "chroot-physical-layout|passed", "chroot-effective-access|passed", "slot-write-data-only|passed",
            "slot-create-list-rename-denied|passed", "slot-owner-rights|passed", "slot-quota|passed",
            "result-read-only|passed", "result-non-list|passed", "request-no-task-rights|passed",
            "claim-copy-race|passed", "openssh-y-verify|passed", "openssh-print-pubkey|passed",
            "openssh-certificate-parse|passed", "winget-system-inventory|passed", "winget-corrupt-hash|passed",
            "winget-dangerous-options|passed", "profile-path-containment|passed",
            "authoritative-result|passed", "reboot-recovery|passed",
            "raw-evidence-sha256|$(Get-Sha256Bytes $RawCanaryEvidence)", "end-canary|")
        [void](Read-NativeCanaryReceipt $CanaryBytes ([byte[]]@(1)) $RawCanaryEvidence $Manifest `
            $GenerationDigest $Challenge $Receipt $CanaryConfirmation -Fixture)
        $CanarySignatureFixture = [byte[]]@(1, 2, 3)
        $CanaryPublicationBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-native-canary-publication|1", "nonce|$($Challenge.Fields.nonce)",
            "receipt-sha256|$(Get-Sha256Bytes $CanaryBytes)",
            "signature-sha256|$(Get-Sha256Bytes $CanarySignatureFixture)",
            "evidence-sha256|$(Get-Sha256Bytes $RawCanaryEvidence)", "end-publication|")
        [void](Read-NativeCanaryPublication $CanaryPublicationBytes $Challenge.Fields.nonce `
            $CanaryBytes $CanarySignatureFixture $RawCanaryEvidence)
        $BadPublicationRejected = $false
        try {
            [void](Read-NativeCanaryPublication $CanaryPublicationBytes $Challenge.Fields.nonce `
                $BadReceipt $CanarySignatureFixture $RawCanaryEvidence)
        } catch { $BadPublicationRejected = $_.Exception.Message -eq "native_canary_publication_drift" }
        if (-not $BadPublicationRejected) { throw "native canary publication self-test failed" }
        $ConsumedBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-native-canary-consumed|1", "nonce|$($Challenge.Fields.nonce)",
            "receipt-sha256|$(Get-Sha256Bytes $CanaryBytes)", "end-consumed|")
        [void](Read-NativeCanaryConsumed $ConsumedBytes $Challenge.Fields.nonce `
            (Get-Sha256Bytes $CanaryBytes))
        $BadCanary = $script:Ascii.GetBytes(($script:Ascii.GetString($CanaryBytes)).Replace(
            "winget-corrupt-hash|passed", "winget-corrupt-hash|failed"))
        $CanaryRejected = $false
        try { [void](Read-NativeCanaryReceipt $BadCanary ([byte[]]@(1)) $RawCanaryEvidence $Manifest `
                $GenerationDigest $Challenge $Receipt $CanaryConfirmation -Fixture) } catch { $CanaryRejected = $true }
        if (-not $CanaryRejected) { throw "native canary gate self-test failed" }
        $BadEfsCanary = $script:Ascii.GetBytes(($script:Ascii.GetString($CanaryBytes)).Replace(
            "profile-efs-capability|supported", "profile-efs-capability|not-supported"))
        $BadEfsRejected = $false
        try { [void](Read-NativeCanaryReceipt $BadEfsCanary ([byte[]]@(1)) $RawCanaryEvidence $Manifest `
                $GenerationDigest $Challenge $Receipt $CanaryConfirmation -Fixture) } catch { $BadEfsRejected = $true }
        if (-not $BadEfsRejected) { throw "EFS native canary self-test failed" }
        $NonCanonicalEfsCanary = $script:Ascii.GetBytes(($script:Ascii.GetString($CanaryBytes)).Replace(
            "profile-efs-capability|supported", "profile-efs-capability|SUPPORTED"))
        $NonCanonicalEfsRejected = $false
        try { [void](Read-NativeCanaryReceipt $NonCanonicalEfsCanary ([byte[]]@(1)) $RawCanaryEvidence `
                $Manifest $GenerationDigest $Challenge $Receipt $CanaryConfirmation -Fixture) } catch {
            $NonCanonicalEfsRejected = $true
        }
        if (-not $NonCanonicalEfsRejected) { throw "noncanonical EFS native canary self-test failed" }
        Write-Output "PASS: enroll-privilege-windows fixture-safe self-check"
    } finally {
        $script:SelfTestFixture = $false
        if ([IO.Directory]::Exists($Root)) { [IO.Directory]::Delete($Root, $true) }
    }
}

if ($SelfTest) { Invoke-SelfTest; return }

$ProgramData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($ProgramData)) { throw "unsupported_context" }
$Root = Join-Path $ProgramData "Roundhouse"
$PublicRoot = Join-Path $ProgramData "Roundhouse-Public"
$BootstrapRoot = Join-Path $ProgramData "Roundhouse-Bootstrap"
$StageRoot = Join-Path $BootstrapRoot "staged"
$ManifestPath = Join-Path $StageRoot "enrollment.manifest"
$ReleaseFilesPath = Join-Path $StageRoot "release.files"
$BootstrapReceiptPath = Join-Path $BootstrapRoot "bootstrap.receipt"
$BootstrapVerifierPath = Join-Path $BootstrapRoot "bootstrap-verifier.ps1"

if ($Status) {
    throw "authenticated_readiness_control_required"
}

$PhysicalProjectionPaths = Get-ChrootProjectionPaths $Root $PublicRoot
if (-not [IO.Path]::GetFullPath($PhysicalProjectionPaths.Chroot).Equals(
        "C:\ProgramData\Roundhouse\chroot", [StringComparison]::OrdinalIgnoreCase)) {
    throw "unsupported_chroot_path"
}

Assert-ElevatedHumanContext
if (-not [IO.File]::Exists($BootstrapReceiptPath) -or -not [IO.File]::Exists($BootstrapVerifierPath) -or
    -not [IO.File]::Exists($ManifestPath) -or
    -not [IO.File]::Exists($ReleaseFilesPath)) { throw "authenticated_bootstrap_required" }
foreach ($Path in @($BootstrapRoot, $StageRoot, $BootstrapReceiptPath, $BootstrapVerifierPath, $ManifestPath, $ReleaseFilesPath)) {
    Assert-ProtectedWindowsPath $Path $BootstrapRoot
}
$ManifestBytes = Read-HeldBytes $ManifestPath 8192
$Receipt = Read-BootstrapReceipt (Read-HeldBytes $BootstrapReceiptPath 4096) $StageRoot
$ExpectedEnrollmentEntrypoint = Join-Path $StageRoot "scripts/enroll-privilege-windows.ps1"
if (-not [IO.Path]::GetFullPath($PSCommandPath).Equals([IO.Path]::GetFullPath($ExpectedEnrollmentEntrypoint),
        [StringComparison]::OrdinalIgnoreCase)) { throw "bootstrap_entrypoint_path_mismatch" }
Assert-ProtectedWindowsPath $PSCommandPath $BootstrapRoot
if ((Get-Sha256Bytes (Read-HeldBytes $PSCommandPath 4194304)) -cne $Receipt.'protected-copy-sha256') {
    throw "bootstrap_entrypoint_digest_mismatch"
}
if ((Get-Sha256Bytes (Read-HeldBytes $BootstrapVerifierPath 4194304)) -cne $Receipt.'bootstrap-verifier-sha256') {
    throw "bootstrap_verifier_digest_mismatch"
}
if ((Get-Sha256Bytes $ManifestBytes) -cne $Receipt.'manifest-sha256') { throw "bootstrap_manifest_mismatch" }
$Manifest = Read-EnrollmentManifest $ManifestBytes
$ReleaseFilesBytes = Read-HeldBytes $ReleaseFilesPath 1048576
$ReleaseFiles = Read-ReleaseFiles $ReleaseFilesBytes
if ($ReleaseFiles.Digest -cne $Manifest.Fields.'file-set-sha256') { throw "release_file_set_mismatch" }
Assert-AuthenticodePublisher $PSCommandPath $Receipt.'publisher-thumbprint'
Assert-AuthenticodePublisher $BootstrapVerifierPath $Receipt.'publisher-thumbprint'

$ManifestDigest = Get-Sha256Bytes $ManifestBytes
$HostName = [Environment]::MachineName.ToUpperInvariant()
if ($Preview) {
    [pscustomobject][ordered]@{
        operation = "install"; host = $HostName; epoch = $Manifest.Epoch
        target_profile_sid = $Manifest.Fields.'target-profile-sid'; broker_version = $script:BrokerVersion
        request_account = $script:RequestAccountName; request_account_initial_state = "disabled"
        system_context = "LocalSystem"; profile_context = "S4U LeastPrivilege"
        transport_activation = "not-performed-by-U3"; transport_ready = $false
        native_canary = "required-on-recoverable-Windows-host"
        confirmation = Get-ConfirmationText "install" $HostName $Manifest.Epoch $ManifestDigest
    } | ConvertTo-Json -Depth 5
    return
}

$StateRoot = Join-Path $Root "state"
$PointerPath = Join-Path $Root "active.generation"
if ($ActivateNativeCanary) {
    $ActivationLock = Acquire-LifecycleLock (Join-Path $StateRoot "broker.lock")
    try {
    $ActivationAcl = Get-AclBlueprint "S-1-5-18" $Manifest.Fields.'target-profile-sid'
    $ResolvedTransaction = Resolve-ExistingLifecycleTransaction $Root $StateRoot $PublicRoot $Manifest `
        $ActivationAcl $Receipt
    if ($null -ne $ResolvedTransaction -and $ResolvedTransaction.operation -ceq "activate" -and
        $ResolvedTransaction.phase -ceq "committed") { return }
    if ([IO.File]::Exists((Join-Path $StateRoot "drain"))) {
        Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $ActivationAcl.PublicDirectory
        throw "lifecycle_recovery_required"
    }
    foreach ($Path in @($Root, $StateRoot, $PointerPath)) { Assert-ProtectedWindowsPath $Path $Root }
    $Pointer = Read-ActivePointer (Read-HeldBytes $PointerPath 160)
    $GenerationRoot = Join-Path (Join-Path $Root "generations") ([string]$Manifest.Epoch)
    $OpenSshIdentityPath = Join-Path $GenerationRoot "openssh.identity"
    [void](Assert-SystemOpenSshIdentity $OpenSshIdentityPath $Root)
    $OpenSshIdentityDigest = Get-Sha256Bytes (Read-HeldBytes $OpenSshIdentityPath 4096)
    $GenerationDigest = Get-GenerationDigest $Manifest $OpenSshIdentityDigest
    if ($Pointer.epoch -cne [string]$Manifest.Epoch -or $Pointer.'generation-sha256' -cne $GenerationDigest) {
        throw "active_generation_mismatch"
    }
    foreach ($Binding in @(
        @("policy.actions", $Manifest.Fields.'policy-sha256'),
        @("policy.constraints", $Manifest.Fields.'constraints-sha256'),
        @("winget.context", $Manifest.Fields.'winget-context-sha256'),
        @("windows-winget-provider.lock", $Manifest.Fields.'provider-lock-sha256'))) {
        $Path = Join-Path $GenerationRoot $Binding[0]
        Assert-ProtectedWindowsPath $Path $Root
        if ((Get-Sha256Bytes (Read-HeldBytes $Path 4194304)) -cne $Binding[1]) { throw "generation_binding_mismatch" }
    }
    $Account = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    if ($Account.Enabled) { throw "request_account_must_remain_disabled" }
    $RequestSid = [string]$Account.Sid.Value
    $Acl = Get-AclBlueprint $RequestSid $Manifest.Fields.'target-profile-sid'
    $ProvisionMarkerBytes = Get-WinGetProvisionRequestBytes $Manifest $GenerationDigest
    $ProvisionPaths = Get-WinGetProvisionPaths $StateRoot $Manifest.Epoch $GenerationDigest
    $ProvisionContext = Read-WinGetProvisionContext (Read-HeldBytes (Join-Path $GenerationRoot "winget.context") 16384)
    [void](Assert-CompletedWinGetProvision $Root $ProvisionPaths $ProvisionMarkerBytes $Manifest `
        $GenerationDigest $ProvisionContext $Acl.ProtectedFile)
    Assert-ChrootProjection $Root $PublicRoot $Acl -RequireLegacyAbsent
    foreach ($Directory in @((Join-Path $Root "generations"), $StateRoot, (Join-Path $Root "profile"))) {
        Assert-PathSddl $Directory $Acl.ProtectedDirectory
    }
    Assert-PathSddl $Root $Acl.ProtectedTraverseDirectory
    Assert-PathSddl (Join-Path $Root "entry") $Acl.ProtectedTraverseDirectory
    Assert-PathSddl (Join-Path $Root "profile/handoff") $Acl.ProtectedTraverseDirectory
    Assert-PathSddl $PublicRoot $Acl.PublicDirectory
    foreach ($Name in @("privilege-broker-windows.ps1", "enroll-privilege-windows.ps1",
        "register-profile-task-windows.ps1")) {
        Assert-PathSddl (Join-Path $Root "entry/$Name") $Acl.ProtectedFile
    }
    Assert-PathSddl (Join-Path $Root "entry/profile-worker-windows.ps1") $Acl.ProfileWorkerFile
    Assert-PathSddl $PointerPath $Acl.ProtectedFile
    Assert-PathSddl (Join-Path $StateRoot "broker.lock") $Acl.ProtectedFile
    foreach ($Directory in @($GenerationRoot) + @([IO.Directory]::EnumerateDirectories(
        $GenerationRoot, "*", [IO.SearchOption]::AllDirectories))) {
        Assert-PathSddl $Directory $Acl.ProtectedDirectory
    }
    foreach ($FilePath in @([IO.Directory]::EnumerateFiles($GenerationRoot, "*", [IO.SearchOption]::AllDirectories))) {
        Assert-PathSddl $FilePath $Acl.ProtectedFile
    }
    Assert-PathSddl (Join-Path $StateRoot "enrollment.mutations") $Acl.ProtectedFile
    Assert-FixedSlotQuota $ProgramData $script:RequestAccountName $RequestSid
    $PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
    Assert-TaskContract (Export-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\") "system" "S-1-5-18" `
        $ProgramData $PowerShellPath
    Assert-TaskContract (Export-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\") "profile" `
        $Manifest.Fields.'target-profile-sid' $ProgramData $PowerShellPath
    Assert-ProtectedTaskSecurity $script:SystemTaskName
    Assert-ProtectedTaskSecurity $script:ProfileTaskName
    $RunnerPath = [string]$Receipt.'native-canary-runner-path'
    if (-not [IO.File]::Exists($RunnerPath) -or
        (Get-Sha256Bytes (Read-HeldBytes $RunnerPath 4194304)) -cne $Receipt.'native-canary-runner-sha256') {
        throw "native_canary_runner_identity_drift"
    }
    Assert-AuthenticodePublisher $RunnerPath $Receipt.'native-canary-publisher-thumbprint'
    $ChallengePath = Join-Path $StateRoot "native-canary.challenge"
    Assert-ProtectedWindowsPath $ChallengePath $Root
    Assert-PathSddl $ChallengePath $Acl.ProtectedFile
    $ChallengeBytes = Read-HeldBytes $ChallengePath 4096
    $Challenge = Read-NativeCanaryChallenge $ChallengeBytes $Manifest $GenerationDigest $Receipt
    $ReceiptRoot = [string]$Receipt.'native-canary-receipt-root'
    Assert-ProtectedWindowsPath $ReceiptRoot $ReceiptRoot
    Assert-PathSddl $ReceiptRoot $Acl.ProtectedDirectory
    $ReceiptStem = Join-Path $ReceiptRoot ("receipt-" + $Challenge.Fields.nonce)
    $CanaryReceiptPath = $ReceiptStem + ".receipt"
    $CanarySignaturePath = $ReceiptStem + ".p7s"
    $CanaryEvidencePath = $ReceiptStem + ".evidence"
    $CanaryPublicationPath = $ReceiptStem + ".publication"
    $CanaryConsumedPath = $ReceiptStem + ".consumed"
    if ([IO.File]::Exists($CanaryConsumedPath) -or [IO.Directory]::Exists($CanaryConsumedPath)) {
        throw "native_canary_nonce_consumed"
    }
    foreach ($Path in @($CanaryReceiptPath, $CanarySignaturePath, $CanaryEvidencePath,
            $CanaryPublicationPath)) {
        Assert-ProtectedWindowsPath $Path $ReceiptRoot
        Assert-PathSddl $Path $Acl.ProtectedFile
    }
    $CanaryBytes = Read-HeldBytes $CanaryReceiptPath 16384
    $CanarySignatureBytes = Read-HeldBytes $CanarySignaturePath 65536
    $CanaryEvidenceBytes = Read-HeldBytes $CanaryEvidencePath 1048576
    $CanaryPublicationBytes = Read-HeldBytes $CanaryPublicationPath 4096
    [void](Read-NativeCanaryPublication $CanaryPublicationBytes $Challenge.Fields.nonce `
        $CanaryBytes $CanarySignatureBytes $CanaryEvidenceBytes)
    [void](Read-NativeCanaryReceipt $CanaryBytes $CanarySignatureBytes $CanaryEvidenceBytes $Manifest `
        $GenerationDigest $Challenge $Receipt $Confirmation $RequestSid)
    $TransactionRoot = Join-Path $StateRoot "rollback"; [void][IO.Directory]::CreateDirectory($TransactionRoot)
    Assert-ProtectedWindowsPath $TransactionRoot $Root
    Assert-PathSddl $TransactionRoot $Acl.ProtectedDirectory
    $TransactionId = "transaction-" + [Guid]::NewGuid().ToString("N")
    $TransactionPath = Join-Path $StateRoot "lifecycle.transaction"
    $ActivationPriorDigest = Get-Sha256Bytes (Read-HeldBytes $PointerPath 160)
    Write-Transaction $TransactionPath $TransactionId "activate" "intent" $Manifest.Epoch $ActivationPriorDigest
    Set-PathSddl $TransactionPath $Acl.ProtectedFile
    Assert-PathSddl $TransactionPath $Acl.ProtectedFile
    $RollbackRoot = Join-Path $TransactionRoot $TransactionId; [void][IO.Directory]::CreateDirectory($RollbackRoot)
    Set-PathSddl $RollbackRoot $Acl.ProtectedDirectory
    Assert-PathSddl $RollbackRoot $Acl.ProtectedDirectory
    Save-RollbackFile (Join-Path $Root "native-canary.receipt") $RollbackRoot "native-canary"
    Save-RollbackFile (Join-Path $Root "native-canary.receipt.p7s") $RollbackRoot "native-canary-signature"
    Save-RollbackFile (Join-Path $Root "native-canary.evidence") $RollbackRoot "native-canary-evidence"
    Save-RollbackFile (Join-Path $PublicRoot "readiness") $RollbackRoot "public-readiness"
    Write-ActivationRecoverySnapshot (Join-Path $RollbackRoot "activation.snapshot") $TransactionId `
        $Manifest.Epoch $ActivationPriorDigest $RollbackRoot
    foreach ($RollbackFile in @([IO.Directory]::EnumerateFiles(
        $RollbackRoot, "*", [IO.SearchOption]::TopDirectoryOnly))) {
        Set-PathSddl $RollbackFile $Acl.ProtectedFile
        Assert-PathSddl $RollbackFile $Acl.ProtectedFile
    }
    Assert-ActivationRollbackSchema $RollbackRoot
    $ActivationSnapshotTransaction = [pscustomobject]@{
        'transaction-id' = $TransactionId
        epoch = [string]$Manifest.Epoch
        'prior-pointer-sha256' = $ActivationPriorDigest
    }
    [void](Read-ActivationRecoverySnapshot (Join-Path $RollbackRoot "activation.snapshot") `
        $ActivationSnapshotTransaction $RollbackRoot)
    try {
        Write-Transaction $TransactionPath $TransactionId "activate" "snapshotted" $Manifest.Epoch $ActivationPriorDigest
        Set-PathSddl $TransactionPath $Acl.ProtectedFile
        Assert-PathSddl $TransactionPath $Acl.ProtectedFile
        Write-AtomicBytes (Join-Path $Root "native-canary.receipt") $CanaryBytes
        Write-AtomicBytes (Join-Path $Root "native-canary.receipt.p7s") $CanarySignatureBytes
        Write-AtomicBytes (Join-Path $Root "native-canary.evidence") $CanaryEvidenceBytes
        Set-PathSddl (Join-Path $Root "native-canary.receipt") $Acl.ProtectedFile
        Set-PathSddl (Join-Path $Root "native-canary.receipt.p7s") $Acl.ProtectedFile
        Set-PathSddl (Join-Path $Root "native-canary.evidence") $Acl.ProtectedFile
        $BrokerDigest = Get-Sha256Bytes (Read-HeldBytes (Join-Path $Root "entry/privilege-broker-windows.ps1") 4194304)
        Write-PublicReadiness $PublicRoot "needs_transport_enrollment" $Manifest $BrokerDigest $GenerationDigest `
            "disabled" $true $true $true -RequestSid $RequestSid `
            -ContextCanaryDigest (Get-Sha256Bytes $CanaryBytes)
        Write-Transaction $TransactionPath $TransactionId "activate" "committed" $Manifest.Epoch `
            $ActivationPriorDigest
        Set-PathSddl $TransactionPath $Acl.ProtectedFile
        Assert-PathSddl $TransactionPath $Acl.ProtectedFile
        Complete-CommittedActivationFinalization (Read-Transaction $TransactionPath) $Root $StateRoot `
            $Manifest $Receipt $Acl
    } catch {
        $ActivationFailure = $_
        $ObservedActivationTransaction = $null
        try { $ObservedActivationTransaction = Read-Transaction $TransactionPath } catch { }
        if ($null -ne $ObservedActivationTransaction -and
            $ObservedActivationTransaction.'transaction-id' -ceq $TransactionId -and
            $ObservedActivationTransaction.operation -ceq "activate" -and
            $ObservedActivationTransaction.phase -ceq "committed") {
            # External consumed-marker/challenge cleanup happens after the local terminal state.
            # A cleanup fault must not roll that verified committed state back.
            try {
                Assert-PathSddl $TransactionPath $Acl.ProtectedFile
                Assert-TerminalLifecycleState $ObservedActivationTransaction $Root $StateRoot $PublicRoot
            } catch {
                Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $Acl.PublicDirectory
                throw "lifecycle_recovery_required"
            }
            throw $ActivationFailure
        }
        if ($null -eq $ObservedActivationTransaction -or
            $ObservedActivationTransaction.'transaction-id' -cne $TransactionId -or
            $ObservedActivationTransaction.operation -cne "activate" -or
            $ObservedActivationTransaction.phase -notin @("intent", "snapshotted")) {
            Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $Acl.PublicDirectory
            throw "lifecycle_recovery_required"
        }
        if ($ObservedActivationTransaction.phase -ceq "snapshotted") {
            Assert-ProtectedWindowsPath $RollbackRoot $Root
            Assert-PathSddl $RollbackRoot $Acl.ProtectedDirectory
            foreach ($RollbackFile in @([IO.Directory]::EnumerateFiles(
                $RollbackRoot, "*", [IO.SearchOption]::TopDirectoryOnly))) {
                Assert-ProtectedWindowsPath $RollbackFile $Root
                Assert-PathSddl $RollbackFile $Acl.ProtectedFile
            }
            Assert-ActivationRollbackSchema $RollbackRoot
            [void](Read-ActivationRecoverySnapshot (Join-Path $RollbackRoot "activation.snapshot") `
                $ObservedActivationTransaction $RollbackRoot)
            Restore-RollbackFile (Join-Path $Root "native-canary.receipt") $RollbackRoot "native-canary"
            Restore-RollbackFile (Join-Path $Root "native-canary.receipt.p7s") $RollbackRoot "native-canary-signature"
            Restore-RollbackFile (Join-Path $Root "native-canary.evidence") $RollbackRoot "native-canary-evidence"
            if ([IO.File]::Exists((Join-Path $Root "native-canary.receipt"))) {
                Set-PathSddl (Join-Path $Root "native-canary.receipt") $Acl.ProtectedFile
            }
            Restore-RollbackFile (Join-Path $PublicRoot "readiness") $RollbackRoot "public-readiness"
        }
        Write-Transaction $TransactionPath $TransactionId "activate" "rolled-back" $Manifest.Epoch `
            $ActivationPriorDigest
        Set-PathSddl $TransactionPath $Acl.ProtectedFile
        Assert-PathSddl $TransactionPath $Acl.ProtectedFile
        throw $ActivationFailure
    }
    } finally { $ActivationLock.Dispose() }
    return
}

$Operation = if ($Install) { "install" } else { "revoke" }
$ExpectedConfirmation = Get-ConfirmationText $Operation $HostName $Manifest.Epoch $ManifestDigest
if ($Confirmation -cne $ExpectedConfirmation) { throw "human_confirmation_mismatch" }
$TransactionRoot = Join-Path $StateRoot "rollback"
$TransactionId = "transaction-" + [Guid]::NewGuid().ToString("N")
$TransactionPath = Join-Path $StateRoot "lifecycle.transaction"
$RollbackRoot = Join-Path $TransactionRoot $TransactionId
$DrainPath = Join-Path $StateRoot "drain"
$NewGenerationCreated = $false
$AccountCreated = $false
$RevokeMoves = New-Object Collections.Generic.List[object]
$TargetRightsBefore = $null
$RequestRightsBefore = $null
$QuotaBefore = $null
$MutationRecord = $null
$Acl = $null
$LifecycleLock = $null
$PriorPointer = $null
$PriorDigest = "-"
$PriorSystemTaskXml = ""
$PriorProfileTaskXml = ""
$PriorSystemTaskSddl = ""
$PriorProfileTaskSddl = ""
$AccountWasPresent = $false
$AccountWasEnabled = $false
$GenerationRoot = $null
$GenerationStage = $null
$SnapshotsComplete = $false
$LifecycleStorageProtected = $false
$ProfileRegistration = $null
$ProfileConstraintRecords = @()
$ProvisionPaths = $null
$ProvisionMarkerBytes = $null
$ProvisionDisposition = $null
$ProvisionEvidencePreserved = $false
$PriorTransactionBytes = $null
$LifecycleAcl = Get-AclBlueprint "S-1-5-18" $Manifest.Fields.'target-profile-sid'

try {
    # No lifecycle evidence may be created beneath an ambient ProgramData ACL. Protect and
    # revalidate every ancestor plus the transaction record before writing drain or rollback data.
    # Preserve the enrolled root's target-profile traverse grant until the drain lock proves that
    # no profile task is still using it.
    if ([IO.Directory]::Exists($Root)) {
        Assert-ProtectedWindowsPath $Root $Root
        $RootAclAccepted = $false
        foreach ($ExpectedRootSddl in @($LifecycleAcl.ProtectedDirectory, $LifecycleAcl.ProtectedTraverseDirectory)) {
            try { Assert-PathSddl $Root $ExpectedRootSddl; $RootAclAccepted = $true; break } catch { }
        }
        if (-not $RootAclAccepted) { throw "lifecycle_root_acl_drift" }
    } else {
        Initialize-ProtectedLifecycleDirectory $Root $LifecycleAcl.ProtectedDirectory
    }
    foreach ($Directory in @($StateRoot, $TransactionRoot)) {
        Initialize-ProtectedLifecycleDirectory $Directory $LifecycleAcl.ProtectedDirectory
    }
    Initialize-ProtectedLifecycleFile $TransactionPath $LifecycleAcl.ProtectedFile
    Initialize-ProtectedLifecycleFile (Join-Path $StateRoot "broker.lock") $LifecycleAcl.ProtectedFile
    $LifecycleStorageProtected = $true
    $LifecycleLock = Acquire-LifecycleLock (Join-Path $StateRoot "broker.lock")
    [void](Resolve-ExistingLifecycleTransaction $Root $StateRoot $PublicRoot $Manifest $LifecycleAcl $Receipt)
    if ((Get-Item -LiteralPath $TransactionPath -Force).Length -gt 0) {
        $PriorTransactionBytes = Read-HeldBytes $TransactionPath 4096
    }
    $LifecycleLock.Dispose(); $LifecycleLock = $null
    Initialize-ProtectedLifecycleDirectory $RollbackRoot $LifecycleAcl.ProtectedDirectory
    if ([IO.File]::Exists($DrainPath)) {
        Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
        throw "lifecycle_recovery_required"
    }
    Save-RollbackFile $DrainPath $RollbackRoot "drain"
    Write-DrainMarker $DrainPath $Operation $TransactionId $Manifest.Epoch
    Set-PathSddl $DrainPath $LifecycleAcl.ProtectedFile
    Assert-PathSddl $DrainPath $LifecycleAcl.ProtectedFile
    $LifecycleLock = Acquire-LifecycleLock (Join-Path $StateRoot "broker.lock")
    Assert-ProtectedJournalsTerminal (Join-Path $StateRoot "replay") (Join-Path $StateRoot "audit")
    $PriorPointer = if ([IO.File]::Exists($PointerPath)) { [IO.File]::ReadAllBytes($PointerPath) } else { $null }
    $PriorDigest = if ($null -eq $PriorPointer) { "-" } else { Get-Sha256Bytes $PriorPointer }
    Write-Transaction $TransactionPath $TransactionId $Operation "intent" $Manifest.Epoch $PriorDigest
    Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    $PriorAccount = Get-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue
    $AccountWasPresent = $null -ne $PriorAccount
    $AccountWasEnabled = $AccountWasPresent -and [bool]$PriorAccount.Enabled
    $PriorSystemTask = Get-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\" -ErrorAction SilentlyContinue
    $PriorProfileTask = Get-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction SilentlyContinue
    $PriorSystemTaskXml = if ($null -eq $PriorSystemTask) { "" } else { Export-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\" }
    $PriorProfileTaskXml = if ($null -eq $PriorProfileTask) { "" } else { Export-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" }
    $PriorSystemTaskSddl = if ($null -eq $PriorSystemTask) { "" } else { Get-TaskSecurity $script:SystemTaskName }
    $PriorProfileTaskSddl = if ($null -eq $PriorProfileTask) { "" } else { Get-TaskSecurity $script:ProfileTaskName }
    foreach ($Snapshot in @(
        @($PointerPath, "active-pointer"),
        @((Join-Path $Root "entry/privilege-broker-windows.ps1"), "entry-broker"),
        @((Join-Path $Root "entry/profile-worker-windows.ps1"), "entry-profile"),
        @((Join-Path $Root "entry/enroll-privilege-windows.ps1"), "entry-enroll"),
        @((Join-Path $Root "entry/register-profile-task-windows.ps1"), "entry-register"),
        @((Join-Path $StateRoot "enrollment.mutations"), "enrollment-mutations"),
        @((Join-Path $PublicRoot "policy.actions"), "public-policy"),
        @((Join-Path $PublicRoot "policy.constraints"), "public-constraints"),
        @((Join-Path $PublicRoot "readiness"), "public-readiness"),
        @((Join-Path $Root "native-canary.receipt"), "native-canary"),
        @((Join-Path $Root "native-canary.receipt.p7s"), "native-canary-signature"),
        @((Join-Path $Root "native-canary.evidence"), "native-canary-evidence"),
        @((Join-Path $StateRoot "native-canary.challenge"), "native-canary-challenge"))) {
        Save-RollbackFile $Snapshot[0] $RollbackRoot $Snapshot[1]
    }
    $DirectorySnapshotPath = Join-Path $RollbackRoot "directory.snapshot"
    Write-LifecycleDirectorySnapshot $DirectorySnapshotPath $Root $StateRoot $PublicRoot
    $DirectorySnapshotSha256 = Get-Sha256Bytes (Read-HeldBytes $DirectorySnapshotPath 65536)
    $RecoverySnapshotPath = Join-Path $RollbackRoot "recovery.snapshot"
    Write-LifecycleRecoverySnapshot $RecoverySnapshotPath $TransactionId $Operation $Manifest.Epoch `
        $PriorDigest $RollbackRoot $PriorAccount $PriorSystemTaskXml $PriorSystemTaskSddl `
        $PriorProfileTaskXml $PriorProfileTaskSddl $Manifest.Fields.'target-profile-sid' $ProgramData `
        ([IO.Directory]::Exists((Join-Path (Join-Path $Root "generations") ([string]$Manifest.Epoch)))) `
        $DirectorySnapshotSha256
    foreach ($RollbackFile in @([IO.Directory]::EnumerateFiles(
        $RollbackRoot, "*", [IO.SearchOption]::AllDirectories))) {
        Set-PathSddl $RollbackFile $LifecycleAcl.ProtectedFile
        Assert-PathSddl $RollbackFile $LifecycleAcl.ProtectedFile
    }
    Write-Transaction $TransactionPath $TransactionId $Operation "snapshotted" $Manifest.Epoch $PriorDigest
    Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    $SnapshotsComplete = $true
    if ($Revoke) {
        $MutationPath = Join-Path $StateRoot "enrollment.mutations"
        if (-not [IO.File]::Exists($MutationPath)) { throw "missing_enrollment_mutations" }
        $MutationRecord = Read-EnrollmentMutations (Read-HeldBytes $MutationPath 2048)
        if ($MutationRecord.TargetSid -cne $Manifest.Fields.'target-profile-sid') {
            throw "enrollment_mutation_target_drift"
        }
        $Account = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
        if ($Account.Enabled) { throw "request_account_must_be_disabled_before_revoke" }
        $RequestSid = [string]$Account.Sid.Value
        if ($MutationRecord.RequestSid -cne $RequestSid) { throw "enrollment_request_sid_drift" }
        $TargetRightsBefore = @(Get-LsaAccountRights $MutationRecord.TargetSid)
        $RequestRightsBefore = @(Get-LsaAccountRights $RequestSid)
        $QuotaBefore = Get-QuotaSnapshot $ProgramData $script:RequestAccountName $RequestSid
        # Mutating is durable before the first revoke-visible write. A crash before this record is
        # still a byte-exact snapshot rollback; a crash after it is deliberately fail-closed.
        Write-Transaction $TransactionPath $TransactionId $Operation "mutating" $Manifest.Epoch $PriorDigest
        Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
        Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
        # Disabling is the first revoke mutation. Never stop an in-flight instance: the drain
        # marker makes it retire naturally, and timeout leaves the durable mutating phase closed.
        $QuiescenceTransaction = Read-Transaction $TransactionPath
        $QuiescedTaskNames = @(Disable-BrokerTasks)
        Wait-BrokerTasksQuiescent $QuiescedTaskNames
        Assert-LifecycleQuiescenceBinding $TransactionPath $DrainPath $QuiescenceTransaction
        Assert-BrokerTasksQuiescent $QuiescedTaskNames
        Assert-ProtectedJournalsTerminal (Join-Path $StateRoot "replay") (Join-Path $StateRoot "audit")
        Write-PublicReadiness $PublicRoot "needs_human_enrollment" $Manifest "-" "-" "disabled" $false $false `
            -RequestSid $RequestSid
        foreach ($TaskName in @($script:SystemTaskName, $script:ProfileTaskName)) {
            $Task = Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
            if ($null -ne $Task) { Unregister-ScheduledTask -TaskName $TaskName -TaskPath "\" -Confirm:$false }
        }
        Disable-LocalUser -Name $script:RequestAccountName
        $Quarantine = Join-Path $RollbackRoot "quarantine"; [void][IO.Directory]::CreateDirectory($Quarantine)
        foreach ($Move in @(
            @((Join-Path $Root "entry"), (Join-Path $Quarantine "entry")),
            @((Join-Path $Root "generations"), (Join-Path $Quarantine "generations")),
            @((Join-Path $Root "ingress"), (Join-Path $Quarantine "ingress")),
            @((Join-Path $Root "profile"), (Join-Path $Quarantine "profile")),
            @((Join-Path $Root "chroot"), (Join-Path $Quarantine "chroot")),
            @((Join-Path $PublicRoot "results"), (Join-Path $Quarantine "public-results")),
            @((Join-Path $StateRoot "replay"), (Join-Path $Quarantine "state-replay")),
            @((Join-Path $StateRoot "processing"), (Join-Path $Quarantine "state-processing")))) {
            if ([IO.Directory]::Exists($Move[0])) {
                [IO.Directory]::Move($Move[0], $Move[1]); [void]$RevokeMoves.Add([pscustomobject]@{ Source = $Move[0]; Destination = $Move[1] })
            }
        }
        if ([IO.File]::Exists($PointerPath)) { [IO.File]::Delete($PointerPath) }
        foreach ($Name in @("policy.actions", "policy.constraints", "active")) {
            $PublicPath = Join-Path $PublicRoot $Name
            if ([IO.File]::Exists($PublicPath)) { [IO.File]::Delete($PublicPath) }
        }
        if (-not $MutationRecord.TargetBatchWasPresent) {
            Remove-LsaAccountRights $MutationRecord.TargetSid @("SeBatchLogonRight")
            if ((Get-LsaAccountRights $MutationRecord.TargetSid) -contains "SeBatchLogonRight") {
                throw "batch_logon_restore_failed"
            }
        }
        Restore-QuotaSnapshot $MutationRecord.Quota $script:RequestAccountName $RequestSid
        Write-PublicReadiness $PublicRoot "revoked" $Manifest "-" "-" "absent" $false $false
        if ($null -ne $Account) { Remove-LocalUser -Name $script:RequestAccountName }
        try { if ([IO.Directory]::Exists($Quarantine)) { [IO.Directory]::Delete($Quarantine, $true) } } catch { }
        Write-Transaction $TransactionPath $TransactionId $Operation "committed" $Manifest.Epoch $PriorDigest
        Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
        Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
        if ([IO.File]::Exists($DrainPath)) { [IO.File]::Delete($DrainPath) }
        return
    }

    # Prepared is durable before account, directory, ACL, entrypoint, or generation preparation.
    # Every change made while this phase is current is covered by the exact rollback snapshot.
    $GenerationStage = Join-Path (Join-Path $Root "generations") `
        ("." + $Manifest.Epoch + "." + [Guid]::NewGuid().ToString("N"))
    $PreparedStatePath = Join-Path $RollbackRoot "prepared.state"
    Write-PreparedLifecycleState $PreparedStatePath $TransactionId $Manifest.Epoch $GenerationStage
    Set-PathSddl $PreparedStatePath $LifecycleAcl.ProtectedFile
    Assert-PathSddl $PreparedStatePath $LifecycleAcl.ProtectedFile
    Write-Transaction $TransactionPath $TransactionId $Operation "prepared" $Manifest.Epoch $PriorDigest
    Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile

    $Account = Get-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue
    $MutationPath = Join-Path $StateRoot "enrollment.mutations"
    if ($null -ne $Account -and -not [IO.File]::Exists($MutationPath)) { throw "request_account_collision" }
    if ($null -eq $Account -and [IO.File]::Exists($MutationPath)) { throw "request_account_missing" }
    if ($null -eq $Account) {
        $Account = New-LocalUser -Name $script:RequestAccountName -NoPassword -AccountNeverExpires -Disabled `
            -UserMayNotChangePassword -Description "Disabled Roundhouse SFTP request principal"
        $AccountCreated = $true
    }
    Disable-LocalUser -Name $script:RequestAccountName
    $Account = Get-LocalUser -Name $script:RequestAccountName -ErrorAction Stop
    if ($Account.Enabled) { throw "atomic_disabled_account_required" }
    $RequestSid = [string]$Account.Sid.Value
    $Acl = Get-AclBlueprint $RequestSid $Manifest.Fields.'target-profile-sid'
    $TargetRightsBefore = @(Get-LsaAccountRights $Manifest.Fields.'target-profile-sid')
    $RequestRightsBefore = @(Get-LsaAccountRights $RequestSid)
    $QuotaBefore = Get-QuotaSnapshot $ProgramData $script:RequestAccountName $RequestSid
    if ([IO.File]::Exists($MutationPath)) {
        $MutationRecord = Read-EnrollmentMutations (Read-HeldBytes $MutationPath 2048)
        if ($MutationRecord.TargetSid -cne $Manifest.Fields.'target-profile-sid') {
            throw "enrollment_mutation_target_drift"
        }
        if ($MutationRecord.RequestSid -cne $RequestSid) { throw "enrollment_request_sid_drift" }
    } else {
        Write-EnrollmentMutations $MutationPath $Manifest.Fields.'target-profile-sid' $RequestSid `
            ($TargetRightsBefore -contains "SeBatchLogonRight") $QuotaBefore
    }

    foreach ($Directory in @($Root, (Join-Path $Root "entry"), (Join-Path $Root "generations"),
        (Join-Path $Root "chroot"),
        $StateRoot,
        (Join-Path $StateRoot "replay"), (Join-Path $StateRoot "journal"), (Join-Path $StateRoot "audit"),
        (Join-Path $StateRoot "processing"), (Join-Path $StateRoot "results"),
        (Join-Path $Root "profile"), (Join-Path $Root "profile/handoff"), $PublicRoot)) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }
    Set-PathSddl $PublicRoot $Acl.PublicDirectory
    Assert-PathSddl $PublicRoot $Acl.PublicDirectory
    foreach ($Directory in @((Join-Path $Root "generations"),
        $StateRoot, (Join-Path $StateRoot "replay"),
        (Join-Path $StateRoot "journal"), (Join-Path $StateRoot "audit"),
        (Join-Path $StateRoot "processing"), (Join-Path $StateRoot "results"), (Join-Path $Root "profile"))) {
        Set-PathSddl $Directory $Acl.ProtectedDirectory
    }
    Set-PathSddl $Root $Acl.ProtectedTraverseDirectory
    Set-PathSddl (Join-Path $Root "entry") $Acl.ProtectedTraverseDirectory
    Set-PathSddl (Join-Path $Root "profile/handoff") $Acl.ProtectedTraverseDirectory
    foreach ($Directory in @($TransactionRoot, $RollbackRoot) + @([IO.Directory]::EnumerateDirectories(
        $RollbackRoot, "*", [IO.SearchOption]::AllDirectories))) {
        Set-PathSddl $Directory $Acl.ProtectedDirectory
    }
    foreach ($FilePath in @([IO.Directory]::EnumerateFiles($RollbackRoot, "*", [IO.SearchOption]::AllDirectories)) +
        @($DrainPath, $TransactionPath, (Join-Path $StateRoot "broker.lock"))) {
        if ([IO.File]::Exists($FilePath)) { Set-PathSddl $FilePath $Acl.ProtectedFile }
    }
    [void][IO.Directory]::CreateDirectory($GenerationStage)
    foreach ($File in $ReleaseFiles.Files) {
        $Source = Join-Path $StageRoot $File.Path
        Assert-ProtectedWindowsPath $Source $BootstrapRoot
        if ($File.Path.StartsWith("scripts/", [StringComparison]::Ordinal)) {
            Assert-AuthenticodePublisher $Source $Receipt.'publisher-thumbprint'
        }
        $Destination = if ($File.Path.StartsWith("scripts/", [StringComparison]::Ordinal)) {
            Join-Path (Join-Path $Root "entry") ([IO.Path]::GetFileName($File.Path))
        } else { Join-Path $GenerationStage $File.Path.Substring("generation/".Length) }
        Copy-VerifiedFile $Source $Destination $File.Sha256
    }
    Install-ProtectedWinGetModule $GenerationStage $TransactionRoot
    $OpenSshIdentityPath = Join-Path $GenerationStage "openssh.identity"
    Write-AtomicBytes $OpenSshIdentityPath (Get-SystemOpenSshIdentityBytes)
    $OpenSshIdentityDigest = Get-Sha256Bytes (Read-HeldBytes $OpenSshIdentityPath 4096)
    foreach ($Binding in @(
        @("policy.actions", $Manifest.Fields.'policy-sha256'),
        @("policy.constraints", $Manifest.Fields.'constraints-sha256'),
        @("winget.context", $Manifest.Fields.'winget-context-sha256'),
        @("windows-winget-provider.lock", $Manifest.Fields.'provider-lock-sha256'))) {
        if ((Get-Sha256Bytes ([IO.File]::ReadAllBytes((Join-Path $GenerationStage $Binding[0]))) -cne $Binding[1])) {
            throw "generation_binding_mismatch"
        }
    }
    $GenerationRoot = Join-Path (Join-Path $Root "generations") ([string]$Manifest.Epoch)
    if ([IO.Directory]::Exists($GenerationRoot)) { throw "generation_already_exists" }
    [IO.Directory]::Move($GenerationStage, $GenerationRoot)
    $NewGenerationCreated = $true
    foreach ($Directory in @($GenerationRoot) + @([IO.Directory]::EnumerateDirectories(
        $GenerationRoot, "*", [IO.SearchOption]::AllDirectories) | Sort-Object { $_.Length })) {
        Set-PathSddl $Directory $Acl.ProtectedDirectory
    }
    foreach ($FilePath in @([IO.Directory]::EnumerateFiles($GenerationRoot, "*", [IO.SearchOption]::AllDirectories))) {
        Set-PathSddl $FilePath $Acl.ProtectedFile
    }
    $OpenSshIdentityPath = Join-Path $GenerationRoot "openssh.identity"
    [void](Assert-SystemOpenSshIdentity $OpenSshIdentityPath $Root)
    $OpenSshIdentityDigest = Get-Sha256Bytes (Read-HeldBytes $OpenSshIdentityPath 4096)
    # The S4U task is user self-registered. Before granting batch logon or activating this
    # generation, independently bind that registration and every generated profile record to
    # the currently observed local profile root.
    $PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (-not [IO.File]::Exists($PowerShellPath)) { throw "fixed_powershell_missing" }
    $ProfileRegistration = Get-VerifiedProfileTaskRegistration $Manifest.Fields.'target-profile-sid' `
        $ProgramData $PowerShellPath
    $ProfileConstraintRecords = @(Assert-ProfileReleaseArtifactCompleteness $ReleaseFiles `
        (Read-HeldBytes (Join-Path $GenerationRoot "policy.constraints") 4194304) `
        $Manifest.Fields.'target-profile-sid' $ProfileRegistration.ProfileRootId)
    Assert-StagedProfileArtifacts $GenerationRoot $ProfileConstraintRecords $Root $Acl.ProtectedFile
    # Prevent either recurring task from observing partially replaced live paths. In-flight
    # instances drain naturally; no enrollment or rollback path terminates a scheduled task.
    # The transaction remains prepared while the legacy siblings are quarantined and the exact
    # physical chroot tree is staged, so every injected fault remains an exact snapshot rollback.
    $QuiescenceTransaction = Read-Transaction $TransactionPath
    $QuiescedTaskNames = @(Disable-BrokerTasks)
    Wait-BrokerTasksQuiescent $QuiescedTaskNames
    Assert-LifecycleQuiescenceBinding $TransactionPath $DrainPath $QuiescenceTransaction
    Assert-BrokerTasksQuiescent $QuiescedTaskNames
    Assert-ProtectedJournalsTerminal (Join-Path $StateRoot "replay") (Join-Path $StateRoot "audit")
    Stage-ChrootProjection $Root $PublicRoot $RollbackRoot $Acl
    Write-Transaction $TransactionPath $TransactionId $Operation "mutating" $Manifest.Epoch $PriorDigest
    Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    Set-PathSddl $PublicRoot $Acl.PublicDirectory
    foreach ($Directory in @((Join-Path $Root "generations"),
        $StateRoot,
        (Join-Path $StateRoot "replay"), (Join-Path $StateRoot "journal"), (Join-Path $StateRoot "audit"),
        (Join-Path $StateRoot "processing"), (Join-Path $StateRoot "results"))) {
        Set-PathSddl $Directory $Acl.ProtectedDirectory
    }
    Set-PathSddl $Root $Acl.ProtectedTraverseDirectory
    Set-PathSddl (Join-Path $Root "entry") $Acl.ProtectedTraverseDirectory
    Set-PathSddl (Join-Path $Root "profile/handoff") $Acl.ProtectedTraverseDirectory
    foreach ($Name in @("privilege-broker-windows.ps1", "enroll-privilege-windows.ps1",
        "register-profile-task-windows.ps1")) {
        Set-PathSddl (Join-Path $Root "entry/$Name") $Acl.ProtectedFile
    }
    Set-PathSddl (Join-Path $Root "entry/profile-worker-windows.ps1") $Acl.ProfileWorkerFile
    Set-PathSddl (Join-Path $StateRoot "enrollment.mutations") $Acl.ProtectedFile

    Add-RequestAccountDenyRights $RequestSid
    Add-BatchLogonRight $Manifest.Fields.'target-profile-sid'
    Enable-FixedSlotQuota $ProgramData $script:RequestAccountName $RequestSid
    $RequiredRequestRights = @(
        "SeDenyInteractiveLogonRight", "SeDenyRemoteInteractiveLogonRight", "SeDenyBatchLogonRight")
    $ObservedRequestRights = @(Get-LsaAccountRights $RequestSid)
    if (@($RequiredRequestRights | Where-Object { $_ -notin $ObservedRequestRights }).Count -ne 0 -or
        (Get-LsaAccountRights $Manifest.Fields.'target-profile-sid') -notcontains "SeBatchLogonRight") {
        throw "account_rights_verification_failed"
    }
    $EnableLua = Get-ItemPropertyValue -LiteralPath `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name EnableLUA
    if ([int]$EnableLua -ne 1) { throw "uac_disabled_host_unsupported" }
    # Re-observe immediately before hardening the task, then prove the protected task did not
    # change except for the enrollment-owned disabled bit while its owner rights were removed.
    $ProfileRegistration = Get-VerifiedProfileTaskRegistration $Manifest.Fields.'target-profile-sid' `
        $ProgramData $PowerShellPath -Disabled
    $SystemXml = Get-SystemTaskXml $ProgramData $PowerShellPath
    Assert-TaskContract $SystemXml "system" "S-1-5-18" $ProgramData $PowerShellPath
    Register-ProtectedSystemTask $SystemXml
    Assert-TaskContract (Export-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\") "system" "S-1-5-18" `
        $ProgramData $PowerShellPath
    Set-ProtectedTaskSecurity $script:SystemTaskName
    Set-ProtectedTaskSecurity $script:ProfileTaskName
    Assert-ProtectedTaskSecurity $script:SystemTaskName
    Assert-ProtectedTaskSecurity $script:ProfileTaskName
    $DisabledProfileXml = Export-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction Stop
    Assert-TaskContract $DisabledProfileXml "profile" $Manifest.Fields.'target-profile-sid' `
        $ProgramData $PowerShellPath -Disabled
    $LockedProfileRoot = Get-TargetProfileRootEvidence $Manifest.Fields.'target-profile-sid'
    if ($LockedProfileRoot.ProfileRootId -cne $ProfileRegistration.ProfileRootId) {
        throw "profile_root_identity_drift"
    }

    $PointerDigest = Get-GenerationDigest $Manifest $OpenSshIdentityDigest
    Write-AtomicAscii $PointerPath @("roundhouse-active-generation|1", "epoch|$($Manifest.Epoch)",
        "generation-sha256|$PointerDigest", "end-generation|")
    foreach ($ProtectedFile in @($PointerPath, $TransactionPath, (Join-Path $StateRoot "broker.lock"),
        (Join-Path $StateRoot "enrollment.mutations"))) {
        Set-PathSddl $ProtectedFile $Acl.ProtectedFile
    }
    Write-AtomicBytes (Join-Path $PublicRoot "policy.actions") `
        ([IO.File]::ReadAllBytes((Join-Path $GenerationRoot "policy.actions")))
    Write-AtomicBytes (Join-Path $PublicRoot "policy.constraints") `
        ([IO.File]::ReadAllBytes((Join-Path $GenerationRoot "policy.constraints")))
    # The protected task is enabled only after the complete live generation and pointer exist.
    # Drain remains asserted, so a trigger cannot admit ordinary work before commit.
    Enable-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction Stop | Out-Null
    $LockedProfileXml = Export-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction Stop
    Assert-TaskContract $LockedProfileXml "profile" $Manifest.Fields.'target-profile-sid' $ProgramData $PowerShellPath
    Assert-ProtectedTaskSecurity $script:ProfileTaskName
    if ((Get-NormalizedTaskXmlSha256 $LockedProfileXml) -cne
        (Get-NormalizedTaskXmlSha256 $ProfileRegistration.TaskXml)) {
        throw "profile_task_registration_drift"
    }
    Write-Transaction $TransactionPath $TransactionId $Operation "activated" $Manifest.Epoch $PriorDigest

    # Provision the WinGet state exactly once for this activated generation. The broker consumes
    # the protected marker before honoring drain, so release only the lifecycle lock while the
    # marker is live; the drain marker keeps all ordinary submissions closed.
    $ProvisionMarkerBytes = Get-WinGetProvisionRequestBytes $Manifest $PointerDigest
    $ProvisionPaths = Get-WinGetProvisionPaths $StateRoot $Manifest.Epoch $PointerDigest
    $ProvisionContext = Read-WinGetProvisionContext (Read-HeldBytes (Join-Path $GenerationRoot "winget.context") 16384)
    Assert-WinGetProvisionEvidenceAbsent $ProvisionPaths $Root $Acl.ProtectedFile
    Write-AtomicBytes $ProvisionPaths.Marker $ProvisionMarkerBytes
    Set-PathSddl $ProvisionPaths.Marker $Acl.ProtectedFile
    if ((Get-WinGetProvisionEvidencePathState $ProvisionPaths.Marker $Root $Acl.ProtectedFile) -cne "file") {
        throw "winget_provision_marker_write_failed"
    }
    $LifecycleLock.Dispose(); $LifecycleLock = $null
    try {
        # Re-attest both complete normalized task definitions and complete owner/group/DACL
        # descriptors at the final submission boundary. Earlier enrollment checks are not a lease.
        Assert-TaskContract (Export-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\" -ErrorAction Stop) `
            "system" "S-1-5-18" $ProgramData $PowerShellPath
        Assert-TaskContract (Export-ScheduledTask -TaskName $script:ProfileTaskName -TaskPath "\" -ErrorAction Stop) `
            "profile" $Manifest.Fields.'target-profile-sid' $ProgramData $PowerShellPath
        Assert-ProtectedTaskSecurity $script:SystemTaskName
        Assert-ProtectedTaskSecurity $script:ProfileTaskName
        Start-ScheduledTask -TaskName $script:SystemTaskName -TaskPath "\" -ErrorAction Stop
        $ProvisionReceipt = Wait-WinGetProvisionReceipt $Root $ProvisionPaths $ProvisionMarkerBytes $Manifest `
            $PointerDigest $ProvisionContext $Acl.ProtectedFile
        $ProvisionDisposition = Get-WinGetProvisionDisposition $ProvisionReceipt
    } finally {
        $LifecycleLock = Acquire-LifecycleLock (Join-Path $StateRoot "broker.lock")
    }
    if ($ProvisionDisposition -ceq "preserve") {
        $ProvisionEvidencePreserved = $true
        throw "winget_provider_provision_recovery_required"
    }
    if ($ProvisionDisposition -ceq "rollback") { throw "winget_provider_provision_rejected" }
    if ($ProvisionDisposition -cne "continue") { throw "invalid_winget_provision_result" }

    $ChallengeIssuedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ChallengePath = Join-Path $StateRoot "native-canary.challenge"
    Write-AtomicAscii $ChallengePath @(
        "windows-native-canary-challenge|1", "nonce|$(New-CryptographicNonce)", "host|$HostName",
        "epoch|$($Manifest.Epoch)", "generation-sha256|$PointerDigest",
        "runner-path-sha256|$(Get-Sha256Utf8Text $Receipt.'native-canary-runner-path'.ToUpperInvariant())",
        "runner-sha256|$($Receipt.'native-canary-runner-sha256')",
        "runner-publisher-thumbprint|$($Receipt.'native-canary-publisher-thumbprint')",
        "issued-at|$ChallengeIssuedAt", "expires-at|$($ChallengeIssuedAt + 3600)",
        "clock-skew-bound-seconds|$script:ClockSkewBoundSeconds", "end-challenge|")
    Set-PathSddl $ChallengePath $Acl.ProtectedFile
    foreach ($OldCanaryPath in @((Join-Path $Root "native-canary.receipt"),
            (Join-Path $Root "native-canary.receipt.p7s"), (Join-Path $Root "native-canary.evidence"))) {
        if ([IO.File]::Exists($OldCanaryPath)) { [IO.File]::Delete($OldCanaryPath) }
    }
    $BrokerDigest = Get-Sha256Bytes ([IO.File]::ReadAllBytes((Join-Path $Root "entry/privilege-broker-windows.ps1")) )
    Write-PublicReadiness $PublicRoot "needs_native_canary" $Manifest $BrokerDigest $PointerDigest "disabled" $true $true `
        -RequestSid $RequestSid
    Write-Transaction $TransactionPath $TransactionId $Operation "committed" $Manifest.Epoch $PriorDigest
    Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
    if ([IO.File]::Exists($DrainPath)) { [IO.File]::Delete($DrainPath) }
} catch {
    $OriginalFailure = $_
    # Committed is absorbing. A cleanup failure after the terminal phase may leave only transaction-
    # owned drain/rollback evidence for the next resolver; it must never trigger a rollback of the
    # already verified final machine state.
    if ($LifecycleStorageProtected -and [IO.File]::Exists($TransactionPath) -and
        (Get-Item -LiteralPath $TransactionPath -Force).Length -gt 0) {
        $FailureTransaction = $null
        try { $FailureTransaction = Read-Transaction $TransactionPath } catch { }
        if ($null -ne $FailureTransaction -and
            $FailureTransaction.'transaction-id' -ceq $TransactionId -and
            $FailureTransaction.phase -ceq "committed") {
            try { Assert-TerminalLifecycleState $FailureTransaction $Root $StateRoot $PublicRoot }
            catch {
                Publish-LifecycleRecoveryRequired $PublicRoot $Manifest $LifecycleAcl.PublicDirectory
                throw "lifecycle_recovery_required"
            }
            throw $OriginalFailure
        }
    }
    $RollbackFailure = $null
    try {
        if ($null -eq $LifecycleLock) { throw "lifecycle_lock_reacquire_failed" }
        if (-not $SnapshotsComplete) {
            $DrainMeta = Join-Path $RollbackRoot "drain.meta"
            if (-not [IO.File]::Exists($DrainMeta)) { throw "pre_snapshot_rollback_evidence_missing" }
            Restore-RollbackFile $DrainPath $RollbackRoot "drain"
            if ($null -eq $PriorTransactionBytes) {
                Write-AtomicBytes $TransactionPath ([byte[]]@())
            } else {
                Write-AtomicBytes $TransactionPath $PriorTransactionBytes
            }
            Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
            Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
            if ([IO.Directory]::Exists($RollbackRoot)) { [IO.Directory]::Delete($RollbackRoot, $true) }
        } else {
        if ($null -ne $ProvisionPaths -and $null -ne $ProvisionMarkerBytes -and $null -ne $Acl) {
            try {
                $MarkerState = Get-WinGetProvisionEvidencePathState $ProvisionPaths.Marker $Root $Acl.ProtectedFile
                $ClaimState = Get-WinGetProvisionEvidencePathState $ProvisionPaths.Claim $Root $Acl.ProtectedFile
                $ReceiptState = Get-WinGetProvisionEvidencePathState $ProvisionPaths.Receipt $Root $Acl.ProtectedFile
                if ($ProvisionDisposition -cne "rollback" -and
                    ($ClaimState -ceq "file" -or $ReceiptState -ceq "file")) {
                    # A claimed or terminal provider operation may have changed machine state;
                    # preserve its generation, drain, and evidence instead of attempting a replay.
                    $ProvisionEvidencePreserved = $true
                } elseif ($MarkerState -ceq "file") {
                    Remove-UnclaimedWinGetProvisionMarker $Root $ProvisionPaths $ProvisionMarkerBytes $Acl.ProtectedFile
                }
            } catch { $ProvisionEvidencePreserved = $true }
        }
        if ($SnapshotsComplete -and -not $ProvisionEvidencePreserved) {
        $RollbackTransaction = Read-Transaction $TransactionPath
        if ($RollbackTransaction.phase -cin @("prepared", "mutating", "activated")) {
            # Disable and wait for natural exit before replacing or unregistering either task.
            # A timeout is rollback drift; termination is reserved for the broker's pre-resume
            # containment emergency and is never used for enrollment cleanup.
            $RollbackTaskNames = @(Disable-BrokerTasks)
            Wait-BrokerTasksQuiescent $RollbackTaskNames
            Assert-LifecycleQuiescenceBinding $TransactionPath $DrainPath $RollbackTransaction
            Assert-BrokerTasksQuiescent $RollbackTaskNames
            Assert-ProtectedJournalsTerminal (Join-Path $StateRoot "replay") (Join-Path $StateRoot "audit")
        }
        foreach ($Move in @($RevokeMoves | Sort-Object { $_.Source.Length } -Descending)) {
            if ([IO.Directory]::Exists($Move.Destination) -and -not [IO.Directory]::Exists($Move.Source)) {
                [IO.Directory]::Move($Move.Destination, $Move.Source)
            }
        }
        if ($RollbackTransaction.phase -cin @("prepared", "mutating", "activated")) {
            Restore-Task $script:SystemTaskName $PriorSystemTaskXml $PriorSystemTaskSddl
            Restore-Task $script:ProfileTaskName $PriorProfileTaskXml $PriorProfileTaskSddl
        }
        foreach ($Snapshot in @(
            @($PointerPath, "active-pointer"),
            @((Join-Path $Root "entry/privilege-broker-windows.ps1"), "entry-broker"),
            @((Join-Path $Root "entry/profile-worker-windows.ps1"), "entry-profile"),
            @((Join-Path $Root "entry/enroll-privilege-windows.ps1"), "entry-enroll"),
            @((Join-Path $Root "entry/register-profile-task-windows.ps1"), "entry-register"),
            @((Join-Path $StateRoot "enrollment.mutations"), "enrollment-mutations"),
            @((Join-Path $PublicRoot "policy.actions"), "public-policy"),
            @((Join-Path $PublicRoot "policy.constraints"), "public-constraints"),
            @((Join-Path $PublicRoot "readiness"), "public-readiness"),
            @((Join-Path $Root "native-canary.receipt"), "native-canary"),
            @((Join-Path $Root "native-canary.receipt.p7s"), "native-canary-signature"),
            @((Join-Path $Root "native-canary.evidence"), "native-canary-evidence"),
            @((Join-Path $StateRoot "native-canary.challenge"), "native-canary-challenge"))) {
            Restore-RollbackFile $Snapshot[0] $RollbackRoot $Snapshot[1]
        }
        if ($NewGenerationCreated -and [IO.Directory]::Exists($GenerationRoot)) {
            [IO.Directory]::Delete($GenerationRoot, $true)
        }
        if ($null -ne $GenerationStage -and [IO.Directory]::Exists($GenerationStage)) {
            [IO.Directory]::Delete($GenerationStage, $true)
        }
        $CurrentAccount = Get-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue
        if ($null -ne $QuotaBefore -and $null -ne $CurrentAccount) {
            Restore-QuotaSnapshot $QuotaBefore $script:RequestAccountName ([string]$CurrentAccount.Sid.Value)
        }
        if ($null -ne $TargetRightsBefore) {
            Set-LsaAccountRightsExact $Manifest.Fields.'target-profile-sid' $TargetRightsBefore
        }
        if ($AccountWasPresent -and $null -ne $RequestRightsBefore -and $null -ne $CurrentAccount) {
            Set-LsaAccountRightsExact ([string]$CurrentAccount.Sid.Value) $RequestRightsBefore
        }
        if (-not $AccountWasPresent -and $null -ne $CurrentAccount) {
            Disable-LocalUser -Name $script:RequestAccountName -ErrorAction SilentlyContinue
            Remove-LocalUser -Name $script:RequestAccountName
        } elseif ($AccountWasPresent) {
            if ($AccountWasEnabled) { Enable-LocalUser -Name $script:RequestAccountName }
            else { Disable-LocalUser -Name $script:RequestAccountName }
        }
        $RollbackSnapshot = Read-LifecycleRecoverySnapshot (Join-Path $RollbackRoot "recovery.snapshot") `
            $RollbackTransaction $RollbackRoot
        if (-not [IO.File]::Exists($DirectorySnapshotPath) -or
            (Get-Sha256Bytes (Read-HeldBytes $DirectorySnapshotPath 65536)) -cne
                $RollbackSnapshot.'directory-snapshot-sha256') { throw "directory_snapshot_drift" }
        $RollbackDirectories = Read-LifecycleDirectorySnapshot $DirectorySnapshotPath $Root $StateRoot $PublicRoot
        Restore-ChrootProjectionMigration $RollbackDirectories $Root $PublicRoot $RollbackRoot $Acl `
            -RequireStagedExact:($RollbackTransaction.operation -ceq "install" -and
                $RollbackTransaction.phase -cin @("mutating", "activated"))
        Restore-LifecycleDirectorySnapshot $RollbackDirectories $Root
        }
        if ($LifecycleStorageProtected) {
            if ($ProvisionEvidencePreserved) {
                if (-not [IO.File]::Exists($DrainPath)) {
                    Write-DrainMarker $DrainPath $Operation $TransactionId $Manifest.Epoch
                }
                Set-PathSddl $DrainPath $LifecycleAcl.ProtectedFile
                Assert-PathSddl $DrainPath $LifecycleAcl.ProtectedFile
                Write-PublicReadiness $PublicRoot "drifted" $Manifest "-" "-" "disabled" $false $false `
                    -RequestSid $RequestSid
            } else {
                $DrainMeta = Join-Path $RollbackRoot "drain.meta"
                if ([IO.File]::Exists($DrainMeta)) { Restore-RollbackFile $DrainPath $RollbackRoot "drain" }
                Write-Transaction $TransactionPath $TransactionId $Operation "rolled-back" $Manifest.Epoch $PriorDigest
                Set-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
                Assert-PathSddl $TransactionPath $LifecycleAcl.ProtectedFile
                foreach ($Directory in @($TransactionRoot, $RollbackRoot)) {
                    Set-PathSddl $Directory $LifecycleAcl.ProtectedDirectory
                    Assert-PathSddl $Directory $LifecycleAcl.ProtectedDirectory
                }
            }
        }
        }
    } catch { $RollbackFailure = $_ }
    if ($null -ne $RollbackFailure) {
        Write-PublicReadiness $PublicRoot "drifted" $Manifest "-" "-" "disabled" $false $false `
            -RequestSid $RequestSid
        throw "enrollment_failed_and_rollback_drifted: $($OriginalFailure.Exception.Message); $($RollbackFailure.Exception.Message)"
    }
    throw $OriginalFailure
} finally {
    if ($null -ne $LifecycleLock) { $LifecycleLock.Dispose() }
}
