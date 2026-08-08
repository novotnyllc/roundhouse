# roundhouse — plan contracts: precondition digests, privileged action and
# protocol contracts, draft validation, and profile bundles.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

precondition_digest() {
  operations=$1
  snapshot=$2
  validate_file "$snapshot"
  jq -cS -n --slurpfile operations "$operations" --slurpfile records "$snapshot" '
    [$operations[0].operations[] | {kind,id}] as $wanted |
    [$operations[0].operations[] |
      select(.type == "chezmoi-apply" and has("targets")) |
      ([.kind,.id] | @json)] as $targeted_chezmoi |
    [$records[] |
      . as $record |
      select(any($wanted[]; .kind == $record.kind and .id == $record.id)) |
      if any($targeted_chezmoi[]; . == ([$record.kind,$record.id] | @json)) then
        .data |= del(.drift_count,.status_codes,.status_digest)
      else . end |
      del(.snapshot_id,.observed_at,.data.codex_checked_at)
    ] | sort_by(.host_id,.kind,.id)[]' | sha256_stream
}

privilege_action_precondition_digest() {
  snapshot=$1
  action=$2
  policy_token=$3
  jq -er -s --arg action "$action" --arg policy_token "$policy_token" '
    [ .[] | select(.kind == "privilege_broker" and .id == "readiness" and .status == "present") |
      .data.observed_preconditions[]? |
      select(.action_id == $action and .policy_token == $policy_token) |
      select(.digest | type == "object" and .algorithm == "sha256" and
        (.value | type == "string" and test("^[0-9a-f]{64}$"))) |
      .digest.value ] |
    if length == 1 then .[0] else empty end
  ' "$snapshot"
}

# One closed descriptor is used by draft validation, sealing, preflight,
# request codecs, and result binding.  A request selects only an action and,
# where required, one protected token; it never supplies package/source/argv
# or dependency controls.
privileged_action_contract_json() {
  printf '%s\n' '{
    "apt.autoremove.v1":{"domain":"updates","context":"posix-root-v1","constraint_kind":"none","token":"none","payload":"empty","protocols":[1]},
    "apt.install-package-version.v1":{"domain":"updates","context":"posix-root-v1","constraint_kind":"package-source-version-closure-set-sha256","token":"protected","payload":"empty","protocols":[1]},
    "apt.update-metadata.v1":{"domain":"updates","context":"posix-root-v1","constraint_kind":"none","token":"none","payload":"empty","protocols":[1]},
    "apt.upgrade-package.v1":{"domain":"updates","context":"posix-root-v1","constraint_kind":"package-source-channel-set-sha256","token":"protected","payload":"empty","protocols":[1]},
    "macos.apply-system-setting.v1":{"domain":"updates","context":"macos-root-v1","constraint_kind":"macos-system-setting-sha256","token":"protected","payload":"empty","protocols":[1]},
    "macos.install-signed-pkg.v1":{"domain":"updates","context":"macos-root-v1","constraint_kind":"macos-signed-pkg-sha256","token":"protected","payload":"empty","protocols":[1]},
    "profile.apply-managed-bundle.v1":{"domain":"agents","context":"windows-user-s4u-v1","constraint_kind":"profile-bundle-set-sha256","token":"protected","payload":"profile-bundle","protocols":[1]},
    "profile.inventory-managed-state.v1":{"domain":"agents","context":"windows-user-s4u-v1","constraint_kind":"profile-bundle-set-sha256","token":"protected","payload":"empty","protocols":[1]},
    "winget.install-machine-package.v1":{"domain":"updates","context":"windows-system-v1","constraint_kind":"winget-package-version-set-sha256","token":"protected","payload":"empty","protocols":[1]},
    "winget.inventory-machine.v1":{"domain":"updates","context":"windows-system-v1","constraint_kind":"none","token":"none","payload":"empty","protocols":[1]},
    "winget.upgrade-machine-package.v1":{"domain":"updates","context":"windows-system-v1","constraint_kind":"winget-package-channel-set-sha256","token":"protected","payload":"empty","protocols":[1]}
  }'
}

