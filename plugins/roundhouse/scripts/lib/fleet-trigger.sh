# roundhouse — the stamp-and-kick trigger, and the running pass's re-loop.
#
# §6.1 of the agent-settings loop design. Two scheduled jobs per host run the
# two cadences (lib/fleet-schedule.sh), and every other wake-up (the push
# nudge, later the SessionStart hook) is a TRIGGER:
#
#   1. touch the dirty stamp under store.run/ — after recording a pending
#      full request, for a `--full` trigger that will start the full job;
#   2. start the scheduled job — `launchctl kickstart` on macOS,
#      `systemctl --user start` on Linux — or, ONLY when that job is known to
#      be installed and enabled but its GUI domain or user manager cannot be
#      reached (a Mac over SSH with nobody at the console, a Linux user whose
#      manager does not linger), a detached `nohup roundhouse fleet-run`;
#   3. return.
#
# A trigger never runs a pass in its own process. A kickstart for a job that
# is already running is a no-op, which is why the stamp exists: the running
# pass re-runs in-process while the stamp has moved since that pass began
# (fleet_trigger_converge), so a trigger that lands mid-pass is never lost —
# nor its cadence: the re-run is full while a full request is pending.
# One that lands after the run's last compare, as it exits, is the trigger's
# to catch: it starts the job once that exit is done
# (fleet_trigger_exit_pending).
#
# AN OPERATOR STOP IS FINAL TO EVERYTHING BUT `install`. A job the operator
# disabled or unloaded, a host whose jobs were uninstalled (the opt-out
# marker), a host that never had them: the trigger stamps and starts nothing,
# a pending full request is dropped rather than run by the fast job, and a
# pass alerts (a disabled or missing job) and changes nothing. Only an
# explicit `roundhouse fleet-schedule install` enables.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

# --- the dirty stamp -----------------------------------------------------------

fleet_trigger_stamp_path() {
  printf '%s/dirty-stamp\n' "$(fleet_run_state_dir)"
}

fleet_trigger_stamp() {
  # Touch the stamp. Its CONTENT is unique per trigger (time, pid, a random
  # draw), so the content alone is the comparison and no mtime is read.
  trigger_stamp=$(fleet_trigger_stamp_path)
  mkdir -p "$(dirname "$trigger_stamp")" || return 1
  printf '%s %s %s\n' "$(fleet_now)" "$$" "${RANDOM:-0}" \
    >"$trigger_stamp.next.$$" || return 1
  mv -f "$trigger_stamp.next.$$" "$trigger_stamp"
}

fleet_trigger_stamp_state() {
  cat "$(fleet_trigger_stamp_path)" 2>/dev/null || printf 'absent\n'
}

# --- the requested cadence -------------------------------------------------------

fleet_trigger_full_path() {
  # The pending FULL request. The stamp says "go look" and every trigger
  # overwrites it, so a cadence written into it would be lost to the next fast
  # trigger; this file stays until a pass begins (fleet_trigger_take_mode).
  printf '%s/full-requested\n' "$(fleet_run_state_dir)"
}

fleet_trigger_request_full() {
  mkdir -p "$(fleet_run_state_dir)" && : >"$(fleet_trigger_full_path)"
}

fleet_trigger_take_mode() {
  # fleet_trigger_take_mode MODE — the cadence of the pass about to begin, and
  # the pending full request consumed: full when MODE is full, or when a full
  # trigger is pending and the full job is still one a trigger would start
  # (fleet_trigger_plan) — an operator who stopped it since is final. A pass
  # beginning answers every request made before it; one that lands during it
  # is the next pass's.
  if [ -e "$(fleet_trigger_full_path)" ]; then
    rm -f "$(fleet_trigger_full_path)"
    if [ "$1" != full ]; then
      case $(fleet_trigger_plan full) in start | detach) set -- full ;; esac
    fi
  fi
  printf '%s\n' "$1"
}

# --- the kick ------------------------------------------------------------------

fleet_trigger_detach() {
  # fleet_trigger_detach fast|full REASON — the unreachable-scheduler
  # fallback, and the only detached pass: with no scheduler to start the job
  # in, nothing will reap it either. No `setsid`: macOS has none. `nohup`
  # with every stream closed is what lets an SSH session that started it end
  # without waiting on it or taking it down. (A self-check may stand in its
  # own runner.)
  trigger_runner="$script_dir/roundhouse"
  if fleet_test_hook "${ROUNDHOUSE_FLEET_TRIGGER_RUNNER:-}"; then
    trigger_runner=$ROUNDHOUSE_FLEET_TRIGGER_RUNNER
  fi
  nohup "$trigger_runner" fleet-run "--$1" </dev/null >/dev/null 2>&1 &
  printf 'roundhouse: %s; started a detached fleet-run --%s\n' "$2" "$1"
}

