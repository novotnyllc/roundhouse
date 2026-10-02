# roundhouse — the controller side of the local privilege lane.
#
# Every host is lane-capable by default: after one OS approval per host
# (`roundhouse privilege-enroll HOST`), privileged package work reaches the
# host's root/SYSTEM side through an owner-only queue over the host's
# ordinary transport (local shell, SSH as the user, or SSH into the WSL
# sibling for native Windows). No CA, no certificates, no dedicated request
# account. Design: docs/specs/2026-10-01-hands-off-privilege-lane.md.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

lane_windows_script='C:\ProgramData\Roundhouse-Lane\privilege-lane-windows.ps1'
lane_windows_relative=ProgramData/Roundhouse-Lane/privilege-lane-windows.ps1

lane_actions_for_platform() {
  # The actions a sealed lane plan may carry. The helpers also implement
  # `macos.install-signed-pkg.v1` and `lane.self-upgrade.v1`, but both need
  # a payload digest the sealed format does not bind yet, so the controller
  # does not advertise them (docs/specs/…hands-off-privilege-lane.md,
  # "Deferred").
  case $1 in
    linux | wsl) printf '%s\n' apt.update-metadata.v1 apt.upgrade-package.v1 \
      apt.install-package-version.v1 apt.autoremove.v1 lane.probe.v1 ;;
    macos) printf '%s\n' lane.probe.v1 ;;
    windows) printf '%s\n' winget.inventory-machine.v1 winget.install-machine-package.v1 \
      winget.upgrade-machine-package.v1 lane.probe.v1 ;;
    *) return 1 ;;
  esac
}
lane_platform_note() {
  # lane_platform_note PLATFORM -> why a machine has no lane.
  printf 'the machine is absent from inventory or on an unsupported platform'
}

# lane_host_local=true makes every lane function treat TARGET as this host's
# own helper, without consulting config.json: the scheduled run on a host
# seals and applies against itself. It is set in exactly one place,
# lane_host_apply, and only inside that function's subshell — that scoping
# is what keeps it from leaking into any other command. Never export it.
lane_host_local=false

# lane_route TARGET -> legacy | local | disabled | unsupported. The legacy
# CA/SFTP lane is selected only by an explicit `automation_transport`.
lane_route() {
  if [ "$lane_host_local" = true ]; then printf 'local\n'; return; fi
  jq -r --arg target "$1" '
    .machines[$target] as $m |
    if $m == null then "unsupported"
    elif ($m.privilege_broker.automation_transport // null) != null then "legacy"
    elif ($m.privilege_lane // "enabled") == "disabled" then "disabled"
    elif ($m.platform | IN("macos","linux","wsl","windows")) then "local"
    else "unsupported" end' "$(config_path)"
}

# lane_transport TARGET -> "local" | "ssh ALIAS" | "interop ALIAS" |
# "unavailable REASON". Windows is reachable only through its WSL sibling.
lane_transport() {
  if [ "$lane_host_local" = true ]; then printf 'local\n'; return; fi
  lane_platform=$(jq -r --arg target "$1" '.machines[$target].platform // empty' "$(config_path)")
  lane_kind=$(jq -r --arg target "$1" '.machines[$target].transport // empty' "$(config_path)")
  case $lane_platform:$lane_kind in
    windows:*)
      if lane_alias=$(wsl_interop_alias "$(config_path)" "$1"); then
        printf 'interop %s\n' "$lane_alias"
      else
        printf 'unavailable user_session_unavailable\n'
      fi
      ;;
    *:local) printf 'local\n' ;;
    *:ssh)
      lane_alias=$(fleet_ssh_destination "$1") || { printf 'unavailable invalid_ssh_alias\n'; return; }
      printf 'ssh %s\n' "$lane_alias"
      ;;
    *) printf 'unavailable unsupported_transport\n' ;;
  esac
}

# lane_remote_sh TRANSPORT SCRIPT: run SCRIPT with /bin/sh on the target.
# stdin and stdout pass through; the return status is the script's.
lane_remote_sh() {
  case $1 in
    local) sh -c "$2" ;;
    ssh\ * | interop\ *) ssh_run "${1#* }" "$2" ;;
    *) return 69 ;;
  esac
}

# The command the TARGET runs for one lane verb. POSIX hosts resolve the
# installed plugin's helper through the `roundhouse` launcher on their PATH;
# the local host uses this checkout's copy. Windows runs the SYSTEM-owned
# copy through pwsh from the WSL side and reports the one approval itself
# when that copy is absent.
lane_posix_helper_script() {
  # lane_posix_helper_script TRANSPORT -> shell text that sets $lane_helper.
  case $1 in
    local) printf 'lane_helper=%s\n' "$(lane_quote "$script_dir/privilege-lane-posix")" ;;
    *) printf '%s\n' 'lane_helper=$(roundhouse privilege-lane-path 2>/dev/null) || { printf "privilege-lane: roundhouse is not on the remote PATH\n" >&2; exit 69; }' ;;
  esac
}
lane_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# The WSL-side programs are CONSTANT one-line text (the same shape as interop_invoke):
# every value reaches them as a positional argument, never interpolated into
# program text, so nothing crosses the `$SHELL -lc` argument boundary except
# quoting the values themselves. Output goes through a file rather than a
# pipe so pwsh's exit status survives.
lane_windows_program='root=$1; pwsh=$2; script=$3; shift 3; if [ ! -f "$root/ProgramData/Roundhouse-Lane/privilege-lane-windows.ps1" ]; then if [ -e "$root/ProgramData/Roundhouse-Lane/lane.identity" ]; then printf "%s\n" "lane-status|1" "state|drifted" "platform|windows" "host-id|-" "owner-sid|-" "owner-name|-" "lane-version|-" "lane-sha256|-" "plugin-root|-" "interop-token|-" "detail|installed lane copy missing while the identity survives" "next-command|roundhouse privilege-enroll HOST" "end-status|"; exit 74; fi; printf "%s\n" "lane-status|1" "state|needs_one_time_approval" "platform|windows" "host-id|-" "owner-sid|-" "owner-name|-" "lane-version|-" "lane-sha256|-" "plugin-root|-" "interop-token|-" "detail|installed lane copy absent" "next-command|roundhouse privilege-enroll HOST" "end-status|"; exit 75; fi; [ -x "$pwsh" ] || { printf "privilege-lane: PowerShell 7 is not reachable through WSL interop\n" >&2; exit 69; }; cd "$root" || exit 69; out=$(mktemp "${TMPDIR:-/tmp}/roundhouse-lane.XXXXXX") || exit 69; "$pwsh" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" "$@" </dev/null >"$out"; rc=$?; tr -d "\r" <"$out"; rm -f "$out"; exit "$rc"'
lane_windows_enroll_program='root=$1; pwsh=$2; version=$3; host=$4; [ -x "$pwsh" ] || { printf "privilege-lane: PowerShell 7 is not reachable through WSL interop\n" >&2; exit 69; }; cd "$root" || exit 69; profile=$("$root/Windows/System32/cmd.exe" /c "echo %USERPROFILE%" 2>/dev/null | tr -d "\r"); case $profile in [A-Za-z]:\\*) ;; *) printf "privilege-lane: cannot resolve the Windows user profile through interop\n" >&2; exit 69 ;; esac; helper=; for cache in .claude .codex; do candidate="$profile\\$cache\\plugins\\cache\\novotnyllc\\roundhouse\\$version\\scripts\\privilege-lane-windows.ps1"; posix=$(printf "%s" "$candidate" | sed "s#^[A-Za-z]:#$root#; s#\\\\#/#g"); [ -f "$posix" ] && helper=$candidate && break; done; [ -n "$helper" ] || { printf "privilege-lane: roundhouse %s is not installed in a Windows plugin cache; install or update the Windows plugin first\n" "$version" >&2; exit 69; }; out=$(mktemp "${TMPDIR:-/tmp}/roundhouse-lane.XXXXXX") || exit 69; "$pwsh" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$helper" -Enroll -HostId "$host" </dev/null >"$out"; rc=$?; tr -d "\r" <"$out"; rm -f "$out"; exit "$rc"'
lane_windows_script_text() {
  # lane_windows_script_text PWSH-ARG...: the one-line remote command that
  # runs the constant program with the drive root, pwsh path, SYSTEM-owned
  # script path and the pwsh arguments as positionals.
  lane_wst_args=
  for lane_wst_arg in "$@"; do lane_wst_args="$lane_wst_args $(lane_quote "$lane_wst_arg")"; done
  printf 'sh -c %s roundhouse-lane %s %s %s%s\n' "$(lane_quote "$lane_windows_program")" \
    "$(lane_quote "$(interop_drive_root)")" "$(lane_quote "$(interop_pwsh_path)")" \
    "$(lane_quote "$lane_windows_script")" "$lane_wst_args"
}