privilege_protocol_matrix_json() {
  contracts=$(privileged_action_contract_json)
  jq -cn --argjson contracts "$contracts" '{
    "1":{readiness:true,result_query:true,drain:true,revocation:true,
      action_contexts:($contracts | to_entries | map({action_id:.key,context_id:.value.context}))},
    "0":{readiness:true,result_query:true,drain:true,revocation:true,action_contexts:[]}
  }'
}

privilege_protocol_supports_action() {
  protocol=$1
  action=$2
  contracts=$(privileged_action_contract_json)
  jq -en --argjson contracts "$contracts" --arg protocol "$protocol" --arg action "$action" '
    ($contracts[$action].protocols // []) | index($protocol | tonumber) != null
  ' >/dev/null 2>&1
}

privilege_protocol_supports_control() {
  protocol=$1
  control=$2
  case $control in readiness|result_query|drain|revocation) ;; *) return 1 ;; esac
  matrix=$(privilege_protocol_matrix_json)
  jq -en --argjson matrix "$matrix" --arg protocol "$protocol" --arg control "$control" \
    '$matrix[$protocol][$control] == true' >/dev/null 2>&1
}

validate_privileged_draft() {
  draft=$1
  contracts=$(privileged_action_contract_json)
  jq -e --argjson contracts "$contracts" '
    type == "object" and (keys | sort) == (["domain","operations","privilege_request","target"] | sort) and
    (.domain | IN("updates","agents")) and
    (.target | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.operations | type == "array" and length == 1) and
    (.operations[0] | type == "object" and (keys | sort) == (["id","kind","type"] | sort)) and
    .operations[0].type == "semantic-action" and .operations[0].kind == "privileged_action" and
    (.operations[0].id | type == "string") and
    (.privilege_request | type == "object" and
      (keys | sort) == (["action_id","expires_at","policy_token","request_id"] | sort)) and
    (.privilege_request.action_id == .operations[0].id) and
    (.privilege_request.action_id as $action | $contracts[$action] != null and
      .domain == $contracts[$action].domain and
      (if $contracts[$action].token == "protected" then
         (.privilege_request.policy_token | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
       else .privilege_request.policy_token == null end)) and
    (.privilege_request.request_id | type == "string" and test("^request-[0-9a-f]{32}$")) and
    (.privilege_request.expires_at | type == "string" and fromdateiso8601 > 0) and
    ([.. | strings | length <= 8192 and (test("[[:cntrl:]]") | not)] | all)
  ' "$draft" >/dev/null || {
    printf 'roundhouse: invalid privileged plan draft\n' >&2
    return 64
  }
}

