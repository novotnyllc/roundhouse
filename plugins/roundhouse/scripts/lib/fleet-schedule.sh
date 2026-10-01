# roundhouse — the per-host scheduled jobs, and the stamp-and-kick trigger.
#
# §6.1 of the agent-settings loop design. Two jobs per host run the two
# cadences, and every other wake-up (the push nudge, later the SessionStart
# hook) is a TRIGGER:
#
#   1. touch the dirty stamp under store.run/;
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
# (fleet_run_command), so a trigger that lands mid-pass is never lost.
#
# AN OPERATOR STOP IS FINAL TO EVERYTHING BUT `install`. A job the operator
# disabled or unloaded, a host whose jobs were uninstalled (the opt-out
# marker), a host that never had them: the trigger stamps and starts nothing,
# and a pass alerts (a disabled or missing job) and changes nothing. Only an explicit
# `roundhouse fleet-schedule install` enables.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_schedule_modes='fast full'

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

fleet_schedule_unit() {
  # fast|full -> the systemd unit base name (`.service` and `.timer`).
  printf 'roundhouse-fleet-%s\n' "$1"
}

fleet_schedule_unit_dir() {
  printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

fleet_schedule_def_path() {
  # fast|full -> the file whose presence means "this job is installed": the
  # LaunchAgent plist, or the systemd timer.
  case $(fleet_schedule_platform) in
    launchd) printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(fleet_schedule_label "$1")" ;;
    systemd) printf '%s/%s.timer\n' "$(fleet_schedule_unit_dir)" "$(fleet_schedule_unit "$1")" ;;
  esac
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

fleet_schedule_lingers() {
  # True unless logind says this user's manager does NOT linger. Without
  # lingering the manager — and every timer in it — dies with the last
  # session, so a job started from an SSH session dies with that session.
  command -v loginctl >/dev/null 2>&1 || return 0
  schedule_linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null) ||
    return 0
  [ "$schedule_linger" != no ]
}

fleet_schedule_state_path() {
  # fast|full -> that job's remembered state: ONE file per job, so a fast and a
  # full trigger landing together each replace only their own file and never
  # read-modify-write the other's line.
  printf '%s/schedule-state.%s\n' "$(fleet_run_state_dir)" "$1"
}

fleet_schedule_legacy_state_path() {
  # The combined `MODE STATE` file written before the per-job files. Read as a
  # fallback for one release, never written, removed by `uninstall`.
  printf '%s/schedule-state\n' "$(fleet_run_state_dir)"
}

fleet_schedule_optout_path() {
  # Left by `fleet-schedule uninstall`: the operator took this host off the
  # schedule, so nothing but `install` may start a pass here.
  printf '%s/schedule-opted-out\n' "$(fleet_run_state_dir)"
}

fleet_schedule_marker() {
  # Host-local evidence that fleet-schedule owns this host's jobs, which is
  # what lets a pass tell "the operator never installed them" from "they
  # were installed and are gone".
  printf '%s/schedule-installed\n' "$(fleet_run_state_dir)"
}

fleet_schedule_last_state() {
  # The last state OBSERVED for MODE (never `unavailable`), or nothing. The
  # per-job file wins; the combined legacy file answers only for a job that has
  # no file of its own yet.
  last_state_path=$(fleet_schedule_state_path "$1")
  if [ -f "$last_state_path" ]; then
    head -n 1 "$last_state_path" 2>/dev/null
    return 0
  fi
  awk -v m="$1" '$1 == m { print $2; exit }' "$(fleet_schedule_legacy_state_path)" 2>/dev/null
}

