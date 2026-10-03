# Roundhouse fleet-schedule's native-Windows Task Scheduler backend.
#
# Roundhouse has no native Windows runtime: the CLI is Bash, the fleet store
# is a jj repository, and the Windows host of a WSL distribution is operated
# from that distribution (docs/specs/2026-08-06-dsc-storage-design-v2.md
# §9.2). So no `fleet-run` task is ever registered here. What the WSL
# sibling's `roundhouse fleet-schedule` does need from this side is the
# Task Scheduler's own view of Roundhouse tasks, and the ONE task native
# Windows does get: RoundhousePluginCurrency, which keeps this user's plugins
# current (scripts/plugins-windows.ps1):
#
#   inspect     every task named Roundhouse* (or under \Roundhouse*), each
#               with the SHA-256 of its exported definition and a class:
#                 privilege-lane    RoundhouseBrokerV1/RoundhouseProfileV1,
#                                   owned by enroll-privilege-windows.ps1;
#                 obsolete-oneshot  a trigger-less, one-shot release-gate
#                                   worker task left behind by an earlier
#                                   session (see Get-TaskClass);
#                 plugin-currency   \RoundhousePluginCurrency, whatever its
#                                   definition; reported with the digest of
#                                   the script bundle it runs, when it is
#                                   exactly the definition `register` writes
#                                   (Get-CurrencyBundle), and with the last
#                                   run's status file;
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
#               it was made, is a removal that does not happen. The plugin
#               currency task is unregistered the same way, by `uninstall`.
#   register    the plugin currency task: the bundle (plugins-windows.ps1 and
#               the hook helper beside it) written under
#               %LOCALAPPDATA%\Roundhouse\plugin-currency\bundles\<digest>\ and
#               checked against the sealed digest, then the task registered
#               to run it every 20 minutes, per-user, unelevated, with no
#               window and a 15-minute limit — only while the task is still
#               the definition the plan observed (or still absent).
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
$CurrencyName = "RoundhousePluginCurrency"
$CurrencyInterval = "PT20M"
$CurrencyLimit = "PT15M"
$CurrencyBoundary = "2026-01-01T00:00:00"
$CurrencyFiles = @("plugins-windows.ps1", "codex-plugin-hooks.mjs")
$MaximumBundleBytes = 1048576

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
    # Named, never "unknown" or "obsolete": install keeps it current and
    # uninstall removes it, whatever its definition says.
    if ($Path -ceq "\" -and $Name -ceq $CurrencyName) { return "plugin-currency" }
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

function Get-BytesSha256([byte[]]$Bytes) {
    $Hash = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($Hash.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") })) } finally { $Hash.Dispose() }
}

function Get-CurrencyRoot {
    $Local = [string]$env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($Local)) { $Local = [Environment]::GetFolderPath("LocalApplicationData") }
    if ([string]::IsNullOrEmpty($Local)) { throw "No local application data directory for the plugin currency task" }
    return [IO.Path]::Combine($Local, "Roundhouse", "plugin-currency")
}

function Get-BundleDigest([string[]]$FileDigests) {
    # One digest over the bundle's files, in their fixed order; the WSL side
    # computes the same (fleet_schedule_windows_bundle).
    $Text = ""
    for ($Index = 0; $Index -lt $CurrencyFiles.Count; $Index++) { $Text += "$($CurrencyFiles[$Index]) $($FileDigests[$Index])`n" }
    return Get-TextSha256 $Text
}

function Get-BundlesRoot {
    # Normalised (a doubled separator in %LOCALAPPDATA% is the same folder),
    # so every comparison below is of one spelling.
    return [IO.Path]::GetFullPath([IO.Path]::Combine((Get-CurrencyRoot), "bundles"))
}

function Get-BundleDirectory([string]$Bundle) {
    return [IO.Path]::Combine((Get-BundlesRoot), $Bundle.Substring(0, 16))
}

function Get-DirectoryBundle([string]$Directory) {
    # The digest of the bundle on disk in DIRECTORY, or "" when a file is
    # missing or unreadable.
    try {
        $Digests = foreach ($File in $CurrencyFiles) {
            Get-BytesSha256 ([IO.File]::ReadAllBytes([IO.Path]::Combine($Directory, $File)))
        }
        return Get-BundleDigest @($Digests)
    } catch {
        return ""
    }
}

function Get-PwshPath {
    # The PowerShell 7 the interop lane itself starts (lib/interop.sh).
    return 'C:\Program Files\PowerShell\7\pwsh.exe'
}

function Get-ConhostPath {
    $Windows = [string]$env:WINDIR
    if ([string]::IsNullOrEmpty($Windows)) { $Windows = 'C:\Windows' }
    return "$Windows\System32\conhost.exe"
}

function New-CurrencyTaskXml([string]$UserSid, [string]$ScriptPath) {
    # The ONE definition `register` writes: this user, its own token, the
    # least privilege; every 20 minutes from a fixed boundary; one instance at
    # a time, stopped after 15 minutes; PowerShell 7 started headless (no
    # window) on the bundle's script.
    $Arguments = "--headless `"$(Get-PwshPath)`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    return "<?xml version=`"1.0`" encoding=`"UTF-16`"?>`r`n" +
        "<Task version=`"1.4`" xmlns=`"$TaskNamespace`">" +
        "<RegistrationInfo><Description>Roundhouse: keeps this user's Claude Code and Codex plugins current (roundhouse fleet-schedule install, from the WSL side)</Description><URI>\$CurrencyName</URI></RegistrationInfo>" +
        "<Principals><Principal id=`"Author`"><UserId>$([Security.SecurityElement]::Escape($UserSid))</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>" +
        "<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>" +
        "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable>" +
        "<IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>" +
        "<ExecutionTimeLimit>$CurrencyLimit</ExecutionTimeLimit><Enabled>true</Enabled></Settings>" +
        "<Triggers><TimeTrigger><StartBoundary>$CurrencyBoundary</StartBoundary><Repetition><Interval>$CurrencyInterval</Interval></Repetition><Enabled>true</Enabled></TimeTrigger></Triggers>" +
        "<Actions Context=`"Author`"><Exec><Command>$([Security.SecurityElement]::Escape((Get-ConhostPath)))</Command>" +
        "<Arguments>$([Security.SecurityElement]::Escape($Arguments))</Arguments></Exec></Actions></Task>"
}

function Get-CurrencyBundle([string]$Xml, [string]$UserSid) {
    # The digest of the bundle the plugin currency task runs, when its
    # definition is exactly the one `register` writes (other elements the
    # Task Scheduler adds aside): one headless PowerShell 7 action on
    # bundles\<16 hex>\plugins-windows.ps1, this user at the least privilege,
    # one 20-minute time trigger, the 15-minute limit. Otherwise "", and
    # install registers it again.
    try { $Document = [xml]$Xml } catch { return "" }
    $Ns = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $Ns.AddNamespace("t", $TaskNamespace)
    $Actions = @($Document.SelectNodes("/t:Task/t:Actions/*", $Ns))
    if ($Actions.Count -ne 1 -or $Actions[0].LocalName -cne "Exec") { return "" }
    $Command = $Actions[0].SelectSingleNode("t:Command", $Ns)
    $ArgumentsNode = $Actions[0].SelectSingleNode("t:Arguments", $Ns)
    if ($null -eq $Command -or $null -eq $ArgumentsNode -or
        -not ([string]$Command.InnerText).Equals((Get-ConhostPath), [StringComparison]::OrdinalIgnoreCase)) { return "" }
    $Match = [regex]::Match([string]$ArgumentsNode.InnerText,
        '^--headless "(?<pwsh>[^"]+)" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "(?<file>[^"]+)"$')
    if (-not $Match.Success -or -not $Match.Groups["pwsh"].Value.Equals((Get-PwshPath), [StringComparison]::OrdinalIgnoreCase)) { return "" }
    try { $File = [IO.Path]::GetFullPath($Match.Groups["file"].Value) } catch { return "" }
    $Bundles = Get-BundlesRoot
    $Directory = [IO.Path]::GetDirectoryName($File)
    if (-not ([string][IO.Path]::GetDirectoryName($Directory)).Equals($Bundles, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Directory) -cnotmatch '^[0-9a-f]{16}$' -or
        [IO.Path]::GetFileName($File) -cne $CurrencyFiles[0]) { return "" }
    $Principals = @($Document.SelectNodes("/t:Task/t:Principals/t:Principal", $Ns))
    if ($Principals.Count -ne 1 -or [string]::IsNullOrEmpty($UserSid)) { return "" }
    $UserNode = $Principals[0].SelectSingleNode("t:UserId", $Ns)
    $RunLevel = $Principals[0].SelectSingleNode("t:RunLevel", $Ns)
    $LogonType = $Principals[0].SelectSingleNode("t:LogonType", $Ns)
    if ($null -eq $UserNode -or -not ([string]$UserNode.InnerText).Equals($UserSid, [StringComparison]::OrdinalIgnoreCase) -or
        ($null -ne $RunLevel -and [string]$RunLevel.InnerText -cne "LeastPrivilege") -or
        $null -eq $LogonType -or [string]$LogonType.InnerText -cne "InteractiveToken") { return "" }
    $Triggers = @($Document.SelectNodes("/t:Task/t:Triggers/*", $Ns))
    if ($Triggers.Count -ne 1 -or $Triggers[0].LocalName -cne "TimeTrigger") { return "" }
    $Interval = $Triggers[0].SelectSingleNode("t:Repetition/t:Interval", $Ns)
    $Boundary = $Triggers[0].SelectSingleNode("t:StartBoundary", $Ns)
    $TriggerOn = $Triggers[0].SelectSingleNode("t:Enabled", $Ns)
    $TaskOn = $Document.SelectSingleNode("/t:Task/t:Settings/t:Enabled", $Ns)
    $Limit = $Document.SelectSingleNode("/t:Task/t:Settings/t:ExecutionTimeLimit", $Ns)
    if ($null -eq $Interval -or [string]$Interval.InnerText -cne $CurrencyInterval -or
        $null -eq $Boundary -or [string]$Boundary.InnerText -cne $CurrencyBoundary -or
        $null -eq $Limit -or [string]$Limit.InnerText -cne $CurrencyLimit) { return "" }
    # A disabled task, or a disabled trigger, runs nothing: not current.
    if (($null -ne $TriggerOn -and [string]$TriggerOn.InnerText -cne "true") -or
        ($null -ne $TaskOn -and [string]$TaskOn.InnerText -cne "true")) { return "" }
    $Bundle = Get-DirectoryBundle $Directory
    if ($Bundle -and $Bundle.Substring(0, 16) -ceq [IO.Path]::GetFileName($Directory)) { return $Bundle }
    return ""
}

function Get-CurrencyStatus {
    # The last plugin currency run's status file, bounded; $null when there
    # is none or it is not one.
    try {
        $Path = [IO.Path]::Combine((Get-CurrencyRoot), "status.json")
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -gt 65536) { return $null }
        $Status = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($Status.schema -cne "roundhouse.plugin-currency-status" -or $Status.schema_version -ne 1 -or
        [string]$Status.state -cnotin @("running", "current", "held", "timeout", "failed")) { return $null }
    $Time = {
        param($Value)
        if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
        if ([string]$Value -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$') { return [string]$Value }
        return ""
    }
    return [ordered]@{
        state = [string]$Status.state
        version = if ([string]$Status.version -cmatch '^[0-9A-Za-z.+-]{1,64}$') { [string]$Status.version } else { "" }
        started_at = & $Time $Status.started_at
        finished_at = & $Time $Status.finished_at
        updated = [Math]::Max(0, [Math]::Min(100000, [int]$Status.updated))
        held = [Math]::Max(0, [Math]::Min(100000, [int]$Status.held))
        messages = [string[]]@(@($Status.messages) | Select-Object -First 32 | ForEach-Object { Get-SafeText $_ 256 })
    }
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
        $Class = Get-TaskClass $Name $Path $Xml $UserSid $TempRoot
        # An unknown task's name and folder are reported, never acted on:
        # bounded text with no control characters and no path separator
        # inside a name, so any task under a Roundhouse folder can be listed.
        $Records.Add([ordered]@{
            name = ((Get-SafeText $Name 128) -replace '[\\/]', '_')
            path = Get-SafeText $Path 256
            class = $Class
            digest = Get-TextSha256 $Xml
            bundle = if ($Class -ceq "plugin-currency") { Get-CurrencyBundle $Xml $UserSid } else { "" }
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
    # The class a removable task must still have: the plugin currency task
    # by its name (uninstall), else an obsolete one-shot task (install).
    $Removable = if ($Name -ceq $CurrencyName) { "plugin-currency" } else { "obsolete-oneshot" }
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
    if ((Get-TaskClass $Name "\" $Xml (Get-CurrentUserSid) ([IO.Path]::GetTempPath())) -cne $Removable) {
        $Outcome.outcome = "not-obsolete"
        $Outcome.message = "the task no longer classifies as $Removable"
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
    if ((Get-TaskClass $Name "\" $Xml (Get-CurrentUserSid) ([IO.Path]::GetTempPath())) -cne $Removable) {
        $Outcome.outcome = "not-obsolete"
        $Outcome.message = "the task no longer classifies as $Removable"
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

function Invoke-Register([object]$Value) {
    # The plugin currency task, at the sealed bundle: the files are written
    # and read back first, the task is still what the plan observed (its
    # digest, or absent), and the task left behind runs that bundle.
    $Outcome = [ordered]@{ outcome = ""; backup = ""; message = "" }
    $Task = Get-ScheduledTask -TaskName $CurrencyName -TaskPath "\" -ErrorAction SilentlyContinue
    $Now = if ($null -eq $Task) { "" } else { Get-TextSha256 (Get-TaskXml $CurrencyName "\") }
    if ($Now -cne [string]$Value.before) {
        $Outcome.outcome = "changed"
        $Outcome.message = "the task changed since the plan was sealed"
        return $Outcome
    }
    $Directory = Get-BundleDirectory ([string]$Value.bundle)
    try {
        # Verified BEFORE anything is written: a payload that is not the sealed
        # bundle never touches a live bundle the task may already run.
        $Payload = @(for ($Index = 0; $Index -lt $CurrencyFiles.Count; $Index++) {
            , [Convert]::FromBase64String([string]$Value.files.($CurrencyFiles[$Index]))
        })
        $Digests = @(foreach ($Bytes in $Payload) { Get-BytesSha256 $Bytes })
        if ((Get-BundleDigest $Digests) -cne [string]$Value.bundle) { throw "the bundle does not hash to the sealed digest" }
        [void][IO.Directory]::CreateDirectory($Directory)
        for ($Index = 0; $Index -lt $CurrencyFiles.Count; $Index++) {
            $Path = [IO.Path]::Combine($Directory, $CurrencyFiles[$Index])
            if ((Test-Path -LiteralPath $Path) -and (Get-BytesSha256 ([IO.File]::ReadAllBytes($Path))) -ceq $Digests[$Index]) { continue }
            # A replacement lands whole: written beside it, then moved over it.
            $Staged = "$Path.staged"
            [IO.File]::WriteAllBytes($Staged, $Payload[$Index])
            if ((Get-BytesSha256 ([IO.File]::ReadAllBytes($Staged))) -cne $Digests[$Index]) { throw "a staged bundle file did not read back" }
            Move-Item -LiteralPath $Staged -Destination $Path -Force
        }
        [IO.File]::WriteAllText([IO.Path]::Combine($Directory, "bundle.json"),
            (ConvertTo-Json -Compress -InputObject ([ordered]@{ bundle = [string]$Value.bundle; version = [string]$Value.version })), $Utf8)
    } catch {
        $Outcome.outcome = "failed"
        $Outcome.message = "the plugin currency bundle could not be written under $Directory"
        return $Outcome
    }
    $Xml = New-CurrencyTaskXml (Get-CurrentUserSid) ([IO.Path]::Combine($Directory, $CurrencyFiles[0]))
    # Staging took time: the task is checked again, as it is now, so -Force
    # never replaces a definition the plan did not observe.
    $Task = Get-ScheduledTask -TaskName $CurrencyName -TaskPath "\" -ErrorAction SilentlyContinue
    $Now = if ($null -eq $Task) { "" } else { Get-TextSha256 (Get-TaskXml $CurrencyName "\") }
    if ($Now -cne [string]$Value.before) {
        $Outcome.outcome = "changed"
        $Outcome.message = "the task changed while its bundle was written; it was left as it is"
        return $Outcome
    }
    try {
        Register-ScheduledTask -TaskName $CurrencyName -TaskPath "\" -Xml $Xml -Force -ErrorAction Stop | Out-Null
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
    if ($null -eq (Get-ScheduledTask -TaskName $CurrencyName -TaskPath "\" -ErrorAction SilentlyContinue) -or
        (Get-CurrencyBundle (Get-TaskXml $CurrencyName "\") (Get-CurrentUserSid)) -cne [string]$Value.bundle) {
        $Outcome.outcome = "failed"
        $Outcome.message = "the registered task does not run the sealed bundle"
        return $Outcome
    }
    # Earlier bundles are no longer run by anything.
    foreach ($Stale in @(Get-ChildItem -LiteralPath (Get-BundlesRoot) -Directory -ErrorAction SilentlyContinue)) {
        if ($Stale.Name -cmatch '^[0-9a-f]{16}$' -and $Stale.Name -cne [IO.Path]::GetFileName($Directory)) {
            Remove-Item -LiteralPath $Stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $Outcome.outcome = "registered"
    return $Outcome
}

function Assert-Request([object]$Value) {
    if ($null -eq $Value -or $Value.schema -cne "roundhouse.schedule-windows-request" -or
        $Value.schema_version -ne 1 -or -not (Test-Pattern $Value.mode '^(inspect|unregister|register)$')) {
        throw "Invalid schedule request"
    }
    $Expected = switch ($Value.mode) {
        "inspect" { @("expected_hostname", "expected_user", "mode", "schema", "schema_version") }
        "unregister" { @("digest", "expected_hostname", "expected_user", "mode", "name", "schema", "schema_version") }
        default { @("before", "bundle", "expected_hostname", "expected_user", "files", "mode", "name", "schema", "schema_version", "version") }
    }
    if (((Get-PropertyNames $Value) -join "`0") -cne ($Expected -join "`0")) {
        throw "Schedule request has unexpected fields"
    }
    if (-not (Test-Pattern $Value.expected_hostname $HostPattern) -or -not (Test-Pattern $Value.expected_user $UserPattern)) {
        throw "Schedule request names no valid Windows machine"
    }
    if ($Value.mode -ceq "unregister" -and ((-not (Test-Pattern $Value.name $OneShotName) -and $Value.name -cne $CurrencyName) -or
            -not (Test-Pattern $Value.digest '^[0-9a-f]{64}$'))) {
        throw "Invalid schedule unregister request"
    }
    if ($Value.mode -ceq "register" -and ($Value.name -cne $CurrencyName -or -not (Test-Pattern $Value.bundle '^[0-9a-f]{64}$') -or
            -not (Test-Pattern $Value.before '^([0-9a-f]{64})?$') -or -not (Test-Pattern $Value.version '^[0-9A-Za-z.+-]{1,64}$') -or
            ((Get-PropertyNames $Value.files) -join "`0") -cne (($CurrencyFiles | Sort-Object -CaseSensitive) -join "`0") -or
            @($CurrencyFiles | Where-Object { -not (Test-Pattern $Value.files.$_ '^[A-Za-z0-9+/]+={0,2}$') -or
                ([string]$Value.files.$_).Length -gt ($MaximumBundleBytes * 4 / 3 + 4) }).Count -ne 0)) {
        throw "Invalid schedule register request"
    }
}

function Invoke-ScheduleRequest([object]$Value) {
    $Result = [ordered]@{
        schema = "roundhouse.schedule-windows-result"; schema_version = 1; mode = ""
        state = "failed"; message = ""; host = ""; user = ""; user_sid = ""; tasks = [object[]]@(); outcome = ""; backup = ""
        currency = $null
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
            $Result.currency = Get-CurrencyStatus
        } else {
            $Removal = if ($Value.mode -ceq "register") { Invoke-Register $Value }
                else { Invoke-Unregister ([string]$Value.name) ([string]$Value.digest) }
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
                return $Fixture[$TaskName].Xml + "<!-- edited -->"
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
        $Script:RegisterCalls = 0
        function Register-ScheduledTask {
            [CmdletBinding()] param([string]$TaskName, [string]$TaskPath, [string]$Xml, [switch]$Force)
            if ($Script:Denied) { throw [UnauthorizedAccessException]::new("Access is denied.") }
            [void]([xml]$Xml)
            $Script:RegisterCalls++
            # The Task Scheduler adds elements of its own on export.
            $Fixture[$TaskName] = @{ Xml = $Xml.Replace("<Enabled>true</Enabled></Settings>",
                "<Enabled>true</Enabled><Hidden>false</Hidden></Settings>"); State = "Ready"; Path = $TaskPath }
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
        # --- the plugin currency task ---
        $ScriptBytes = $Utf8.GetBytes("# the currency script")
        $HelperBytes = $Utf8.GetBytes("// the hook helper")
        $Bundle = Get-BundleDigest @((Get-BytesSha256 $ScriptBytes), (Get-BytesSha256 $HelperBytes))
        function New-Register([string]$Before = "", [string]$Digest = $Bundle, [byte[]]$Script = $ScriptBytes) {
            return [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "register"
                expected_hostname = "iris"; expected_user = "claire"; name = $CurrencyName; before = $Before; bundle = $Digest
                version = "0.9.66"; files = [pscustomobject]@{ "plugins-windows.ps1" = [Convert]::ToBase64String($Script)
                    "codex-plugin-hooks.mjs" = [Convert]::ToBase64String($HelperBytes) } }
        }
        function Get-Currency { return @((Invoke-ScheduleRequest (New-Inspect)).tasks | Where-Object { $_.name -ceq $CurrencyName }) }
        if ((Invoke-ScheduleRequest (New-Register -Before ("0" * 64))).outcome -cne "changed" -or $Script:RegisterCalls -ne 0) {
            throw "Self-test registered over a task the plan did not observe"
        }
        if ((Invoke-ScheduleRequest (New-Register -Script $Utf8.GetBytes("# other bytes"))).outcome -cne "failed" -or $Script:RegisterCalls -ne 0) {
            throw "Self-test registered a bundle that is not the sealed one"
        }
        $SealedScript = [IO.Path]::Combine((Get-BundleDirectory $Bundle), $CurrencyFiles[0])
        if ((Test-Path -LiteralPath $SealedScript) -and
            [IO.File]::ReadAllText($SealedScript).Contains("# other bytes")) {
            throw "Self-test wrote an unverified payload over the sealed bundle before checking it"
        }
        $Script:Denied = $true
        if ((Invoke-ScheduleRequest (New-Register)).outcome -cne "refused") { throw "Self-test did not report a refused registration" }
        $Script:Denied = $false
        $RegisterResult = Invoke-ScheduleRequest (New-Register)
        $Currency = @(Get-Currency)
        if ($RegisterResult.outcome -cne "registered" -or $Currency.Count -ne 1 -or $Currency[0].class -cne "plugin-currency" -or
            $Currency[0].bundle -cne $Bundle) {
            throw "Self-test did not register the plugin currency task at its bundle"
        }
        $BundleDirectory = Get-BundleDirectory $Bundle
        if ([IO.File]::ReadAllText([IO.Path]::Combine($BundleDirectory, "plugins-windows.ps1")) -cne "# the currency script" -or
            (Get-Content -Raw ([IO.Path]::Combine($BundleDirectory, "bundle.json")) | ConvertFrom-Json).version -cne "0.9.66") {
            throw "Self-test did not write the bundle beside the task"
        }
        # Exactly the written definition, or no bundle at all: install then
        # registers it again. Never unknown, never obsolete.
        foreach ($Edit in @(@("<RunLevel>LeastPrivilege</RunLevel>", "<RunLevel>HighestAvailable</RunLevel>"),
                @("<Enabled>true</Enabled><Hidden>", "<Enabled>false</Enabled><Hidden>"),
                @("<Enabled>true</Enabled></TimeTrigger>", "<Enabled>false</Enabled></TimeTrigger>"),
                @("<StartBoundary>2026-01-01T00:00:00</StartBoundary>", "<StartBoundary>2099-01-01T00:00:00</StartBoundary>"),
                @("<Interval>PT20M</Interval>", "<Interval>PT1M</Interval>"),
                @("-ExecutionPolicy Bypass -File", "-ExecutionPolicy Bypass -Command x -File"),
                @("<Triggers>", "<Triggers><LogonTrigger />"))) {
            $Saved = $Fixture[$CurrencyName].Xml
            $Fixture[$CurrencyName].Xml = $Saved.Replace($Edit[0], $Edit[1])
            $Edited = @(Get-Currency)
            $Fixture[$CurrencyName].Xml = $Saved
            if ($Edited[0].class -cne "plugin-currency" -or $Edited[0].bundle -cne "") { throw "Self-test reported an edited currency task as current: $($Edit[1])" }
        }
        [IO.File]::WriteAllText([IO.Path]::Combine($BundleDirectory, "codex-plugin-hooks.mjs"), "// edited")
        if (@(Get-Currency)[0].bundle -cne "") { throw "Self-test reported an edited bundle as current" }
        # A task edited while the bundle is staged is left as it is.
        $Script:Exports = 0; $Script:ChangeOnExport = 2
        $Raced = Invoke-ScheduleRequest (New-Register -Before $Currency[0].digest)
        $Script:ChangeOnExport = 0
        if ($Raced.outcome -cne "changed" -or $Script:RegisterCalls -ne 1) { throw "Self-test registered over a task edited while its bundle was staged" }
        # Re-pointing: a new bundle replaces the task bound to its digest, and
        # the old bundle goes.
        $OldDirectory = $BundleDirectory
        $ScriptBytes = $Utf8.GetBytes("# the next currency script")
        $Bundle = Get-BundleDigest @((Get-BytesSha256 $ScriptBytes), (Get-BytesSha256 $HelperBytes))
        $Repointed = Invoke-ScheduleRequest (New-Register -Before $Currency[0].digest)
        if ($Repointed.outcome -cne "registered" -or @(Get-Currency)[0].bundle -cne $Bundle -or (Test-Path -LiteralPath $OldDirectory)) {
            throw "Self-test did not re-point the currency task at the new bundle"
        }
        # The last run's status, bounded; nothing that is not one.
        $StatusPath = [IO.Path]::Combine((Get-CurrencyRoot), "status.json")
        [IO.File]::WriteAllText($StatusPath, (ConvertTo-Json -InputObject ([ordered]@{ schema = "roundhouse.plugin-currency-status"
            schema_version = 1; version = "0.9.66"; started_at = "2026-10-02T09:00:00Z"; finished_at = "2026-10-02T09:01:00Z"
            state = "held"; updated = 2; held = 1; messages = @("hold x`u{7}y") })), $Utf8)
        $Reported = (Invoke-ScheduleRequest (New-Inspect)).currency
        if ($Reported.state -cne "held" -or $Reported.finished_at -cne "2026-10-02T09:01:00Z" -or $Reported.held -ne 1 -or
            $Reported.messages[0] -cne "hold x y") {
            throw "Self-test did not report the plugin currency status"
        }
        [IO.File]::WriteAllText($StatusPath, '{"schema":"other"}', $Utf8)
        if ($null -ne (Invoke-ScheduleRequest (New-Inspect)).currency) { throw "Self-test reported a status file that is not one" }
        # Uninstall removes it by its digest, like an obsolete task.
        $CurrencyDigest = @(Get-Currency)[0].digest
        $Gone = Invoke-ScheduleRequest (New-Unregister $CurrencyName $CurrencyDigest)
        if ($Gone.outcome -cne "removed" -or $Fixture.ContainsKey($CurrencyName)) { throw "Self-test did not unregister the currency task" }
        foreach ($Bad in @(
                [pscustomobject]@{ schema = "roundhouse.schedule-windows-request"; schema_version = 1; mode = "register"; expected_hostname = "iris"; expected_user = "claire" },
                ((New-Register) | Add-Member -PassThru -NotePropertyName extra -NotePropertyValue 1),
                ((New-Register) | ForEach-Object { $_.name = "RoundhouseOther"; $_ }),
                ((New-Register) | ForEach-Object { $_.files = [pscustomobject]@{ "plugins-windows.ps1" = "AA==" }; $_ }),
                ((New-Register) | ForEach-Object { $_.files."plugins-windows.ps1" = "not base64!"; $_ }),
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
