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

fleet_schedule_def_paths() {
  # fast|full -> EVERY file the job is made of, one per line: the plist, or
  # the systemd `.service` and its `.timer`. A job missing any of them is
  # missing — a timer whose service is gone fires into nothing.
  case $(fleet_schedule_platform) in
    launchd) fleet_schedule_def_path "$1" ;;
    systemd)
      printf '%s/%s.service\n' "$(fleet_schedule_unit_dir)" "$(fleet_schedule_unit "$1")"
      fleet_schedule_def_path "$1"
      ;;
  esac
}

fleet_schedule_render() {
  # fleet_schedule_render MODE PATH — what `install` writes at PATH, one of
  # MODE's fleet_schedule_def_paths.
  case $2 in
    *.plist) fleet_schedule_plist_render "$1" ;;
    *.service) fleet_schedule_service_render "$1" ;;
    *.timer) fleet_schedule_timer_render "$1" ;;
    *) return 1 ;;
  esac
}

fleet_schedule_defs_present() {
  # True when every one of MODE's definition files exists.
  defs_present_list=$(fleet_schedule_def_paths "$1")
  [ -n "$defs_present_list" ] || return 1
  while IFS= read -r defs_present_path; do
    [ -f "$defs_present_path" ] || return 1
  done <<EOF_DEFS
$defs_present_list
EOF_DEFS
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
  # The last state OBSERVED for MODE (never `unavailable`), or nothing.
  head -n 1 "$(fleet_schedule_state_path "$1")" 2>/dev/null || :
}

