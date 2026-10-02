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
#             the superseded entries, the scheduler's reachability;
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
  jq -cn --arg platform "$observe_platform" --arg domain "$(fleet_schedule_gui_domain)" \
    --argjson reachable "$observe_reachable" --argjson lingers "$observe_lingers" \
    --argjson opted_out "$observe_optout" --argjson files "$observe_files" \
    --argjson jobs "$observe_jobs" --argjson legacy "$observe_legacy" \
    '{id:"roundhouse:schedule",artifact_kind:"schedule",platform:$platform,
      domain:(if $platform == "launchd" then $domain else null end),
      scheduler_reachable:$reachable,lingers:$lingers,opted_out:$opted_out,
      files:$files,jobs:$jobs,legacy:$legacy}'
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
    fleet_schedule_run_step legacy unload false launchctl bootout "$launchd_domain/$launchd_label"
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
  # fleet_schedule_systemd_plan ACTION MODE WRITTEN JOB — the per-job steps
  # an uninstall needs; install's come after every unit is written
  # (fleet_schedule_systemd_plan_finish).
  [ "$1" = uninstall ] || return 0
  if [ "$(printf '%s\n' "$4" | jq -r '.enabled or .active')" = true ]; then
    fleet_schedule_command_step "$2" disable-stop true
  fi
}

fleet_schedule_launchd_plan_finish() {
  # fleet_schedule_launchd_plan_finish ACTION CHANGED REACHABLE RECORD —
  # Absorb, never duplicate (fleet-update): only after the new pair, and
  # renamed BEFORE it is unloaded — a rename that fails leaves the superseded
  # entry on disk and running. The new name is sealed too.
  [ "$1" = install ] || return 0
  printf '%s\n' "$4" | jq -c '.legacy[]' | while IFS= read -r finish_file; do
    [ -n "$finish_file" ] || continue
    finish_path=$(printf '%s\n' "$finish_file" | jq -r '.path')
    finish_to="$finish_path.absorbed"
    [ ! -e "$finish_to" ] || finish_to="$finish_path.absorbed.$(date -u +%Y%m%dT%H%M%SZ)"
    printf '%s\n' "$finish_file" | jq -c --arg to "$finish_to" \
      '{action:"absorb",path,before:.digest,to:$to}'
    [ "$3" != true ] || fleet_schedule_run_step legacy unload false launchctl bootout \
      "$(fleet_schedule_gui_domain)/$(basename "$finish_path" .plist)"
  done
}

fleet_schedule_systemd_plan_finish() {
  # fleet_schedule_systemd_plan_finish ACTION CHANGED REACHABLE RECORD
  [ "$3" = true ] || return 0
  case $1 in
    install)
      [ "$2" != true ] || fleet_schedule_command_step all reload
      for finish_mode in $fleet_schedule_modes; do
        if [ "$(printf '%s\n' "$4" | jq -r --arg mode "$finish_mode" \
          'first(.jobs[] | select(.mode == $mode)) | .enabled and .active')" = true ]; then
          [ "$2" != true ] || fleet_schedule_command_step "$finish_mode" restart
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
    # file behind it.
    if [ "$plan_action" = uninstall ] && [ "$plan_reachable" = true ]; then
      fleet_schedule_backend plan uninstall "$plan_mode" false "$plan_job" \
        >>"$plan_work/steps.jsonl" || return 70
      ! grep -q '"action":"run"' "$plan_work/steps.jsonl" || plan_changed=true
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
      write | keep | remove | absorb)
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
      *) exit 64 ;;
    esac
  done
)

# --- report and verify ----------------------------------------------------------------

fleet_schedule_report() {
  # fleet_schedule_report install|uninstall OPERATION-JSON REACHABLE — what the
  # applied plan did, one line per definition, read from the sealed steps'
  # actions and effects.
  printf '%s\n' "$2" | jq -r --arg action "$1" --argjson reachable "$3" \
    --arg platform "$(fleet_schedule_platform)" '
    .steps as $steps |
    ($steps | map(select(.action == "absorb"))) as $absorbed |
    (["fast","full"][] as $mode |
      ($steps | map(select(.mode == $mode))) as $s |
      if $action == "uninstall" then
        ($s | map(select(.action == "remove"))) as $removed |
        if ($removed | length) == 0 then "fleet-\($mode): not installed"
        else $removed[] | "fleet-\($mode): removed \(.path)" end
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
    ($absorbed[] | "roundhouse: absorbed the superseded \(.path | split("/") | last | rtrimstr(".plist")) entry (kept as \(.to))")'
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
      # A scheduler this session cannot reach may still hold the job: launchd
      # with no GUI domain (over SSH) cannot say whether a present agent is
      # loaded, and a systemd user manager out of reach still enables a timer
      # through its timers.target.wants link. Removing the definitions then
      # would leave a job running with no file. Refuse first.
      for uninstall_mode in $fleet_schedule_modes; do
        fleet_schedule_facts_read "$(fleet_schedule_facts "$uninstall_mode")"
        [ "$sf_reachable" = 1 ] || { [ "$sf_wants" != 1 ] && [ "$sf_present" != 1 ]; } || {
          printf 'roundhouse: the %s job is still installed but its scheduler is not reachable from this session (no GUI domain over SSH, or no systemd user manager); run uninstall from a login session. Nothing was changed.\n' \
            "$uninstall_mode" >&2
          exit 75
        }
      done
      errexit_capture uninstall_status fleet_schedule_sealed uninstall
      [ "$uninstall_status" -eq 0 ] || exit "$uninstall_status"
      # The opt-out: from here on a trigger stamps and starts nothing, and a
      # pass raises no schedule alert, until `install` is run again. It is
      # this host's own run state (store.run), like schedule-state, not a
      # target the sealed plan mutates. A write that fails is reported, never
      # swallowed: the jobs are gone, and re-running uninstall — a no-op for
      # the scheduler — records it.
      { mkdir -p "$(dirname "$(fleet_schedule_optout_path)")" &&
        printf 'uninstalled_at: %s\n' "$(fleet_now)" >"$(fleet_schedule_optout_path)"; } || {
        printf 'roundhouse: the scheduled jobs are removed, but the opt-out could not be recorded (%s); re-run `roundhouse fleet-schedule uninstall`\n' \
          "$(fleet_schedule_optout_path)" >&2
        exit 73
      }
      rm -f "$(fleet_schedule_marker)"
      for uninstall_mode in $fleet_schedule_modes; do
        rm -f "$(fleet_schedule_state_path "$uninstall_mode")"
      done
      # A full request no pass took yet goes with the jobs it was made of: a
      # later install must not inherit it as a full pass nobody asked for.
      rm -f "$(fleet_trigger_full_path)"
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
      errexit_capture install_status fleet_schedule_sealed install
      case $install_status in
        0 | 75)
          mkdir -p "$(dirname "$(fleet_schedule_marker)")"
          printf 'platform: %s\ninstalled_at: %s\n' "$(fleet_schedule_platform)" \
            "$(fleet_now)" >"$(fleet_schedule_marker)"
          rm -f "$(fleet_schedule_optout_path)"
          # Remember what the verified install left, so a later trigger with
          # no GUI domain to ask (over SSH) still knows the job is loaded.
          for install_mode in $fleet_schedule_modes; do
            fleet_schedule_job_state "$install_mode" >/dev/null || :
          done
          ;;
      esac
      exit "$install_status"
      ;;
  esac
)