# lane_status_raw TARGET OUTPUT: the host's own `lane-status|1` record into
# OUTPUT. Prints nothing; the return status is the host's.
lane_status_raw() {
  lane_target=$1
  lane_out=$2
  lane_tr=$(lane_transport "$lane_target")
  case $lane_tr in
    unavailable\ *)
      printf '%s\n' 'lane-status|1' "state|${lane_tr#* }" "platform|$(jq -r --arg t "$lane_target" '.machines[$t].platform' "$(config_path)")" \
        'host-id|-' 'owner-uid|-' 'owner-name|-' 'lane-version|-' 'lane-sha256|-' 'plugin-root|-' \
        "detail|$(lane_transport_detail "${lane_tr#* }")" 'next-command|-' 'end-status|' >"$lane_out"
      return 75
      ;;
    interop\ *) lane_script=$(lane_windows_script_text -Status) ;;
    *) lane_script="$(lane_posix_helper_script "$lane_tr"); exec \"\$lane_helper\" status" ;;
  esac
  lane_rc=0
  lane_remote_sh "$lane_tr" "$lane_script" </dev/null >"$lane_out" 2>"$lane_out.err" || lane_rc=$?
  if ! lane_record_valid "$lane_out" lane-status; then
    printf '%s\n' 'lane-status|1' 'state|unreachable' 'platform|-' 'host-id|-' 'owner-uid|-' 'owner-name|-' \
      'lane-version|-' 'lane-sha256|-' 'plugin-root|-' \
      "detail|$(tr '\n' ' ' <"$lane_out.err" | cut -c1-300 | tr -d '|')" 'next-command|-' 'end-status|' >"$lane_out"
    rm -f "$lane_out.err"
    return 70
  fi
  rm -f "$lane_out.err"
  return "$lane_rc"
}
lane_transport_detail() {
  case $1 in
    user_session_unavailable) printf 'native Windows is reachable only through a configured, reachable wsl_interop_via sibling with an active user session' ;;
    *) printf '%s' "$1" ;;
  esac
}
lane_record_valid() {
  # lane_record_valid FILE HEADER: printable ASCII, LF-terminated, bounded,
  # the expected header and an `end-…|` trailer.
  [ -s "$1" ] && [ "$(wc -c <"$1")" -le 16384 ] || return 1
  ! LC_ALL=C grep -q '[^ -~]' "$1" || return 1
  [ "$(sed -n 1p "$1")" = "$2|1" ] || return 1
  tail -n 1 "$1" | grep -Eq '^(end-[a-z-]+\||result-sha256\|(-|[0-9a-f]{64}))$'
}
lane_field() {
  # lane_field FILE NAME -> value of the first `NAME|value` line, or `-`.
  lane_value=$(awk -F '|' -v name="$2" '$1 == name { print substr($0, length(name) + 2); exit }' "$1")
  printf '%s\n' "${lane_value:--}"
}

# lane_status_command TARGET OUTPUT: JSON status for the controller and the
# skills. States: ready, needs_one_time_approval, canary_pending,
# user_session_unavailable, disabled, legacy, unsupported, drifted,
# unreachable.
lane_status_command() (
  target=$1
  output=$2
  require_jq
  [ "$lane_host_local" = true ] || validate_config_file
  route=$(lane_route "$target")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-lane-status.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  platform=-
  [ "$lane_host_local" = true ] || platform=$(jq -r --arg t "$target" '.machines[$t].platform // "-"' "$(config_path)")
  state=$route
  detail=-
  raw=$tmp/status
  : >"$raw"
  rc=0
  case $route in
    local)
      lane_status_raw "$target" "$raw" || rc=$?
      state=$(lane_field "$raw" state)
      detail=$(lane_field "$raw" detail)
      # The host's own report wins when config has no platform for it.
      [ "$platform" != - ] || platform=$(lane_field "$raw" platform)
      # An alias that resolves to a host enrolled under another name would
      # run the operation on that other host: drift, never ready.
      if [ "$(lane_field "$raw" host-id)" != - ] && [ "$(lane_field "$raw" host-id)" != "$target" ]; then
        state=drifted
        detail="the host is enrolled as $(lane_field "$raw" host-id), not $target; the transport resolves to another machine"
      fi
      if [ "$(lane_field "$raw" interop-token)" = elevated ]; then
        # Requests written under an elevated token are owned by
        # Administrators, not the user, and the SYSTEM side refuses them;
        # user-scope work would land in the wrong profile for the same
        # reason. The WSL session must be started from a limited shell.
        state=user_session_unavailable
        detail='the WSL interop token is elevated; start the WSL session from a non-elevated shell'
      fi
      ;;
    legacy) detail='an explicit privilege_broker.automation_transport route is configured; the local lane is not used' ;;
    disabled) detail='privilege_lane is disabled for this machine' ;;
    *) detail='the machine is absent from inventory or on an unsupported platform' ;;
  esac
  next=-
  case $state in
    needs_one_time_approval | drifted | canary_pending) next="roundhouse privilege-enroll $target" ;;
  esac
  jq -S -n --arg target "$target" --arg platform "$platform" --arg route "$route" \
    --arg transport "$(lane_transport "$target")" --arg state "$state" --arg detail "$detail" \
    --arg next "$next" --arg host_id "$(lane_field "$raw" host-id)" \
    --arg owner "$(lane_field "$raw" owner-uid)" --arg owner_sid "$(lane_field "$raw" owner-sid)" \
    --arg version "$(lane_field "$raw" lane-version)" --arg sha "$(lane_field "$raw" lane-sha256)" \
    --arg token "$(lane_field "$raw" interop-token)" \
    --arg actions "$(lane_actions_for_platform "$platform" 2>/dev/null | tr '\n' ' ')" '
    {schema:"roundhouse.privilege-lane-status",schema_version:1,target:$target,platform:$platform,
     route:$route,transport:$transport,state:$state,detail:$detail,next_command:$next,
     host_id:$host_id,owner:(if $owner_sid != "-" then $owner_sid else $owner end),
     lane_version:$version,lane_sha256:$sha,interop_token:$token,
     actions:($actions | split(" ") | map(select(length > 0)))}' >"$tmp/status.json"
  safe_output "$tmp/status.json" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
  case $state in
    ready) exit 0 ;;
    needs_one_time_approval | user_session_unavailable | disabled | legacy) exit 75 ;;
    unsupported) exit 69 ;;
    *) exit 74 ;;
  esac
)

