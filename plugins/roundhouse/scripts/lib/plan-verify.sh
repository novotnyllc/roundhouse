# roundhouse — sealed plan validation and precondition verification.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

validate_privileged_plan_file() (
  plan=$1
  contracts=$(privileged_action_contract_json)
  jq -e --argjson contracts "$contracts" '
    def exact($expected): (keys | sort) == ($expected | sort);
    . as $plan |
    type == "object" and exact(["configuration_digest","created_at","domain","operations","plan_digest",
      "plan_id","planning_observed_at","planning_snapshot_id","precondition_digest","privilege",
      "required_executor","required_section","schema","schema_version","target","worker_configuration_digest"]) and
    .schema == "roundhouse.plan" and .schema_version == 3 and
    (.plan_id | test("^plan-[0-9a-f]{16}$")) and (.domain | IN("updates","agents")) and
    (.target | test("^[A-Za-z0-9._-]+$")) and (.required_section | IN("packages","agents")) and
    (.created_at | fromdateiso8601 > 0) and (.planning_observed_at | fromdateiso8601 > 0) and
    (.planning_snapshot_id | type == "string" and length > 0) and
    (.operations | type == "array" and length == 1) and
    (.operations[0] | exact(["id","kind","type"]) and .type == "semantic-action" and
      .kind == "privileged_action") and
    (.configuration_digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
      (.value | test("^[0-9a-f]{64}$"))) and
    (.worker_configuration_digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
      (.value | test("^[0-9a-f]{64}$"))) and
    (.precondition_digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
      (.value | test("^[0-9a-f]{64}$"))) and
    (.plan_digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
      (.value | test("^[0-9a-f]{64}$"))) and
    (.required_executor.plugin == "roundhouse") and
    (.required_executor.marketplace | test("^[A-Za-z0-9._-]+$")) and
    (.required_executor.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.required_executor.integrity_manifest_sha256 | test("^[0-9a-f]{64}$")) and
    (.required_executor.files | type == "array" and length > 0) and
    ((.required_executor.files | map(.path) | unique | length) == (.required_executor.files | length)) and
    ([.required_executor.files[] |
      (.path | test("^[A-Za-z0-9._/-]+$") and (startswith("/") | not) and
        (test("(^|/)\\.\\.(/|$)") | not)) and (.sha256 | test("^[0-9a-f]{64}$"))
    ] | all) and
    (.privilege | exact(["action","broker","context","contract_version","enrollment","policy","precondition","request"]) and
      .contract_version == 1) and
    (.privilege.broker | exact(["adapter","digest","protocol_version","version"]) and
      (.adapter | IN("posix-sudo-v1","windows-scheduled-task-v1")) and
      (.protocol_version | IN(0,1)) and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
      (.digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
        (.value | test("^[0-9a-f]{64}$")))) and
    (.privilege.policy | exact(["action_manifest_version","catalog_version","constraint_digest","constraint_generation",
      "constraint_kind","constraints_digest","digest","proposal_digest","version"]) and .catalog_version == 1 and .version == 1 and
      .action_manifest_version == 1 and
      (.digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
        (.value | test("^[0-9a-f]{64}$"))) and
      (.proposal_digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
        (.value | test("^[0-9a-f]{64}$"))) and
      (.constraints_digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
        (.value | test("^[0-9a-f]{64}$"))) and
      (.constraint_generation | type == "number" and floor == . and . >= 1 and
        . == $plan.privilege.enrollment.epoch) and
      .constraint_kind == $contracts[$plan.privilege.action.id].constraint_kind and
      (if .constraint_kind == "none" then .constraint_digest == "-"
       else (.constraint_digest | test("^[0-9a-f]{64}$")) end)) and
    (.privilege.action | exact(["id","policy_token"]) and .id == $plan.operations[0].id and
      $contracts[.id] != null and
      (if $contracts[.id].token == "none" then .policy_token == null
       else (.policy_token | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$")) end)) and
    (.privilege.context | exact(["canary_digest","manager_source_identity","observed_execution_principal",
      "platform_boundary","required","session_requirement"]) and
      .required == $contracts[$plan.privilege.action.id].context and
      (.observed_execution_principal | IN("root","LocalSystem","enrolled-s4u-user")) and
      .session_requirement == "no-console-session" and (.platform_boundary | IN("linux","macos","windows")) and
      (.manager_source_identity | type == "string" and length > 0) and
      (.canary_digest | exact(["algorithm","value"]) and .algorithm == "sha256" and
        (.value | test("^[0-9a-f]{64}$")))) and
    (.privilege.request | . as $request | exact(["certificate_serial","created_at","expires_at","id","node_key_fingerprint",
      "originating_node_id","principal","transport"]) and
      (.id | test("^request-[0-9a-f]{32}$")) and .created_at == $plan.created_at and
      (.created_at | fromdateiso8601 > 0) and
      (.expires_at | fromdateiso8601 > ($request.created_at | fromdateiso8601)) and
      (.transport | IN("posix-ssh","windows-sftp")) and
      (.principal | test("^[A-Za-z0-9._-]{1,128}$")) and
      (.originating_node_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
      (.node_key_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
      (.certificate_serial | test("^(0|[1-9][0-9]{0,19})$"))) and
    (.privilege.enrollment | . as $enrollment | exact(["ca_generation","certificate_valid_after","certificate_valid_before","epoch",
      "fleet_ca_fingerprint","fleet_domain","pinned_host_key_fingerprint"]) and
      (.epoch | type == "number" and floor == . and . >= 1) and
      (.fleet_domain | test("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$")) and
      (.fleet_ca_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
      (.ca_generation | type == "number" and floor == . and . >= 1) and
      (.certificate_valid_after | fromdateiso8601 > 0 and
        fromdateiso8601 <= ($plan.created_at | fromdateiso8601)) and
      (.certificate_valid_before | fromdateiso8601 > ($enrollment.certificate_valid_after | fromdateiso8601)) and
      (.pinned_host_key_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$"))) and
    (.privilege.precondition | exact(["digest"]) and
      .digest == $plan.precondition_digest) and
    .domain == $contracts[.privilege.action.id].domain and
    (if .privilege.context.required == "posix-root-v1" then
       .required_section == "packages" and
       .privilege.broker.adapter == "posix-sudo-v1" and .privilege.context.required == "posix-root-v1" and
       .privilege.context.observed_execution_principal == "root" and .privilege.context.platform_boundary == "linux" and
       .privilege.request.transport == "posix-ssh"
     elif .privilege.context.required == "macos-root-v1" then
       .required_section == "packages" and
       .privilege.broker.adapter == "posix-sudo-v1" and
       .privilege.context.observed_execution_principal == "root" and
       .privilege.context.platform_boundary == "macos" and .privilege.request.transport == "posix-ssh"
     elif .privilege.context.required == "windows-system-v1" then
       .required_section == "packages" and
       .privilege.broker.adapter == "windows-scheduled-task-v1" and
       .privilege.context.observed_execution_principal == "LocalSystem" and
       .privilege.context.platform_boundary == "windows" and .privilege.request.transport == "windows-sftp"
     else .required_section == "agents" and
       .privilege.broker.adapter == "windows-scheduled-task-v1" and
       .privilege.context.observed_execution_principal == "enrolled-s4u-user" and
       .privilege.context.platform_boundary == "windows" and .privilege.request.transport == "windows-sftp" end) and
    ([.. | strings | length <= 8192 and (test("[[:cntrl:]]") | not)] | all)
  ' "$plan" >/dev/null || {
    printf 'roundhouse: invalid privileged apply plan\n' >&2
    return 64
  }
)

validate_mixed_privileged_plan_file() (
  plan=$1
  contracts=$(privileged_action_contract_json)
  jq -e --argjson contracts "$contracts" '
    def exact($expected): (keys | sort) == ($expected | sort);
    def digest: type == "object" and exact(["algorithm","value"]) and .algorithm == "sha256" and
      (.value | type == "string" and test("^[0-9a-f]{64}$"));
    def ordinary:
      (if .type == "package-upgrade" then
         exact(["candidate_version","id","kind","type","argv"])
       else exact(["id","kind","type","argv"]) end) and
      (.kind | IN("package","agent_runtime","plugin","skill")) and
      (.type | IN("package-metadata-refresh","package-upgrade","package-cleanup","agent-update")) and
      (.id | type == "string" and length > 0) and
      (.argv | type == "array" and length > 0 and length <= 64 and
        ([.[] | type == "string" and length > 0] | all) and
        ([.[] | (split("/") | last) | IN("sudo","apt-get")] | any | not)) and
      (if .type == "package-upgrade" then .candidate_version | type == "string" and length > 0 else true end);
    def privileged:
      . as $operation |
      exact(["id","kind","privilege","type"]) and .kind == "privileged_action" and
      .type == "semantic-action" and $contracts[.id] != null and
      (.privilege | type == "object" and
        .action.id == $operation.id and .context.required == $contracts[$operation.id].context and
        .policy.constraint_kind == $contracts[$operation.id].constraint_kind and
        (if $contracts[$operation.id].token == "none" then .action.policy_token == null
         else (.action.policy_token | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$")) end) and
        (.broker.protocol_version | IN(0,1)) and
        (if (.context.required | startswith("windows-")) then
           .broker.adapter == "windows-scheduled-task-v1" and .context.platform_boundary == "windows" and
           .request.transport == "windows-sftp" and .request.target_uid == "-" and
           (.request.request_sid | type == "string" and test("^S-[0-9]+(?:-[0-9]+){1,14}$")) and
           (.context.platform_context_digest | digest)
         elif .context.required == "posix-root-v1" then
           .broker.adapter == "posix-sudo-v1" and .context.platform_boundary == "linux" and
           .request.transport == "posix-ssh" and .request.request_sid == "-" and
           (.request.target_uid | type == "string" and test("^(0|[1-9][0-9]{0,9})$")) and
           .context.platform_context_digest == null
         else .context.required == "macos-root-v1" and
           .broker.adapter == "posix-sudo-v1" and .context.platform_boundary == "macos" and
           .request.transport == "posix-ssh" and .request.request_sid == "-" and
           (.request.target_uid | type == "string" and test("^(0|[1-9][0-9]{0,9})$")) and
           (.context.platform_context_digest | digest) end)) and
      (.privilege.request | type == "object" and
        exact(["certificate_serial","certificate_source_addresses","created_at","expires_at","id",
          "node_key_fingerprint","originating_node_id","principal","request_sid","target_uid","transport"]) and
        (.certificate_source_addresses | type == "array" and length <= 16 and unique == . and
          all(.[]; type == "string" and test("^[0-9A-Fa-f:.]+/[0-9]{1,3}$"))));
    . as $plan |
    type == "object" and exact(["configuration_digest","created_at","domain","operations","plan_digest",
      "plan_id","planning_observed_at","planning_snapshot_id","precondition_digest",
      "required_executor","required_section","schema","schema_version","target","worker_configuration_digest"]) and
    .schema == "roundhouse.plan" and .schema_version == 4 and (.domain | IN("updates","agents")) and
    .required_section == (if .domain == "updates" then "packages" else "agents" end) and
    (.target | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.created_at | type == "string" and fromdateiso8601 > 0) and
    (.planning_observed_at | type == "string" and fromdateiso8601 > 0) and
    (.planning_snapshot_id | type == "string" and length > 0) and
    (.operations | type == "array" and length > 1 and length <= 128 and
      (map(.id) as $ids | ($ids | unique | length) == ($ids | length)) and any(.[]; .type == "semantic-action") and
      all(.[]; if .type == "semantic-action" then
          privileged and $contracts[.id].domain == $plan.domain
        else ordinary and
          (if $plan.domain == "updates" then .kind == "package" and (.type | startswith("package-"))
           else .type == "agent-update" and (.kind | IN("agent_runtime","plugin","skill")) end)
        end)) and
    (.configuration_digest | digest) and (.worker_configuration_digest | digest) and
    (.precondition_digest | digest) and (.plan_digest | digest) and
    (.required_executor | type == "object") and
    ([.. | strings | length <= 8192 and (test("[[:cntrl:]]") | not)] | all)
  ' "$plan" >/dev/null || {
    printf 'roundhouse: invalid mixed privileged apply plan\n' >&2
    exit 64
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-v4-plan.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  jq -c '
    . as $plan |
    .operations[] | select(.type == "semantic-action") as $operation |
    {
      schema:$plan.schema,schema_version:3,created_at:$plan.created_at,domain:$plan.domain,target:$plan.target,
      operations:[{id:$operation.id,kind:$operation.kind,type:$operation.type}],
      required_section:$plan.required_section,planning_snapshot_id:$plan.planning_snapshot_id,
      planning_observed_at:$plan.planning_observed_at,
      configuration_digest:$plan.configuration_digest,
      worker_configuration_digest:$plan.worker_configuration_digest,
      precondition_digest:$operation.privilege.precondition.digest,
      required_executor:$plan.required_executor,plan_id:$plan.plan_id,plan_digest:$plan.plan_digest,
      privilege:($operation.privilege |
        .request |= del(.target_uid,.request_sid,.certificate_source_addresses) |
        .context |= del(.platform_context_digest))
    }
  ' "$plan" >"$tmp/privileged-candidates.jsonl"
  while IFS= read -r candidate; do
    printf '%s\n' "$candidate" >"$tmp/candidate.json"
    validate_privileged_plan_file "$tmp/candidate.json" || {
      printf 'roundhouse: invalid sealed privilege metadata in mixed plan\n' >&2
      exit 64
    }
  done <"$tmp/privileged-candidates.jsonl"
)

mixed_plan_integrity_check() {
  plan=$1
  expected_plan_digest=$(jq -cS 'del(.plan_id,.plan_digest)' "$plan" | sha256_stream)
  actual_plan_digest=$(jq -r '.plan_digest.value' "$plan")
  [ "$expected_plan_digest" = "$actual_plan_digest" ] || {
    printf 'roundhouse: mixed plan integrity check failed\n' >&2
    return 65
  }
  expected_plan_id="plan-$(printf '%s' "$actual_plan_digest" | cut -c 1-16)"
  [ "$(jq -r '.plan_id' "$plan")" = "$expected_plan_id" ] || {
    printf 'roundhouse: mixed plan ID does not match its digest\n' >&2
    return 65
  }
}

privileged_plan_integrity_check() {
  plan=$1
  expected_plan_digest=$(jq -cS 'del(.plan_id,.plan_digest)' "$plan" | sha256_stream)
  actual_plan_digest=$(jq -r '.plan_digest.value' "$plan")
  [ "$expected_plan_digest" = "$actual_plan_digest" ] || {
    printf 'roundhouse: privileged plan integrity check failed\n' >&2
    return 65
  }
  expected_plan_id="plan-$(printf '%s' "$actual_plan_digest" | cut -c 1-16)"
  [ "$(jq -r '.plan_id' "$plan")" = "$expected_plan_id" ] || {
    printf 'roundhouse: privileged plan ID does not match its digest\n' >&2
    return 65
  }
}

verify_mixed_configuration_binding() (
  plan=$1
  config=$(config_path)
  target=$(jq -r '.target' "$plan")
  if jq -e '.worker != null' "$config" >/dev/null; then
    jq -e --arg target "$target" --arg controller_digest "$(jq -r '.configuration_digest.value' "$plan")" '
      .worker.target == $target and .worker.controller_configuration_digest == $controller_digest
    ' "$config" >/dev/null &&
      [ "$(jq -r '.worker_configuration_digest.value' "$plan")" = "$(sha256_file "$config")" ] || {
        printf 'roundhouse: bounded worker configuration does not match the mixed plan\n' >&2
        return 65
      }
  else
    [ "$(jq -r '.configuration_digest.value' "$plan")" = "$(sha256_file "$config")" ] || {
      printf 'roundhouse: configuration changed after mixed planning\n' >&2
      return 65
    }
  fi
)

mixed_privilege_actions_compatible() {
  plan=$1
  contracts=$(privileged_action_contract_json)
  jq -e --argjson contracts "$contracts" 'all(.operations[] | select(.type == "semantic-action");
    . as $operation | ($contracts[$operation.id].protocols |
      index($operation.privilege.broker.protocol_version) != null))' "$plan" >/dev/null
}

verify_mixed_privilege_readiness() {
  plan=$1
  snapshot=$2
  readiness_authority=${3:-ordinary-inventory}
  case $readiness_authority in
    ordinary-inventory) remote_execution=false ;;
    windows-sftp-execution) remote_execution=true ;;
    *) return 64 ;;
  esac
  contracts=$(privileged_action_contract_json)
  jq -e -s --slurpfile plan "$plan" --argjson contracts "$contracts" \
    --argjson remote_execution "$remote_execution" '
    . as $records | $plan[0] as $plan |
    all($plan.operations[] | select(.type == "semantic-action"); . as $operation |
      $operation.privilege as $p |
      any($records[]; .kind == "privilege_broker" and .id == "readiness" and .status == "present" and
        .data.lifecycle_status == "ready" and .data.transport_ready == true and
        .data.node_identity_ready == true and .data.broker_ready == true and
        .data.action_context_ready == true and .data.adapter_mechanism_ready == true and
        .data.platform_adapter == $p.broker.adapter and .data.platform_boundary == $p.context.platform_boundary and
        .data.session_requirement == $p.context.session_requirement and .data.transport == $p.request.transport and
        .data.broker_protocol.observed == $p.broker.protocol_version and
        (.data.broker_protocol.supported | index($p.broker.protocol_version) != null) and
        .data.broker_version == $p.broker.version and .data.broker_digest == $p.broker.digest and
        .data.observed_policy_digest == $p.policy.digest and
        .data.observed_constraints_digest == $p.policy.constraints_digest and
        .data.constraint_generation == $p.policy.constraint_generation and
        (if $remote_execution then
           .data.mixed_inventory_authority == false and .data.policy_proposal_digest == null and
           .data.context_canary_digest == null and .data.system_task_ready == true and
           .data.native_canary_ready == true and
           (if $p.context.required == "windows-user-s4u-v1" then .data.profile_task_ready == true else true end) and
           .data.readiness_response.state == "ready" and
           (.data.readiness_response.observed_at | fromdateiso8601) <= now + 300 and
           (.data.readiness_response.expires_at | fromdateiso8601) > now
         else .data.policy_proposal_digest == $p.policy.proposal_digest and
           .data.context_canary_digest == $p.context.canary_digest end) and
        .data.request_principal == $p.request.principal and
        .data.protected_identity.host_id == $plan.target and
        .data.protected_identity.request_principal == $p.request.principal and
        (if ($p.context.required | IN("posix-root-v1","macos-root-v1")) then
           (.data.protected_identity.uid | tostring) == $p.request.target_uid and $p.request.request_sid == "-" and
           (if $p.context.required == "macos-root-v1" then
              .data.observed_platform_context_digest == $p.context.platform_context_digest
            else $p.context.platform_context_digest == null end)
         else .data.protected_identity.sid == $p.request.request_sid and $p.request.target_uid == "-" and
           .data.observed_winget_context_digest == $p.context.platform_context_digest end) and
        .data.originating_node_identity.node_id == $p.request.originating_node_id and
        .data.originating_node_identity.node_key_fingerprint == $p.request.node_key_fingerprint and
        .data.originating_node_identity.certificate_serial == $p.request.certificate_serial and
        .data.originating_node_identity.certificate_source_addresses == $p.request.certificate_source_addresses and
        .data.enrollment_epoch == $p.enrollment.epoch and
        .data.originating_node_identity.fleet_domain == $p.enrollment.fleet_domain and
        .data.originating_node_identity.fleet_ca_fingerprint == $p.enrollment.fleet_ca_fingerprint and
        .data.originating_node_identity.ca_generation == $p.enrollment.ca_generation and
        .data.pinned_host_key_fingerprint == $p.enrollment.pinned_host_key_fingerprint and
        (.data.node_identity.certificate_valid_after | fromdateiso8601 <= now) and
        (.data.node_identity.certificate_valid_before | fromdateiso8601 > now) and
        (.data.originating_node_identity.certificate_valid_after | fromdateiso8601 <= now) and
        (.data.originating_node_identity.certificate_valid_before | fromdateiso8601 > now) and
        any(.data.observed_action_contexts[]; .action_id == $p.action.id and
          .context_id == $contracts[$operation.id].context and
          .constraint_kind == $contracts[$operation.id].constraint_kind and
          .constraint_generation == $p.policy.constraint_generation and
          .constraint_kind == $p.policy.constraint_kind and
          (if $remote_execution then true else .constraint_digest == $p.policy.constraint_digest end) and
          (if $p.context.required == "windows-user-s4u-v1" then
             any(.profile_constraints[]; .policy_token == $p.action.policy_token and
               .target_sid != $p.request.request_sid and
               .entry_map_digest == $p.context.manager_source_identity and
               ([.profile_root_id,.entry_map_digest,.marketplace_set_digest] |
                 all(type == "string" and test("^[0-9a-f]{64}$"))) and
               (.delete_mode | IN("managed-only","managed-and-prune")) and
               (.max_entries | type == "number" and floor == . and . >= 1 and . <= 100000) and
               (.max_bytes | type == "number" and floor == . and . >= 1 and . <= 1073741824))
           else (if $remote_execution then true
             else .manager_source_identity == $p.context.manager_source_identity end) end) and
          (if $contracts[$operation.id].token == "none" then
             (if $remote_execution then true else .constraint_digest == "-" end) and
             $p.action.policy_token == null and (.policy_tokens | length) == 0
           else (.policy_tokens | index($p.action.policy_token) != null) end)) and
        any(.data.observed_preconditions[]; .action_id == $p.action.id and
          .policy_token == (if $p.action.policy_token == null then "-" else $p.action.policy_token end) and
          .digest == $p.precondition.digest)))
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: current broker readiness does not match a sealed mixed privilege contract\n' >&2
    return 65
  }
  jq -e 'all(.operations[] | select(.type == "semantic-action");
    (.privilege.enrollment.certificate_valid_after | fromdateiso8601) <= now and
    (.privilege.request.expires_at | fromdateiso8601) > now and
    (.privilege.request.expires_at | fromdateiso8601) <=
      (.privilege.enrollment.certificate_valid_before | fromdateiso8601))' "$plan" >/dev/null || {
    printf 'roundhouse: mixed privileged request or node certificate expired\n' >&2
    return 65
  }
}

verify_mixed_privileged_preconditions_command() {
  plan=$1
  snapshot=$2
  validate_mixed_privileged_plan_file "$plan"
  mixed_plan_integrity_check "$plan"
  config=$(config_path)
  verify_executor_requirement "$plan" >/dev/null
  target=$(jq -r '.target' "$plan")
  verify_mixed_configuration_binding "$plan"
  validate_file "$snapshot"
  jq -e -s --arg target "$target" 'map(.host_id) | unique == [$target]' "$snapshot" >/dev/null || {
    printf 'roundhouse: current snapshot does not exclusively describe mixed target %s\n' "$target" >&2
    return 64
  }
  expected_hostname=$(jq -r --arg target "$target" '.machines[$target].expected_hostname // empty' "$config")
  expected_user=$(jq -r --arg target "$target" '.machines[$target].expected_user // empty' "$config")
  [ -n "$expected_hostname" ] && [ -n "$expected_user" ] &&
    jq -e -s --arg hostname "$expected_hostname" --arg user "$expected_user" '
      any(.[]; .kind == "host" and .status == "present" and .data.hostname == $hostname and .data.user == $user)
    ' "$snapshot" >/dev/null || {
      printf 'roundhouse: mixed target identity does not match configured hostname/user\n' >&2
      return 65
    }
  planning_snapshot_id=$(jq -r '.planning_snapshot_id' "$plan")
  jq -e -s --arg planning_snapshot_id "$planning_snapshot_id" '
    any(.[]; .kind == "snapshot" and .snapshot_id != $planning_snapshot_id and
      ((.observed_at | fromdateiso8601) as $observed | (now - $observed) >= 0 and (now - $observed) <= 900))
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: mixed apply requires a distinct recent inventory\n' >&2
    return 65
  }
  jq -e -s '
    any(.[]; .kind == "snapshot" and (.data.sections as $sections |
      ($sections | index("all") != null) or ($sections | index("packages") != null))) and
    any(.[]; .kind == "operation" and .status == "present" and .data.operation_status == "completed")
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: current snapshot lacks completed mixed preflight inventory\n' >&2
    return 65
  }
  jq -e -n --slurpfile plan "$plan" --slurpfile records "$snapshot" '
    [$plan[0].operations[] | select(.type != "semantic-action") | ([.kind,.id] | @json)] as $wanted |
    [$records[] | select(.kind != "snapshot" and .kind != "operation" and
      (.status == "present" or .status == "absent")) | ([.kind,.id] | @json)] as $observed |
    ($wanted - $observed) | length == 0
  ' >/dev/null || {
    printf 'roundhouse: current snapshot does not cover every ordinary mixed operation\n' >&2
    return 65
  }
  [ "$(jq -r '.precondition_digest.value' "$plan")" = "$(mixed_precondition_digest "$plan" "$snapshot")" ] || {
    printf 'roundhouse: ordinary state or broker readiness changed after mixed planning\n' >&2
    return 65
  }
  verify_mixed_privilege_readiness "$plan" "$snapshot"
  if ! mixed_privilege_actions_compatible "$plan"; then
    printf 'roundhouse: needs_broker_upgrade\n' >&2
    return 69
  fi
  jq -cn --arg plan_id "$(jq -r '.plan_id' "$plan")" --arg target "$target" \
    '{verified:true,privileged:true,mixed:true,plan_id:$plan_id,target:$target}'
}

