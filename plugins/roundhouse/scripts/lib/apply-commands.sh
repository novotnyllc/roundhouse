# roundhouse — the apply surface: sealed broker operations, mixed and
# privileged plan application, SSH plans, and privilege result lookup.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

execute_sealed_posix_broker_operation() {
  plan=$1
  index=$2
  work=$3
  outcome=$4
  request_id=$(jq -r --argjson index "$index" '.operations[$index].privilege.request.id' "$plan")
  plan_id=$(jq -r '.plan_id' "$plan")
  action_id=$(jq -r --argjson index "$index" '.operations[$index].id' "$plan")
  protocol=$(jq -r --argjson index "$index" '.operations[$index].privilege.broker.protocol_version' "$plan")
  target=$(jq -r '.target' "$plan")
  if [ "$protocol" != 1 ]; then
    printf 'rejected|needs_broker_upgrade|-|-|-\n' >"$outcome"
    return 69
  fi
  make_posix_broker_envelope "$plan" "$index" "$action_id" "$work/envelope-$index" || {
    printf 'stale|broker_envelope_unavailable|-|-|-\n' >"$outcome"
    return 70
  }
  write_posix_journal_expectations "$plan" "$index" "$work/envelope-$index" \
    "$work/journal-expectations-$index" || {
    printf 'stale|journal_expectation_unavailable|-|-|-\n' >"$outcome"
    return 70
  }
  invoke_posix_broker_for_target "$target" "$work/envelope-$index" "$work/broker-$index" || true
  if terminal=$(posix_broker_terminal_result "$work/broker-$index" "$request_id" "$plan_id" \
      "$action_id" true "$protocol" "$work/journal-expectations-$index"); then
    printf '%s\n' "$terminal" >"$outcome"
  else
    make_posix_broker_envelope "$plan" "$index" broker.query-result.v1 "$work/query-envelope-$index" || {
      printf 'stale|broker_result_unavailable|-|-|-\n' >"$outcome"
      return 70
    }
    invoke_posix_broker_for_target "$target" "$work/query-envelope-$index" "$work/broker-query-$index" || true
    if terminal=$(posix_broker_terminal_result "$work/broker-query-$index" "$request_id" "$plan_id" \
        "$action_id" false "$protocol" "$work/journal-expectations-$index"); then
      printf '%s\n' "$terminal" >"$outcome"
    else
      printf 'stale|broker_result_unavailable|-|-|-\n' >"$outcome"
      return 70
    fi
  fi
  case $(sed -n '1p' "$outcome" | cut -d '|' -f 1) in
    completed) return 0 ;;
    *) return 70 ;;
  esac
}