fleet_schedule_probe() {
  # fleet_schedule_probe fast|full -> one word, read-only:
  #
  #   missing      no job definition on disk
  #   disabled     the operator disabled it
  #   unloaded     present and not disabled, but not loaded/active
  #   loaded       present, enabled, loaded (launchd) or active (systemd timer)
  #   unavailable  installed, but there is no GUI domain / reachable, lingering
  #                user manager to ask or to start it in. On systemd this means
  #                ENABLED (the timers.target.wants link says so); on launchd
  #                the enablement is unknown and the last observed state rules.
  probe_def=$(fleet_schedule_def_path "$1")
  [ -n "$probe_def" ] && [ -f "$probe_def" ] || {
    printf 'missing\n'
    return 0
  }
  case $(fleet_schedule_platform) in
    launchd)
      probe_domain=$(fleet_schedule_gui_domain)
      launchctl print "$probe_domain" >/dev/null 2>&1 || {
        printf 'unavailable\n'
        return 0
      }
      # Both spellings: `=> disabled` on current macOS, `=> true` on older.
      if launchctl print-disabled "$probe_domain" 2>/dev/null |
        grep -Eq "\"$(fleet_schedule_label "$1")\" => (disabled|true)"; then
        printf 'disabled\n'
      elif launchctl print "$probe_domain/$(fleet_schedule_label "$1")" >/dev/null 2>&1; then
        printf 'loaded\n'
      else
        printf 'unloaded\n'
      fi
      ;;
    systemd)
      probe_timer="$(fleet_schedule_unit "$1").timer"
      if ! fleet_schedule_user_manager; then
        # No manager to ask: `enable` is a symlink on disk, so read that.
        if [ -L "$(fleet_schedule_unit_dir)/timers.target.wants/$probe_timer" ]; then
          printf 'unavailable\n'
        else
          printf 'disabled\n'
        fi
        return 0
      fi
      case $(systemctl --user is-enabled "$probe_timer" 2>/dev/null || :) in
        disabled | masked | masked-runtime)
          printf 'disabled\n'
          return 0
          ;;
      esac
      # A timer the operator STOPPED (inactive, still enabled) is unloaded
      # whether or not the account lingers: only an ACTIVE timer without
      # lingering is unavailable, so a trigger never runs behind a stop.
      if ! systemctl --user is-active --quiet "$probe_timer" 2>/dev/null; then
        printf 'unloaded\n'
      elif ! fleet_schedule_lingers; then
        printf 'unavailable\n'
      else
        printf 'loaded\n'
      fi
      ;;
    *) printf 'unavailable\n' ;;
  esac
}

fleet_schedule_job_state() {
  # The probe, remembered: every state actually observed is written to
  # store.run/schedule-state.MODE, and `unavailable` never overwrites one. That
  # memory is what lets a trigger over SSH (no GUI domain to ask) still honour
  # an operator's disable it can no longer see.
  #
  # Written whole through a temporary file UNIQUE to this writer and renamed
  # into place, so two triggers racing on one job leave one complete state,
  # never a torn file or another writer's half-written temporary.
  job_state=$(fleet_schedule_probe "$1")
  if [ "$job_state" != unavailable ] && [ "$(fleet_schedule_last_state "$1")" != "$job_state" ]; then
    job_state_path=$(fleet_schedule_state_path "$1")
    if mkdir -p "$(dirname "$job_state_path")" &&
      job_state_next=$(mktemp "$job_state_path.next.XXXXXX" 2>/dev/null); then
      { printf '%s\n' "$job_state" >"$job_state_next" &&
        mv -f "$job_state_next" "$job_state_path"; } || rm -f "$job_state_next"
    fi
  fi
  printf '%s\n' "$job_state"
}

fleet_schedule_start() {
  # Start MODE's job in its scheduler, without waiting for the pass.
  case $(fleet_schedule_platform) in
    launchd) launchctl kickstart "$(fleet_schedule_gui_domain)/$(fleet_schedule_label "$1")" ;;
    systemd) systemctl --user start --no-block "$(fleet_schedule_unit "$1").service" ;;
    *) return 1 ;;
  esac >/dev/null 2>&1
}

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

# --- the kick ------------------------------------------------------------------

fleet_trigger_detach() {
  # fleet_trigger_detach fast|full REASON — the unreachable-scheduler
  # fallback. No `setsid`: macOS has none. `nohup` with every stream closed is
  # what lets an SSH session that started it end without waiting on it or
  # taking it down.
  trigger_runner="$script_dir/roundhouse"
  if fleet_test_hook "${ROUNDHOUSE_FLEET_TRIGGER_RUNNER:-}"; then
    trigger_runner=$ROUNDHOUSE_FLEET_TRIGGER_RUNNER
  fi
  nohup "$trigger_runner" fleet-run "--$1" </dev/null >/dev/null 2>&1 &
  printf 'roundhouse: %s; started a detached fleet-run --%s\n' "$2" "$1"
}