# lane_readiness_snapshot TARGET OUTPUT: the lane's state as an inventory
# snapshot carrying one privilege_broker/readiness record, so
# `privilege-status` keeps its file format for lane hosts.
lane_readiness_snapshot() (
  target=$1
  output=$2
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-lane-readiness.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  lane_status_command "$target" "$tmp/status.json" >/dev/null 2>&1 || :
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -c --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "lane-$(date -u +%Y%m%dT%H%M%SZ)-$$" --arg observed "$observed" '
    . as $s |
    {schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$s.target,
     kind:"privilege_broker",id:"readiness",observed_at:$observed,
     status:(if $s.state == "ready" then "present" elif $s.state == "unreachable" then "unavailable" else "partial" end),
     confidence:"high",
     data:{lifecycle_status:$s.state,transport:"local-lane",platform_adapter:"local-privilege-lane-v1",
       broker_ready:($s.state == "ready"),action_context_ready:($s.state == "ready"),
       platform:$s.platform,route:$s.route,lane_version:$s.lane_version,lane_sha256:$s.lane_sha256,
       host_id:$s.host_id,owner:$s.owner,interop_token:$s.interop_token,actions:$s.actions,
       detail:$s.detail,next_command:$s.next_command},
     evidence:[{source:"privilege-lane",method:"status"}],errors:[]}' "$tmp/status.json" >"$tmp/readiness.jsonl"
  validate_file "$tmp/readiness.jsonl"
  safe_output "$tmp/readiness.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

# privilege_enroll_command TARGET: the one approval. Never asks for, relays or
# stores a password; without a terminal it reports the exact command instead.
privilege_enroll_command() (
  target=$1
  require_jq
  validate_config_file
  route=$(lane_route "$target")
  case $route in
    local) ;;
    legacy)
      printf 'roundhouse: %s configures the legacy privilege_broker.automation_transport route; remove it to use the hands-off lane\n' "$target" >&2
      exit 69
      ;;
    disabled) printf 'roundhouse: privilege_lane is disabled for %s\n' "$target" >&2; exit 69 ;;
    *) printf 'roundhouse: %s is not a lane-capable machine\n' "$target" >&2; exit 64 ;;
  esac
  tr=$(lane_transport "$target")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-lane-enroll.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  case $tr in
    unavailable\ *)
      lane_report_pending "$target" "${tr#* }" "$(lane_transport_detail "${tr#* }")"
      exit 75
      ;;
    interop\ *)
      # UAC consent is a GUI dialog on the console, so the controller may
      # trigger it without a terminal of its own.
      version=$(jq -r '.version' "$plugin_root/.codex-plugin/plugin.json")
      lane_remote_sh "$tr" "$(lane_windows_enroll_script "$target" "$version")" </dev/null >"$tmp/out" 2>"$tmp/err" || rc=$?
      lane_report_enrollment "$target" "$tmp/out" "$tmp/err" "${rc:-0}"
      ;;
    local)
      lane_enroll_identity_check "$target" "$tr" || exit $?
      if fleet_test_hook "${ROUNDHOUSE_LANE_ENROLL_COMMAND:-}"; then
        sh -c "$ROUNDHOUSE_LANE_ENROLL_COMMAND" "lane-enroll" "$target" >"$tmp/out" 2>"$tmp/err" || rc=$?
      elif [ -t 0 ] && [ -t 1 ]; then
        /usr/bin/sudo -p "Roundhouse one-time approval for $target (your sudo password): " \
          "$script_dir/privilege-lane-posix" enroll --host-id "$target" --owner "$(id -un)" \
          >"$tmp/out" 2>"$tmp/err" || rc=$?
      else
        lane_report_pending "$target" needs_one_time_approval \
          "run from a terminal: roundhouse privilege-enroll $target (one sudo password prompt)"
        exit 75
      fi
      lane_report_enrollment "$target" "$tmp/out" "$tmp/err" "${rc:-0}"
      ;;
    ssh\ *)
      alias=${tr#* }
      lane_enroll_identity_check "$target" "$tr" || exit $?
      if fleet_test_hook "${ROUNDHOUSE_LANE_ENROLL_COMMAND:-}"; then
        sh -c "$ROUNDHOUSE_LANE_ENROLL_COMMAND" "lane-enroll" "$target" >"$tmp/out" 2>"$tmp/err" || rc=$?
      elif [ -t 0 ] && [ -t 1 ]; then
        # The remote half is constant text run by the login shell, exactly
        # as ssh_run does it, so the launcher's ~/.local/bin is on PATH and
        # `roundhouse privilege-lane-path` resolves. -t forwards the
        # terminal for sudo's prompt, which sudo prints on the pty — that
        # is ssh's stdout — so the output is copied to stderr for the owner
        # and kept for the record; lane_report_enrollment cuts the record
        # out from its header line. $target matches ^[A-Za-z0-9._-]+$.
        lane_enroll_program="lane_helper=\$(roundhouse privilege-lane-path) || exit 69; sudo -p \"Roundhouse one-time approval for $target (your sudo password): \" \"\$lane_helper\" enroll --host-id $target --owner \"\$(id -un)\""
        ssh -t -o BatchMode=no -o RequestTTY=yes -o RemoteCommand=none -o ConnectTimeout=10 "$alias" \
          "if [ -z \"\${SHELL:-}\" ] || [ ! -x \"\$SHELL\" ]; then printf 'roundhouse: configured login shell is unavailable\\n' >&2; exit 69; fi; exec \"\$SHELL\" -lc '$lane_enroll_program'" \
          2>"$tmp/err" | tee "$tmp/out" >&2 && rc=${PIPESTATUS[0]} || rc=${PIPESTATUS[0]}
      else
        lane_report_pending "$target" needs_one_time_approval \
          "run from a terminal: roundhouse privilege-enroll $target (one sudo password prompt over ssh $alias)"
        exit 75
      fi
      lane_report_enrollment "$target" "$tmp/out" "$tmp/err" "${rc:-0}"
      ;;
  esac
)
lane_enroll_identity_check() {
  # lane_enroll_identity_check TARGET TRANSPORT: the host at the other end
  # of the transport must answer as the configured expected_hostname and
  # expected_user before anything is enrolled under TARGET's name. The
  # identity record is written from the controller's --host-id, so an alias
  # that lands on the wrong machine would otherwise enroll that machine as
  # TARGET and every later status check would agree with it. Status 0 when
  # the identity matches; otherwise the failed enrollment record and 65.
  lane_eic_expected_host=$(jq -r --arg t "$1" '.machines[$t].expected_hostname // empty' "$(config_path)")
  lane_eic_expected_user=$(jq -r --arg t "$1" '.machines[$t].expected_user // empty' "$(config_path)")
  lane_eic_reason=
  if [ -z "$lane_eic_expected_host" ] || [ -z "$lane_eic_expected_user" ]; then
    lane_eic_reason=identity_unverifiable
    lane_eic_detail="config.json has no expected_hostname/expected_user for $1; set both before enrolling"
  else
    lane_eic_answer=$(lane_remote_sh "$2" 'printf "%s\n%s\n" "$(hostname)" "$(id -un)"' </dev/null 2>/dev/null | tr -d '\r') || lane_eic_answer=
    lane_eic_host=$(sed -n 1p <<<"$lane_eic_answer")
    lane_eic_user=$(sed -n 2p <<<"$lane_eic_answer")
    if [ -z "$lane_eic_host" ] || [ -z "$lane_eic_user" ]; then
      lane_eic_reason=identity_unverifiable
      lane_eic_detail="$2 did not answer the identity probe"
    elif [ "$lane_eic_host" != "$lane_eic_expected_host" ] || [ "$lane_eic_user" != "$lane_eic_expected_user" ]; then
      lane_eic_reason=identity_mismatch
      lane_eic_detail="$2 answers as $lane_eic_user@$lane_eic_host; config expects $lane_eic_expected_user@$lane_eic_expected_host"
    fi
  fi
  [ -n "$lane_eic_reason" ] || return 0
  jq -S -n --arg target "$1" --arg reason "$lane_eic_reason" --arg detail "$lane_eic_detail" '
    {schema:"roundhouse.privilege-enrollment",schema_version:1,target:$target,state:"failed",
     reason:$reason,detail:$detail,next_command:"-",
     credential_handling:"never_requests_or_relays_a_password_or_administrator_credential"}'
  printf 'roundhouse: %s: enrollment refused: %s\n' "$1" "$lane_eic_detail" >&2
  return 65
}

