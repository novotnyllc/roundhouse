# roundhouse — `fleet-schedule install|status|uninstall`, and the sealed plan
# install and uninstall ride.
#
# AGENTS.md: every mutation rides the sealed-plan pipeline, and these two are
# mutations of this host. So `install` and `uninstall` never act on what they
# see; they PLAN from what the collector observed, seal that plan, and apply
# only the sealed plan (lib/local-plan.sh, the pipeline launcher-install uses
# too):
#
#   observe   the collector's `agent_artifact roundhouse:schedule` record
#             (fleet_schedule_observe): every definition file's sha256 or its
#             absence, each job's facts and state word (lib/fleet-schedule.sh),
#             the superseded entries (each plist's sha256 or its absence, and
#             whether launchd still holds the job), the scheduler's
#             reachability, and whether a systemd user manager still runs an
#             older copy of a replaced unit;
#   plan      fleet_schedule_plan_steps turns that record into the EXACT
#             steps — each file to write (with its rendered sha256), keep,
#             remove or absorb, and each scheduler command with the effect it
#             has, in order;
#   seal      the record is the plan's precondition, and the target's
#             hostname and user are bound to the configured local machine;
#   recheck   a fresh collect must match the sealed preconditions immediately
#             before anything changes — an operator who disabled a job or
#             edited a definition in between gets a refusal, not a surprise;
#   apply     fleet_schedule_execute performs exactly the sealed steps, a
#             rendered definition only when it still hashes to the sealed
#             digest, a command only when it is the one this host's own job
#             has for that effect;
#   verify    apply's post-change collect must show every written file at its
#             sealed digest and every removed one gone, and the status FACTS
#             (fleet_schedule_status_facts) must show the jobs as the plan
#             left them — an uninstall is done only once the scheduler no
#             longer holds them.
#
# On a WSL distribution the record also carries the machine's NATIVE half:
# the Windows Task Scheduler's Roundhouse tasks, observed through the interop
# lane (lib/fleet-schedule-windows.sh). Native Windows never gets a fleet-run
# task of its own; `install` only removes the obsolete one-shot tasks an
# earlier session left there, each bound to its sealed definition digest.
#
# A definition that is replaced is kept as `.replaced`, one that is removed as
# `.removed`; a backup that cannot be made stops the step. No definition's
# CONTENT is ever printed: a hand-added environment variable may be a secret.
#
# `status` stays read-only and unsealed.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

# --- observe ---------------------------------------------------------------------

fleet_schedule_observe() {
  # One JSON object, read-only: the collector's roundhouse:schedule record.
  # Each job's facts are read ONCE, and its state is the word derived from
  # them (fleet_schedule_state_word).
  observe_platform=$(fleet_schedule_platform)
  case $observe_platform in
    launchd | systemd) ;;
    *)
      printf 'roundhouse: fleet-schedule observes launchd or systemd only\n' >&2
      return 69
      ;;
  esac
  observe_optout=false
  [ ! -e "$(fleet_schedule_optout_path)" ] || observe_optout=true
  observe_files='[]'
  observe_jobs='[]'
  observe_reachable=false
  observe_lingers=true
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
    observe_facts=$(fleet_schedule_facts "$observe_mode")
    fleet_schedule_facts_read "$observe_facts"
    [ "$sf_reachable" != 1 ] || observe_reachable=true
    [ "$sf_lingers" = 1 ] || observe_lingers=false
    observe_jobs=$(printf '%s\n' "$observe_jobs" | jq -c --arg mode "$observe_mode" \
      --arg state "$(fleet_schedule_state_word "$observe_facts")" \
      --argjson loaded "$([ "$sf_loaded" = 1 ] && echo true || echo false)" \
      --argjson disabled "$([ "$sf_disabled" = 1 ] && echo true || echo false)" \
      --argjson enabled "$([ "$sf_enabled" = 1 ] && echo true || echo false)" \
      --argjson active "$([ "$sf_active" = 1 ] && echo true || echo false)" \
      --argjson wants "$([ "$sf_wants" = 1 ] && echo true || echo false)" \
      --argjson unreached "$([ "$sf_manager_unreached" = 1 ] && echo true || echo false)" \
      '. + [{mode:$mode,state:$state,loaded:$loaded,disabled:$disabled,
        enabled:$enabled,active:$active,wants:$wants,manager_unreached:$unreached}]')
  done
  # A manager still on an older copy of a replaced unit (systemd only).
  observe_reload=false
  if [ "$observe_reachable" = true ] && fleet_schedule_backend needs_reload; then
    observe_reload=true
  fi
  observe_legacy='[]'
  if [ "$observe_platform" = launchd ]; then
    observe_legacy=$(fleet_schedule_legacy_entries) || {
      printf 'roundhouse: a superseded scheduler entry could not be read\n' >&2
      return 70
    }
  fi
  # The native Windows half of a WSL machine, or null where there is none.
  observe_native=null
  if [ "$observe_platform" = systemd ] && fleet_schedule_windows_host; then
    observe_native=$(fleet_schedule_native observe) || observe_native=null
  fi
  jq -cn --arg platform "$observe_platform" --arg domain "$(fleet_schedule_gui_domain)" \
    --argjson reachable "$observe_reachable" --argjson lingers "$observe_lingers" \
    --argjson reload "$observe_reload" \
    --argjson opted_out "$observe_optout" --argjson files "$observe_files" \
    --argjson jobs "$observe_jobs" --argjson legacy "$observe_legacy" \
    --argjson native "$observe_native" \
    '{id:"roundhouse:schedule",artifact_kind:"schedule",platform:$platform,
      domain:(if $platform == "launchd" then $domain else null end),
      scheduler_reachable:$reachable,lingers:$lingers,needs_reload:$reload,
      opted_out:$opted_out,
      files:$files,jobs:$jobs,legacy:$legacy,native:$native}'
}