fleet_trigger_kick() {
  # fleet_trigger_kick fast|full — start MODE's job, fall back, or decline.
  # Returns as soon as the start is requested; never waits for a pass.
  [ "$(fleet_schedule_platform)" != windows ] || {
    printf 'roundhouse: fleet-trigger does not run on native Windows; the operated instance is driven from its WSL operator host\n' >&2
    return 69
  }
  if [ -e "$(fleet_schedule_optout_path)" ]; then
    printf 'roundhouse: this host was taken off the schedule (fleet-schedule uninstall); stamped, not started\n'
    return 0
  fi
  case $(fleet_schedule_job_state "$1") in
    loaded)
      if fleet_schedule_start "$1"; then
        printf 'roundhouse: stamped and started fleet-%s\n' "$1"
      else
        printf 'roundhouse: the scheduler refused to start fleet-%s; stamped, the next scheduled run picks it up\n' "$1"
      fi
      ;;
    unavailable)
      # Detached only when the job is KNOWN installed and enabled: systemd
      # says so from its wants link; launchd from the last state observed
      # while its domain was reachable.
      if [ "$(fleet_schedule_platform)" = systemd ] ||
        [ "$(fleet_schedule_last_state "$1")" = loaded ]; then
        fleet_trigger_detach "$1" "fleet-$1 is installed and enabled but its scheduler is unreachable from here"
      else
        printf 'roundhouse: fleet-%s cannot be reached and was not last seen running; stamped, not started\n' "$1"
      fi
      ;;
    disabled | unloaded)
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
  fleet_trigger_stamp || {
    printf 'roundhouse: could not write the trigger stamp at %s\n' \
      "$(fleet_trigger_stamp_path)" >&2
    exit 73
  }
  fleet_trigger_kick "$trigger_mode"
)

# --- the running pass's re-loop -------------------------------------------------

fleet_trigger_converge() {
  # fleet_trigger_converge PASS-FUNCTION — run one pass, then again in-process
  # while the dirty stamp moved since that pass began. Called by
  # fleet_run_command under its lock, with its run_tmp and run_mode.
  #
  # A trigger that lands while a pass holds the lock starts a second run that
  # finds the lock and exits, so the trigger rides the stamp instead. Bounded —
  # three extra passes — so a trigger storm cannot pin the lock; anything later
  # waits for the next scheduled run. An extra pass is a FAST one, floor
  # included: a trigger says "go look", and repeating a full pass's
  # marketplace refresh and package updates is not looking.
  #
  # Each pass gets its own run_tmp and its own alert ledger: a re-run pass that
  # inherited the previous pass's `raised` lines would keep an alert its own
  # check no longer raises. Each pass runs with errexit ON — `PASS || …` would
  # switch it off for the whole body — and the return status is the WORST of
  # the passes, so a later clean pass does not launder an earlier hold.
  converge_root=$run_tmp
  converge_extra=0
  converge_status=0
  converge_errexit=false
  case $- in *e*) converge_errexit=true ;; esac
  while :; do
    converge_seen=$(fleet_trigger_stamp_state)
    mkdir -p "$converge_root/pass-$converge_extra"
    : >"$converge_root/pass-$converge_extra/alert-ledger"
    set +e
    (
      set -e
      run_tmp="$converge_root/pass-$converge_extra"
      run_ledger="$run_tmp/alert-ledger"
      "$1"
    )
    converge_pass_status=$?
    [ "$converge_errexit" != true ] || set -e
    [ "$converge_pass_status" -le "$converge_status" ] ||
      converge_status=$converge_pass_status
    [ "$converge_extra" -lt 3 ] || break
    [ "$(fleet_trigger_stamp_state)" != "$converge_seen" ] || break
    converge_extra=$((converge_extra + 1))
    run_mode=fast
    printf 'roundhouse: a trigger arrived during the pass; converging again in-process (%s of 3)\n' \
      "$converge_extra"
  done
  return "$converge_status"
}

# --- the job definitions -------------------------------------------------------