lane_windows_enroll_script() {
  # lane_windows_enroll_script TARGET VERSION: the constant enrollment
  # program with the drive root, pwsh path, plugin version and host as
  # positionals. The helper it finds re-launches itself elevated (UAC).
  printf 'sh -c %s roundhouse-lane %s %s %s %s\n' "$(lane_quote "$lane_windows_enroll_program")" \
    "$(lane_quote "$(interop_drive_root)")" "$(lane_quote "$(interop_pwsh_path)")" \
    "$(lane_quote "$2")" "$(lane_quote "$1")"
}
lane_report_pending() {
  # lane_report_pending TARGET STATE DETAIL — the human-facing one-time step.
  jq -S -n --arg target "$1" --arg state "$2" --arg detail "$3" '
    {schema:"roundhouse.privilege-enrollment",schema_version:1,target:$target,state:$state,
     detail:$detail,next_command:("roundhouse privilege-enroll " + $target),
     credential_handling:"never_requests_or_relays_a_password_or_administrator_credential"}'
  printf 'roundhouse: %s: %s — %s\n' "$1" "$2" "$3" >&2
}
lane_report_enrollment() {
  # lane_report_enrollment TARGET OUT ERR RC: translate the host's
  # lane-enrollment record into the controller's JSON and exit status. A
  # forced pty (ssh -t) turns LF into CRLF and echoes the sudo prompt ahead
  # of the record, so the record is cut out from its header line first.
  tr -d '\r' <"$2" | sed -n '/^lane-enrollment|1$/,$p' >"$2.record"
  mv -f "$2.record" "$2"
  if lane_record_valid "$2" lane-enrollment; then
    state=$(lane_field "$2" state)
    reason=$(lane_field "$2" reason)
  else
    state=failed
    reason=$(tr '\n' ' ' <"$3" | cut -c1-300)
    [ -n "$reason" ] || reason="exit status $4"
  fi
  jq -S -n --arg target "$1" --arg state "$state" --arg reason "$reason" \
    --arg version "$(lane_field "$2" lane-version)" --arg sha "$(lane_field "$2" lane-sha256)" \
    --arg canary "$(lane_field "$2" canary)" '
    {schema:"roundhouse.privilege-enrollment",schema_version:1,target:$target,state:$state,
     reason:$reason,lane_version:$version,lane_sha256:$sha,canary:$canary,
     next_command:(if $state == "enrolled" then "-" else ("roundhouse privilege-enroll " + $target) end),
     credential_handling:"never_requests_or_relays_a_password_or_administrator_credential"}'
  case $state in
    enrolled) return 0 ;;
    needs_one_time_approval) return 75 ;;
    *) return 74 ;;
  esac
}

# lane_submit TARGET ACTION PACKAGE VERSION SOURCE PAYLOAD-SHA PLAN-ID PLAN-SHA INDEX OUTPUT [REQUEST-ID]
# One request through the host's lane; OUTPUT receives the host's
# `lane-result|1` record. The return status mirrors the result state:
# 0 completed, 65 rejected, 70 failed, 71 partial, 75 lane unavailable.
lane_submit() {
  submit_target=$1
  submit_output=${10}
  submit_id=${11:-}
  submit_id_posix=
  [ -z "$submit_id" ] || submit_id_posix=" --request-id $(lane_quote "$submit_id")"
  submit_tr=$(lane_transport "$submit_target")
  case $submit_tr in
    unavailable\ *)
      lane_unavailable_result "$submit_target" "$2" "$3" "$4" "$7" "$8" "$9" "lane_${submit_tr#* }" >"$submit_output"
      return 75
      ;;
    interop\ *)
      submit_script=$(lane_windows_script_text -Request -Action "$2" -Package "$3" -Version "$4" -Source "$5" \
        -PayloadSha256 "$6" -PlanId "$7" -PlanSha256 "$8" -OperationIndex "$9" ${submit_id:+-RequestId "$submit_id"})
      ;;
    *)
      submit_script="$(lane_posix_helper_script "$submit_tr"); exec \"\$lane_helper\" request $(lane_quote "$2") $(lane_quote "$3") $(lane_quote "$4") $(lane_quote "$5") $(lane_quote "$6") --plan-id $(lane_quote "$7") --plan-sha256 $(lane_quote "$8") --operation-index $(lane_quote "$9")$submit_id_posix"
      ;;
  esac
  submit_rc=0
  lane_remote_sh "$submit_tr" "$submit_script" </dev/null >"$submit_output" 2>"$submit_output.err" || submit_rc=$?
  if ! lane_record_valid "$submit_output" lane-result; then
    lane_unavailable_result "$submit_target" "$2" "$3" "$4" "$7" "$8" "$9" \
      "lane_unreachable:$(tr '\n' ' ' <"$submit_output.err" | cut -c1-200 | tr -d '|')" >"$submit_output"
    rm -f "$submit_output.err"
    return 75
  fi
  rm -f "$submit_output.err"
  case $(lane_field "$submit_output" state) in
    completed) return 0 ;;
    rejected) [ "$submit_rc" -eq 75 ] && return 75 || return 65 ;;
    partial) return 71 ;;
    *) return 70 ;;
  esac
}
lane_unavailable_result() {
  # lane_unavailable_result TARGET ACTION PACKAGE VERSION PLAN PLAN-SHA INDEX REASON
  printf '%s\n' 'lane-result|1' 'request-id|-' "host-id|$1" "plan-id|$5" "plan-sha256|$6" "operation-index|$7" \
    "action-id|$2" "package|$3" "version|$4" 'state|rejected' "reason|$8" 'native-exit|-' \
    'pre-state-sha256|-' 'post-state-sha256|-' "started-at|$(date -u +%s)" "finished-at|$(date -u +%s)" \
    'lane-version|-' 'lane-sha256|-' 'request-sha256|-' 'end-result|' 'result-sha256|-'
}

# lane_lookup TARGET REQUEST-ID OUTPUT: the published result for a request
# id, without resubmitting anything.
lane_lookup() {
  lookup_tr=$(lane_transport "$1")
  case $lookup_tr in
    unavailable\ *) return 75 ;;
    interop\ *) lookup_script=$(lane_windows_script_text -Lookup -RequestId "$2") ;;
    *) lookup_script="$(lane_posix_helper_script "$lookup_tr"); exec \"\$lane_helper\" result $(lane_quote "$2")" ;;
  esac
  lookup_rc=0
  lane_remote_sh "$lookup_tr" "$lookup_script" </dev/null >"$3" 2>/dev/null || lookup_rc=$?
  lane_record_valid "$3" lane-result || return 70
  return "$lookup_rc"
}