# --- plan --------------------------------------------------------------------------

fleet_schedule_run_step() {
  # fleet_schedule_run_step MODE EFFECT REQUIRED ARG... -> one `run` step: the
  # scheduler command, and the EFFECT it has (what the report and the
  # executor's allowlist key on — never an argv position). One argument per
  # line, read back with -R: jq takes a `--user` among `--args` for an option
  # of its own.
  run_step_mode=$1
  run_step_effect=$2
  run_step_required=$3
  shift 3
  jq -cn --arg mode "$run_step_mode" --arg effect "$run_step_effect" \
    --argjson required "$run_step_required" \
    --argjson argv "$(printf '%s\n' "$@" | jq -Rnc '[inputs]')" \
    '{action:"run",mode:$mode,effect:$effect,required:$required,argv:$argv}'
}

fleet_schedule_launchd_commands() {
  # The launchd half of fleet_schedule_allowed_commands, one {mode,effect,argv}
  # per line; with ACTION and RECORD (fleet_schedule_launchd_plan) the same
  # table drives the plan, so plan and allowlist cannot drift apart.
  launchd_domain=$(fleet_schedule_gui_domain)
  for launchd_mode in $fleet_schedule_modes; do
    launchd_target="$launchd_domain/$(fleet_schedule_label "$launchd_mode")"
    fleet_schedule_run_step "$launchd_mode" enable true launchctl enable "$launchd_target"
    fleet_schedule_run_step "$launchd_mode" unload true launchctl bootout "$launchd_target"
    fleet_schedule_run_step "$launchd_mode" load true launchctl bootstrap "$launchd_domain" \
      "$(fleet_schedule_launchd_def_path "$launchd_mode")"
  done
  for launchd_label in $fleet_schedule_legacy_labels; do
    fleet_schedule_run_step legacy unload true launchctl bootout "$launchd_domain/$launchd_label"
  done
}

fleet_schedule_systemd_commands() {
  fleet_schedule_run_step all reload false systemctl --user daemon-reload
  for systemd_mode in $fleet_schedule_modes; do
    systemd_timer="$(fleet_schedule_unit "$systemd_mode").timer"
    fleet_schedule_run_step "$systemd_mode" restart false systemctl --user restart "$systemd_timer"
    fleet_schedule_run_step "$systemd_mode" enable-start true systemctl --user enable --now "$systemd_timer"
    fleet_schedule_run_step "$systemd_mode" disable-stop true systemctl --user disable --now "$systemd_timer"
  done
}

fleet_schedule_command_step() {
  # fleet_schedule_command_step MODE EFFECT [REQUIRED] — the one command this
  # host has for MODE's EFFECT, as a step (REQUIRED overrides its default).
  fleet_schedule_backend commands |
    jq -c --arg mode "$1" --arg effect "$2" --arg required "${3:-}" '
      select(.mode == $mode and .effect == $effect) |
      if $required == "" then . else .required = ($required == "true") end' | head -n 1
}

fleet_schedule_launchd_plan() {
  # fleet_schedule_launchd_plan ACTION MODE WRITTEN JOB — MODE's scheduler
  # steps. JOB is the record's job object; WRITTEN is true when a definition
  # of MODE is (re)written.
  launchd_plan_loaded=$(printf '%s\n' "$4" | jq -r '.loaded')
  case $1 in
    install)
      # The ONE place a disabled job is re-enabled: the operator asked for it.
      # A job can stay LOADED through a disable, and bootstrapping a loaded
      # job is an error, so loaded-ness is the observed flag, not a guess.
      [ "$(printf '%s\n' "$4" | jq -r '.disabled')" != true ] ||
        fleet_schedule_command_step "$2" enable
      if [ "$launchd_plan_loaded" = true ] && [ "$3" = true ]; then
        fleet_schedule_command_step "$2" unload false
      fi
      if [ "$launchd_plan_loaded" != true ] || [ "$3" = true ]; then
        fleet_schedule_command_step "$2" load
      fi
      ;;
    uninstall)
      # A job the scheduler still holds must be unloaded, or the uninstall
      # has not happened: required.
      [ "$launchd_plan_loaded" != true ] || fleet_schedule_command_step "$2" unload true
      ;;
  esac
}

