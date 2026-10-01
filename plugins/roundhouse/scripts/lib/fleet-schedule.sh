# roundhouse — the per-host scheduled jobs, and the stamp-and-kick trigger.
#
# §6.1 of the agent-settings loop design. Two jobs per host run the two
# cadences, and every other wake-up (the push nudge, later the SessionStart
# hook) is a TRIGGER:
#
#   1. touch the dirty stamp under store.run/;
#   2. start the scheduled job — `launchctl kickstart` on macOS,
#      `systemctl --user start` on Linux — or, when there is no GUI domain or
#      user manager to start it in (a Mac reached over SSH with nobody at the
#      console), a detached `nohup roundhouse fleet-run`;
#   3. return.
#
# A trigger never runs a pass in its own process. A kickstart for a job that
# is already running is a no-op, which is why the stamp exists: the running
# pass re-runs in-process while the stamp has moved since that pass began
# (fleet_run_command), so a trigger that lands mid-pass is never lost.
#
# An operator-disabled job is the operator's decision. A trigger stamps and
# does NOT start it; a pass alerts on it and never re-enables it. Only an
# explicit `roundhouse fleet-schedule install` enables.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_schedule_platform() {
  # launchd | systemd | windows | unsupported. WSL is Linux, and gets the
  # systemd jobs when the distribution runs a user manager.
  case $(uname -s) in
    Darwin) printf 'launchd\n' ;;
    Linux) printf 'systemd\n' ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) printf 'windows\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

fleet_schedule_label() {
  # fast|full -> the launchd label. Fixed names, not inventory: every Mac in
  # every fleet carries the same two.
  printf 'com.novotnyllc.roundhouse.fleet-%s\n' "$1"
}

fleet_schedule_plist() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(fleet_schedule_label "$1")"
}

fleet_schedule_unit() {
  # fast|full -> the systemd unit base name (`.service` and `.timer`).
  printf 'roundhouse-fleet-%s\n' "$1"
}

fleet_schedule_unit_dir() {
  printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

fleet_schedule_gui_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

fleet_schedule_user_manager() {
  # True when `systemctl --user` reaches a running user manager. Under WSL
  # without systemd, or a login with no lingering manager, it does not.
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user show-environment >/dev/null 2>&1
}

fleet_schedule_job_state() {
  # fleet_schedule_job_state fast|full -> one word:
  #
  #   missing      no job definition on disk
  #   disabled     the definition exists and the operator disabled it
  #   unloaded     present and not disabled, but not loaded/active
  #   loaded       present, enabled, loaded (launchd) or active (systemd timer)
  #   unavailable  no GUI domain / user manager to ask, so the state is unknown
  #
  # Read-only: this asks and never changes anything.
  case $(fleet_schedule_platform) in
    launchd)
      [ -f "$(fleet_schedule_plist "$1")" ] || {
        printf 'missing\n'
        return 0
      }
      job_domain=$(fleet_schedule_gui_domain)
      launchctl print "$job_domain" >/dev/null 2>&1 || {
        printf 'unavailable\n'
        return 0
      }
      # Both spellings: `=> disabled` on current macOS, `=> true` on older.
      if launchctl print-disabled "$job_domain" 2>/dev/null |
        grep -Eq "\"$(fleet_schedule_label "$1")\" => (disabled|true)"; then
        printf 'disabled\n'
      elif launchctl print "$job_domain/$(fleet_schedule_label "$1")" >/dev/null 2>&1; then
        printf 'loaded\n'
      else
        printf 'unloaded\n'
      fi
      ;;
    systemd)
      [ -f "$(fleet_schedule_unit_dir)/$(fleet_schedule_unit "$1").timer" ] || {
        printf 'missing\n'
        return 0
      }
      fleet_schedule_user_manager || {
        printf 'unavailable\n'
        return 0
      }
      job_enabled=$(systemctl --user is-enabled "$(fleet_schedule_unit "$1").timer" \
        2>/dev/null) || :
      case $job_enabled in
        disabled | masked | masked-runtime)
          printf 'disabled\n'
          return 0
          ;;
      esac
      if systemctl --user is-active --quiet "$(fleet_schedule_unit "$1").timer" 2>/dev/null; then
        printf 'loaded\n'
      else
        printf 'unloaded\n'
      fi
      ;;
    *) printf 'unavailable\n' ;;
  esac
}

# --- the dirty stamp -----------------------------------------------------------

fleet_trigger_stamp_path() {
  printf '%s/dirty-stamp\n' "$(fleet_instance_path store.run)"
}