fleet_schedule_probe() {
  # fleet_schedule_probe fast|full -> one word, read-only:
  #
  #   missing      a job definition is not on disk (the plist; on systemd the
  #                `.timer` OR its `.service`)
  #   disabled     the operator disabled it
  #   unloaded     present and not disabled, but not loaded/active
  #   loaded       present, enabled, loaded (launchd) or active (systemd timer)
  #   unavailable  installed, but there is no GUI domain / reachable, lingering
  #                user manager to ask or to start it in. On systemd this means
  #                ENABLED (the timers.target.wants link says so); on launchd
  #                the enablement is unknown and the last observed state rules.
  fleet_schedule_defs_present "$1" || {
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

fleet_trigger_runner() {
  # The `roundhouse` a detached pass runs: this one (a self-check may stand in
  # its own).
  if fleet_test_hook "${ROUNDHOUSE_FLEET_TRIGGER_RUNNER:-}"; then
    printf '%s\n' "$ROUNDHOUSE_FLEET_TRIGGER_RUNNER"
  else
    printf '%s/roundhouse\n' "$script_dir"
  fi
}

fleet_trigger_detach() {
  # fleet_trigger_detach fast|full REASON — the unreachable-scheduler
  # fallback. No `setsid`: macOS has none. `nohup` with every stream closed is
  # what lets an SSH session that started it end without waiting on it or
  # taking it down.
  trigger_runner=$(fleet_trigger_runner)
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
  #
  # It leaves the stamp its LAST comparison read in converge_handoff_stamp,
  # for fleet_trigger_handoff once the lock is released.
  converge_root=$run_tmp
  converge_extra=0
  converge_handoff_stamp=
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
    converge_now=$(fleet_trigger_stamp_state)
    converge_handoff_stamp=$converge_now
    [ "$converge_extra" -lt 3 ] || break
    [ "$converge_now" != "$converge_seen" ] || break
    converge_extra=$((converge_extra + 1))
    run_mode=fast
    printf 'roundhouse: a trigger arrived during the pass; converging again in-process (%s of 3)\n' \
      "$converge_extra"
  done
  return "$converge_status"
}

fleet_trigger_handoff() {
  # fleet_trigger_handoff STAMP — the last word of a run, called by
  # fleet_run_command AFTER it released the run lock, with the stamp the
  # loop's final comparison read.
  #
  # A trigger that lands after that comparison but before the release is
  # otherwise lost: its own run found the lock and exited, and on systemd a
  # `start` of a oneshot that is still active queues nothing. So the stamp is
  # compared once more with the lock free, and a move starts ONE detached
  # fast pass. That pass takes the lock like any run — two follow-ups, or a
  # follow-up and a scheduled run, cannot both run a pass; the loser exits.
  [ "$(fleet_trigger_stamp_state)" != "$1" ] || return 0
  handoff_runner=$(fleet_trigger_runner)
  nohup "$handoff_runner" fleet-run --fast </dev/null >/dev/null 2>&1 &
  printf 'roundhouse: a trigger arrived as this run released its lock; started a detached fleet-run --fast\n'
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

fleet_schedule_write_definition() {
  # fleet_schedule_write_definition PATH RENDERED-FILE — put one definition in
  # place. An existing one is KEPT as PATH.replaced first, and a backup that
  # cannot be made is a replacement that does not happen: the existing
  # definition stays exactly as it was and this fails.
  if [ -f "$1" ]; then
    cp -p "$1" "$1.replaced" 2>/dev/null && cmp -s "$1" "$1.replaced" || {
      printf 'roundhouse: could not keep the previous definition as %s.replaced; %s was left in place, unchanged\n' \
        "$1" "$1" >&2
      return 1
    }
    printf 'roundhouse: the previous definition is kept as %s.replaced\n' "$1" >&2
  fi
  mkdir -p "$(dirname "$1")" || return 1
  write_next=$(mktemp "$1.next.XXXXXX") || return 1
  cp "$2" "$write_next" && chmod 0644 "$write_next" && mv -f "$write_next" "$1" || {
    rm -f "$write_next"
    return 1
  }
}

fleet_schedule_legacy_plists() {
  # The superseded entries fleet-update's absorb rule names, where they exist:
  # the old autoupdate agent and the one-plist fleet agent.
  for legacy_label in com.novotnyllc.roundhouse.autoupdate com.novotnyllc.roundhouse.fleet; do
    [ ! -f "$HOME/Library/LaunchAgents/$legacy_label.plist" ] ||
      printf '%s\n' "$HOME/Library/LaunchAgents/$legacy_label.plist"
  done
}

fleet_schedule_lingers_preflight() {
  # Before ANY unit is written: a user manager that does not linger stops
  # every timer with the last login session, so installing them would only
  # schedule jobs that die when the operator logs out.
  fleet_schedule_lingers && return 0
  printf 'roundhouse: this user manager does not linger, so its timers would stop with the last login session; run `loginctl enable-linger %s`, then re-run `roundhouse fleet-schedule install`. Nothing was written.\n' \
    "$(id -un)" >&2
  return 75
}

fleet_schedule_manager_unreachable_note() {
  # Distinct from lingering: the account lingers (or logind cannot say), but
  # `systemctl --user` reaches no running manager — WSL without systemd, or a
  # manager that has not started.
  printf 'roundhouse: the units are written but no systemd user manager is reachable (`systemctl --user`); under WSL enable systemd in /etc/wsl.conf (`[boot] systemd=true`) and restart the distribution, otherwise start the user manager, then re-run `roundhouse fleet-schedule install`\n' >&2
}

# --- install and uninstall ride the sealed-plan pipeline -----------------------
#
# AGENTS.md: every mutation rides the sealed-plan pipeline, and these two are
# mutations of this host. So `install` and `uninstall` never act on what they
# see; they PLAN from what the collector observed, seal that plan, and apply
# only the sealed plan (local_plan_seal_apply, the helper launcher-install
# uses too):
#
#   observe   the collector's `agent_artifact roundhouse:schedule` record
#             (fleet_schedule_observe): every definition file's sha256 or its
#             absence, each job's loaded/disabled/enabled/active state, the
#             superseded entries, the scheduler's reachability;
#   plan      fleet_schedule_plan_steps turns that record into the EXACT
#             steps — each file to write (with its rendered sha256), keep,
#             remove or absorb, and each scheduler command, in order;
#   seal      the record is the plan's precondition, and the target's
#             hostname and user are bound to the configured local machine;
#   recheck   a fresh collect must match the sealed preconditions immediately
#             before anything changes — an operator who disabled a job or
#             edited a definition in between gets a refusal, not a surprise;
#   apply     fleet_schedule_execute performs exactly the sealed steps, a
#             rendered definition only when it still hashes to the sealed
#             digest, a command only when it is one this host's jobs own;
#   verify    apply's post-change collect must show every written file at its
#             sealed digest and every removed one gone, and `status` must
#             then report the jobs as the plan left them.
#
# `status` stays read-only and unsealed.

fleet_schedule_observe() {
  # One JSON object, read-only: the collector's roundhouse:schedule record.
  observe_platform=$(fleet_schedule_platform)
  observe_domain=$(fleet_schedule_gui_domain)
  observe_reachable=false
  case $observe_platform in
    launchd) ! launchctl print "$observe_domain" >/dev/null 2>&1 || observe_reachable=true ;;
    systemd) ! fleet_schedule_user_manager || observe_reachable=true ;;
    *)
      printf 'roundhouse: fleet-schedule observes launchd or systemd only\n' >&2
      return 69
      ;;
  esac
  observe_lingers=true
  [ "$observe_platform" != systemd ] || fleet_schedule_lingers || observe_lingers=false
  observe_optout=false
  [ ! -e "$(fleet_schedule_optout_path)" ] || observe_optout=true
  observe_files='[]'
  observe_jobs='[]'
  for observe_mode in $fleet_schedule_modes; do
    observe_paths=$(fleet_schedule_def_paths "$observe_mode")
    while IFS= read -r observe_path; do
      [ -n "$observe_path" ] || continue
      observe_digest=
      [ ! -f "$observe_path" ] || observe_digest=$(sha256_file "$observe_path")
      observe_files=$(printf '%s\n' "$observe_files" | jq -c --arg mode "$observe_mode" \
        --arg form "${observe_path##*.}" --arg path "$observe_path" --arg digest "$observe_digest" \
        '. + [{mode:$mode,form:$form,path:$path,
          digest:(if $digest == "" then null else $digest end)}]')
    done <<EOF_OBSERVE