fleet_schedule_systemd_plan() {
  # fleet_schedule_systemd_plan ACTION MODE WRITTEN JOB RECORD — the per-job
  # steps an uninstall needs; install's come after every unit is written
  # (fleet_schedule_systemd_plan_finish).
  [ "$1" = uninstall ] || return 0
  # A manager that runs out of this session's reach may have the timer
  # loaded, link or no link (another session can start a disabled timer),
  # and removing anything of the job then would not stop it: refused while
  # any unit or the wants link is on disk.
  if [ "$(printf '%s\n' "$4" | jq -r '.manager_unreached')" = true ] &&
    [ "$(printf '%s\n' "$5" | jq -r --arg mode "$2" --argjson job "$4" \
      '$job.wants or any(.files[]; .mode == $mode and .digest != null)')" = true ]; then
    printf 'roundhouse: a systemd user manager runs that this session cannot reach, and it may still run the fleet-%s timer; nothing was changed\n' "$2" >&2
    return 75
  fi
  if [ "$(printf '%s\n' "$4" | jq -r '.wants')" = true ]; then
    # Observed only with no user manager to ask: the timer's enablement is
    # its timers.target.wants link on disk, removed like the units.
    jq -cn --arg mode "$2" --arg path "$(fleet_schedule_systemd_wants_path "$2")" \
      '{action:"unlink",mode:$mode,path:$path}'
  elif [ "$(printf '%s\n' "$4" | jq -r '.enabled or .active')" = true ]; then
    fleet_schedule_command_step "$2" disable-stop true
  fi
}

fleet_schedule_launchd_plan_finish() {
  # fleet_schedule_launchd_plan_finish ACTION CHANGED REACHABLE RECORD —
  # Absorb, never duplicate (fleet-update): only after the new pair, and
  # renamed BEFORE it is unloaded — a rename that fails leaves the superseded
  # entry on disk and running. The new name is sealed too. A superseded job
  # launchd still holds (the record's `loaded`, false where the domain could
  # not be reached) is unloaded, REQUIRED: one left running beside the new
  # pair is not absorbed, and the install fails before reporting it. That
  # holds with no plist left to rename too (an earlier unload failed).
  [ "$1" = install ] || return 0
  printf '%s\n' "$4" | jq -c '.legacy[]' | while IFS= read -r finish_entry; do
    [ -n "$finish_entry" ] || continue
    if [ "$(printf '%s\n' "$finish_entry" | jq -r '.digest != null')" = true ]; then
      finish_path=$(printf '%s\n' "$finish_entry" | jq -r '.path')
      finish_to="$finish_path.absorbed"
      [ ! -e "$finish_to" ] || finish_to="$finish_path.absorbed.$(date -u +%Y%m%dT%H%M%SZ)"
      printf '%s\n' "$finish_entry" | jq -c --arg to "$finish_to" \
        '{action:"absorb",path,before:.digest,to:$to}'
    fi
    [ "$(printf '%s\n' "$finish_entry" | jq -r '.loaded')" != true ] ||
      fleet_schedule_run_step legacy unload true launchctl bootout \
        "$(fleet_schedule_gui_domain)/$(printf '%s\n' "$finish_entry" | jq -r '.label')"
  done
}

fleet_schedule_systemd_plan_finish() {
  # fleet_schedule_systemd_plan_finish ACTION CHANGED REACHABLE RECORD
  [ "$3" = true ] || return 0
  case $1 in
    install)
      # A replaced unit runs only once the manager reloads it, so the reload
      # is REQUIRED: an install whose reload fails has not happened. A
      # manager still on an older copy (a previous install whose reload
      # failed) is reloaded, and its timers restarted, though nothing is
      # rewritten.
      finish_reload=$2
      [ "$(printf '%s\n' "$4" | jq -r '.needs_reload')" != true ] || finish_reload=true
      [ "$finish_reload" != true ] || fleet_schedule_command_step all reload true
      for finish_mode in $fleet_schedule_modes; do
        if [ "$(printf '%s\n' "$4" | jq -r --arg mode "$finish_mode" \
          'first(.jobs[] | select(.mode == $mode)) | .enabled and .active')" = true ]; then
          [ "$finish_reload" != true ] || fleet_schedule_command_step "$finish_mode" restart
        else
          # The ONE place a disabled timer is re-enabled: the operator asked.
          fleet_schedule_command_step "$finish_mode" enable-start
        fi
      done
      ;;
    uninstall)
      [ "$2" != true ] || fleet_schedule_command_step all reload
      ;;
  esac
}

