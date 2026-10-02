# roundhouse self-check — §6.1 scheduling: the stamp-and-kick trigger, the
# in-process re-loop, and the per-host scheduled jobs
# (`fleet-schedule install|status|uninstall`). The push nudge's use of the
# trigger is asserted once, in tests/74-run.sh.
#
# Every scheduler is a stub: launchctl, systemctl, loginctl and uname below
# record what they were asked and keep their "state" in files under this
# section's root. Nothing here reads or changes real launchd/systemd state.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
#
# Three independent parts, each over the same stubs: the trigger and the
# run's loop (1), fleet-schedule on macOS (2), and on Linux, a spaced HOME and
# the refusals (3). No assertion reads a wall clock: the trigger's "returns
# without waiting" is checked by order, against a runner held on a file.
# roundhouse-test: parts=3
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'schedule: §6.1 trigger, in-process loop, scheduled jobs\n'
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
# Like the real one, `disable` does NOT unload a running job, and
# bootstrapping a job that is already loaded is an error.
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
    [ ! -e "$SCHED_STATE/loaded.$label" ] || exit 37
    [ -f "$2" ] || exit 2
    : >"$SCHED_STATE/loaded.$label"
    ;;
  bootout)
    # SCHED_BOOTOUT_FAIL: a scheduler that refuses to let go of a job.
    [ -z "${SCHED_BOOTOUT_FAIL:-}" ] || exit 5
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
# A systemd user manager, as files: usermgr, enabled.<unit>, active.<unit>,
# and — like the real one — the timers.target.wants link `enable` writes.
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
  start) [ "$2" = --no-block ] || exit 64 ;;
  enable)
    [ "$2" = --now ] && shift
    : >"$SCHED_STATE/enabled.$2"
    : >"$SCHED_STATE/active.$2"
    mkdir -p "$wants"
    ln -sf "../$2" "$wants/$2"
    ;;
  disable)
    # SCHED_DISABLE_FAIL: a manager that refuses to disable the timer.
    [ -z "${SCHED_DISABLE_FAIL:-}" ] || exit 1
    [ "$2" = --now ] && shift
    rm -f "$SCHED_STATE/enabled.$2" "$SCHED_STATE/active.$2" "$wants/$2"
    ;;
  *) exit 64 ;;
esac
STUB
    cat >"$sched_bin/loginctl" <<'STUB'
#!/bin/sh
printf 'loginctl %s\n' "$*" >>"$SCHED_LOG"
[ "$1" = show-user ] || exit 64
if [ -e "$SCHED_STATE/linger" ]; then printf 'yes\n'; else printf 'no\n'; fi
STUB
    cat >"$sched_bin/runner" <<'STUB'
#!/bin/sh
# Stands in for `roundhouse` in the detached fallback. With SCHED_RUNNER_HOLD
# set it does not finish until that file exists (bounded), so a trigger that
# waited for the pass is caught by ORDER — the pass's record is there before
# the trigger returns — not by a wall clock.
hold_n=0
while [ -n "${SCHED_RUNNER_HOLD:-}" ] && [ ! -e "$SCHED_RUNNER_HOLD" ] && [ "$hold_n" -lt 300 ]; do
  sleep 0.1
  hold_n=$((hold_n + 1))
