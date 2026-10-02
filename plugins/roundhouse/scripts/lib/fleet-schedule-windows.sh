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
# pair, and this backend gives that schedule the Windows side's view.
#
# What native Windows DOES get is one task that needs no roundhouse runtime:
# RoundhousePluginCurrency, per-user and unelevated, which runs the shipped
# scripts/plugins-windows.ps1 every 20 minutes to keep this user's Claude
# Code and Codex plugins current (third-party ones too). Its action runs a
# content-addressed copy of the current plugin version's script and hook
# helper (the "bundle", fleet_schedule_windows_bundle), so each install that
# ships new bytes re-points it.
#
#   observe   every Roundhouse* task in the configured Windows machine's Task
#             Scheduler, each with the SHA-256 of its exported definition and
#             a class decided by scripts/schedule-windows.ps1
#             (privilege-lane, obsolete-oneshot, plugin-currency with the
#             bundle it runs, unknown) — into the sealed roundhouse:schedule
#             record as `native`, so the plan's precondition covers it;
#   plan      `install` unregisters each obsolete-oneshot task (a release-gate
#             session's trigger-less leftover) and registers the plugin
#             currency task unless it already runs this version's bundle;
#             `uninstall` unregisters the plugin currency task; nothing else;
#   apply     one native step per sealed step, which the Windows side performs
#             only while the task still hashes to the sealed digest (or is
#             still absent): an unregister also while it still classifies and
#             is not running, its definition kept first; a register only with
#             bundle bytes that hash to the sealed bundle;
#   verify    a fresh inspect: an obsolete task still registered, or a plugin
#             currency task not (or still) registered, is reported with the
#             fix, and the command exits 75.
#
# The Windows half is the inventory's, not whatever answers on interop: the
# one configured `platform: windows` machine whose `wsl_interop_via` names
# this host's own local WSL record (fleet_schedule_windows_sibling). Every
# request carries that machine's expected hostname and user, the Windows side
# refuses a session that is not it before it reads anything, and the result's
# identity is checked again here. A machine with no such sibling has its
# native half reported as not inspected and skipped; the local jobs never
# wait on it. (Interop reaches only this hardware's own Windows, so this is
# consistency with the inventory, not a reachability fix.)
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
fleet_schedule_windows_currency=RoundhousePluginCurrency

fleet_schedule_windows_bundle() {
  # The digest of the plugin currency bundle this plugin version ships:
  # plugins-windows.ps1 and the hook helper it runs, in that order — the
  # same text scripts/schedule-windows.ps1 Get-BundleDigest hashes.
  bundle_script=$(sha256_file "$script_dir/plugins-windows.ps1") &&
    bundle_helper=$(sha256_file "$script_dir/codex-plugin-hooks.mjs") || return 70
  printf 'plugins-windows.ps1 %s\ncodex-plugin-hooks.mjs %s\n' "$bundle_script" "$bundle_helper" |
    sha256_stream
}

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

