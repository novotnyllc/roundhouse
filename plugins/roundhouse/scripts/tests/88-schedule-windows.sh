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
    jq '.machines["test-apt"].expected_hostname = "another-fixture-host" |
      .machines["test-apt"].expected_user = "another-fixture-user"' \
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
    win_valid='{"schema":"roundhouse.schedule-windows-result","schema_version":1,"mode":"inspect","state":"completed","message":"","user_sid":"S-1-5-21-1","tasks":[{"name":"Roundhouse-Remaining-0123456789abcdef0123456789abcdef","path":"\\","class":"obsolete-oneshot","digest":"'"$(printf '%064d' 0)"'","state":"Ready","last_run":"2026-09-22T13:06:11Z","last_result":0}],"outcome":"","backup":""}'
    printf '%s\n' "$win_valid" >"$win_root/result.json"
    fleet_schedule_windows_result_valid "$win_root/result.json" ||
      fail "a well-formed native result was rejected"
    for win_bad in \
      '.extra = 1' \
      '.tasks[0].class = "removable"' \
      '.tasks[0].name = "RoundhouseBrokerV1"' \
      '.tasks[0].path = "\\Roundhouse\\"' \
      '.tasks[0].name = "Other-Task"' \
      '.tasks[0].digest = "ABC"' \
      '.tasks[0].xml = "<Task/>"' \
      '.message = "a\u0007b"' \
      '.tasks = [range(65) | {name:"RoundhouseX",path:"\\",class:"unknown",digest:("0" * 64),state:"Ready",last_run:"",last_result:null}]' \
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
      '{action:"unregister",mode:"native",name:$name,path:"\\",digest:$digest}')
    win_contract install "$win_step" || fail "the plan contract refused a native unregister step"
    ! win_contract uninstall "$win_step" || fail "an uninstall plan may unregister a native task"
    for win_bad in '.name = "RoundhouseBrokerV1"' '.path = "\\Roundhouse\\"' '.mode = "fast"' \
      '.digest = "x"' '.argv = ["schtasks"]'; do
      ! win_contract install "$(printf '%s\n' "$win_step" | jq -c "$win_bad")" ||
        fail "the plan contract accepted a widened unregister step: $win_bad"
    done

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
    fleet_schedule_windows_call '{"schema":"roundhouse.schedule-windows-request","schema_version":1,"mode":"inspect"}' \
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
function Get-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
    foreach ($File in @(Get-ChildItem -LiteralPath $env:WIN_TASKS -Filter "*.xml" | Sort-Object Name)) {
        $Name = $File.BaseName
        if ($TaskName -and $Name -cne $TaskName) { continue }
        $State = if (Test-Path -LiteralPath (Join-Path $env:WIN_TASKS "$Name.running")) { "Running" } else { "Ready" }
        [pscustomobject]@{ TaskName = $Name; TaskPath = "\"; State = $State }
    }
}
function Export-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
    return [IO.File]::ReadAllText((Join-Path $env:WIN_TASKS "$TaskName.xml"))
}
function Get-ScheduledTaskInfo {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath)
    return [pscustomobject]@{ LastRunTime = [DateTime]::new(2026, 9, 22, 13, 6, 11, [DateTimeKind]::Utc); LastTaskResult = 0 }
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
export TMPDIR="$WIN_TEMP/" LOCALAPPDATA="$WIN_LOCAL" ROUNDHOUSE_SCHEDULE_FIXTURE_SID="$WIN_SID"
exec "$REAL_PWSH" -NoLogo -NoProfile -NonInteractive -EncodedCommand \
  "$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