# lane_candidate TARGET MANAGER PACKAGE SOURCE -> "INSTALLED CANDIDATE" as the
# host's owner-side view reports it (`-` for unknown), through the lane helper.
lane_candidate() {
  lane_cand_tr=$(lane_transport "$1")
  case $2:$lane_cand_tr in
    *:unavailable\ *) return 75 ;;
    winget:interop\ *) lane_cand_script=$(lane_windows_script_text -Candidate -Package "$3" -Source "$4") ;;
    apt:local | apt:ssh\ *) lane_cand_script="$(lane_posix_helper_script "$lane_cand_tr"); exec \"\$lane_helper\" candidate $(lane_quote "$3")" ;;
    *) return 70 ;;
  esac
  lane_cand_out=$(mktemp "${TMPDIR:-/tmp}/roundhouse-lane-candidate.XXXXXX")
  lane_remote_sh "$lane_cand_tr" "$lane_cand_script" </dev/null >"$lane_cand_out" 2>/dev/null || :
  if ! lane_record_valid "$lane_cand_out" lane-candidate || [ "$(lane_field "$lane_cand_out" package)" != "$3" ]; then
    rm -f "$lane_cand_out"
    return 70
  fi
  printf '%s %s\n' "$(lane_field "$lane_cand_out" installed)" "$(lane_field "$lane_cand_out" candidate)"
  rm -f "$lane_cand_out"
}
# lane_fresh_snapshot TARGET PLAN-OR-DRAFT OUTPUT: the target's lane readiness
# record plus a fresh package record for every upgrade the plan names — the
# exact inputs the precondition digest is computed over, observed now.
lane_fresh_snapshot() {
  lane_fs_target=$1
  lane_fs_plan=$2
  lane_fs_out=$3
  lane_readiness_snapshot "$lane_fs_target" "$lane_fs_out" >/dev/null 2>&1 || return 70
  lane_fs_id=$(jq -r '.snapshot_id' "$lane_fs_out")
  lane_fs_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while IFS=$'\t' read -r lane_fs_action lane_fs_package lane_fs_source; do
    [ -n "$lane_fs_action" ] || continue
    case $lane_fs_action in
      apt.upgrade-package.v1) lane_fs_manager=apt ;;
      winget.upgrade-machine-package.v1) lane_fs_manager=winget ;;
      *) continue ;;
    esac
    lane_fs_versions=$(lane_candidate "$lane_fs_target" "$lane_fs_manager" "$lane_fs_package" "$lane_fs_source") || continue
    jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" --arg s "$lane_fs_id" \
      --arg host "$lane_fs_target" --arg at "$lane_fs_at" --arg manager "$lane_fs_manager" \
      --arg name "$lane_fs_package" --arg installed "${lane_fs_versions%% *}" --arg candidate "${lane_fs_versions##* }" '
      {schema:$schema,schema_version:$schema_version,snapshot_id:$s,host_id:$host,kind:"package",
       id:($manager + ":" + $name),observed_at:$at,status:"present",confidence:"high",
       data:{manager:$manager,name:$name,installed_version:(if $installed == "-" then null else $installed end),
         candidate_version:(if $candidate == "-" then null else $candidate end),
         update_available:($candidate != "-" and $candidate != $installed)},
       evidence:[{source:"privilege-lane",method:"candidate"}],errors:[]}' >>"$lane_fs_out"
  done <<EOF
$(jq -r '.operations[] | [.id, .package, .source] | @tsv' "$lane_fs_plan")
EOF
  validate_file "$lane_fs_out"
}