fleet_schedule_plan_steps() {
  # fleet_schedule_plan_steps install|uninstall RECORD-JSON WORKDIR — the
  # sealed plan's exact steps, as one JSON array, decided from the OBSERVED
  # record alone (never a fresh look: the record is what gets sealed and
  # rechecked). A definition that exists and differs is reported by PATH
  # here, before anything is sealed — never by content.
  plan_action=$1
  plan_record=$2
  plan_work=$3
  plan_reachable=$(printf '%s\n' "$plan_record" | jq -r '.scheduler_reachable')
  : >"$plan_work/steps.jsonl"
  plan_changed=false
  for plan_mode in $fleet_schedule_modes; do
    plan_mode_written=false
    plan_job=$(printf '%s\n' "$plan_record" | jq -c --arg mode "$plan_mode" \
      'first(.jobs[] | select(.mode == $mode))')
    # An uninstall unloads BEFORE it removes: a scheduler that refuses to let
    # go of the job leaves its definition on disk, not a running job with no
    # file behind it. An unreachable scheduler reports nothing loaded or
    # enabled; with no systemd user manager the backend removes the timer's
    # wants link instead.
    if [ "$plan_action" = uninstall ]; then
      fleet_schedule_backend plan uninstall "$plan_mode" false "$plan_job" "$plan_record" \
        >>"$plan_work/steps.jsonl" || return 70
      ! grep -Eq '"action":"(run|unlink)"' "$plan_work/steps.jsonl" || plan_changed=true
    fi
    plan_files=$(printf '%s\n' "$plan_record" | jq -c --arg mode "$plan_mode" \
      '.files[] | select(.mode == $mode)')
    while IFS= read -r plan_file; do
      [ -n "$plan_file" ] || continue
      plan_path=$(printf '%s\n' "$plan_file" | jq -r '.path')
      plan_form=$(printf '%s\n' "$plan_file" | jq -r '.form')
      plan_before=$(printf '%s\n' "$plan_file" | jq -r '.digest // empty')
      if [ "$plan_action" = uninstall ]; then
        if [ -n "$plan_before" ]; then
          jq -cn --arg mode "$plan_mode" --arg form "$plan_form" \
            --arg path "$plan_path" --arg before "$plan_before" \
            '{action:"remove",mode:$mode,form:$form,path:$path,before:$before}' \
            >>"$plan_work/steps.jsonl"
          plan_changed=true
        fi
        continue
      fi
      plan_rendered="$plan_work/${plan_path##*/}"
      fleet_schedule_render "$plan_mode" "$plan_path" >"$plan_rendered" || return 70
      if [ -n "$plan_before" ] && [ -f "$plan_path" ] &&
        fleet_schedule_same "$plan_path" "$plan_rendered"; then
        jq -cn --arg mode "$plan_mode" --arg form "$plan_form" \
          --arg path "$plan_path" --arg digest "$plan_before" \
          '{action:"keep",mode:$mode,form:$form,path:$path,digest:$digest}' \
          >>"$plan_work/steps.jsonl"
        continue
      fi
      [ -z "$plan_before" ] ||
        printf 'roundhouse: %s differs from the definition fleet-schedule writes; it will be replaced, and the previous definition kept as %s.replaced\n' \
          "$plan_path" "$plan_path" >&2
      jq -cn --arg mode "$plan_mode" --arg form "$plan_form" --arg path "$plan_path" \
        --arg digest "$(sha256_file "$plan_rendered")" --arg before "$plan_before" \
        '{action:"write",mode:$mode,form:$form,path:$path,digest:$digest,
          before:(if $before == "" then null else $before end)}' >>"$plan_work/steps.jsonl"
      plan_mode_written=true
      plan_changed=true
    done <<EOF_PLAN
$plan_files
EOF_PLAN
    [ "$plan_action" = install ] && [ "$plan_reachable" = true ] || continue
    fleet_schedule_backend plan install "$plan_mode" "$plan_mode_written" "$plan_job" \
      >>"$plan_work/steps.jsonl" || return 70
  done
  fleet_schedule_backend plan_finish "$plan_action" "$plan_changed" "$plan_reachable" \
    "$plan_record" >>"$plan_work/steps.jsonl" || return 70
  # The native half last: the local jobs never wait on the Windows side.
  if [ "$(printf '%s\n' "$plan_record" | jq -r '.native != null')" = true ]; then
    fleet_schedule_native plan "$plan_action" "$plan_record" >>"$plan_work/steps.jsonl" || return 70
  fi
  jq -cs . "$plan_work/steps.jsonl"
}

# --- apply -------------------------------------------------------------------------

