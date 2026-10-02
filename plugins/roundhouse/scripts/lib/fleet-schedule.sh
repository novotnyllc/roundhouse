# roundhouse — the per-host scheduled jobs: what they are made of, what state
# they are in, and the pass's own check on them.
#
# §6.1 of the agent-settings loop design. Two jobs per host run the two
# cadences: a pair of LaunchAgents on macOS, a pair of systemd user
# service+timer units on Linux and WSL. The trigger that kicks them is
# lib/fleet-trigger.sh; `fleet-schedule install|uninstall`, which change them
# through the sealed-plan pipeline, is lib/fleet-schedule-plan.sh.
#
# ONE observation, ONE state. Each job's raw facts — its definition files,
# whether its scheduler can be reached, loaded/disabled (launchd) or
# enabled/active/linger (systemd) — are read once per command
# (fleet_schedule_facts), and its state word comes from those facts alone
# (fleet_schedule_state_word, a pure function). The trigger, the pass check,
# `status`, and the collector the sealed plan is built from all read the same
# two, so they cannot disagree about a job.
#
# Platform specifics live in fleet_schedule_launchd_* and
# fleet_schedule_systemd_*, reached through fleet_schedule_backend.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_schedule_modes='fast full'

# The superseded launchd entries fleet-update's absorb rule names: the old
# autoupdate agent and the one-plist fleet agent. The ONE list; every reader
# (the observation, the absorb plan, the executor's allowlist) derives from it.
fleet_schedule_legacy_labels='com.novotnyllc.roundhouse.autoupdate com.novotnyllc.roundhouse.fleet'

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

fleet_schedule_backend() {
  # fleet_schedule_backend VERB [ARG...] — fleet_schedule_<platform>_VERB, the
  # one dispatcher to the per-backend functions. 69 on a platform with none.
  backend_platform=$(fleet_schedule_platform)
  case $backend_platform in
    launchd | systemd) "fleet_schedule_${backend_platform}_$1" "${@:2}" ;;
    *) return 69 ;;
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

fleet_schedule_gui_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

fleet_schedule_def_path() {
  # fast|full -> the file whose presence names the job: the LaunchAgent plist,
  # or the systemd timer.
  fleet_schedule_backend def_path "$1"
}

fleet_schedule_def_paths() {
  # fast|full -> EVERY file the job is made of, one per line: the plist, or
  # the systemd `.service` and its `.timer`. A job missing any of them is
  # missing — a timer whose service is gone fires into nothing.
  fleet_schedule_backend def_paths "$1"
}

fleet_schedule_legacy_plists() {
  # The superseded entries (fleet_schedule_legacy_labels) that exist, one path
  # per line.
  for legacy_label in $fleet_schedule_legacy_labels; do
    [ ! -f "$HOME/Library/LaunchAgents/$legacy_label.plist" ] ||
      printf '%s\n' "$HOME/Library/LaunchAgents/$legacy_label.plist"
  done
}