# --- sealed lane plans (schema 5) ---------------------------------------------
plan_is_lane() {
  # plan_is_lane FILE: a sealed lane plan (schema 5) or a lane draft. The one
  # test every plan verb dispatches on.
  jq -e '(.schema_version == 5 or (has("schema_version") | not)) and .lane == "local"' "$1" >/dev/null 2>&1
}
# A lane draft names the target, `lane: "local"`, and semantic operations
# with their package/version/source. Sealing binds every operation to a
# fresh request id, to the target's lane readiness record and, for
# upgrades, to the snapshot's candidate version; verification recomputes
# that binding from a fresh snapshot before submission.
lane_draft_valid() {
  jq -e '
    type == "object" and (keys | sort) == (["domain","lane","operations","target"] | sort) and
    .lane == "local" and .domain == "updates" and
    (.target | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.operations | type == "array" and length >= 1 and length <= 32) and
    ([.operations[] |
      type == "object" and (keys | sort) == (["id","kind","package","source","type","version"] | sort) and
      .type == "semantic-action" and .kind == "privileged_action" and
      (.id | type == "string" and test("^[a-z]+\\.[a-z0-9-]+\\.v[0-9]+$")) and
      (.package | type == "string" and (. == "-" or test("^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}(:[a-z0-9-]{1,16})?$"))) and
      (.version | type == "string" and (. == "-" or test("^[A-Za-z0-9][A-Za-z0-9.+:~_-]{0,127}$"))) and
      (.source == "-")
    ] | all)' "$1" >/dev/null 2>&1
}
lane_plan_precondition() {
  # lane_plan_precondition PLAN-OR-DRAFT SNAPSHOT -> digest over the target's
  # lane readiness record and the package records the operations depend on.
  jq -cS -n --slurpfile plan "$1" --slurpfile records "$2" '
    $plan[0] as $p |
    [$p.operations[] | select(.id | IN("apt.upgrade-package.v1","winget.upgrade-machine-package.v1")) |
      {manager:(if (.id | startswith("apt.")) then "apt" else "winget" end), package:.package}] as $deps |
    [$records[] | select(.host_id == $p.target) |
      if .kind == "privilege_broker" and .id == "readiness" then
        {kind,id,status,data:(.data | del(.detail,.next_command))}
      elif .kind == "package" and (. as $r | any($deps[]; ($r.id == (.manager + ":" + .package)))) then
        {kind,id,status,installed_version:.data.installed_version,candidate_version:.data.candidate_version}
      else empty end
    ] | sort_by(.kind,.id)' | sha256_stream
}
lane_snapshot_supports_draft() {
  # lane_snapshot_supports_draft DRAFT SNAPSHOT: the lane is ready on the
  # target and every upgrade names the candidate the snapshot observed.
  jq -e -n --slurpfile draft "$1" --slurpfile records "$2" '
    $draft[0] as $d |
    ([$records[] | select(.host_id == $d.target and .kind == "privilege_broker" and .id == "readiness" and
      .data.transport == "local-lane" and .data.lifecycle_status == "ready")] | length == 1) and
    ([$records[] | select(.host_id == $d.target and .kind == "privilege_broker" and .id == "readiness")][0].data.actions as $actions |
      [$d.operations[] | .id as $a | $actions | index($a) != null] | all) and
    ([$d.operations[] | select(.id | IN("apt.upgrade-package.v1","winget.upgrade-machine-package.v1")) |
      ((if (.id | startswith("apt.")) then "apt:" else "winget:" end) + .package) as $pid | .version as $v |
      any($records[]; .host_id == $d.target and .kind == "package" and .id == $pid and .data.candidate_version == $v)
    ] | all)' >/dev/null 2>&1
}
seal_lane_plan() (
  # seal_lane_plan DRAFT SNAPSHOT OUTPUT — a subshell body: it exits on
  # refusal, so callers (the CLI verb and lane_host_apply) get a status.
  draft=$1
  snapshot=$2
  output=$3
  lane_draft_valid "$draft" || { printf 'roundhouse: invalid lane plan draft\n' >&2; exit 64; }
  validate_file "$snapshot"
  target=$(jq -r '.target' "$draft")
  [ "$(lane_route "$target")" = local ] || { printf 'roundhouse: %s is not on the local privilege lane\n' "$target" >&2; exit 69; }
  # The platform the snapshot's readiness record observed, not a config guess.
  platform=$(jq -r --arg t "$target" 'select(.host_id == $t and .kind == "privilege_broker" and .id == "readiness") | .data.platform' "$snapshot" | head -n 1)
  while IFS= read -r action; do
    lane_actions_for_platform "$platform" | grep -Fqx "$action" || {
      printf 'roundhouse: %s is not a lane action on %s\n' "$action" "$platform" >&2
      exit 64
    }
  done <<EOF
$(jq -r '.operations[].id' "$draft")
EOF
  lane_snapshot_supports_draft "$draft" "$snapshot" || {
    printf 'roundhouse: the snapshot does not show a ready lane on %s with every candidate version present\n' "$target" >&2
    exit 65
  }
  work=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-lane-seal.XXXXXX")
  trap 'rm -rf "$work"' EXIT HUP INT TERM
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  expires=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
  : >"$work/ids"
  count=$(jq '.operations | length' "$draft")
  i=0
  while [ "$i" -lt "$count" ]; do
    printf 'request-%s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" >>"$work/ids"
    i=$((i + 1))
  done
  jq -S --arg created "$created" --arg expires "$expires" --arg precondition "$(lane_plan_precondition "$draft" "$snapshot")" \
    --rawfile ids "$work/ids" '
    ($ids | split("\n") | map(select(length > 0))) as $ids |
    {schema:"roundhouse.plan",schema_version:5,lane:"local",domain:.domain,target:.target,
     required_section:"packages",created_at:$created,expires_at:$expires,
     precondition:{algorithm:"sha256",value:$precondition},
     operations:[.operations | to_entries[] | .value + {request_id:$ids[.key]}]}' "$draft" >"$work/unsealed.json"
  digest=$(jq -cS 'del(.plan_id,.plan_digest)' "$work/unsealed.json" | sha256_stream)
  jq -S --arg id "plan-$(printf '%s' "$digest" | cut -c1-16)" --arg digest "$digest" \
    '. + {plan_id:$id,plan_digest:{algorithm:"sha256",value:$digest}}' "$work/unsealed.json" >"$work/plan.json"
  safe_output "$work/plan.json" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$work"
)
lane_plan_check() {
  # lane_plan_check PLAN: shape, integrity and freshness of a sealed lane
  # plan — what a submission requires.
  lane_plan_integrity_check "$1" || return $?
  [ "$(jq -r '.expires_at | fromdateiso8601' "$1")" -gt "$(date -u +%s)" ] || {
    printf 'roundhouse: lane plan has expired; seal a fresh one\n' >&2
    return 65
  }
}
lane_plan_integrity_check() {
  # lane_plan_integrity_check PLAN: shape and integrity only. A lookup reads
  # a published result and never resubmits, so an expired plan still names
  # the request ids whose outcomes the host keeps for seven days.
  jq -e '
    .schema == "roundhouse.plan" and .schema_version == 5 and .lane == "local" and
    (.plan_id | type == "string" and test("^plan-[0-9a-f]{16}$")) and
    (.plan_digest.algorithm == "sha256") and (.plan_digest.value | test("^[0-9a-f]{64}$")) and
    (.precondition.algorithm == "sha256") and (.precondition.value | test("^[0-9a-f]{64}$")) and
    (.expires_at | type == "string" and fromdateiso8601 > 0) and
    (.operations | type == "array" and length >= 1 and length <= 32) and
    ([.operations[] | .request_id | type == "string" and test("^request-[0-9a-f]{32}$")] | all) and
    ([.operations[].request_id] | unique | length) == (.operations | length)' "$1" >/dev/null 2>&1 || {
    printf 'roundhouse: not a sealed lane plan\n' >&2
    return 64
  }
  expected=$(jq -cS 'del(.plan_id,.plan_digest)' "$1" | sha256_stream)
  [ "$expected" = "$(jq -r '.plan_digest.value' "$1")" ] &&
    [ "$(jq -r '.plan_id' "$1")" = "plan-$(printf '%s' "$expected" | cut -c1-16)" ] || {
    printf 'roundhouse: lane plan integrity check failed\n' >&2
    return 65
  }
}
verify_lane_plan() {
  # verify_lane_plan PLAN SNAPSHOT: the fresh snapshot must reproduce the
  # sealed precondition digest exactly.
  lane_plan_check "$1" || return $?
  validate_file "$2"
  [ "$(lane_plan_precondition "$1" "$2")" = "$(jq -r '.precondition.value' "$1")" ] || {
    printf 'roundhouse: lane plan preconditions drifted; re-inventory and seal again\n' >&2
    return 65
  }
  printf 'roundhouse: lane plan %s preconditions verified\n' "$(jq -r '.plan_id' "$1")"
}
apply_lane_plan() (
  # apply_lane_plan PLAN PLAN-ID OUTPUT: submit every operation in order and
  # write one inventory `operation` record per submission. A subshell body:
  # it exits with the worst operation status.
  plan=$1
  confirmation=$2
  output=$3
  # The plan file is trusted input: it must be the caller's own 0600 file
  # (its digest is unkeyed, so a writable plan could be re-digested), and
  # the mutation config gate applies as on every other apply path. The
  # host-local path seals into its own 0600 temp file.
  # The host-local path seals into the run's own 0600 temp file on a host
  # that may carry no controller config.json at all; the gate is the
  # controller's.
  [ "$lane_host_local" = true ] || check_mutation_config
  check_private_owned_file "$plan" "lane apply plan"
  lane_plan_check "$plan" || exit $?
  [ "$confirmation" = "$(jq -r '.plan_id' "$plan")" ] || {
    printf 'roundhouse: apply confirmation must equal the sealed plan ID\n' >&2
    exit 64
  }
  target=$(jq -r '.target' "$plan")
  work=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-lane-apply.XXXXXX")
  trap 'rm -rf "$work"' EXIT HUP INT TERM
  # The whole sealed precondition — readiness AND every package the plan
  # depends on — observed again now, never a readiness-only shortcut.
  lane_fresh_snapshot "$target" "$plan" "$work/fresh.jsonl" >/dev/null 2>&1 || :
  [ -s "$work/fresh.jsonl" ] && [ "$(lane_plan_precondition "$plan" "$work/fresh.jsonl")" = "$(jq -r '.precondition.value' "$plan")" ] || {
    printf 'roundhouse: lane preconditions drifted since sealing (readiness or package versions); re-inventory and seal again\n' >&2
    exit 65
  }
  snapshot_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  run_id=$(jq -r '.plan_id' "$plan")
  plan_sha=$(jq -r '.plan_digest.value' "$plan")
  : >"$work/records.jsonl"
  worst=0
  index=0
  count=$(jq '.operations | length' "$plan")
  while [ "$index" -lt "$count" ]; do
    op=$(jq -c --argjson i "$index" '.operations[$i]' "$plan")
    action=$(printf '%s\n' "$op" | jq -r '.id')
    rc=0
    lane_submit "$target" "$action" "$(printf '%s\n' "$op" | jq -r '.package')" \
      "$(printf '%s\n' "$op" | jq -r '.version')" "$(printf '%s\n' "$op" | jq -r '.source')" - \
      "$run_id" "$plan_sha" "$index" "$work/result.$index" "$(printf '%s\n' "$op" | jq -r '.request_id')" || rc=$?
    state=$(lane_field "$work/result.$index" state)
    reason=$(lane_field "$work/result.$index" reason)
    case $state in
      completed) op_status=completed ;;
      partial) op_status=partial ;;
      rejected) op_status=blocked ;;
      *) op_status=failed ;;
    esac
    jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" --arg snapshot_id "$snapshot_id" \
      --arg host "$target" --arg action "$action" --arg observed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg run_id "$run_id" --arg state "$state" --arg reason "$reason" --arg op_status "$op_status" \
      --arg request "$(lane_field "$work/result.$index" request-id)" --argjson index "$index" \
      --rawfile record "$work/result.$index" --argjson rc "$rc" '
      {schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host,kind:"operation",
       id:("lane:" + ($index | tostring) + ":" + $action),observed_at:$observed,
       status:(if $state == "completed" then "present" elif $state == "partial" then "partial" else "unavailable" end),
       confidence:"high",
       data:{run_id:$run_id,host_id:$host,scope:["packages"],phase:"apply",operation_status:$op_status,
         transport:"local-lane",operation_index:$index,action_id:$action,request_id:$request,
         state:$state,reason:$reason,exit_status:$rc,
         result_record:($record | split("\n") | map(select(length > 0)))},
       evidence:[{source:"privilege-lane",method:"request"}],errors:[]}' >>"$work/records.jsonl"
    [ "$rc" -le "$worst" ] || worst=$rc
    # Stop at the first non-completed operation: later operations may depend
    # on it, and the caller recovers with lookup-privilege-result.
    [ "$rc" -eq 0 ] || break
    index=$((index + 1))
  done
  validate_file "$work/records.jsonl"
  safe_output "$work/records.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$work"
  exit "$worst"
)
lookup_lane_result() {
  # lookup_lane_result PLAN INDEX OUTPUT
  lane_plan_integrity_check "$1" || exit $?
  request=$(jq -r --argjson i "$2" '.operations[$i].request_id // empty' "$1")
  [ -n "$request" ] || { printf 'roundhouse: operation index %s is not in the plan\n' "$2" >&2; exit 64; }
  rc=0
  lane_lookup "$(jq -r '.target' "$1")" "$request" "$3" || rc=$?
  exit "$rc"
}