verify_privileged_preconditions_command() {
  plan=$1
  snapshot=$2
  contracts=$(privileged_action_contract_json)
  validate_privileged_plan_file "$plan"
  privileged_plan_integrity_check "$plan"
  expected_plan_id=$(jq -r '.plan_id' "$plan")
  config=$(config_path)
  verify_executor_requirement "$plan" >/dev/null
  target=$(jq -r '.target' "$plan")
  if jq -e '.worker != null' "$config" >/dev/null; then
    jq -e --arg target "$target" --arg controller_digest "$(jq -r '.configuration_digest.value' "$plan")" '
      .worker.target == $target and .worker.controller_configuration_digest == $controller_digest
    ' "$config" >/dev/null &&
      [ "$(jq -r '.worker_configuration_digest.value' "$plan")" = "$(sha256_file "$config")" ] || {
        printf 'roundhouse: bounded worker configuration does not match the privileged plan\n' >&2
        return 65
      }
  else
    [ "$(jq -r '.configuration_digest.value' "$plan")" = "$(sha256_file "$config")" ] || {
      printf 'roundhouse: configuration changed after privileged planning\n' >&2
      return 65
    }
  fi
  validate_file "$snapshot"
  jq -e -s --arg target "$target" 'map(.host_id) | unique == [$target]' "$snapshot" >/dev/null || {
    printf 'roundhouse: current snapshot does not exclusively describe privileged target %s\n' "$target" >&2
    return 64
  }
  planning_snapshot_id=$(jq -r '.planning_snapshot_id' "$plan")
  jq -e -s --arg planning_snapshot_id "$planning_snapshot_id" '
    any(.[]; .kind == "snapshot" and .snapshot_id != $planning_snapshot_id and
      ((.observed_at | fromdateiso8601) as $observed | (now - $observed) >= 0 and (now - $observed) <= 900))
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: privileged apply requires a distinct recent inventory\n' >&2
    return 65
  }
  required_section=$(jq -r '.required_section' "$plan")
  jq -e -s --arg section "$required_section" '
    any(.[]; .kind == "snapshot" and
      ((.data.sections | index("all")) != null or (.data.sections | index($section)) != null)) and
    any(.[]; .kind == "operation" and .status == "present" and .data.operation_status == "completed")
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: current snapshot lacks completed privileged preflight inventory\n' >&2
    return 65
  }
  sealed_action=$(jq -r '.privilege.action.id' "$plan")
  sealed_policy_token=$(jq -r '.privilege.action.policy_token // "-"' "$plan")
  sealed_precondition=$(jq -r '.privilege.precondition.digest.value' "$plan")
  current_precondition=$(privilege_action_precondition_digest "$snapshot" "$sealed_action" \
    "$sealed_policy_token" || true)
  [ "$sealed_precondition" = "$current_precondition" ] || {
    printf 'roundhouse: broker, policy, action context, or node identity changed after planning\n' >&2
    return 65
  }
  sealed_protocol=$(jq -r '.privilege.broker.protocol_version' "$plan")
  privilege_protocol_supports_action "$sealed_protocol" "$sealed_action" || {
    printf 'roundhouse: needs_broker_upgrade\n' >&2
    return 69
  }
  jq -e -s --slurpfile plan "$plan" --argjson contracts "$contracts" '
    $plan[0].privilege as $p |
    any(.[]; .data as $readiness | .kind == "privilege_broker" and .id == "readiness" and .status == "present" and
      .data.lifecycle_status == "ready" and .data.transport_ready == true and
      .data.node_identity_ready == true and .data.broker_ready == true and .data.action_context_ready == true and
      .data.adapter_mechanism_ready == true and
      .data.platform_adapter == $p.broker.adapter and .data.broker_protocol.observed == $p.broker.protocol_version and
      .data.broker_version == $p.broker.version and .data.broker_digest == $p.broker.digest and
      .data.observed_policy_digest == $p.policy.digest and .data.policy_proposal_digest == $p.policy.proposal_digest and
      .data.observed_constraints_digest == $p.policy.constraints_digest and
      .data.constraint_generation == $p.policy.constraint_generation and
      .data.context_canary_digest == $p.context.canary_digest and .data.platform_boundary == $p.context.platform_boundary and
      .data.session_requirement == $p.context.session_requirement and .data.transport == $p.request.transport and
      .data.request_principal == $p.request.principal and
      (.data.node_identity.certificate_valid_after | fromdateiso8601 <= now) and
      (.data.node_identity.certificate_valid_before | fromdateiso8601 > now) and
      .data.originating_node_identity.node_id == $p.request.originating_node_id and
      .data.originating_node_identity.node_key_fingerprint == $p.request.node_key_fingerprint and
      .data.originating_node_identity.certificate_serial == $p.request.certificate_serial and
      .data.enrollment_epoch == $p.enrollment.epoch and
      .data.originating_node_identity.fleet_domain == $p.enrollment.fleet_domain and
      .data.originating_node_identity.fleet_ca_fingerprint == $p.enrollment.fleet_ca_fingerprint and
      .data.originating_node_identity.ca_generation == $p.enrollment.ca_generation and
      (.data.originating_node_identity.certificate_valid_after | fromdateiso8601 <= now) and
      (.data.originating_node_identity.certificate_valid_before | fromdateiso8601 > now) and
      .data.pinned_host_key_fingerprint == $p.enrollment.pinned_host_key_fingerprint and
      any(.data.observed_action_contexts[]; .action_id == $p.action.id and
        .context_id == $contracts[$p.action.id].context and
        .constraint_generation == $p.policy.constraint_generation and
        .constraint_kind == $contracts[$p.action.id].constraint_kind and
        .constraint_kind == $p.policy.constraint_kind and .constraint_digest == $p.policy.constraint_digest and
        (if $p.context.required == "windows-user-s4u-v1" then
           any(.profile_constraints[]; .policy_token == $p.action.policy_token and
             .target_sid != $readiness.protected_identity.sid and
             .entry_map_digest == $p.context.manager_source_identity and
             ([.profile_root_id,.entry_map_digest,.marketplace_set_digest] |
               all(type == "string" and test("^[0-9a-f]{64}$"))) and
             (.delete_mode | IN("managed-only","managed-and-prune")) and
             (.max_entries | type == "number" and floor == . and . >= 1 and . <= 100000) and
             (.max_bytes | type == "number" and floor == . and . >= 1 and . <= 1073741824))
         else .manager_source_identity == $p.context.manager_source_identity end) and
        (if $contracts[$p.action.id].token == "none" then
           .constraint_digest == "-" and $p.action.policy_token == null and (.policy_tokens | length) == 0
         else (.policy_tokens | index($p.action.policy_token) != null) end)))
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: current broker readiness does not match the sealed privilege contract\n' >&2
    return 65
  }
  jq -e '
    (.privilege.enrollment.certificate_valid_after | fromdateiso8601) <= now and
    (.privilege.request.expires_at | fromdateiso8601) > now and
    (.privilege.request.expires_at | fromdateiso8601) <= (.privilege.enrollment.certificate_valid_before | fromdateiso8601)
  ' "$plan" >/dev/null || {
    printf 'roundhouse: privileged request or node certificate expired\n' >&2
    return 65
  }
  jq -cn --arg plan_id "$expected_plan_id" --arg target "$target" \
    '{verified:true,privileged:true,plan_id:$plan_id,target:$target}'
}