fleet_schedule_windows_sibling() {
  # fleet_schedule_windows_sibling [MACHINE] — the configured Windows half of
  # this machine, as one {machine,expected_hostname,expected_user} line: the
  # ONE `platform: windows` entry whose wsl_interop_via names the ONE local
  # WSL entry whose expected hostname and user are this host's (the record a
  # host-local plan binds to, local_plan_target). With MACHINE it must be
  # that entry. Otherwise 69, with the reason on stderr; nothing is guessed.
  sibling_found=$(jq -c --arg hostname "$(hostname)" --arg user "$(id -un)" --arg want "${1:-}" '
    [.machines // {} | to_entries[] | select(.value.platform == "wsl" and
      .value.transport == "local" and .value.expected_hostname == $hostname and
      .value.expected_user == $user) | .key] as $self |
    if ($self | length) != 1 then
      {reason:"no single configured local WSL machine is this host (\($hostname), \($user))"}
    else
      [.machines | to_entries[] | select(.value.platform == "windows" and
        (.value.wsl_interop_via // null) == $self[0])] as $windows |
      if ($windows | length) != 1 then
        {reason:"no single configured Windows machine names \($self[0]) as its wsl_interop_via sibling"}
      elif $want != "" and $windows[0].key != $want then
        {reason:"the configured Windows half of \($self[0]) is \($windows[0].key), not \($want)"}
      elif ($windows[0].value.expected_hostname | type == "string" and test("^[A-Za-z0-9._-]{1,253}$") | not) or
        ($windows[0].value.expected_user | type == "string" and test("^[A-Za-z0-9._@-]{1,128}$") | not) then
        {reason:"the configured Windows machine \($windows[0].key) has no expected_hostname and expected_user"}
      else
        {machine:$windows[0].key,expected_hostname:$windows[0].value.expected_hostname,
          expected_user:$windows[0].value.expected_user}
      end
    end' "$(config_path)" 2>/dev/null) || sibling_found='{"reason":"the roundhouse config could not be read"}'
  if [ "$(printf '%s\n' "$sibling_found" | jq -r 'has("machine")')" = true ]; then
    printf '%s\n' "$sibling_found"
    return 0
  fi
  printf '%s\n' "$sibling_found" | jq -r '.reason' >&2
  return 69
}

fleet_schedule_windows_request() {
  # fleet_schedule_windows_request SIBLING MODE [FIELDS-JSON] — one request
  # for the configured Windows machine SIBLING names.
  request_fields=${3:-}
  [ -n "$request_fields" ] || request_fields='{}'
  jq -cn --argjson sibling "$1" --arg mode "$2" --argjson fields "$request_fields" '
    {schema:"roundhouse.schedule-windows-request",schema_version:1,mode:$mode,
      expected_hostname:$sibling.expected_hostname,expected_user:$sibling.expected_user} + $fields'
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
  # and no task definition's content travels at all. A task roundhouse does
  # not recognise may carry any bounded name and folder (it is only ever
  # reported); a class it acts on keeps the strict root-folder names.
  jq -e --arg oneshot "$fleet_schedule_windows_oneshot_re" --arg currency "$fleet_schedule_windows_currency" '
    def text($n): type == "string" and length <= $n and (test("[[:cntrl:]]") | not);
    (keys == ["backup","currency","host","message","mode","outcome","schema","schema_version","state","tasks","user","user_sid"]) and
    .schema == "roundhouse.schedule-windows-result" and .schema_version == 1 and
    (.mode | IN("inspect","unregister","register","")) and (.state | IN("completed","failed")) and
    (.message | text(1024)) and (.user_sid | text(184)) and (.backup | text(512)) and
    (.host | text(253)) and (.user | text(128)) and
    (.outcome | IN("","removed","registered","absent","refused","changed","not-obsolete","running","failed")) and
    (.currency == null or (.currency | type == "object" and
      keys == ["finished_at","held","messages","started_at","state","updated","version"] and
      (.state | IN("running","current","held","timeout","failed")) and
      (.version | type == "string" and test("^([0-9A-Za-z.+-]{1,64})?$")) and
      ([.started_at, .finished_at] | all(type == "string" and test("^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z)?$"))) and
      ([.updated, .held] | all(type == "number" and . >= 0 and . <= 100000 and floor == .)) and
      (.messages | type == "array" and length <= 32 and all(.[]; text(256))))) and
    (.tasks | type == "array" and length <= 64 and all(.[];
      type == "object" and
      (keys == ["bundle","class","digest","last_result","last_run","name","path","state"]) and
      (.name | type == "string" and test("^[^\\\\/[:cntrl:]]{1,128}$")) and
      (.path | type == "string" and length <= 256 and test("^\\\\([^\\\\/[:cntrl:]]{1,64}\\\\){0,8}$")) and
      ((.name | test("^Roundhouse"; "i")) or (.path | test("^\\\\Roundhouse"; "i"))) and
      (.class | IN("privilege-lane","obsolete-oneshot","plugin-currency","unknown")) and
      (.bundle | type == "string" and test("^([0-9a-f]{64})?$")) and
      (if .class == "plugin-currency" then .name == $currency else .bundle == "" end) and
      (.digest | type == "string" and test("^[0-9a-f]{64}$")) and
      (.state | text(32)) and
      (.last_run | type == "string" and test("^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z)?$")) and
      (.last_result == null or (.last_result | type == "number")) and
      (if .class == "unknown" then true
       else .path == "\\" and (.name | test("^Roundhouse[A-Za-z0-9._-]{0,118}$")) end) and
      (if .class == "obsolete-oneshot" then .name | test($oneshot) else true end) and
      (if .class == "privilege-lane" then .name | IN("RoundhouseBrokerV1","RoundhouseProfileV1") else true end)))
  ' "$1" >/dev/null 2>&1
}

fleet_schedule_windows_identity_holds() {
  # fleet_schedule_windows_identity_holds SIBLING RESULT — the session that
  # answered is the configured machine and account (Windows compares them
  # without case, as it names them).
  printf '%s\n' "$2" | jq -e --argjson sibling "$1" '
    (.host | ascii_downcase) == ($sibling.expected_hostname | ascii_downcase) and
    (.user | ascii_downcase) == ($sibling.expected_user | ascii_downcase)' >/dev/null
}

fleet_schedule_windows_inspect() {
  # fleet_schedule_windows_inspect SIBLING — the configured Windows machine's
  # Roundhouse tasks: the inspect result object, or a failure with the reason
  # on stderr.
  inspect_result=$(fleet_schedule_windows_call "$(fleet_schedule_windows_request "$1" inspect)") ||
    return $?
  [ "$(printf '%s\n' "$inspect_result" | jq -r '.state')" = completed ] || {
    printf 'the native Task Scheduler could not be read: %s\n' \
      "$(printf '%s\n' "$inspect_result" | jq -r '.message')" >&2
    return 70
  }
  fleet_schedule_windows_identity_holds "$1" "$inspect_result" || {
    printf 'the native Task Scheduler answered as %s, not the configured %s\n' \
      "$(printf '%s\n' "$inspect_result" | jq -r '"\(.host)\\\(.user)"')" \
      "$(printf '%s\n' "$1" | jq -r '"\(.machine) (\(.expected_hostname)\\\(.expected_user))"')" >&2
    return 70
  }
  printf '%s\n' "$inspect_result"
}

fleet_schedule_windows_observe() {
  # The `native` half of the roundhouse:schedule record: the configured
  # Windows machine it is, and its tasks. Only what is stable between the
  # seal and the apply goes in — a task's last run time does not — because
  # the record is the plan's precondition. A sibling the inventory does not
  # configure is observed as unreachable, with the reason, and planned for
  # by no step.
  observe_sibling=$(fleet_schedule_windows_sibling 2>&1) || {
    jq -cn --arg reason "$(printf '%s\n' "$observe_sibling" | head -n 1)" \
      '{lane:"wsl-interop",machine:null,reachable:false,reason:$reason,tasks:[]}'
    return 0
  }
  observe_machine=$(printf '%s\n' "$observe_sibling" | jq -r '.machine')
  # On success the inspect prints only its result; on failure only its reason.
  if observe_native=$(fleet_schedule_windows_inspect "$observe_sibling" 2>&1); then
    printf '%s\n' "$observe_native" | jq -c --arg machine "$observe_machine" \
      '{lane:"wsl-interop",machine:$machine,reachable:true,reason:null,
        tasks:[.tasks[] | {name,path,class,digest,bundle}]}'
    return 0
  fi
  jq -cn --arg machine "$observe_machine" --arg reason "$(printf '%s\n' "$observe_native" | head -n 1)" \
    '{lane:"wsl-interop",machine:$machine,reachable:false,
      reason:(if $reason == "" then "the native Task Scheduler could not be reached" else $reason end),
      tasks:[]}'
}

fleet_schedule_windows_plan() {
  # fleet_schedule_windows_plan ACTION RECORD — the native steps, on the
  # configured Windows machine the record observed: on install, one
  # `unregister` per obsolete one-shot task, then a `register` of the plugin
  # currency task unless it already runs this version's bundle (bound to the
  # definition observed, or to its absence); on uninstall, an `unregister`
  # of the plugin currency task. Nothing else: no native task is one of this
  # host's fleet-run jobs.
  plan_bundle=$(fleet_schedule_windows_bundle) || return 70
  printf '%s\n' "$2" | jq -c --arg action "$1" --arg bundle "$plan_bundle" \
    --arg currency "$fleet_schedule_windows_currency" '
    (.native // {}) as $n | select($n.reachable == true and ($n.machine | type == "string")) |
    (first($n.tasks[] | select(.name == $currency and .path == "\\")) // null) as $c |
    if $action == "install" then
      ($n.tasks[] | select(.class == "obsolete-oneshot") |
        {action:"unregister",mode:"native",machine:$n.machine,name,path,digest}),
      (if $c != null and $c.class == "plugin-currency" and $c.bundle == $bundle then empty
       else {action:"register",mode:"native",machine:$n.machine,name:$currency,path:"\\",
         bundle:$bundle,before:($c.digest // null)} end)
    elif $c != null then
      {action:"unregister",mode:"native",machine:$n.machine,name:$currency,path:"\\",digest:$c.digest}
    else empty end'
}

fleet_schedule_windows_unregister() {
  # fleet_schedule_windows_unregister MACHINE NAME DIGEST — the executor's one
  # native mutation, on the configured Windows machine MACHINE only. The
  # Windows side refuses a session that is not that machine, re-reads the
  # task and removes it only while it is still the sealed definition of an
  # obsolete one-shot task. Always returns 0 once the request is decided: a
  # refusal is the operator's to resolve and does not undo the local jobs the
  # same plan installed; apply's postcondition reports what is left.
  unregister_sibling=$(fleet_schedule_windows_sibling "$1" 2>&1) || {
    printf 'roundhouse: native Windows: %s was not removed: %s\n' "$2" \
      "$(printf '%s\n' "$unregister_sibling" | head -n 1)" >&2
    return 0
  }
  unregister_request=$(fleet_schedule_windows_request "$unregister_sibling" unregister \
    "$(jq -cn --arg name "$2" --arg digest "$3" '{name:$name,digest:$digest}')")
  unregister_result=$(fleet_schedule_windows_call "$unregister_request" 2>&1) || {
    printf 'roundhouse: native Windows: %s was not removed: %s\n' "$2" \
      "$(printf '%s\n' "$unregister_result" | head -n 1)" >&2
    return 0
  }
  printf '%s\n' "$unregister_result" | jq -r --arg name "$2" '
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

fleet_schedule_windows_register() {
  # fleet_schedule_windows_register MACHINE BEFORE BUNDLE — the plugin
  # currency task, on the configured Windows machine MACHINE only, running
  # BUNDLE: this plugin's bundle bytes, which must still hash to the sealed
  # digest, travel with the request, and the Windows side writes them, checks
  # them again, and registers the task only while it is still the definition
  # the plan observed (BEFORE, empty for absent). Returns 0 once the request
  # is decided, as an unregister does: apply's postcondition reports a task
  # that is not registered.
  register_sibling=$(fleet_schedule_windows_sibling "$1" 2>&1) || {
    printf 'roundhouse: native Windows: %s was not registered: %s\n' "$fleet_schedule_windows_currency" \
      "$(printf '%s\n' "$register_sibling" | head -n 1)" >&2
    return 0
  }
  [ "$(fleet_schedule_windows_bundle)" = "$3" ] || {
    printf 'roundhouse: native Windows: %s was not registered: this plugin'"'"'s bundle changed since the plan was sealed; create a new plan\n' \
      "$fleet_schedule_windows_currency" >&2
    return 0
  }
  register_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule-register.XXXXXX") || return 0
  interop_base64_file "$script_dir/plugins-windows.ps1" >"$register_tmp/script.b64"
  interop_base64_file "$script_dir/codex-plugin-hooks.mjs" >"$register_tmp/helper.b64"
  register_fields=$(jq -cn --arg name "$fleet_schedule_windows_currency" --arg before "$2" \
    --arg bundle "$3" --arg version "$(jq -r '.version' "$script_dir/../.claude-plugin/plugin.json")" \
    --rawfile script "$register_tmp/script.b64" --rawfile helper "$register_tmp/helper.b64" '
    {name:$name,before:$before,bundle:$bundle,version:$version,
      files:{"plugins-windows.ps1":($script | rtrimstr("\n")),"codex-plugin-hooks.mjs":($helper | rtrimstr("\n"))}}')
  rm -rf "$register_tmp"
  register_result=$(fleet_schedule_windows_call \
    "$(fleet_schedule_windows_request "$register_sibling" register "$register_fields")" 2>&1) || {
    printf 'roundhouse: native Windows: %s was not registered: %s\n' "$fleet_schedule_windows_currency" \
      "$(printf '%s\n' "$register_result" | head -n 1)" >&2
    return 0
  }
  printf '%s\n' "$register_result" | jq -r --arg name "$fleet_schedule_windows_currency" '
    if .state != "completed" then
      "roundhouse: native Windows: \($name) was not registered: \(.message)"
    elif .outcome == "registered" then
      "roundhouse: native Windows: registered \($name), which keeps this user'"'"'s plugins current every 20 minutes"
    elif .outcome == "refused" then
      "roundhouse: native Windows: \($name) was not registered: \(.message). Registering it needs the user'"'"'s own desktop session: run `roundhouse fleet-schedule install` from a WSL terminal there"
    else
      "roundhouse: native Windows: \($name) was not registered (\(.outcome)): \(.message)"
    end' >&2
}

fleet_schedule_windows_status() {
  # `fleet-schedule status`'s native lines, read-only. Returns 0 even when the
  # Windows side cannot be reached or is not configured: the reason is the
  # line.
  status_sibling=$(fleet_schedule_windows_sibling 2>&1) || {
    printf 'native Windows: Task Scheduler not inspected — %s\n' \
      "$(printf '%s\n' "$status_sibling" | head -n 1)"
    return 0
  }
  status_native=$(fleet_schedule_windows_inspect "$status_sibling" 2>&1) || {
    printf 'native Windows: Task Scheduler not inspected — %s\n' \
      "$(printf '%s\n' "$status_native" | head -n 1)"
    return 0
  }
  printf 'native Windows: %s — no fleet-run task, by design — roundhouse has no native runtime; the timers above are this machine'"'"'s one scheduled runner, and they converge this WSL side (native Windows changes only through the interop lane)\n' \
    "$(printf '%s\n' "$status_sibling" | jq -r '.machine')"
  printf '%s\n' "$status_native" | jq -r --arg bundle "$(fleet_schedule_windows_bundle)" \
    --arg currency "$fleet_schedule_windows_currency" '
    (.tasks[] |
    (if .last_run == "" then "never run" else "last run \(.last_run), result \(.last_result)" end) as $run |
    "native Windows: \(.path)\(.name) — " +
    (if .class == "privilege-lane" then
       "the privilege lane'"'"'s task (enroll-privilege-windows), not a schedule job; left alone"
     elif .class == "obsolete-oneshot" then
       "an obsolete one-shot release-gate task (no trigger, \($run)); `fleet-schedule install` removes it"
     elif .class == "plugin-currency" then
       "keeps this user'"'"'s plugins current every 20 minutes (\(.state), \($run)); " +
       (if .bundle == $bundle then "runs this version'"'"'s bundle"
        else "not this version'"'"'s definition; `fleet-schedule install` re-points it" end)
     else
       "not a task roundhouse recognises (\(.state), \($run)); reported, never changed"
     end)),
    (if any(.tasks[]; .class == "plugin-currency") | not then
       "native Windows: no \($currency) task; `fleet-schedule install` registers it" else empty end),
    (.currency // empty |
      "native Windows: plugin currency: " +
      (if .state == "running" then "running since \(.started_at)"
       else "last run \(.finished_at): \(.state) (\(.updated) updated, \(.held) held)" end) +
      (if .version == "" then "" else ", roundhouse \(.version)" end)),
    (.currency // empty | .messages[] | select(startswith("hold ")) |
      "native Windows: plugin currency: \(.)")'
}

fleet_schedule_windows_verify() {
  # fleet_schedule_windows_verify [install|uninstall] — after an install: 0
  # when no obsolete one-shot task is still registered and the plugin
  # currency task runs this version's bundle; after an uninstall: 0 when the
  # plugin currency task is gone. Else 75 with each one named. An inspection
  # that fails AFTER the plan reached Windows proves nothing, so it is 75
  # too, never a verified change.
  verify_action=${1:-install}
  verify_native=$(fleet_schedule_windows_sibling 2>/dev/null) &&
    verify_native=$(fleet_schedule_windows_inspect "$verify_native" 2>/dev/null) || {
    printf 'roundhouse: native Windows: could not inspect the Task Scheduler after the %s, so its native steps are unverified; re-run `roundhouse fleet-schedule %s`\n' \
      "$verify_action" "$verify_action" >&2
    return 75
  }
  verify_currency=$(printf '%s\n' "$verify_native" | jq -r --arg currency "$fleet_schedule_windows_currency" \
    'first(.tasks[] | select(.name == $currency and .path == "\\") | .bundle) // "absent"')
  if [ "$verify_action" = uninstall ]; then
    [ "$verify_currency" != absent ] || return 0
    printf 'roundhouse: native Windows: %s is still registered; from the user'"'"'s own desktop session run `Unregister-ScheduledTask -TaskName %s -TaskPath \\ -Confirm:$false`, or re-run `roundhouse fleet-schedule uninstall`\n' \
      "$fleet_schedule_windows_currency" "$fleet_schedule_windows_currency" >&2
    return 75
  fi
  verify_status=0
  [ "$verify_currency" = "$(fleet_schedule_windows_bundle)" ] || {
    printf 'roundhouse: native Windows: %s does not run this version'"'"'s plugin currency bundle, so native Windows plugins are not kept current; re-run `roundhouse fleet-schedule install` from a WSL terminal in the user'"'"'s own desktop session\n' \
      "$fleet_schedule_windows_currency" >&2
    verify_status=75
  }
  verify_left=$(printf '%s\n' "$verify_native" |
    jq -r '.tasks[] | select(.class == "obsolete-oneshot") | .name')
  [ -n "$verify_left" ] || return "$verify_status"
  printf '%s\n' "$verify_left" | while IFS= read -r verify_name; do
    printf 'roundhouse: native Windows: the obsolete one-shot task %s is still registered; from the user'"'"'s own desktop session run `Unregister-ScheduledTask -TaskName %s -TaskPath \\ -Confirm:$false`, or re-run `roundhouse fleet-schedule install`\n' \
      "$verify_name" "$verify_name" >&2
  done
  return 75
}