# --- fleet-run: the host-local path --------------------------------------------
# The scheduled run calls these on the host it runs on. When the lane is
# enrolled the work goes through it; otherwise the caller keeps its hold and
# the run raises the one-time-approval alert exactly once per host.
lane_local_state() {
  # lane_local_state -> ready | needs_one_time_approval | drifted |
  # unsupported | unreachable (the helper printed no state at all).
  lane_local_raw=$("$script_dir/privilege-lane-posix" status 2>/dev/null) || :
  lane_local_value=$(awk -F '|' '$1 == "state" { print $2; exit }' <<<"$lane_local_raw")
  printf '%s\n' "${lane_local_value:-unreachable}"
}
lane_host_apply() {
  # lane_host_apply HOST OPERATIONS-JSON — the scheduled run's only way to
  # reach its own lane: a sealed plan, verified and applied with the same
  # precondition rechecks the controller path uses. OPERATIONS-JSON is the
  # draft's operations array. Status 0 only when every operation completed;
  # the apply records are discarded (the lane's own journal is the record).
  # Seal from a fresh snapshot, then apply, which observes the whole
  # precondition again right before it submits (verify would only compare
  # the snapshot the plan was just sealed from with itself). Refusals keep
  # their stderr, and a non-completed operation prints the host's reason, so
  # an unattended log line says what happened.
  (
    lane_host_local=true
    lane_ha_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-lane-host.XXXXXX")
    trap 'rm -rf "$lane_ha_tmp"' EXIT HUP INT TERM
    jq -cn --arg host "$1" --argjson ops "$2" '{domain:"updates",target:$host,lane:"local",operations:$ops}' \
      >"$lane_ha_tmp/draft.json"
    lane_fresh_snapshot "$1" "$lane_ha_tmp/draft.json" "$lane_ha_tmp/snapshot.jsonl" >/dev/null 2>&1 ||
      { printf 'roundhouse: lane: this host did not answer a status probe\n' >&2; exit 70; }
    seal_lane_plan "$lane_ha_tmp/draft.json" "$lane_ha_tmp/snapshot.jsonl" "$lane_ha_tmp/plan.json" >/dev/null || exit 65
    chmod 600 "$lane_ha_tmp/plan.json"
    lane_ha_rc=0
    apply_lane_plan "$lane_ha_tmp/plan.json" "$(jq -r '.plan_id' "$lane_ha_tmp/plan.json")" "$lane_ha_tmp/apply.jsonl" >/dev/null || lane_ha_rc=$?
    [ "$lane_ha_rc" -eq 0 ] || [ ! -s "$lane_ha_tmp/apply.jsonl" ] ||
      jq -r 'select(.data.state != "completed") | "roundhouse: lane: \(.data.action_id) \(.data.state): \(.data.reason)"' \
        "$lane_ha_tmp/apply.jsonl" | head -n 1 >&2
    exit "$lane_ha_rc"
  )
}
lane_operation_json() {
  # lane_operation_json ACTION PACKAGE VERSION SOURCE -> one draft operation.
  jq -cn --arg id "$1" --arg package "${2:--}" --arg version "${3:--}" --arg source "${4:--}" \
    '{type:"semantic-action",kind:"privileged_action",id:$id,package:$package,version:$version,source:$source}'
}
lane_package_hold_detail() {
  # lane_package_hold_detail ITEM HOST MANAGER -> the alert text for a held
  # package: names the one-time approval only when apt is the manager that
  # would provide it and the lane is not ready; the ordinary "no manager"
  # text otherwise (an npm or Homebrew hold, or a package no manager on the
  # host resolves, is never an apt problem).
  if [ "${3:-none}" = apt ] && command -v apt-get >/dev/null 2>&1 && [ "$(lane_local_state)" != ready ]; then
    printf 'apt needs the local privilege lane for %s on %s: run `roundhouse privilege-enroll %s` once (a single sudo prompt); scheduled runs never prompt\n' \
      "$1" "$2" "$2"
  else
    printf 'no package manager on this host can provide %s\n' "$1"
  fi
}
fleet_readiness_lane_row() {
  # fleet_readiness_lane_row HOST — the `privilege-lane` readiness row. A
  # host that has not yet had its one approval is PENDING, not a finding:
  # ordinary work proceeds without it. An enrolled lane that is broken is a
  # finding.
  lane_row_route=$(lane_route "$1")
  case $lane_row_route in
    legacy) fleet_readiness_row "$1" privilege-lane ok 'legacy automation_transport route configured'; return 0 ;;
    disabled) fleet_readiness_row "$1" privilege-lane ok 'disabled by configuration'; return 0 ;;
    local) ;;
    *) fleet_readiness_row "$1" privilege-lane finding 'unsupported platform for the privilege lane'; return 0 ;;
  esac
  lane_row_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-lane-row.XXXXXX")
  lane_status_command "$1" "$lane_row_tmp" >/dev/null 2>&1 || :
  lane_row_state=$(jq -r '.state // "unreachable"' "$lane_row_tmp" 2>/dev/null || printf unreachable)
  lane_row_detail=$(jq -r '.detail // "-"' "$lane_row_tmp" 2>/dev/null || printf -- -)
  lane_row_version=$(jq -r '.lane_version // "-"' "$lane_row_tmp" 2>/dev/null || printf -- -)
  rm -f "$lane_row_tmp"
  case $lane_row_state in
    ready) fleet_readiness_row "$1" privilege-lane ok "enrolled, lane $lane_row_version" ;;
    needs_one_time_approval | canary_pending)
      printf 'PENDING  %-24s %-18s %s\n' "$1" privilege-lane \
        "$lane_row_state: run \`roundhouse privilege-enroll $1\` once" ;;
    user_session_unavailable | unreachable)
      # Neither is a finding: ordinary work proceeds without the lane, and an
      # unreachable probe (no roundhouse on the remote PATH yet, a sleeping
      # host) is what `tools`/`roundhouse` rows already report.
      printf 'PENDING  %-24s %-18s %s\n' "$1" privilege-lane \
        "$lane_row_state: $lane_row_detail" ;;
    *) fleet_readiness_row "$1" privilege-lane finding "$lane_row_state: $lane_row_detail" ;;
  esac
}
fleet_doctor_lane_row() {
  # fleet_doctor_lane_row — this host's lane, from its own status helper.
  lane_doctor_raw=$("$script_dir/privilege-lane-posix" status 2>/dev/null) || :
  lane_doctor_state=$(awk -F '|' '$1 == "state" { print $2; exit }' <<<"$lane_doctor_raw")
  lane_doctor_version=$(awk -F '|' '$1 == "lane-version" { print $2; exit }' <<<"$lane_doctor_raw")
  lane_doctor_sha=$(awk -F '|' '$1 == "lane-sha256" { print $2; exit }' <<<"$lane_doctor_raw")
  lane_doctor_detail=$(awk -F '|' '$1 == "detail" { print $2; exit }' <<<"$lane_doctor_raw")
  case ${lane_doctor_state:-unreachable} in
    ready) fleet_doctor_row ok privilege-lane "enrolled, lane $lane_doctor_version $(printf '%s' "$lane_doctor_sha" | cut -c1-12)" ;;
    needs_one_time_approval) fleet_doctor_row ok privilege-lane 'not enrolled; privileged package work holds until `roundhouse privilege-enroll` runs once' ;;
    unsupported) fleet_doctor_row ok privilege-lane 'not applicable on this platform' ;;
    unreachable) fleet_doctor_row finding privilege-lane 'the lane helper printed no status; the installed plugin is damaged' ;;
    *) fleet_doctor_row finding privilege-lane "${lane_doctor_state}: ${lane_doctor_detail:--}" ;;
  esac
}
lane_fleet_run_apt() {
  # lane_fleet_run_apt STORE HOST PACKAGE APT-NAME HOLD-DIR — the full
  # cadence's apt arm: refresh metadata once per pass, upgrade the package to
  # the candidate apt-cache reports, or hold with the one-time-approval
  # alert (raised once per pass, keyed so it clears after the approval).
  lane_fra_store=$1
  lane_fra_host=$2
  lane_fra_package=$3
  lane_fra_name=$4
  lane_fra_hold_dir=$5
  if [ "$(lane_local_state)" != ready ]; then
    printf '  hold  packages.%s — apt needs the local privilege lane; run: roundhouse privilege-enroll %s\n' \
      "$lane_fra_package" "$lane_fra_host"
    [ "${lane_fleet_apt_alerted:-false}" = true ] && return 0
    lane_fleet_apt_alerted=true
    lane_fleet_apt_alert privilege-lane-needs-one-time-approval \
      "$(lane_package_hold_detail "packages.$lane_fra_package" "$lane_fra_host" apt)"
    return 0
  fi
  # Metadata refresh once per pass, then the upgrade: each a sealed plan
  # against this host, verified and applied with the full precondition
  # recheck — never an ad-hoc request.
  # A refresh that did not complete holds every apt upgrade this pass: a
  # candidate read from a stale cache is not a candidate. The failure is
  # reported once, and the flag is set only by a completed refresh.
  if [ "${lane_fleet_apt_refresh_failed:-false}" = true ]; then
    printf '  hold  packages.%s — apt metadata refresh did not complete this pass\n' "$lane_fra_package"
    return 0
  fi
  lane_fra_err=$(mktemp "${TMPDIR:-/tmp}/roundhouse-lane-apt.XXXXXX")
  if [ "${lane_fleet_apt_refreshed:-false}" != true ]; then
    if lane_host_apply "$lane_fra_host" "[$(lane_operation_json apt.update-metadata.v1)]" </dev/null 2>"$lane_fra_err"; then
      lane_fleet_apt_refreshed=true
    else
      lane_fleet_apt_refresh_failed=true
      lane_fra_why=$(tr '\n' ' ' <"$lane_fra_err" | cut -c1-200)
      printf 'roundhouse: lane apt metadata refresh did not complete; apt upgrades hold this pass: %s\n' "$lane_fra_why" >&2
      printf '  hold  packages.%s — apt metadata refresh did not complete this pass\n' "$lane_fra_package"
      # An enrolled lane that cannot complete its work is a standing
      # condition the owner must see, not a line in a scheduled run's log.
      lane_fleet_apt_alert privilege-lane-apt-refresh-failed \
        "apt metadata refresh through the privilege lane did not complete on $lane_fra_host: ${lane_fra_why:-no reason reported}"
      rm -f "$lane_fra_err"
      return 0
    fi
  fi
  lane_fra_record=$("$script_dir/privilege-lane-posix" candidate "$lane_fra_name" 2>/dev/null) || { rm -f "$lane_fra_err"; return 0; }
  lane_fra_installed=$(awk -F '|' '$1 == "installed" { print $2; exit }' <<<"$lane_fra_record")
  lane_fra_candidate=$(awk -F '|' '$1 == "candidate" { print $2; exit }' <<<"$lane_fra_record")
  [ "$lane_fra_installed" != - ] && [ "$lane_fra_candidate" != - ] && [ "$lane_fra_installed" != "$lane_fra_candidate" ] || { rm -f "$lane_fra_err"; return 0; }
  if ! lane_host_apply "$lane_fra_host" "[$(lane_operation_json apt.upgrade-package.v1 "$lane_fra_name" "$lane_fra_candidate")]" </dev/null 2>"$lane_fra_err"; then
    lane_fra_why=$(tr '\n' ' ' <"$lane_fra_err" | cut -c1-200)
    printf 'roundhouse: lane apt upgrade of %s to %s did not complete: %s\n' "$lane_fra_name" "$lane_fra_candidate" "$lane_fra_why" >&2
    lane_fleet_apt_alert "privilege-lane-apt-upgrade-failed-$(printf '%s' "$lane_fra_package" | tr './' '--')" \
      "apt upgrade of $lane_fra_name to $lane_fra_candidate through the privilege lane did not complete on $lane_fra_host: ${lane_fra_why:-no reason reported}"
  fi
  rm -f "$lane_fra_err"
}
lane_fleet_apt_alert() {
  # lane_fleet_apt_alert SLUG DETAIL — a keyed `privilege-lane` alert for the
  # package lane_fleet_run_apt is working on, through the pass ledger when
  # there is one (so it clears on the first pass where the condition is
  # gone) and straight to the store otherwise.
  if [ -n "$lane_fra_hold_dir" ]; then
    fleet_alert_raise "$lane_fra_hold_dir/alert-ledger" "$lane_fra_store" "$lane_fra_host" privilege-lane \
      "$1" "$2" "packages.$lane_fra_package" || :
  else
    fleet_alert_write "$lane_fra_store" "$lane_fra_host" privilege-lane "$1" "$2" "packages.$lane_fra_package" || :
  fi
}