fleet_schedule_interval() {
  # fast|full -> the job interval in seconds, from the ONE cadence source the
  # run itself uses (fleet_run_interval_seconds): the store's policy keys,
  # jittered from the host NAME, so the scheduler and the policy cannot
  # drift apart and two hosts do not fire on the same minute. The fold is the
  # working copy's, like fleet_run_stale_after's; a store with no policy reads
  # the built-in defaults (20 ± 5 min, 12 h ± 90 min).
  interval_host=$(fleet_host_name 2>/dev/null) || interval_host=
  interval_fold=$(fleet_fold "$(fleet_store_path)" "$interval_host" 2>/dev/null) ||
    interval_fold=
  [ -n "$interval_fold" ] || interval_fold='{}'
  fleet_run_interval_seconds "$interval_fold" "$interval_host" "$1"
}

fleet_schedule_xml_text() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

fleet_schedule_plist_render() {
  # fleet_schedule_plist_render fast|full — the LaunchAgent, in the shape the
  # fleet's hosts already carry. `$HOME` stays literal in the command (zsh
  # expands it); the log path is absolute because launchd expands nothing.
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
  # Monotonic, like launchd's StartInterval and from the same interval: the
  # first run one interval after the user manager starts, then one interval
  # after each run began. Monotonic time does not advance while the machine
  # sleeps, so a laptop resumes its cadence at wake rather than storming.
  render_interval=$(fleet_schedule_interval "$1")
  cat <<UNIT
[Unit]
Description=roundhouse fleet-run --$1 every ${render_interval}s

[Timer]
OnBootSec=${render_interval}s
OnUnitActiveSec=${render_interval}s
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
    # Kept, never discarded: the replaced definition survives as .replaced.
    cp "$1" "$1.replaced" 2>/dev/null &&
      printf 'roundhouse: the previous definition is kept as %s.replaced\n' "$1" >&2 || :
  fi
  mkdir -p "$(dirname "$1")" || return 1
  cp "$2" "$1.next.$$" && chmod 0644 "$1.next.$$" && mv -f "$1.next.$$" "$1" || {
    rm -f "$1.next.$$"
    return 1
  }
  printf 'written\n'
}

fleet_schedule_legacy_plists() {
  # The superseded entries fleet-update's absorb rule names, where they exist:
  # the old autoupdate agent and the one-plist fleet agent.
  for legacy_label in com.novotnyllc.roundhouse.autoupdate com.novotnyllc.roundhouse.fleet; do
    [ ! -f "$HOME/Library/LaunchAgents/$legacy_label.plist" ] ||
      printf '%s\n' "$HOME/Library/LaunchAgents/$legacy_label.plist"
  done
}

fleet_schedule_install_launchd() {
  install_domain=$(fleet_schedule_gui_domain)
  install_has_domain=true
  launchctl print "$install_domain" >/dev/null 2>&1 || install_has_domain=false
  install_rc=0
  # The new pair FIRST: a superseded entry is retired only once its
  # replacement is on disk, so a failure here leaves the host scheduled.
  for install_mode in $fleet_schedule_modes; do
    install_plist=$(fleet_schedule_def_path "$install_mode")
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
    # Re-probed afterwards, because a job can stay LOADED through a disable,
    # and bootstrapping a loaded job is an error.
    if [ "$install_state" = disabled ]; then
      launchctl enable "$install_domain/$install_label" >/dev/null 2>&1 || {
        printf 'roundhouse: launchctl enable %s/%s failed\n' "$install_domain" "$install_label" >&2
        return 70
      }
      printf 'fleet-%s: re-enabled (it was disabled)\n' "$install_mode"
      install_state=$(fleet_schedule_job_state "$install_mode")
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
      fleet_schedule_job_state "$install_mode" >/dev/null
    fi
    printf 'fleet-%s: %s %s\n' "$install_mode" "$install_result" "$install_plist"
  done
  # Absorb, never duplicate (fleet-update): only now, with the new pair in
  # place. Renamed, not deleted, so the superseded job can be restored.
  fleet_schedule_legacy_plists | while IFS= read -r install_legacy; do
    [ "$install_has_domain" != true ] ||
      launchctl bootout "$install_domain/$(basename "$install_legacy" .plist)" \
        >/dev/null 2>&1 || :
    install_absorbed="$install_legacy.absorbed"
    [ ! -e "$install_absorbed" ] || install_absorbed="$install_legacy.absorbed.$(date +%Y%m%dT%H%M%S)"
    mv "$install_legacy" "$install_absorbed" &&
      printf 'roundhouse: absorbed the superseded %s entry (kept as %s)\n' \
        "$(basename "$install_legacy" .plist)" "$install_absorbed"
  done
  return "$install_rc"
}

