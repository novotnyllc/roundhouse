# Roundhouse fleet-schedule's native-Windows Task Scheduler backend.
#
# Roundhouse has no native Windows runtime: the CLI is Bash, the fleet store
# is a jj repository, and the Windows host of a WSL distribution is operated
# from that distribution (docs/specs/2026-08-06-dsc-storage-design-v2.md
# §9.2). So no `fleet-run` task is ever registered here. What the WSL
# sibling's `roundhouse fleet-schedule` does need from this side is the
# Task Scheduler's own view of Roundhouse tasks:
#
#   inspect     every task named Roundhouse* (or under \Roundhouse*), each
#               with the SHA-256 of its exported definition and a class:
#                 privilege-lane    RoundhouseBrokerV1/RoundhouseProfileV1,
#                                   owned by enroll-privilege-windows.ps1;
#                 obsolete-oneshot  a trigger-less, one-shot release-gate
#                                   worker task left behind by an earlier
#                                   session (see Get-TaskClass);
#                 unknown           anything else, reported and never changed;
#                                   its name and folder are bounded text, so a
#                                   task such as \Roundhouse\Routine Backup is
#                                   reported rather than failing the inspection.
#   unregister  one obsolete-oneshot task, only while its definition still
#               hashes to the digest the sealed plan carries, it still
#               classifies as obsolete-oneshot and it is not running. Its
#               definition is kept first under
#               %LOCALAPPDATA%\Roundhouse\schedule-removed\, in the encoding its
#               XML declaration names, and the task is checked again after the
#               copy; a copy that cannot be made, or a task that changed while
#               it was made, is a removal that does not happen.
#
# Every request names the Windows machine the WSL side's inventory configures
# (its expected hostname and user), and this session refuses one that is not
# it, before it reads or changes anything.
#
# The sibling starts this script through the WSL interop lane's fixed
# bootstrap (lib/interop.sh): full-path PowerShell 7 started from /mnt/c, so
# it runs natively as the logged-in user, unelevated. Nothing here needs
# elevation: the user deletes only a task registered under its own SID with
# a Limited run level. A refusal is reported as `refused`, never retried.
#
# The single result is one stdout line, prefixed by a marker. No task
# definition's content is ever returned, only its digest.
[CmdletBinding()]
param(
    [object]$Request,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Utf8 = [Text.UTF8Encoding]::new($false)
$ResultMarker = "roundhouse-schedule-result "
$PrivilegeLaneTasks = @("RoundhouseBrokerV1", "RoundhouseProfileV1")
$OneShotName = '^Roundhouse-[A-Za-z0-9]{1,32}-[0-9a-f]{32}$'
$TaskNamespace = "http://schemas.microsoft.com/windows/2004/02/mit/task"
$MaximumTasks = 64
$HostPattern = '^[A-Za-z0-9._-]{1,253}$'
$UserPattern = '^[A-Za-z0-9._@-]{1,128}$'

function Test-Pattern([object]$Value, [string]$Pattern) {
    return $Value -is [string] -and $Value -cmatch $Pattern
}

function Get-PropertyNames([object]$Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return @() }
    $Names = @($Value.PSObject.Properties.Name)
    [Array]::Sort($Names, [StringComparer]::Ordinal)
    return $Names
}

function Get-SafeText([object]$Value, [int]$Limit) {
    $Text = ([string]$Value) -replace '[\x00-\x1f\x7f-\x9f]', ' '
    if ($Text.Length -gt $Limit) { $Text = $Text.Substring(0, $Limit) }
    return $Text
}

function Get-TextSha256([string]$Text) {
    $Hash = [Security.Cryptography.SHA256]::Create()
    try {
        return (-join ($Hash.ComputeHash($Utf8.GetBytes($Text)) | ForEach-Object { $_.ToString("x2") }))
    } finally {
        $Hash.Dispose()
    }
}

function Test-OnWindows {
    return $PSVersionTable.PSEdition -ceq "Desktop" -or $IsWindows -eq $true
}

