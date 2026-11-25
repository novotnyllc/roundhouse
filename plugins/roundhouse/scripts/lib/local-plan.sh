# roundhouse — the sealed-plan pipeline for a HOST-LOCAL mutation: the one
# local target it plans for, and seal -> recheck -> apply over a draft the
# caller built from a planning snapshot. Shared by launcher-install and
# fleet-schedule install|uninstall, so neither has a mechanism of its own.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

local_plan_target() {
  # local_plan_target WHAT [TARGET] — the one configured LOCAL machine a
  # host-local mutation plans for: TARGET when given (it must be local, with
  # expected_hostname and expected_user), else the single local entry whose
  # expected hostname and user are this host's. Never chosen by JSON order.
  local_plan_what=$1
  local_plan_requested=${2:-}
  local_plan_config=$(config_path)
  if [ -n "$local_plan_requested" ]; then
    jq -e --arg target "$local_plan_requested" '
      .machines[$target].transport == "local" and
      (.machines[$target].expected_hostname | type == "string" and length > 0) and
      (.machines[$target].expected_user | type == "string" and length > 0)
    ' "$local_plan_config" >/dev/null || {
      printf 'roundhouse: %s target must be one local machine with expected_hostname and expected_user\n' \
        "$local_plan_what" >&2
      return 64
    }
    printf '%s\n' "$local_plan_requested"
    return 0
  fi
  local_plan_candidates=$(jq -r --arg hostname "$(hostname)" --arg user "$(id -un)" '
    .machines | to_entries[] |
    select(.value.transport == "local" and
      .value.expected_hostname == $hostname and .value.expected_user == $user) |
    .key
  ' "$local_plan_config")
  [ "$(printf '%s\n' "$local_plan_candidates" | grep -c . || true)" -eq 1 ] || {
    printf 'roundhouse: %s requires one local target matching hostname/user; pass TARGET explicitly\n' \
      "$local_plan_what" >&2
    return 64
  }
  printf '%s\n' "$local_plan_candidates"
}

local_plan_seal_apply() (
  # local_plan_seal_apply DRAFT PLANNING WORKDIR — the
  # sealed-plan pipeline for a host-local mutation, shared by every one
  # (launcher-install, fleet-schedule install|uninstall):
  #
  #   seal      DRAFT against PLANNING, the snapshot it was built from: the
  #             operations' preconditions become the plan's precondition
  #             digest, and the target's identity is bound;
  #   recheck   apply-plan's own preflight: a FRESH collect, compared with the
  #             sealed preconditions, the configured identity and the sealed
  #             executor immediately before the first operation runs;
  #   apply     only the sealed operations, then their postconditions in a
  #             post-change collect.
  #
  # The recheck is apply-plan's, not a second one here: one taken before
  # apply-plan starts is older than apply-plan's own, so it proves nothing
  # that one does not, and costs a full collect and executor verification.
  #
  # Whatever selects a special collector mode (ROUNDHOUSE_LAUNCHER_PATH,
  # ROUNDHOUSE_SCHEDULE_OBSERVE) is the caller's to export before PLANNING is
  # collected. Exit 0 only when the apply completed.
  #
  # seal-plan and apply-plan stop on their first failed check through
  # errexit, so this runs under it and calls them plainly. It refuses to run
  # where errexit is suppressed (errexit_require): call it plainly, or capture
  # its status with errexit_capture — never `… || status=$?`.
  errexit_require local_plan_seal_apply
  set -e
  local_plan_draft=$1
  local_plan_planning=$2
  local_plan_work=$3
  seal_plan_command "$local_plan_draft" "$local_plan_planning" "$local_plan_work/plan.json"
  local_plan_id=$(jq -r '.plan_id' "$local_plan_work/plan.json")
  apply_plan_command "$local_plan_work/plan.json" "$local_plan_id" \
    "$local_plan_work/result.jsonl" >/dev/null
  jq -s -e --arg plan "$local_plan_id" '
    any(.[]; type == "object" and .kind == "operation" and
      .id == ("apply:" + $plan) and .data.operation_status == "completed")
  ' "$local_plan_work/result.jsonl" >/dev/null
)