fleet_schedule_execute() (
  # fleet_schedule_execute OPERATION.json — apply-plan's executor for the
  # sealed `roundhouse:schedule` operation: its steps, exactly and in order.
  # Every path is re-derived and must be one this host's jobs own, under
  # $HOME; a written definition is rendered again and must hash to the sealed
  # digest; a command must be the one fleet_schedule_backend commands lists
  # for that mode and effect. Anything else refuses.
  execute_op=$1
  jq -e '(.argv | length) == 3 and .argv[0] == "roundhouse" and
    .argv[1] == "fleet-schedule" and (.argv[2] | IN("install","uninstall")) and
    (.steps | type == "array")' "$execute_op" >/dev/null || {
    printf 'roundhouse: unsafe fleet-schedule plan operation\n' >&2
    exit 64
  }
  execute_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule-apply.XXXXXX") || exit 73
  trap 'rm -rf "$execute_tmp"' EXIT HUP INT TERM
  fleet_schedule_backend commands | jq -cs 'map({mode,effect,argv})' >"$execute_tmp/allowed.json"
  execute_count=$(jq '.steps | length' "$execute_op")
  execute_index=0
  while [ "$execute_index" -lt "$execute_count" ]; do
    jq -c ".steps[$execute_index]" "$execute_op" >"$execute_tmp/step.json"
    execute_index=$((execute_index + 1))
    execute_action=$(jq -r '.action' "$execute_tmp/step.json")
    case $execute_action in
      write | keep | remove | absorb | unlink)
        execute_path=$(jq -r '.path' "$execute_tmp/step.json")
        printf '%s\n' "$execute_path" | fleet_schedule_paths_in_home || {
          printf 'roundhouse: a sealed fleet-schedule step names %s, which is not under %s\n' \
            "$execute_path" "$HOME" >&2
          exit 64
        }
        ;;
    esac
    case $execute_action in
      write | keep | remove)
        execute_mode=$(jq -r '.mode' "$execute_tmp/step.json")
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
            # Kept, never discarded: the removed definition survives as
            # .removed, and a backup that cannot be made stops the removal.
            fleet_schedule_keep_copy "$execute_path" removed || exit 73
            rm -f -- "$execute_path" || exit 73
            ;;
        esac
        ;;
      unlink)
        # Only this host's own timer's wants link, and only a link.
        execute_mode=$(jq -r '.mode' "$execute_tmp/step.json")
        case $execute_mode in fast | full) ;; *) exit 64 ;; esac
        [ "$(fleet_schedule_platform)" = systemd ] &&
          [ "$execute_path" = "$(fleet_schedule_systemd_wants_path "$execute_mode")" ] || {
          printf 'roundhouse: a sealed fleet-schedule step unlinks %s, which is not the fleet-%s timer'"'"'s wants link on this host\n' \
            "$execute_path" "$execute_mode" >&2
          exit 64
        }
        # Sealed on "no user manager running"; asked again at the last
        # moment: a manager that started since may already have loaded the
        # timer from this link, and removing it would not unload it.
        if fleet_schedule_user_manager || fleet_schedule_systemd_manager_runs; then
          printf 'roundhouse: a systemd user manager started after the plan was sealed; %s was left in place — create a new plan\n' \
            "$execute_path" >&2
          exit 65
        fi
        [ ! -e "$execute_path" ] || [ -L "$execute_path" ] || {
          printf 'roundhouse: %s is not a link; a sealed unlink removes only the timer'"'"'s wants link\n' \
            "$execute_path" >&2
          exit 64
        }
        rm -f -- "$execute_path" || exit 73
        ;;
      absorb)
        execute_to=$(jq -r '.to' "$execute_tmp/step.json")
        fleet_schedule_legacy_plists | grep -Fqx -- "$execute_path" || {
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
        jq -e --slurpfile allowed "$execute_tmp/allowed.json" \
          '{mode,effect,argv} as $s | $allowed[0] | index([$s]) != null' \
          "$execute_tmp/step.json" >/dev/null || {
          printf 'roundhouse: a sealed fleet-schedule step runs %s, which is not the command this host'"'"'s job has for that effect\n' \
            "$(jq -c '.argv' "$execute_tmp/step.json")" >&2
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
      unregister)
        # The native half (lib/fleet-schedule-windows.sh): an obsolete
        # one-shot task in the Windows root folder, by its sealed digest,
        # and only on the WSL side of a machine. The Windows side re-checks
        # both before it removes anything.
        jq -e --arg oneshot "$fleet_schedule_windows_oneshot_re" '
          .mode == "native" and .path == "\\" and (.name | test($oneshot)) and
          (.digest | test("^[0-9a-f]{64}$"))' "$execute_tmp/step.json" >/dev/null &&
          fleet_schedule_windows_host || {
          printf 'roundhouse: a sealed fleet-schedule step unregisters a native task this host does not reach\n' >&2
          exit 64
        }
        fleet_schedule_native unregister "$(jq -r '.name' "$execute_tmp/step.json")" \
          "$(jq -r '.digest' "$execute_tmp/step.json")"
        ;;
      *) exit 64 ;;
    esac
  done
)

# --- report and verify ----------------------------------------------------------------