$observe_paths
EOF_OBSERVE
    observe_loaded=false
    observe_disabled=false
    observe_enabled=false
    observe_active=false
    if [ "$observe_reachable" = true ]; then
      case $observe_platform in
        launchd)
          observe_label=$(fleet_schedule_label "$observe_mode")
          ! launchctl print "$observe_domain/$observe_label" >/dev/null 2>&1 ||
            observe_loaded=true
          ! launchctl print-disabled "$observe_domain" 2>/dev/null |
            grep -Eq "\"$observe_label\" => (disabled|true)" || observe_disabled=true
          ;;
        systemd)
          observe_timer="$(fleet_schedule_unit "$observe_mode").timer"
          [ "$(systemctl --user is-enabled "$observe_timer" 2>/dev/null || :)" != enabled ] ||
            observe_enabled=true
          ! systemctl --user is-active --quiet "$observe_timer" 2>/dev/null ||
            observe_active=true
          ;;
      esac
    fi
    observe_jobs=$(printf '%s\n' "$observe_jobs" | jq -c --arg mode "$observe_mode" \
      --arg state "$(fleet_schedule_probe "$observe_mode")" \
      --argjson loaded "$observe_loaded" --argjson disabled "$observe_disabled" \
      --argjson enabled "$observe_enabled" --argjson active "$observe_active" \
      '. + [{mode:$mode,state:$state,loaded:$loaded,disabled:$disabled,
        enabled:$enabled,active:$active}]')
  done
  observe_legacy='[]'
  if [ "$observe_platform" = launchd ]; then
    observe_legacy_list=$(fleet_schedule_legacy_plists)
    while IFS= read -r observe_path; do
      [ -n "$observe_path" ] || continue
      observe_legacy=$(printf '%s\n' "$observe_legacy" | jq -c --arg path "$observe_path" \
        --arg digest "$(sha256_file "$observe_path")" '. + [{path:$path,digest:$digest}]')
    done <<EOF_OBSERVE
$observe_legacy_list
EOF_OBSERVE
  fi
  jq -cn --arg platform "$observe_platform" --arg domain "$observe_domain" \
    --argjson reachable "$observe_reachable" --argjson lingers "$observe_lingers" \
    --argjson opted_out "$observe_optout" --argjson files "$observe_files" \
    --argjson jobs "$observe_jobs" --argjson legacy "$observe_legacy" \
    '{id:"roundhouse:schedule",artifact_kind:"schedule",platform:$platform,
      domain:(if $platform == "launchd" then $domain else null end),
      scheduler_reachable:$reachable,lingers:$lingers,opted_out:$opted_out,
      files:$files,jobs:$jobs,legacy:$legacy}'
}