fleet_schedule_paths_in_home() {
  # True when every path on stdin (one per line) is strictly under $HOME. A
  # definition is per-user state: an XDG_CONFIG_HOME pointing elsewhere must
  # not turn `install` into a write outside the account's own tree.
  while IFS= read -r home_path; do
    [ -n "$home_path" ] || continue
    case $home_path in
      "$HOME"/?*) ;;
      *) return 1 ;;
    esac
    case /$home_path/ in */../* | */./*) return 1 ;; esac
    # Lexically under $HOME is not enough: a symlinked ~/.config or
    # LaunchAgents could carry the write elsewhere. The nearest existing
    # parent, resolved, must sit under the resolved home too.
    home_parent=$(dirname "$home_path")
    while [ ! -d "$home_parent" ] && [ "$home_parent" != "$HOME" ]; do
      home_parent=$(dirname "$home_parent")
    done
    home_real=$(CDPATH='' cd -P -- "$HOME" 2>/dev/null && pwd) || return 1
    home_parent_real=$(CDPATH='' cd -P -- "$home_parent" 2>/dev/null && pwd) || return 1
    case $home_parent_real/ in
      "$home_real"/*) ;;
      *) return 1 ;;
    esac
  done
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

# --- launchd -------------------------------------------------------------------

fleet_schedule_launchd_def_path() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(fleet_schedule_label "$1")"
}

fleet_schedule_launchd_def_paths() {
  fleet_schedule_launchd_def_path "$1"
}

fleet_schedule_launchd_facts() {
  # The scheduler half of fleet_schedule_facts: the GUI domain, then — only
  # where it answers — the job's disabled flag and whether it is loaded. Both
  # spellings of disabled: `=> disabled` on current macOS, `=> true` older.
  launchd_domain=$(fleet_schedule_gui_domain)
  launchd_label=$(fleet_schedule_label "$1")
  if ! launchctl print "$launchd_domain" >/dev/null 2>&1; then
    printf 'reachable=0 loaded=0 disabled=0\n'
    return 0
  fi
  launchd_disabled=0
  ! launchctl print-disabled "$launchd_domain" 2>/dev/null |
    grep -Eq "\"$launchd_label\" => (disabled|true)" || launchd_disabled=1
  launchd_loaded=0
  ! launchctl print "$launchd_domain/$launchd_label" >/dev/null 2>&1 || launchd_loaded=1
  printf 'reachable=1 loaded=%s disabled=%s\n' "$launchd_loaded" "$launchd_disabled"
}

fleet_schedule_launchd_start() {
  launchctl kickstart "$(fleet_schedule_gui_domain)/$(fleet_schedule_label "$1")"
}

fleet_schedule_launchd_running() {
  # True while the job has a live process: a kickstart now would be a no-op.
  # A live read for fleet_trigger_exit_pending, not one of the facts.
  launchctl print "$(fleet_schedule_gui_domain)/$(fleet_schedule_label "$1")" \
    2>/dev/null | grep -Eq '^[[:space:]]*state = running$'
}

# --- systemd -------------------------------------------------------------------

fleet_schedule_systemd_def_path() {
  printf '%s/%s.timer\n' "$(fleet_schedule_unit_dir)" "$(fleet_schedule_unit "$1")"
}

fleet_schedule_systemd_def_paths() {
  printf '%s/%s.service\n' "$(fleet_schedule_unit_dir)" "$(fleet_schedule_unit "$1")"
  fleet_schedule_systemd_def_path "$1"
}

fleet_schedule_systemd_facts() {
  # The scheduler half of fleet_schedule_facts. With no manager to ask,
  # `enable` is a symlink on disk (timers.target.wants), so that is read
  # instead; lingering is logind's, and is read either way.
  systemd_timer="$(fleet_schedule_unit "$1").timer"
  systemd_lingers=1
  fleet_schedule_lingers || systemd_lingers=0
  if ! fleet_schedule_user_manager; then
    systemd_wants=0
    [ ! -L "$(fleet_schedule_unit_dir)/timers.target.wants/$systemd_timer" ] || systemd_wants=1
    printf 'reachable=0 enabled=0 disabled=0 active=0 wants=%s lingers=%s\n' \
      "$systemd_wants" "$systemd_lingers"
    return 0
  fi
  systemd_enabled=0
  systemd_disabled=0
  case $(systemctl --user is-enabled "$systemd_timer" 2>/dev/null || :) in
    enabled) systemd_enabled=1 ;;
    disabled | masked | masked-runtime) systemd_disabled=1 ;;
  esac
  systemd_active=0
  ! systemctl --user is-active --quiet "$systemd_timer" 2>/dev/null || systemd_active=1
  printf 'reachable=1 enabled=%s disabled=%s active=%s wants=0 lingers=%s\n' \
    "$systemd_enabled" "$systemd_disabled" "$systemd_active" "$systemd_lingers"
}

fleet_schedule_systemd_start() {
  systemctl --user start --no-block "$(fleet_schedule_unit "$1").service"
}

fleet_schedule_systemd_running() {
  # True while a start would merge into the run already going: the oneshot
  # is `activating` for the whole run. (While `deactivating`, systemd queues
  # the start for after the stop, so there is nothing to wait for.) A live
  # read for fleet_trigger_exit_pending, not one of the facts.
  case $(systemctl --user show -p ActiveState --value \
    "$(fleet_schedule_unit "$1").service" 2>/dev/null) in
    activating | active) return 0 ;;
    *) return 1 ;;
  esac
}

# --- the facts, and the one state derived from them -----------------------------

fleet_schedule_facts() {
  # fleet_schedule_facts fast|full -> ONE line of `key=value` words, read-only:
  #
  #   platform   launchd | systemd
  #   present    1 when EVERY definition file exists (fleet_schedule_def_paths)
  #   reachable  the GUI domain / user manager answers
  #   loaded disabled                      (launchd; 0 when unreachable)
  #   enabled disabled active wants lingers (systemd)
  #
  # Values never carry spaces; fleet_schedule_facts_read splits them.
  facts_platform=$(fleet_schedule_platform)
  case $facts_platform in launchd | systemd) ;; *) return 69 ;; esac
  facts_present=1
  facts_paths=$(fleet_schedule_def_paths "$1")
  while IFS= read -r facts_path; do
    [ -n "$facts_path" ] || continue
    [ -f "$facts_path" ] || facts_present=0
  done <<EOF_FACTS
$facts_paths
EOF_FACTS
  printf 'platform=%s present=%s %s\n' "$facts_platform" "$facts_present" \
    "$(fleet_schedule_backend facts "$1")"
}

fleet_schedule_facts_read() {
  # fleet_schedule_facts_read FACTS — split a facts line into sf_<key>
  # globals (absent keys read as 0). Pure: no process, no scheduler query.
  sf_platform= sf_present=0 sf_reachable=0 sf_loaded=0 sf_disabled=0
  sf_enabled=0 sf_active=0 sf_wants=0 sf_lingers=1
  for facts_word in $1; do
    case $facts_word in
      platform=*) sf_platform=${facts_word#*=} ;;
      present=*) sf_present=${facts_word#*=} ;;
      reachable=*) sf_reachable=${facts_word#*=} ;;
      loaded=*) sf_loaded=${facts_word#*=} ;;
      disabled=*) sf_disabled=${facts_word#*=} ;;
      enabled=*) sf_enabled=${facts_word#*=} ;;
      active=*) sf_active=${facts_word#*=} ;;
      wants=*) sf_wants=${facts_word#*=} ;;
      lingers=*) sf_lingers=${facts_word#*=} ;;
    esac
  done
}

fleet_schedule_state_word() {
  # fleet_schedule_state_word FACTS -> one word, a PURE function of the facts:
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
  #
  # A timer the operator STOPPED (inactive, still enabled) is unloaded whether
  # or not the account lingers: only an ACTIVE timer without lingering is
  # unavailable, so a trigger never runs behind a stop.
  fleet_schedule_facts_read "$1"
  if [ "$sf_present" != 1 ]; then
    printf 'missing\n'
    return 0
  fi
  case $sf_platform in
    launchd)
      if [ "$sf_reachable" != 1 ]; then printf 'unavailable\n'
      elif [ "$sf_disabled" = 1 ]; then printf 'disabled\n'
      elif [ "$sf_loaded" = 1 ]; then printf 'loaded\n'
      else printf 'unloaded\n'
      fi
      ;;
    systemd)
      if [ "$sf_reachable" != 1 ]; then
        if [ "$sf_wants" = 1 ]; then printf 'unavailable\n'; else printf 'disabled\n'; fi
      elif [ "$sf_disabled" = 1 ]; then printf 'disabled\n'
      elif [ "$sf_active" != 1 ]; then printf 'unloaded\n'
      elif [ "$sf_lingers" != 1 ]; then printf 'unavailable\n'
      else printf 'loaded\n'
      fi
      ;;
    *) printf 'unavailable\n' ;;
  esac
}

fleet_schedule_still_scheduled() {
  # fleet_schedule_still_scheduled FACTS — true while the scheduler still
  # holds the job: loaded (launchd), or enabled or active (systemd). What an
  # uninstall must have ended before it may report done.
  fleet_schedule_facts_read "$1"
  # An unreachable user manager reports a still-enabled timer only through its
  # timers.target.wants link, so that link counts as scheduled too.
  [ "$sf_loaded" = 1 ] || [ "$sf_enabled" = 1 ] || [ "$sf_active" = 1 ] ||
    [ "$sf_wants" = 1 ]
}

fleet_schedule_probe() {
  # fleet_schedule_probe fast|full -> the state word, read-only.
  fleet_schedule_state_word "$(fleet_schedule_facts "$1")"
}

# --- the remembered state ------------------------------------------------------

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

fleet_schedule_job_state() {
  # fleet_schedule_job_state fast|full [FACTS] — the state word, remembered:
  # every state actually observed is written to store.run/schedule-state.MODE,
  # and `unavailable` never overwrites one. That memory is what lets a trigger
  # over SSH (no GUI domain to ask) still honour an operator's disable it can
  # no longer see. FACTS, when the caller already read them, are not re-read.
  #
  # Written whole through a temporary file UNIQUE to this writer and renamed
  # into place, so two triggers racing on one job leave one complete state,
  # never a torn file or another writer's half-written temporary.
  job_state=$(fleet_schedule_state_word "${2:-$(fleet_schedule_facts "$1")}")
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
  fleet_schedule_keep_copy "$1" replaced || return 1
  mkdir -p "$(dirname "$1")" || return 1
  write_next=$(mktemp "$1.next.XXXXXX") || return 1
  cp "$2" "$write_next" && chmod 0644 "$write_next" && mv -f "$write_next" "$1" || {
    rm -f "$write_next"
    return 1
  }
}

fleet_schedule_keep_copy() {
  # fleet_schedule_keep_copy PATH SUFFIX — keep an existing definition as
  # PATH.SUFFIX (`replaced` before install overwrites it, `removed` before
  # uninstall deletes it), verified byte-equal. Nothing to keep is success; a
  # copy that cannot be made fails, and the caller must leave PATH alone.
  [ -f "$1" ] || return 0
  cp -p "$1" "$1.$2" 2>/dev/null && cmp -s "$1" "$1.$2" || {
    printf 'roundhouse: could not keep the previous definition as %s.%s; %s was left in place, unchanged\n' \
      "$1" "$2" "$1" >&2
    return 1
  }
  printf 'roundhouse: the previous definition is kept as %s.%s\n' "$1" "$2" >&2
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

# --- status: structured facts, rendered -----------------------------------------

fleet_schedule_status_facts() {
  # One JSON object per job, read-only apart from the remembered state:
  #
  #   mode state last   the state word and the last one remembered
  #   reachable         the scheduler answered
  #   scheduled         the scheduler still holds the job (loaded; or enabled
  #                     or active)
  #   paths             every definition file, in fleet_schedule_def_paths order
  #   present           how many of them exist
  #   differs absent    the file names that differ from what install writes,
  #                     and the ones that do not exist
  #   opted_out         the host was taken off the schedule
  #
  # `status` renders these; `install` and `uninstall` verify against them.
  # Every file the job is made of is compared — on systemd both the `.timer`
  # and its `.service` — so a hand-edited or missing service never hides
  # behind a matching timer.
  status_dir=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule.XXXXXX") || return 1
  status_optout=false
  [ ! -e "$(fleet_schedule_optout_path)" ] || status_optout=true
  for status_mode in $fleet_schedule_modes; do
    status_facts=$(fleet_schedule_facts "$status_mode")
    # Read-only: the pure state word, never the remembered (persisted) one.
    status_state=$(fleet_schedule_state_word "$status_facts")
    status_scheduled=false
    ! fleet_schedule_still_scheduled "$status_facts" || status_scheduled=true
    fleet_schedule_facts_read "$status_facts"
    status_reachable=false
    [ "$sf_reachable" != 1 ] || status_reachable=true
    : >"$status_dir/paths"
    : >"$status_dir/differs"
    : >"$status_dir/absent"
    fleet_schedule_def_paths "$status_mode" >"$status_dir/paths"
    while IFS= read -r status_path; do
      [ -n "$status_path" ] || continue
      if [ ! -f "$status_path" ]; then
        printf '%s\n' "${status_path##*/}" >>"$status_dir/absent"
        continue
      fi
      fleet_schedule_render "$status_mode" "$status_path" >"$status_dir/def"
      fleet_schedule_same "$status_path" "$status_dir/def" ||
        printf '%s\n' "${status_path##*/}" >>"$status_dir/differs"
    done <"$status_dir/paths"
    jq -cn --arg mode "$status_mode" --arg state "$status_state" \
      --arg last "$(fleet_schedule_last_state "$status_mode")" \
      --argjson reachable "$status_reachable" --argjson scheduled "$status_scheduled" \
      --argjson opted_out "$status_optout" \
      --rawfile paths "$status_dir/paths" --rawfile differs "$status_dir/differs" \
      --rawfile absent "$status_dir/absent" '
      def lines: split("\n") | map(select(length > 0));
      ($paths | lines) as $p | ($absent | lines) as $a |
      {mode:$mode,state:$state,last:$last,reachable:$reachable,scheduled:$scheduled,
        paths:$p,present:(($p | length) - ($a | length)),differs:($differs | lines),
        absent:$a,opted_out:$opted_out}'
  done
  rm -rf "$status_dir"
}

