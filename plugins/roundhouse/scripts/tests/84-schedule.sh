# roundhouse self-check — §6.1 scheduling: the stamp-and-kick trigger, the
# in-process re-loop, the push nudge as a trigger, and the per-host scheduled
# jobs (`fleet-schedule install|status|uninstall`).
#
# Every scheduler is a stub: launchctl, systemctl, uname and ssh below record
# what they were asked and keep their "state" in files under this section's
# root. Nothing here reads or changes real launchd/systemd state.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'schedule: §6.1 trigger, in-process loop, nudge, scheduled jobs\n'
  (
    set -eu
    sched_root="$tmp/schedule"
    sched_bin="$sched_root/bin"
    SCHED_STATE="$sched_root/state"
    SCHED_LOG="$sched_root/calls.log"
    mkdir -p "$sched_bin" "$SCHED_STATE"
    : >"$SCHED_LOG"
    export SCHED_STATE SCHED_LOG

    cat >"$sched_bin/uname" <<'STUB'
#!/bin/sh
# The platform under test, not the one running the suite.
printf '%s\n' "${SCHED_UNAME:-Darwin}"
STUB
    cat >"$sched_bin/launchctl" <<'STUB'
#!/bin/sh
# launchd, as files: loaded.<label>, disabled.<label>, and gui (the domain).
printf 'launchctl %s\n' "$*" >>"$SCHED_LOG"
verb=$1
shift
case $verb in
  print)
    case $1 in
      gui/*/*) [ -e "$SCHED_STATE/loaded.${1##*/}" ] || exit 113 ;;
      gui/*) [ -e "$SCHED_STATE/gui" ] || exit 113 ;;
      *) exit 64 ;;
    esac
    ;;
  print-disabled)
    [ -e "$SCHED_STATE/gui" ] || exit 113
    printf 'disabled services = {\n'
    for f in "$SCHED_STATE"/disabled.*; do
      [ -e "$f" ] || continue
      printf '\t"%s" => disabled\n' "${f##*/disabled.}"
    done
    printf '}\n'
    ;;
  kickstart)
    [ -e "$SCHED_STATE/gui" ] && [ -e "$SCHED_STATE/loaded.${1##*/}" ] || exit 113
    ;;
  bootstrap)
    [ -e "$SCHED_STATE/gui" ] || exit 125
    label=$(basename "$2" .plist)
    [ ! -e "$SCHED_STATE/disabled.$label" ] || exit 5
    [ -f "$2" ] || exit 2
    : >"$SCHED_STATE/loaded.$label"
    ;;
  bootout)
    case $1 in
      gui/*/*) label=${1##*/} ;;
      *) label=$(basename "$2" .plist) ;;
    esac
    [ -e "$SCHED_STATE/loaded.$label" ] || exit 3
    rm -f "$SCHED_STATE/loaded.$label"
    ;;
  enable) rm -f "$SCHED_STATE/disabled.${1##*/}" ;;
  disable) : >"$SCHED_STATE/disabled.${1##*/}" ;;
  *) exit 64 ;;
esac
STUB
    cat >"$sched_bin/systemctl" <<'STUB'
#!/bin/sh
# A systemd user manager, as files: usermgr, enabled.<unit>, active.<unit>.
printf 'systemctl %s\n' "$*" >>"$SCHED_LOG"
[ "${1:-}" = --user ] || exit 64
shift
[ -e "$SCHED_STATE/usermgr" ] || exit 1
case $1 in
  show-environment | daemon-reload) ;;
  is-enabled)
    if [ -e "$SCHED_STATE/enabled.$2" ]; then printf 'enabled\n'
    else printf 'disabled\n'; exit 1; fi
    ;;
  is-active)
    [ "$2" = --quiet ] && shift
    [ -e "$SCHED_STATE/active.$2" ] || exit 3
    ;;
  start) [ "$2" = --no-block ] || exit 64 ;;
  enable)
    [ "$2" = --now ] && shift
    : >"$SCHED_STATE/enabled.$2"
    : >"$SCHED_STATE/active.$2"
    ;;
  disable)
    [ "$2" = --now ] && shift
    rm -f "$SCHED_STATE/enabled.$2" "$SCHED_STATE/active.$2"
    ;;
  *) exit 64 ;;