fleet_schedule_report() {
  # fleet_schedule_report install|uninstall OPERATION-JSON REACHABLE RECORD —
  # what the applied plan did, one line per definition, read from the sealed
  # steps' actions and effects; the superseded entries it unloaded are the
  # ones the observed RECORD says launchd held (each one's unload is a
  # required step, so an applied install unloaded them all).
  printf '%s\n' "$2" | jq -r --arg action "$1" --argjson reachable "$3" \
    --argjson record "$4" --arg platform "$(fleet_schedule_platform)" '
    .steps as $steps |
    ($steps | map(select(.action == "absorb"))) as $absorbed |
    (["fast","full"][] as $mode |
      ($steps | map(select(.mode == $mode))) as $s |
      if $action == "uninstall" then
        ($s | map(select(.action == "remove" or .action == "unlink"))) as $removed |
        if ($removed | length) == 0 then "fleet-\($mode): not installed"
        else $removed[] |
          if .action == "unlink" then "fleet-\($mode): disabled (no user manager is running; removed \(.path))"
          else "fleet-\($mode): removed \(.path)" end
        end
      else
        (if any($s[]; .action == "run" and .effect == "enable") then
           "fleet-\($mode): re-enabled (it was disabled)" else empty end),
        ($s[] | select(.action == "write" or .action == "keep") |
          (if .action == "write" then "written" else "unchanged" end) as $result |
          if $platform == "launchd" then
            ($result + (if any($s[]; .action == "run" and .effect == "load") then ", loaded" else "" end)) as $r |
            if $reachable then "fleet-\($mode): \($r) \(.path)"
            else "fleet-\($mode): \($r) \(.path); no GUI launchd domain for this user, so it loads at the next console login" end
          else "fleet-\($mode): \($result) \(.path)" end),
        ($s[] | select(.action == "run" and .effect == "enable-start") |
          "fleet-\($mode): enabled and started roundhouse-fleet-\($mode).timer")
      end),
    (if $action == "install" and any($steps[]; .action == "run" and .effect == "reload") and
        all($steps[]; .action != "write") then
       "roundhouse: reloaded the user manager, which was still on an older copy of a unit"
     else empty end),
    (if $action == "install" then [($record.legacy // [])[] | select(.loaded) | .path] else [] end) as $unloaded |
    ($absorbed[] |
      "roundhouse: absorbed the superseded \(.path | split("/") | last | rtrimstr(".plist")) entry (kept as \(.to)\(if (.path as $p | $unloaded | index($p)) != null then ", unloaded" else "" end))"),
    (($record.legacy // [])[] | select(.loaded and $action == "install" and
        (.path as $p | all($absorbed[]; .path != $p))) |
      "roundhouse: unloaded the superseded \(.label) entry")'
}

fleet_schedule_verify() {
  # fleet_schedule_verify install|uninstall REACHABLE — the post-change check
  # against the status FACTS, never their English: an install leaves every
  # definition present and matching (and loaded, where the scheduler could be
  # reached); an uninstall leaves both jobs missing AND no longer held by the
  # scheduler.
  verify_facts=$(fleet_schedule_status_facts) || return 70
  printf '%s\n' "$verify_facts" | jq -se --arg action "$1" --argjson reachable "$2" '
    length > 0 and all(.[];
      if $action == "install" then
        (.absent | length) == 0 and (.differs | length) == 0 and
        (($reachable | not) or .state == "loaded")
      else .state == "missing" and (.scheduled | not) end)' >/dev/null && return 0
  printf 'roundhouse: the sealed fleet-schedule %s applied, but status does not show it:\n' "$1" >&2
  fleet_schedule_status_render "$verify_facts" >&2
  return 70
}

# --- one mutation at a time ---------------------------------------------------------------

fleet_schedule_lock_path() {
  # The schedule lock: held by one `fleet-schedule install|uninstall` from its
  # first look at the jobs to its last bookkeeping write, so two overlapping
  # runs never interleave the opt-out and marker writes. Host-local run state,
  # beside them; not the run lock, which a pass holds for minutes.
  printf '%s/schedule.lock\n' "$(fleet_run_state_dir)"
}

fleet_schedule_lock_take() {
  # fleet_schedule_lock_take — take the schedule lock (fleet_lock_take's
  # shape: a dead holder, a crashed install or uninstall, is taken over; a
  # live one refuses). Sets fleet_schedule_lock_nonce for the release. Exit 75
  # when another install or uninstall holds it, or it cannot be judged.
  # Called directly, never in a command substitution.
  schedule_lock=$(fleet_schedule_lock_path)
  mkdir -p "$(dirname "$schedule_lock")" || return 73
  schedule_lock_rc=0
  # No ceiling: a mutation is never stopped from outside. A lock whose holder
  # cannot be judged is waited out for ten minutes (an install takes seconds),
  # then refused with its path for the operator to remove.
  fleet_lock_take "$schedule_lock" 600 || schedule_lock_rc=$?
  case $schedule_lock_rc in
    0 | 11) fleet_schedule_lock_nonce=$fleet_lock_nonce_held ;;
    10)
      printf 'roundhouse: another fleet-schedule install or uninstall holds %s on this host; nothing was changed — retry when it finishes\n' \
        "$schedule_lock" >&2
      return 75
      ;;
    *) return 75 ;;
  esac
}

fleet_schedule_signals_defer() {
  # From the sealed step to the last bookkeeping write, a HUP, INT or TERM is
  # held here, not acted on. The sealed step's own processes may still die of
  # it (Ctrl-C signals the whole group), which is why, after a held signal,
  # the bookkeeping is decided from what the scheduler shows, not from the
  # step's status alone (fleet_schedule_record) — and the bookkeeping itself
  # runs with the signals ignored, so no `mkdir` or `rm` of it dies of one.
  # fleet_schedule_signals_replay exits with the held signal once the writes
  # are done.
  fleet_schedule_signal=
  trap 'fleet_schedule_signal=129' HUP
  trap 'fleet_schedule_signal=130' INT
  trap 'fleet_schedule_signal=143' TERM
}

fleet_schedule_signals_replay() {
  # A signal held by fleet_schedule_signals_defer ends the command now.
  fleet_lock_signals_exit
  [ -z "${fleet_schedule_signal:-}" ] || exit "$fleet_schedule_signal"
}

