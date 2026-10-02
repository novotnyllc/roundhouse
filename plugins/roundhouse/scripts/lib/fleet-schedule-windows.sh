# roundhouse — the Windows Task Scheduler backend of fleet-schedule, reached
# from the WSL side of the same machine.
#
# Native Windows gets NO fleet-run task, by design rather than omission:
# roundhouse has no native Windows runtime (the CLI is Bash, the fleet store
# a jj repository, signing `ssh-keygen -Y`), and the Windows host of a WSL
# distribution is operated from that distribution through the interop lane
# (docs/specs/2026-08-06-dsc-storage-design-v2.md §9.2, KTD15). A native
# task running `roundhouse fleet-run` would have nothing to run. So the
# schedule for such a machine is its WSL distribution's own systemd timer
# pair, and this backend gives that schedule the Windows side's view:
#
#   observe   every Roundhouse* task in the Task Scheduler, each with the
#             SHA-256 of its exported definition and a class decided by
#             scripts/schedule-windows.ps1 (privilege-lane, obsolete-oneshot,
#             unknown) — into the sealed roundhouse:schedule record as
#             `native`, so the plan's precondition covers it;
#   plan      `install` unregisters each obsolete-oneshot task (a release-gate
#             session's trigger-less leftover) and nothing else;
#   apply     one native unregister per sealed step, which the Windows side
#             performs only while the task still hashes to the sealed digest,
#             still classifies as obsolete and is not running — its definition
#             kept first;
#   verify    a fresh inspect: an obsolete task still registered is reported
#             with the fix, and `install` exits 75.
#
# Everything on the Windows side runs as a native process holding the
# logged-in user's token, started from this distribution exactly as the
# interop lane starts one (lib/interop.sh): full-path PowerShell 7 from the
# drive root, the fixed `-EncodedCommand` bootstrap, the driver and one
# bounded request on standard input. Nothing is elevated, and a Task
# Scheduler refusal ("Access is denied") is reported as needing the user's
# own desktop session, never retried another way.
#
# Reached through fleet_schedule_native, the dispatcher beside
# fleet_schedule_backend: the local platform here is systemd, and the Task
# Scheduler is the OTHER half of the machine.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_schedule_windows_result_marker='roundhouse-schedule-result '
fleet_schedule_windows_oneshot_re='^Roundhouse-[A-Za-z0-9]{1,32}-[0-9a-f]{32}$'

fleet_schedule_native() {
  # fleet_schedule_native VERB [ARG...] — fleet_schedule_windows_VERB on a WSL
  # distribution (the one host kind with a native half), else 69.
  fleet_schedule_windows_host || return 69
  "fleet_schedule_windows_$1" "${@:2}"
}

