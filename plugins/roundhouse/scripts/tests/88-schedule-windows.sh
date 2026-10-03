# roundhouse self-check — fleet-schedule's native Windows half: the Task
# Scheduler of a WSL machine, observed and converged from its systemd side
# (lib/fleet-schedule-windows.sh, scripts/schedule-windows.ps1).
#
# Every scheduler is a stub. systemctl, loginctl and uname record what they
# were asked and keep their state in files under this section's root; the
# Windows side is the REAL scripts/schedule-windows.ps1, run by real pwsh
# behind a fake full-path `pwsh.exe` whose ScheduledTasks cmdlets are
# functions over a fixture directory. Nothing here reads or changes a real
# Task Scheduler, launchd or systemd. The driver-backed blocks are skipped
# without pwsh, as section 69's lane fixtures are.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'schedule: native Windows Task Scheduler from the WSL side\n'
  (
    set -eu
    win_root="$tmp/schedule-windows"
    win_bin="$win_root/bin"
    SCHED_STATE="$win_root/state"
    SCHED_LOG="$win_root/calls.log"
    mkdir -p "$win_bin" "$SCHED_STATE"
    : >"$SCHED_LOG"
    export SCHED_STATE SCHED_LOG

    cat >"$win_bin/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${SCHED_UNAME:-Linux}"
STUB
    cat >"$win_bin/systemctl" <<'STUB'
#!/bin/sh
# A systemd user manager, as files (the subset section 84's stub keeps).
printf 'systemctl %s\n' "$*" >>"$SCHED_LOG"
[ "${1:-}" = --user ] || exit 64
shift
[ -e "$SCHED_STATE/usermgr" ] || exit 1
wants="$XDG_CONFIG_HOME/systemd/user/timers.target.wants"
case $1 in
  show-environment | daemon-reload | restart) ;;
  is-enabled)
    if [ -e "$SCHED_STATE/enabled.$2" ]; then printf 'enabled\n'
    else printf 'disabled\n'; exit 1; fi
    ;;
  is-active)
    [ "$2" = --quiet ] && shift
    [ -e "$SCHED_STATE/active.$2" ] || exit 3
    ;;
  enable)
    [ "$2" = --now ] && shift
    : >"$SCHED_STATE/enabled.$2"
    : >"$SCHED_STATE/active.$2"
    mkdir -p "$wants"
    ln -sf "../$2" "$wants/$2"
    ;;
  disable)
    [ "$2" = --now ] && shift
    rm -f "$SCHED_STATE/enabled.$2" "$SCHED_STATE/active.$2" "$wants/$2"
    ;;
  *) exit 64 ;;
esac
STUB
    cat >"$win_bin/loginctl" <<'STUB'
