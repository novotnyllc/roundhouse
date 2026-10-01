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
  )
fi