fleet_schedule_windows_host() {
  # True on a WSL distribution: this machine has a native Windows half whose
  # Task Scheduler the schedule must account for. Read from the kernel the
  # distribution runs on, so a systemd service (no WSL_* environment) sees
  # it too. The self-check states it instead.
  if fleet_test_hook "${ROUNDHOUSE_SCHEDULE_WSL:-}"; then
    [ "$ROUNDHOUSE_SCHEDULE_WSL" = 1 ]
    return
  fi
  [ "$(uname -s)" = Linux ] || return 1
  grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

fleet_schedule_windows_call() {
  # fleet_schedule_windows_call REQUEST-JSON — run scripts/schedule-windows.ps1
  # natively with REQUEST and print its ONE validated result object. Fails
  # (69 the lane is unreachable, 70 no well-formed result) with the reason on
  # stderr; the caller decides what that means for its step.
  call_pwsh=$(interop_pwsh_path)
  [ -x "$call_pwsh" ] || {
    printf 'PowerShell 7 is not reachable through WSL interop (%s)\n' "$call_pwsh" >&2
    return 69
  }
  call_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule-windows.XXXXXX") || return 70
  interop_base64_file "$script_dir/schedule-windows.ps1" >"$call_tmp/driver.b64"
  jq -cn --rawfile driver "$call_tmp/driver.b64" --argjson request "$1" \
    '{driver:($driver | rtrimstr("\n")),request:$request}' >"$call_tmp/input.json" || {
    rm -rf "$call_tmp"
    return 70
  }
  call_rc=0
  # cd first: without it Windows processes start in C:\Windows.
  # shellcheck disable=SC2016 # expanded by the child sh, not here
  bounded_query sh -c '
cd -- "$1" || exit 69
exec "$2" -NoLogo -NoProfile -NonInteractive -EncodedCommand "$3"
' roundhouse-schedule-windows "$(interop_drive_root)" "$call_pwsh" "$(interop_bootstrap_encoded)" \
    <"$call_tmp/input.json" >"$call_tmp/raw" 2>/dev/null || call_rc=$?
  tr -d '\r' <"$call_tmp/raw" | jq -R -r --arg marker "$fleet_schedule_windows_result_marker" \
    'select(startswith($marker)) | ltrimstr($marker)' >"$call_tmp/result.b64" 2>/dev/null || :
  if [ "$(grep -c . "$call_tmp/result.b64" 2>/dev/null || :)" != 1 ] ||
    ! jq -R -r '@base64d' "$call_tmp/result.b64" >"$call_tmp/result.json" 2>/dev/null ||
    ! fleet_schedule_windows_result_valid "$call_tmp/result.json"; then
    rm -rf "$call_tmp"
    if [ "$call_rc" -eq 124 ]; then
      printf 'the native Task Scheduler did not answer within %ss\n' "$(run_bounded_seconds list)" >&2
    else
      printf 'no well-formed native Task Scheduler result (status %s)\n' "$call_rc" >&2
    fi
    return 70
  fi
  jq -c . "$call_tmp/result.json"
  rm -rf "$call_tmp"
}

fleet_schedule_windows_result_valid() {
  # The closed shape of one schedule-windows.ps1 result. Nothing from the
  # Windows side is believed beyond it: names, paths and digests are bounded,
  # and no task definition's content travels at all.
  jq -e --arg oneshot "$fleet_schedule_windows_oneshot_re" '
    def text($n): type == "string" and length <= $n and (test("[[:cntrl:]]") | not);
    (keys == ["backup","message","mode","outcome","schema","schema_version","state","tasks","user_sid"]) and
    .schema == "roundhouse.schedule-windows-result" and .schema_version == 1 and
    (.mode | IN("inspect","unregister","")) and (.state | IN("completed","failed")) and
    (.message | text(1024)) and (.user_sid | text(184)) and (.backup | text(512)) and
    (.outcome | IN("","removed","absent","refused","changed","not-obsolete","running","failed")) and
    (.tasks | type == "array" and length <= 64 and all(.[];
      type == "object" and
      (keys == ["class","digest","last_result","last_run","name","path","state"]) and
      (.name | type == "string" and test("^Roundhouse[A-Za-z0-9._-]{0,118}$"; "i")) and
      (.path | type == "string" and test("^\\\\([A-Za-z0-9 ._-]{1,64}\\\\){0,4}$")) and
      (.class | IN("privilege-lane","obsolete-oneshot","unknown")) and
      (.digest | type == "string" and test("^[0-9a-f]{64}$")) and
      (.state | text(32)) and
      (.last_run | type == "string" and test("^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z)?$")) and
      (.last_result == null or (.last_result | type == "number")) and
      (if .class == "obsolete-oneshot" then .path == "\\" and (.name | test($oneshot)) else true end)))
  ' "$1" >/dev/null 2>&1
}

fleet_schedule_windows_inspect() {
  # The native Task Scheduler's Roundhouse tasks: the inspect result object,
  # or a failure with the reason on stderr.
  inspect_result=$(fleet_schedule_windows_call \
    '{"schema":"roundhouse.schedule-windows-request","schema_version":1,"mode":"inspect"}') ||
    return $?
  [ "$(printf '%s\n' "$inspect_result" | jq -r '.state')" = completed ] || {
    printf 'the native Task Scheduler could not be read: %s\n' \
      "$(printf '%s\n' "$inspect_result" | jq -r '.message')" >&2
    return 70
  }
  printf '%s\n' "$inspect_result"
}

fleet_schedule_windows_observe() {
  # The `native` half of the roundhouse:schedule record. Only what is stable
  # between the seal and the apply goes in — a task's last run time does
  # not — because the record is the plan's precondition.
  # On success the inspect prints only its result; on failure only its reason.
  if observe_native=$(fleet_schedule_windows_inspect 2>&1); then
    printf '%s\n' "$observe_native" | jq -c '{lane:"wsl-interop",reachable:true,reason:null,
      tasks:[.tasks[] | {name,path,class,digest}]}'
    return 0
  fi
  jq -cn --arg reason "$(printf '%s\n' "$observe_native" | head -n 1)" \
    '{lane:"wsl-interop",reachable:false,
      reason:(if $reason == "" then "the native Task Scheduler could not be reached" else $reason end),
      tasks:[]}'
}