#!/bin/sh
[ "$1" = show-user ] || exit 64
printf 'yes\n'
STUB
    chmod +x "$win_bin"/*

    PATH="$win_bin:$fleet_fixture_path"
    ROUNDHOUSE_SELFTEST=1
    # This host is the WSL side (test-host, local); test-windows is its
    # configured Windows half, the sibling every native request names.
    jq '.machines["test-apt"].expected_hostname = "another-fixture-host" |
      .machines["test-apt"].expected_user = "another-fixture-user" |
      .machines["test-host"].platform = "wsl" |
      .machines["test-windows"].wsl_interop_via = "test-host" |
      .machines["test-windows"].expected_hostname = "WREN-PC" |
      .machines["test-windows"].expected_user = "Wren"' \
      "$tmp/config.json" >"$win_root/config.json"
    chmod 600 "$win_root/config.json"
    ROUNDHOUSE_CONFIG="$win_root/config.json"
    ROUNDHOUSE_FLEET_STORE="$win_root/store"
    HOME="$win_root/home"
    XDG_CONFIG_HOME="$HOME/.config"
    SCHED_UNAME=Linux
    # The fake drive root and full-path PowerShell 7 the interop lane uses.
    win_drive="$win_root/drive"
    ROUNDHOUSE_INTEROP_ROOT="$win_drive"
    ROUNDHOUSE_INTEROP_PWSH="$win_drive/Program Files/PowerShell/7/pwsh.exe"
    ROUNDHOUSE_SCHEDULE_WSL=1
    export PATH ROUNDHOUSE_SELFTEST ROUNDHOUSE_CONFIG ROUNDHOUSE_FLEET_STORE HOME \
      XDG_CONFIG_HOME SCHED_UNAME ROUNDHOUSE_INTEROP_ROOT ROUNDHOUSE_INTEROP_PWSH \
      ROUNDHOUSE_SCHEDULE_WSL
    mkdir -p "$ROUNDHOUSE_FLEET_STORE" "$HOME/.local/bin" "$win_drive/Program Files/PowerShell/7"
    printf '#!/bin/sh\n' >"$HOME/.local/bin/roundhouse"
    chmod +x "$HOME/.local/bin/roundhouse"
    : >"$SCHED_STATE/usermgr"
    printf 'name: wren\ndomain: fleet.example.invalid\n' >"$win_root/identity.yaml"
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    win_units="$XDG_CONFIG_HOME/systemd/user"
    win_stale=Roundhouse-Remaining-0123456789abcdef0123456789abcdef

    # fleet-schedule as the CLI runs it, its own process with errexit live;
    # `sealed` runs $WIN_AFTER_SEAL between the seal and the apply.
    # shellcheck disable=SC2016 # the driver is a program, expanded by its own bash
    win_driver='set -eu
ROUNDHOUSE_LIB_ONLY=1
. "$0"
eval "win_seal_real() $(declare -f seal_plan_command | tail -n +2)"
seal_plan_command() {
  win_seal_real "$@"
  [ -z "${WIN_AFTER_SEAL:-}" ] || eval "$WIN_AFTER_SEAL"
}
fleet_schedule_command "$@"'
    win_sealed() {
      bash -c "$win_driver" "$cli" "$@"
    }
    win_reset_units() {
      rm -rf "$win_units" "$SCHED_STATE"/enabled.* "$SCHED_STATE"/active.*
      rm -f "$(fleet_run_state_dir)"/schedule-*
      : >"$SCHED_LOG"
    }

    # --- the host test, the inert hook and the native-Windows refusal ---
    fleet_schedule_windows_host || fail "the WSL hook did not mark this a WSL machine"
    ROUNDHOUSE_SCHEDULE_WSL=0 fleet_schedule_windows_host &&
      fail "the WSL hook could not say this is not a WSL machine"
    # Outside the self-check the hook is inert, and a stub Linux kernel that
    # is not Microsoft's is no WSL machine.
    ROUNDHOUSE_SELFTEST=0 fleet_schedule_windows_host &&
      ! grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null &&
      fail "a stray ROUNDHOUSE_SCHEDULE_WSL made a real host a WSL machine"
    win_status=0
    win_out=$(ROUNDHOUSE_SCHEDULE_WSL=0 fleet_schedule_native status 2>&1) || win_status=$?
    [ "$win_status" -eq 69 ] || fail "the native dispatcher ran on a host with no native half ($win_status)"
    win_status=0
    win_out=$(SCHED_UNAME=MINGW64_NT-10.0 "$cli" fleet-schedule status 2>&1) || win_status=$?
    [ "$win_status" -eq 69 ] || fail "fleet-schedule on native Windows was not refused ($win_status)"
    case $win_out in
      *'no native runtime there'*'WSL side of this machine'*) ;;
      *) fail "the native-Windows refusal did not name the WSL side: $win_out" ;;
    esac

    # --- the result contract: nothing beyond the closed shape is believed ---
    win_valid='{"schema":"roundhouse.schedule-windows-result","schema_version":1,"mode":"inspect","state":"completed","message":"","host":"WREN-PC","user":"Wren","user_sid":"S-1-5-21-1","tasks":[{"name":"Roundhouse-Remaining-0123456789abcdef0123456789abcdef","path":"\\","class":"obsolete-oneshot","digest":"'"$(printf '%064d' 0)"'","state":"Ready","last_run":"2026-09-22T13:06:11Z","last_result":0,"bundle":""}],"outcome":"","backup":"","currency":null}'
    printf '%s\n' "$win_valid" >"$win_root/result.json"
    fleet_schedule_windows_result_valid "$win_root/result.json" ||
      fail "a well-formed native result was rejected"
    # A task roundhouse does not recognise may carry any bounded name under
    # a Roundhouse folder (#94): reported, never a failed inspection.
    for win_good in \
      '.tasks += [{name:"Routine Backup (weekly)",path:"\\Roundhouse\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      '.tasks += [{name:"Roundhouse Notes",path:"\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      '.tasks += [{name:"x",path:"\\Roundhouse Tools\\Nightly\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]'; do
      printf '%s\n' "$win_valid" | jq -c "$win_good" >"$win_root/result.json"
      fleet_schedule_windows_result_valid "$win_root/result.json" ||
        fail "a bounded unknown native task was not believed: $win_good"
    done
    # The plugin currency task, by its name only, with the bundle it runs;
    # and the last run's status, bounded.
    win_currency_task='{name:"RoundhousePluginCurrency",path:"\\",class:"plugin-currency",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:("a" * 64)}'
    win_currency_status='{state:"held",version:"0.9.66",started_at:"2026-10-02T09:00:00Z",finished_at:"2026-10-02T09:01:00Z",updated:2,held:1,messages:["hold x"]}'
    printf '%s\n' "$win_valid" | jq -c ".tasks += [$win_currency_task] | .currency = $win_currency_status" \
      >"$win_root/result.json"
    fleet_schedule_windows_result_valid "$win_root/result.json" ||
      fail "a native result with the plugin currency task and its status was rejected"
    for win_bad in \
      ".tasks += [$win_currency_task | .name = \"RoundhouseOther\"]" \
      ".tasks += [$win_currency_task | .path = \"\\\\Roundhouse\\\\\"]" \
      ".tasks += [$win_currency_task | .bundle = \"xyz\"]" \
      ".tasks[0].bundle = (\"a\" * 64)" \
      ".currency = ($win_currency_status | .state = \"great\")" \
      ".currency = ($win_currency_status | .extra = 1)" \
      ".currency = ($win_currency_status | .messages = [\"a\\u0007\"])" \
      ".currency = ($win_currency_status | .updated = -1)"; do
      printf '%s\n' "$win_valid" | jq -c "$win_bad" >"$win_root/result.json"
      ! fleet_schedule_windows_result_valid "$win_root/result.json" ||
        fail "a malformed plugin currency result was believed: $win_bad"
    done
    for win_bad in \
      '.tasks[0] += {name:"Routine Backup",path:"\\Roundhouse\\"}' \
      '.tasks += [{name:"Backup",path:"\\Other\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      '.tasks += [{name:"Roundhouse\u0007",path:"\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      '.tasks += [{name:"a/b",path:"\\Roundhouse\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      '.tasks += [{name:("R" * 129),path:"\\Roundhouse\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      '.tasks += [{name:"RoundhouseBrokerV1",path:"\\Roundhouse\\",class:"privilege-lane",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      'del(.host)' \
      '.extra = 1' \
      '.tasks[0].class = "removable"' \
      '.tasks[0].name = "RoundhouseBrokerV1"' \
      '.tasks[0].path = "\\Roundhouse\\"' \
      '.tasks[0].name = "Other-Task"' \
      '.tasks[0].digest = "ABC"' \
      '.tasks[0].xml = "<Task/>"' \
      '.message = "a\u0007b"' \
      '.tasks = [range(65) | {name:"RoundhouseX",path:"\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null,bundle:""}]' \
      '.outcome = "deleted"'; do
      printf '%s\n' "$win_valid" | jq -c "$win_bad" >"$win_root/result.json"
      ! fleet_schedule_windows_result_valid "$win_root/result.json" ||
        fail "a malformed native result was believed: $win_bad"
    done

    # --- the plan contract: an unregister step is install-only and narrow ---
    win_contract() {
      # win_contract ACTION STEP-JSON — schedule_operations_valid on a draft
      # whose one schedule operation carries STEP.
      jq -n --arg action "$1" --argjson step "$2" '{operations:[{type:"agent-update",
        kind:"agent_artifact",id:"roundhouse:schedule",
        argv:["roundhouse","fleet-schedule",$action],steps:[$step]}]}' >"$win_root/draft.json"
      schedule_operations_valid "$win_root/draft.json" "$HOME"
    }
    win_step=$(jq -cn --arg name "$win_stale" --arg digest "$(printf '%064d' 0)" \
      '{action:"unregister",mode:"native",machine:"test-windows",name:$name,path:"\\",digest:$digest}')
    win_contract install "$win_step" || fail "the plan contract refused a native unregister step"
    ! win_contract uninstall "$win_step" || fail "an uninstall plan may unregister an obsolete native task"
    # The plugin currency task: registered by install, removed by uninstall.
    win_register=$(jq -cn --arg bundle "$(printf '%064d' 1)" \
      '{action:"register",mode:"native",machine:"test-windows",name:"RoundhousePluginCurrency",path:"\\",bundle:$bundle,before:null}')
    win_contract install "$win_register" || fail "the plan contract refused the plugin currency registration"
    win_contract install "$(printf '%s\n' "$win_register" | jq -c '.before = ("2" * 64)')" ||
      fail "the plan contract refused re-pointing the plugin currency task"
    ! win_contract uninstall "$win_register" || fail "an uninstall plan may register a native task"
    win_unregister_currency=$(printf '%s\n' "$win_step" | jq -c '.name = "RoundhousePluginCurrency"')
    win_contract uninstall "$win_unregister_currency" || fail "the plan contract refused removing the plugin currency task"
    ! win_contract install "$win_unregister_currency" || fail "an install plan may remove the plugin currency task"
    for win_bad in '.name = "RoundhouseOther"' '.path = "\\Roundhouse\\"' '.bundle = "x"' '.before = "x"' \
      'del(.before)' '.argv = ["schtasks"]'; do
      ! win_contract install "$(printf '%s\n' "$win_register" | jq -c "$win_bad")" ||
        fail "the plan contract accepted a widened register step: $win_bad"
    done
    for win_bad in '.name = "RoundhouseBrokerV1"' '.path = "\\Roundhouse\\"' '.mode = "fast"' \
      '.digest = "x"' '.argv = ["schtasks"]' 'del(.machine)' '.machine = "../x"'; do
      ! win_contract install "$(printf '%s\n' "$win_step" | jq -c "$win_bad")" ||
        fail "the plan contract accepted a widened unregister step: $win_bad"
    done

    # --- the step budget: 64 native removals beside a fresh local install ---
    # (#94) The native inspection reports at most 64 tasks; every one of them
    # obsolete beside a fresh systemd install (seven local steps) still seals.
    win_reset_units
    win_record=$(fleet_schedule_observe | jq -c --arg stale "$win_stale" '
      .native = {lane:"wsl-interop",machine:"test-windows",reachable:true,reason:null,
        tasks:[range(64) as $i | {name:("Roundhouse-Remaining-" + ("\($i)" | ("0" * (32 - length)) + .)),
          path:"\\",class:"obsolete-oneshot",digest:("0" * 64),bundle:""}]}')
    mkdir -p "$win_root/budget"
    win_steps=$(fleet_schedule_plan_steps install "$win_record" "$win_root/budget") ||
      fail "a plan with 64 obsolete native tasks could not be made"
    [ "$(printf '%s\n' "$win_steps" | jq '[.[] | select(.action == "unregister")] | length')" -eq 64 ] &&
      [ "$(printf '%s\n' "$win_steps" | jq '[.[] | select(.action == "register")] | length')" -eq 1 ] &&
      [ "$(printf '%s\n' "$win_steps" | jq '[.[] | select(.mode != "native")] | length')" -ge 7 ] ||
      fail "the budget fixture is not 64 removals and a registration beside a fresh install: $win_steps"
    jq -n --argjson steps "$win_steps" '{operations:[{type:"agent-update",kind:"agent_artifact",
      id:"roundhouse:schedule",argv:["roundhouse","fleet-schedule","install"],steps:$steps}]}' \
      >"$win_root/draft.json"
    schedule_operations_valid "$win_root/draft.json" "$HOME" ||
      fail "64 native removals beside a fresh local install broke the plan's step budget"
    jq '.operations[0].steps += [.operations[0].steps[] | select(.action == "unregister")][:1]' \
      "$win_root/draft.json" >"$win_root/draft-over.json"
    ! schedule_operations_valid "$win_root/draft-over.json" "$HOME" ||
      fail "a 65th native removal fitted the plan's step budget"
    jq '.operations[0].steps += [.operations[0].steps[] | select(.action == "register")]' \
      "$win_root/draft.json" >"$win_root/draft-over.json"
    ! schedule_operations_valid "$win_root/draft-over.json" "$HOME" ||
      fail "a second native registration fitted the plan's step budget"
    jq '.operations[0].steps = [range(65) as $i | {action:"run",mode:"all",effect:"reload",required:false,
      argv:["systemctl","--user","daemon-reload"]}]' "$win_root/draft.json" >"$win_root/draft-over.json"
    ! schedule_operations_valid "$win_root/draft-over.json" "$HOME" ||
      fail "65 local steps fitted the plan's step budget"

    # --- the configured Windows sibling: resolved from the inventory ---
    [ "$(fleet_schedule_windows_sibling | jq -r '.machine')" = test-windows ] ||
      fail "the configured Windows sibling of this WSL host was not resolved"
    ! fleet_schedule_windows_sibling other-windows >/dev/null 2>&1 ||
      fail "the sibling resolved as a machine the inventory does not configure"
    jq 'del(.machines["test-windows"].wsl_interop_via)' "$ROUNDHOUSE_CONFIG" >"$win_root/no-sibling.json"
    chmod 600 "$win_root/no-sibling.json"
    win_out=$(ROUNDHOUSE_CONFIG="$win_root/no-sibling.json" fleet_schedule_native observe)
    printf '%s\n' "$win_out" | jq -e '.reachable == false and .machine == null and
      (.reason | test("no single configured Windows machine names test-host"))' >/dev/null ||
      fail "a WSL host with no configured Windows sibling was observed as reachable: $win_out"

    # --- an unreachable Windows side never holds up the local jobs ---
    # (No pwsh.exe exists yet at the interop path.)
    win_out=$(fleet_schedule_native observe)
    [ "$(printf '%s\n' "$win_out" | jq -r '.reachable')" = false ] &&
      printf '%s\n' "$win_out" | jq -e '.reason | test("not reachable through WSL interop")' >/dev/null ||
      fail "an unreachable native half was not observed as such: $win_out"
    win_reset_units
    win_out=$("$cli" fleet-schedule install 2>&1) ||
      fail "install failed because native Windows was unreachable: $win_out"
    [ -f "$win_units/roundhouse-fleet-fast.timer" ] && [ -f "$win_units/roundhouse-fleet-full.service" ] ||
      fail "install wrote no local jobs while native Windows was unreachable"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: installed, enabled, loaded, definition matches'*'native Windows: Task Scheduler not inspected — PowerShell 7 is not reachable'*) ;;
      *) fail "status did not report the unreachable native half: $("$cli" fleet-schedule status)" ;;
    esac

    # A Windows side that answers with anything but exactly one well-formed
    # result is unreachable too, never half-believed.
    cat >"$ROUNDHOUSE_INTEROP_PWSH" <<'SH'
#!/bin/sh
cat >/dev/null
printf 'roundhouse-schedule-result %s\r\n' "$(printf '{"schema":"x"}' | base64)"
printf 'roundhouse-schedule-result %s\r\n' "$(printf '{"schema":"x"}' | base64)"
SH
    chmod +x "$ROUNDHOUSE_INTEROP_PWSH"
    win_status=0
    fleet_schedule_windows_call "$(fleet_schedule_windows_request "$(fleet_schedule_windows_sibling)" inspect)" \
      >/dev/null 2>&1 || win_status=$?
    [ "$win_status" -eq 70 ] || fail "a doubled, malformed native result was accepted ($win_status)"

    if [ -n "$pwsh_command" ]; then
      # --- the real driver behind the fake full-path PowerShell 7 ---
      win_tasks="$win_root/tasks"
      win_temp="$win_root/windows-temp"
      win_local="$win_root/windows-local"
      win_sid=S-1-12-1-1111111111-2222222222-3333333333-4444444444
      mkdir -p "$win_tasks" "$win_temp" "$win_local"
      cat >"$win_root/stubs.ps1" <<'PS1'
# The ScheduledTasks cmdlets, as functions over $env:WIN_TASKS: one
# <name>.xml per task in the root folder, <name>.running while it runs.
# A subdirectory is a Task Scheduler folder: Roundhouse/<name>.xml is
# \Roundhouse\<name>.
function Get-FixtureFile([string]$TaskName, [string]$TaskPath) {
    $Folder = $TaskPath.Trim('\') -replace '\\', [IO.Path]::DirectorySeparatorChar
    return Join-Path (Join-Path $env:WIN_TASKS $Folder) "$TaskName.xml"
}
function Get-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
    foreach ($File in @(Get-ChildItem -LiteralPath $env:WIN_TASKS -Filter "*.xml" -Recurse | Sort-Object FullName)) {
        $Name = $File.BaseName
        $Relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($env:WIN_TASKS), $File.DirectoryName)
        $Path = if ($Relative -cne ".") { "\" + ($Relative -replace '/', '\') + "\" } else { "\" }
        if ($TaskName -and $Name -cne $TaskName) { continue }
        if ($TaskPath -and $Path -cne $TaskPath) { continue }
        $State = if (Test-Path -LiteralPath (Join-Path $File.DirectoryName "$Name.running")) { "Running" } else { "Ready" }
        [pscustomobject]@{ TaskName = $Name; TaskPath = $Path; State = $State }
    }
}
function Export-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
    return [IO.File]::ReadAllText((Get-FixtureFile $TaskName $TaskPath))
}
function Get-ScheduledTaskInfo {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
    return [pscustomobject]@{ LastRunTime = [DateTime]::new(2026, 9, 22, 13, 6, 11, [DateTimeKind]::Utc); LastTaskResult = 0 }
}
function Register-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath, [string]$Xml, [switch]$Force)
    Add-Content -LiteralPath $env:WIN_REGISTER_LOG -Value "$TaskPath$TaskName"
    if ($env:WIN_DENY -eq "1") { throw [UnauthorizedAccessException]::new("Access is denied.") }
    [IO.File]::WriteAllText((Get-FixtureFile $TaskName $TaskPath), $Xml)
}
function Unregister-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath, [switch]$Confirm)
    Add-Content -LiteralPath $env:WIN_UNREGISTER_LOG -Value "$TaskPath$TaskName"
    if ($env:WIN_DENY -eq "1") { throw [UnauthorizedAccessException]::new("Access is denied.") }
    Remove-Item -LiteralPath (Join-Path $env:WIN_TASKS "$TaskName.xml")
}
PS1
      # The fake pwsh.exe: started from the drive root like the lane's, then
      # real pwsh with the stubs loaded ahead of the lane's own bootstrap.
      cat >"$ROUNDHOUSE_INTEROP_PWSH" <<'SH'
#!/usr/bin/env bash
[ "$(pwd -P)" = "$(CDPATH='' cd -P -- "$ROUNDHOUSE_INTEROP_ROOT" && pwd -P)" ] || {
  printf 'schedule fixture: Windows process did not start from the drive root\n' >&2
  exit 97
}
[ "$4" = -EncodedCommand ] || exit 98
# Decoded in ONE pipeline: UTF-16 carries NUL bytes a shell variable drops.
boot=$(printf '%s' "$5" | base64 -d | iconv -f UTF-16LE -t UTF-8)
script=". '$WIN_STUBS'; $boot"
export TMPDIR="$WIN_TEMP/" LOCALAPPDATA="$WIN_LOCAL" ROUNDHOUSE_SCHEDULE_FIXTURE_SID="$WIN_SID" \
  ROUNDHOUSE_SCHEDULE_FIXTURE_HOST="${WIN_HOST:-WREN-PC}" ROUNDHOUSE_SCHEDULE_FIXTURE_USER="${WIN_USER:-wren}"
exec "$REAL_PWSH" -NoLogo -NoProfile -NonInteractive -EncodedCommand \
  "$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
SH
      chmod +x "$ROUNDHOUSE_INTEROP_PWSH"
      WIN_TASKS=$win_tasks WIN_TEMP=$win_temp WIN_LOCAL=$win_local WIN_SID=$win_sid
      WIN_STUBS="$win_root/stubs.ps1" WIN_UNREGISTER_LOG="$win_root/unregister.log"
      WIN_REGISTER_LOG="$win_root/register.log"
      REAL_PWSH=$pwsh_command
      export WIN_TASKS WIN_TEMP WIN_LOCAL WIN_SID WIN_STUBS WIN_UNREGISTER_LOG WIN_REGISTER_LOG REAL_PWSH
      win_task_xml() {
        # win_task_xml USER-SID SCRIPT [TRIGGERS] — a task definition in the
        # shape Export-ScheduledTask prints.
        printf '<?xml version="1.0" encoding="UTF-16"?>\n<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">\n  <RegistrationInfo><Description>Temporary one-shot verified Roundhouse package apply as the existing standard user</Description></RegistrationInfo>\n  <Principals><Principal id="Author"><UserId>%s</UserId><LogonType>InteractiveToken</LogonType></Principal></Principals>\n  %s\n  <Actions Context="Author"><Exec><Command>C:\\Program Files\\PowerShell\\7\\pwsh.exe</Command><Arguments>-NoLogo -NoProfile -NonInteractive -File &quot;%s&quot;</Arguments></Exec></Actions>\n</Task>\n' \
          "$1" "${3:-<Triggers />}" "$2"
      }
      win_seed() {
        rm -rf "$win_tasks"/* "$WIN_UNREGISTER_LOG" "$win_local/Roundhouse/plugin-currency"
        : >"$WIN_UNREGISTER_LOG"
        : >"$WIN_REGISTER_LOG"
        win_task_xml "$win_sid" "$win_temp/roundhouse-release-gate.649j8Z/remaining-batch09-apply-limited-worker.ps1" \
          >"$win_tasks/$win_stale.xml"
        # The privilege lane's task, and lookalikes that must never be removed:
        # a stale-shaped task with a trigger, and one belonging to another user.
        win_task_xml S-1-5-18 'C:\ProgramData\Roundhouse\broker.ps1' '<Triggers><BootTrigger /></Triggers>' \
          >"$win_tasks/RoundhouseBrokerV1.xml"
        win_task_xml "$win_sid" "$win_temp/roundhouse-release-gate.649j8Z/w.ps1" '<Triggers><LogonTrigger /></Triggers>' \
          >"$win_tasks/Roundhouse-Logon-00000000000000000000000000000001.xml"
        win_task_xml S-1-5-21-9 "$win_temp/roundhouse-release-gate.649j8Z/w.ps1" \
          >"$win_tasks/Roundhouse-Other-00000000000000000000000000000002.xml"
        # The operator's own task under a Roundhouse folder, of any name.
        mkdir -p "$win_tasks/Roundhouse"
        win_task_xml "$win_sid" 'C:\Tools\backup.ps1' '<Triggers><CalendarTrigger /></Triggers>' \
          >"$win_tasks/Roundhouse/Routine Backup.xml"
        cp "$win_tasks/$win_stale.xml" "$win_root/stale.xml.saved"
      }

      # status: the stale task is named as obsolete, the rest are left alone.
      win_seed
      win_out=$("$cli" fleet-schedule status) || fail "status failed with a reachable native half"
      for win_expect in \
        "native Windows: \\$win_stale — an obsolete one-shot release-gate task (no trigger, last run 2026-09-22T13:06:11Z, result 0); \`fleet-schedule install\` removes it" \
        "native Windows: \\RoundhouseBrokerV1 — the privilege lane's task" \
        'native Windows: \Roundhouse-Logon-00000000000000000000000000000001 — not a task roundhouse recognises' \
        'native Windows: \Roundhouse-Other-00000000000000000000000000000002 — not a task roundhouse recognises' \
        'native Windows: \Roundhouse\Routine Backup — not a task roundhouse recognises' \
        'native Windows: test-windows — no fleet-run task, by design'; do
        assert_contains "$win_out" "$win_expect"
      done
      case $win_out in *'pwsh.exe'* | *'release-gate.649j8Z'* | *'one-shot verified'*)
        fail "status printed a task definition's content: $win_out" ;;
      esac
      [ ! -s "$WIN_UNREGISTER_LOG" ] && [ ! -s "$WIN_REGISTER_LOG" ] || fail "status changed the Task Scheduler"
      assert_contains "$win_out" 'native Windows: no RoundhousePluginCurrency task; `fleet-schedule install` registers it'

      # install: the sealed pipeline end to end. The local timers are
      # installed, the stale task alone is removed and its definition kept.
      win_reset_units
      win_out=$("$cli" fleet-schedule install 2>&1) || fail "install with a stale native task failed: $win_out"
      [ -f "$win_units/roundhouse-fleet-fast.timer" ] || fail "install wrote no local jobs beside the native step"
      [ "$(cat "$WIN_UNREGISTER_LOG")" = "\\$win_stale" ] ||
        fail "install unregistered something other than the stale task: $(cat "$WIN_UNREGISTER_LOG")"
      [ ! -e "$win_tasks/$win_stale.xml" ] || fail "install left the stale native task registered"
      for win_kept in RoundhouseBrokerV1 Roundhouse-Logon-00000000000000000000000000000001 \
        Roundhouse-Other-00000000000000000000000000000002; do
        [ -f "$win_tasks/$win_kept.xml" ] || fail "install removed a task it does not own: $win_kept"
      done
      # Kept in the UTF-16 its declaration names (#94), byte order mark first,
      # and the very definition once decoded.
      win_backup="$win_local/Roundhouse/schedule-removed/$win_stale.xml"
      [ "$(head -c 2 "$win_backup" | od -An -tx1 | tr -d ' \n')" = fffe ] ||
        fail "the removed task's definition was not kept in its declared UTF-16"
      iconv -f UTF-16 -t UTF-8 "$win_backup" | cmp -s - "$win_root/stale.xml.saved" ||
        fail "the removed task's definition was not kept intact"
      [ -f "$win_tasks/Roundhouse/Routine Backup.xml" ] || fail "install removed a foldered task it does not own"
      assert_contains "$win_out" "removed the obsolete one-shot task $win_stale; its definition is kept as"
      # The plugin currency task: registered once, running this version's
      # bundle — the shipped script and hook helper, byte for byte.
      [ "$(cat "$WIN_REGISTER_LOG")" = '\RoundhousePluginCurrency' ] ||
        fail "install did not register the plugin currency task once: $(cat "$WIN_REGISTER_LOG")"
      assert_contains "$win_out" "registered RoundhousePluginCurrency, which keeps this user's plugins current every 20 minutes"
      win_bundle=$(fleet_schedule_windows_bundle)
      win_bundle_dir="$win_local/Roundhouse/plugin-currency/bundles/$(printf '%.16s' "$win_bundle")"
      cmp -s "$win_bundle_dir/plugins-windows.ps1" "$script_dir/plugins-windows.ps1" &&
        cmp -s "$win_bundle_dir/codex-plugin-hooks.mjs" "$script_dir/codex-plugin-hooks.mjs" ||
        fail "the plugin currency bundle is not the shipped script and helper"
      [ "$(jq -r '.version' "$win_bundle_dir/bundle.json")" = "$(jq -r '.version' "$script_dir/../.claude-plugin/plugin.json")" ] ||
        fail "the plugin currency bundle does not name this plugin version"
      grep -Fq "plugins-windows.ps1" "$win_tasks/RoundhousePluginCurrency.xml" &&
        grep -Fq '<Interval>PT20M</Interval>' "$win_tasks/RoundhousePluginCurrency.xml" &&
        grep -Fq '<RunLevel>LeastPrivilege</RunLevel>' "$win_tasks/RoundhousePluginCurrency.xml" ||
        fail "the plugin currency task is not the 20-minute, unelevated run of the bundle"
      # Its last run, as status reports it from the WSL side.
      printf '%s\n' '{"schema":"roundhouse.plugin-currency-status","schema_version":1,"version":"0.9.66","started_at":"2026-10-02T09:00:00Z","finished_at":"2026-10-02T09:01:00Z","state":"held","updated":2,"held":1,"messages":["update claude a@m 1 -> 2","hold railyard@novotnyllc hooks: Codex has not synced to 0123456789ab yet; the next run retries"]}' \
        >"$win_local/Roundhouse/plugin-currency/status.json"
      win_out=$("$cli" fleet-schedule status)
      assert_contains "$win_out" "native Windows: \\RoundhousePluginCurrency — keeps this user's plugins current every 20 minutes"
      assert_contains "$win_out" "runs this version's bundle"
      assert_contains "$win_out" "native Windows: plugin currency: last run 2026-10-02T09:01:00Z: held (2 updated, 1 held), roundhouse 0.9.66"
      assert_contains "$win_out" "native Windows: plugin currency: hold railyard@novotnyllc hooks: Codex has not synced"
      # Idempotent: nothing obsolete is left and the currency task runs this
      # version's bundle, so a repeat plans no native step.
      : >"$WIN_UNREGISTER_LOG"
      : >"$WIN_REGISTER_LOG"
      win_out=$("$cli" fleet-schedule install 2>&1) || fail "a repeat install failed: $win_out"
      [ ! -s "$WIN_UNREGISTER_LOG" ] && [ ! -s "$WIN_REGISTER_LOG" ] || fail "a repeat install touched the Task Scheduler again"
      # A currency task that is not this version's definition is re-pointed,
      # bound to the definition observed.
      sed 's/PT20M/PT5M/' "$win_tasks/RoundhousePluginCurrency.xml" >"$win_root/edited.xml"
      cp "$win_root/edited.xml" "$win_tasks/RoundhousePluginCurrency.xml"
      assert_contains "$("$cli" fleet-schedule status)" "re-points it"
      win_out=$("$cli" fleet-schedule install 2>&1) || fail "install did not re-point an edited currency task: $win_out"
      [ "$(cat "$WIN_REGISTER_LOG")" = '\RoundhousePluginCurrency' ] && grep -Fq PT20M "$win_tasks/RoundhousePluginCurrency.xml" ||
        fail "install did not re-point the edited plugin currency task"
      # uninstall takes this host's timers off and the currency task with
      # them; no other native task is its.
      : >"$WIN_UNREGISTER_LOG"
      win_out=$("$cli" fleet-schedule uninstall 2>&1) || fail "uninstall failed: $win_out"
      [ "$(cat "$WIN_UNREGISTER_LOG")" = '\RoundhousePluginCurrency' ] ||
        fail "uninstall removed other than the plugin currency task: $(cat "$WIN_UNREGISTER_LOG")"
      [ ! -e "$win_tasks/RoundhousePluginCurrency.xml" ] || fail "uninstall left the plugin currency task"
      [ -f "$win_tasks/RoundhouseBrokerV1.xml" ] || fail "uninstall removed the privilege lane's task"
      : >"$WIN_UNREGISTER_LOG"
      win_out=$("$cli" fleet-schedule uninstall 2>&1) || fail "a repeat uninstall failed: $win_out"
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "a repeat uninstall touched the Task Scheduler"

      # A Task Scheduler that refuses this session: the local jobs stand, the
      # task stays, and install exits 75 naming the desktop-session fix.
      win_seed
      win_reset_units
      win_status=0
      win_out=$(WIN_DENY=1 "$cli" fleet-schedule install 2>&1) || win_status=$?
      [ "$win_status" -eq 75 ] || fail "a refused native removal was not install's 75 ($win_status): $win_out"
      [ -f "$win_tasks/$win_stale.xml" ] || fail "a refused removal still deleted the task"
      [ ! -e "$win_tasks/RoundhousePluginCurrency.xml" ] || fail "a refused registration left a task"
      assert_contains "$win_out" "RoundhousePluginCurrency was not registered: Task Scheduler refused this session (Access is denied). Registering it needs the user's own desktop session"
      assert_contains "$win_out" "does not run this version's plugin currency bundle"
      [ -f "$win_units/roundhouse-fleet-full.timer" ] || fail "a refused native removal undid the local jobs"
      assert_contains "$win_out" "Access is denied"
      assert_contains "$win_out" "Unregister-ScheduledTask -TaskName $win_stale -TaskPath \\ -Confirm:\$false"
      assert_contains "$win_out" "own desktop session"
      assert_contains "$win_out" "is still registered"

      # An uninstall the Task Scheduler refuses: the timers are gone and the
      # host opted out, the currency task stays, and uninstall exits 75.
      win_out=$("$cli" fleet-schedule install 2>&1) || fail "install failed: $win_out"
      win_status=0
      win_out=$(WIN_DENY=1 "$cli" fleet-schedule uninstall 2>&1) || win_status=$?
      [ "$win_status" -eq 75 ] || fail "a refused currency task removal was not uninstall's 75 ($win_status): $win_out"
      [ -f "$win_tasks/RoundhousePluginCurrency.xml" ] || fail "a refused removal deleted the currency task"
      [ ! -e "$win_units/roundhouse-fleet-fast.timer" ] && [ -e "$(fleet_schedule_optout_path)" ] ||
        fail "a refused native removal held up the local uninstall"
      assert_contains "$win_out" "RoundhousePluginCurrency is still registered"

      # The central apply pipeline itself (#94): a direct apply-plan of the
      # same sealed plan whose native removal is refused reports partial,
      # not completed — the postcondition is apply's, not only install's.
      win_seed
      win_reset_units
      ROUNDHOUSE_SCHEDULE_OBSERVE=1 "$cli" collect --target test-host --section agents \
        --output "$win_root/planning.jsonl"
      win_record=$(jq -c 'select(.kind == "agent_artifact" and .id == "roundhouse:schedule") | .data' \
        "$win_root/planning.jsonl")
      rm -rf "$win_root/direct" && mkdir -p "$win_root/direct"
      win_steps=$(fleet_schedule_plan_steps install "$win_record" "$win_root/direct")
      jq -n --argjson steps "$win_steps" '{domain:"agents",target:"test-host",operations:[{
        type:"agent-update",kind:"agent_artifact",id:"roundhouse:schedule",
        argv:["roundhouse","fleet-schedule","install"],steps:$steps}]}' >"$win_root/direct/draft.json"
      # Each native step's postcondition on its own: a plan of the local
      # jobs and only the removal, then only the registration.
      # Each from a fresh seed and its own planning snapshot, so neither
      # rides on the other's changes.
      for win_only in unregister register; do
        win_seed
        win_reset_units
        rm -rf "$win_root/direct/$win_only" "$win_root/direct/result.jsonl"
        mkdir -p "$win_root/direct/$win_only"
        ROUNDHOUSE_SCHEDULE_OBSERVE=1 "$cli" collect --target test-host --section agents \
          --output "$win_root/direct/$win_only/planning.jsonl"
        win_steps=$(fleet_schedule_plan_steps install "$(jq -c 'select(.kind == "agent_artifact" and
          .id == "roundhouse:schedule") | .data' "$win_root/direct/$win_only/planning.jsonl")" "$win_root/direct/$win_only")
        jq -n --arg only "$win_only" --argjson steps "$win_steps" '{domain:"agents",target:"test-host",operations:[{
          type:"agent-update",kind:"agent_artifact",id:"roundhouse:schedule",
          argv:["roundhouse","fleet-schedule","install"],
          steps:($steps | map(select(.mode != "native" or .action == $only)))}]}' >"$win_root/direct/only.json"
        [ "$(jq '[.operations[0].steps[] | select(.mode == "native")] | length' "$win_root/direct/only.json")" -eq 1 ] ||
          fail "the direct $win_only fixture is not one native step"
        "$cli" seal-plan "$win_root/direct/only.json" "$win_root/direct/$win_only/planning.jsonl" \
          "$win_root/direct/plan.json" || fail "the native $win_only plan did not seal"
        win_status=0
        WIN_DENY=1 ROUNDHOUSE_SCHEDULE_OBSERVE=1 "$cli" apply-plan "$win_root/direct/plan.json" \
          "$(jq -r '.plan_id' "$win_root/direct/plan.json")" "$win_root/direct/result.jsonl" \
          >/dev/null 2>"$win_root/direct/apply.err" || win_status=$?
        [ "$win_status" -ne 0 ] &&
          jq -s -e 'any(.[]; .kind == "operation" and .data.operation_status == "partial" and
            .data.failed_operation_index == null)' "$win_root/direct/result.jsonl" >/dev/null ||
          fail "a direct apply-plan whose native $win_only was refused did not report partial ($win_status)"
        [ -f "$win_tasks/$win_stale.xml" ] && [ ! -e "$win_tasks/RoundhousePluginCurrency.xml" ] ||
          fail "the refused direct apply changed the Task Scheduler"
      done

      # Bound to the planning snapshot (#94): a hand-supplied unregister of a
      # task the snapshot never observed — or observed on another machine —
      # does not seal.
      for win_forged in \
        '.operations[0].steps += [{action:"unregister",mode:"native",machine:"test-windows",name:"Roundhouse-Forged-00000000000000000000000000000009",path:"\\",digest:("0" * 64)}]' \
        '(.operations[0].steps[] | select(.action == "unregister")).machine = "other-windows"' \
        '(.operations[0].steps[] | select(.action == "unregister")).digest = ("1" * 64)'; do
        jq "$win_forged" "$win_root/direct/draft.json" >"$win_root/direct/forged.json"
        ! "$cli" seal-plan "$win_root/direct/forged.json" "$win_root/planning.jsonl" \
          "$win_root/direct/forged-plan.json" >/dev/null 2>&1 ||
          fail "a native unregister the planning snapshot does not hold was sealed: $win_forged"
      done
      for win_forged in \
        '(.operations[0].steps[] | select(.action == "register")).before = ("0" * 64)' \
        '(.operations[0].steps[] | select(.action == "register")).machine = "other-windows"'; do
        jq "$win_forged" "$win_root/direct/draft.json" >"$win_root/direct/forged.json"
        ! "$cli" seal-plan "$win_root/direct/forged.json" "$win_root/planning.jsonl" \
          "$win_root/direct/forged-plan.json" >/dev/null 2>&1 ||
          fail "a native register the planning snapshot does not hold was sealed: $win_forged"
      done
      jq 'select(.id == "roundhouse:schedule") .data.native.reachable = false' \
        "$win_root/planning.jsonl" >"$win_root/direct/unreached.jsonl"
      ! "$cli" seal-plan "$win_root/direct/draft.json" "$win_root/direct/unreached.jsonl" \
        "$win_root/direct/forged-plan.json" >/dev/null 2>&1 ||
        fail "a native unregister sealed against an unreachable native observation"

      # The configured sibling's identity (#94): a Windows session that is
      # not the inventory's machine is neither inspected nor changed, and
      # the local install goes ahead.
      win_seed
      win_reset_units
      : >"$WIN_UNREGISTER_LOG"
      win_out=$(WIN_HOST=OTHER-PC "$cli" fleet-schedule status)
      assert_contains "$win_out" "native Windows: Task Scheduler not inspected"
      assert_contains "$win_out" "not the configured WREN-PC"
      win_out=$(WIN_USER=mallory "$cli" fleet-schedule install 2>&1) ||
        fail "install failed because the native session was another account: $win_out"
      [ -f "$win_units/roundhouse-fleet-fast.timer" ] || fail "a mismatched native identity held up the local jobs"
      [ ! -s "$WIN_UNREGISTER_LOG" ] && [ ! -s "$WIN_REGISTER_LOG" ] && [ -f "$win_tasks/$win_stale.xml" ] ||
        fail "a native task was changed through a session that is not the configured machine"
      # The executor's own gate, beneath the plan: a session that changed
      # identity since the seal is refused by the Windows side.
      WIN_HOST=OTHER-PC fleet_schedule_windows_unregister test-windows "$win_stale" \
        "$(shasum -a 256 "$win_tasks/$win_stale.xml" | awk '{print $1}')" 2>"$win_root/unregister.err"
      assert_contains "$(cat "$win_root/unregister.err")" "not the configured"
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "the Windows side unregistered a task for another machine"
      # No sibling in the inventory: the native half is reported and skipped.
      win_reset_units
      win_out=$(ROUNDHOUSE_CONFIG="$win_root/no-sibling.json" "$cli" fleet-schedule install 2>&1) ||
        fail "install failed with no configured Windows sibling: $win_out"
      [ ! -s "$WIN_UNREGISTER_LOG" ] && [ ! -s "$WIN_REGISTER_LOG" ] ||
        fail "install changed a Windows side the inventory does not configure"
      assert_contains "$(ROUNDHOUSE_CONFIG="$win_root/no-sibling.json" "$cli" fleet-schedule status)" \
        'native Windows: Task Scheduler not inspected — no single configured Windows machine names test-host'

      # A task that changed between the seal and the apply is not the sealed
      # one: apply's recheck refuses, and nothing native is touched.
      win_seed
      win_reset_units
      : >"$WIN_UNREGISTER_LOG"
      win_status=0
      # shellcheck disable=SC2016 # expanded by the driver's own bash
      win_out=$(WIN_AFTER_SEAL='printf "<!-- edited -->\n" >>"$WIN_TASKS/'"$win_stale"'.xml"' \
        win_sealed install 2>&1) || win_status=$?
      [ "$win_status" -ne 0 ] || fail "install applied a plan whose native task changed after the seal"
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "a changed native task was unregistered anyway"
      [ -f "$win_tasks/$win_stale.xml" ] || fail "a changed native task was removed"
      # The Windows side's own gate, beneath the recheck: a digest that is
      # not the task's, or a running task, is left in place.
      cp "$win_root/stale.xml.saved" "$win_tasks/$win_stale.xml"
      fleet_schedule_windows_unregister test-windows "$win_stale" "$(printf '%064d' 0)" 2>"$win_root/unregister.err"
      assert_contains "$(cat "$win_root/unregister.err")" "was left in place (changed)"
      : >"$win_tasks/$win_stale.running"
      fleet_schedule_windows_unregister test-windows "$win_stale" \
        "$(shasum -a 256 "$win_tasks/$win_stale.xml" | awk '{print $1}')" 2>"$win_root/unregister.err"
      assert_contains "$(cat "$win_root/unregister.err")" "was left in place (running)"
      [ -f "$win_tasks/$win_stale.xml" ] || fail "the Windows side removed a running or changed task"
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "the Windows side called Unregister-ScheduledTask past its own gate"
    else
      printf 'NOTICE: pwsh is unavailable; the native Task Scheduler driver fixtures were skipped\n'
    fi
  )
fi