fleet_schedule_install_systemd() {
  install_dir=$(fleet_schedule_unit_dir)
  install_changed=false
  for install_mode in $fleet_schedule_modes; do
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
  for install_mode in $fleet_schedule_modes; do
    install_timer="$(fleet_schedule_unit "$install_mode").timer"
    if [ "$(systemctl --user is-enabled "$install_timer" 2>/dev/null || :)" = enabled ] &&
      systemctl --user is-active --quiet "$install_timer" 2>/dev/null; then
      [ "$install_changed" != true ] ||
        systemctl --user restart "$install_timer" >/dev/null 2>&1 || :
    else
      # The ONE place a disabled timer is re-enabled: the operator asked.
      systemctl --user enable --now "$install_timer" >/dev/null 2>&1 || {
        printf 'roundhouse: systemctl --user enable --now %s failed\n' "$install_timer" >&2
        return 70
      }
      printf 'fleet-%s: enabled and started %s\n' "$install_mode" "$install_timer"
    fi
    fleet_schedule_job_state "$install_mode" >/dev/null
  done
  fleet_schedule_lingers || {
    printf 'roundhouse: the timers are enabled, but this user manager does not linger, so they stop with the last login session and triggers fall back to a detached pass; run `loginctl enable-linger %s`\n' \
      "$(id -un)" >&2
    return 75
  }
}

fleet_schedule_status() {
  # One line per job: installed or missing, enabled or disabled, loaded or
  # not, and whether the definition on disk is the one `install` writes.
  status_dir=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule.XXXXXX") || return 1
  for status_mode in $fleet_schedule_modes; do
    status_path=$(fleet_schedule_def_path "$status_mode")
    case $(fleet_schedule_platform) in
      launchd) fleet_schedule_plist_render "$status_mode" >"$status_dir/def" ;;
      *) fleet_schedule_timer_render "$status_mode" >"$status_dir/def" ;;
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
      *)
        status_last=$(fleet_schedule_last_state "$status_mode")
        status_text="installed, scheduler unreachable (no GUI domain, or no lingering user manager); last seen ${status_last:-never}"
        ;;
    esac
    printf 'fleet-%s: %s%s — %s\n' "$status_mode" "$status_text" "$status_def" "$status_path"
  done
  [ ! -e "$(fleet_schedule_optout_path)" ] ||
    printf 'this host is opted out of scheduling (fleet-schedule uninstall); triggers only stamp\n'
  rm -rf "$status_dir"
}