fleet_schedule_plan_steps() {
  # fleet_schedule_plan_steps install|uninstall RECORD-JSON WORKDIR — the
  # sealed plan's exact steps, as one JSON array, decided from the OBSERVED
  # record alone (never a fresh look: the record is what gets sealed and
  # rechecked). A definition that exists and differs is reported with its
  # diff here, before anything is sealed, so a hand edit is never replaced
  # silently.
  plan_action=$1
  plan_record=$2
  plan_work=$3
  plan_platform=$(printf '%s\n' "$plan_record" | jq -r '.platform')
  plan_reachable=$(printf '%s\n' "$plan_record" | jq -r '.scheduler_reachable')
  plan_domain=$(fleet_schedule_gui_domain)
  plan_steps='[]'
  plan_changed=false
  plan_add() {
    plan_steps=$(printf '%s\n' "$plan_steps" | jq -c --argjson step "$1" '. + [$step]')
  }
  plan_run() {
    # plan_run MODE REQUIRED ARG... — one scheduler command.
    plan_run_mode=$1
    plan_run_required=$2
    shift 2
    # One argument per line, read back with -R: jq takes a `--user` among
    # `--args` for an option of its own.
    plan_run_argv=$(printf '%s\n' "$@" | jq -Rnc '[inputs]')
    plan_add "$(jq -cn --arg mode "$plan_run_mode" --argjson required "$plan_run_required" \
      --argjson argv "$plan_run_argv" '{action:"run",mode:$mode,required:$required,argv:$argv}')"
  }
  plan_job() {
    printf '%s\n' "$plan_record" | jq -r --arg mode "$1" --arg key "$2" \
      'first(.jobs[] | select(.mode == $mode)) | .[$key]'
  }
  plan_mode_files() {
    printf '%s\n' "$plan_record" | jq -c --arg mode "$1" '.files[] | select(.mode == $mode)'
  }
  for plan_mode in $fleet_schedule_modes; do
    plan_mode_written=false
    plan_files=$(plan_mode_files "$plan_mode")
    while IFS= read -r plan_file; do
      [ -n "$plan_file" ] || continue
      plan_path=$(printf '%s\n' "$plan_file" | jq -r '.path')
      plan_form=$(printf '%s\n' "$plan_file" | jq -r '.form')
      plan_before=$(printf '%s\n' "$plan_file" | jq -r '.digest // empty')
      if [ "$plan_action" = uninstall ]; then
        [ -z "$plan_before" ] ||
          plan_add "$(jq -cn --arg mode "$plan_mode" --arg form "$plan_form" \
            --arg path "$plan_path" --arg before "$plan_before" \
            '{action:"remove",mode:$mode,form:$form,path:$path,before:$before}')"
        continue
      fi
      plan_rendered="$plan_work/${plan_path##*/}"
      fleet_schedule_render "$plan_mode" "$plan_path" >"$plan_rendered" || return 70
      plan_digest=$(sha256_file "$plan_rendered")
      if [ -n "$plan_before" ] && [ -f "$plan_path" ] &&
        fleet_schedule_same "$plan_path" "$plan_rendered"; then
        plan_add "$(jq -cn --arg mode "$plan_mode" --arg form "$plan_form" \
          --arg path "$plan_path" --arg digest "$plan_before" \
          '{action:"keep",mode:$mode,form:$form,path:$path,digest:$digest}')"
        continue
      fi
      if [ -n "$plan_before" ] && [ -f "$plan_path" ]; then
        printf 'roundhouse: %s differs from the definition fleet-schedule writes; replacing it:\n' \
          "$plan_path" >&2
        diff -u "$plan_path" "$plan_rendered" | sed 's/^/  /' >&2 || :
      fi
      plan_add "$(jq -cn --arg mode "$plan_mode" --arg form "$plan_form" \
        --arg path "$plan_path" --arg digest "$plan_digest" --arg before "$plan_before" \
        '{action:"write",mode:$mode,form:$form,path:$path,digest:$digest,
          before:(if $before == "" then null else $before end)}')"
      plan_mode_written=true
      plan_changed=true
    done <<EOF_PLAN
$plan_files
EOF_PLAN
    [ "$plan_reachable" = true ] || continue
    case $plan_platform:$plan_action in
      launchd:install)
        # The ONE place a disabled job is re-enabled: the operator asked for
        # it. A job can stay LOADED through a disable, and bootstrapping a
        # loaded job is an error, so loaded-ness is the observed flag, not a
        # guess from the disable.
        plan_label=$(fleet_schedule_label "$plan_mode")
        [ "$(plan_job "$plan_mode" disabled)" != true ] ||
          plan_run "$plan_mode" true launchctl enable "$plan_domain/$plan_label"
        if [ "$(plan_job "$plan_mode" loaded)" = true ] && [ "$plan_mode_written" = true ]; then
          plan_run "$plan_mode" false launchctl bootout "$plan_domain/$plan_label"
        fi
        if [ "$(plan_job "$plan_mode" loaded)" != true ] || [ "$plan_mode_written" = true ]; then
          plan_run "$plan_mode" true launchctl bootstrap "$plan_domain" \
            "$(fleet_schedule_def_path "$plan_mode")"
        fi
        ;;
      launchd:uninstall)
        [ "$(plan_job "$plan_mode" loaded)" != true ] ||
          plan_run "$plan_mode" false launchctl bootout \
            "$plan_domain/$(fleet_schedule_label "$plan_mode")"
        ;;
      systemd:uninstall)
        if [ "$(plan_job "$plan_mode" enabled)" = true ] ||
          [ "$(plan_job "$plan_mode" active)" = true ]; then
          plan_run "$plan_mode" false systemctl --user disable --now \
            "$(fleet_schedule_unit "$plan_mode").timer"
          plan_changed=true
        fi
        ;;
    esac
  done
  case $plan_platform:$plan_action:$plan_reachable in
    launchd:install:*)
      # Absorb, never duplicate (fleet-update): only after the new pair, and
      # renamed BEFORE it is unloaded — a rename that fails leaves the
      # superseded entry on disk and running. The new name is sealed too.
      plan_legacy=$(printf '%s\n' "$plan_record" | jq -c '.legacy[]')
      while IFS= read -r plan_file; do
        [ -n "$plan_file" ] || continue
        plan_path=$(printf '%s\n' "$plan_file" | jq -r '.path')
        plan_to="$plan_path.absorbed"
        [ ! -e "$plan_to" ] || plan_to="$plan_path.absorbed.$(date -u +%Y%m%dT%H%M%SZ)"
        plan_add "$(printf '%s\n' "$plan_file" | jq -c --arg to "$plan_to" \
          '{action:"absorb",path,before:.digest,to:$to}')"
        [ "$plan_reachable" != true ] ||
          plan_run legacy false launchctl bootout \
            "$plan_domain/$(basename "$plan_path" .plist)"
      done <<EOF_PLAN