fleet_trigger_stamp() {
  # Touch the stamp. The CONTENT changes on every trigger, not only the mtime:
  # two triggers inside one second share an mtime on a 1-second filesystem,
  # and the running pass compares both.
  trigger_stamp=$(fleet_trigger_stamp_path)
  mkdir -p "$(dirname "$trigger_stamp")" || return 1
  printf '%s %s %s\n' "$(fleet_now)" "$$" "${RANDOM:-0}" \
    >"$trigger_stamp.next.$$" || return 1
  mv -f "$trigger_stamp.next.$$" "$trigger_stamp"
}

fleet_trigger_stamp_state() {
  # The stamp as one comparable string: mtime and content, or `absent`.
  trigger_stamp=$(fleet_trigger_stamp_path)
  [ -f "$trigger_stamp" ] || {
    printf 'absent\n'
    return 0
  }
  printf '%s %s\n' "$(fleet_run_mtime "$trigger_stamp")" "$(cat "$trigger_stamp" 2>/dev/null)"
}

# --- the kick ------------------------------------------------------------------

fleet_trigger_detach() {
  # fleet_trigger_detach fast|full REASON — the no-scheduler fallback. No
  # `setsid`: macOS has none. `nohup` with every stream closed is what lets an
  # SSH session that started it end without waiting on it or taking it down.
  trigger_runner="$script_dir/roundhouse"
  if fleet_test_hook "${ROUNDHOUSE_FLEET_TRIGGER_RUNNER:-}"; then
    trigger_runner=$ROUNDHOUSE_FLEET_TRIGGER_RUNNER
  fi
  nohup "$trigger_runner" fleet-run "--$1" </dev/null >/dev/null 2>&1 &
  printf 'roundhouse: %s; started a detached fleet-run --%s\n' "$2" "$1"
}

fleet_trigger_kick() {
  # fleet_trigger_kick fast|full — start the scheduled job for MODE, or fall
  # back. Returns as soon as the start is requested; never waits for a pass.
  case $(fleet_schedule_platform) in
    launchd)
      trigger_target="$(fleet_schedule_gui_domain)/$(fleet_schedule_label "$1")"
      if [ ! -f "$(fleet_schedule_plist "$1")" ]; then
        fleet_trigger_detach "$1" "no fleet-$1 job is installed (roundhouse fleet-schedule install)"
      elif ! launchctl print "$(fleet_schedule_gui_domain)" >/dev/null 2>&1; then
        fleet_trigger_detach "$1" "no GUI launchd domain for this user (no console login)"
      elif [ "$(fleet_schedule_job_state "$1")" = disabled ]; then
        printf 'roundhouse: fleet-%s is disabled by the operator; stamped, not started (roundhouse fleet-schedule status)\n' "$1"
      elif launchctl kickstart "$trigger_target" >/dev/null 2>&1; then
        printf 'roundhouse: stamped and kicked %s\n' "$trigger_target"
      else
        fleet_trigger_detach "$1" "launchctl kickstart $trigger_target was refused"
      fi
      ;;
    systemd)
      trigger_unit="$(fleet_schedule_unit "$1").service"
      if [ ! -f "$(fleet_schedule_unit_dir)/$(fleet_schedule_unit "$1").timer" ]; then
        fleet_trigger_detach "$1" "no fleet-$1 timer is installed (roundhouse fleet-schedule install)"
      elif ! fleet_schedule_user_manager; then
        fleet_trigger_detach "$1" "no systemd user manager for this user"
      elif [ "$(fleet_schedule_job_state "$1")" = disabled ]; then
        printf 'roundhouse: fleet-%s is disabled by the operator; stamped, not started (roundhouse fleet-schedule status)\n' "$1"
      elif systemctl --user start --no-block "$trigger_unit" >/dev/null 2>&1; then
        printf 'roundhouse: stamped and started %s\n' "$trigger_unit"
      else
        fleet_trigger_detach "$1" "systemctl --user start $trigger_unit was refused"
      fi
      ;;
    windows)
      printf 'roundhouse: fleet-trigger does not run on native Windows; the operated instance is driven from its WSL operator host\n' >&2
      return 69
      ;;
    *)
      fleet_trigger_detach "$1" "no supported scheduler on $(uname -s)"
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
  fleet_trigger_stamp || {
    printf 'roundhouse: could not write the trigger stamp at %s\n' \
      "$(fleet_trigger_stamp_path)" >&2
    exit 73
  }
  fleet_trigger_kick "$trigger_mode"
)