fleet_schedule_preflight() {
  # fleet_schedule_preflight install|uninstall — the refusals that come
  # before anything is planned. Nothing is changed by any of them.
  case $1 in
    uninstall)
      # A scheduler this session cannot reach may still hold the job: launchd
      # with no GUI domain (over SSH) cannot say whether an agent is loaded,
      # even one whose plist was deleted by hand, and a systemd user manager
      # running out of reach still runs its timers. Removing the definitions
      # then would leave a job running with no file. Refuse first
      # (fleet_schedule_out_of_reach).
      for preflight_mode in $fleet_schedule_modes; do
        ! fleet_schedule_out_of_reach "$preflight_mode" "$(fleet_schedule_facts "$preflight_mode")" || {
          printf 'roundhouse: the %s job is still installed, or was last seen loaded or disabled, but its scheduler is not reachable from this session (no GUI domain over SSH, or a systemd user manager this session cannot ask, e.g. XDG_RUNTIME_DIR unset); run uninstall from a login session. Nothing was changed.\n' \
            "$preflight_mode" >&2
          return 75
        }
      done
      ;;
    install)
      [ -x "$HOME/.local/bin/roundhouse" ] || {
        printf 'roundhouse: %s is not installed; run `roundhouse launcher-install` first — the scheduled jobs run that shim\n' \
          "$HOME/.local/bin/roundhouse" >&2
        return 69
      }
      # A superseded job that WORKS is not retired for a pair that would only
      # fail: the new jobs converge the fleet store, so it must be enrolled.
      # On disk or still loaded: either is a working job install would retire.
      install_legacy=$(fleet_schedule_legacy_entries | jq -r \
        '[.[] | select(.digest != null or .loaded) | .label] | join(" ")')
      if [ -n "$install_legacy" ] &&
        ! fleet_vcs_store_ready "$(fleet_store_path)" >/dev/null 2>&1; then
        printf 'roundhouse: a superseded scheduler entry is still installed (%s) and this host has no enrolled fleet store for the new jobs to converge; enroll it (roundhouse fleet-init / fleet-enroll), then re-run install. Nothing was changed.\n' \
          "$install_legacy" >&2
        return 69
      fi
      [ "$(fleet_schedule_platform)" != systemd ] || fleet_schedule_lingers_preflight
      ;;
  esac
}

fleet_schedule_record() {
  # fleet_schedule_record install|uninstall SEALED-STATUS [SIGNALLED] — the
  # host-local bookkeeping after the sealed step; its exit is the command's.
  # It is this host's own run state (store.run), like schedule-state, not a
  # target the sealed plan mutates. A write or removal that fails is
  # reported, never swallowed (73). Its caller runs it with HUP, INT and TERM
  # ignored, so a held signal waits for it.
  case $1 in
    uninstall)
      # Done when the sealed step succeeded — or, when a held signal
      # (SIGNALLED) ended that step, which it can after its removals and
      # before it reports, when the scheduler shows both jobs gone and let
      # go. Any other failure changes nothing here, and a job still there is
      # never opted out.
      if [ "$2" -ne 0 ]; then
        [ -n "${3:-}" ] && fleet_schedule_verify uninstall false 2>/dev/null || return "$2"
      fi
      # The opt-out: from here on a trigger stamps and starts nothing, and a
      # pass raises no schedule alert, until `install` is run again. If it
      # cannot be written the jobs are still gone, and re-running uninstall —
      # a no-op for the scheduler — records it.
      { mkdir -p "$(dirname "$(fleet_schedule_optout_path)")" &&
        printf 'uninstalled_at: %s\n' "$(fleet_now)" >"$(fleet_schedule_optout_path)"; } || {
        printf 'roundhouse: the scheduled jobs are removed, but the opt-out could not be recorded (%s); re-run `roundhouse fleet-schedule uninstall`\n' \
          "$(fleet_schedule_optout_path)" >&2
        return 73
      }
      # The install marker and remembered states go with the jobs, and a
      # full request no pass took yet with the jobs it was made of: a later
      # install must not inherit it as a full pass nobody asked for.
      record_failed=false
      rm -f "$(fleet_schedule_marker)" "$(fleet_trigger_full_path)" || record_failed=true
      for record_mode in $fleet_schedule_modes; do
        rm -f "$(fleet_schedule_state_path "$record_mode")" || record_failed=true
      done
      [ "$record_failed" != true ] || {
        printf 'roundhouse: the scheduled jobs are removed and the host opted out, but the install marker, remembered job states or pending full request under %s could not be removed; remove them, or re-run `roundhouse fleet-schedule uninstall`\n' \
          "$(fleet_run_state_dir)" >&2
        return 73
      }
      ;;
    install)
      case $2 in 0 | 75) ;; *) return "$2" ;; esac
      { mkdir -p "$(dirname "$(fleet_schedule_marker)")" &&
        printf 'platform: %s\ninstalled_at: %s\n' "$(fleet_schedule_platform)" \
          "$(fleet_now)" >"$(fleet_schedule_marker)" &&
        rm -f "$(fleet_schedule_optout_path)"; } || {
        printf 'roundhouse: the scheduled jobs are installed, but the install could not be recorded (%s); re-run `roundhouse fleet-schedule install`\n' \
          "$(fleet_schedule_marker)" >&2
        return 73
      }
      # Remember what the verified install left, so a later trigger with
      # no GUI domain to ask (over SSH) still knows the job is loaded.
      for record_mode in $fleet_schedule_modes; do
        fleet_schedule_job_state "$record_mode" >/dev/null || :
      done
      ;;
  esac
  return "$2"
}