$plan_legacy
EOF_PLAN
      ;;
    systemd:install:true)
      [ "$plan_changed" != true ] || plan_run all false systemctl --user daemon-reload
      for plan_mode in $fleet_schedule_modes; do
        plan_timer="$(fleet_schedule_unit "$plan_mode").timer"
        if [ "$(plan_job "$plan_mode" enabled)" = true ] &&
          [ "$(plan_job "$plan_mode" active)" = true ]; then
          [ "$plan_changed" != true ] ||
            plan_run "$plan_mode" false systemctl --user restart "$plan_timer"
        else
          # The ONE place a disabled timer is re-enabled: the operator asked.
          plan_run "$plan_mode" true systemctl --user enable --now "$plan_timer"
        fi
      done
      ;;
    systemd:uninstall:true)
      [ "$plan_changed" != true ] &&
        [ "$(printf '%s\n' "$plan_steps" | jq '[.[] | select(.action == "remove")] | length')" -eq 0 ] ||
        plan_run all false systemctl --user daemon-reload
      ;;
  esac
  printf '%s\n' "$plan_steps"
}

fleet_schedule_allowed_commands() {
  # The scheduler commands a sealed fleet-schedule step may run on THIS host:
  # its own two jobs (and the superseded entries) in its own domain, nothing
  # else. A JSON array of argv arrays.
  allowed_domain=$(fleet_schedule_gui_domain)
  {
    case $(fleet_schedule_platform) in
      launchd)
        for allowed_mode in $fleet_schedule_modes; do
          allowed_label=$(fleet_schedule_label "$allowed_mode")
          jq -cn --arg target "$allowed_domain/$allowed_label" \
            '["launchctl","enable",$target], ["launchctl","bootout",$target]'
          jq -cn --arg domain "$allowed_domain" --arg plist "$(fleet_schedule_def_path "$allowed_mode")" \
            '["launchctl","bootstrap",$domain,$plist]'
        done
        for allowed_label in com.novotnyllc.roundhouse.autoupdate com.novotnyllc.roundhouse.fleet; do
          jq -cn --arg target "$allowed_domain/$allowed_label" '["launchctl","bootout",$target]'
        done
        ;;
      systemd)
        jq -cn '["systemctl","--user","daemon-reload"]'
        for allowed_mode in $fleet_schedule_modes; do
          jq -cn --arg timer "$(fleet_schedule_unit "$allowed_mode").timer" '
            ["systemctl","--user","restart",$timer],
            ["systemctl","--user","enable","--now",$timer],
            ["systemctl","--user","disable","--now",$timer]'
        done
        ;;
    esac
  } | jq -cs .
}