SH
      chmod +x "$ROUNDHOUSE_INTEROP_PWSH"
      WIN_TASKS=$win_tasks WIN_TEMP=$win_temp WIN_LOCAL=$win_local WIN_SID=$win_sid
      WIN_STUBS="$win_root/stubs.ps1" WIN_UNREGISTER_LOG="$win_root/unregister.log"
      REAL_PWSH=$pwsh_command
      export WIN_TASKS WIN_TEMP WIN_LOCAL WIN_SID WIN_STUBS WIN_UNREGISTER_LOG REAL_PWSH
      win_task_xml() {
        # win_task_xml USER-SID SCRIPT [TRIGGERS] — a task definition in the
        # shape Export-ScheduledTask prints.
        printf '<?xml version="1.0" encoding="UTF-16"?>\n<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">\n  <RegistrationInfo><Description>Temporary one-shot verified Roundhouse package apply as the existing standard user</Description></RegistrationInfo>\n  <Principals><Principal id="Author"><UserId>%s</UserId><LogonType>InteractiveToken</LogonType></Principal></Principals>\n  %s\n  <Actions Context="Author"><Exec><Command>C:\\Program Files\\PowerShell\\7\\pwsh.exe</Command><Arguments>-NoLogo -NoProfile -NonInteractive -File &quot;%s&quot;</Arguments></Exec></Actions>\n</Task>\n' \
          "$1" "${3:-<Triggers />}" "$2"
      }
      win_seed() {
        rm -f "$win_tasks"/* "$WIN_UNREGISTER_LOG"
        : >"$WIN_UNREGISTER_LOG"
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
        cp "$win_tasks/$win_stale.xml" "$win_root/stale.xml.saved"
      }

      # status: the stale task is named as obsolete, the rest are left alone.
      win_seed
      win_out=$("$cli" fleet-schedule status) || fail "status failed with a reachable native half"
      for win_expect in \
        'native Windows: no fleet-run task, by design' \
        "native Windows: \\$win_stale — an obsolete one-shot release-gate task (no trigger, last run 2026-09-22T13:06:11Z, result 0); \`fleet-schedule install\` removes it" \
        "native Windows: \\RoundhouseBrokerV1 — the privilege lane's task" \
        'native Windows: \Roundhouse-Logon-00000000000000000000000000000001 — not a task roundhouse recognises' \
        'native Windows: \Roundhouse-Other-00000000000000000000000000000002 — not a task roundhouse recognises'; do
        assert_contains "$win_out" "$win_expect"
      done
      case $win_out in *'pwsh.exe'* | *'release-gate.649j8Z'* | *'one-shot verified'*)
        fail "status printed a task definition's content: $win_out" ;;
      esac
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "status changed the Task Scheduler"

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
      cmp -s "$win_local/Roundhouse/schedule-removed/$win_stale.xml" "$win_root/stale.xml.saved" ||
        fail "the removed task's definition was not kept byte for byte"
      assert_contains "$win_out" "removed the obsolete one-shot task $win_stale; its definition is kept as"
      # Idempotent: nothing obsolete is left, so a repeat plans no native step.
      : >"$WIN_UNREGISTER_LOG"
      win_out=$("$cli" fleet-schedule install 2>&1) || fail "a repeat install failed: $win_out"
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "a repeat install touched the Task Scheduler again"
      # uninstall takes this host's timers off; native tasks are not its jobs.
      win_out=$("$cli" fleet-schedule uninstall 2>&1) || fail "uninstall failed: $win_out"
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "uninstall touched the native Task Scheduler"
      [ -f "$win_tasks/RoundhouseBrokerV1.xml" ] || fail "uninstall removed the privilege lane's task"

      # A Task Scheduler that refuses this session: the local jobs stand, the
      # task stays, and install exits 75 naming the desktop-session fix.
      win_seed
      win_reset_units
      win_status=0
      win_out=$(WIN_DENY=1 "$cli" fleet-schedule install 2>&1) || win_status=$?
      [ "$win_status" -eq 75 ] || fail "a refused native removal was not install's 75 ($win_status): $win_out"
      [ -f "$win_tasks/$win_stale.xml" ] || fail "a refused removal still deleted the task"
      [ -f "$win_units/roundhouse-fleet-full.timer" ] || fail "a refused native removal undid the local jobs"
      assert_contains "$win_out" "Access is denied"
      assert_contains "$win_out" "Unregister-ScheduledTask -TaskName $win_stale -TaskPath \\ -Confirm:\$false"
      assert_contains "$win_out" "own desktop session"

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
      fleet_schedule_windows_unregister "$win_stale" "$(printf '%064d' 0)" 2>"$win_root/unregister.err"
      assert_contains "$(cat "$win_root/unregister.err")" "was left in place (changed)"
      : >"$win_tasks/$win_stale.running"
      fleet_schedule_windows_unregister "$win_stale" \
        "$(shasum -a 256 "$win_tasks/$win_stale.xml" | awk '{print $1}')" 2>"$win_root/unregister.err"
      assert_contains "$(cat "$win_root/unregister.err")" "was left in place (running)"
      [ -f "$win_tasks/$win_stale.xml" ] || fail "the Windows side removed a running or changed task"
      [ ! -s "$WIN_UNREGISTER_LOG" ] || fail "the Windows side called Unregister-ScheduledTask past its own gate"
    else
      printf 'NOTICE: pwsh is unavailable; the native Task Scheduler driver fixtures were skipped\n'
    fi
  )
fi