fleet_schedule_windows_plan() {
  # fleet_schedule_windows_plan ACTION RECORD — the native steps: on install,
  # one `unregister` per obsolete one-shot task the record observed; on
  # uninstall none (this host's jobs are its systemd timers, and no native
  # task is one of them).
  [ "$1" = install ] || return 0
  printf '%s\n' "$2" | jq -c '
    (.native // {}) as $n | select($n.reachable == true) |
    $n.tasks[] | select(.class == "obsolete-oneshot") |
    {action:"unregister",mode:"native",name,path,digest}'
}

fleet_schedule_windows_unregister() {
  # fleet_schedule_windows_unregister NAME DIGEST — the executor's one native
  # mutation. The Windows side re-reads the task and removes it only while
  # it is still the sealed definition of an obsolete one-shot task. Always
  # returns 0 once the request went out: a refusal is the operator's to
  # resolve and does not undo the local jobs the same plan installed; the
  # verify after apply reports what is left.
  unregister_request=$(jq -cn --arg name "$1" --arg digest "$2" \
    '{schema:"roundhouse.schedule-windows-request",schema_version:1,mode:"unregister",
      name:$name,digest:$digest}')
  unregister_result=$(fleet_schedule_windows_call "$unregister_request" 2>&1) || {
    printf 'roundhouse: native Windows: %s was not removed: %s\n' "$1" \
      "$(printf '%s\n' "$unregister_result" | head -n 1)" >&2
    return 0
  }
  printf '%s\n' "$unregister_result" | jq -r --arg name "$1" '
    if .state != "completed" then
      "roundhouse: native Windows: \($name) was not removed: \(.message)"
    elif .outcome == "removed" then
      "roundhouse: native Windows: removed the obsolete one-shot task \($name); its definition is kept as \(.backup)"
    elif .outcome == "absent" then
      "roundhouse: native Windows: \($name) is already gone"
    elif .outcome == "refused" then
      "roundhouse: native Windows: \($name) was not removed: \(.message). Removing it needs the user'"'"'s own desktop session: run `Unregister-ScheduledTask -TaskName \($name) -TaskPath \\ -Confirm:$false` in PowerShell there"
    else
      "roundhouse: native Windows: \($name) was left in place (\(.outcome)): \(.message)"
    end' >&2
}

fleet_schedule_windows_status() {
  # `fleet-schedule status`'s native lines, read-only. Returns 0 even when the
  # Windows side cannot be reached: the reason is the line.
  status_native=$(fleet_schedule_windows_inspect 2>&1) || {
    printf 'native Windows: Task Scheduler not inspected — %s\n' \
      "$(printf '%s\n' "$status_native" | head -n 1)"
    return 0
  }
  printf 'native Windows: no fleet-run task, by design — roundhouse has no native runtime; the timers above are this machine'"'"'s one scheduled runner, and they converge this WSL side (native Windows changes only through the interop lane)\n'
  printf '%s\n' "$status_native" | jq -r '
    .tasks[] |
    (if .last_run == "" then "never run" else "last run \(.last_run), result \(.last_result)" end) as $run |
    "native Windows: \(.path)\(.name) — " +
    (if .class == "privilege-lane" then
       "the privilege lane'"'"'s task (enroll-privilege-windows), not a schedule job; left alone"
     elif .class == "obsolete-oneshot" then
       "an obsolete one-shot release-gate task (no trigger, \($run)); `fleet-schedule install` removes it"
     else
       "not a task roundhouse recognises (\(.state), \($run)); reported, never changed"
     end)'
}

fleet_schedule_windows_verify() {
  # fleet_schedule_windows_verify — after an install: 0 when no obsolete
  # one-shot task is still registered, else 75 with each one named. An
  # inspection that fails AFTER the plan reached Windows proves nothing was
  # removed, so it is 75 too, never a verified removal.
  verify_native=$(fleet_schedule_windows_inspect 2>/dev/null) || {
    printf 'roundhouse: native Windows: could not inspect the Task Scheduler after the install, so the obsolete one-shot tasks are unverified; re-run `roundhouse fleet-schedule install`\n' >&2
    return 75
  }
  verify_left=$(printf '%s\n' "$verify_native" |
    jq -r '.tasks[] | select(.class == "obsolete-oneshot") | .name')
  [ -n "$verify_left" ] || return 0
  printf '%s\n' "$verify_left" | while IFS= read -r verify_name; do
    printf 'roundhouse: native Windows: the obsolete one-shot task %s is still registered; from the user'"'"'s own desktop session run `Unregister-ScheduledTask -TaskName %s -TaskPath \\ -Confirm:$false`, or re-run `roundhouse fleet-schedule install`\n' \
      "$verify_name" "$verify_name" >&2
  done
  return 75
}