fleet_schedule_status_render() {
  # fleet_schedule_status_render FACTS — FACTS is fleet_schedule_status_facts'
  # output; stdout: one line per job, then the opt-out notice.
  printf '%s\n' "$1" | jq -r '
    (if .state == "missing" then "missing"
     elif .state == "disabled" then "installed, disabled"
     elif .state == "unloaded" then "installed, enabled, not loaded"
     elif .state == "loaded" then "installed, enabled, loaded"
     else "installed, scheduler unreachable (no GUI domain, or no lingering user manager); last seen " +
       (if .last == "" then "never" else .last end)
     end) as $text |
    (if .present == 0 then ""
     elif (.differs | length) > 0 then
       ", definition differs from what install writes (" + (.differs | join(" ")) + ")"
     elif (.absent | length) == 0 then ", definition matches"
     else "" end) as $def |
    (if .present > 0 and (.absent | length) > 0 then
       ", definition incomplete (" + (.absent | join(" ")) + " absent)"
     else "" end) as $incomplete |
    "fleet-\(.mode): \($text)\($def)\($incomplete) — \(.paths | join(" and "))"'
  ! printf '%s\n' "$1" | jq -se 'any(.[]; .opted_out)' >/dev/null ||
    printf 'this host is opted out of scheduling (fleet-schedule uninstall); triggers only stamp\n'
}

fleet_schedule_status() {
  # `fleet-schedule status`: one line per job — installed or missing, enabled
  # or disabled, loaded or not, and whether the definition on disk is the one
  # `install` writes. Read-only and unsealed.
  status_all=$(fleet_schedule_status_facts) || return 1
  fleet_schedule_status_render "$status_all"
}

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