fleet_schedule_uninstall() {
  for uninstall_mode in $fleet_schedule_modes; do
    uninstall_def=$(fleet_schedule_def_path "$uninstall_mode")
    case $(fleet_schedule_platform) in
      launchd)
        launchctl bootout "$(fleet_schedule_gui_domain)/$(fleet_schedule_label "$uninstall_mode")" \
          >/dev/null 2>&1 || :
        uninstall_files=$uninstall_def
        ;;
      systemd)
        ! fleet_schedule_user_manager ||
          systemctl --user disable --now "$(fleet_schedule_unit "$uninstall_mode").timer" \
            >/dev/null 2>&1 || :
        uninstall_files="$uninstall_def ${uninstall_def%.timer}.service"
        ;;
    esac
    uninstall_any=false
    for uninstall_file in $uninstall_files; do
      [ -f "$uninstall_file" ] || continue
      rm -f "$uninstall_file"
      uninstall_any=true
      printf 'fleet-%s: removed %s\n' "$uninstall_mode" "$uninstall_file"
    done
    [ "$uninstall_any" = true ] || printf 'fleet-%s: not installed\n' "$uninstall_mode"
  done
  [ "$(fleet_schedule_platform)" != systemd ] || ! fleet_schedule_user_manager ||
    systemctl --user daemon-reload >/dev/null 2>&1 || :
  rm -f "$(fleet_schedule_marker)" "$(fleet_schedule_legacy_state_path)"
  for uninstall_mode in $fleet_schedule_modes; do
    rm -f "$(fleet_schedule_state_path "$uninstall_mode")"
  done
  # The opt-out: from here on a trigger stamps and starts nothing, and a pass
  # raises no schedule alert, until `install` is run again.
  mkdir -p "$(dirname "$(fleet_schedule_optout_path)")"
  printf 'uninstalled_at: %s\n' "$(fleet_now)" >"$(fleet_schedule_optout_path)"
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
    status) fleet_schedule_status ;;
    uninstall) fleet_schedule_uninstall ;;
    install)
      [ -x "$HOME/.local/bin/roundhouse" ] || {
        printf 'roundhouse: %s is not installed; run `roundhouse launcher-install` first — the scheduled jobs run that shim\n' \
          "$HOME/.local/bin/roundhouse" >&2
        exit 69
      }
      # A superseded job that WORKS is not retired for a pair that would only
      # fail: the new jobs converge the fleet store, so it must be enrolled.
      if [ -n "$(fleet_schedule_legacy_plists)" ] &&
        ! fleet_vcs_store_ready "$(fleet_store_path)" >/dev/null 2>&1; then
        printf 'roundhouse: a superseded scheduler entry is still installed (%s) and this host has no enrolled fleet store for the new jobs to converge; enroll it (roundhouse fleet-init / fleet-enroll), then re-run install. Nothing was changed.\n' \
          "$(fleet_schedule_legacy_plists | tr '\n' ' ')" >&2
        exit 69
      fi
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
          rm -f "$(fleet_schedule_optout_path)"
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
  # `schedule-disabled` and `schedule-missing` are store-scoped CONDITIONS
  # (lib/fleet-alerts.sh), one keyed alert per job (`…--fleet-fast.yaml`):
  # this check sets each while it holds and clears it the pass it ends — the
  # job re-enabled or reinstalled, or the host opted out with
  # `fleet-schedule uninstall`.
  #
  # "Missing" needs evidence the host is meant to be scheduled — the install
  # marker, or the other job still present — so a host whose operator never
  # scheduled it raises nothing. An UNREACHABLE scheduler (no GUI domain over
  # SSH: the ordinary state of a pass a trigger started) decides nothing, so
  # both alerts are left as they stand.
  case $(fleet_schedule_platform) in launchd | systemd) ;; *) return 0 ;; esac
  check_optout=false
  [ ! -e "$(fleet_schedule_optout_path)" ] || check_optout=true
  check_fast=$(fleet_schedule_job_state fast)
  check_full=$(fleet_schedule_job_state full)
  for check_mode in $fleet_schedule_modes; do
    if [ "$check_mode" = fast ]; then
      check_state=$check_fast
      check_other=$check_full
    else
      check_state=$check_full
      check_other=$check_fast
    fi
    [ "$check_state" != unavailable ] || [ "$check_optout" = true ] || continue
    check_disabled=false
    check_missing=false
    if [ "$check_optout" != true ]; then
      case $check_state in
        disabled) check_disabled=true ;;
        missing)
          if [ -f "$(fleet_schedule_marker)" ] || [ "$check_other" != missing ]; then
            check_missing=true
          fi
          ;;
      esac
    fi
    [ "$check_disabled" != true ] ||
      printf 'roundhouse: the fleet-%s scheduled job is disabled; a pass never re-enables it (schedule-disabled alert)\n' \
        "$check_mode" >&2
    [ "$check_missing" != true ] ||
      printf 'roundhouse: the fleet-%s scheduled job is missing (schedule-missing alert)\n' \
        "$check_mode" >&2
    fleet_alert_set "$1" "$2" schedule-disabled "fleet-$check_mode" "$check_disabled" \
      "the fleet-$check_mode scheduled job on $2 is disabled; passes will not re-enable it. Run \`roundhouse fleet-schedule install\` on $2 to re-enable it, or \`roundhouse fleet-schedule uninstall\` if it should not be scheduled" ||
      :
    fleet_alert_set "$1" "$2" schedule-missing "fleet-$check_mode" "$check_missing" \
      "the fleet-$check_mode scheduled job on $2 is missing; run \`roundhouse fleet-schedule install\` on $2" ||
      :
  done
}