execute_sealed_windows_broker_operation() {
  plan=$1
  index=$2
  work=$3
  outcome=$4
  trusted_projection=${5:-false}
  action_id=$(jq -r --argjson index "$index" '.operations[$index].id' "$plan")
  request_id=$(jq -r --argjson index "$index" '.operations[$index].privilege.request.id' "$plan")
  payload=-
  if [ "$action_id" = profile.apply-managed-bundle.v1 ]; then
    bundle_root=${ROUNDHOUSE_PROFILE_BUNDLE_DIR:-}
    case $bundle_root in /*) ;; *) bundle_root= ;; esac
    payload=$bundle_root/$request_id.bundle
    [ -n "$bundle_root" ] && [ -f "$payload" ] && [ ! -L "$payload" ] || {
      printf 'stale|profile_bundle_unavailable|-|-|-\n' >"$outcome"
      return 70
    }
  fi
  slot=$work/windows-slot-$index
  mkdir "$slot"
  if ! make_windows_broker_slot "$plan" "$index" "$payload" "$slot" \
      "$work/pre-operation-$index.jsonl" "$trusted_projection"; then
    printf 'stale|windows_slot_unavailable|-|-|-\n' >"$outcome"
    return 70
  fi
  if ! windows_sftp_submit_slot "$(jq -r '.target' "$plan")" "$slot"; then
    printf 'partial|windows_submission_interrupted|-|-|-\n' >"$outcome"
    return 70
  fi
  if ! windows_sftp_poll_result "$(jq -r '.target' "$plan")" "$plan" "$index" "$outcome" \
      "$trusted_projection"; then
    return 70
  fi
  case $(sed -n '1p' "$outcome" | cut -d '|' -f 1) in
    completed) return 0 ;;
    *) return 70 ;;
  esac
}

write_mixed_apply_operation_record() {
  destination=$1
  plan=$2
  index=$3
  snapshot_id=$4
  target=$5
  observed_at=$6
  operation_status=$7
  reason=$8
  broker_state=$9
  evidence_kind=${10}
  evidence_digest=${11}
  projection_digest=${12}
  plan_id=$(jq -r '.plan_id' "$plan")
  domain=$(jq -r '.domain' "$plan")
  contracts=$(privileged_action_contract_json)
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --slurpfile plan "$plan" --argjson index "$index" --arg snapshot_id "$snapshot_id" \
    --arg host_id "$target" --arg observed_at "$observed_at" --arg plan_id "$plan_id" \
    --arg domain "$domain" --arg operation_status "$operation_status" --arg reason "$reason" \
    --arg broker_state "$broker_state" --arg evidence_kind "$evidence_kind" \
    --arg evidence_digest "$evidence_digest" --arg projection_digest "$projection_digest" \
    --argjson contracts "$contracts" '
    $plan[0].operations[$index] as $operation |
    ($contracts[$operation.id] // null) as $contract |
    {
      schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"operation",id:("apply:" + $plan_id + ":" + ($index|tostring)),observed_at:$observed_at,
      status:(if $operation_status == "completed" then "present" else "partial" end),confidence:"high",
      data:{run_id:$snapshot_id,host_id:$host_id,scope:[$domain],phase:"apply",
        operation_status:$operation_status,plan_id:$plan_id,index:$index,operation_id:$operation.id,
        operation_type:$operation.type,
        privilege_contract:(if $operation.type == "semantic-action" then
          {action_id:$operation.id,context_id:$contract.context,
            policy_token_bound:($contract.token == "protected")}
          else null end),
        broker_state:(if $broker_state == "-" then null else $broker_state end),
        authoritative_result_evidence:(if $evidence_kind == "-" then null else
          {kind:$evidence_kind,digest:{algorithm:"sha256",value:$evidence_digest},
            public_projection_digest:(if $projection_digest == "-" then null else
              {algorithm:"sha256",value:$projection_digest} end)} end),
        result_reason:$reason,
        transport:(if $operation.type == "semantic-action" then $operation.privilege.request.transport else "local" end)},
      evidence:([{source:"sealed-plan",method:"ordered-v4-apply"}] +
        (if $evidence_kind == "-" then [] else [{source:"protected-terminal",method:$evidence_kind,
          digest:{algorithm:"sha256",value:$evidence_digest},
          public_projection_digest:(if $projection_digest == "-" then null else
            {algorithm:"sha256",value:$projection_digest} end)}] end)),
      errors:(if $operation_status == "completed" or $operation_status == "skipped" then [] else
        [{code:"apply_operation_failed",severity:"error",retryable:false,
          message:"The ordered sealed operation did not complete"}] end)
    }' >>"$destination"
}

apply_mixed_privileged_plan_command() {
  plan=$1
  confirmation=$2
  output=$3
  native_mode=${4:-false}
  verification_plan=${5:-$plan}
  trusted_projection=${6:-false}
  initial_readiness=${7:-}
  require_jq
  check_mutation_config
  check_private_owned_file "$plan" "mixed apply plan"
  [ "$(jq -r '.plan_id // empty' "$plan" 2>/dev/null || true)" = "$confirmation" ] || {
    printf 'roundhouse: apply confirmation must equal the sealed mixed plan ID\n' >&2
    return 64
  }
  if [ "$trusted_projection" = true ]; then
    validate_privileged_plan_file "$verification_plan"
  else
    validate_mixed_privileged_plan_file "$plan"
  fi
  config=$(config_path)
  target=$(jq -r '.target' "$plan")
  transport=$(jq -r --arg target "$target" '.machines[$target].transport // empty' "$config")
  platform=$(jq -r --arg target "$target" '.machines[$target].platform // empty' "$config")
  route_mode=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // empty' "$config")
  standalone_windows_sftp=false
  if [ "$trusted_projection" = true ] &&
    [ "$platform:$transport:$route_mode" = windows:codex-remote-control:windows-sftp ]; then
    standalone_windows_sftp=true
  fi
  if [ "$native_mode" != false ]; then
    printf 'roundhouse: protected plans require their fixed broker transport\n' >&2
    return 69
  fi
  case $platform:$transport:$route_mode in
    linux:local:posix-ssh|linux:ssh:posix-ssh|macos:local:posix-ssh|macos:ssh:posix-ssh|\
    windows:codex-remote-control:windows-sftp) ;;
    *)
      printf 'roundhouse: protected apply has no fixed platform broker route; SSH, WSL, and context fallback are forbidden\n' >&2
      return 69
      ;;
  esac
  if [ "$trusted_projection" != true ] &&
    [ "$platform:$transport:$route_mode" = windows:codex-remote-control:windows-sftp ]; then
    printf 'roundhouse: mixed Windows plans require ordinary Codex inventory; protected SFTP readiness is execution-only\n' >&2
    return 69
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-v4-apply.XXXXXX")
  trap 'rm -rf "$work"' EXIT HUP INT TERM
  required_section=$(jq -r '.required_section' "$plan")
  preflight_ok=true
  if [ "$standalone_windows_sftp" = true ]; then
    if [ -n "$initial_readiness" ] && [ -f "$initial_readiness" ] && [ ! -L "$initial_readiness" ]; then
      cp "$initial_readiness" "$work/pre.jsonl"
    elif ! windows_sftp_readiness_snapshot "$target" "$work/pre.jsonl"; then
      preflight_ok=false
    fi
  elif ! "$script_dir/roundhouse" collect --target "$target" --section host --section "$required_section" \
      --output "$work/pre.jsonl"; then
    preflight_ok=false
  fi
  [ -f "$work/pre.jsonl" ] && validate_file "$work/pre.jsonl" || preflight_ok=false
  if [ "$preflight_ok" = true ]; then
    if [ "$standalone_windows_sftp" = true ]; then
      verify_mixed_configuration_binding "$verification_plan" &&
        verify_executor_requirement "$verification_plan" >/dev/null &&
        verify_mixed_privilege_readiness "$plan" "$work/pre.jsonl" windows-sftp-execution &&
        mixed_privilege_actions_compatible "$plan" || preflight_ok=false
    elif [ "$trusted_projection" = true ]; then
      verify_privileged_preconditions_command "$verification_plan" "$work/pre.jsonl" >/dev/null || preflight_ok=false
    else
      verify_mixed_privileged_preconditions_command "$plan" "$work/pre.jsonl" >/dev/null || preflight_ok=false
    fi
  fi
  operation_count=$(jq '.operations | length' "$plan")
  index=0
  completed_operation_count=0
  first_failed_index=null
  if [ "$preflight_ok" = false ]; then
    printf 'failed|preflight_verification_failed|-|-|-|-\n' >"$work/state-0"
    first_failed_index=0
    index=1
  else
    while [ "$index" -lt "$operation_count" ]; do
    jq ".operations[$index]" "$plan" >"$work/operation-$index.json"
    operation_type=$(jq -r '.type' "$work/operation-$index.json")
    if [ "$operation_type" = semantic-action ]; then
      operation_ready=true
      if [ "$standalone_windows_sftp" = true ]; then
        if ! windows_sftp_readiness_snapshot "$target" "$work/pre-operation-$index.jsonl" ||
          ! validate_file "$work/pre-operation-$index.jsonl" || ! check_mutation_config ||
          ! verify_mixed_configuration_binding "$verification_plan" ||
          ! verify_executor_requirement "$verification_plan" >/dev/null ||
          ! verify_mixed_privilege_readiness "$plan" "$work/pre-operation-$index.jsonl" \
            windows-sftp-execution; then
          operation_ready=false
        fi
      elif ! "$script_dir/roundhouse" collect --target "$target" --section host --section "$required_section" \
          --output "$work/pre-operation-$index.jsonl" ||
        ! validate_file "$work/pre-operation-$index.jsonl" || ! check_mutation_config; then
        operation_ready=false
      elif [ "$trusted_projection" = true ]; then
        verify_privileged_preconditions_command "$verification_plan" \
          "$work/pre-operation-$index.jsonl" >/dev/null || operation_ready=false
      elif ! verify_mixed_configuration_binding "$plan" ||
        ! verify_executor_requirement "$plan" >/dev/null ||
        ! verify_mixed_privilege_readiness "$plan" "$work/pre-operation-$index.jsonl"; then
        operation_ready=false
      fi
      if [ "$operation_ready" = false ]; then
        printf 'failed|broker_readiness_changed|stale|-|-|-\n' >"$work/state-$index"
        first_failed_index=$index
        index=$((index + 1))
        break
      fi
      sealed_context=$(jq -r '.privilege.context.required' "$work/operation-$index.json")
      if { { [ "$sealed_context" = posix-root-v1 ] || [ "$sealed_context" = macos-root-v1 ]; } &&
          execute_sealed_posix_broker_operation "$plan" "$index" "$work" "$work/outcome-$index"; } ||
        { case $sealed_context in windows-*) true ;; *) false ;; esac &&
          execute_sealed_windows_broker_operation "$plan" "$index" "$work" "$work/outcome-$index" \
            "$trusted_projection"; }; then
        IFS='|' read -r broker_state broker_reason evidence_kind evidence_digest projection_digest <"$work/outcome-$index"
        printf 'completed|%s|%s|%s|%s|%s\n' "$broker_reason" "$broker_state" \
          "$evidence_kind" "$evidence_digest" "$projection_digest" >"$work/state-$index"
        completed_operation_count=$((completed_operation_count + 1))
      else
        IFS='|' read -r broker_state broker_reason evidence_kind evidence_digest projection_digest <"$work/outcome-$index"
        printf 'failed|%s|%s|%s|%s|%s\n' "$broker_reason" "$broker_state" \
          "$evidence_kind" "$evidence_digest" "$projection_digest" >"$work/state-$index"
        first_failed_index=$index
        index=$((index + 1))
        break
      fi
    elif execute_plan_operation "$work/operation-$index.json" "$config" "$target"; then
      printf 'completed|normal_operation_completed|-|-|-|-\n' >"$work/state-$index"
      completed_operation_count=$((completed_operation_count + 1))
    else
      printf 'failed|normal_operation_failed|-|-|-|-\n' >"$work/state-$index"
      first_failed_index=$index
      index=$((index + 1))
      break
    fi
      index=$((index + 1))
    done
  fi
  while [ "$index" -lt "$operation_count" ]; do
    printf 'skipped|not_run_after_first_failure|-|-|-|-\n' >"$work/state-$index"
    index=$((index + 1))
  done

  post_status=completed
  sealed_evidence_method=ordered-v4-broker-execution+post-inventory
  if [ "$standalone_windows_sftp" = true ]; then
    sealed_evidence_method=standalone-windows-sftp-broker-execution+protected-readiness
    if windows_sftp_readiness_snapshot "$target" "$work/post.jsonl"; then
      post_status=protected-readiness-only
    else
      post_status=partial
    fi
  elif ! "$script_dir/roundhouse" collect --target "$target" --section host --section "$required_section" \
      --output "$work/post.jsonl"; then
    post_status=partial
  fi
  if [ ! -f "$work/post.jsonl" ] || ! validate_file "$work/post.jsonl"; then
    if [ -f "$work/pre.jsonl" ] && validate_file "$work/pre.jsonl"; then
      cp "$work/pre.jsonl" "$work/post.jsonl"
      post_status=partial
    else
      printf 'roundhouse: mixed apply could not produce authoritative inventory\n' >&2
      return 70
    fi
  fi
  snapshot_id=$(jq -r 'select(.kind == "snapshot") | .snapshot_id' "$work/post.jsonl")
  observed_at=$(jq -r 'select(.kind == "snapshot") | .observed_at' "$work/post.jsonl")
  : >"$work/apply-operations.jsonl"
  result_index=0
  while [ "$result_index" -lt "$operation_count" ]; do
    IFS='|' read -r result_status result_reason result_broker_state result_evidence_kind \
      result_evidence_digest result_projection_digest <"$work/state-$result_index"
    write_mixed_apply_operation_record "$work/apply-operations.jsonl" "$plan" "$result_index" \
      "$snapshot_id" "$target" "$observed_at" "$result_status" "$result_reason" "$result_broker_state" \
      "$result_evidence_kind" "$result_evidence_digest" "$result_projection_digest"
    result_index=$((result_index + 1))
  done
  apply_status=completed
  [ "$first_failed_index" = null ] &&
    { [ "$post_status" = completed ] || [ "$post_status" = protected-readiness-only ]; } || apply_status=partial
  plan_id=$(jq -r '.plan_id' "$plan")
  domain=$(jq -r '.domain' "$plan")
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" \
    --arg plan_id "$plan_id" --arg domain "$domain" --argjson operation_count "$operation_count" \
    --argjson completed_operation_count "$completed_operation_count" --argjson failed_operation_index "$first_failed_index" \
    --arg operation_status "$apply_status" --arg post_inventory_status "$post_status" \
    --arg sealed_evidence_method "$sealed_evidence_method" --slurpfile plan "$plan" \
    --slurpfile operation_records "$work/apply-operations.jsonl" '
    {schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"operation",id:("apply:" + $plan_id),observed_at:$observed_at,
      status:(if $operation_status == "completed" then "present" else "partial" end),confidence:"high",
      data:{run_id:$snapshot_id,host_id:$host_id,scope:[$domain],phase:"verify",
        operation_status:$operation_status,plan_id:$plan_id,domain:$domain,
        operation_count:$operation_count,completed_operation_count:$completed_operation_count,
        failed_operation_index:$failed_operation_index,post_inventory_status:$post_inventory_status,
        authoritative_result_evidence:[$operation_records[] |
          select(.data.authoritative_result_evidence != null) |
          {index:.data.index,operation_id:.data.operation_id,evidence:.data.authoritative_result_evidence}],
        transport:(if any($plan[0].operations[]; .type == "semantic-action" and
          .privilege.request.transport == "windows-sftp") then "windows-sftp" else "local" end),
        executor:$plan[0].required_executor},
      evidence:([{source:"sealed-plan",method:$sealed_evidence_method}] +
        [$operation_records[] | select(.data.authoritative_result_evidence != null) |
          {source:"protected-terminal",method:.data.authoritative_result_evidence.kind,
            operation_index:.data.index,digest:.data.authoritative_result_evidence.digest,
            public_projection_digest:.data.authoritative_result_evidence.public_projection_digest}]),
      errors:(if $operation_status == "completed" then [] else
        [{code:"apply_partial",severity:"error",retryable:false,
          message:"One or more ordered operations did not complete"}] end)}' >"$work/apply-summary.jsonl"
  jq -sc 'sort_by(.host_id,.kind,.id)[]' "$work/post.jsonl" "$work/apply-operations.jsonl" \
    "$work/apply-summary.jsonl" >"$work/result.jsonl"
  validate_file "$work/result.jsonl"
  safe_output "$work/result.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$work"
  [ "$apply_status" = completed ] || return 70
}

normalize_privileged_plan_for_broker_execution() (
  plan=$1
  snapshot=$2
  output=$3
  validate_privileged_plan_file "$plan"
  validate_file "$snapshot"
  context=$(jq -r '.privilege.context.required' "$plan")
  if [[ $context == windows-* ]]; then
    action_id=$(jq -r '.privilege.action.id' "$plan")
    policy_token=$(jq -r '.privilege.action.policy_token // "-"' "$plan")
    sealed_precondition=$(jq -r '.privilege.precondition.digest.value' "$plan")
    current_precondition=$(privilege_action_precondition_digest "$snapshot" "$action_id" "$policy_token" || true)
    [ "$sealed_precondition" = "$current_precondition" ] || {
      printf 'roundhouse: current action precondition does not match the sealed privilege plan\n' >&2
      return 65
    }
  fi
  jq -e -S -s --slurpfile plan "$plan" '
    $plan[0] as $plan |
    first(.[] | select(.kind == "privilege_broker" and .id == "readiness" and .status == "present")).data as $r |
    $plan.privilege.context.required as $context |
    $plan |
    .schema_version = 4 |
    .operations[0].privilege = .privilege |
    .operations[0].privilege.request += {
      target_uid:(if ($context | IN("posix-root-v1","macos-root-v1")) then ($r.protected_identity.uid | tostring) else "-" end),
      request_sid:(if ($context | startswith("windows-")) then $r.protected_identity.sid else "-" end),
      certificate_source_addresses:$r.originating_node_identity.certificate_source_addresses
    } |
    .operations[0].privilege.context.platform_context_digest =
      (if ($context | startswith("windows-")) then $r.observed_winget_context_digest
       elif $context == "macos-root-v1" then $r.observed_platform_context_digest
       else null end) |
    del(.privilege)
  ' "$snapshot" >"$output" || {
    printf 'roundhouse: could not normalize the verified standalone privilege plan\n' >&2
    return 65
  }
  chmod 600 "$output"
)

fresh_posix_broker_readiness_snapshot() (
  target=$1
  output=$2
  config=$(config_path)
  validate_config_file
  platform=$(jq -r --arg target "$target" '.machines[$target].platform // empty' "$config")
  transport=$(jq -r --arg target "$target" '.machines[$target].transport // empty' "$config")
  route=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // empty' "$config")
  case $platform:$transport:$route in
    linux:ssh:posix-ssh|macos:ssh:posix-ssh)
      # This path enters only through the pinned forced dispatcher; it never
      # falls back to ordinary SSH collection or controller-local identity.
      posix_dispatch_readiness_snapshot "$target" "$output"
      ;;
    linux:local:posix-ssh|macos:local:posix-ssh)
      collect_command --target "$target" --section host --output "$output"
      ;;
    *)
      printf 'roundhouse: protected POSIX readiness has no dedicated target route\n' >&2
      return 69
      ;;
  esac
)

apply_privileged_plan_command() (
  plan=$1
  confirmation=$2
  output=$3
  native_mode=${4:-false}
  require_jq || exit $?
  check_mutation_config || exit $?
  check_private_owned_file "$plan" "privileged apply plan" || exit $?
  validate_privileged_plan_file "$plan" || exit $?
  [ "$(jq -r '.plan_id' "$plan")" = "$confirmation" ] || {
    printf 'roundhouse: apply confirmation must equal the sealed privilege plan ID\n' >&2
    exit 64
  }
  privileged_plan_integrity_check "$plan" || exit $?
  [ "$native_mode" = false ] || {
    printf 'roundhouse: protected plans require their fixed broker transport\n' >&2
    exit 69
  }
  target=$(jq -r '.target' "$plan")
  required_section=$(jq -r '.required_section' "$plan")
  config=$(config_path)
  platform=$(jq -r --arg target "$target" '.machines[$target].platform // empty' "$config")
  transport=$(jq -r --arg target "$target" '.machines[$target].transport // empty' "$config")
  route_mode=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // empty' "$config")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-v3-execution.XXXXXX") || exit $?
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  if [ "$platform:$transport:$route_mode" = windows:codex-remote-control:windows-sftp ]; then
    verify_mixed_configuration_binding "$plan" || exit $?
    verify_executor_requirement "$plan" >/dev/null || exit $?
    windows_sftp_readiness_snapshot "$target" "$tmp/current.jsonl" || exit $?
    validate_file "$tmp/current.jsonl" || exit $?
  else
    "$script_dir/roundhouse" collect --target "$target" --section host --section "$required_section" \
      --output "$tmp/current.jsonl" || exit $?
    validate_file "$tmp/current.jsonl" || exit $?
    verify_privileged_preconditions_command "$plan" "$tmp/current.jsonl" >/dev/null || exit $?
  fi
  normalize_privileged_plan_for_broker_execution "$plan" "$tmp/current.jsonl" "$tmp/executable.json" || exit $?
  result=0
  apply_mixed_privileged_plan_command "$tmp/executable.json" "$confirmation" "$output" false \
    "$plan" true "$tmp/current.jsonl" || result=$?
  rm -rf "$tmp"
  trap - EXIT HUP INT TERM
  exit "$result"
)

apply_plan_command() {
  plan=$1
  confirmation=$2
  output=$3
  native_mode=${4:-false}
  require_jq
  plan_id=$(jq -r '.plan_id // empty' "$plan" 2>/dev/null || true)
  [ -n "$plan_id" ] && [ "$confirmation" = "$plan_id" ] || {
    printf 'roundhouse: apply confirmation must equal the sealed plan ID\n' >&2
    exit 64
  }
  if jq -e '.schema_version == 4' "$plan" >/dev/null 2>&1; then
    apply_mixed_privileged_plan_command "$plan" "$confirmation" "$output" "$native_mode"
    return
  fi
  if jq -e '.schema_version == 3 or has("privilege")' "$plan" >/dev/null 2>&1; then
    apply_privileged_plan_command "$plan" "$confirmation" "$output" "$native_mode"
    return
  fi
  config=$(config_path)
  target=$(jq -r '.target' "$plan")
  transport=$(jq -r --arg target "$target" '.machines[$target].transport' "$config")
  if [ "$native_mode" = true ]; then
    [ "$transport" = ssh ] || {
      printf 'roundhouse: native POSIX apply requires an SSH-configured target\n' >&2
      exit 69
    }
    if jq -e 'any(.operations[]; .type == "auth-reauth")' "$plan" >/dev/null; then
      printf 'roundhouse: interactive reauthentication requires a visible target terminal\n' >&2
      exit 69
    fi
  else
    [ "$transport" = local ] || {
      printf 'roundhouse: %s apply must execute through its target-native task transport\n' "$transport" >&2
      exit 69
    }
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-apply.XXXXXX")
  trap 'rm -rf "$work"' EXIT HUP INT TERM
  section=$(jq -r '.required_section' "$plan")
  set -- --target "$target" --section host --section "$section"
  [ "$section" != agents ] || set -- "$@" --section auth
  [ "$native_mode" != true ] || set -- "$@" --native-target
  if ! "$script_dir/roundhouse" collect "$@" --output "$work/pre.jsonl"; then
    printf 'roundhouse: apply preflight inventory was partial\n' >&2
    exit 70
  fi
  verify_preconditions_command "$plan" "$work/pre.jsonl" >/dev/null
  operation_count=$(jq '.operations | length' "$plan")
  index=0
  apply_status=completed
  failed_index=null
  while [ "$index" -lt "$operation_count" ]; do
    jq ".operations[$index]" "$plan" >"$work/operation.json"
    if ! execute_plan_operation "$work/operation.json" "$config" "$target"; then
      printf 'roundhouse: apply operation %s failed\n' "$index" >&2
      apply_status=partial
      failed_index=$index
      break
    fi
    index=$((index + 1))
  done

  post_status=completed
  if ! "$script_dir/roundhouse" collect "$@" --output "$work/post.jsonl"; then
    printf 'roundhouse: apply completed but post-change inventory was partial\n' >&2
    post_status=partial
    apply_status=partial
  fi
  validate_file "$work/post.jsonl"
  if [ "$apply_status" = completed ] && ! jq -e -n --slurpfile plan "$plan" --slurpfile before "$work/pre.jsonl" \
    --slurpfile records "$work/post.jsonl" '
    def same_agent($record; $operation):
      if $operation.kind == "plugin" and
        ($operation.id | test("^(claude|codex):[^:]+:[^:]+:[^:]+$")) then
        ($operation.id | split(":")) as $parts |
        $record.kind == "plugin" and
        $record.data.agent == $parts[0] and
        $record.data.marketplace == $parts[1] and
        $record.data.name == $parts[2]
      else
        $record.kind == $operation.kind and $record.id == $operation.id
      end;
    all($plan[0].operations[];
      if .type == "package-upgrade" then
        . as $operation |
        any($records[]; .kind == $operation.kind and .id == $operation.id and
          .status == "present" and
          .data.installed_version == $operation.candidate_version)
      elif (.type == "auth-reauth" or .type == "auth-install") then
        . as $operation |
        any($records[]; .kind == $operation.kind and .id == $operation.id and
          .status == "present" and .data.health == "healthy")
      elif .type == "chezmoi-pull" then
        any($records[]; .kind == "file" and .id == "chezmoi:source" and
          .status == "present" and .data.dirty_count == 0)
      elif .type == "chezmoi-apply" then
        if has("targets") then true else
          any($records[]; .kind == "chezmoi_state" and .id == "live" and
            .status == "present" and .data.drift_count == 0)
        end
      elif .type == "agent-update" and .id == "roundhouse:launcher" then
        . as $operation |
        any($records[];
          .kind == "agent_artifact" and .id == "roundhouse:launcher" and
          .status == "present" and .data.path == $operation.argv[2] and
          .data.executable == true and
          .data.digest.algorithm == "sha256" and
          (.data.digest.value | type == "string" and length > 0))
      elif .type == "agent-update" then
        . as $operation |
        if $operation.kind == "agent_runtime" then
          any($records[]; same_agent(.; $operation) and .status == "present")
        else
          any($records[]; . as $after |
            same_agent(.; $operation) and
            .status == "present" and
            any($before[]; same_agent(.; $operation) and
              (.data | del(.installed_at,.updated_at,.inferred_installed_at,
                .inferred_installed_at_evidence,.inferred_installed_at_confidence)) !=
              ($after.data | del(.installed_at,.updated_at,.inferred_installed_at,
                .inferred_installed_at_evidence,.inferred_installed_at_confidence))))
        end
      elif .type == "project-update" then
        . as $operation |
        any($records[]; . as $after |
          .kind == $operation.kind and .id == $operation.id and
          .status == "present" and .data.origin_matches == true and
          .data.repository_readiness == "ready" and .data.dirty_count == 0 and
          any($before[]; .kind == $operation.kind and .id == $operation.id and
            .data.head != $after.data.head))
      else true end)
  ' >/dev/null; then
    printf 'roundhouse: post-change state did not satisfy the sealed plan\n' >&2
    apply_status=partial
  fi
  if [ "$apply_status" = completed ] && ! check_chezmoi_target_postconditions "$plan"; then
    printf 'roundhouse: targeted chezmoi postcondition failed\n' >&2
    apply_status=partial
  fi
  snapshot_id=$(jq -r 'select(.kind == "snapshot") | .snapshot_id' "$work/post.jsonl")
  observed_at=$(jq -r 'select(.kind == "snapshot") | .observed_at' "$work/post.jsonl")
  domain=$(jq -r '.domain' "$plan")
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" \
    --arg plan_id "$plan_id" --arg domain "$domain" --argjson operation_count "$operation_count" \
    --argjson completed_operation_count "$index" --argjson failed_operation_index "$failed_index" \
    --arg operation_status "$apply_status" --arg post_inventory_status "$post_status" \
    --arg transport "$transport" --slurpfile plan "$plan" \
    '{schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"operation",id:("apply:"+$plan_id),observed_at:$observed_at,
      status:(if $operation_status == "completed" then "present" else "partial" end),confidence:"high",
      data:{run_id:$snapshot_id,host_id:$host_id,scope:[$domain],phase:"verify",
        operation_status:$operation_status,plan_id:$plan_id,domain:$domain,
        operation_count:$operation_count,completed_operation_count:$completed_operation_count,
        failed_operation_index:$failed_operation_index,post_inventory_status:$post_inventory_status,
        transport:$transport,
        executor:$plan[0].required_executor},
      evidence:[{source:"sealed-plan",method:"verified-execution+post-inventory"}],
      errors:(if $operation_status == "completed" then [] else
        [{code:"apply_partial",severity:"error",retryable:false,
          message:"One or more operations or postconditions failed"}] end)}' \
    >"$work/apply.jsonl"
  cat "$work/post.jsonl" "$work/apply.jsonl" |
    jq -sc 'sort_by(.host_id,.kind,.id)[]' >"$work/result.jsonl"
  validate_file "$work/result.jsonl"
  safe_output "$work/result.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$work"
  [ "$apply_status" = completed ] || return 70
}

validate_legacy_ssh_plan_file() {
  plan=$1
  jq -e '
    def exact($expected): (keys | sort) == ($expected | sort);
    def forbidden_key:
      ascii_downcase | gsub("-"; "_") |
      IN("action_id","broker","broker_protocol","certificate_source_addresses","context","enrollment",
        "observed_execution_principal","payload","policy","policy_token","privilege","privilege_request",
        "request","request_sid","required_context","semantic_action","target_uid");
    type == "object" and
    exact(["configuration_digest","created_at","domain","operations","plan_digest","plan_id",
      "planning_observed_at","planning_snapshot_id","precondition_digest","required_executor",
      "required_section","schema","schema_version","target","worker_configuration_digest"]) and
    .schema == "roundhouse.plan" and .schema_version == 2 and
    ([paths as $path | ($path[-1] | tostring) | forbidden_key] | any | not) and
    (.operations | type == "array" and length > 0 and
      all(.[];
        .type != "semantic-action" and
        (if .type == "package-upgrade" then
           exact(["argv","candidate_version","id","kind","type"])
         else exact(["argv","id","kind","type"]) end) and
        (.argv | type == "array" and length > 0 and length <= 64 and
          all(.[]; type == "string" and length > 0)) and
        ([.argv[] | (split("/") | last) | IN("sudo","su","doas","apt-get")] | any | not)))
  ' "$plan" >/dev/null || {
    printf 'roundhouse: legacy SSH accepts only ordinary schema 2 plans; protected schema 3/4 requests require the fixed dispatcher\n' >&2
    return 64
  }
}

apply_ssh_plan_command() (
  plan=$1
  confirmation=$2
  output=$3
  require_jq
  check_private_owned_file "$plan" "apply plan"
  # Classification is local and precedes configuration lookup or any SSH/SCP
  # activity. Protected plans can never reach the arbitrary workspace lane.
  validate_legacy_ssh_plan_file "$plan"
  check_mutation_config
  [ "$(jq -r '.plan_id // empty' "$plan")" = "$confirmation" ] || {
    printf 'roundhouse: apply confirmation must equal the sealed plan ID\n' >&2
    exit 64
  }
  target=$(jq -r '.target' "$plan")
  domain=$(jq -r '.domain' "$plan")
  config=$(config_path)
  transport=$(jq -r --arg target "$target" '.machines[$target].transport // empty' "$config")
  alias=$(jq -r --arg target "$target" '.machines[$target].ssh_alias // empty' "$config")
  [ "$transport" = ssh ] && [ -n "$alias" ] || {
    printf 'roundhouse: apply-ssh-plan requires a configured SSH target\n' >&2
    exit 64
  }
  if jq -e 'any(.operations[]; .type == "auth-reauth")' "$plan" >/dev/null; then
    printf 'roundhouse: interactive reauthentication requires a visible target terminal\n' >&2
    exit 69
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-ssh-apply.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  worker_config_command "$target" "$domain" "$tmp/config.json"
  [ "$(sha256_file "$tmp/config.json")" = "$(jq -r '.worker_configuration_digest.value' "$plan")" ] || {
    printf 'roundhouse: generated worker configuration does not match the sealed plan\n' >&2
    exit 65
  }
  remote_dir=$(ssh_run "$alias" \
    'umask 077; mktemp -d /tmp/roundhouse-apply.XXXXXX') || {
      printf 'roundhouse: SSH target did not create a private workspace\n' >&2
      exit 70
    }
  printf '%s\n' "$remote_dir" |
    LC_ALL=C grep -Eq '^(/private)?/tmp/roundhouse-apply\.[A-Za-z0-9]{6,64}$' || {
      printf 'roundhouse: unsafe remote temporary path\n' >&2
      exit 70
    }
  if ! scp_run "$tmp/config.json" "$alias:$remote_dir/config.json" ||
    ! scp_run "$plan" "$alias:$remote_dir/plan.json"; then
    ssh_run "$alias" \
      "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || true
    printf 'roundhouse: failed to transfer bounded worker inputs\n' >&2
    exit 70
  fi
  marketplace=$(jq -r '.required_executor.marketplace' "$plan")
  version=$(jq -r '.required_executor.version' "$plan")
  remote_rc=0
  ssh_run "$alias" \
    sh -s -- "$remote_dir" "$marketplace" "$version" "$confirmation" >"$tmp/result.jsonl" <<'REMOTE_WORKER' || remote_rc=$?
set -eu
remote_dir=$1
marketplace=$2
version=$3
confirmation=$4
trap 'rm -rf "$remote_dir"' EXIT HUP INT TERM
codex_cli=$HOME/.codex/plugins/cache/$marketplace/roundhouse/$version/scripts/roundhouse
claude_cli=$HOME/.claude/plugins/cache/$marketplace/roundhouse/$version/scripts/roundhouse
if [ -x "$codex_cli" ]; then
  cli=$codex_cli
elif [ -x "$claude_cli" ]; then
  cli=$claude_cli
else
  printf 'roundhouse: exact executor is not installed on target\n' >&2
  exit 69
fi
export ROUNDHOUSE_CONFIG=$remote_dir/config.json
"$cli" verify-executor "$remote_dir/plan.json" >/dev/null
worker_rc=0
"$cli" apply-native-plan "$remote_dir/plan.json" \
  "$confirmation" "$remote_dir/result.jsonl" >/dev/null || worker_rc=$?
cat "$remote_dir/result.jsonl"
exit "$worker_rc"
REMOTE_WORKER
  if [ ! -s "$tmp/result.jsonl" ]; then
    ssh_run "$alias" \
      "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || true
    printf 'roundhouse: target-native SSH worker returned no result\n' >&2
    exit 70
  fi
  validate_file "$tmp/result.jsonl"
  jq -e -s --arg target "$target" --arg plan_id "$confirmation" --argjson remote_rc "$remote_rc" '
    . as $records |
    ($records | map(.host_id) | unique) == [$target] and
    any($records[]; .kind == "operation" and .id == ("apply:" + $plan_id) and
      (if $remote_rc == 0 then
        .status == "present" and .data.operation_status == "completed"
      else
        .status == "partial" and .data.operation_status == "partial"
      end) and
      .data.plan_id == $plan_id)
  ' "$tmp/result.jsonl" >/dev/null || {
    printf 'roundhouse: SSH worker returned no authoritative completion record\n' >&2
    exit 70
  }
  safe_output "$tmp/result.jsonl" "$output"
  if [ "$remote_rc" -ne 0 ]; then
    printf 'roundhouse: target-native SSH worker reported a partial apply\n' >&2
    exit 70
  fi
)

lookup_privilege_result_command() (
  plan=$1
  index=$2
  output=$3
  require_jq
  check_mutation_config
  check_private_owned_file "$plan" "privilege result plan"
  case $index in ''|*[!0-9]*) usage ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-result-lookup.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  if jq -e '.schema_version == 4' "$plan" >/dev/null 2>&1; then
    validate_mixed_privileged_plan_file "$plan"
    mixed_plan_integrity_check "$plan"
    cp "$plan" "$tmp/executable.json"
  elif jq -e '.schema_version == 3' "$plan" >/dev/null 2>&1; then
    validate_privileged_plan_file "$plan"
    expected_digest=$(jq -cS 'del(.plan_id,.plan_digest)' "$plan" | sha256_stream)
    [ "$expected_digest" = "$(jq -r '.plan_digest.value' "$plan")" ] &&
      [ "$(jq -r '.plan_id' "$plan")" = "plan-$(printf '%s' "$expected_digest" | cut -c 1-16)" ] || {
        printf 'roundhouse: privilege result plan integrity check failed\n' >&2
        exit 65
      }
    [ "$index" -eq 0 ] || {
      printf 'roundhouse: standalone privilege plan has only operation index 0\n' >&2
      exit 64
    }
    standalone_context=$(jq -r '.privilege.context.required' "$plan")
    standalone_target=$(jq -r '.target' "$plan")
    if [ "$standalone_context" = posix-root-v1 ] || [ "$standalone_context" = macos-root-v1 ]; then
      # A query must bind the UID from a newly observed protected target
      # readiness record. Never substitute the controller's local UID.
      fresh_posix_broker_readiness_snapshot "$standalone_target" "$tmp/current-readiness.jsonl"
      normalize_privileged_plan_for_broker_execution "$plan" "$tmp/current-readiness.jsonl" \
        "$tmp/executable.json"
    else
      jq -S '
        .schema_version = 4 |
        .operations[0].privilege = .privilege |
        .operations[0].privilege.request += {
          target_uid:"-",request_sid:"-",certificate_source_addresses:null
        } |
        .operations[0].privilege.context.platform_context_digest = null |
        del(.privilege)
      ' "$plan" >"$tmp/executable.json"
    fi
  else
    printf 'roundhouse: result lookup requires a sealed schema 3 or schema 4 privilege plan\n' >&2
    exit 64
  fi
  operation_count=$(jq '.operations | length' "$tmp/executable.json")
  [ "$index" -lt "$operation_count" ] &&
    jq -e --argjson index "$index" '.operations[$index].type == "semantic-action"' \
      "$tmp/executable.json" >/dev/null || {
        printf 'roundhouse: result lookup index is not a sealed privilege operation\n' >&2
        exit 64
      }
  context=$(jq -r --argjson index "$index" '.operations[$index].privilege.context.required' \
    "$tmp/executable.json")
  case $context in
    posix-root-v1|macos-root-v1)
      protocol=$(jq -r --argjson index "$index" \
        '.operations[$index].privilege.broker.protocol_version' "$tmp/executable.json")
      privilege_protocol_supports_control "$protocol" result_query || {
        printf 'roundhouse: privilege result protocol is unsupported\n' >&2
        exit 69
      }
      make_posix_broker_envelope "$tmp/executable.json" "$index" broker.query-result.v1 \
        "$tmp/query-envelope"
      write_posix_result_lookup_expectations "$tmp/executable.json" "$index" "$tmp/expectations"
      invoke_posix_broker_for_target "$(jq -r '.target' "$tmp/executable.json")" \
        "$tmp/query-envelope" "$tmp/result" || true
      request_id=$(jq -r --argjson index "$index" '.operations[$index].privilege.request.id' \
        "$tmp/executable.json")
      plan_id=$(jq -r '.plan_id' "$tmp/executable.json")
      action_id=$(jq -r --argjson index "$index" '.operations[$index].id' "$tmp/executable.json")
      if terminal=$(posix_broker_terminal_result "$tmp/result" "$request_id" "$plan_id" \
          "$action_id" false "$protocol" "$tmp/expectations"); then
        printf '%s\n' "$terminal" >"$tmp/outcome"
        safe_output "$tmp/outcome" "$output"
      else
        printf '%s\n' 'stale|broker_result_unavailable|-|-|-' >"$tmp/outcome"
        safe_output "$tmp/outcome" "$output"
        exit 70
      fi
      ;;
    windows-system-v1|windows-user-s4u-v1)
      windows_sftp_poll_result "$(jq -r '.target' "$tmp/executable.json")" \
        "$tmp/executable.json" "$index" "$output" true lookup
      ;;
    *)
      printf 'roundhouse: result lookup has no fixed action context\n' >&2
      exit 69
      ;;
  esac
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

preview_privilege_upgrade_command() (
  target=$1
  output=$2
  require_jq
  validate_config_file
  config=$(config_path)
  jq -e --arg target "$target" '.machines[$target] != null' "$config" >/dev/null || usage
  platform=$(jq -r --arg target "$target" '.machines[$target].platform' "$config")
  route=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // "not-configured"' "$config")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-upgrade-preview.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  case $platform:$route in
    wsl:*) state=unsupported; reason=unsupported_security_boundary; entrypoints='[]' ;;
    linux:posix-ssh|macos:posix-ssh)
      state=needs_human_upgrade; reason=local_passworded_sudo_required
      entrypoints='[{"path":"scripts/enroll-privilege-posix","mode":"preview_then_install"},{"path":"scripts/enroll-ssh-posix","mode":"preview_then_repair"}]'
      ;;
    windows:windows-sftp)
      state=needs_human_upgrade; reason=local_uac_required
      entrypoints='[{"path":"scripts/enroll-privilege-windows.ps1","mode":"Preview_then_Install"},{"path":"scripts/enroll-windows-sftp.ps1","mode":"Preview_then_Repair"}]'
      ;;
    *) state=needs_configuration; reason=fixed_automation_route_not_configured; entrypoints='[]' ;;
  esac
  jq -S -n --arg target "$target" --arg platform "$platform" --arg route "$route" \
    --arg state "$state" --arg reason "$reason" --argjson entrypoints "$entrypoints" '{
      schema:"roundhouse.privilege-upgrade-preview",schema_version:1,target:$target,
      platform:$platform,route:$route,state:$state,reason:$reason,activation_performed:false,
      allow_submit:false,allow_result_query:true,
      credential_handling:"agent_stops_before_password_or_uac_and_never_requests_or_relays_a_credential",
      fixed_entrypoints:$entrypoints,
      next_action:(if $state == "needs_human_upgrade" then
        "drain_new_submissions_verify_terminal_results_then_run_the_local_owner_preview"
        elif $state == "unsupported" then "use_a_native_linux_or_windows_target"
        else "configure_the_fixed_automation_route" end)
    }' >"$tmp/preview"
  safe_output "$tmp/preview" "$output"
  [ "$state" != unsupported ] || exit 69
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

preview_privilege_revocation_command() (
  target=$1
  output=$2
  require_jq
  validate_config_file
  config=$(config_path)
  jq -e --arg target "$target" '.machines[$target] != null' "$config" >/dev/null || usage
  platform=$(jq -r --arg target "$target" '.machines[$target].platform' "$config")
  route=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // "not-configured"' "$config")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-revocation-preview.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  case $platform:$route in
    wsl:*) state=unsupported; reason=unsupported_security_boundary; entrypoints='[]' ;;
    linux:posix-ssh|macos:posix-ssh)
      state=needs_human_revocation; reason=local_passworded_sudo_required
      entrypoints='[{"path":"scripts/enroll-ssh-posix","mode":"preview-revoke_then_revoke"},{"path":"scripts/enroll-privilege-posix","mode":"revoke_after_transport_drain"}]'
      ;;
    windows:windows-sftp)
      state=needs_human_revocation; reason=local_uac_required
      entrypoints='[{"path":"scripts/enroll-windows-sftp.ps1","mode":"PreviewRevoke_then_Revoke"},{"path":"scripts/enroll-privilege-windows.ps1","mode":"Revoke_after_transport_drain"}]'
      ;;
    *) state=needs_configuration; reason=fixed_automation_route_not_configured; entrypoints='[]' ;;
  esac
  jq -S -n --arg target "$target" --arg platform "$platform" --arg route "$route" \
    --arg state "$state" --arg reason "$reason" --argjson entrypoints "$entrypoints" '{
      schema:"roundhouse.privilege-revocation-preview",schema_version:1,target:$target,
      platform:$platform,route:$route,state:$state,reason:$reason,activation_performed:false,
      allow_submit:false,allow_result_query:true,
      normal_sequence:["drain","reject_new_submissions","recover_terminal_result",
        "revoke_adapter_grant","remove_transport_authorization"],
      emergency_effect:"reachability_may_end_with_explicit_partial_or_stale_evidence",
      credential_handling:"agent_stops_before_password_or_uac_and_never_requests_or_relays_a_credential",
      fixed_entrypoints:$entrypoints,
      next_action:(if $state == "needs_human_revocation" then
        "inspect_the_local_owner_revocation_preview_and_choose_normal_or_emergency_revocation"
        elif $state == "unsupported" then "no_privileged_adapter_is_installed_in_wsl"
        else "configure_or_identify_the_fixed_adapter_before_revocation" end)
    }' >"$tmp/preview"
  safe_output "$tmp/preview" "$output"
  [ "$state" != unsupported ] || exit 69
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)