esac
STUB
    cat >"$sched_bin/runner" <<'STUB'
#!/bin/sh
# Stands in for `roundhouse` in the nohup fallback: slow on purpose, so a
# trigger that waited for the pass would be measurably late.
sleep "${SCHED_RUNNER_SLEEP:-0}"
printf '%s\n' "$*" >>"$SCHED_STATE/runner"
STUB
    chmod +x "$sched_bin"/*

    PATH="$sched_bin:$fleet_fixture_path"
    ROUNDHOUSE_SELFTEST=1
    ROUNDHOUSE_FLEET_TRIGGER_RUNNER="$sched_bin/runner"
    ROUNDHOUSE_FLEET_STORE="$sched_root/store"
    HOME="$sched_root/home"
    XDG_CONFIG_HOME="$HOME/.config"
    export PATH ROUNDHOUSE_SELFTEST ROUNDHOUSE_FLEET_TRIGGER_RUNNER \
      ROUNDHOUSE_FLEET_STORE HOME XDG_CONFIG_HOME
    mkdir -p "$ROUNDHOUSE_FLEET_STORE" "$HOME/Library/LaunchAgents" \
      "$HOME/.local/bin"
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    sched_uid=$(id -u)

    sched_reset() {
      rm -rf "$SCHED_STATE"
      mkdir -p "$SCHED_STATE"
      : >"$SCHED_LOG"
      rm -f "$HOME"/Library/LaunchAgents/*.plist
      rm -rf "$XDG_CONFIG_HOME/systemd"
      rm -f "$(fleet_instance_path store.run)/schedule-installed" \
        "$(fleet_instance_path store.run)/schedule-alerted"
    }
    sched_wait_runner() {
      sched_waited=0
      while [ ! -s "$SCHED_STATE/runner" ] && [ "$sched_waited" -lt 50 ]; do
        sleep 0.1
        sched_waited=$((sched_waited + 1))
      done
      [ -s "$SCHED_STATE/runner" ]
    }

    # --- the trigger: stamp, then kick the scheduled job ---
    sched_reset
    : >"$SCHED_STATE/gui"
    : >"$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-fast.plist"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-fast"
    sched_before=$(fleet_trigger_stamp_state)
    sched_out=$("$cli" fleet-trigger --fast) || fail "fleet-trigger failed: $sched_out"
    [ "$(fleet_trigger_stamp_state)" != "$sched_before" ] ||
      fail "the trigger did not touch the dirty stamp"
    grep -Fqx "launchctl kickstart gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" \
      "$SCHED_LOG" || fail "the trigger did not kickstart the fast job: $(cat "$SCHED_LOG")"
    [ ! -e "$SCHED_STATE/runner" ] ||
      fail "the trigger ran a pass itself although the job could be kicked"
    # The stamp moves on every trigger, even inside one second.
    sched_before=$(fleet_trigger_stamp_state)
    "$cli" fleet-trigger --fast >/dev/null
    [ "$(fleet_trigger_stamp_state)" != "$sched_before" ] ||
      fail "two triggers in one second left the same stamp"
    # --full kicks the full job.
    : >"$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-full.plist"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-full"
    "$cli" fleet-trigger --full >/dev/null
    grep -Fqx "launchctl kickstart gui/$sched_uid/com.novotnyllc.roundhouse.fleet-full" \
      "$SCHED_LOG" || fail "fleet-trigger --full did not kick the full job"

    # No GUI domain (a Mac reached over SSH, nobody at the console): the
    # detached nohup fallback, and the trigger does not wait for it.
    rm -f "$SCHED_STATE/gui"
    : >"$SCHED_LOG"
    SCHED_RUNNER_SLEEP=3
    export SCHED_RUNNER_SLEEP
    sched_start=$(date +%s)
    sched_out=$("$cli" fleet-trigger --fast) || fail "the fallback trigger failed"
    [ $(($(date +%s) - sched_start)) -lt 3 ] ||
      fail "the fallback trigger waited for the pass instead of returning"
    case $sched_out in
      *'no GUI launchd domain'*'detached fleet-run --fast'*) ;;
      *) fail "the fallback did not say why it detached: $sched_out" ;;
    esac
    ! grep -q kickstart "$SCHED_LOG" || fail "the fallback kickstarted with no GUI domain"
    sched_wait_runner || fail "the nohup fallback never started a pass"
    [ "$(cat "$SCHED_STATE/runner")" = 'fleet-run --fast' ] ||
      fail "the nohup fallback ran something other than fleet-run --fast: $(cat "$SCHED_STATE/runner")"
    SCHED_RUNNER_SLEEP=0
    # Not installed at all: the same fallback, so a host without the jobs is
    # still nudgeable.
    sched_reset
    : >"$SCHED_STATE/gui"
    "$cli" fleet-trigger --fast >/dev/null
    sched_wait_runner || fail "a host with no scheduled job was not triggered"
    # An operator-disabled job is stamped and NOT started, by either path.
    sched_reset
    : >"$SCHED_STATE/gui"
    : >"$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-fast.plist"
    : >"$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-fast"
    sched_out=$("$cli" fleet-trigger --fast)
    case $sched_out in
      *'disabled by the operator'*) ;;
      *) fail "a disabled job was not reported as such: $sched_out" ;;
    esac
    ! grep -Eq 'kickstart|enable|bootstrap' "$SCHED_LOG" ||
      fail "the trigger started or re-enabled an operator-disabled job: $(cat "$SCHED_LOG")"
    sleep 0.3
    [ ! -e "$SCHED_STATE/runner" ] ||
      fail "the trigger ran a pass behind an operator-disabled job"

    # Linux: systemctl --user start --no-block, or the fallback.
    SCHED_UNAME=Linux
    export SCHED_UNAME
    sched_reset
    : >"$SCHED_STATE/usermgr"
    mkdir -p "$XDG_CONFIG_HOME/systemd/user"
    : >"$XDG_CONFIG_HOME/systemd/user/roundhouse-fleet-fast.timer"
    : >"$SCHED_STATE/enabled.roundhouse-fleet-fast.timer"
    "$cli" fleet-trigger --fast >/dev/null
    grep -Fqx 'systemctl --user start --no-block roundhouse-fleet-fast.service' \
      "$SCHED_LOG" || fail "the Linux trigger did not start the fast service without blocking"
    [ ! -e "$SCHED_STATE/runner" ] || fail "the Linux trigger ran a pass itself"
    rm -f "$SCHED_STATE/usermgr"
    "$cli" fleet-trigger --fast >/dev/null
    sched_wait_runner || fail "no user manager did not fall back to a detached pass"
    SCHED_UNAME=MINGW64_NT-10.0
    sched_status=0
    "$cli" fleet-trigger --fast >/dev/null 2>&1 || sched_status=$?
    [ "$sched_status" -eq 69 ] || fail "native Windows was not refused clearly ($sched_status)"
    SCHED_UNAME=Darwin
    sched_status=0
    "$cli" fleet-trigger --sideways >/dev/null 2>&1 || sched_status=$?
    [ "$sched_status" -eq 64 ] || fail "an unknown fleet-trigger option was accepted"

    # --- the push nudge sends the trigger and returns ---
    cat >"$sched_bin/ssh" <<'STUB'
#!/bin/sh
printf 'ssh %s\n' "$*" >>"$SCHED_LOG"
STUB
    chmod +x "$sched_bin/ssh"
    : >"$SCHED_LOG"
    sched_start=$(date +%s)
    fleet_run_nudge_peer wren || fail "the nudge reported failure for a reachable peer"
    [ $(($(date +%s) - sched_start)) -lt 3 ] || fail "the nudge did not return promptly"
    grep -q "rh-wren .*roundhouse fleet-trigger --fast" "$SCHED_LOG" ||
      fail "the nudge did not send fleet-trigger --fast: $(cat "$SCHED_LOG")"
    ! grep -q 'fleet-run' "$SCHED_LOG" || fail "the nudge ran the peer's pass in the channel"

    # --- the running pass re-loops in-process while the stamp moved ---
    (
      # The pass itself is stubbed: what is under test is the loop around it.
      fleet_vcs_store_ready() { return 0; }
      fleet_host_name() { printf 'vireo\n'; }
      sched_calls="$sched_root/pass-calls"
      fleet_run_pass() (
        printf '%s %s\n' "$run_mode" "$run_tmp" >>"$sched_calls"
        [ -d "$run_tmp" ] || exit 70
        sched_n=$(grep -c . "$sched_calls")
        # Triggers "arrive" during the first SCHED_TRIGGERS passes.
        [ "$sched_n" -gt "${SCHED_TRIGGERS:-0}" ] || fleet_trigger_stamp
        exit "${SCHED_PASS_STATUS:-0}"
      )
      for sched_case in '0 1' '1 2' '2 3' '9 4'; do
        : >"$sched_calls"
        SCHED_TRIGGERS=${sched_case% *}
        fleet_run_command --fast >/dev/null ||
          fail "the looping run failed with $SCHED_TRIGGERS mid-pass triggers"
        [ "$(grep -c . "$sched_calls")" -eq "${sched_case#* }" ] ||
          fail "$SCHED_TRIGGERS mid-pass triggers ran $(grep -c . "$sched_calls") passes, not ${sched_case#* }"
      done
      # A trigger re-runs a FULL pass as a fast one: "go look", not "redo the
      # marketplace refresh and package updates".
      : >"$sched_calls"
      SCHED_TRIGGERS=1
      fleet_run_command --full >/dev/null || fail "the looping full run failed"
      [ "$(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')" = 'full fast ' ] ||
        fail "an in-process re-run repeated the full pass: $(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')"
      : >"$sched_calls"
      SCHED_TRIGGERS=9
      fleet_run_command --fast >/dev/null
      # Each pass gets its own scratch directory, and the lock is released.
      [ "$(cut -d' ' -f2 "$sched_calls" | LC_ALL=C sort -u | grep -c .)" -eq 4 ] ||
        fail "the in-process passes shared one scratch directory"
      [ ! -e "$(fleet_lock_path)" ] || fail "the looping run left its lock behind"
      # The status is the last pass's.
      : >"$sched_calls"
      SCHED_TRIGGERS=0
      SCHED_PASS_STATUS=65
      sched_status=0
      fleet_run_command --fast >/dev/null 2>&1 || sched_status=$?
      [ "$sched_status" -eq 65 ] || fail "the loop swallowed the pass's exit status ($sched_status)"
    )

    # --- fleet-schedule on macOS: install, idempotence, status, uninstall ---
    SCHED_UNAME=Darwin
    sched_reset
    : >"$SCHED_STATE/gui"
    sched_fast="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-fast.plist"
    sched_full="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-full.plist"
    rm -f "$HOME/.local/bin/roundhouse"
    sched_status=0
    "$cli" fleet-schedule install >/dev/null 2>&1 || sched_status=$?
    [ "$sched_status" -eq 69 ] || fail "install without the launcher shim was not refused ($sched_status)"
    [ ! -e "$sched_fast" ] || fail "a refused install still wrote a job"
    printf '#!/bin/sh\n' >"$HOME/.local/bin/roundhouse"
    chmod +x "$HOME/.local/bin/roundhouse"
    sched_out=$("$cli" fleet-schedule install) || fail "fleet-schedule install failed: $sched_out"
    for sched_mode_interval in fast:1260 full:45540; do
      sched_mode=${sched_mode_interval%%:*}
      sched_plist="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-$sched_mode.plist"
      [ -f "$sched_plist" ] || fail "install wrote no fleet-$sched_mode LaunchAgent"
      grep -Fq "<string>com.novotnyllc.roundhouse.fleet-$sched_mode</string>" "$sched_plist" ||
        fail "the fleet-$sched_mode LaunchAgent carries the wrong label"
      grep -Fq "<integer>${sched_mode_interval#*:}</integer>" "$sched_plist" ||
        fail "the fleet-$sched_mode LaunchAgent has the wrong StartInterval"
      grep -Fq '<string>/bin/zsh</string>' "$sched_plist" &&
        grep -Fq '<string>-lc</string>' "$sched_plist" &&
        grep -Fq "<string>exec \"\$HOME/.local/bin/roundhouse\" fleet-run --$sched_mode</string>" \
          "$sched_plist" ||
        fail "the fleet-$sched_mode LaunchAgent does not run the shim through a zsh login shell"
      grep -Fq "<string>$HOME/Library/Logs/roundhouse-fleet-$sched_mode.log</string>" "$sched_plist" ||
        fail "the fleet-$sched_mode LaunchAgent does not log under ~/Library/Logs"
      grep -Fqx "launchctl bootstrap gui/$sched_uid $sched_plist" "$SCHED_LOG" ||
        fail "install did not load the fleet-$sched_mode job"
    done
    [ -f "$(fleet_instance_path store.run)/schedule-installed" ] ||
      fail "install left no host-local marker"
    case $sched_out in
      *'fleet-fast: written, loaded'*'fleet-full: written, loaded'*) ;;
      *) fail "install did not report what it did: $sched_out" ;;
    esac
    # Idempotent: a second install changes nothing and touches no job.
    : >"$SCHED_LOG"
    sched_out=$("$cli" fleet-schedule install 2>&1) || fail "a repeat install failed"
    case $sched_out in
      *'fleet-fast: unchanged'*'fleet-full: unchanged'*) ;;
      *) fail "a repeat install did not report the jobs unchanged: $sched_out" ;;
    esac
    ! grep -Eq 'launchctl (bootstrap|bootout|enable|disable|kickstart)' "$SCHED_LOG" ||
      fail "a repeat install reloaded an unchanged, loaded job: $(cat "$SCHED_LOG")"
    # A job a previous session installed, byte for byte the shape install
    # writes, is matched, not duplicated or rewritten.
    sched_saved=$(cat "$sched_fast")
    sched_reset
    : >"$SCHED_STATE/gui"
    printf '%s\n' "$sched_saved" >"$sched_fast"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-fast"
    sched_mtime=$(fleet_run_mtime "$sched_fast")
    sched_out=$("$cli" fleet-schedule install 2>&1) || fail "install over an existing job failed"
    case $sched_out in
      *'fleet-fast: unchanged'*) ;;
      *) fail "an existing identical job was not recognised: $sched_out" ;;
    esac
    ! grep -Fq "bootstrap gui/$sched_uid $sched_fast" "$SCHED_LOG" ||
      fail "install reloaded an existing identical job"
    [ "$(ls "$HOME/Library/LaunchAgents" | grep -c 'fleet-fast')" -eq 1 ] ||
      fail "install duplicated an existing job"
    # A job that DIFFERS is reported with its diff, then replaced and reloaded.
    sed 's/<integer>1260</<integer>600</' "$sched_fast" >"$sched_fast.edit"
    mv "$sched_fast.edit" "$sched_fast"
    : >"$SCHED_LOG"
    sched_out=$("$cli" fleet-schedule install 2>&1) || fail "install over a differing job failed"
    case $sched_out in
      *'differs from the definition fleet-schedule writes'*'-'*'600'*'+'*'1260'*) ;;
      *) fail "a differing job was replaced without reporting the difference: $sched_out" ;;
    esac
    grep -Fq '<integer>1260</integer>' "$sched_fast" || fail "the differing job was not replaced"
    grep -Fqx "launchctl bootout gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" "$SCHED_LOG" &&
      grep -Fqx "launchctl bootstrap gui/$sched_uid $sched_fast" "$SCHED_LOG" ||
      fail "a replaced, loaded job was not reloaded"
    # Absorb, never duplicate: the superseded entries go in the same step.
    : >"$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.autoupdate.plist"
    : >"$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist"
    "$cli" fleet-schedule install >/dev/null 2>&1 || fail "install with legacy entries failed"
    [ ! -e "$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.autoupdate.plist" ] &&
      [ ! -e "$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist" ] ||
      fail "install left a superseded scheduler entry beside the new pair"
    sched_out=$("$cli" fleet-schedule status) || fail "fleet-schedule status failed"
    case $sched_out in
      *'fleet-fast: installed, enabled, loaded, definition matches'*'fleet-full: installed, enabled, loaded, definition matches'*) ;;
      *) fail "status did not report two healthy jobs: $sched_out" ;;
    esac

    # --- a pass never re-enables an operator-disabled job; it alerts ---
    launchctl disable "gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast"
    launchctl bootout "gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: installed, disabled'*) ;;
      *) fail "status did not report an operator-disabled job" ;;
    esac
    : >"$SCHED_LOG"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    sched_alert=$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" \
      -name '*-schedule-disabled-fleet-fast.yaml' 2>/dev/null | head -1)
    [ -n "$sched_alert" ] || fail "a pass did not alert on an operator-disabled job"
    [ "$(yq -r '.kind' "$sched_alert")" = schedule-disabled ] ||
      fail "the disabled-job alert has the wrong kind"
    ! grep -Eq 'launchctl (enable|bootstrap|load|kickstart)' "$SCHED_LOG" ||
      fail "a pass re-enabled or started an operator-disabled job: $(cat "$SCHED_LOG")"
    [ -e "$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-fast" ] ||
      fail "the operator's disable did not survive a pass"
    rm -f "$sched_alert"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ -z "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" -name '*-schedule-disabled-*')" ] ||
      fail "a disabled job was alerted on again by the next pass"
    # Only the operator's explicit install enables it again.
    : >"$SCHED_LOG"
    sched_out=$("$cli" fleet-schedule install 2>&1) || fail "re-install after a disable failed"
    case $sched_out in *'fleet-fast: re-enabled'*) ;; *) fail "install did not re-enable: $sched_out" ;; esac
    grep -Fqx "launchctl enable gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" "$SCHED_LOG" ||
      fail "install did not enable the operator-disabled job"
    [ -e "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-fast" ] ||
      fail "install did not load the re-enabled job"
    # Missing, with evidence the host is scheduled: alerted. With none: silent.
    rm -f "$sched_full"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ -n "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" -name '*-schedule-missing-fleet-full.yaml')" ] ||
      fail "a pass did not alert on a missing job"
    [ -z "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" -name '*-schedule-*-fleet-fast.yaml')" ] ||
      fail "a pass alerted on a healthy job"
    # Uninstall removes both, unloads, and the marker goes with them.
    : >"$SCHED_LOG"
    "$cli" fleet-schedule uninstall >/dev/null || fail "fleet-schedule uninstall failed"
    [ ! -e "$sched_fast" ] && [ ! -e "$sched_full" ] || fail "uninstall left a job behind"
    grep -Fqx "launchctl bootout gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" "$SCHED_LOG" ||
      fail "uninstall did not unload the fast job"
    [ ! -e "$(fleet_instance_path store.run)/schedule-installed" ] ||
      fail "uninstall left the install marker"
    rm -rf "$ROUNDHOUSE_FLEET_STORE/alerts"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ ! -d "$ROUNDHOUSE_FLEET_STORE/alerts" ] ||
      fail "a host that is not scheduled raised a schedule alert"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: missing'*'fleet-full: missing'*) ;;
      *) fail "status did not report the uninstalled jobs missing" ;;
    esac
    # No GUI domain (install over SSH): the jobs are written to load at login.
    rm -f "$SCHED_STATE/gui"
    sched_status=0
    sched_out=$("$cli" fleet-schedule install 2>&1) || sched_status=$?
    [ "$sched_status" -eq 75 ] || fail "install with no GUI domain did not say so ($sched_status)"
    case $sched_out in *'loads at the next console login'*) ;; *) fail "install over SSH was not explained: $sched_out" ;; esac
    [ -f "$sched_fast" ] || fail "install with no GUI domain wrote no job"
    "$cli" fleet-schedule uninstall >/dev/null

    # --- fleet-schedule on Linux: systemd user service + timer pairs ---
    SCHED_UNAME=Linux
    sched_reset
    : >"$SCHED_STATE/usermgr"
    sched_units="$XDG_CONFIG_HOME/systemd/user"
    sched_out=$("$cli" fleet-schedule install 2>&1) || fail "the Linux install failed: $sched_out"
    for sched_mode in fast full; do
      [ -f "$sched_units/roundhouse-fleet-$sched_mode.service" ] &&
        [ -f "$sched_units/roundhouse-fleet-$sched_mode.timer" ] ||
        fail "the Linux install wrote no fleet-$sched_mode service/timer pair"
      grep -Eq "^ExecStart=/[^ ]+ -lc 'exec \"%h/.local/bin/roundhouse\" fleet-run --$sched_mode'\$" \
        "$sched_units/roundhouse-fleet-$sched_mode.service" ||
        fail "the fleet-$sched_mode service does not run the shim through a login shell"
      grep -Fqx 'Type=oneshot' "$sched_units/roundhouse-fleet-$sched_mode.service" ||
        fail "the fleet-$sched_mode service is not a oneshot"
      grep -Fqx 'Persistent=true' "$sched_units/roundhouse-fleet-$sched_mode.timer" ||
        fail "the fleet-$sched_mode timer does not catch up after sleep (Persistent=true)"
      grep -Eq '^OnCalendar=' "$sched_units/roundhouse-fleet-$sched_mode.timer" ||
        fail "the fleet-$sched_mode timer has no calendar cadence"
      grep -Fqx "systemctl --user enable --now roundhouse-fleet-$sched_mode.timer" "$SCHED_LOG" ||
        fail "the Linux install did not enable the fleet-$sched_mode timer"
    done
    grep -Fqx 'OnCalendar=*:0/21' "$sched_units/roundhouse-fleet-fast.timer" ||
      fail "the fast timer is not on the 21-minute cadence"
    grep -Fqx 'systemctl --user daemon-reload' "$SCHED_LOG" ||
      fail "the Linux install did not reload the user manager"
    : >"$SCHED_LOG"
    sched_out=$("$cli" fleet-schedule install 2>&1) || fail "a repeat Linux install failed"
    ! grep -Eq 'systemctl --user (enable|restart|start|daemon-reload)' "$SCHED_LOG" ||
      fail "a repeat Linux install touched unchanged, active timers: $(cat "$SCHED_LOG")"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: installed, enabled, loaded, definition matches'*) ;;
      *) fail "the Linux status did not report a healthy timer" ;;
    esac
    # The operator disables the timer; the pass alerts and leaves it disabled.
    systemctl --user disable --now roundhouse-fleet-fast.timer
    : >"$SCHED_LOG"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" wren 2>/dev/null
    [ -n "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/wren" -name '*-schedule-disabled-fleet-fast.yaml')" ] ||
      fail "a pass did not alert on an operator-disabled Linux timer"
    ! grep -Eq 'systemctl --user (enable|start|restart)' "$SCHED_LOG" ||
      fail "a pass re-enabled an operator-disabled timer: $(cat "$SCHED_LOG")"
    "$cli" fleet-schedule uninstall >/dev/null || fail "the Linux uninstall failed"
    [ ! -e "$sched_units/roundhouse-fleet-fast.timer" ] &&
      [ ! -e "$sched_units/roundhouse-fleet-full.service" ] ||
      fail "the Linux uninstall left a unit behind"
    # No user manager (WSL without systemd): written, and the fix is named.
    rm -f "$SCHED_STATE/usermgr"
    sched_status=0
    sched_out=$("$cli" fleet-schedule install 2>&1) || sched_status=$?
    [ "$sched_status" -eq 75 ] || fail "install with no user manager did not say so ($sched_status)"
    case $sched_out in *'enable-linger'*) ;; *) fail "install with no user manager named no fix: $sched_out" ;; esac
    "$cli" fleet-schedule uninstall >/dev/null

    # Native Windows is out of scope, and says so; bad arguments never reach a job.
    SCHED_UNAME=MINGW64_NT-10.0
    sched_status=0
    sched_out=$("$cli" fleet-schedule status 2>&1) || sched_status=$?
    [ "$sched_status" -eq 69 ] || fail "native Windows fleet-schedule was not refused ($sched_status)"
    case $sched_out in *'native Windows'*) ;; *) fail "the Windows refusal did not say why: $sched_out" ;; esac
    SCHED_UNAME=Darwin
    for sched_bad in '' 'enable' 'install extra'; do
      sched_status=0
      # shellcheck disable=SC2086 # deliberate splitting of the argument list
      "$cli" fleet-schedule $sched_bad >/dev/null 2>&1 || sched_status=$?
      [ "$sched_status" -eq 64 ] || fail "fleet-schedule accepted '$sched_bad' ($sched_status)"
    done
  )
fi