# Schema v4 is deliberately additive.  Schema v2 stays the ordinary-user
# plan format and schema v3 stays the single-action U1 contract. A v4 plan is
# the only format which may place a broker action beside ordinary operations.
# Broker actions carry no argv or caller-chosen identity binding: every
# effective value is reconstructed from protected readiness and the broker's
# action/policy contract at submission time.
validate_mixed_privileged_draft() {
  draft=$1
  contracts=$(privileged_action_contract_json)
  jq -e --argjson contracts "$contracts" '
    def exact($expected): (keys | sort) == ($expected | sort);
    def bounded: ([.. | strings | length <= 8192 and (test("[[:cntrl:]]") | not)] | all);
    def ordinary:
      . as $o |
      (if .type == "package-upgrade" then
         exact(["candidate_version","id","kind","type","argv"])
       else exact(["id","kind","type","argv"]) end) and
      (.argv | type == "array" and length > 0 and length <= 64 and
        ([.[] | type == "string" and length > 0] | all) and
        ([.[] | (split("/") | last) | IN("sudo","apt-get")] | any | not)) and
      (.id | type == "string" and length > 0) and
      (.kind | IN("package","agent_runtime","plugin","skill")) and
      (.type | IN("package-metadata-refresh","package-upgrade","package-cleanup","agent-update")) and
      (if .type == "package-upgrade" then .candidate_version | type == "string" and length > 0 else true end) and
      (if $o.type | startswith("package-") then $o.kind == "package" else true end) and
      (if $o.type == "agent-update" then $o.kind | IN("agent_runtime","plugin","skill") else true end);
    def privileged:
      . as $operation |
      exact(["id","kind","privilege_request","type"]) and
      .type == "semantic-action" and .kind == "privileged_action" and
      (.id | type == "string") and
      (.privilege_request | exact(["action_id","expires_at","policy_token","request_id"]) and
        .action_id == $operation.id and
        (.request_id | type == "string" and test("^request-[0-9a-f]{32}$")) and
        (.expires_at | type == "string" and fromdateiso8601 > 0) and
        (.action_id as $action | $contracts[$action] != null and
          (if $contracts[$action].token == "protected" then
             (.policy_token | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
           else .policy_token == null end)));
    . as $draft |
    type == "object" and exact(["domain","operations","target"]) and
    (.domain | IN("updates","agents")) and
    (.target | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.operations | type == "array" and length > 1 and length <= 128 and
      (map(.id) as $ids | ($ids | unique | length) == ($ids | length))) and
    (any(.operations[]; .type == "semantic-action")) and
    ([.operations[] | if .type == "semantic-action" then privileged else ordinary end] | all) and
    ([.operations[] | select(.type == "semantic-action") |
      .id as $action | $contracts[$action].domain == $draft.domain] | all) and
    ([.operations[] | select(.type == "semantic-action") | .id as $action |
      if $draft.domain == "updates" then $contracts[$action].context | IN("posix-root-v1","macos-root-v1","windows-system-v1")
      else $contracts[$action].context == "windows-user-s4u-v1" end] | all) and
    (if .domain == "updates" then
       [.operations[] | select(.type != "semantic-action") | .kind == "package"] | all
     else [.operations[] | select(.type != "semantic-action") | .type == "agent-update"] | all end) and
    bounded
  ' "$draft" >/dev/null || {
    printf 'roundhouse: invalid mixed privileged plan draft\n' >&2
    return 64
  }
}

mixed_precondition_digest() {
  plan=$1
  snapshot=$2
  validate_file "$snapshot"
  jq -cS -n --slurpfile plan "$plan" --slurpfile records "$snapshot" '
    [$plan[0].operations[] | select(.type != "semantic-action") | {kind,id}] as $ordinary |
    ([ $plan[0].operations[] | select(.type == "semantic-action") ] | length > 0) as $has_privilege |
    [$records[] |
      if .kind == "privilege_broker" and .id == "readiness" then
        if $has_privilege then del(.snapshot_id,.observed_at,.data.active_request,.data.last_terminal_result) else empty end
      elif (. as $record | any($ordinary[]; .kind == $record.kind and .id == $record.id)) then
        del(.snapshot_id,.observed_at,.data.codex_checked_at)
      else empty end
    ] | sort_by(.host_id,.kind,.id)[]
  ' | sha256_stream
}

