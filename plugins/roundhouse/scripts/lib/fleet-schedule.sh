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

# --- the job definitions -------------------------------------------------------

fleet_schedule_interval() {
  # The macOS StartInterval, in seconds: 21 minutes and 12 h 39 min. Not
  # round numbers on purpose — an interval that divides the hour fires every
  # Mac in the fleet on the same minute.
  case $1 in
    fast) printf '1260\n' ;;
    *) printf '45540\n' ;;
  esac
}

fleet_schedule_xml_text() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

fleet_schedule_plist_render() {
  # fleet_schedule_plist_render fast|full — the LaunchAgent, byte for byte the
  # shape the fleet's hosts already carry, so `install` on a host that has it
  # is a no-op. `$HOME` stays literal in the command (zsh expands it); the log
  # path is absolute because launchd expands nothing.
  render_log=$(fleet_schedule_xml_text "$HOME/Library/Logs/roundhouse-fleet-$1.log")
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(fleet_schedule_label "$1")</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>-lc</string>
		<string>exec "\$HOME/.local/bin/roundhouse" fleet-run --$1</string>
	</array>
	<key>StartInterval</key>
	<integer>$(fleet_schedule_interval "$1")</integer>
	<key>RunAtLoad</key>
	<false/>
	<key>StandardOutPath</key>
	<string>$render_log</string>
	<key>StandardErrorPath</key>
	<string>$render_log</string>
</dict>
</plist>
PLIST
}