fleet_schedule_execute() (
  # fleet_schedule_execute OPERATION.json — apply-plan's executor for the
  # sealed `roundhouse:schedule` operation: its steps, exactly and in order.
  # Every path is re-derived and must be one this host's jobs own; a written
  # definition is rendered again and must hash to the sealed digest; a command
  # must be on fleet_schedule_allowed_commands. Anything else refuses.
  execute_op=$1
  jq -e '(.argv | length) == 3 and .argv[0] == "roundhouse" and
    .argv[1] == "fleet-schedule" and (.argv[2] | IN("install","uninstall")) and
    (.steps | type == "array")' "$execute_op" >/dev/null || {
    printf 'roundhouse: unsafe fleet-schedule plan operation\n' >&2
    exit 64
  }
  execute_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule-apply.XXXXXX") || exit 73
  trap 'rm -rf "$execute_tmp"' EXIT HUP INT TERM
  execute_allowed=$(fleet_schedule_allowed_commands)
  execute_legacy=$(printf '%s\n' \
    "$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.autoupdate.plist" \
    "$HOME/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist" | jq -Rnc '[inputs]')
  execute_count=$(jq '.steps | length' "$execute_op")
  execute_index=0
  while [ "$execute_index" -lt "$execute_count" ]; do
    jq -c ".steps[$execute_index]" "$execute_op" >"$execute_tmp/step.json"
    execute_index=$((execute_index + 1))
    execute_action=$(jq -r '.action' "$execute_tmp/step.json")
    case $execute_action in
      write | keep | remove)
        execute_mode=$(jq -r '.mode' "$execute_tmp/step.json")
        execute_path=$(jq -r '.path' "$execute_tmp/step.json")
        case $execute_mode in fast | full) ;; *) exit 64 ;; esac
        fleet_schedule_def_paths "$execute_mode" | grep -Fqx -- "$execute_path" &&
          [ "${execute_path##*.}" = "$(jq -r '.form' "$execute_tmp/step.json")" ] || {
          printf 'roundhouse: a sealed fleet-schedule step names %s, which is not a fleet-%s definition on this host\n' \
            "$execute_path" "$execute_mode" >&2
          exit 64
        }
        case $execute_action in
          write)
            fleet_schedule_render "$execute_mode" "$execute_path" >"$execute_tmp/definition" || exit 70
            [ "$(sha256_file "$execute_tmp/definition")" = "$(jq -r '.digest' "$execute_tmp/step.json")" ] || {
              printf 'roundhouse: the fleet-%s definition no longer renders to the sealed digest (the store policy or this host changed); create a new plan\n' \
                "$execute_mode" >&2
              exit 65
            }
            fleet_schedule_write_definition "$execute_path" "$execute_tmp/definition" || {
              printf 'roundhouse: could not write %s\n' "$execute_path" >&2
              exit 73
            }
            ;;
          remove)
            rm -f -- "$execute_path" || exit 73
            ;;
        esac
        ;;
      absorb)
        execute_path=$(jq -r '.path' "$execute_tmp/step.json")
        execute_to=$(jq -r '.to' "$execute_tmp/step.json")
        printf '%s\n' "$execute_legacy" | jq -e --arg path "$execute_path" 'index($path) != null' \
          >/dev/null || {
          printf 'roundhouse: a sealed absorb names %s, which is not a superseded entry\n' "$execute_path" >&2
          exit 64
        }
        case $execute_to in
          "$execute_path.absorbed" | "$execute_path".absorbed.[0-9]*) ;;
          *) exit 64 ;;
        esac
        [ ! -e "$execute_to" ] && mv "$execute_path" "$execute_to" 2>/dev/null || {
          printf 'roundhouse: could not keep the superseded %s as %s; it was left in place and loaded\n' \
            "$execute_path" "$execute_to" >&2
          exit 73
        }
        ;;
      run)
        execute_argv=$(jq -c '.argv' "$execute_tmp/step.json")
        printf '%s\n' "$execute_allowed" | jq -e --argjson argv "$execute_argv" \
          'index([$argv]) != null' >/dev/null || {
          printf 'roundhouse: a sealed fleet-schedule step runs %s, which is not a command this host'"'"'s jobs own\n' \
            "$execute_argv" >&2
          exit 64
        }
        set --
        while IFS= read -r execute_arg; do
          set -- "$@" "$execute_arg"
        done <<EOF_ARGV
$(jq -r '.argv[]' "$execute_tmp/step.json")
EOF_ARGV
        if ! "$@" >/dev/null 2>&1; then
          [ "$(jq -r '.required' "$execute_tmp/step.json")" != true ] || {
            printf 'roundhouse: %s failed\n' "$*" >&2
            exit 70
          }
        fi
        ;;
      *) exit 64 ;;
    esac
  done
)