write_v4_privilege_metadata() (
  operation=$1
  readiness=$2
  created_at=$3
  precondition_digest=$4
  metadata_output=$5
  contracts=$(privileged_action_contract_json)
  jq -S -n --slurpfile operation "$operation" --slurpfile readiness "$readiness" \
    --argjson contracts "$contracts" \
    --arg created_at "$created_at" --arg precondition_digest "$precondition_digest" '
    $operation[0] as $operation |
    $readiness[0] as $r |
    $operation.privilege_request.action_id as $action |
    $contracts[$action] as $contract |
    first($r.observed_action_contexts[] | select(.action_id == $action and
      .context_id == $contract.context and .constraint_kind == $contract.constraint_kind)) as $a |
    (if $contract.context == "windows-user-s4u-v1" then
       first($a.profile_constraints[] | select(.policy_token == $operation.privilege_request.policy_token))
     else null end) as $profile |
    {
      contract_version:1,
      broker:{adapter:$r.platform_adapter,protocol_version:$r.broker_protocol.observed,
        version:$r.broker_version,digest:$r.broker_digest},
      policy:{catalog_version:$r.policy.catalog_version,version:$r.policy.version,
        action_manifest_version:$r.policy.action_manifest_version,digest:$r.observed_policy_digest,
        proposal_digest:$r.policy_proposal_digest,constraint_kind:$a.constraint_kind,
        constraint_digest:$a.constraint_digest,constraint_generation:$a.constraint_generation,
        constraints_digest:$r.observed_constraints_digest},
      action:{id:$action,policy_token:$operation.privilege_request.policy_token},
      context:{required:$a.context_id,
        observed_execution_principal:(if ($a.context_id | IN("posix-root-v1","macos-root-v1")) then "root"
          elif $a.context_id == "windows-system-v1" then "LocalSystem" else "enrolled-s4u-user" end),
        session_requirement:$r.session_requirement,platform_boundary:$r.platform_boundary,
        manager_source_identity:(if $profile == null then $a.manager_source_identity
          else $profile.entry_map_digest end),canary_digest:$r.context_canary_digest,
        platform_context_digest:(if $a.context_id == "macos-root-v1" then $r.observed_platform_context_digest
          else ($r.observed_winget_context_digest // null) end)},
      request:{id:$operation.privilege_request.request_id,created_at:$created_at,
        expires_at:$operation.privilege_request.expires_at,transport:$r.transport,
        principal:$r.request_principal,originating_node_id:$r.originating_node_identity.node_id,
        node_key_fingerprint:$r.originating_node_identity.node_key_fingerprint,
        certificate_serial:$r.originating_node_identity.certificate_serial,
        certificate_source_addresses:$r.originating_node_identity.certificate_source_addresses,
        target_uid:(if ($a.context_id | IN("posix-root-v1","macos-root-v1")) then ($r.protected_identity.uid | tostring) else "-" end),
        request_sid:(if ($a.context_id | startswith("windows-")) then $r.protected_identity.sid else "-" end)},
      enrollment:{epoch:$r.enrollment_epoch,fleet_domain:$r.originating_node_identity.fleet_domain,
        fleet_ca_fingerprint:$r.originating_node_identity.fleet_ca_fingerprint,
        ca_generation:$r.originating_node_identity.ca_generation,
        certificate_valid_after:$r.originating_node_identity.certificate_valid_after,
        certificate_valid_before:$r.originating_node_identity.certificate_valid_before,
        pinned_host_key_fingerprint:$r.pinned_host_key_fingerprint},
      precondition:{digest:{algorithm:"sha256",value:$precondition_digest}}
    }
  ' >"$metadata_output"
)

profile_compiled_entry_contract() {
  path=$1
  handler=$2
  folded=$(printf '%s' "$path" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$handler:$folded" in
    json-scalar:.claude/settings.json)
      printf '%s\t%s\t%s\n' claude-code-settings claude claude-settings
      ;;
    json-scalar:.codex/settings.json|json-scalar:.codex/settings.*.json)
      printf '%s\t%s\t%s\n' codex-settings codex codex-settings
      ;;
    toml-scalar:.codex/config.toml|toml-scalar:.codex/config.*.toml)
      printf '%s\t%s\t%s\n' codex-settings codex codex-settings
      ;;
    standalone-skill-file:.codex/skills/*/*)
      skill=$(printf '%s' "$folded" | cut -d/ -f3)
      printf '%s\t%s\tstandalone-skill-file:%s\n' "$skill" standalone \
        "$(printf '%s' "$folded" | sha256_stream)"
      ;;
    marketplace-desired-record:.codex/roundhouse/managed/marketplace.desired)
      printf '%s\t%s\t%s\n' marketplace-desired fleet-agents marketplace-desired
      ;;
    marketplace-file:.codex/roundhouse/marketplace-stage/*/*)
      artifact=$(printf '%s' "$folded" | cut -d/ -f4)
      printf '%s\t%s\tmarketplace-file:%s\n' "$artifact" fleet-agents \
        "$(printf '%s' "$folded" | sha256_stream)"
      ;;
    managed-file:.codex/roundhouse/managed/*/*)
      artifact=$(printf '%s' "$folded" | cut -d/ -f4)
      printf '%s\t%s\tmanaged-file:%s\n' "$artifact" roundhouse \
        "$(printf '%s' "$folded" | sha256_stream)"
      ;;
    *) return 1 ;;
  esac
}

profile_destination_contract() {
  path=$1
  handler=$2
  printf '%s\n' "$path" | LC_ALL=C awk '
    length($0) < 1 || length($0) > 512 || $0 !~ /^[A-Za-z0-9._@+ \/-]+$/ ||
      $0 ~ /^\// || $0 ~ /\/\// { exit 1 }
    {
      count=split($0, segment, "/")
      for (i=1; i<=count; i++) {
        folded=tolower(segment[i])
        if (segment[i] == "" || segment[i] == "." || segment[i] == ".." ||
            segment[i] ~ /[. ]$/ || folded ~ /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$/) exit 1
      }
    }
  ' || return 1
  folded=$(printf '%s' "$path" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case /$folded/ in
    */.ssh/*|*/authorized_keys/*|*/.codex/roundhouse/node-overlay/*|*/.codex/auth.json/*|\
    */.codex/plugins/cache/*|*/auth/*|*/credential*/*|*/secret*/*|*/cache/*|*/sessions/*|\
    */browser/*|*/history/*|*/internal/*|*/startup/*|*/tasks/*|*/programdata/*|*.tmpl/*)
      return 1
      ;;
  esac
  profile_compiled_entry_contract "$path" "$handler"
}

profile_source_link_count() {
  if stat -f '%l' "$1" >/dev/null 2>&1; then
    stat -f '%l' "$1"
  else
    stat -c '%h' "$1"
  fi
}

profile_source_is_non_symlink_path() {
  root=$1
  relative=$2
  current=$root
  old_ifs=$IFS
  IFS=/
  # shellcheck disable=SC2086
  set -- $relative
  IFS=$old_ifs
  for component in "$@"; do
    current=$current/$component
    [ ! -L "$current" ] || return 1
  done
}

validate_profile_handler_content() {
  handler=$1
  manager=$2
  source=$3
  case $handler in
    json-scalar)
      if [ "$manager" = claude ]; then
        jq -e 'type == "object" and
          (keys - ["remoteControlAtStartup","switchModelsOnFlag","model","effortLevel",
            "availableModels","fallbackModel","autoUpdatesChannel","agentPushNotifEnabled"] | length == 0) and
          all(to_entries[];
            if (.key | IN("remoteControlAtStartup","switchModelsOnFlag","agentPushNotifEnabled")) then
              (.value | type == "boolean")
            elif .key == "availableModels" then
              (.value | type == "array" and all(.[]; type == "string" and length > 0))
            elif .key == "fallbackModel" then
              (.value == null or (.value | type == "string" and length > 0))
            elif .key == "autoUpdatesChannel" then (.value | IN("latest","stable"))
            else (.value | type == "string" and length > 0) end)' \
          "$source" >/dev/null
      else
        jq -e 'type == "object" and
          (keys - ["model","model_reasoning_effort","service_tier","check_for_update_on_startup",
            "cli_auth_credentials_store"] | length == 0) and
          all(to_entries[];
            if .key == "check_for_update_on_startup" then (.value | type == "boolean")
            elif .key == "cli_auth_credentials_store" then (.value | IN("file","keyring","auto"))
            else (.value | type == "string" and length > 0) end)' "$source" >/dev/null
      fi
      ;;
    toml-scalar)
      LC_ALL=C awk '
        NR != 1 { exit 1 }
        $0 !~ /^(model|model_reasoning_effort|service_tier|check_for_update_on_startup|cli_auth_credentials_store)[[:space:]]*=[[:space:]]*(true|false|"[^"[:cntrl:]]+")[[:space:]]*$/ { exit 1 }
        /^check_for_update_on_startup[[:space:]]*=/ && $0 !~ /=[[:space:]]*(true|false)[[:space:]]*$/ { exit 1 }
        /^cli_auth_credentials_store[[:space:]]*=/ && $0 !~ /=[[:space:]]*"(file|keyring|auto)"[[:space:]]*$/ { exit 1 }
        /^(model|model_reasoning_effort|service_tier)[[:space:]]*=/ && $0 !~ /=[[:space:]]*"[^"[:cntrl:]]+"[[:space:]]*$/ { exit 1 }
        END { exit !(NR == 1) }
      ' "$source"
      ;;
    marketplace-desired-record)
      [ "$(tail -c 1 "$source" | wc -l | tr -d ' ')" -eq 1 ] &&
        LC_ALL=C awk -F '|' '
          NR == 1 { if ($0 != "marketplace-desired|1") exit 1; next }
          $0 == "end-marketplace-desired|" { ended++; next }
          ended || NF != 4 || $1 != "plugin" ||
            $2 !~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/ ||
            $3 !~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/ ||
            $4 !~ /^[0-9a-f]{64}$/ || (previous != "" && previous >= $0) { exit 1 }
          { previous=$0 }
          END { exit !(NR >= 2 && ended == 1) }
        ' "$source"
      ;;
    *) return 0 ;;
  esac
}

write_u64_be() {
  value=$1
  byte_index=7
  while [ "$byte_index" -ge 0 ]; do
    byte=$(( (value >> (byte_index * 8)) & 255 ))
    octal=$(printf '%03o' "$byte")
    printf '%b' "\\$octal"
    byte_index=$((byte_index - 1))
  done
}

profile_bundle_command() (
  spec=$1
  source_root=$2
  output=$3
  require_jq
  [ -f "$spec" ] && [ ! -L "$spec" ] || {
    printf 'roundhouse: profile bundle spec must be a regular non-symlink file\n' >&2
    exit 64
  }
  [ -d "$source_root" ] && [ ! -L "$source_root" ] || {
    printf 'roundhouse: profile source root must be a real directory\n' >&2
    exit 64
  }
  [ "$(wc -c <"$spec" | tr -d ' ')" -le 1048576 ] || {
    printf 'roundhouse: profile bundle spec exceeds its bound\n' >&2
    exit 64
  }
  jq -e '
    def exact($expected): (keys | sort) == ($expected | sort);
    type == "object" and exact(["action_id","entries","policy_token","profile_root_id",
      "request_id","schema","schema_version","target_sid"]) and
    .schema == "roundhouse.profile-bundle-spec" and .schema_version == 1 and
    (.request_id | type == "string" and test("^request-[0-9a-f]{32}$")) and
    (.action_id | IN("profile.apply-managed-bundle.v1","profile.inventory-managed-state.v1")) and
    (.policy_token | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
    (.target_sid | type == "string" and test("^S-[0-9]+(?:-[0-9]+){1,14}$")) and
    (.profile_root_id | type == "string" and test("^[0-9a-f]{64}$")) and
    (.entries | type == "array" and length <= 100000 and
      all(.[]; type == "object" and exact(["artifact","expected_manager","expected_presence",
        "expected_sha256","handler","logical_identity","manager","operation","path","source"]) and
        (.path | type == "string" and test("^[A-Za-z0-9._/-]+$") and
          (startswith("/") | not) and (test("(^|/)\\.\\.?(/|$)") | not)) and
        (.handler | IN("json-scalar","managed-file","marketplace-desired-record","marketplace-file",
          "standalone-skill-file","toml-scalar")) and
        ([.artifact,.manager,.logical_identity] | all(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"))) and
        (.operation | IN("delete","observe","write")) and
        (if .operation == "write" then
           (.source | type == "string" and test("^[A-Za-z0-9._/-]+$") and
             (startswith("/") | not) and (test("(^|/)\\.\\.?(/|$)") | not))
         else .source == null end) and
        (.expected_presence | IN("present","absent")) and
        (if .expected_presence == "present" then
           (.expected_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
           (.expected_manager | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"))
         else .expected_sha256 == "-" and .expected_manager == "-" end))) and
    ([.entries[].path | ascii_downcase] | unique | length) == (.entries | length) and
    ([.. | strings | length <= 8192 and (test("[[:cntrl:]]") | not)] | all)
  ' "$spec" >/dev/null || {
    printf 'roundhouse: invalid profile bundle spec\n' >&2
    exit 64
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-profile-bundle.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  : >"$tmp/payload"
  : >"$tmp/entries"
  empty_digest=$(printf '' | sha256_stream)
  index=0
  offset=0
  jq -c '.entries | sort_by(.path)[]' "$spec" >"$tmp/sorted.jsonl"
  while IFS= read -r entry; do
    path=$(printf '%s\n' "$entry" | jq -r '.path')
    handler=$(printf '%s\n' "$entry" | jq -r '.handler')
    contract=$(profile_destination_contract "$path" "$handler") || {
      printf 'roundhouse: profile handler/destination mismatch: %s\n' "$path" >&2
      exit 64
    }
    tab=$(printf '\t')
    IFS="$tab" read -r artifact manager logical_identity <<EOF
$contract
EOF
    [ "$(printf '%s\n' "$entry" | jq -r '.artifact')" = "$artifact" ] &&
      [ "$(printf '%s\n' "$entry" | jq -r '.manager')" = "$manager" ] &&
      [ "$(printf '%s\n' "$entry" | jq -r '.logical_identity')" = "$logical_identity" ] || {
        printf 'roundhouse: profile entry identity is not the compiled contract: %s\n' "$path" >&2
        exit 64
      }
    expected_presence=$(printf '%s\n' "$entry" | jq -r '.expected_presence')
    expected_sha256=$(printf '%s\n' "$entry" | jq -r '.expected_sha256')
    expected_manager=$(printf '%s\n' "$entry" | jq -r '.expected_manager')
    if [ "$expected_presence" = present ]; then
      [ "$expected_manager" = "$manager" ] || {
        printf 'roundhouse: expected profile manager is not the compiled owner: %s\n' "$path" >&2
        exit 64
      }
    fi
    operation=$(printf '%s\n' "$entry" | jq -r '.operation')
    length=0
    content_digest=$empty_digest
    if [ "$operation" = write ]; then
      relative=$(printf '%s\n' "$entry" | jq -r '.source')
      source=$source_root/$relative
      profile_source_is_non_symlink_path "$source_root" "$relative" &&
        [ -f "$source" ] && [ ! -L "$source" ] &&
        [ "$(profile_source_link_count "$source")" -eq 1 ] || {
          printf 'roundhouse: profile source must be a regular single-link non-symlink file: %s\n' "$relative" >&2
          exit 64
        }
      length=$(wc -c <"$source" | tr -d ' ')
      [ "$length" -le 16777216 ] || {
        printf 'roundhouse: profile payload exceeds its bound\n' >&2
        exit 64
      }
      assert_windows_broker_payload_length "$((offset + length))" || exit $?
      validate_profile_handler_content "$handler" "$manager" "$source" || {
        printf 'roundhouse: invalid content for profile handler: %s\n' "$path" >&2
        exit 64
      }
      content_digest=$(sha256_file "$source")
      cat "$source" >>"$tmp/payload"
    fi
    printf 'entry|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$index" "$path" "$handler" "$artifact" "$manager" "$logical_identity" "$operation" \
      "$offset" "$length" "$content_digest" "$expected_presence" "$expected_sha256" "$expected_manager" \
      >>"$tmp/entries"
    index=$((index + 1))
    offset=$((offset + length))
  done <"$tmp/sorted.jsonl"
  payload_digest=$(sha256_file "$tmp/payload")
  {
    printf '%s\n' 'profile-bundle|1'
    printf 'request-id|%s\n' "$(jq -r '.request_id' "$spec")"
    printf 'action-id|%s\n' "$(jq -r '.action_id' "$spec")"
    printf 'policy-token|%s\n' "$(jq -r '.policy_token' "$spec")"
    printf 'target-sid|%s\n' "$(jq -r '.target_sid' "$spec")"
    printf 'profile-root-id|%s\n' "$(jq -r '.profile_root_id' "$spec")"
    printf 'entry-count|%s\n' "$index"
    printf 'payload-length|%s\n' "$offset"
    printf 'payload-sha256|%s\n' "$payload_digest"
    cat "$tmp/entries"
    printf '%s\n' 'end-bundle|'
  } >"$tmp/manifest"
  manifest_length=$(wc -c <"$tmp/manifest" | tr -d ' ')
  [ "$manifest_length" -le 4194304 ] || {
    printf 'roundhouse: profile manifest exceeds its bound\n' >&2
    exit 64
  }
  assert_windows_broker_payload_length "$((16 + manifest_length + offset))" || exit $?
  {
    write_u64_be "$manifest_length"
    write_u64_be "$offset"
    cat "$tmp/manifest" "$tmp/payload"
  } >"$tmp/bundle"
  safe_output "$tmp/bundle" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)