function Get-CurrentUserSid {
    if (Test-OnWindows) { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    # Off Windows there is no Task Scheduler and no account a task could run
    # as; only the self-check's fixture account stands in, and without it
    # nothing ever classifies as removable.
    return [string]$env:ROUNDHOUSE_SCHEDULE_FIXTURE_SID
}

function Get-SessionIdentity {
    # The machine and account this session runs as. Off Windows only the
    # self-check's fixture identity stands in, and without it no request
    # matches.
    if (Test-OnWindows) {
        return [pscustomobject]@{ Host = [string]$env:COMPUTERNAME; User = [string][Environment]::UserName }
    }
    return [pscustomobject]@{
        Host = [string]$env:ROUNDHOUSE_SCHEDULE_FIXTURE_HOST
        User = [string]$env:ROUNDHOUSE_SCHEDULE_FIXTURE_USER
    }
}

function Assert-SessionIdentity([object]$Value) {
    # The configured Windows sibling, or nothing at all: a request that names
    # another machine or account is refused before any task is read.
    $Session = Get-SessionIdentity
    if ([string]::IsNullOrEmpty($Session.Host) -or [string]::IsNullOrEmpty($Session.User) -or
        -not ([string]$Value.expected_hostname).Equals($Session.Host, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$Value.expected_user).Equals($Session.User, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("This Windows session is $(Get-SafeText $Session.Host 64)\$(Get-SafeText $Session.User 64), " +
            "not the configured $(Get-SafeText $Value.expected_hostname 64)\$(Get-SafeText $Value.expected_user 64)")
    }
    return $Session
}

function Get-DeclaredEncoding([string]$Xml) {
    # The encoding a task definition's XML declaration names, so a kept copy
    # is bytes that declaration describes and loads for a file-based restore.
    # Export-ScheduledTask declares UTF-16: little-endian with its byte order
    # mark, as Task Scheduler itself writes one.
    $Declaration = [regex]::Match($Xml, '^\uFEFF?\s*<\?xml[^>]*?\bencoding\s*=\s*["'']([A-Za-z0-9._-]+)["'']')
    $Name = if ($Declaration.Success) { $Declaration.Groups[1].Value } else { "UTF-8" }
    switch -regex ($Name) {
        '^(?i)utf-?16(le)?$' { return [Text.UnicodeEncoding]::new($false, $true) }
        '^(?i)utf-?8$' { return $Utf8 }
        default { throw "the definition declares an encoding this copy does not write: $(Get-SafeText $Name 32)" }
    }
}

function Get-RemovedRoot {
    $Local = [string]$env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($Local)) { $Local = [Environment]::GetFolderPath("LocalApplicationData") }
    if ([string]::IsNullOrEmpty($Local)) { throw "No local application data directory to keep a removed task in" }
    return [IO.Path]::Combine($Local, "Roundhouse", "schedule-removed")
}

function Get-TaskXml([string]$Name, [string]$Path) {
    return [string](Export-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction Stop)
}

function Get-TaskClass([string]$Name, [string]$Path, [string]$Xml, [string]$UserSid, [string]$TempRoot) {
    # obsolete-oneshot is deliberately narrow: the exact shape a release-gate
    # session registered to run one worker script as the standard user, and
    # nothing that merely resembles it. Every condition must hold:
    #   - in the root folder, named Roundhouse-<word>-<32 hex>;
    #   - no trigger at all (it can only ever have run on demand);
    #   - exactly one action, PowerShell running `-File "<script>.ps1"` from
    #     the user's own %TEMP%\roundhouse-release-gate.<id>\ directory;
    #   - one principal, this very user's SID, at the Limited run level.
    if ($Path -ceq "\" -and $Name -cin $PrivilegeLaneTasks) { return "privilege-lane" }
    if ($Path -cne "\" -or -not (Test-Pattern $Name $OneShotName) -or [string]::IsNullOrEmpty($UserSid)) {
        return "unknown"
    }
    try { $Document = [xml]$Xml } catch { return "unknown" }
    $Ns = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Ns.AddNamespace("t", $TaskNamespace)
    if (@($Document.SelectNodes("/t:Task/t:Triggers/*", $Ns)).Count -ne 0) { return "unknown" }
    $Actions = @($Document.SelectNodes("/t:Task/t:Actions/*", $Ns))
    if ($Actions.Count -ne 1 -or $Actions[0].LocalName -cne "Exec") { return "unknown" }
    $CommandNode = $Actions[0].SelectSingleNode("t:Command", $Ns)
    $ArgumentsNode = $Actions[0].SelectSingleNode("t:Arguments", $Ns)
    if ($null -eq $CommandNode -or $null -eq $ArgumentsNode) { return "unknown" }
    $Leaf = @(([string]$CommandNode.InnerText).Trim('"') -split '[\\/]')[-1]
    if ($Leaf -inotin @("pwsh.exe", "powershell.exe")) { return "unknown" }
    # The WHOLE invocation: only these switches, then `-File "<path>"`, then
    # nothing. Command-mode text that merely mentions `-File` is not a worker.
    $FileMatch = [regex]::Match([string]$ArgumentsNode.InnerText,
        '(?i)^\s*(?:-(?:NoLogo|NoProfile|NonInteractive)\s+)*-File\s+"(?<file>[^"]+)"\s*$')
    if (-not $FileMatch.Success) { return "unknown" }
    $File = $FileMatch.Groups["file"].Value
    $Root = $TempRoot.TrimEnd([char[]]@('\', '/'))
    if ([string]::IsNullOrEmpty($Root) -or $File.Length -le $Root.Length + 1 -or
        -not $File.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $File[$Root.Length] -notin @([char]'\', [char]'/')) {
        return "unknown"
    }
    if ($File.Substring($Root.Length + 1) -notmatch
        '^roundhouse-release-gate\.[A-Za-z0-9]{6,32}[\\/][A-Za-z0-9._-]{1,128}\.ps1$') {
        return "unknown"
    }
    $Principals = @($Document.SelectNodes("/t:Task/t:Principals/t:Principal", $Ns))
    if ($Principals.Count -ne 1) { return "unknown" }
    $UserNode = $Principals[0].SelectSingleNode("t:UserId", $Ns)
    if ($null -eq $UserNode -or -not ([string]$UserNode.InnerText).Equals($UserSid, [StringComparison]::OrdinalIgnoreCase)) {
        return "unknown"
    }
    $RunLevel = $Principals[0].SelectSingleNode("t:RunLevel", $Ns)
    if ($null -ne $RunLevel -and [string]$RunLevel.InnerText -cne "LeastPrivilege") { return "unknown" }
    $LogonType = $Principals[0].SelectSingleNode("t:LogonType", $Ns)
    if ($null -ne $LogonType -and [string]$LogonType.InnerText -cnotin @("InteractiveToken", "S4U")) {
        return "unknown"
    }
    return "obsolete-oneshot"
}

function Get-RoundhouseTasks {
    $UserSid = Get-CurrentUserSid
    $TempRoot = [IO.Path]::GetTempPath()
    $Tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        ([string]$_.TaskName).StartsWith("Roundhouse", [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.TaskPath).StartsWith("\Roundhouse", [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object -Property TaskPath, TaskName)
    if ($Tasks.Count -gt $MaximumTasks) { throw "More than $MaximumTasks Roundhouse tasks; refusing to report a partial list" }
    $Records = [Collections.Generic.List[object]]::new()
    foreach ($Task in $Tasks) {
        $Name = [string]$Task.TaskName
        $Path = [string]$Task.TaskPath
        $Xml = Get-TaskXml $Name $Path
        $LastRun = ""
        $LastResult = $null
        $Info = Get-ScheduledTaskInfo -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
        if ($null -ne $Info) {
            # A task that never ran reports 1999-11-30; that is no run at all.
            if ($Info.LastRunTime -is [DateTime] -and $Info.LastRunTime.Year -ge 2000) {
                $LastRun = $Info.LastRunTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            if ($null -ne $Info.LastTaskResult) { $LastResult = [long]$Info.LastTaskResult }
        }
        # An unknown task's name and folder are reported, never acted on:
        # bounded text with no control characters and no path separator
        # inside a name, so any task under a Roundhouse folder can be listed.
        $Records.Add([ordered]@{
            name = ((Get-SafeText $Name 128) -replace '[\\/]', '_')
            path = Get-SafeText $Path 256
            class = Get-TaskClass $Name $Path $Xml $UserSid $TempRoot
            digest = Get-TextSha256 $Xml
            state = Get-SafeText $Task.State 32
            last_run = $LastRun
            last_result = $LastResult
        })
    }
    return ,$Records.ToArray()
}

function Test-AccessDenied([object]$ErrorRecord) {
    $Exception = $ErrorRecord.Exception
    return $Exception -is [UnauthorizedAccessException] -or
        $Exception.HResult -eq -2147024891 -or
        [string]$ErrorRecord.CategoryInfo.Category -ceq "PermissionDenied" -or
        ([string]$Exception.Message) -match 'Access is denied'
}

function Invoke-Unregister([string]$Name, [string]$Digest) {
    $Outcome = [ordered]@{ outcome = ""; backup = ""; message = "" }
    $Task = Get-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction SilentlyContinue
    if ($null -eq $Task) {
        $Outcome.outcome = "absent"
        return $Outcome
    }
    $Xml = Get-TaskXml $Name "\"
    if ((Get-TextSha256 $Xml) -cne $Digest) {
        $Outcome.outcome = "changed"
        $Outcome.message = "the task's definition changed since the plan was sealed"
        return $Outcome
    }
    if ((Get-TaskClass $Name "\" $Xml (Get-CurrentUserSid) ([IO.Path]::GetTempPath())) -cne "obsolete-oneshot") {
        $Outcome.outcome = "not-obsolete"
        $Outcome.message = "the task no longer classifies as an obsolete one-shot task"
        return $Outcome
    }
    if ([string]$Task.State -ceq "Running") {
        $Outcome.outcome = "running"
        $Outcome.message = "the task is running"
        return $Outcome
    }
    # Kept, never discarded: the definition is copied out and read back before
    # the task is removed, so a failed copy leaves the task exactly as it was.
    $RemovedRoot = Get-RemovedRoot
    [void][IO.Directory]::CreateDirectory($RemovedRoot)
    $Backup = [IO.Path]::Combine($RemovedRoot, "$Name.xml")
    if (Test-Path -LiteralPath $Backup) {
        $Backup = [IO.Path]::Combine($RemovedRoot, "$Name.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).xml")
    }
    try {
        if (Test-Path -LiteralPath $Backup) { throw "backup path exists" }
        $Encoding = Get-DeclaredEncoding $Xml
        [IO.File]::WriteAllText($Backup, $Xml, $Encoding)
        if ((Get-TextSha256 ([IO.File]::ReadAllText($Backup, $Encoding))) -cne $Digest) { throw "backup does not read back" }
        # The copy is only a copy if it loads as the XML it declares.
        [void][Xml.XmlDocument]::new().Load($Backup)
    } catch {
        $Outcome.outcome = "failed"
        $Outcome.message = "the definition could not be kept under $RemovedRoot; the task was left in place"
        return $Outcome
    }
    $Outcome.backup = Get-SafeText $Backup 512
    # The copy took time: the task is checked again, as it is now, before it
    # is removed. One that changed, stopped classifying or started running in
    # between is left in place, its copy kept.
    $Task = Get-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction SilentlyContinue
    if ($null -eq $Task) {
        $Outcome.outcome = "absent"
        return $Outcome
    }
    $Xml = Get-TaskXml $Name "\"
    if ((Get-TextSha256 $Xml) -cne $Digest) {
        $Outcome.outcome = "changed"
        $Outcome.message = "the task's definition changed while its copy was made; it was left in place"
        return $Outcome
    }
    if ((Get-TaskClass $Name "\" $Xml (Get-CurrentUserSid) ([IO.Path]::GetTempPath())) -cne "obsolete-oneshot") {
        $Outcome.outcome = "not-obsolete"
        $Outcome.message = "the task no longer classifies as an obsolete one-shot task"
        return $Outcome
    }
    if ([string]$Task.State -ceq "Running") {
        $Outcome.outcome = "running"
        $Outcome.message = "the task started running while its copy was made"
        return $Outcome
    }
    try {
        Unregister-ScheduledTask -TaskName $Name -TaskPath "\" -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        if (Test-AccessDenied $_) {
            $Outcome.outcome = "refused"
            $Outcome.message = "Task Scheduler refused this session (Access is denied)"
        } else {
            $Outcome.outcome = "failed"
            $Outcome.message = Get-SafeText $_.Exception.Message 512
        }
        return $Outcome
    }
    if ($null -ne (Get-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction SilentlyContinue)) {
        $Outcome.outcome = "failed"
        $Outcome.message = "the task is still registered after Unregister-ScheduledTask"
        return $Outcome
    }
    $Outcome.outcome = "removed"
    return $Outcome
}

function Assert-Request([object]$Value) {
    if ($null -eq $Value -or $Value.schema -cne "roundhouse.schedule-windows-request" -or
        $Value.schema_version -ne 1 -or -not (Test-Pattern $Value.mode '^(inspect|unregister)$')) {
        throw "Invalid schedule request"
    }
    $Expected = if ($Value.mode -ceq "inspect") { @("expected_hostname", "expected_user", "mode", "schema", "schema_version") }
        else { @("digest", "expected_hostname", "expected_user", "mode", "name", "schema", "schema_version") }
    if (((Get-PropertyNames $Value) -join "`0") -cne ($Expected -join "`0")) {
        throw "Schedule request has unexpected fields"
    }
    if (-not (Test-Pattern $Value.expected_hostname $HostPattern) -or -not (Test-Pattern $Value.expected_user $UserPattern)) {
        throw "Schedule request names no valid Windows machine"
    }
    if ($Value.mode -ceq "unregister" -and (-not (Test-Pattern $Value.name $OneShotName) -or
            -not (Test-Pattern $Value.digest '^[0-9a-f]{64}$'))) {
        throw "Invalid schedule unregister request"
    }
}

function Invoke-ScheduleRequest([object]$Value) {
    $Result = [ordered]@{
        schema = "roundhouse.schedule-windows-result"; schema_version = 1; mode = ""
        state = "failed"; message = ""; host = ""; user = ""; user_sid = ""; tasks = [object[]]@(); outcome = ""; backup = ""
    }
    try {
        Assert-Request $Value
        $Result.mode = [string]$Value.mode
        $Session = Assert-SessionIdentity $Value
        $Result.host = Get-SafeText $Session.Host 253
        $Result.user = Get-SafeText $Session.User 128
        $Result.user_sid = Get-SafeText (Get-CurrentUserSid) 184
        if ($Value.mode -ceq "inspect") {
            $Result.tasks = Get-RoundhouseTasks
        } else {
            $Removal = Invoke-Unregister ([string]$Value.name) ([string]$Value.digest)
            $Result.outcome = $Removal.outcome
            $Result.backup = $Removal.backup
            $Result.message = $Removal.message
        }
        $Result.state = "completed"
    } catch {
        $Result.state = "failed"
        $Result.message = Get-SafeText $_.Exception.Message 1024
    }
    return $Result
}

function ConvertTo-ResultLine([object]$Result) {
    $Json = ConvertTo-Json -InputObject $Result -Compress -Depth 6
    return $ResultMarker + [Convert]::ToBase64String($Utf8.GetBytes($Json))
}

if ($SelfTest) {
    $FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("roundhouse-schedule-selftest-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($FixtureRoot)
    $SavedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $FixtureRoot
        $Sid = "S-1-12-1-1-2-3-4"
        $Temp = [IO.Path]::GetTempPath().TrimEnd([char[]]@('\', '/'))
        $Sep = [IO.Path]::DirectorySeparatorChar
        $Script = "$Temp${Sep}roundhouse-release-gate.649j8Z${Sep}remaining-batch09-apply-limited-worker.ps1"
        function New-FixtureXml([string]$UserId = $Sid, [string]$Triggers = "<Triggers />",
            [string]$Command = 'C:\Program Files\PowerShell\7\pwsh.exe',
            [string]$Arguments = "-NoLogo -NoProfile -NonInteractive -File `"$Script`"",
            [string]$RunLevel = "", [string]$Extra = "", [string]$Encoding = "UTF-16") {
            $Level = if ($RunLevel) { "<RunLevel>$RunLevel</RunLevel>" } else { "" }
            return "<?xml version=`"1.0`" encoding=`"$Encoding`"?><Task version=`"1.3`" xmlns=`"$TaskNamespace`">" +
                "<Principals><Principal id=`"Author`"><UserId>$UserId</UserId><LogonType>InteractiveToken</LogonType>$Level</Principal></Principals>" +
                "$Triggers<Actions Context=`"Author`"><Exec><Command>$Command</Command><Arguments>" +
                [Security.SecurityElement]::Escape($Arguments) + "</Arguments></Exec>$Extra</Actions></Task>"
        }
        $Stale = "Roundhouse-Remaining-0123456789abcdef0123456789abcdef"
        $Latin = "Roundhouse-Latin-0123456789abcdef0123456789abcdef"
        $Fixture = @{}
        $Fixture[$Stale] = @{ Xml = (New-FixtureXml); State = "Ready"; Path = "\" }
        $Fixture[$Latin] = @{ Xml = (New-FixtureXml -Encoding "ISO-8859-1"); State = "Ready"; Path = "\" }
        $Fixture["RoundhouseBrokerV1"] = @{ Xml = (New-FixtureXml -UserId "S-1-5-18"); State = "Ready"; Path = "\" }
        # A task of the operator's own under a Roundhouse folder: any name is
        # listed as unknown, and never fails the inspection.
        $Fixture["Routine Backup (weekly)"] = @{ Xml = (New-FixtureXml); State = "Ready"; Path = "\Roundhouse\" }
        $Fixture["Nightly/Copy`tB"] = @{ Xml = (New-FixtureXml); State = "Ready"; Path = "\Roundhouse\" }
        $Cases = [ordered]@{
            "Roundhouse-Trigger-00000000000000000000000000000001" = (New-FixtureXml -Triggers "<Triggers><LogonTrigger /></Triggers>")
            "Roundhouse-Outside-00000000000000000000000000000002" = (New-FixtureXml -Arguments "-File `"C:\Tools\worker.ps1`"")
            "Roundhouse-Other-00000000000000000000000000000003" = (New-FixtureXml -UserId "S-1-5-21-9")
            "Roundhouse-Highest-00000000000000000000000000000004" = (New-FixtureXml -RunLevel "HighestAvailable")
            "Roundhouse-Two-00000000000000000000000000000005" = (New-FixtureXml -Extra "<Exec><Command>cmd.exe</Command></Exec>")
            "Roundhouse-Shell-00000000000000000000000000000006" = (New-FixtureXml -Command "C:\Windows\System32\cmd.exe")
            "Roundhouse-Escape-00000000000000000000000000000007" = (New-FixtureXml -Arguments "-File `"$Temp${Sep}roundhouse-release-gate.649j8Z${Sep}..${Sep}x.ps1`"")
            "Roundhouse-Command-00000000000000000000000000000008" = (New-FixtureXml -Arguments "-Command Write-Output 'x -File `"$Temp${Sep}roundhouse-release-gate.649j8Z${Sep}w.ps1`"'")
            "RoundhouseFleetFast" = (New-FixtureXml)
        }
        foreach ($Key in $Cases.Keys) { $Fixture[$Key] = @{ Xml = $Cases[$Key]; State = "Ready"; Path = "\" } }
        $Script:Denied = $false
        # A task that changes (or starts) while its copy is being made: the
        # Nth export of it returns another definition, the Nth look shows it
        # running.
        $Script:ChangeOnExport = 0
        $Script:RunOnLook = 0
        $Script:Exports = 0
        $Script:Looks = 0
        function Get-CurrentUserSid { return $Sid }
        function Get-SessionIdentity { return [pscustomobject]@{ Host = "IRIS"; User = "Claire" } }
        function Get-ScheduledTask {
            [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
            $Names = if ($TaskName) { @($TaskName) } else { @($Fixture.Keys) }
            foreach ($Each in $Names) {
                if ($Fixture.ContainsKey($Each) -and (-not $TaskPath -or $Fixture[$Each].Path -ceq $TaskPath)) {
                    $Script:Looks++
                    $State = if ($Script:RunOnLook -gt 0 -and $Script:Looks -ge $Script:RunOnLook) { "Running" } else { $Fixture[$Each].State }
                    [pscustomobject]@{ TaskName = $Each; TaskPath = $Fixture[$Each].Path; State = $State }
                }
            }
        }
        function Export-ScheduledTask {
            [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
            $Script:Exports++
            if ($Script:ChangeOnExport -gt 0 -and $Script:Exports -ge $Script:ChangeOnExport) {
                return $Fixture[$TaskName].Xml.Replace("<Triggers />", "<Triggers></Triggers>")
            }
            return $Fixture[$TaskName].Xml
        }
        function Get-ScheduledTaskInfo {
            [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
            return [pscustomobject]@{ LastRunTime = [DateTime]::new(2026, 9, 22, 9, 6, 11, [DateTimeKind]::Utc); LastTaskResult = 0 }
        }
        function Unregister-ScheduledTask {
            [CmdletBinding()] param([string]$TaskName, [string]$TaskPath, [switch]$Confirm)
            if ($Script:Denied) { throw [UnauthorizedAccessException]::new("Access is denied.") }
            [void]$Fixture.Remove($TaskName)
        }
        $Identity = @{ expected_hostname = "iris"; expected_user = "claire" }
        function New-Inspect([hashtable]$Who = $Identity) {
            return [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "inspect"
                expected_hostname = $Who.expected_hostname; expected_user = $Who.expected_user }
        }

        $Inspect = Invoke-ScheduleRequest (New-Inspect)
        if ($Inspect.state -cne "completed") { throw "Self-test inspect failed: $($Inspect.message)" }
        if ($Inspect.host -cne "IRIS" -or $Inspect.user -cne "Claire") { throw "Self-test result did not name the session's identity" }
        $Classes = @{}
        foreach ($Task in $Inspect.tasks) { $Classes[$Task.path + $Task.name] = $Task.class }
        if ($Classes["\$Stale"] -cne "obsolete-oneshot") { throw "Self-test did not classify the stale one-shot task" }
        if ($Classes["\RoundhouseBrokerV1"] -cne "privilege-lane") { throw "Self-test did not recognise the privilege lane task" }
        if ($Classes["\Roundhouse\Routine Backup (weekly)"] -cne "unknown") { throw "Self-test did not list a foldered task of another name as unknown" }
        # Reported as bounded text: no separator inside a name, no control
        # character.
        if ($Classes["\Roundhouse\Nightly_Copy B"] -cne "unknown") { throw "Self-test reported an unbounded task name" }
        foreach ($Key in $Cases.Keys) {
            if ($Classes["\$Key"] -cne "unknown") { throw "Self-test classified a lookalike as removable: $Key" }
        }
        # Another machine or account is refused before anything is read.
        foreach ($Other in @(@{ expected_hostname = "other-pc"; expected_user = "claire" },
                @{ expected_hostname = "iris"; expected_user = "someone" })) {
            $Refused = Invoke-ScheduleRequest (New-Inspect $Other)
            if ($Refused.state -cne "failed" -or $Refused.tasks.Count -ne 0 -or $Refused.message -notmatch 'not the configured') {
                throw "Self-test inspected the Task Scheduler for another configured machine"
            }
        }
        $Line = ConvertTo-ResultLine $Inspect
        if (-not $Line.StartsWith($ResultMarker) -or $Line.Contains("pwsh.exe") -or
            $Utf8.GetString([Convert]::FromBase64String($Line.Substring($ResultMarker.Length))).Contains("release-gate")) {
            throw "Self-test result carries task content or no marker"
        }
        $StaleDigest = Get-TextSha256 $Fixture[$Stale].Xml
        function New-Unregister([string]$Name, [string]$Digest, [hashtable]$Who = $Identity) {
            return [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1
                mode = "unregister"; name = $Name; digest = $Digest
                expected_hostname = $Who.expected_hostname; expected_user = $Who.expected_user }
        }
        $Elsewhere = Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest @{ expected_hostname = "other-pc"; expected_user = "claire" })
        if ($Elsewhere.state -cne "failed" -or -not $Fixture.ContainsKey($Stale)) { throw "Self-test removed a task for another configured machine" }
        $Changed = Invoke-ScheduleRequest (New-Unregister $Stale ("0" * 64))
        if ($Changed.outcome -cne "changed" -or -not $Fixture.ContainsKey($Stale)) { throw "Self-test removed a task whose digest changed" }
        $Fixture[$Stale].State = "Running"
        if ((Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)).outcome -cne "running") { throw "Self-test removed a running task" }
        $Fixture[$Stale].State = "Ready"
        $Lookalike = "Roundhouse-Other-00000000000000000000000000000003"
        $NotObsolete = Invoke-ScheduleRequest (New-Unregister $Lookalike (Get-TextSha256 $Fixture[$Lookalike].Xml))
        if ($NotObsolete.outcome -cne "not-obsolete" -or -not $Fixture.ContainsKey($Lookalike)) { throw "Self-test removed another user's task" }
        # Checked again after the copy: a definition that changed, or a task
        # that started, while it was copied is left in place.
        $Script:Exports = 0; $Script:ChangeOnExport = 2
        $During = Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)
        $Script:ChangeOnExport = 0
        if ($During.outcome -cne "changed" -or -not $Fixture.ContainsKey($Stale) -or -not (Test-Path -LiteralPath $During.backup)) {
            throw "Self-test removed a task whose definition changed while its copy was made"
        }
        Remove-Item -LiteralPath $During.backup
        $Script:Looks = 0; $Script:RunOnLook = 2
        $Started = Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)
        $Script:RunOnLook = 0
        if ($Started.outcome -cne "running" -or -not $Fixture.ContainsKey($Stale)) {
            throw "Self-test removed a task that started while its copy was made"
        }
        Remove-Item -LiteralPath $Started.backup
        # A declaration this copy cannot honour is no copy, and no removal.
        $LatinOutcome = Invoke-ScheduleRequest (New-Unregister $Latin (Get-TextSha256 $Fixture[$Latin].Xml))
        if ($LatinOutcome.outcome -cne "failed" -or -not $Fixture.ContainsKey($Latin)) {
            throw "Self-test removed a task whose definition could not be kept in its declared encoding"
        }
        $Script:Denied = $true
        $Refused = Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)
        if ($Refused.outcome -cne "refused" -or -not $Fixture.ContainsKey($Stale)) { throw "Self-test did not report an access-denied refusal" }
        Remove-Item -LiteralPath $Refused.backup
        $Script:Denied = $false
        $Removed = Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)
        if ($Removed.outcome -cne "removed" -or $Fixture.ContainsKey($Stale) -or
            -not (Test-Path -LiteralPath $Removed.backup) -or
            (Get-TextSha256 ([IO.File]::ReadAllText($Removed.backup, [Text.UnicodeEncoding]::new($false, $true)))) -cne $StaleDigest) {
            throw "Self-test did not remove the stale task with its definition kept"
        }
        # Kept as the UTF-16 it declares, byte order mark first, and loadable
        # as XML for a file-based restore.
        $Bytes = [IO.File]::ReadAllBytes($Removed.backup)
        if ($Bytes.Length -lt 2 -or $Bytes[0] -ne 0xFF -or $Bytes[1] -ne 0xFE) { throw "Self-test backup is not the UTF-16 its declaration names" }
        try { [void][Xml.XmlDocument]::new().Load($Removed.backup) } catch { throw "Self-test backup does not load as XML: $($_.Exception.Message)" }
        if ((Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)).outcome -cne "absent") { throw "Self-test repeat removal was not idempotent" }
        foreach ($Bad in @(
                [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "register"; expected_hostname = "iris"; expected_user = "claire" },
                [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "inspect"; expected_hostname = "iris"; expected_user = "claire"; argv = "x" },
                [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "inspect" },
                (New-Inspect @{ expected_hostname = "iris\x"; expected_user = "claire" }),
                (New-Unregister "RoundhouseBrokerV1" $StaleDigest),
                (New-Unregister $Stale "ABC"))) {
            if ((Invoke-ScheduleRequest $Bad).state -cne "failed") { throw "Self-test accepted an invalid request" }
        }
    } finally {
        $env:LOCALAPPDATA = $SavedLocal
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output "PASS: schedule-windows fixture-safe self-check"
    exit 0
}

Write-Output (ConvertTo-ResultLine (Invoke-ScheduleRequest $Request))
