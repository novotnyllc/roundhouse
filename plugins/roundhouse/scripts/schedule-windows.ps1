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
#                 unknown           anything else, reported and never changed.
#   unregister  one obsolete-oneshot task, only while its definition still
#               hashes to the digest the sealed plan carries, it still
#               classifies as obsolete-oneshot and it is not running. Its
#               definition is kept first under
#               %LOCALAPPDATA%\Roundhouse\schedule-removed\, and a copy that
#               cannot be made is a removal that does not happen.
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
    $FileMatch = [regex]::Match([string]$ArgumentsNode.InnerText, '(?i)(?:^|\s)-File\s+"(?<file>[^"]+)"')
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
        $Records.Add([ordered]@{
            name = Get-SafeText $Name 128
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
        [IO.File]::WriteAllText($Backup, $Xml, $Utf8)
        if ((Get-TextSha256 ([IO.File]::ReadAllText($Backup, $Utf8))) -cne $Digest) { throw "backup does not read back" }
    } catch {
        $Outcome.outcome = "failed"
        $Outcome.message = "the definition could not be kept under $RemovedRoot; the task was left in place"
        return $Outcome
    }
    $Outcome.backup = Get-SafeText $Backup 512
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
    $Expected = if ($Value.mode -ceq "inspect") { @("mode", "schema", "schema_version") }
        else { @("digest", "mode", "name", "schema", "schema_version") }
    if (((Get-PropertyNames $Value) -join "`0") -cne ($Expected -join "`0")) {
        throw "Schedule request has unexpected fields"
    }
    if ($Value.mode -ceq "unregister" -and (-not (Test-Pattern $Value.name $OneShotName) -or
            -not (Test-Pattern $Value.digest '^[0-9a-f]{64}$'))) {
        throw "Invalid schedule unregister request"
    }
}