fleet_trigger_exit_pending() {
  # fleet_trigger_exit_pending fast|full — THE LAST-MOMENT RACE. A run
  # compares the stamp one final time AFTER it releases the lock
  # (fleet_run_command's handoff), then exits. A trigger that moves the stamp
  # after that compare, while the job is still running, would get a start
  # that is a no-op — a running launchd job or an activating systemd oneshot
  # is not started twice — and wait for the next scheduled run.
  #
  # True in the only state in which that can be so: the job running with no
  # lock held. Held means the lock's meta names a holder, so a lock directory
  # caught mid-acquire or mid-release reads as free. While a lock IS held, its
  # holder (a fleet-run) compares again after this stamp, within its storm
  # bounds.
  fleet_schedule_backend running "$1" 2>/dev/null &&
    [ -z "$(fleet_lock_identity "$(fleet_lock_path)")" ]
}

fleet_trigger_start_after_exit() {
  # fleet_trigger_start_after_exit fast|full — while fleet_trigger_exit_pending
  # holds, wait for whichever comes first: a run taking the lock (it sees the
  # stamp) or the job ending (the start then launches a fresh run); then
  # start. It lasts a run's exit, or its startup before the lock, never a
  # pass, and it is bounded. DETACHED, with SIGHUP ignored: a trigger that
  # came over SSH (the push nudge, under a ten-second watchdog) returns at
  # once, and the session ending does not take the start with it.
  #
  # The job is judged AGAIN right before the start, by the trigger's own
  # plan: an operator who disabled, unloaded or uninstalled it during the
  # wait has stopped it, and an operator stop is final.
  await_limit=30
  if fleet_test_hook "${ROUNDHOUSE_TEST_TRIGGER_AWAIT_SECONDS:-}"; then
    await_limit=$ROUNDHOUSE_TEST_TRIGGER_AWAIT_SECONDS
  fi
  (
    trap '' HUP
    await_until=$((SECONDS + await_limit))
    while fleet_trigger_exit_pending "$1" && [ "$SECONDS" -lt "$await_until" ]; do
      sleep 0.1
    done
    [ "$(fleet_trigger_plan "$1")" = start ] || exit 0
    fleet_schedule_backend start "$1" || :
  ) </dev/null >/dev/null 2>&1 &
}

fleet_trigger_plan() {
  # fleet_trigger_plan fast|full — what a trigger does with MODE's job, one
  # word. Only `start` and `detach` run MODE's pass; every other word is a
  # refusal or an operator stop the trigger honours.
  #
  #   windows  native Windows: the WSL operator host drives this instance
  #   optout   the host was taken off the schedule (fleet-schedule uninstall)
  #   start    the job is loaded: ask its scheduler to start it
  #   detach   KNOWN installed and enabled — systemd says so from its wants
  #            link, launchd from the last state observed while its domain
  #            was reachable — but the scheduler is unreachable from here
  #   unseen   unreachable, and not last seen loaded
  #   stopped  disabled or unloaded by the operator
  #   none     no job installed
  if [ "$(fleet_schedule_platform)" = windows ]; then
    printf 'windows\n'
  elif [ -e "$(fleet_schedule_optout_path)" ]; then
    printf 'optout\n'
  else
    case $(fleet_schedule_job_state "$1") in
      loaded) printf 'start\n' ;;
      unavailable)
        if [ "$(fleet_schedule_platform)" = systemd ] ||
          [ "$(fleet_schedule_last_state "$1")" = loaded ]; then
          printf 'detach\n'
        else
          printf 'unseen\n'
        fi
        ;;
      disabled | unloaded) printf 'stopped\n' ;;
      *) printf 'none\n' ;;
    esac
  fi
}

fleet_trigger_kick() {
  # fleet_trigger_kick fast|full PLAN — act on fleet_trigger_plan's word.
  # Returns as soon as the start is requested; never waits for a pass.
  case $2 in
    windows)
      printf 'roundhouse: fleet-trigger does not run on native Windows; the operated instance is driven from its WSL operator host\n' >&2
      return 69
      ;;
    optout)
      printf 'roundhouse: this host was taken off the schedule (fleet-schedule uninstall); stamped, not started\n'
      ;;
    start)
      if fleet_trigger_exit_pending "$1"; then
        fleet_trigger_start_after_exit "$1"
        printf 'roundhouse: stamped; fleet-%s is finishing a run that may not have seen this trigger, and is started once that run exits\n' "$1"
      elif fleet_schedule_backend start "$1" >/dev/null 2>&1; then
        printf 'roundhouse: stamped and started fleet-%s\n' "$1"
      else
        printf 'roundhouse: the scheduler refused to start fleet-%s; stamped, the next scheduled run picks it up\n' "$1"
      fi
      ;;
    detach)
      fleet_trigger_detach "$1" "fleet-$1 is installed and enabled but its scheduler is unreachable from here"
      ;;
    unseen)
      printf 'roundhouse: fleet-%s cannot be reached and was not last seen running; stamped, not started\n' "$1"
      ;;
    stopped)
      printf 'roundhouse: fleet-%s is stopped by the operator (fleet-schedule status); stamped, not started\n' "$1"
      ;;
    *)
      printf 'roundhouse: no fleet-%s job is installed (roundhouse fleet-schedule install); stamped, not started\n' "$1"
      ;;
  esac
}