fleet_schedule_status() {
  # One line per job: installed or missing, enabled or disabled, loaded or
  # not, and whether the definition on disk is the one `install` writes.
  #
  # Every file the job is made of is rendered and compared — on systemd both
  # the `.timer` and its `.service` — so a hand-edited or missing service
  # never hides behind a matching timer.
  status_dir=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule.XXXXXX") || return 1
  for status_mode in $fleet_schedule_modes; do
    status_paths=$(fleet_schedule_def_paths "$status_mode")
    status_present=0
    status_absent=
    status_differs=
    while IFS= read -r status_path; do
      [ -n "$status_path" ] || continue
      if [ ! -f "$status_path" ]; then
        status_absent="$status_absent ${status_path##*/}"
        continue
      fi
      status_present=$((status_present + 1))
      fleet_schedule_render "$status_mode" "$status_path" >"$status_dir/def"
      fleet_schedule_same "$status_path" "$status_dir/def" ||
        status_differs="$status_differs ${status_path##*/}"
    done <<EOF_STATUS
$status_paths
EOF_STATUS
    status_def=
    if [ "$status_present" -gt 0 ]; then
      if [ -n "$status_differs" ]; then
        status_def=", definition differs from what install writes (${status_differs# })"
      elif [ -z "$status_absent" ]; then
        status_def=', definition matches'
      fi
      [ -z "$status_absent" ] ||
        status_def="$status_def, definition incomplete (${status_absent# } absent)"
    fi
    status_path=$(printf '%s\n' "$status_paths" |
      awk 'NR > 1 { printf " and " } { printf "%s", $0 } END { print "" }')
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

fleet_schedule_report() {
  # fleet_schedule_report install|uninstall OPERATION-JSON REACHABLE — what the
  # applied plan did, one line per definition, read from the sealed steps.
  report_platform=$(fleet_schedule_platform)
  for report_mode in $fleet_schedule_modes; do
    report_steps=$(printf '%s\n' "$2" | jq -c --arg mode "$report_mode" \
      '[.steps[] | select(.mode == $mode)]')
    if [ "$1" = uninstall ]; then
      report_removed=$(printf '%s\n' "$report_steps" | jq -r '.[] | select(.action == "remove") | .path')
      if [ -z "$report_removed" ]; then
        printf 'fleet-%s: not installed\n' "$report_mode"
      else
        printf '%s\n' "$report_removed" | while IFS= read -r report_path; do
          printf 'fleet-%s: removed %s\n' "$report_mode" "$report_path"
        done
      fi
      continue
    fi
    ! printf '%s\n' "$report_steps" | jq -e 'any(.[]; .action == "run" and .argv[1] == "enable" and .argv[0] == "launchctl")' >/dev/null ||
      printf 'fleet-%s: re-enabled (it was disabled)\n' "$report_mode"
    printf '%s\n' "$report_steps" | jq -r '.[] | select(.action == "write" or .action == "keep") |
      [(if .action == "write" then "written" else "unchanged" end), .path] | @tsv' |
      while IFS="$(printf '\t')" read -r report_result report_path; do
        if [ "$report_platform" = launchd ]; then
          ! printf '%s\n' "$report_steps" | jq -e 'any(.[]; .action == "run" and .argv[1] == "bootstrap")' >/dev/null ||
            report_result="$report_result, loaded"
          if [ "$3" = true ]; then
            printf 'fleet-%s: %s %s\n' "$report_mode" "$report_result" "$report_path"
          else
            printf 'fleet-%s: %s %s; no GUI launchd domain for this user, so it loads at the next console login\n' \
              "$report_mode" "$report_result" "$report_path"
          fi
        else
          printf 'fleet-%s: %s %s\n' "$report_mode" "$report_result" "$report_path"
        fi
      done
    printf '%s\n' "$report_steps" | jq -r '.[] | select(.action == "run" and .argv[2] == "enable") | .argv[4]' |
      while IFS= read -r report_timer; do
        printf 'fleet-%s: enabled and started %s\n' "$report_mode" "$report_timer"
      done
  done
  printf '%s\n' "$2" | jq -r '.steps[] | select(.action == "absorb") | [.path, .to] | @tsv' |
    while IFS="$(printf '\t')" read -r report_path report_to; do
      printf 'roundhouse: absorbed the superseded %s entry (kept as %s)\n' \
        "$(basename "$report_path" .plist)" "$report_to"
    done
}

fleet_schedule_verify() {
  # fleet_schedule_verify install|uninstall REACHABLE — the post-change check
  # through `status`, the operator's own view: an install leaves every
  # definition matching (and loaded, where the scheduler could be reached);
  # an uninstall leaves both jobs missing.
  verify_status=$(fleet_schedule_status)
  for verify_mode in $fleet_schedule_modes; do
    verify_line=$(printf '%s\n' "$verify_status" | grep "^fleet-$verify_mode: " || true)
    verify_ok=true
    case $1 in
      install)
        case $verify_line in *', definition matches'*) ;; *) verify_ok=false ;; esac
        [ "$2" != true ] || case $verify_line in
          *': installed, enabled, loaded'*) ;;
          *) verify_ok=false ;;
        esac
        ;;
      uninstall)
        case $verify_line in "fleet-$verify_mode: missing"*) ;; *) verify_ok=false ;; esac
        ;;
    esac
    [ "$verify_ok" = true ] || {
      printf 'roundhouse: the sealed fleet-schedule %s applied, but status does not show it:\n%s\n' \
        "$1" "$verify_status" >&2
      return 70
    }
  done
}