done
printf '%s\n' "$*" >>"$SCHED_STATE/runner"
STUB
    chmod +x "$sched_bin"/*

    PATH="$sched_bin:$fleet_fixture_path"
    ROUNDHOUSE_SELFTEST=1
    # install and uninstall ride the sealed-plan pipeline, which plans for the
    # configured LOCAL machine whose expected hostname and user are this one.
    jq '.machines["test-apt"].expected_hostname = "another-fixture-host" |
      .machines["test-apt"].expected_user = "another-fixture-user"' \
      "$tmp/config.json" >"$sched_root/config.json"
    chmod 600 "$sched_root/config.json"
    ROUNDHOUSE_CONFIG="$sched_root/config.json"
    export ROUNDHOUSE_CONFIG
    ROUNDHOUSE_FLEET_TRIGGER_RUNNER="$sched_bin/runner"
    ROUNDHOUSE_FLEET_STORE="$sched_root/store"
    HOME="$sched_root/home"
    XDG_CONFIG_HOME="$HOME/.config"
    SCHED_UNAME=Darwin
    export PATH ROUNDHOUSE_SELFTEST ROUNDHOUSE_FLEET_TRIGGER_RUNNER \
      ROUNDHOUSE_FLEET_STORE HOME XDG_CONFIG_HOME SCHED_UNAME
    mkdir -p "$ROUNDHOUSE_FLEET_STORE" "$HOME/Library/LaunchAgents" \
      "$HOME/.local/bin"
    # The host's own name, so the jittered intervals are this fixture's.
    printf 'name: vireo\ndomain: fleet.example.invalid\n' >"$sched_root/identity.yaml"
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    sched_uid=$(id -u)
    sched_fast="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-fast.plist"
    sched_full="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-full.plist"
    sched_units="$XDG_CONFIG_HOME/systemd/user"

    # fleet-schedule as the CLI runs it — its own process, errexit live —
    # with the test's hooks: `fast` replaces only the seal and apply-plan's
    # transport with a direct execution of the drafted operation under the
    # shared shape check; `sealed` runs the real pipeline and keeps copies of
    # the draft, the planning snapshot and the sealed plan, running
    # $SCHED_AFTER_SEAL between the seal and the apply. SCHED_STORE_READY
    # stands in an enrolled store.
    #
    # The sealed pipeline costs seconds per run (the executor's integrity is
    # verified at the seal and again at apply), so most install and uninstall
    # BEHAVIOUR below runs `fast`: the real observation, planner, executor,
    # report and status verification. The pipeline itself runs end to end in
    # the "$cli" installs and uninstalls (first install, both uninstalls, the
    # Linux install, the spaced HOME) and in the `sealed` block.
    # shellcheck disable=SC2016 # the driver is a program, expanded by its own bash
    sched_driver='set -eu
ROUNDHOUSE_LIB_ONLY=1
. "$0"
[ -z "${SCHED_STORE_READY:-}" ] || fleet_vcs_store_ready() { return 0; }
case $1 in
  fast)
    local_plan_seal_apply() {
      schedule_operations_valid "$1" "$HOME"
      jq ".operations[0]" "$1" >"$3/operation.json"
      fleet_schedule_execute "$3/operation.json"
    }
    ;;
  sealed)
    eval "sched_seal_real() $(declare -f seal_plan_command | tail -n +2)"
    seal_plan_command() {
      cp "$1" "$SCHED_SEAL_DIR/draft.json"
      cp "$2" "$SCHED_SEAL_DIR/planning.jsonl"
      sched_seal_real "$@"
      cp "$3" "$SCHED_SEAL_DIR/plan.json"
      [ -z "${SCHED_AFTER_SEAL:-}" ] || eval "$SCHED_AFTER_SEAL"
    }
    ;;
esac
shift
fleet_schedule_command "$@"'
    sched_schedule() {
      bash -c "$sched_driver" "$cli" fast "$@"
    }
    sched_sealed() {
      bash -c "$sched_driver" "$cli" sealed "$@"
    }
    sched_reset() {
      rm -rf "$SCHED_STATE" "$sched_units"
      mkdir -p "$SCHED_STATE"
      : >"$SCHED_LOG"
      rm -f "$HOME"/Library/LaunchAgents/*
      rm -f "$(fleet_run_state_dir)"/schedule-*
    }
    sched_wait_runner() {
      sched_waited=0
      while [ ! -s "$SCHED_STATE/runner" ] && [ "$sched_waited" -lt 50 ]; do
        sleep 0.1
        sched_waited=$((sched_waited + 1))
      done
      [ -s "$SCHED_STATE/runner" ]
    }
    sched_no_runner() {
      sleep 0.3
      [ ! -e "$SCHED_STATE/runner" ]
    }

    if section_part 1; then
    # --- the trigger: stamp, then start the scheduled job ---
    sched_reset
    : >"$SCHED_STATE/gui"
    : >"$sched_fast"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-fast"
    sched_before=$(fleet_trigger_stamp_state)
    sched_out=$("$cli" fleet-trigger --fast) || fail "fleet-trigger failed: $sched_out"
    [ "$(fleet_trigger_stamp_state)" != "$sched_before" ] ||
      fail "the trigger did not touch the dirty stamp"
    grep -Fqx "launchctl kickstart gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" \
      "$SCHED_LOG" || fail "the trigger did not kickstart the fast job: $(cat "$SCHED_LOG")"
    sched_no_runner || fail "the trigger ran a pass itself although the job could be kicked"
    [ "$(fleet_schedule_last_state fast)" = loaded ] ||
      fail "the observed job state was not remembered"
    # The stamp moves on every trigger, even inside one second.
    sched_before=$(fleet_trigger_stamp_state)
    "$cli" fleet-trigger --fast >/dev/null
    [ "$(fleet_trigger_stamp_state)" != "$sched_before" ] ||
      fail "two triggers in one second left the same stamp"
    : >"$sched_full"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-full"
    "$cli" fleet-trigger --full >/dev/null
    grep -Fqx "launchctl kickstart gui/$sched_uid/com.novotnyllc.roundhouse.fleet-full" \
      "$SCHED_LOG" || fail "fleet-trigger --full did not kick the full job"
    # …and records the cadence it asked for, which outlives the next fast
    # trigger's stamp: a pass holding the lock re-runs as full (below).
    [ -e "$(fleet_trigger_full_path)" ] ||
      fail "fleet-trigger --full recorded no full request"
    "$cli" fleet-trigger --fast >/dev/null
    [ -e "$(fleet_trigger_full_path)" ] ||
      fail "a fast trigger after a full one dropped the full request"
    # A full trigger that starts nothing records no request: an operator stop
    # is final, so no later fast run turns into the stopped job's full pass.
    rm -f "$(fleet_trigger_full_path)" "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-full"
    : >"$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-full"
    "$cli" fleet-trigger --full >/dev/null
    [ ! -e "$(fleet_trigger_full_path)" ] ||
      fail "a full trigger for a stopped full job recorded a full request"
    rm -f "$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-full"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-full"

    # No GUI domain (a Mac over SSH, nobody at the console) and the job was
    # last SEEN loaded: the detached fallback, and the trigger does not wait.
    rm -f "$SCHED_STATE/gui"
    : >"$SCHED_LOG"
    SCHED_RUNNER_HOLD="$sched_root/runner-release"
    rm -f "$SCHED_RUNNER_HOLD"
    export SCHED_RUNNER_HOLD
    sched_out=$("$cli" fleet-trigger --fast) || fail "the fallback trigger failed"
    [ ! -e "$SCHED_STATE/runner" ] ||
      fail "the fallback trigger waited for the pass instead of returning"
    : >"$SCHED_RUNNER_HOLD"
    case $sched_out in
      *'scheduler is unreachable'*'detached fleet-run --fast'*) ;;
      *) fail "the fallback did not say why it detached: $sched_out" ;;
    esac
    ! grep -q kickstart "$SCHED_LOG" || fail "the fallback kickstarted with no GUI domain"
    sched_wait_runner || fail "the detached fallback never started a pass"
    [ "$(cat "$SCHED_STATE/runner")" = 'fleet-run --fast' ] ||
      fail "the fallback ran something other than fleet-run --fast: $(cat "$SCHED_STATE/runner")"
    unset SCHED_RUNNER_HOLD
    [ "$(fleet_schedule_last_state fast)" = loaded ] ||
      fail "an unreachable domain overwrote the remembered job state"
    # Never seen: nothing is known about the operator's intent, so nothing runs.
    rm -f "$SCHED_STATE/runner" "$(fleet_schedule_state_path fast)" \
      "$(fleet_schedule_state_path full)"
    "$cli" fleet-trigger --fast >/dev/null
    sched_no_runner || fail "a job never seen running was started blind"
    rm -f "$SCHED_STATE/runner"
    # Concurrent fast and full triggers each replace only their OWN job's
    # state, through their own temporary file: neither loses the other's.
    : >"$SCHED_STATE/gui"
    : >"$sched_full"
    : >"$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-full"
    for sched_i in 1 2 3 4 5 6 7 8; do
      fleet_schedule_job_state fast >/dev/null &
      fleet_schedule_job_state full >/dev/null &
    done
    wait
    [ "$(fleet_schedule_last_state fast)" = loaded ] &&
      [ "$(fleet_schedule_last_state full)" = disabled ] ||
      fail "concurrent fast and full probes lost a job's remembered state"
    [ -z "$(find "$(fleet_run_state_dir)" -name 'schedule-state*.next*')" ] ||
      fail "a state write left its temporary file behind"
    rm -f "$sched_full" "$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-full"
    rm -f "$SCHED_STATE/gui"
    # No job installed at all: stamped, nothing started.
    sched_reset
    : >"$SCHED_STATE/gui"
    case $("$cli" fleet-trigger --fast) in
      *'no fleet-fast job is installed'*'stamped, not started'*) ;;
      *) fail "a host with no job did not say it only stamped" ;;
    esac
    sched_no_runner || fail "a host with no scheduled job ran a pass"
    # An operator-disabled job is stamped and NOT started — and stays so over
    # SSH, where the disable can no longer be seen.
    sched_reset
    : >"$SCHED_STATE/gui"
    : >"$sched_fast"
    : >"$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-fast"
    case $("$cli" fleet-trigger --fast) in
      *'stopped by the operator'*) ;;
      *) fail "a disabled job was not reported as stopped" ;;
    esac
    rm -f "$SCHED_STATE/gui"
    "$cli" fleet-trigger --fast >/dev/null
    ! grep -Eq 'kickstart|enable|bootstrap' "$SCHED_LOG" ||
      fail "the trigger started or re-enabled an operator-disabled job: $(cat "$SCHED_LOG")"
    sched_no_runner || fail "the trigger ran a pass behind an operator-disabled job"
    # …and so is one the operator unloaded.
    sched_reset
    : >"$SCHED_STATE/gui"
    : >"$sched_fast"
    "$cli" fleet-trigger --fast >/dev/null
    ! grep -Eq 'kickstart|bootstrap' "$SCHED_LOG" || fail "the trigger loaded an unloaded job"
    sched_no_runner || fail "the trigger ran a pass behind an unloaded job"

    # Linux: systemctl --user start --no-block, or the fallback only when the
    # timer is known enabled.
    SCHED_UNAME=Linux
    sched_reset
    : >"$SCHED_STATE/usermgr"
    : >"$SCHED_STATE/linger"
    mkdir -p "$sched_units/timers.target.wants"
    : >"$sched_units/roundhouse-fleet-fast.timer"
    # A timer whose service is gone is a MISSING job: it fires into nothing.
    : >"$SCHED_STATE/enabled.roundhouse-fleet-fast.timer"
    : >"$SCHED_STATE/active.roundhouse-fleet-fast.timer"
    case $("$cli" fleet-trigger --fast) in
      *'no fleet-fast job is installed'*) ;;
      *) fail "a timer without its service was not treated as a missing job" ;;
    esac
    ! grep -q 'start --no-block' "$SCHED_LOG" || fail "the trigger started a job whose service is missing"
    : >"$sched_units/roundhouse-fleet-fast.service"
    : >"$SCHED_STATE/active.roundhouse-fleet-fast.timer"
    ln -s ../roundhouse-fleet-fast.timer "$sched_units/timers.target.wants/roundhouse-fleet-fast.timer"
    "$cli" fleet-trigger --fast >/dev/null
    grep -Fqx 'systemctl --user start --no-block roundhouse-fleet-fast.service' \
      "$SCHED_LOG" || fail "the Linux trigger did not start the fast service without blocking"
    sched_no_runner || fail "the Linux trigger ran a pass itself"
    # No lingering: a start from this session would die with it.
    rm -f "$SCHED_STATE/linger"
    "$cli" fleet-trigger --fast >/dev/null
    sched_wait_runner || fail "a non-lingering user manager did not fall back to a detached pass"
    # …but a timer the operator STOPPED (still enabled, inactive) is a stop,
    # lingering or not: stamp only.
    rm -f "$SCHED_STATE/runner" "$SCHED_STATE/active.roundhouse-fleet-fast.timer"
    "$cli" fleet-trigger --fast >/dev/null
    sched_no_runner || fail "a stopped timer without lingering still got a detached pass"
    : >"$SCHED_STATE/active.roundhouse-fleet-fast.timer"
    : >"$SCHED_STATE/linger"
    # No user manager: the wants link says enabled, so the fallback.
    rm -f "$SCHED_STATE/usermgr" "$SCHED_STATE/runner"
    "$cli" fleet-trigger --fast >/dev/null
    sched_wait_runner || fail "no user manager did not fall back for an enabled timer"
    # …and no link means the operator disabled it: stamp only.
    rm -f "$SCHED_STATE/runner" "$sched_units/timers.target.wants/roundhouse-fleet-fast.timer"
    "$cli" fleet-trigger --fast >/dev/null
    sched_no_runner || fail "a disabled timer (no wants link) was started by the fallback"
    SCHED_UNAME=MINGW64_NT-10.0
    sched_status=0
    "$cli" fleet-trigger --fast >/dev/null 2>&1 || sched_status=$?
    [ "$sched_status" -eq 69 ] || fail "native Windows was not refused clearly ($sched_status)"
    SCHED_UNAME=Darwin
    sched_status=0
    "$cli" fleet-trigger --sideways >/dev/null 2>&1 || sched_status=$?
    [ "$sched_status" -eq 64 ] || fail "an unknown fleet-trigger option was accepted"

    # --- the running pass re-loops in-process while the stamp moved ---
    (
      # The pass itself is stubbed: what is under test is the loop around it.
      # fleet_run_command and its loop depend on errexit, so they are run the
      # way the CLI runs them — never inside `|| …` (errexit_capture).
      fleet_vcs_store_ready() { return 0; }
      fleet_vcs_op_id() {
        printf 'op\n' >>"$sched_root/op-calls"
        printf 'op-fixture\n'
      }
      fleet_host_name() { printf 'vireo\n'; }
      sched_calls="$sched_root/pass-calls"
      sched_run() {
        # sched_run ARG... — fleet_run_command, its status in sched_status and
        # its output in $sched_root/run.out.
        errexit_capture sched_status fleet_run_command "$@" >"$sched_root/run.out" 2>&1
      }
      fleet_run_pass() (
        run_tmp=$1
        run_mode=$2
        printf '%s %s\n' "$run_mode" "$run_tmp" >>"$sched_calls"
        [ -d "$run_tmp" ] || exit 70
        # PER PASS: a fresh, empty alert ledger inside this pass's run_tmp,
        # whatever the previous pass wrote to its own.
        [ -f "$run_tmp/alert-ledger" ] && [ ! -s "$run_tmp/alert-ledger" ] || exit 71
        printf 'raised\tx\ty\n' >>"$run_tmp/alert-ledger"
        sched_n=$(grep -c . "$sched_calls")
        # Triggers "arrive" during the first SCHED_TRIGGERS passes.
        # A full one records its request before the stamp, as the trigger does.
        [ "$sched_n" -gt "${SCHED_TRIGGERS:-0}" ] || {
          [ -z "${SCHED_TRIGGER_FULL:-}" ] || fleet_trigger_request_full
          fleet_trigger_stamp
        }
        sched_status_var="SCHED_PASS_STATUS_$sched_n"
        exit "${!sched_status_var:-0}"
      )
      rm -f "$SCHED_STATE/runner"
      for sched_case in '0 1' '1 2' '2 3' '9 4'; do
        : >"$sched_calls"
        SCHED_TRIGGERS=${sched_case% *}
        sched_run --fast
        [ "$sched_status" -eq 0 ] ||
          fail "the looping run failed with $SCHED_TRIGGERS mid-pass triggers: $(cat "$sched_root/run.out")"
        [ "$(grep -c . "$sched_calls")" -eq "${sched_case#* }" ] ||
          fail "$SCHED_TRIGGERS mid-pass triggers ran $(grep -c . "$sched_calls") passes, not ${sched_case#* }"
      done
      # Each pass gets its own scratch directory, and the lock is released.
      [ "$(cut -d' ' -f2 "$sched_calls" | LC_ALL=C sort -u | grep -c .)" -eq 4 ] ||
        fail "the in-process passes shared one scratch directory"
      [ ! -e "$(fleet_lock_path)" ] || fail "the looping run left its lock behind"
      # A trigger that the in-process loop saw (or that the three-pass bound
      # deferred) starts no follow-up of its own.
      sched_no_runner || fail "a run whose triggers the loop already saw started a detached follow-up"
      # THE HANDOFF RACE: a trigger landing after the loop's last comparison
      # but before the lock is released. Its own run found the lock and
      # exited, and systemd queues no second start of an active oneshot, so
      # the run compares the stamp once more after releasing, takes the lock
      # back IN-PROCESS and converges again — never a detached pass, which
      # the scheduler would kill with the job's process group.
      eval "sched_lock_release_real() $(declare -f fleet_lock_release | tail -n +2)"
      SCHED_LATE_TRIGGERS=1
      fleet_lock_release() {
        if [ "$SCHED_LATE_TRIGGERS" -gt 0 ]; then
          SCHED_LATE_TRIGGERS=$((SCHED_LATE_TRIGGERS - 1))
          fleet_trigger_stamp
        fi
        sched_lock_release_real "$@"
      }
      : >"$sched_calls"
      SCHED_TRIGGERS=0
      sched_run --fast
      [ "$sched_status" -eq 0 ] || fail "the run with a late trigger failed: $(cat "$sched_root/run.out")"
      [ "$(grep -c . "$sched_calls")" -eq 2 ] ||
        fail "a trigger that landed as the lock was released was not converged in-process ($(grep -c . "$sched_calls") passes)"
      case $(cat "$sched_root/run.out") in
        *'released its lock; took it again and converging in-process'*) ;;
        *) fail "the run did not say it took the lock back for a late trigger: $(cat "$sched_root/run.out")" ;;
      esac
      [ ! -e "$(fleet_lock_path)" ] || fail "the handoff left its lock behind"
      sched_no_runner || fail "the handoff started a detached pass"
      # A late trigger every time is bounded: two handoffs, then the next
      # scheduled run.
      : >"$sched_calls"
      SCHED_LATE_TRIGGERS=9
      sched_run --fast
      [ "$sched_status" -eq 0 ] && [ "$(grep -c . "$sched_calls")" -eq 3 ] ||
        fail "a stream of late triggers was not bounded at two handoffs ($(grep -c . "$sched_calls") passes)"
      grep -q 'the next scheduled run picks them up' "$sched_root/run.out" ||
        fail "the bounded handoff did not say it stopped: $(cat "$sched_root/run.out")"
      # If another run holds the lock by then, IT sees the stamp: no pass here.
      eval "sched_lock_take_real() $(declare -f fleet_run_lock_take | tail -n +2)"
      SCHED_LOCK_TAKES=0
      fleet_run_lock_take() {
        SCHED_LOCK_TAKES=$((SCHED_LOCK_TAKES + 1))
        [ "$SCHED_LOCK_TAKES" -lt 2 ] || return 10
        sched_lock_take_real "$@"
      }
      : >"$sched_calls"
      SCHED_LATE_TRIGGERS=1
      sched_run --fast
      [ "$sched_status" -eq 0 ] && [ "$(grep -c . "$sched_calls")" -eq 1 ] ||
        fail "the handoff ran a pass although another run held the lock"
      grep -q 'the run that holds it now sees it' "$sched_root/run.out" ||
        fail "the handoff did not leave the trigger to the run that holds the lock: $(cat "$sched_root/run.out")"
      eval "fleet_run_lock_take() $(declare -f sched_lock_take_real | tail -n +2)"
      eval "fleet_lock_release() $(declare -f sched_lock_release_real | tail -n +2)"
      # A run whose lock is taken over mid-loop starts no further pass.
      eval "sched_lock_identity_real() $(declare -f fleet_lock_identity | tail -n +2)"
      fleet_lock_identity() { printf 'someone-else\n'; }
      : >"$sched_calls"
      SCHED_TRIGGERS=9
      sched_run --fast
      [ "$(grep -c . "$sched_calls")" -eq 1 ] ||
        fail "a run that lost its lock went on to another pass ($(grep -c . "$sched_calls") passes)"
      grep -q 'no longer this run' "$sched_root/run.out" ||
        fail "the loop did not say why it stopped: $(cat "$sched_root/run.out")"
      eval "fleet_lock_identity() $(declare -f sched_lock_identity_real | tail -n +2)"
      # (Its release refused the lock it no longer owns; clear it for the rest.)
      rm -rf "$(fleet_lock_path)"
      # PER RUN: one starting operation, the abort point for every pass.
      : >"$sched_root/op-calls"
      : >"$sched_calls"
      SCHED_TRIGGERS=9
      sched_run --fast
      [ "$sched_status" -eq 0 ] || fail "the four-pass run failed"
      [ "$(grep -c . "$sched_root/op-calls")" -eq 1 ] ||
        fail "a four-pass run captured $(grep -c . "$sched_root/op-calls") starting operations, not one"
      [ "$(cat "$(fleet_run_state_dir)/starting-operation")" = op-fixture ] ||
        fail "the run did not record its starting operation"
      # A trigger re-runs a FULL pass as a fast one: "go look", not "redo the
      # marketplace refresh and package updates".
      : >"$sched_calls"
      SCHED_TRIGGERS=1
      sched_run --full
      [ "$sched_status" -eq 0 ] || fail "the looping full run failed"
      [ "$(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')" = 'full fast ' ] ||
        fail "an in-process re-run repeated the full pass: $(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')"
      # …but a FULL trigger wins: `fleet-trigger --full` landing mid-pass
      # kicks a full job that finds the lock and exits, so the run holding
      # the lock re-runs full, and that consumes the request.
      : >"$SCHED_STATE/gui"
      : >"$sched_full"
      rm -f "$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-full"
      : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-full"
      : >"$sched_calls"
      SCHED_TRIGGERS=1
      SCHED_TRIGGER_FULL=1
      sched_run --fast
      unset SCHED_TRIGGER_FULL
      [ "$sched_status" -eq 0 ] || fail "the run with a mid-pass full trigger failed"
      [ "$(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')" = 'fast full ' ] ||
        fail "a mid-pass full trigger was consumed as fast: $(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')"
      [ ! -e "$(fleet_trigger_full_path)" ] ||
        fail "the full pass did not consume the full request"
      # A request still pending when a run begins (the fast job won the lock
      # race against the full job it kicked) makes that run's pass full.
      fleet_trigger_request_full
      : >"$sched_calls"
      SCHED_TRIGGERS=0
      sched_run --fast
      [ "$(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')" = 'full ' ] ||
        fail "a pending full request did not make the next pass full: $(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')"
      [ ! -e "$(fleet_trigger_full_path)" ] ||
        fail "a full pass left the request it satisfied behind"
      # …unless the operator stopped the full job since: the request is
      # dropped, and the fast job does not run the stopped job's full pass.
      fleet_trigger_request_full
      rm -f "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-full"
      : >"$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-full"
      : >"$sched_calls"
      sched_run --fast
      [ "$(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')" = 'fast ' ] ||
        fail "a pending request ran the full pass of a job the operator stopped: $(cut -d' ' -f1 "$sched_calls" | tr '\n' ' ')"
      [ ! -e "$(fleet_trigger_full_path)" ] ||
        fail "a request for a stopped full job was not dropped"
      # The run's status is the WORST pass's: a clean re-run does not launder
      # an earlier hold.
      : >"$sched_calls"
      SCHED_TRIGGERS=1
      SCHED_PASS_STATUS_1=65
      export SCHED_PASS_STATUS_1
      sched_run --fast
      [ "$sched_status" -eq 65 ] || fail "a later clean pass laundered an earlier hold ($sched_status)"
      unset SCHED_PASS_STATUS_1
      # Every pass runs under errexit: an unguarded failure ends the pass.
      fleet_run_pass() (
        false
        printf 'reached\n' >>"$sched_calls"
      )
      : >"$sched_calls"
      sched_run --fast
      [ "$sched_status" -ne 0 ] || fail "a pass whose command failed reported success"
      ! grep -q reached "$sched_calls" ||
        fail "a pass ran on past an unguarded failure (errexit was off)"
      # …and the loop REFUSES a caller that suppresses errexit, rather than
      # running every pass with it silently off.
      sched_status=0
      ( fleet_run_command --fast ) >"$sched_root/run.out" 2>&1 || sched_status=$?
      [ "$sched_status" -eq 70 ] &&
        grep -q 'ran where errexit is suppressed' "$sched_root/run.out" ||
        fail "the run loop accepted an errexit-suppressed caller ($sched_status): $(cat "$sched_root/run.out")"
      [ ! -e "$(fleet_lock_path)" ] || fail "the refused run left its lock behind"

      # A SIGNAL ENDS THE RUN. The pass below moves the stamp (as a trigger
      # would) and waits for a release file; the run is signalled mid-pass.
      # Whatever the signal shape, the run exits 128+N after that pass, never
      # starts another, and leaves no lock. (A handler that only cleaned up
      # and returned let the loop run a second pass with no lock at all.)
      # shellcheck disable=SC2016 # a program for the driver's own bash
      sched_signal_driver='set -eu
ROUNDHOUSE_LIB_ONLY=1
. "$0"
fleet_vcs_store_ready() { return 0; }
fleet_vcs_op_id() { printf "op\n"; }
fleet_host_name() { printf "vireo\n"; }
fleet_run_pass() (
  printf "pass\n" >>"$SCHED_SIG_DIR/calls"
  fleet_trigger_stamp
  : >"$SCHED_SIG_DIR/in-pass"
  sig_n=0
  while [ ! -e "$SCHED_SIG_DIR/release" ] && [ "$sig_n" -lt 100 ]; do
    sleep 0.1
    sig_n=$((sig_n + 1))
  done
)
fleet_run_command --fast'
      SCHED_SIG_DIR="$sched_root/signal"
      export SCHED_SIG_DIR
      for sched_signal in 'TERM pid 143' 'INT group 130'; do
        # shellcheck disable=SC2086 # deliberate: signal, shape, status
        set -- $sched_signal
        rm -rf "$SCHED_SIG_DIR" "$(fleet_lock_path)"
        mkdir -p "$SCHED_SIG_DIR"
        # Its own process group, with INT and TERM at their defaults (a
        # background job of a non-interactive shell starts with INT ignored).
        perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; setpgrp(0, 0); exec @ARGV or die' \
          bash -c "$sched_signal_driver" "$cli" >"$SCHED_SIG_DIR/out" 2>&1 &
        sched_signal_pid=$!
        sched_waited=0
        while [ ! -e "$SCHED_SIG_DIR/in-pass" ] && [ "$sched_waited" -lt 100 ]; do
          sleep 0.1
          sched_waited=$((sched_waited + 1))
        done
        [ -e "$SCHED_SIG_DIR/in-pass" ] || fail "the signal fixture's pass never started"
        if [ "$2" = group ]; then
          kill -"$1" -- "-$sched_signal_pid"
        else
          kill -"$1" "$sched_signal_pid"
        fi
        : >"$SCHED_SIG_DIR/release"
        sched_status=0
        wait "$sched_signal_pid" || sched_status=$?
        [ "$sched_status" -eq "$3" ] ||
          fail "a run signalled with SIG$1 ($2) exited $sched_status, not $3: $(cat "$SCHED_SIG_DIR/out")"
        [ "$(grep -c . "$SCHED_SIG_DIR/calls")" -eq 1 ] ||
          fail "a run signalled with SIG$1 ($2) went on to another pass"
        [ ! -e "$(fleet_lock_path)" ] ||
          fail "a run signalled with SIG$1 ($2) left its lock behind"
      done
    )

    fi

    if section_part 2; then
    # --- fleet-schedule on macOS: install, idempotence, status, uninstall ---
    SCHED_UNAME=Darwin
    sched_reset
    : >"$SCHED_STATE/gui"
    rm -f "$HOME/.local/bin/roundhouse"
    sched_status=0
    "$cli" fleet-schedule install >/dev/null 2>&1 || sched_status=$?
    [ "$sched_status" -eq 69 ] || fail "install without the launcher shim was not refused ($sched_status)"
    [ ! -e "$sched_fast" ] || fail "a refused install still wrote a job"
    printf '#!/bin/sh\n' >"$HOME/.local/bin/roundhouse"
    chmod +x "$HOME/.local/bin/roundhouse"
    sched_out=$("$cli" fleet-schedule install) || fail "fleet-schedule install failed: $sched_out"
    for sched_mode in fast full; do
      sched_plist="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-$sched_mode.plist"
      [ -f "$sched_plist" ] || fail "install wrote no fleet-$sched_mode LaunchAgent"
      grep -Fq "<string>com.novotnyllc.roundhouse.fleet-$sched_mode</string>" "$sched_plist" ||
        fail "the fleet-$sched_mode LaunchAgent carries the wrong label"
      # ONE cadence source: the run's own interval, jittered from the name.
      grep -Fq "<integer>$(fleet_run_interval_seconds '{}' vireo "$sched_mode")</integer>" \
        "$sched_plist" ||
        fail "the fleet-$sched_mode StartInterval is not the run's own jittered interval"
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
    [ "$(fleet_run_interval_seconds '{}' vireo fast)" != \
      "$(fleet_run_interval_seconds '{}' wren fast)" ] ||
      fail "two hosts drew the same scheduled interval"
    [ -f "$(fleet_schedule_marker)" ] || fail "install left no host-local marker"
    case $sched_out in
      *'fleet-fast: written, loaded'*'fleet-full: written, loaded'*) ;;
      *) fail "install did not report what it did: $sched_out" ;;
    esac
    # Idempotent: a second install changes nothing and touches no job.
    : >"$SCHED_LOG"
    sched_out=$(sched_schedule install 2>&1) || fail "a repeat install failed: $sched_out"
    case $sched_out in
      *'fleet-fast: unchanged'*'fleet-full: unchanged'*) ;;
      *) fail "a repeat install did not report the jobs unchanged: $sched_out" ;;
    esac
    ! grep -Eq 'launchctl (bootstrap|bootout|enable|disable|kickstart)' "$SCHED_LOG" ||
      fail "a repeat install reloaded an unchanged, loaded job: $(cat "$SCHED_LOG")"
    # --- install and uninstall ride the sealed-plan pipeline ---
    (
      SCHED_SEAL_DIR="$sched_root/sealed"
      export SCHED_SEAL_DIR
      rm -rf "$SCHED_SEAL_DIR"
      mkdir -p "$SCHED_SEAL_DIR"
      sched_seal_dir=$SCHED_SEAL_DIR
      # The sealed plan lists the exact files and commands, preconditioned on
      # the observed record, and is bound to the configured local target.
      rm -f "$sched_fast" "$sched_full" "$SCHED_STATE"/loaded.*
      sched_sealed install >/dev/null 2>&1 || fail "the sealed install failed"
      [ "$(jq -r '.operations[0].id' "$sched_seal_dir/plan.json")" = roundhouse:schedule ] &&
        [ "$(jq -c '.operations[0].argv' "$sched_seal_dir/plan.json")" = '["roundhouse","fleet-schedule","install"]' ] &&
        [ "$(jq -r '.target' "$sched_seal_dir/plan.json")" = test-host ] &&
        jq -e '.precondition_digest.value | test("^[0-9a-f]{64}$")' "$sched_seal_dir/plan.json" >/dev/null ||
        fail "install did not seal a roundhouse:schedule plan for the local target: $(jq -c . "$sched_seal_dir/plan.json")"
      for sched_mode in fast full; do
        sched_plist="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-$sched_mode.plist"
        jq -e --arg path "$sched_plist" --arg digest "$(sha256_file "$sched_plist")" '
          any(.operations[0].steps[]; .action == "write" and .path == $path and
            .digest == $digest and .before == null)' "$sched_seal_dir/plan.json" >/dev/null ||
          fail "the sealed plan does not name fleet-$sched_mode's file and its written digest"
        jq -e --arg plist "$sched_plist" --arg domain "gui/$sched_uid" '
          any(.operations[0].steps[]; .action == "run" and .required == true and
            .argv == ["launchctl","bootstrap",$domain,$plist])' "$sched_seal_dir/plan.json" >/dev/null ||
          fail "the sealed plan does not carry fleet-$sched_mode's exact bootstrap command"
      done
      jq -s -e '[.[] | select(.kind == "agent_artifact" and .id == "roundhouse:schedule") |
          .data.files[] | select(.digest == null)] | length == 2' "$sched_seal_dir/planning.jsonl" \
        >/dev/null || fail "the planning snapshot did not observe both definitions absent"
      # RECHECKED before mutating: a job edited after the seal refuses the
      # apply, and nothing the plan would have done happens.
      cp "$sched_fast" "$sched_root/fast.sealed"
      # Between the seal and the apply, the operator edits a definition.
      SCHED_AFTER_SEAL="printf '<!-- hand -->\\n' >>'$sched_fast'"
      export SCHED_AFTER_SEAL
      sed 's/<integer>[0-9]*</<integer>11</' "$sched_full" >"$sched_full.edit"
      mv "$sched_full.edit" "$sched_full"
      : >"$SCHED_LOG"
      sched_status=0
      sched_out=$(sched_sealed install 2>&1) || sched_status=$?
      [ "$sched_status" -ne 0 ] || fail "an install whose preconditions changed after sealing applied"
      case $sched_out in *'target state changed after planning'*) ;;
        *) fail "a changed precondition was not reported: $sched_out" ;; esac
      grep -Fq '<integer>11</integer>' "$sched_full" ||
        fail "an install refused at the recheck still replaced a definition"
      ! grep -Eq 'launchctl (bootout|bootstrap|enable)' "$SCHED_LOG" ||
        fail "an install refused at the recheck still ran a scheduler command: $(cat "$SCHED_LOG")"
      unset SCHED_AFTER_SEAL
      cp "$sched_root/fast.sealed" "$sched_fast"
      sched_sealed install >/dev/null 2>&1 || fail "the re-planned install failed"
      # The executor runs only what this host's jobs own, wherever the plan
      # came from: a foreign command or path refuses.
      for sched_bad_step in \
        '{"action":"run","mode":"fast","effect":"unload","required":true,"argv":["launchctl","bootout","gui/'"$sched_uid"'/com.apple.Finder"]}' \
        '{"action":"run","mode":"fast","effect":"disable-stop","required":true,"argv":["systemctl","--user","stop","dbus.service"]}' \
        '{"action":"run","mode":"fast","effect":"load","required":true,"argv":["launchctl","bootout","gui/'"$sched_uid"'/com.novotnyllc.roundhouse.fleet-fast"]}' \
        '{"action":"remove","mode":"fast","form":"plist","path":"'"$HOME"'/Library/LaunchAgents/com.apple.Finder.plist","before":"'"$(printf '%064d' 0)"'"}' \
        '{"action":"write","mode":"fast","form":"timer","path":"/etc/systemd/user/roundhouse-fleet-fast.timer","digest":"'"$(printf '%064d' 0)"'","before":null}'; do
        jq -n --argjson step "$sched_bad_step" '{type:"agent-update",kind:"agent_artifact",
          id:"roundhouse:schedule",argv:["roundhouse","fleet-schedule","install"],steps:[$step]}' \
          >"$sched_seal_dir/bad.json"
        sched_status=0
        fleet_schedule_execute "$sched_seal_dir/bad.json" >/dev/null 2>&1 || sched_status=$?
        [ "$sched_status" -eq 64 ] || fail "the executor ran a step this host's jobs do not own ($sched_status): $sched_bad_step"
      done
      # The plan contract itself refuses a definition path outside HOME.
      jq -n '{operations:[{type:"agent-update",kind:"agent_artifact",
        id:"roundhouse:schedule",argv:["roundhouse","fleet-schedule","install"],
        steps:[{action:"write",mode:"fast",form:"timer",
          path:"/etc/systemd/user/roundhouse-fleet-fast.timer",
          digest:("0" * 64),before:null}]}]}' >"$sched_seal_dir/outside.json"
      ! schedule_operations_valid "$sched_seal_dir/outside.json" "$HOME" ||
        fail "the plan contract accepted a definition path outside HOME"
      # status is read-only and unsealed: it needs no mutation configuration.
      ROUNDHOUSE_CONFIG="$sched_root/no-such-config.json" "$cli" fleet-schedule status >/dev/null ||
        fail "status required the sealed-plan configuration"
      sched_status=0
      ROUNDHOUSE_CONFIG="$sched_root/no-such-config.json" "$cli" fleet-schedule install \
        >/dev/null 2>&1 || sched_status=$?
      [ "$sched_status" -ne 0 ] || fail "install ran without a mutation configuration to seal against"
      # A mutation configuration others can write is refused BEFORE planning,
      # not noticed and ignored (the check's status used to be dropped).
      cp "$ROUNDHOUSE_CONFIG" "$sched_root/open-config.json"
      chmod 666 "$sched_root/open-config.json"
      sched_status=0
      sched_out=$(ROUNDHOUSE_CONFIG="$sched_root/open-config.json" "$cli" fleet-schedule install 2>&1) ||
        sched_status=$?
      [ "$sched_status" -eq 64 ] ||
        fail "install sealed against a group/world-writable configuration ($sched_status): $sched_out"
      case $sched_out in *'group/world writable'*) ;; *) fail "the writable configuration was not named: $sched_out" ;; esac
      rm -f "$sched_root/open-config.json"
    )
    : >"$SCHED_LOG"

    # A job a previous session installed, in the shape install writes, is
    # matched — not duplicated, rewritten or reloaded.
    sched_saved=$(cat "$sched_fast")
    sched_reset
    : >"$SCHED_STATE/gui"
    printf '%s\n' "$sched_saved" >"$sched_fast"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-fast"
    sched_out=$(sched_schedule install 2>&1) || fail "install over an existing job failed"
    case $sched_out in
      *'fleet-fast: unchanged'*) ;;
      *) fail "an existing identical job was not recognised: $sched_out" ;;
    esac
    ! grep -Fq "bootstrap gui/$sched_uid $sched_fast" "$SCHED_LOG" ||
      fail "install reloaded an existing identical job"
    [ "$(find "$HOME/Library/LaunchAgents" -name '*fleet-fast*' | grep -c .)" -eq 1 ] ||
      fail "install duplicated an existing job"
    # A job that DIFFERS is reported by path, with where the old one is kept,
    # then replaced and reloaded — and its CONTENT is never printed: a
    # hand-added environment variable in it may be a secret.
    sed 's/<integer>[0-9]*</<integer>7</; s#<key>RunAtLoad</key>#<key>EnvironmentVariables</key><dict><key>TOKEN</key><string>sched-secret-sentinel</string></dict><key>RunAtLoad</key>#' \
      "$sched_fast" >"$sched_fast.edit"
    mv "$sched_fast.edit" "$sched_fast"
    : >"$SCHED_LOG"
    sched_out=$(sched_schedule install 2>&1) || fail "install over a differing job failed"
    case $sched_out in
      *"$sched_fast differs from the definition fleet-schedule writes"*"$sched_fast.replaced"*) ;;
      *) fail "a differing job was replaced without reporting the difference: $sched_out" ;;
    esac
    case $sched_out in
      *sched-secret-sentinel* | *'<integer>7<'*)
        fail "install printed the content of a definition it replaced: $sched_out" ;;
    esac
    ! grep -Fq '<integer>7</integer>' "$sched_fast" || fail "the differing job was not replaced"
    grep -Fqx "launchctl bootout gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" "$SCHED_LOG" &&
      grep -Fqx "launchctl bootstrap gui/$sched_uid $sched_fast" "$SCHED_LOG" ||
      fail "a replaced, loaded job was not reloaded"
    grep -Fq '<integer>7</integer>' "$sched_fast.replaced" ||
      fail "the replaced definition was not kept as .replaced"
    # A backup that cannot be made is a replacement that does not happen: the
    # install fails and the operator's definition stays exactly as it was.
    rm -f "$sched_fast.replaced"
    mkdir "$sched_fast.replaced"
    sed 's/<integer>[0-9]*</<integer>9</' "$sched_fast" >"$sched_fast.edit"
    mv "$sched_fast.edit" "$sched_fast"
    sched_before=$(cat "$sched_fast")
    : >"$SCHED_LOG"
    sched_status=0
    sched_out=$(sched_schedule install 2>&1) || sched_status=$?
    [ "$sched_status" -ne 0 ] || fail "install replaced a definition it could not back up"
    case $sched_out in *'could not keep the previous definition'*) ;;
      *) fail "a failed backup was not reported: $sched_out" ;; esac
    [ "$(cat "$sched_fast")" = "$sched_before" ] ||
      fail "a definition whose backup failed was replaced anyway"
    ! grep -Eq "launchctl (bootout|bootstrap) gui/$sched_uid.*fleet-fast" "$SCHED_LOG" ||
      fail "a definition whose backup failed was reloaded: $(cat "$SCHED_LOG")"
    rm -rf "$sched_fast.replaced"

    # Absorb, never duplicate — but never retire a WORKING superseded job for
    # a pair with no enrolled store to converge.
    sched_reset
    : >"$SCHED_STATE/gui"
    sched_legacy="$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.autoupdate.plist"
    : >"$sched_legacy"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.autoupdate"
    sched_status=0
    sched_out=$(sched_schedule install 2>&1) || sched_status=$?
    [ "$sched_status" -eq 69 ] || fail "install retired a legacy job with no enrolled store ($sched_status)"
    case $sched_out in *'Nothing was changed'*) ;; *) fail "the legacy refusal did not say so: $sched_out" ;; esac
    [ -f "$sched_legacy" ] && [ -e "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.autoupdate" ] &&
      [ ! -e "$sched_fast" ] || fail "a refused install touched the legacy job or wrote new ones"
    : >"$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist"
    SCHED_STORE_READY=1 sched_schedule install >/dev/null 2>&1 ||
      fail "install with legacy entries failed"
    [ -f "$sched_fast" ] && [ -f "$sched_full" ] || fail "the absorbing install wrote no new pair"
    [ ! -e "$sched_legacy" ] && [ -f "$sched_legacy.absorbed" ] &&
      [ -f "$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist.absorbed" ] ||
      fail "the superseded entries were not kept as *.absorbed"
    [ ! -e "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.autoupdate" ] ||
      fail "the superseded job was left loaded beside the new pair"
    sched_new_at=$(grep -n "bootstrap gui/$sched_uid $sched_full" "$SCHED_LOG" | cut -d: -f1)
    sched_old_at=$(grep -n "bootout gui/$sched_uid/com.novotnyllc.roundhouse.autoupdate" "$SCHED_LOG" | cut -d: -f1)
    [ -n "$sched_new_at" ] && [ -n "$sched_old_at" ] && [ "$sched_new_at" -lt "$sched_old_at" ] ||
      fail "the superseded job was retired before the new pair was in place"
    sched_out=$("$cli" fleet-schedule status) || fail "fleet-schedule status failed"
    case $sched_out in
      *'fleet-fast: installed, enabled, loaded, definition matches'*'fleet-full: installed, enabled, loaded, definition matches'*) ;;
      *) fail "status did not report two healthy jobs: $sched_out" ;;
    esac
    # A superseded entry that cannot be kept as .absorbed is not retired: it
    # stays on disk and loaded, and the install fails.
    (
      : >"$sched_legacy"
      : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.autoupdate"
      chmod a-w "$HOME/Library/LaunchAgents"
      sched_status=0
      SCHED_STORE_READY=1 sched_schedule install >/dev/null 2>&1 || sched_status=$?
      chmod u+w "$HOME/Library/LaunchAgents"
      [ "$sched_status" -ne 0 ] || fail "install retired a superseded entry it could not keep"
      [ -f "$sched_legacy" ] &&
        [ -e "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.autoupdate" ] ||
        fail "a superseded entry whose rename failed was removed or unloaded"
      rm -f "$sched_legacy" "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.autoupdate"
    )

    # --- a pass never re-enables an operator-disabled job; it alerts ---
    # The stub, like launchd, keeps the job LOADED through the disable.
    launchctl disable "gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: installed, disabled'*) ;;
      *) fail "status did not report an operator-disabled job" ;;
    esac
    : >"$SCHED_LOG"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    sched_alert=$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" \
      -name 'schedule-disabled--fleet-fast.yaml' 2>/dev/null | head -1)
    [ -n "$sched_alert" ] || fail "a pass did not alert on an operator-disabled job"
    [ "$(yq -r '.kind' "$sched_alert")" = schedule-disabled ] ||
      fail "the disabled-job alert has the wrong kind"
    ! grep -Eq 'launchctl (enable|bootstrap|load|kickstart)' "$SCHED_LOG" ||
      fail "a pass re-enabled or started an operator-disabled job: $(cat "$SCHED_LOG")"
    [ -e "$SCHED_STATE/disabled.com.novotnyllc.roundhouse.fleet-fast" ] ||
      fail "the operator's disable did not survive a pass"
    # One keyed alert while it lasts: the next pass leaves it as it is.
    sched_before=$(cat "$sched_alert")
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ "$(cat "$sched_alert")" = "$sched_before" ] ||
      fail "a standing schedule-disabled alert was rewritten by the next pass"
    # Unreachable (over SSH) decides nothing: the alert stands.
    rm -f "$SCHED_STATE/gui"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ -f "$sched_alert" ] || fail "an unreachable scheduler cleared a standing alert"
    : >"$SCHED_STATE/gui"
    # Only the operator's explicit install enables it again — and a job still
    # loaded is re-probed after the enable, never bootstrapped twice.
    : >"$SCHED_LOG"
    sched_out=$(sched_schedule install 2>&1) ||
      fail "re-install of a disabled-but-loaded job failed: $sched_out"
    case $sched_out in *'fleet-fast: re-enabled'*) ;; *) fail "install did not re-enable: $sched_out" ;; esac
    grep -Fqx "launchctl enable gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" "$SCHED_LOG" ||
      fail "install did not enable the operator-disabled job"
    ! grep -Fq "bootstrap gui/$sched_uid $sched_fast" "$SCHED_LOG" ||
      fail "install bootstrapped a job that stayed loaded through its disable"
    # Disabled AND unloaded: enabled, then loaded.
    launchctl disable "gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast"
    launchctl bootout "gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast"
    : >"$SCHED_LOG"
    sched_schedule install >/dev/null 2>&1 || fail "re-install after disable and unload failed"
    grep -Fqx "launchctl bootstrap gui/$sched_uid $sched_fast" "$SCHED_LOG" ||
      fail "install did not load the re-enabled, unloaded job"
    # The condition has ended: the next pass clears the alert.
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ ! -e "$sched_alert" ] || fail "a re-enabled job's schedule-disabled alert was not cleared"
    # Missing, with evidence the host is scheduled: alerted.
    rm -f "$sched_full"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ -n "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" -name 'schedule-missing--fleet-full.yaml')" ] ||
      fail "a pass did not alert on a missing job"
    [ -z "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" -name 'schedule-*--fleet-fast.yaml')" ] ||
      fail "a pass alerted on a healthy job"
    # An uninstall the scheduler refuses is not done: a job it still holds
    # keeps its definition, the host is not opted out, and the exit is not 0.
    sched_status=0
    sched_out=$(SCHED_BOOTOUT_FAIL=1 sched_schedule uninstall 2>&1) || sched_status=$?
    [ "$sched_status" -ne 0 ] || fail "uninstall reported success while launchd still held the job"
    [ -f "$sched_fast" ] && [ -e "$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-fast" ] ||
      fail "an uninstall whose unload failed still removed the definition: $sched_out"
    [ ! -e "$(fleet_schedule_optout_path)" ] ||
      fail "an uninstall whose unload failed still opted the host out"
    # Uninstall removes both, unloads, and opts the host out: from then on a
    # trigger only stamps and a pass raises nothing. A removed definition is
    # kept, as .removed.
    : >"$SCHED_LOG"
    "$cli" fleet-schedule uninstall >/dev/null || fail "fleet-schedule uninstall failed"
    [ ! -e "$sched_fast" ] && [ ! -e "$sched_full" ] || fail "uninstall left a job behind"
    [ -f "$sched_fast.removed" ] || fail "uninstall kept no .removed copy of the definition"
    rm -f "$sched_fast.removed"
    grep -Fqx "launchctl bootout gui/$sched_uid/com.novotnyllc.roundhouse.fleet-fast" "$SCHED_LOG" ||
      fail "uninstall did not unload the fast job"
    [ ! -e "$(fleet_schedule_marker)" ] || fail "uninstall left the install marker"
    [ -e "$(fleet_schedule_optout_path)" ] || fail "uninstall left no opt-out marker"
    : >"$sched_fast"
    : >"$SCHED_STATE/loaded.com.novotnyllc.roundhouse.fleet-fast"
    : >"$SCHED_LOG"
    case $("$cli" fleet-trigger --fast) in
      *'taken off the schedule'*) ;;
      *) fail "a trigger on an opted-out host did not say it only stamped" ;;
    esac
    ! grep -q kickstart "$SCHED_LOG" || fail "a trigger started a job on an opted-out host"
    rm -f "$sched_fast"
    [ -n "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" -name 'schedule-missing--fleet-full.yaml')" ] ||
      fail "the missing-job alert was gone before the opt-out probe"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" vireo 2>/dev/null
    [ -z "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/vireo" -name 'schedule-*')" ] ||
      fail "an opted-out host kept or raised a schedule alert"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: missing'*'fleet-full: missing'*'opted out'*) ;;
      *) fail "status did not report the uninstalled, opted-out jobs" ;;
    esac
    # No GUI domain (install over SSH): written to load at login; and install
    # lifts the opt-out.
    rm -f "$SCHED_STATE/gui"
    sched_status=0
    sched_out=$(sched_schedule install 2>&1) || sched_status=$?
    [ "$sched_status" -eq 75 ] || fail "install with no GUI domain did not say so ($sched_status)"
    case $sched_out in *'loads at the next console login'*) ;; *) fail "install over SSH was not explained: $sched_out" ;; esac
    [ -f "$sched_fast" ] || fail "install with no GUI domain wrote no job"
    [ ! -e "$(fleet_schedule_optout_path)" ] || fail "install did not lift the opt-out"

    fi

    if section_part 3; then
    # The launcher shim the jobs run (part 2 builds its own).
    printf '#!/bin/sh\n' >"$HOME/.local/bin/roundhouse"
    chmod +x "$HOME/.local/bin/roundhouse"
    # --- fleet-schedule on Linux: systemd user service + timer pairs ---
    SCHED_UNAME=Linux
    sched_reset
    : >"$SCHED_STATE/usermgr"
    : >"$SCHED_STATE/linger"
    sched_out=$("$cli" fleet-schedule install 2>&1) || fail "the Linux install failed: $sched_out"
    for sched_mode in fast full; do
      sched_interval=$(fleet_run_interval_seconds '{}' vireo "$sched_mode")
      [ -f "$sched_units/roundhouse-fleet-$sched_mode.service" ] &&
        [ -f "$sched_units/roundhouse-fleet-$sched_mode.timer" ] ||
        fail "the Linux install wrote no fleet-$sched_mode service/timer pair"
      grep -Eq "^ExecStart=/[^ ]+ -lc 'exec \"%h/.local/bin/roundhouse\" fleet-run --$sched_mode'\$" \
        "$sched_units/roundhouse-fleet-$sched_mode.service" ||
        fail "the fleet-$sched_mode service does not run the shim through a login shell"
      grep -Fqx 'Type=oneshot' "$sched_units/roundhouse-fleet-$sched_mode.service" ||
        fail "the fleet-$sched_mode service is not a oneshot"
      grep -Fqx "OnUnitActiveSec=${sched_interval}s" "$sched_units/roundhouse-fleet-$sched_mode.timer" &&
        grep -Fqx "OnBootSec=${sched_interval}s" "$sched_units/roundhouse-fleet-$sched_mode.timer" ||
        fail "the fleet-$sched_mode timer is not on the run's own jittered interval"
      grep -Fqx "systemctl --user enable --now roundhouse-fleet-$sched_mode.timer" "$SCHED_LOG" ||
        fail "the Linux install did not enable the fleet-$sched_mode timer"
    done
    grep -Fqx 'systemctl --user daemon-reload' "$SCHED_LOG" ||
      fail "the Linux install did not reload the user manager"
    : >"$SCHED_LOG"
    sched_schedule install >/dev/null 2>&1 || fail "a repeat Linux install failed"
    ! grep -Eq 'systemctl --user (enable|restart|start|daemon-reload)' "$SCHED_LOG" ||
      fail "a repeat Linux install touched unchanged, active timers: $(cat "$SCHED_LOG")"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: installed, enabled, loaded, definition matches'*) ;;
      *) fail "the Linux status did not report a healthy timer" ;;
    esac
    # Status renders and compares the SERVICE too, not only the timer: a
    # hand-edited service differs, and a missing one is a missing job.
    cp "$sched_units/roundhouse-fleet-fast.service" "$sched_root/fast.service.saved"
    printf 'ExecStartPre=/bin/true\n' >>"$sched_units/roundhouse-fleet-fast.service"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: installed, enabled, loaded, definition differs from what install writes (roundhouse-fleet-fast.service)'*) ;;
      *) fail "status did not report a hand-edited service: $("$cli" fleet-schedule status)" ;;
    esac
    rm -f "$sched_units/roundhouse-fleet-fast.service"
    case $("$cli" fleet-schedule status) in
      *'fleet-fast: missing, definition incomplete (roundhouse-fleet-fast.service absent)'*) ;;
      *) fail "status did not report a missing service as a missing job: $("$cli" fleet-schedule status)" ;;
    esac
    [ "$(fleet_schedule_probe fast)" = missing ] ||
      fail "the probe did not treat a missing service as a missing job"
    cp "$sched_root/fast.service.saved" "$sched_units/roundhouse-fleet-fast.service"
    fleet_schedule_job_state fast >/dev/null
    # Without lingering, the timers die with the session: a PREFLIGHT, so
    # install says so and writes and enables nothing.
    rm -f "$SCHED_STATE/linger"
    mv "$sched_units" "$sched_units.away"
    : >"$SCHED_LOG"
    sched_status=0
    sched_out=$("$cli" fleet-schedule install 2>&1) || sched_status=$?
    [ "$sched_status" -eq 75 ] || fail "install on a non-lingering user did not say so ($sched_status)"
    case $sched_out in *'loginctl enable-linger'*'Nothing was written'*) ;; *) fail "the linger preflight named no fix: $sched_out" ;; esac
    [ -z "$(find "$sched_units" -name 'roundhouse-fleet-*' 2>/dev/null)" ] ||
      fail "install wrote units for a user manager that does not linger"
    ! grep -Eq 'systemctl --user (enable|start|restart|daemon-reload)' "$SCHED_LOG" ||
      fail "install enabled timers for a user manager that does not linger: $(cat "$SCHED_LOG")"
    rm -rf "$sched_units"
    mv "$sched_units.away" "$sched_units"
    : >"$SCHED_STATE/linger"
    # The operator disables the timer; the pass alerts and leaves it disabled.
    systemctl --user disable --now roundhouse-fleet-fast.timer
    : >"$SCHED_LOG"
    fleet_schedule_check "$ROUNDHOUSE_FLEET_STORE" wren 2>/dev/null
    [ -n "$(find "$ROUNDHOUSE_FLEET_STORE/alerts/wren" -name 'schedule-disabled--fleet-fast.yaml')" ] ||
      fail "a pass did not alert on an operator-disabled Linux timer"
    ! grep -Eq 'systemctl --user (enable|start|restart)' "$SCHED_LOG" ||
      fail "a pass re-enabled an operator-disabled timer: $(cat "$SCHED_LOG")"
    # A manager that will not disable a timer it still has enabled leaves the
    # uninstall undone.
    sched_status=0
    SCHED_DISABLE_FAIL=1 sched_schedule uninstall >/dev/null 2>&1 || sched_status=$?
    [ "$sched_status" -ne 0 ] || fail "uninstall reported success while systemd still held the timer"
    [ -f "$sched_units/roundhouse-fleet-full.timer" ] ||
      fail "an uninstall whose disable failed still removed the unit"
    "$cli" fleet-schedule uninstall >/dev/null || fail "the Linux uninstall failed"
    [ -f "$sched_units/roundhouse-fleet-full.timer.removed" ] &&
      [ -f "$sched_units/roundhouse-fleet-full.service.removed" ] ||
      fail "the Linux uninstall kept no .removed copies"
    [ ! -e "$sched_units/roundhouse-fleet-fast.timer" ] &&
      [ ! -e "$sched_units/roundhouse-fleet-full.service" ] ||
      fail "the Linux uninstall left a unit behind"
    # An XDG_CONFIG_HOME outside HOME would put the units outside the
    # account's own tree: install refuses and writes nothing there.
    sched_status=0
    sched_out=$(XDG_CONFIG_HOME="$sched_root/outside-home" sched_schedule install 2>&1) ||
      sched_status=$?
    [ "$sched_status" -eq 64 ] || fail "install wrote units outside HOME ($sched_status): $sched_out"
    [ ! -e "$sched_root/outside-home" ] || fail "install created files outside HOME"
    # The same through a symlink: lexically under HOME, really outside it.
    mkdir -p "$sched_root/outside-real"
    ln -s "$sched_root/outside-real" "$HOME/linked-config"
    sched_status=0
    sched_out=$(XDG_CONFIG_HOME="$HOME/linked-config" sched_schedule install 2>&1) ||
      sched_status=$?
    [ "$sched_status" -eq 64 ] || fail "install followed a symlink out of HOME ($sched_status): $sched_out"
    [ -z "$(ls -A "$sched_root/outside-real")" ] || fail "install wrote through a symlink outside HOME"
    rm -f "$HOME/linked-config"
    # No user manager (WSL without systemd): written, and the fix is named.
    rm -f "$SCHED_STATE/usermgr"
    sched_status=0
    sched_out=$(sched_schedule install 2>&1) || sched_status=$?
    [ "$sched_status" -eq 75 ] || fail "install with no user manager did not say so ($sched_status)"
    case $sched_out in *'no systemd user manager is reachable'*'wsl.conf'*) ;; *) fail "install with no user manager named no fix: $sched_out" ;; esac
    case $sched_out in *'enable-linger'*) fail "an unreachable manager on a lingering account was blamed on lingering: $sched_out" ;; esac

    # A HOME and an XDG_CONFIG_HOME with spaces in them: every definition is
    # one path, installed and then removed whole, on both platforms.
    (
      HOME="$sched_root/home with space"
      XDG_CONFIG_HOME="$HOME/config dir"
      export HOME XDG_CONFIG_HOME
      mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.local/bin"
      printf '#!/bin/sh\n' >"$HOME/.local/bin/roundhouse"
      chmod +x "$HOME/.local/bin/roundhouse"
      for sched_uname in Darwin Linux; do
        SCHED_UNAME=$sched_uname
        export SCHED_UNAME
        rm -rf "$SCHED_STATE" "$(fleet_schedule_optout_path)"
        mkdir -p "$SCHED_STATE"
        : >"$SCHED_STATE/gui"
        : >"$SCHED_STATE/usermgr"
        : >"$SCHED_STATE/linger"
        # The pipeline end to end on macOS; the planner and executor on Linux.
        sched_run() {
          if [ "$sched_uname" = Darwin ]; then "$cli" fleet-schedule "$@"; else sched_schedule "$@"; fi
        }
        sched_out=$(sched_run install 2>&1) ||
          fail "install under a spaced HOME failed on $sched_uname: $sched_out"
        sched_spaced=$(fleet_schedule_def_paths fast; fleet_schedule_def_paths full)
        while IFS= read -r sched_spaced_path; do
          case $sched_spaced_path in *' '*) ;; *) fail "the spaced fixture produced an unspaced path: $sched_spaced_path" ;; esac
          [ -f "$sched_spaced_path" ] || fail "install under a spaced HOME wrote no $sched_spaced_path"
        done <<EOF_SPACED
$sched_spaced
EOF_SPACED
        sched_out=$(sched_run uninstall 2>&1) ||
          fail "uninstall under a spaced HOME failed on $sched_uname: $sched_out"
        while IFS= read -r sched_spaced_path; do
          [ ! -e "$sched_spaced_path" ] ||
            fail "uninstall under a spaced HOME left $sched_spaced_path on $sched_uname: $sched_out"
        done <<EOF_SPACED
$sched_spaced
EOF_SPACED
        case $sched_out in *'not installed'*) fail "uninstall under a spaced HOME found nothing: $sched_out" ;; esac
      done
    )

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
    fi
  )
fi