# --- the command -----------------------------------------------------------------------

fleet_schedule_sealed() (
  # fleet_schedule_sealed install|uninstall — observe, plan, seal, recheck,
  # apply, verify (the file comment). Exit 0, install's 75 (written, loads
  # when the scheduler can be reached), or the failing step's status.
  errexit_require fleet_schedule_sealed
  sealed_action=$1
  check_mutation_config || exit $?
  fleet_schedule_def_paths fast >/dev/null || exit 69
  { fleet_schedule_def_paths fast; fleet_schedule_def_paths full; } |
    fleet_schedule_paths_in_home || {
    printf 'roundhouse: the fleet-schedule definitions would be written outside %s (XDG_CONFIG_HOME is %s); nothing was changed\n' \
      "$HOME" "${XDG_CONFIG_HOME:-unset}" >&2
    exit 64
  }
  sealed_target=$(local_plan_target "fleet-schedule $sealed_action") || exit $?
  sealed_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-schedule-plan.XXXXXX") || exit 73
  trap 'rm -rf "$sealed_tmp"' EXIT HUP INT TERM
  mkdir "$sealed_tmp/render" "$sealed_tmp/apply"
  ROUNDHOUSE_SCHEDULE_OBSERVE=1
  export ROUNDHOUSE_SCHEDULE_OBSERVE
  errexit_capture sealed_status collect_command --target "$sealed_target" --section agents \
    --output "$sealed_tmp/planning.jsonl"
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
    exit 70
  jq -n --arg target "$sealed_target" --arg action "$sealed_action" --argjson steps "$sealed_steps" '
    {domain:"agents",target:$target,operations:[{
      type:"agent-update",kind:"agent_artifact",id:"roundhouse:schedule",
      argv:["roundhouse","fleet-schedule",$action],steps:$steps
    }]}' >"$sealed_tmp/draft.json"
  errexit_capture sealed_status local_plan_seal_apply "$sealed_tmp/draft.json" \
    "$sealed_tmp/planning.jsonl" "$sealed_tmp/apply"
  [ "$sealed_status" -eq 0 ] || {
    printf 'roundhouse: the sealed fleet-schedule %s did not complete; nothing past the failing step was changed\n' \
      "$sealed_action" >&2
    exit 70
  }
  fleet_schedule_report "$sealed_action" "$(jq -c '.operations[0]' "$sealed_tmp/draft.json")" \
    "$sealed_reachable" "$sealed_record"
  fleet_schedule_verify "$sealed_action" "$sealed_reachable" || exit $?
  # An obsolete native task the Windows side would not let go of is the
  # operator's to remove from the desktop session: 75, named, after the local
  # jobs are verified in place.
  sealed_native=0
  if [ "$sealed_action" = install ] &&
    [ "$(printf '%s\n' "$sealed_record" | jq -r '.native.reachable == true')" = true ]; then
    fleet_schedule_native verify || sealed_native=$?
  fi
  # An install the scheduler could not take yet is 75 (written, loads later);
  # an uninstall has removed what it could see either way.
  [ "$sealed_action" != install ] || [ "$sealed_reachable" = true ] || {
    [ "$(fleet_schedule_platform)" != systemd ] || fleet_schedule_manager_unreachable_note
    exit 75
  }
  [ "$sealed_native" -eq 0 ] || exit 75
)

fleet_schedule_command() (
  # `roundhouse fleet-schedule install|status|uninstall` — this host's two
  # scheduled jobs. Host-local and operator-run: it never reaches another
  # host, and `install` is the only path in the system that enables a job.
  # `install` and `uninstall` ride the sealed-plan pipeline; `status` is
  # read-only.
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
      # Roundhouse has no native Windows runtime, so no Task Scheduler entry
      # here could run a pass: the machine's schedule is its WSL side's.
      printf 'roundhouse: fleet-schedule does not run on native Windows: roundhouse has no native runtime there (no fleet store, jj or launcher), so no Task Scheduler task could run a pass. Run `roundhouse fleet-schedule install|status` on the WSL side of this machine; it inspects this Task Scheduler over interop and removes obsolete Roundhouse one-shot tasks\n' >&2
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
  if [ "$1" = status ]; then
    fleet_schedule_status
    [ "$(fleet_schedule_platform)" != systemd ] || ! fleet_schedule_windows_host ||
      fleet_schedule_native status || exit $?
    exit 0
  fi
  # One install or uninstall at a time, held from the first look at the jobs
  # to the last bookkeeping write; a signal before the sealed step ends the
  # command and releases it.
  fleet_schedule_lock_take || exit $?
  trap 'fleet_lock_release "$(fleet_schedule_lock_path)" "$fleet_schedule_lock_nonce" || :' EXIT
  fleet_lock_signals_exit
  fleet_schedule_preflight "$1" || exit $?
  fleet_schedule_signals_defer
  errexit_capture command_sealed_status fleet_schedule_sealed "$1"
  command_status=0
  (
    trap '' HUP INT TERM
    fleet_schedule_record "$1" "$command_sealed_status" "$fleet_schedule_signal"
  ) || command_status=$?
  fleet_schedule_signals_replay
  exit "$command_status"
)
