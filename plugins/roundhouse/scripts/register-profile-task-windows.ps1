[CmdletBinding(DefaultParameterSetName = "Register")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Register")][switch]$Register,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:TaskName = "RoundhouseProfileV1"
$script:ContextName = "windows-user-s4u-v1"
$script:WorkerRelativePath = "Roundhouse\entry\profile-worker-windows.ps1"
$script:TaskCreateOrUpdate = 0x6
$script:TaskDontAddPrincipalAce = 0x10
$script:TaskLogonS4U = 0x2

function Get-Sha256Text([string]$Text) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally { $Hasher.Dispose() }
}

function Get-NormalizedTaskXml([string]$XmlText) {
    try {
        $Document = [Xml.XmlDocument]::new()
        $Document.PreserveWhitespace = $false
        $Document.LoadXml($XmlText)
    } catch { throw "invalid_profile_task_xml" }
    $Settings = [Xml.XmlWriterSettings]::new()
    $Settings.OmitXmlDeclaration = $true
    $Settings.Indent = $false
    $Settings.NewLineHandling = [Xml.NewLineHandling]::None
    $Builder = [Text.StringBuilder]::new()
    $Writer = [Xml.XmlWriter]::Create($Builder, $Settings)
    function Write-NormalizedNode([Xml.XmlNode]$Node, [Xml.XmlWriter]$Target) {
        if ($Node.NodeType -eq [Xml.XmlNodeType]::Element) {
            $Target.WriteStartElement([string]$Node.Prefix, [string]$Node.LocalName, [string]$Node.NamespaceURI)
            foreach ($Attribute in @($Node.Attributes | Sort-Object NamespaceURI, LocalName)) {
                if ($Attribute.Prefix -ceq "xmlns" -or $Attribute.Name -ceq "xmlns") { continue }
                $Target.WriteAttributeString([string]$Attribute.Prefix, [string]$Attribute.LocalName,
                    [string]$Attribute.NamespaceURI, [string]$Attribute.Value)
            }
            foreach ($Child in @($Node.ChildNodes)) { Write-NormalizedNode $Child $Target }
            $Target.WriteEndElement()
        } elseif ($Node.NodeType -in @([Xml.XmlNodeType]::Text, [Xml.XmlNodeType]::CDATA)) {
            $Target.WriteString([string]$Node.Value)
        }
    }
    try { Write-NormalizedNode $Document.DocumentElement $Writer; $Writer.Flush() }
    finally { $Writer.Dispose() }
    return $Builder.ToString()
}

function Get-NormalizedTaskXmlSha256([string]$XmlText) {
    return Get-Sha256Text (Get-NormalizedTaskXml $XmlText)
}

function Get-ProfileRootIdentityRecord([string]$Sid, [string]$FinalPath, [uint32]$VolumeSerial, [uint64]$FileId) {
    if ($Sid -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or -not (Test-WindowsAbsolutePath $FinalPath)) {
        throw "invalid_profile_root_identity"
    }
    return Get-Sha256Text ("profile-root-identity|1`ntarget-sid|$Sid`nfinal-path|$($FinalPath.ToUpperInvariant())" +
        "`nvolume-serial|$($VolumeSerial.ToString('x8'))`nfile-id|$($FileId.ToString('x16'))`nend-profile-root|`n")
}

function Initialize-ProfileRootIdentityType {
    if ("RoundhouseRegistrationProfileRoot" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class RoundhouseRegistrationProfileRoot
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

    public static RoundhouseRegistrationProfileRoot Observe(string path)
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
            return new RoundhouseRegistrationProfileRoot { FinalPath = finalPath,
                VolumeSerial = info.VolumeSerialNumber,
                FileId = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow };
        }
    }
}
'@
}

function Test-WindowsAbsolutePath([string]$Path) {
    return $Path -cmatch '^[A-Za-z]:\\[^:*?"<>|\r\n]+$' -and $Path -notmatch '(?:^|\\)\.\.?(?:\\|$)'
}