function Invoke-ScheduleRequest([object]$Value) {
    $Result = [ordered]@{
        schema = "roundhouse.schedule-windows-result"; schema_version = 1; mode = ""
        state = "failed"; message = ""; user_sid = ""; tasks = [object[]]@(); outcome = ""; backup = ""
    }
    try {
        Assert-Request $Value
        $Result.mode = [string]$Value.mode
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
            [string]$RunLevel = "", [string]$Extra = "") {
            $Level = if ($RunLevel) { "<RunLevel>$RunLevel</RunLevel>" } else { "" }
            return "<?xml version=`"1.0`" encoding=`"UTF-16`"?><Task version=`"1.3`" xmlns=`"$TaskNamespace`">" +
                "<Principals><Principal id=`"Author`"><UserId>$UserId</UserId><LogonType>InteractiveToken</LogonType>$Level</Principal></Principals>" +
                "$Triggers<Actions Context=`"Author`"><Exec><Command>$Command</Command><Arguments>" +
                [Security.SecurityElement]::Escape($Arguments) + "</Arguments></Exec>$Extra</Actions></Task>"
        }
        $Stale = "Roundhouse-Remaining-0123456789abcdef0123456789abcdef"
        $Fixture = @{}
        $Fixture[$Stale] = @{ Xml = (New-FixtureXml); State = "Ready" }
        $Fixture["RoundhouseBrokerV1"] = @{ Xml = (New-FixtureXml -UserId "S-1-5-18"); State = "Ready" }
        $Cases = [ordered]@{
            "Roundhouse-Trigger-00000000000000000000000000000001" = (New-FixtureXml -Triggers "<Triggers><LogonTrigger /></Triggers>")
            "Roundhouse-Outside-00000000000000000000000000000002" = (New-FixtureXml -Arguments "-File `"C:\Tools\worker.ps1`"")
            "Roundhouse-Other-00000000000000000000000000000003" = (New-FixtureXml -UserId "S-1-5-21-9")
            "Roundhouse-Highest-00000000000000000000000000000004" = (New-FixtureXml -RunLevel "HighestAvailable")
            "Roundhouse-Two-00000000000000000000000000000005" = (New-FixtureXml -Extra "<Exec><Command>cmd.exe</Command></Exec>")
            "Roundhouse-Shell-00000000000000000000000000000006" = (New-FixtureXml -Command "C:\Windows\System32\cmd.exe")
            "Roundhouse-Escape-00000000000000000000000000000007" = (New-FixtureXml -Arguments "-File `"$Temp${Sep}roundhouse-release-gate.649j8Z${Sep}..${Sep}x.ps1`"")
            "RoundhouseFleetFast" = (New-FixtureXml)
        }
        foreach ($Key in $Cases.Keys) { $Fixture[$Key] = @{ Xml = $Cases[$Key]; State = "Ready" } }
        $Script:Denied = $false
        function Get-CurrentUserSid { return $Sid }
        function Get-ScheduledTask {
            [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
            $Names = if ($TaskName) { @($TaskName) } else { @($Fixture.Keys) }
            foreach ($Each in $Names) {
                if ($Fixture.ContainsKey($Each)) {
                    [pscustomobject]@{ TaskName = $Each; TaskPath = "\"; State = $Fixture[$Each].State }
                }
            }
        }
        function Export-ScheduledTask {
            [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
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

        $Inspect = Invoke-ScheduleRequest ([pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "inspect" })
        if ($Inspect.state -cne "completed") { throw "Self-test inspect failed: $($Inspect.message)" }
        $Classes = @{}
        foreach ($Task in $Inspect.tasks) { $Classes[$Task.name] = $Task.class }
        if ($Classes[$Stale] -cne "obsolete-oneshot") { throw "Self-test did not classify the stale one-shot task" }
        if ($Classes["RoundhouseBrokerV1"] -cne "privilege-lane") { throw "Self-test did not recognise the privilege lane task" }
        foreach ($Key in $Cases.Keys) {
            if ($Classes[$Key] -cne "unknown") { throw "Self-test classified a lookalike as removable: $Key" }
        }
        $Line = ConvertTo-ResultLine $Inspect
        if (-not $Line.StartsWith($ResultMarker) -or $Line.Contains("pwsh.exe") -or
            $Utf8.GetString([Convert]::FromBase64String($Line.Substring($ResultMarker.Length))).Contains("release-gate")) {
            throw "Self-test result carries task content or no marker"
        }
        $StaleDigest = Get-TextSha256 $Fixture[$Stale].Xml
        function New-Unregister([string]$Name, [string]$Digest) {
            return [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1
                mode = "unregister"; name = $Name; digest = $Digest }
        }
        $Changed = Invoke-ScheduleRequest (New-Unregister $Stale ("0" * 64))
        if ($Changed.outcome -cne "changed" -or -not $Fixture.ContainsKey($Stale)) { throw "Self-test removed a task whose digest changed" }
        $Fixture[$Stale].State = "Running"
        if ((Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)).outcome -cne "running") { throw "Self-test removed a running task" }
        $Fixture[$Stale].State = "Ready"
        $Lookalike = "Roundhouse-Other-00000000000000000000000000000003"
        $NotObsolete = Invoke-ScheduleRequest (New-Unregister $Lookalike (Get-TextSha256 $Fixture[$Lookalike].Xml))
        if ($NotObsolete.outcome -cne "not-obsolete" -or -not $Fixture.ContainsKey($Lookalike)) { throw "Self-test removed another user's task" }
        $Script:Denied = $true
        $Refused = Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)
        if ($Refused.outcome -cne "refused" -or -not $Fixture.ContainsKey($Stale)) { throw "Self-test did not report an access-denied refusal" }
        $Script:Denied = $false
        $Removed = Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)
        if ($Removed.outcome -cne "removed" -or $Fixture.ContainsKey($Stale) -or
            -not (Test-Path -LiteralPath $Removed.backup) -or
            (Get-TextSha256 ([IO.File]::ReadAllText($Removed.backup, $Utf8))) -cne $StaleDigest) {
            throw "Self-test did not remove the stale task with its definition kept"
        }
        if ((Invoke-ScheduleRequest (New-Unregister $Stale $StaleDigest)).outcome -cne "absent") { throw "Self-test repeat removal was not idempotent" }
        foreach ($Bad in @(
                [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "register" },
                [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "inspect"; argv = "x" },
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