fleet_trigger_command() (
  # `roundhouse fleet-trigger [--fast|--full]` — §6.1's one trigger: stamp,
  # kick, return. The push nudge sends exactly this to a peer over SSH.
  trigger_mode=fast
  while [ $# -gt 0 ]; do
    case $1 in
      --fast) trigger_mode=fast ;;
      --full) trigger_mode=full ;;
      *)
        printf 'roundhouse: unknown fleet-trigger option: %s\n' "$1" >&2
        exit 64
        ;;
    esac
    shift
  done
  exec </dev/null
  trigger_plan=$(fleet_trigger_plan "$trigger_mode")
  # A full trigger that will start the full job records the request BEFORE
  # the stamp, so a pass that sees the stamp move also sees the cadence it
  # was moved for: a full job that finds a pass holding the lock exits, and
  # that pass's re-run takes the request (fleet_trigger_converge). One that
  # starts nothing records none, so an operator stop stays final.
  case $trigger_mode.$trigger_plan in
    full.start | full.detach)
      fleet_trigger_request_full || {
        printf 'roundhouse: could not record the full request at %s\n' \
          "$(fleet_trigger_full_path)" >&2
        exit 73
      }
      ;;
  esac
  fleet_trigger_stamp || {
    printf 'roundhouse: could not write the trigger stamp at %s\n' \
      "$(fleet_trigger_stamp_path)" >&2
    exit 73
  }
  fleet_trigger_kick "$trigger_mode" "$trigger_plan"
)

# --- the running pass's re-loop -------------------------------------------------

fleet_trigger_converge() {
  # fleet_trigger_converge PASS ROOT MODE LOCK NONCE — run `PASS PASS-TMP
  # PASS-MODE` once,
  # then again in-process while the dirty stamp moved since that pass began.
  # Called by fleet_run_command under its lock. Every pass gets its own
  # PASS-TMP under ROOT (and, inside it, its own alert ledger): a re-run pass
  # that inherited the previous pass's `raised` lines would keep an alert its
  # own check no longer raises.
  #
  # A trigger that lands while a pass holds the lock starts a second run that
  # finds the lock and exits, so the trigger rides the stamp instead. Bounded —
  # three extra passes — so a trigger storm cannot pin the lock; anything later
  # waits for the next scheduled run. Each pass's cadence is
  # fleet_trigger_take_mode's: an extra pass is a FAST one, floor included —
  # a trigger says "go look", and repeating a full pass's marketplace refresh
  # and package updates is not looking — unless a full trigger is pending.
  # `fleet-trigger --full` landing mid-pass kicks a full job that finds the
  # lock and exits, so this run's next pass is the full one it asked for.
  #
  # It STOPS, without another pass, when a pass ended on a signal (status
  # 128 and above; a signal to the run itself exits it outright), and
  # when LOCK no longer carries NONCE — another run took it over, and a pass
  # outside the lock is exactly what the lock exists to prevent.
  #
  # Each pass runs with errexit LIVE (errexit_capture): `PASS || …` would
  # switch it off for the whole body. The results land in two globals rather
  # than the return status, so the caller can call this plainly:
  #
  #   fleet_trigger_status      the WORST pass status, so a later clean pass
  #                             does not launder an earlier hold
  #   fleet_trigger_last_stamp  the stamp the LAST comparison read, for the
  #                             caller's check once the lock is released
  errexit_require fleet_trigger_converge
  converge_pass=$1
  converge_root=$2
  converge_mode=$3
  converge_lock=$4
  converge_nonce=$5
  converge_extra=0
  fleet_trigger_status=0
  fleet_trigger_last_stamp=
  while :; do
    converge_seen=$(fleet_trigger_stamp_state)
    converge_mode=$(fleet_trigger_take_mode "$converge_mode")
    converge_tmp="$converge_root/pass-$converge_extra"
    mkdir -p "$converge_tmp"
    : >"$converge_tmp/alert-ledger"
    errexit_capture converge_pass_status "$converge_pass" "$converge_tmp" "$converge_mode"
    [ "$converge_pass_status" -le "$fleet_trigger_status" ] ||
      fleet_trigger_status=$converge_pass_status
    fleet_trigger_last_stamp=$(fleet_trigger_stamp_state)
    [ "$converge_pass_status" -lt 128 ] || break
    [ "$converge_extra" -lt 3 ] || break
    [ "$fleet_trigger_last_stamp" != "$converge_seen" ] || break
    [ "$(fleet_lock_identity "$converge_lock")" = "$converge_nonce" ] || {
      printf 'roundhouse: the run lock is no longer this run'"'"'s; not starting another pass\n' >&2
      [ "$fleet_trigger_status" -ge 75 ] || fleet_trigger_status=75
      break
    }
    converge_extra=$((converge_extra + 1))
    converge_mode=fast
    printf 'roundhouse: a trigger arrived during the pass; converging again in-process (%s of 3)\n' \
      "$converge_extra"
  done
}