function Get-FixedTaskContract([string]$Sid, [string]$ProgramData, [string]$PowerShellPath) {
    if ($Sid -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-WindowsAbsolutePath $ProgramData) -or
        -not (Test-WindowsAbsolutePath $PowerShellPath)) { throw "invalid_task_contract_input" }
    $EntryRoot = $ProgramData.TrimEnd('\') + "\Roundhouse\entry"
    $WorkerPath = $ProgramData.TrimEnd('\') + "\" + $script:WorkerRelativePath
    return [pscustomobject]@{
        TaskName = $script:TaskName
        Sid = $Sid
        Command = $PowerShellPath
        Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "' +
            $WorkerPath + '" -Context windows-user-s4u-v1'
        WorkingDirectory = $EntryRoot
        LogonType = "S4U"
        RunLevel = "LeastPrivilege"
        MultipleInstancesPolicy = "IgnoreNew"
        ExecutionTimeLimit = "PT0S"
    }
}

function ConvertTo-TaskXml([object]$Contract) {
    $Settings = [Xml.XmlWriterSettings]::new()
    $Settings.OmitXmlDeclaration = $false
    $Settings.Indent = $false
    $Settings.Encoding = [Text.UnicodeEncoding]::new($false, $false)
    $Builder = [Text.StringBuilder]::new()
    $Writer = [Xml.XmlWriter]::Create($Builder, $Settings)
    try {
        $Writer.WriteStartDocument()
        $Writer.WriteStartElement("Task", "http://schemas.microsoft.com/windows/2004/02/mit/task")
        $Writer.WriteAttributeString("version", "1.4")
        $Writer.WriteStartElement("RegistrationInfo"); $Writer.WriteElementString("URI", "\" + $Contract.TaskName); $Writer.WriteEndElement()
        $Writer.WriteStartElement("Triggers"); $Writer.WriteEndElement()
        $Writer.WriteStartElement("Principals"); $Writer.WriteStartElement("Principal"); $Writer.WriteAttributeString("id", "Author")
        $Writer.WriteElementString("UserId", $Contract.Sid); $Writer.WriteElementString("LogonType", $Contract.LogonType)
        $Writer.WriteElementString("RunLevel", $Contract.RunLevel); $Writer.WriteEndElement(); $Writer.WriteEndElement()
        $Writer.WriteStartElement("Settings")
        foreach ($Pair in @(
            @("MultipleInstancesPolicy", $Contract.MultipleInstancesPolicy), @("DisallowStartIfOnBatteries", "false"),
            @("StopIfGoingOnBatteries", "false"), @("AllowHardTerminate", "false"), @("StartWhenAvailable", "false"),
            @("RunOnlyIfNetworkAvailable", "false"), @("Enabled", "true"), @("Hidden", "true"),
            @("RunOnlyIfIdle", "false"), @("WakeToRun", "false"), @("ExecutionTimeLimit", $Contract.ExecutionTimeLimit),
            @("Priority", "7"))) { $Writer.WriteElementString($Pair[0], $Pair[1]) }
        $Writer.WriteEndElement()
        $Writer.WriteStartElement("Actions"); $Writer.WriteAttributeString("Context", "Author")
        $Writer.WriteStartElement("Exec"); $Writer.WriteElementString("Command", $Contract.Command)
        $Writer.WriteElementString("Arguments", $Contract.Arguments)
        $Writer.WriteElementString("WorkingDirectory", $Contract.WorkingDirectory)
        $Writer.WriteEndElement(); $Writer.WriteEndElement(); $Writer.WriteEndElement(); $Writer.WriteEndDocument()
    } finally { $Writer.Dispose() }
    return $Builder.ToString()
}

function Assert-TaskXml([string]$XmlText, [object]$Expected) {
    try { [xml]$Document = $XmlText } catch { throw "invalid_profile_task_xml" }
    $Manager = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Manager.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
    $Checks = [ordered]@{
        "/t:Task/@version" = "1.4"
        "/t:Task/t:RegistrationInfo/t:URI" = "\" + $Expected.TaskName
        "/t:Task/t:Principals/t:Principal/t:UserId" = $Expected.Sid
        "/t:Task/t:Principals/t:Principal/t:LogonType" = "S4U"
        "/t:Task/t:Principals/t:Principal/t:RunLevel" = "LeastPrivilege"
        "/t:Task/t:Settings/t:MultipleInstancesPolicy" = "IgnoreNew"
        "/t:Task/t:Settings/t:StartWhenAvailable" = "false"
        "/t:Task/t:Settings/t:Enabled" = "true"
        "/t:Task/t:Settings/t:ExecutionTimeLimit" = "PT0S"
        "/t:Task/t:Actions/t:Exec/t:Command" = $Expected.Command
        "/t:Task/t:Actions/t:Exec/t:Arguments" = $Expected.Arguments
        "/t:Task/t:Actions/t:Exec/t:WorkingDirectory" = $Expected.WorkingDirectory
    }
    foreach ($Path in $Checks.Keys) {
        $Nodes = @($Document.SelectNodes($Path, $Manager))
        $Observed = if ($Nodes.Count -eq 1 -and $Nodes[0] -is [Xml.XmlAttribute]) {
            [string]$Nodes[0].Value
        } elseif ($Nodes.Count -eq 1) { [string]$Nodes[0].InnerText } else { "" }
        if ($Nodes.Count -ne 1 -or $Observed -cne [string]$Checks[$Path]) {
            throw "profile_task_contract_drift"
        }
    }
    if (@($Document.SelectNodes("/t:Task/t:Triggers", $Manager)).Count -ne 1 -or
        @($Document.SelectNodes("/t:Task/t:Triggers/*", $Manager)).Count -ne 0 -or
        @($Document.SelectNodes("//t:TimeTrigger|//t:Repetition", $Manager)).Count -ne 0 -or
        @($Document.SelectNodes("/t:Task/t:Actions/*", $Manager)).Count -ne 1 -or
        $XmlText -match '(?i)(<Password>|InteractiveToken|HighestAvailable|cmd\.exe|powershell\.exe|winget\.exe)') {
        throw "profile_task_contract_drift"
    }
    $ExpectedXml = ConvertTo-TaskXml $Expected
    if ((Get-NormalizedTaskXml $XmlText) -cne (Get-NormalizedTaskXml $ExpectedXml)) {
        throw "profile_task_contract_drift"
    }
}

function Register-FixedProfileTask([string]$Xml, [string]$Sid) {
    if ($Sid -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$') { throw "invalid_profile_task_sid" }
    $Service = New-Object -ComObject "Schedule.Service"
    $Service.Connect()
    $Folder = $Service.GetFolder("\")
    $Flags = $script:TaskCreateOrUpdate -bor $script:TaskDontAddPrincipalAce
    $Task = $Folder.RegisterTask($script:TaskName, $Xml, $Flags, $Sid, $null, $script:TaskLogonS4U, $null)
    if ($null -eq $Task) { throw "profile_task_registration_failed" }
}

function Invoke-SelfTest {
    Initialize-ProfileRootIdentityType
    $Contract = Get-FixedTaskContract "S-1-5-21-1-2-3-1001" "C:\ProgramData" "C:\Program Files\PowerShell\7\pwsh.exe"
    $Xml = ConvertTo-TaskXml $Contract
    Assert-TaskXml $Xml $Contract
    if (($script:TaskCreateOrUpdate -bor $script:TaskDontAddPrincipalAce) -ne 0x16 -or
        $script:TaskLogonS4U -ne 0x2) { throw "task registration flags self-test failed" }
    if ($Xml -match 'generations\\|active\.generation|request-' -or
        $Contract.Arguments -cne '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File "C:\ProgramData\Roundhouse\entry\profile-worker-windows.ps1" -Context windows-user-s4u-v1') {
        throw "epoch-free task action self-test failed"
    }
    foreach ($Mutation in @(
        $Xml.Replace("<LogonType>S4U</LogonType>", "<LogonType>InteractiveToken</LogonType>"),
        $Xml.Replace("<RunLevel>LeastPrivilege</RunLevel>", "<RunLevel>HighestAvailable</RunLevel>"),
        $Xml.Replace("<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>",
            "<MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>"),
        $Xml.Replace("-Context windows-user-s4u-v1", "-Context windows-system-v1"),
        $Xml.Replace("<Triggers />", "<Triggers><TimeTrigger><StartBoundary>2000-01-01T00:00:00</StartBoundary>" +
            "<Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>" +
            "<Enabled>true</Enabled></TimeTrigger></Triggers>"),
        $Xml.Replace("<StartWhenAvailable>false</StartWhenAvailable>",
            "<StartWhenAvailable>true</StartWhenAvailable>"),
        $Xml.Replace("<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>",
            "<ExecutionTimeLimit>PT1M</ExecutionTimeLimit>"),
        $Xml.Replace("</Settings>", "<RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings>"))) {
        $Rejected = $false
        try { Assert-TaskXml $Mutation $Contract } catch { $Rejected = $true }
        if (-not $Rejected) { throw "task drift self-test failed" }
    }
    $BuiltInAdminRejected = "S-1-5-21-1-2-3-500" -match '-500$'
    if (-not $BuiltInAdminRejected) { throw "built-in Administrator self-test failed" }
    $RootIdentity = Get-ProfileRootIdentityRecord "S-1-5-21-1-2-3-1001" "C:\Users\Fixture" 1 2
    if ($RootIdentity -notmatch '^[0-9a-f]{64}$' -or $RootIdentity -cne
        (Get-ProfileRootIdentityRecord "S-1-5-21-1-2-3-1001" "C:\Users\Fixture" 1 2) -or
        $RootIdentity -ceq (Get-ProfileRootIdentityRecord "S-1-5-21-1-2-3-1001" "C:\Users\Fixture" 1 3)) {
        throw "profile root identity self-test failed"
    }
    Write-Output "PASS: register-profile-task-windows fixture-safe self-check"
}

if ($SelfTest) { Invoke-SelfTest; return }

if (-not $IsWindows) { throw "unsupported_context" }
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if ($Identity.IsSystem -or $null -eq $Identity.User) { throw "unsupported_profile_account" }
    $Sid = [string]$Identity.User.Value
    if ($Sid -match '-500$') { throw "built_in_administrator_forbidden" }
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    if ($Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "elevated_registration_forbidden"
    }
} finally { $Identity.Dispose() }
$EnableLua = Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name EnableLUA -ErrorAction Stop
if ([int]$EnableLua -ne 1) { throw "uac_disabled_host_unsupported" }
$ProgramData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
if (-not [IO.File]::Exists($PowerShellPath)) { throw "fixed_powershell_missing" }
$PowerShellItem = Get-Item -LiteralPath $PowerShellPath -Force
if (($PowerShellItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "task_action_path_drift"
}
# Fresh enrollment deliberately records the exact future protected worker path before the
# elevated installer creates it. This helper never executes that path; enrollment later copies,
# Authenticode-verifies, ACL-hardens, and re-attests it before the task can be submitted.
$Contract = Get-FixedTaskContract $Sid $ProgramData $PowerShellPath
$ProfileRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).TrimEnd('\')
$ProfileKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
$RegisteredRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(
    [string](Get-ItemPropertyValue -LiteralPath $ProfileKey -Name ProfileImagePath -ErrorAction Stop))).TrimEnd('\')
if (-not $ProfileRoot.Equals($RegisteredRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "profile_root_identity_drift"
}
Initialize-ProfileRootIdentityType
$ObservedRoot = [RoundhouseRegistrationProfileRoot]::Observe($ProfileRoot)
if (-not $ObservedRoot.FinalPath.Equals($ProfileRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "profile_root_identity_drift"
}
$ProfileRootId = Get-ProfileRootIdentityRecord $Sid $ObservedRoot.FinalPath $ObservedRoot.VolumeSerial $ObservedRoot.FileId
$Xml = ConvertTo-TaskXml $Contract
Assert-TaskXml $Xml $Contract
Register-FixedProfileTask $Xml $Sid
$Observed = Export-ScheduledTask -TaskName $script:TaskName -TaskPath "\"
Assert-TaskXml $Observed $Contract
$ReceiptRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "Roundhouse"
[void][IO.Directory]::CreateDirectory($ReceiptRoot)
$ReceiptPath = Join-Path $ReceiptRoot "profile-task-registration.json"
$Receipt = [ordered]@{
    schema = "roundhouse.profile-task-registration"; schema_version = 1
    task_name = $script:TaskName; target_sid = $Sid; context = $script:ContextName
    task_xml_sha256 = Get-NormalizedTaskXmlSha256 $Observed; password_supplied = $false
    profile_root_id = $ProfileRootId; profile_root_path_sha256 = Get-Sha256Text ($ObservedRoot.FinalPath.ToUpperInvariant())
    registered_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}
$Receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8NoBOM
$Receipt | ConvertTo-Json -Depth 5