fleet_schedule_login_shell() {
  # The account's login shell, absolute and executable, else /bin/sh. The
  # scheduled pass needs the login PATH (harnesses, Node) exactly as an
  # interactive shell has it — fleet-update's Node requirement.
  render_shell=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7) || render_shell=
  [ -n "$render_shell" ] || render_shell=${SHELL:-}
  case $render_shell in
    /*) [ -x "$render_shell" ] || render_shell=/bin/sh ;;
    *) render_shell=/bin/sh ;;
  esac
  printf '%s\n' "$render_shell"
}

fleet_schedule_service_render() {
  cat <<UNIT
[Unit]
Description=roundhouse fleet-run --$1 (desired-state convergence)

[Service]
Type=oneshot
ExecStart=$(fleet_schedule_login_shell) -lc 'exec "%h/.local/bin/roundhouse" fleet-run --$1'
UNIT
}

fleet_schedule_timer_render() {
  # The same cadence as the LaunchAgents, as calendar events so Persistent=
  # applies: a laptop that slept through a slot catches up once at wake rather
  # than storming. FixedRandomDelay keeps each host's offset stable (seeded by
  # systemd from the machine and unit), the jitter rule the run itself follows.
  case $1 in
    fast)
      render_calendar='*:0/21'
      render_delay=300
      render_what='every 21 minutes'
      ;;
    *)
      render_calendar='*-*-* 00,12:00:00'
      render_delay=5400
      render_what='twice a day'
      ;;
  esac
  cat <<UNIT
[Unit]
Description=roundhouse fleet-run --$1, $render_what

[Timer]
OnCalendar=$render_calendar
RandomizedDelaySec=$render_delay
FixedRandomDelay=true
Persistent=true
Unit=$(fleet_schedule_unit "$1").service

[Install]
WantedBy=timers.target
UNIT
}

fleet_schedule_same() {
  # fleet_schedule_same EXISTING RENDERED — byte-equal, or (for a plist, where
  # plutil exists) equal after canonicalisation, so a hand-saved copy with
  # different whitespace or key order still reads as the same job.
  cmp -s "$1" "$2" && return 0
  case $1 in
    *.plist)
      command -v plutil >/dev/null 2>&1 || return 1
      same_left=$(plutil -convert xml1 -o - "$1" 2>/dev/null) || return 1
      same_right=$(plutil -convert xml1 -o - "$2" 2>/dev/null) || return 1
      [ "$same_left" = "$same_right" ]
      ;;
    *) return 1 ;;
  esac
}

fleet_schedule_place() {
  # fleet_schedule_place PATH RENDERED-FILE — install one definition. Prints
  # `unchanged` or `written`; a definition that already exists and DIFFERS is
  # reported with its diff before it is replaced, so an operator's hand edit is
  # never overwritten silently.
  if [ -f "$1" ] && fleet_schedule_same "$1" "$2"; then
    printf 'unchanged\n'
    return 0
  fi
  if [ -f "$1" ]; then
    printf 'roundhouse: %s differs from the definition fleet-schedule writes; replacing it:\n' \
      "$1" >&2
    diff -u "$1" "$2" | sed 's/^/  /' >&2 || :
  fi
  mkdir -p "$(dirname "$1")" || return 1
  cp "$2" "$1.next.$$" && chmod 0644 "$1.next.$$" && mv -f "$1.next.$$" "$1" || {
    rm -f "$1.next.$$"
    return 1
  }
  printf 'written\n'
}

fleet_schedule_marker() {
  # Host-local evidence that fleet-schedule owns this host's jobs, which is
  # what lets a pass tell "the operator never installed them" from "they
  # were installed and are gone".
  printf '%s/schedule-installed\n' "$(fleet_instance_path store.run)"
}

fleet_schedule_legacy_labels() {
  # The superseded entries fleet-update's absorb rule names: the old
  # autoupdate agent and the one-plist fleet agent.
  printf '%s\n' com.novotnyllc.roundhouse.autoupdate com.novotnyllc.roundhouse.fleet
}

fleet_schedule_install_launchd() {
  install_domain=$(fleet_schedule_gui_domain)
  install_has_domain=true
  launchctl print "$install_domain" >/dev/null 2>&1 || install_has_domain=false
  # Absorb, never duplicate (fleet-update): a host carrying an old entry beside
  # the new pair is the double runner the one-owner rule exists to prevent.
  for install_legacy in $(fleet_schedule_legacy_labels); do
    install_legacy_plist="$HOME/Library/LaunchAgents/$install_legacy.plist"
    [ -f "$install_legacy_plist" ] || continue
    [ "$install_has_domain" != true ] ||
      launchctl bootout "$install_domain/$install_legacy" >/dev/null 2>&1 || :
    rm -f "$install_legacy_plist"
    printf 'roundhouse: absorbed the superseded %s entry\n' "$install_legacy"
  done
  install_rc=0
  for install_mode in fast full; do
    install_plist=$(fleet_schedule_plist "$install_mode")
    install_label=$(fleet_schedule_label "$install_mode")
    fleet_schedule_plist_render "$install_mode" >"$install_tmp/$install_mode.plist"
    install_result=$(fleet_schedule_place "$install_plist" \
      "$install_tmp/$install_mode.plist") || {
      printf 'roundhouse: could not write %s\n' "$install_plist" >&2
      return 73
    }
    mkdir -p "$HOME/Library/Logs"
    if [ "$install_has_domain" != true ]; then
      printf 'fleet-%s: %s %s; no GUI launchd domain for this user, so it loads at the next console login\n' \
        "$install_mode" "$install_result" "$install_plist"
      install_rc=75
      continue
    fi
    install_state=$(fleet_schedule_job_state "$install_mode")
    # The ONE place a disabled job is re-enabled: the operator asked for it.
    if [ "$install_state" = disabled ]; then
      launchctl enable "$install_domain/$install_label" >/dev/null 2>&1 || {
        printf 'roundhouse: launchctl enable %s/%s failed\n' "$install_domain" "$install_label" >&2
        return 70
      }
      printf 'fleet-%s: re-enabled (it was disabled)\n' "$install_mode"
      install_state=unloaded
    fi
    if [ "$install_state" = loaded ] && [ "$install_result" = written ]; then
      launchctl bootout "$install_domain/$install_label" >/dev/null 2>&1 || :
      install_state=unloaded
    fi
    if [ "$install_state" != loaded ]; then
      launchctl bootstrap "$install_domain" "$install_plist" >/dev/null 2>&1 || {
        printf 'roundhouse: launchctl bootstrap %s %s failed\n' "$install_domain" "$install_plist" >&2
        return 70
      }
      install_result="$install_result, loaded"
    fi
    printf 'fleet-%s: %s %s\n' "$install_mode" "$install_result" "$install_plist"
  done
  return "$install_rc"
}

fleet_schedule_install_systemd() {
  install_dir=$(fleet_schedule_unit_dir)
  install_changed=false
  for install_mode in fast full; do
    install_unit=$(fleet_schedule_unit "$install_mode")
    fleet_schedule_service_render "$install_mode" >"$install_tmp/$install_unit.service"
    fleet_schedule_timer_render "$install_mode" >"$install_tmp/$install_unit.timer"
    for install_kind in service timer; do
      install_result=$(fleet_schedule_place "$install_dir/$install_unit.$install_kind" \
        "$install_tmp/$install_unit.$install_kind") || {
        printf 'roundhouse: could not write %s\n' "$install_dir/$install_unit.$install_kind" >&2
        return 73
      }
      printf 'fleet-%s: %s %s\n' "$install_mode" "$install_result" \
        "$install_dir/$install_unit.$install_kind"
      [ "$install_result" = unchanged ] || install_changed=true
    done
  done
  fleet_schedule_user_manager || {
    printf 'roundhouse: the units are written but no systemd user manager is reachable (`systemctl --user`); under WSL enable systemd in /etc/wsl.conf, and on a headless host run `loginctl enable-linger %s`, then re-run `roundhouse fleet-schedule install`\n' \
      "$(id -un)" >&2
    return 75
  }
  [ "$install_changed" != true ] || systemctl --user daemon-reload >/dev/null 2>&1 || :
  for install_mode in fast full; do
    install_timer="$(fleet_schedule_unit "$install_mode").timer"
    case $(fleet_schedule_job_state "$install_mode") in
      loaded)
        [ "$install_changed" != true ] ||
          systemctl --user restart "$install_timer" >/dev/null 2>&1 || :
        ;;
      *)
        # The ONE place a disabled timer is re-enabled: the operator asked.
        systemctl --user enable --now "$install_timer" >/dev/null 2>&1 || {
          printf 'roundhouse: systemctl --user enable --now %s failed\n' "$install_timer" >&2
          return 70
        }
        printf 'fleet-%s: enabled and started %s\n' "$install_mode" "$install_timer"
        ;;
    esac
  done
}

fleet_schedule_status() {
  # One line per job: installed or missing, enabled or disabled, loaded or
  # not, and whether the definition on disk is the one `install` writes.
  status_dir=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule.XXXXXX") || return 1
  for status_mode in fast full; do
    case $(fleet_schedule_platform) in
      launchd)
        status_path=$(fleet_schedule_plist "$status_mode")
        fleet_schedule_plist_render "$status_mode" >"$status_dir/def"
        ;;
      *)
        status_path="$(fleet_schedule_unit_dir)/$(fleet_schedule_unit "$status_mode").timer"
        fleet_schedule_timer_render "$status_mode" >"$status_dir/def"
        ;;
    esac
    status_def=
    if [ -f "$status_path" ]; then
      if fleet_schedule_same "$status_path" "$status_dir/def"; then
        status_def=', definition matches'
      else
        status_def=', definition differs from what install writes'
      fi
    fi
    case $(fleet_schedule_job_state "$status_mode") in
      missing) status_text='missing' ;;
      disabled) status_text='installed, disabled' ;;
      unloaded) status_text='installed, enabled, not loaded' ;;
      loaded) status_text='installed, enabled, loaded' ;;
      *) status_text='installed, state unknown (no GUI domain or user manager to ask)' ;;
    esac
    printf 'fleet-%s: %s%s — %s\n' "$status_mode" "$status_text" "$status_def" "$status_path"
  done
  rm -rf "$status_dir"
}

fleet_schedule_uninstall() {
  case $(fleet_schedule_platform) in
    launchd)
      uninstall_domain=$(fleet_schedule_gui_domain)
      for uninstall_mode in fast full; do
        uninstall_plist=$(fleet_schedule_plist "$uninstall_mode")
        launchctl bootout "$uninstall_domain/$(fleet_schedule_label "$uninstall_mode")" \
          >/dev/null 2>&1 || :
        if [ -f "$uninstall_plist" ]; then
          rm -f "$uninstall_plist"
          printf 'fleet-%s: removed %s\n' "$uninstall_mode" "$uninstall_plist"
        else
          printf 'fleet-%s: not installed\n' "$uninstall_mode"
        fi
      done
      ;;
    systemd)
      uninstall_dir=$(fleet_schedule_unit_dir)
      for uninstall_mode in fast full; do
        uninstall_unit=$(fleet_schedule_unit "$uninstall_mode")
        ! fleet_schedule_user_manager ||
          systemctl --user disable --now "$uninstall_unit.timer" >/dev/null 2>&1 || :
        if [ -f "$uninstall_dir/$uninstall_unit.timer" ] ||
          [ -f "$uninstall_dir/$uninstall_unit.service" ]; then
          rm -f "$uninstall_dir/$uninstall_unit.timer" "$uninstall_dir/$uninstall_unit.service"
          printf 'fleet-%s: removed %s/%s.timer and .service\n' "$uninstall_mode" \
            "$uninstall_dir" "$uninstall_unit"
        else
          printf 'fleet-%s: not installed\n' "$uninstall_mode"
        fi
      done
      ! fleet_schedule_user_manager || systemctl --user daemon-reload >/dev/null 2>&1 || :
      ;;
  esac
  rm -f "$(fleet_schedule_marker)"
}

fleet_schedule_command() (
  # `roundhouse fleet-schedule install|status|uninstall` — this host's two
  # scheduled jobs. Host-local and operator-run: it never reaches another
  # host, and `install` is the only path in the system that enables a job.
  [ $# -eq 1 ] || {
    printf 'roundhouse: fleet-schedule takes one of install, status, uninstall\n' >&2
    exit 64
  }
  case $1 in
    install | status | uninstall) ;;
    *)
      printf 'roundhouse: unknown fleet-schedule action: %s\n' "$1" >&2
      exit 64
      ;;
  esac
  exec </dev/null
  case $(fleet_schedule_platform) in
    launchd | systemd) ;;
    windows)
      printf 'roundhouse: fleet-schedule does not manage native Windows; the operated Windows instance is scheduled by its Task Scheduler task and driven from its WSL operator host\n' >&2
      exit 69
      ;;
    *)
      printf 'roundhouse: fleet-schedule supports launchd (macOS) and systemd user units (Linux, WSL); not %s\n' \
        "$(uname -s)" >&2
      exit 69
      ;;
  esac
  [ "$(id -u)" != 0 ] || {
    printf 'roundhouse: fleet-schedule installs per-user jobs; run it as the user whose fleet store this is, not root\n' >&2
    exit 64
  }
  case $1 in
    status)
      fleet_schedule_status
      ;;
    uninstall)
      fleet_schedule_uninstall
      ;;
    install)
      [ -x "$HOME/.local/bin/roundhouse" ] || {
        printf 'roundhouse: %s is not installed; run `roundhouse launcher-install` first — the scheduled jobs run that shim\n' \
          "$HOME/.local/bin/roundhouse" >&2
        exit 69
      }
      install_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule.XXXXXX") || exit 73
      trap 'rm -rf "$install_tmp"' EXIT HUP INT TERM
      install_status=0
      case $(fleet_schedule_platform) in
        launchd) fleet_schedule_install_launchd || install_status=$? ;;
        systemd) fleet_schedule_install_systemd || install_status=$? ;;
      esac
      case $install_status in
        0 | 75)
          mkdir -p "$(dirname "$(fleet_schedule_marker)")"
          printf 'platform: %s\ninstalled_at: %s\n' "$(fleet_schedule_platform)" \
            "$(fleet_now)" >"$(fleet_schedule_marker)"
          # A fresh install clears what the pass remembered alerting on, so a
          # job that is disabled again later is alerted afresh.
          rm -f "$(fleet_instance_path store.run)/schedule-alerted"
          ;;
      esac
      exit "$install_status"
      ;;
  esac
)

# --- the pass's own check ------------------------------------------------------

fleet_schedule_check() {
  # fleet_schedule_check STORE HOST — called by every pass. A job the operator
  # disabled, or one that went missing, is ALERTED and left exactly as it is:
  # an automatic pass never enables, loads or rewrites a job. Only
  # `roundhouse fleet-schedule install` does, because a human ran it.
  #
  # "Missing" needs evidence the host is meant to be scheduled — the install
  # marker, or the other job still present — so a host whose operator never
  # scheduled it raises nothing. A loaded-but-idle or unknown state is not an
  # alert either: no GUI domain over SSH is the ordinary state of a pass the
  # nudge started.
  #
  # One alert per state change: store.run/schedule-alerted remembers what was
  # already raised, so a disabled job is one record and not one per pass.
  check_memo=$(fleet_instance_path store.run)/schedule-alerted
  check_fast=$(fleet_schedule_job_state fast)
  check_full=$(fleet_schedule_job_state full)
  mkdir -p "$(dirname "$check_memo")" || return 0
  : >"$check_memo.next"
  for check_mode in fast full; do
    if [ "$check_mode" = fast ]; then
      check_state=$check_fast
      check_other=$check_full
    else
      check_state=$check_full
      check_other=$check_fast
    fi
    case $check_state in
      disabled)
        check_kind=schedule-disabled
        check_detail="the fleet-$check_mode scheduled job on $2 is disabled; passes will not re-enable it. Run \`roundhouse fleet-schedule install\` on $2 to re-enable it, or \`roundhouse fleet-schedule uninstall\` if it should not be scheduled"
        ;;
      missing)
        [ -f "$(fleet_schedule_marker)" ] || [ "$check_other" != missing ] || continue
        check_kind=schedule-missing
        check_detail="the fleet-$check_mode scheduled job on $2 is missing; run \`roundhouse fleet-schedule install\` on $2"
        ;;
      *) continue ;;
    esac
    if grep -Fqx "$check_mode $check_kind" "$check_memo" 2>/dev/null; then
      printf '%s %s\n' "$check_mode" "$check_kind" >>"$check_memo.next"
      continue
    fi
    printf 'roundhouse: %s\n' "$check_detail" >&2
    # Remembered only once the alert is written, so a refused write retries.
    ! fleet_alert_write "$1" "$2" "$check_kind" "$check_kind-fleet-$check_mode" \
      "$check_detail" ||
      printf '%s %s\n' "$check_mode" "$check_kind" >>"$check_memo.next"
  done
  mv -f "$check_memo.next" "$check_memo"
}