verify_preconditions_command() {
  plan=$1
  snapshot=$2
  require_jq
  check_mutation_config
  check_private_owned_file "$plan" "apply plan"
  if jq -e '.schema_version == 4' "$plan" >/dev/null 2>&1; then
    verify_mixed_privileged_preconditions_command "$plan" "$snapshot"
    return
  fi
  if jq -e '.schema_version == 3 or has("privilege")' "$plan" >/dev/null 2>&1; then
    verify_privileged_preconditions_command "$plan" "$snapshot"
    return
  fi
  jq -e '
    .schema == "roundhouse.plan" and
    .schema_version == 2 and
    (.plan_id | type == "string" and test("^plan-[0-9a-f]{16}$")) and
    (.domain | IN("updates","agents","auth","chezmoi","projects")) and
    (.target | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.operations | type == "array" and length > 0) and
    ([.operations[] |
      (.type | IN(
        "package-metadata-refresh","package-upgrade","package-cleanup",
        "agent-update",
        "auth-reauth","auth-install",
        "chezmoi-pull","chezmoi-apply",
        "project-clone","project-update"
      )) and
      (.kind | IN("package","agent_runtime","plugin","skill","capability","skill_root","agent_artifact","auth_artifact","file","chezmoi_state","project")) and
      (.id | type == "string" and length > 0) and
      (.argv | type == "array" and length > 0 and length <= 64) and
      ([.argv[] | type == "string" and length > 0] | all) and
      (if .type == "package-upgrade" then
        (.candidate_version | type == "string" and length > 0)
      else true end) and
      (if .type == "chezmoi-apply" and has("targets") then
        (.targets | type == "array" and length > 0 and length <= 16 and
          (unique | length) == length and
          ([.[] | type == "string" and length > 0 and length <= 512 and
            ((startswith("/") and (contains("\\") | not)) or
             (test("^[A-Za-z]:\\\\") and contains("\\"))) and
            (test("(^|[/\\\\])\\.\\.?($|[/\\\\])") | not)] | all))
       elif has("targets") then false
       else true end)
    ] | all) and
    (if .domain == "updates" then
       [.operations[] | .kind == "package" and (.type | startswith("package-"))] | all
     elif .domain == "agents" then
       [.operations[] | (.kind | IN("agent_runtime","plugin","skill","capability","skill_root","agent_artifact")) and (.type | startswith("agent-"))] | all
     elif .domain == "auth" then
       [.operations[] | .kind == "auth_artifact" and (.type | startswith("auth-"))] | all
     elif .domain == "chezmoi" then
       [.operations[] |
         (.type == "chezmoi-pull" and .kind == "file" and .id == "chezmoi:source") or
         (.type == "chezmoi-apply" and .kind == "chezmoi_state" and .id == "live")
       ] | all
     elif .domain == "projects" then
       [.operations[] | .kind == "project" and (.type | startswith("project-"))] | all
     else false end) and
    (.required_section | IN("packages","agents","auth","chezmoi","projects")) and
    (.planning_snapshot_id | type == "string" and length > 0) and
    (.planning_observed_at | type == "string" and fromdateiso8601 > 0) and
    (.configuration_digest.algorithm == "sha256") and
    (.configuration_digest.value | test("^[0-9a-f]{64}$")) and
    (.worker_configuration_digest.algorithm == "sha256") and
    (.worker_configuration_digest.value | test("^[0-9a-f]{64}$")) and
    (.precondition_digest.algorithm == "sha256") and
    (.precondition_digest.value | test("^[0-9a-f]{64}$")) and
    (.required_executor.plugin == "roundhouse") and
    (.required_executor.marketplace | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.required_executor.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.required_executor.integrity_manifest_sha256 | test("^[0-9a-f]{64}$")) and
    (.required_executor.files | type == "array" and length > 0) and
    ((.required_executor.files | map(.path) | unique | length) == (.required_executor.files | length)) and
    ([.required_executor.files[] |
      (.path | type == "string" and test("^[A-Za-z0-9._/-]+$") and
        (startswith("/") | not) and (test("(^|/)\\.\\.(/|$)") | not)) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ] | all) and
    (.plan_digest.algorithm == "sha256") and
    (.plan_digest.value | test("^[0-9a-f]{64}$")) and
    ([.. | strings | length <= 8192] | all)
  ' "$plan" >/dev/null || {
    printf 'roundhouse: invalid apply plan\n' >&2
    exit 64
  }
  expected_plan_digest=$(jq -cS 'del(.plan_id,.plan_digest)' "$plan" | sha256_stream)
  actual_plan_digest=$(jq -r '.plan_digest.value' "$plan")
  [ "$expected_plan_digest" = "$actual_plan_digest" ] || {
    printf 'roundhouse: apply plan integrity check failed\n' >&2
    exit 65
  }
  expected_plan_id="plan-$(printf '%s' "$actual_plan_digest" | cut -c 1-16)"
  [ "$(jq -r '.plan_id' "$plan")" = "$expected_plan_id" ] || {
    printf 'roundhouse: apply plan ID does not match its digest\n' >&2
    exit 65
  }
  config=$(config_path)
  if jq -e 'any(.operations[]; .id == "roundhouse:launcher")' "$plan" >/dev/null; then
    launcher_plan_destination=$(jq -r '
      .operations[] | select(.id == "roundhouse:launcher") |
      select(.type == "agent-update" and .kind == "agent_artifact" and
        (.argv == ["roundhouse","launcher-install",.argv[2]]) and
        (.expected_digest | type == "string" and test("^[0-9a-f]{64}$"))) | .argv[2]
    ' "$plan")
    [ -n "$launcher_plan_destination" ] || {
      printf 'roundhouse: invalid Roundhouse launcher plan operation\n' >&2
      exit 64
    }
    validate_launcher_destination "$launcher_plan_destination"
    jq -e -s --arg destination "$launcher_plan_destination" '
      any(.[]; .kind == "agent_artifact" and .id == "roundhouse:launcher" and
        (.status | IN("present","absent")) and .data.path == $destination)
    ' "$snapshot" >/dev/null || {
      printf 'roundhouse: current snapshot is not bound to the launcher destination\n' >&2
      exit 65
    }
  fi
  verify_executor_requirement "$plan" >/dev/null
  target=$(jq -r '.target' "$plan")
  platform=$(jq -r --arg target "$target" '.machines[$target].platform' "$config")
  jq -e --arg platform "$platform" '
    all(.operations[];
      if .type == "chezmoi-apply" and has("targets") then
        all(.targets[];
          if $platform == "windows" then test("^[A-Za-z]:\\\\") and contains("\\")
          else startswith("/") and (contains("\\") | not)
          end)
      else true end)
  ' "$plan" >/dev/null || {
    printf 'roundhouse: chezmoi targets do not match the target platform\n' >&2
    exit 64
  }
  if jq -e '.worker != null' "$config" >/dev/null; then
    jq -e --arg target "$target" --arg controller_digest "$(jq -r '.configuration_digest.value' "$plan")" '
      .worker.target == $target and
      .worker.controller_configuration_digest == $controller_digest
    ' "$config" >/dev/null &&
      [ "$(jq -r '.worker_configuration_digest.value' "$plan")" = "$(sha256_file "$config")" ] || {
        printf 'roundhouse: bounded worker configuration does not match the sealed plan\n' >&2
        exit 65
      }
  else
    [ "$(jq -r '.configuration_digest.value' "$plan")" = "$(sha256_file "$config")" ] || {
      printf 'roundhouse: configuration changed after planning; create a new plan\n' >&2
      exit 65
    }
  fi
  validate_file "$snapshot"
  jq -e -s --arg target "$target" 'map(.host_id) | unique == [$target]' "$snapshot" >/dev/null || {
    printf 'roundhouse: current snapshot does not exclusively describe plan target %s\n' "$target" >&2
    exit 64
  }
  transport=$(jq -r --arg target "$target" '.machines[$target].transport' "$config")
  if [ "$transport" = local ] || [ "$transport" = ssh ]; then
    expected_hostname=$(jq -r --arg target "$target" '.machines[$target].expected_hostname // empty' "$config")
    expected_user=$(jq -r --arg target "$target" '.machines[$target].expected_user // empty' "$config")
    [ -n "$expected_hostname" ] && [ -n "$expected_user" ] || {
      printf 'roundhouse: mutation requires expected_hostname and expected_user for %s\n' "$target" >&2
      exit 65
    }
    jq -e -s --arg hostname "$expected_hostname" --arg user "$expected_user" '
      any(.[]; .kind == "host" and .status == "present" and
        .data.hostname == $hostname and .data.user == $user)
    ' "$snapshot" >/dev/null || {
      printf 'roundhouse: target identity does not match configured hostname/user\n' >&2
      exit 65
    }
  fi
  planning_snapshot_id=$(jq -r '.planning_snapshot_id' "$plan")
  jq -e -s --arg planning_snapshot_id "$planning_snapshot_id" '
    any(.[]; .kind == "snapshot" and .snapshot_id != $planning_snapshot_id and
      ((.observed_at | fromdateiso8601) as $observed |
        (now - $observed) >= 0 and (now - $observed) <= 900))
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: apply requires a distinct inventory captured within the last 15 minutes\n' >&2
    exit 65
  }
  required_section=$(jq -r '.required_section' "$plan")
  jq -e -s --arg section "$required_section" '
    any(.[]; .kind == "snapshot" and
      ((.data.sections | index("all")) != null or (.data.sections | index($section)) != null)) and
    any(.[]; .kind == "operation" and .status == "present" and .data.operation_status == "completed")
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: current snapshot lacks a completed %s inventory\n' "$required_section" >&2
    exit 65
  }
  jq -e -n --slurpfile plan "$plan" --slurpfile records "$snapshot" '
    [$plan[0].operations[] | ([.kind,.id] | @json)] as $wanted |
    [$records[] | select(.kind != "snapshot" and .kind != "operation" and
      (.status == "present" or .status == "absent")) | ([.kind,.id] | @json)] as $observed |
    ($wanted - $observed) | length == 0
  ' >/dev/null || {
    printf 'roundhouse: current snapshot does not cover every planned operation\n' >&2
    exit 65
  }
  [ "$(jq -r '.precondition_digest.value' "$plan")" = "$(precondition_digest "$plan" "$snapshot")" ] || {
    printf 'roundhouse: target state changed after planning; create a new plan\n' >&2
    exit 65
  }
  jq -cn --arg plan_id "$expected_plan_id" --arg target "$target" \
    '{verified:true,plan_id:$plan_id,target:$target}'
}