fleet_schedule_sealed() (
  # fleet_schedule_sealed install|uninstall — observe, plan, seal, recheck,
  # apply, verify (the section comment above). Returns install's 0 or 75.
  sealed_action=$1
  check_mutation_config
  sealed_target=$(local_plan_target "fleet-schedule $sealed_action") || exit $?
  sealed_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule-plan.XXXXXX") || exit 73
  trap 'rm -rf "$sealed_tmp"' EXIT HUP INT TERM
  mkdir "$sealed_tmp/render" "$sealed_tmp/apply"
  ROUNDHOUSE_SCHEDULE_OBSERVE=1
  export ROUNDHOUSE_SCHEDULE_OBSERVE
  # The collect, seal and apply below stop on their first failed check through
  # errexit, so each runs as `( set -e; … )` with errexit off AROUND it: a
  # `… || …` would switch it off inside them too.
  set +e
  ( set -e; collect_command --target "$sealed_target" --section agents \
    --output "$sealed_tmp/planning.jsonl" )
  sealed_status=$?
  set -e
  [ "$sealed_status" -eq 0 ] || {
    printf 'roundhouse: could not observe this host'"'"'s scheduled jobs; nothing was changed\n' >&2
    exit 70
  }
  sealed_record=$(jq -c 'select(.kind == "agent_artifact" and .id == "roundhouse:schedule") | .data' \
    "$sealed_tmp/planning.jsonl")
  [ -n "$sealed_record" ] || {
    printf 'roundhouse: the collector returned no roundhouse:schedule record; nothing was changed\n' >&2
    exit 70
  }
  sealed_reachable=$(printf '%s\n' "$sealed_record" | jq -r '.scheduler_reachable')
  sealed_steps=$(fleet_schedule_plan_steps "$sealed_action" "$sealed_record" "$sealed_tmp/render") ||
    exit $?
  jq -n --arg target "$sealed_target" --arg action "$sealed_action" --argjson steps "$sealed_steps" '
    {domain:"agents",target:$target,operations:[{
      type:"agent-update",kind:"agent_artifact",id:"roundhouse:schedule",
      argv:["roundhouse","fleet-schedule",$action],steps:$steps
    }]}' >"$sealed_tmp/draft.json"
  set +e
  local_plan_seal_apply "$sealed_tmp/draft.json" "$sealed_tmp/planning.jsonl" \
    "$sealed_tmp/apply"
  sealed_status=$?
  set -e
  [ "$sealed_status" -eq 0 ] || {
    printf 'roundhouse: the sealed fleet-schedule %s did not complete; nothing past the failing step was changed\n' \
      "$sealed_action" >&2
    exit 70
  }
  fleet_schedule_report "$sealed_action" "$(jq -c '.operations[0]' "$sealed_tmp/draft.json")" \
    "$sealed_reachable"
  fleet_schedule_verify "$sealed_action" "$sealed_reachable" || exit $?
  # An install the scheduler could not take yet is 75 (written, loads later);
  # an uninstall has removed what it could see either way.
  [ "$sealed_action" != install ] || [ "$sealed_reachable" = true ] || {
    [ "$(fleet_schedule_platform)" != systemd ] || fleet_schedule_manager_unreachable_note
    exit 75
  }
)

fleet_schedule_command() (
  # `roundhouse fleet-schedule install|status|uninstall` — this host's two
  # scheduled jobs. Host-local and operator-run: it never reaches another
  # host, and `install` is the only path in the system that enables a job.
  # `install` and `uninstall` ride the sealed-plan pipeline (above); `status`
  # is read-only.
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
    uninstall)
      # Plainly or under `set +e`, never `|| exit $?` (fleet_schedule_sealed).
      set +e
      fleet_schedule_sealed uninstall
      uninstall_status=$?
      set -e
      [ "$uninstall_status" -eq 0 ] || exit "$uninstall_status"
      rm -f "$(fleet_schedule_marker)"
      for uninstall_mode in $fleet_schedule_modes; do
        rm -f "$(fleet_schedule_state_path "$uninstall_mode")"
      done
      # The opt-out: from here on a trigger stamps and starts nothing, and a
      # pass raises no schedule alert, until `install` is run again.
      mkdir -p "$(dirname "$(fleet_schedule_optout_path)")"
      printf 'uninstalled_at: %s\n' "$(fleet_now)" >"$(fleet_schedule_optout_path)"
      ;;
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
      [ "$(fleet_schedule_platform)" != systemd ] || fleet_schedule_lingers_preflight || exit $?
      set +e
      fleet_schedule_sealed install
      install_status=$?
      set -e
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
