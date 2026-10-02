# roundhouse — plan sealing: turning a validated draft into a sealed plan.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

seal_plan_command() {
  draft=$1
  snapshot=$2
  output=$3
  require_jq
  [ -f "$draft" ] && [ ! -L "$draft" ] || {
    printf 'roundhouse: plan draft must be a regular non-symlink file\n' >&2
    exit 64
  }
  privileged=false
  mixed_privileged=false
  if jq -e '(.operations | type == "array") and any(.operations[]; has("privilege_request"))' "$draft" >/dev/null 2>&1; then
    validate_mixed_privileged_draft "$draft"
    mixed_privileged=true
  elif jq -e 'has("privilege_request")' "$draft" >/dev/null; then
    validate_privileged_draft "$draft"
    privileged=true
  else
    jq -e '
    type == "object" and
    (.domain | IN("updates","agents","auth","chezmoi","projects")) and
    (.target | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.operations | type == "array" and length > 0) and
    ([.operations[] |
      type == "object" and
      (.type | IN(
        "package-metadata-refresh","package-upgrade","package-cleanup",
        "agent-update",
        "auth-reauth","auth-install",
        "chezmoi-pull","chezmoi-apply","chezmoi-external-reset",
        "project-clone","project-update"
      )) and
      (.kind | IN("package","agent_runtime","plugin","skill","capability","skill_root","agent_artifact","auth_artifact","file","chezmoi_state","chezmoi_external","project")) and
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
       else true end) and
      (if has("status_digest") then
        .type == "chezmoi-apply" and has("targets") and
        (.status_digest | type == "string" and test("^[0-9a-f]{64}$"))
       else true end) and
      (if .type == "chezmoi-external-reset" then
        (.id | type == "string" and length <= 512 and startswith("/") and
          (contains("\\") | not) and (test("(^|/)\\.\\.?($|/)") | not)) and
        # Full object IDs in either Git object format (SHA-1 or SHA-256).
        (.head | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
        (.upstream_head | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
        .argv == ["git","-C",.id,"reset","--hard","--quiet",.upstream_head]
       elif has("upstream_head") or has("head") then false
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
         (.type == "chezmoi-apply" and .kind == "chezmoi_state" and .id == "live") or
         (.type == "chezmoi-external-reset" and .kind == "chezmoi_external")
       ] | all
     elif .domain == "projects" then
       [.operations[] | .kind == "project" and (.type | startswith("project-"))] | all
     else false end) and
    ([.. | strings |
      length <= 8192 and (test("[[:cntrl:]]") | not)
    ] | all)
  ' "$draft" >/dev/null || {
    printf 'roundhouse: invalid plan draft\n' >&2
    exit 64
  }
  fi
  # One Node switch per plan: plain operation validation allows duplicate IDs,
  # and a second switch would carry versions an earlier npm upgrade changed.
  jq -e '[.operations[] | select(.id == "fnm:node")] | length <= 1' "$draft" >/dev/null || {
    printf 'roundhouse: a plan may contain at most one Node switch\n' >&2
    exit 65
  }
  # A Node switch must run before any npm upgrade in the same plan: an npm
  # upgrade first changes a version the switch's sealed carry names, and the
  # switch would then refuse halfway through an already-mutated plan.
  jq -e '(.operations | map(.id)) as $ids | ($ids | index("fnm:node")) as $switch |
    $switch == null or all(range(0; $switch); $ids[.] | startswith("npm:") | not)' \
    "$draft" >/dev/null || {
    printf 'roundhouse: the Node switch must precede every npm upgrade in the same plan\n' >&2
    exit 65
  }
  # The shape of a Node switch, shared with verify-preconditions.
  node_switch_operations_valid "$draft" || {
    printf 'roundhouse: invalid plan draft\n' >&2
    exit 64
  }
  validate_file "$snapshot"
  # No npm upgrade seals for a host whose snapshot records a Node switch in
  # flight: its runtime is unverified or still moving.
  ! node_switch_npm_blocked "$draft" "$snapshot" || {
    printf 'roundhouse: a Node switch is recorded in flight on the target; npm upgrades are refused until it is resolved\n' >&2
    exit 65
  }
  target=$(jq -r '.target' "$draft")
  domain=$(jq -r '.domain' "$draft")
  case $domain in
    updates) required_section=packages ;;
    agents) required_section=agents ;;
    auth) required_section=auth ;;
    chezmoi) required_section=chezmoi ;;
    projects) required_section=projects ;;
  esac
  config=$(config_path)
  validate_config_file
  jq -e --arg target "$target" '.machines[$target] != null' "$config" >/dev/null || {
    printf 'roundhouse: plan target is not configured: %s\n' "$target" >&2
    exit 64
  }
  jq -e --arg target "$target" --slurpfile draft "$draft" '
    . as $config |
    all($draft[0].operations[];
      if .type == "auth-install" then
        .id as $id |
        (($config.auth_artifacts[$id].path // null) != null or
         ($config.auth_artifacts[$id].paths[$target] // null) != null)
      elif .type == "auth-reauth" then
        . as $operation |
        .id as $id |
        ($config.auth_artifacts[$id].strategy == "reauth") and
        ($config.auth_artifacts[$id].reauth == $operation.argv)
      else true end)
  ' "$config" >/dev/null || {
    printf 'roundhouse: auth operation is not configured for target %s\n' "$target" >&2
    exit 65
  }
  # npm upgrades carry one of exactly two argv shapes: the exact-version
  # global install, or the updater the configuration declares for that
  # package (the auth-reauth precedent: configured argv, compared whole).
  jq -e --slurpfile draft "$draft" '
    . as $config |
    all(($draft[0].operations // [])[];
      if .type == "package-upgrade" and (.id | startswith("npm:")) then
        (.argv == ["npm","install","--global",((.id | ltrimstr("npm:")) + "@" + .candidate_version)]) or
        (($config.package_updaters[.id] // null) == .argv)
      else true end)
  ' "$config" >/dev/null || {
    printf 'roundhouse: npm upgrade argv is neither the exact global install nor the configured updater\n' >&2
    exit 65
  }
  platform=$(jq -r --arg target "$target" '.machines[$target].platform' "$config")
  jq -e --arg platform "$platform" '
    all(.operations[];
      if .type == "chezmoi-apply" and has("targets") then
        all(.targets[];
          if $platform == "windows" then test("^[A-Za-z]:\\\\") and contains("\\")
          else startswith("/") and (contains("\\") | not)
          end)
      else true end)
  ' "$draft" >/dev/null || {
    printf 'roundhouse: chezmoi targets do not match the target platform\n' >&2
    exit 64
  }
  if [ "$platform" = windows ] && [ "$privileged" = false ] && [ "$mixed_privileged" = false ]; then
    # An ordinary Windows plan needs a native lane to run on: the saved Codex
    # control project, or the WSL interop sibling (apply-interop-plan).
    interop_lane=false
    wsl_interop_alias "$config" "$target" >/dev/null && interop_lane=true
    jq -e --arg target "$target" --argjson interop "$interop_lane" '
      .machines[$target] as $machine |
      ($machine.expected_hostname | type == "string" and length > 0) and
      ($machine.expected_user | type == "string" and length > 0) and
      ((($machine.codex_control_project | type == "string" and length > 0) and
        (.projects[$machine.codex_control_project] != null)) or $interop)
    ' "$config" >/dev/null || {
      printf 'roundhouse: Windows mutation requires expected identity and a configured Codex control project or WSL interop sibling\n' >&2
      exit 65
    }
    jq -e '
      if .domain == "updates" then
        [.operations[] |
          .type == "package-upgrade" and .kind == "package" and
          ((.id | startswith("winget:")) or (.id | startswith("npm:")))
        ] | all
      elif .domain == "agents" then
        [.operations[] | .type == "agent-update"] | all
      elif .domain == "chezmoi" then
        # The native Windows executor has neither the reset nor the target
        # status digest check.
        [.operations[] | .type != "chezmoi-external-reset" and (has("status_digest") | not)] | all
      elif .domain == "projects" then true
      else false end
    ' "$draft" >/dev/null || {
      printf 'roundhouse: operation is not supported by the native Windows executor\n' >&2
      exit 69
    }
  fi
  if [ "$platform" = windows ]; then
    # Node on Windows is winget's OpenJS.NodeJS MSI, installed machine-wide:
    # its upgrade needs elevation (UAC), which the ordinary lane never
    # attempts. Only a user-scope install observed as such may upgrade here;
    # a machine-scope one goes through the protected
    # winget.upgrade-machine-package.v1 action when readiness advertises it,
    # and is otherwise a hold. Unknown scope is machine scope.
    jq -e -n --slurpfile draft "$draft" --slurpfile records "$snapshot" '
      all($draft[0].operations[];
        if .type == "package-upgrade" and .id == "winget:OpenJS.NodeJS" then
          . as $operation |
          any($records[]; .kind == "package" and .id == $operation.id and
            .data.install_scope == "user")
        else true end)
    ' >/dev/null || {
      printf 'roundhouse: hold: Node.js (winget OpenJS.NodeJS) is installed machine-wide and needs elevation; seal the protected winget.upgrade-machine-package.v1 action when readiness advertises it, never a UAC prompt\n' >&2
      exit 69
    }
  fi
  jq -e -s --arg target "$target" 'map(.host_id) | unique == [$target]' "$snapshot" >/dev/null || {
    printf 'roundhouse: snapshot does not exclusively describe plan target %s\n' "$target" >&2
    exit 64
  }
  jq -e -s --arg section "$required_section" '
    any(.[]; .kind == "snapshot" and
      ((.data.sections | index("all")) != null or (.data.sections | index($section)) != null)) and
    any(.[]; .kind == "operation" and .status == "present" and .data.operation_status == "completed")
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: snapshot does not contain a completed %s inventory\n' "$required_section" >&2
    exit 65
  }
  if jq -e 'any(.operations[]; .id == "roundhouse:launcher")' "$draft" >/dev/null; then
    launcher_plan_destination=$(jq -r '
      .operations[] | select(.id == "roundhouse:launcher") |
      select(.type == "agent-update" and .kind == "agent_artifact" and
        (.argv == ["roundhouse","launcher-install",.argv[2]]) and
        (.expected_digest | type == "string" and test("^[0-9a-f]{64}$"))) | .argv[2]
    ' "$draft")
    [ -n "$launcher_plan_destination" ] || {
      printf 'roundhouse: invalid Roundhouse launcher plan operation\n' >&2
      exit 64
    }
    validate_launcher_destination "$launcher_plan_destination"
    jq -e -s --arg destination "$launcher_plan_destination" '
      any(.[]; .kind == "agent_artifact" and .id == "roundhouse:launcher" and
        (.status | IN("present","absent")) and .data.path == $destination)
    ' "$snapshot" >/dev/null || {
      printf 'roundhouse: launcher plan is not bound to its observed destination\n' >&2
      exit 65
    }
  fi
  if jq -e 'any(.operations[]; .id == "roundhouse:schedule")' "$draft" >/dev/null; then
    schedule_operations_valid "$draft" || {
      printf 'roundhouse: invalid fleet-schedule plan operation\n' >&2
      exit 64
    }
    # Bound to what was OBSERVED: every file a step writes over, keeps,
    # removes or absorbs is the observed file at its observed digest (or
    # observed absent), so the plan is the snapshot's and nothing else's.
    jq -e -n --slurpfile draft "$draft" --slurpfile records "$snapshot" '
      first($records[] | select(.kind == "agent_artifact" and
        .id == "roundhouse:schedule" and (.status | IN("present","absent")))) as $r |
      all($draft[0].operations[] | select(.id == "roundhouse:schedule") | .steps[];
        . as $s |
        if .action == "write" then
          any($r.data.files[]; .path == $s.path and .mode == $s.mode and .digest == $s.before)
        elif .action == "keep" then
          any($r.data.files[]; .path == $s.path and .mode == $s.mode and .digest == $s.digest)
        elif .action == "remove" then
          any($r.data.files[]; .path == $s.path and .mode == $s.mode and .digest == $s.before)
        elif .action == "absorb" then
          any($r.data.legacy[]; .path == $s.path and .digest == $s.before)
        else true end)
    ' >/dev/null || {
      printf 'roundhouse: fleet-schedule plan is not bound to the observed definitions\n' >&2
      exit 65
    }
  fi
  if [ "$privileged" = true ] || [ "$mixed_privileged" = true ]; then
    if [ "$mixed_privileged" = true ]; then
      privilege_actions=$(jq -c '[.operations[] | select(.type == "semantic-action") |
        {action_id:.privilege_request.action_id,policy_token:.privilege_request.policy_token}]' "$draft")
    else
      privilege_actions=$(jq -c '[{action_id:.privilege_request.action_id,policy_token:.privilege_request.policy_token}]' "$draft")
    fi
    privilege_contracts=$(privileged_action_contract_json)
    jq -e -s --arg platform "$platform" --argjson actions "$privilege_actions" \
      --argjson contracts "$privilege_contracts" \
      --argjson require_preconditions "$mixed_privileged" '
      . as $records |
      all($actions[]; . as $request |
      (($platform == "linux" and $contracts[$request.action_id].context == "posix-root-v1") or
       ($platform == "macos" and $contracts[$request.action_id].context == "macos-root-v1") or
       ($platform == "windows" and ($contracts[$request.action_id].context | startswith("windows-")))) and
      any($records[]; .data as $readiness | .kind == "privilege_broker" and .id == "readiness" and .status == "present" and
        .data.lifecycle_status == "ready" and .data.transport_ready == true and
        .data.node_identity_ready == true and .data.broker_ready == true and
        .data.action_context_ready == true and .data.adapter_mechanism_ready == true and
        (.data.broker_protocol.observed as $protocol |
          ($protocol | type == "number") and (.data.broker_protocol.supported | index($protocol) != null)) and
        (.data.broker_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        (.data.broker_digest.value | test("^[0-9a-f]{64}$")) and
        (.data.observed_policy_digest.value | test("^[0-9a-f]{64}$")) and
        (.data.observed_constraints_digest.value | test("^[0-9a-f]{64}$")) and
        (.data.context_canary_digest.value | test("^[0-9a-f]{64}$")) and
        (.data.enrollment_epoch | type == "number" and . >= 1) and
        (.data.constraint_generation == .data.enrollment_epoch) and
        (.data.node_identity.node_id | type == "string" and length > 0) and
        (.data.node_identity.fleet_domain | type == "string" and length > 0) and
        (.data.node_identity.node_key_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
        (.data.node_identity.fleet_ca_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
        (.data.node_identity.certificate_serial | test("^(0|[1-9][0-9]{0,19})$")) and
        (.data.node_identity.certificate_valid_after | fromdateiso8601 > 0 and fromdateiso8601 <= now) and
        (.data.node_identity.certificate_valid_before | fromdateiso8601 > now) and
        (.data.originating_node_identity.node_id | type == "string" and length > 0) and
        (.data.originating_node_identity.fleet_domain | type == "string" and length > 0) and
        (.data.originating_node_identity.node_key_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
        (.data.originating_node_identity.fleet_ca_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
        (.data.originating_node_identity.certificate_serial | test("^(0|[1-9][0-9]{0,19})$")) and
        (.data.originating_node_identity.certificate_valid_after | fromdateiso8601 > 0 and fromdateiso8601 <= now) and
        (.data.originating_node_identity.certificate_valid_before | fromdateiso8601 > now) and
        (.data.pinned_host_key_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
        (.data.request_principal | type == "string" and length > 0) and
        (if ($platform | IN("linux","macos")) then .data.platform_adapter == "posix-sudo-v1"
         elif $platform == "windows" then .data.platform_adapter == "windows-scheduled-task-v1"
         else false end) and
        any(.data.observed_action_contexts[]; .action_id == $request.action_id and
          .context_id == $contracts[$request.action_id].context and
          .constraint_kind == $contracts[$request.action_id].constraint_kind and
          .constraint_generation == $readiness.constraint_generation and
          (.policy_tokens | type == "array" and unique == .) and
          (if $contracts[$request.action_id].token == "none" then
             .constraint_digest == "-" and $request.policy_token == null and (.policy_tokens | length) == 0
           else (.constraint_digest | test("^[0-9a-f]{64}$")) and
             ($request.policy_token | type == "string") and (.policy_tokens | index($request.policy_token) != null)
           end) and
          (if $contracts[$request.action_id].context == "windows-user-s4u-v1" then
             any(.profile_constraints[]; .policy_token == $request.policy_token and
               (.target_sid | test("^S-[0-9]+(?:-[0-9]+){1,14}$")) and
               .target_sid != $readiness.protected_identity.sid and
               ([.profile_root_id,.entry_map_digest,.marketplace_set_digest] |
                 all(type == "string" and test("^[0-9a-f]{64}$"))) and
               (.delete_mode | IN("managed-only","managed-and-prune")) and
               (.max_entries | type == "number" and floor == . and . >= 1 and . <= 100000) and
               (.max_bytes | type == "number" and floor == . and . >= 1 and . <= 1073741824))
           else true end)) and
        (if $require_preconditions then
           any(.data.observed_preconditions[]; .action_id == $request.action_id and
             .policy_token == (if $request.policy_token == null then "-" else $request.policy_token end) and
             (.digest | type == "object" and .algorithm == "sha256" and
               (.value | type == "string" and test("^[0-9a-f]{64}$"))))
         else true end)))
    ' "$snapshot" >/dev/null || {
      printf 'roundhouse: privileged action is not ready in the observed broker context\n' >&2
      exit 65
    }
    if [ "$mixed_privileged" = true ]; then
      privilege_expiries=$(jq -c '[.operations[] | select(.type == "semantic-action") | .privilege_request.expires_at]' "$draft")
    else
      privilege_expiries=$(jq -c '[.privilege_request.expires_at]' "$draft")
    fi
    jq -e -s --argjson expiries "$privilege_expiries" '
      first(.[] | select(.kind == "privilege_broker" and .id == "readiness")) as $r |
      all($expiries[]; (. | fromdateiso8601) as $expiry |
        ($expiry - now) >= $r.data.request_ttl.minimum_seconds and
        ($expiry - now) <= $r.data.request_ttl.maximum_seconds)
    ' "$snapshot" >/dev/null || {
      printf 'roundhouse: privileged request expiry is outside the observed broker bounds\n' >&2
      exit 65
    }
  fi
  if [ "$privileged" = false ]; then
    jq -e -n --slurpfile draft "$draft" --slurpfile records "$snapshot" '
      [$draft[0].operations[] | select(.type != "semantic-action") | ([.kind,.id] | @json)] as $wanted |
      [$records[] | select(.kind != "snapshot" and .kind != "operation" and
        (.status == "present" or .status == "absent")) | ([.kind,.id] | @json)] as $observed |
      ($wanted - $observed) | length == 0
    ' >/dev/null || {
      printf 'roundhouse: plan operations are not covered by usable snapshot records\n' >&2
      exit 65
    }
    jq -e -n --slurpfile draft "$draft" --slurpfile records "$snapshot" '
      all($draft[0].operations[] | select(.type != "semantic-action");
        if .type == "package-upgrade" then
          . as $operation |
          any($records[]; .kind == $operation.kind and .id == $operation.id and
            .status == "present" and .data.candidate_version == $operation.candidate_version and
            .data.update_available == true and
            # A package updater must also have been proven, at collect time,
            # to be a bin of the installed package.
            (if ($operation.id | startswith("npm:")) and
                $operation.argv != ["npm","install","--global",
                  (($operation.id | ltrimstr("npm:")) + "@" + $operation.candidate_version)]
             then .data.updater == $operation.argv else true end) and
            # A Node switch carries only globals installed under the current
            # default at exactly the recorded versions, and never a package
            # whose configured post-switch hook was unproven at collect time.
            (if $operation.id == "fnm:node" then
               (.data.prefix | type == "string") and (.data.globals | type == "object") and
               (.data.globals as $globals | all($operation.carry[]; $globals[.name] == .version)) and
               ((.data.switch_hooks_unproven // []) as $unproven |
                 all($operation.carry[]; ("npm:" + .name) as $key |
                   any($unproven[]; . == $key) | not))
             else true end))
        elif .type == "agent-update" and .kind == "agent_runtime" then
          . as $operation |
          any($records[]; .kind == $operation.kind and .id == $operation.id and
            .status == "present")
        elif .type == "project-update" then
          . as $operation |
          any($records[]; .kind == $operation.kind and .id == $operation.id and
            .status == "present" and .data.origin_matches == true and
            .data.repository_readiness == "ready" and .data.dirty_count == 0 and
            .data.sync_state == "local-tracking-behind")
        elif .type == "chezmoi-pull" then
          any($records[]; .kind == "file" and .id == "chezmoi:source" and
            .status == "present" and .data.dirty_count == 0)
        elif .type == "chezmoi-external-reset" then
          . as $operation |
          any($records[]; .kind == "chezmoi_external" and .id == $operation.id and
            .status == "present" and .data.state == "rewritten-resettable" and
            .data.dirty_count == 0 and .data.local_commits_from_upstream == true and
            .data.head == $operation.head and .data.upstream_head == $operation.upstream_head)
        else true end)
    ' >/dev/null || {
      printf 'roundhouse: %s plan does not match an actionable observed state\n' \
        "$domain" >&2
      exit 65
    }
  fi
  # A Node switch seals only on the carry rule (node_switch_plan, §7.5): its
  # carry is every global the snapshot shows installed under the current
  # default at its exact version, less what the new Node provides itself; an
  # unpinnable global holds it. `hooks` are exactly what the configuration
  # declares for the carried packages and `required` exactly the node_switch
  # hooks the store definitions require for them, each of which must be in
  # `hooks`. (Its order before any npm upgrade is checked above.)
  if jq -e 'any(.operations[]?; .type == "package-upgrade" and .id == "fnm:node")' \
    "$draft" >/dev/null 2>&1; then
    node_seal_store=$(fleet_store_path)
    [ -d "$node_seal_store" ] || {
      printf 'roundhouse: a Node switch seals only against the store definitions (its hook requirements); no store at %s\n' \
        "$node_seal_store" >&2
      exit 65
    }
    node_seal_plan=$(node_switch_plan_from_snapshot "$snapshot" \
      "$(jq -r 'first(.operations[] | select(.type == "package-upgrade" and .id == "fnm:node")) |
        .candidate_version' "$draft")" \
      "$(fleet_definitions_load "$node_seal_store")" \
      "$(jq -c '.node_switch_hooks // {}' "$config")") || {
      printf 'roundhouse: the snapshot does not record the npm globals under the current Node default\n' >&2
      exit 65
    }
    node_seal_held=$(printf '%s\n' "$node_seal_plan" | jq -r '.held // empty')
    [ -z "$node_seal_held" ] || {
      printf 'roundhouse: Node switch held: %s\n' "$node_seal_held" >&2
      exit 65
    }
    jq -e --argjson plan "$node_seal_plan" '
      all(.operations[] | select(.type == "package-upgrade" and .id == "fnm:node");
        .carry == $plan.carry and .hooks == $plan.hooks and .required == $plan.required)
    ' "$draft" >/dev/null || {
      printf 'roundhouse: a Node switch carries every installed npm global: carry %s, hooks %s, required %s\n' \
        "$(printf '%s\n' "$node_seal_plan" | jq -c '.carry')" \
        "$(printf '%s\n' "$node_seal_plan" | jq -c '.hooks')" \
        "$(printf '%s\n' "$node_seal_plan" | jq -c '.required')" >&2
      exit 65
    }
  fi

  if [ "$privileged" = true ]; then
    action_precondition_action=$(jq -r '.privilege_request.action_id' "$draft")
    action_precondition_token=$(jq -r '.privilege_request.policy_token // "-"' "$draft")
    precondition_digest=$(privilege_action_precondition_digest "$snapshot" \
      "$action_precondition_action" "$action_precondition_token" || true)
    case $precondition_digest in
      ""|*[!0-9a-f]*)
        printf 'roundhouse: privileged action has no sealed protected precondition\n' >&2
        exit 65
        ;;
    esac
    [ "${#precondition_digest}" -eq 64 ] || {
      printf 'roundhouse: privileged action has an invalid protected precondition\n' >&2
      exit 65
    }
  elif [ "$mixed_privileged" = true ]; then
    precondition_digest=$(mixed_precondition_digest "$draft" "$snapshot")
  else
    precondition_digest=$(precondition_digest "$draft" "$snapshot")
  fi
  config_digest=$(sha256_file "$config")
  planning_snapshot_id=$(jq -r 'select(.kind == "snapshot") | .snapshot_id' "$snapshot")
  planning_observed_at=$(jq -r 'select(.kind == "snapshot") | .observed_at' "$snapshot")
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-plan.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  executor_status_command "$tmp/executor.json"
  worker_config_command "$target" "$domain" "$tmp/worker-config.json"
  worker_config_digest=$(sha256_file "$tmp/worker-config.json")
  if [ "$privileged" = true ]; then
    jq -s 'first(.[] | select(.kind == "privilege_broker" and .id == "readiness")) | .data' \
      "$snapshot" >"$tmp/readiness.json"
    jq -S -n \
      --slurpfile draft "$draft" --slurpfile executor "$tmp/executor.json" \
      --slurpfile readiness "$tmp/readiness.json" \
      --argjson contracts "$privilege_contracts" \
      --arg created_at "$created_at" --arg config_digest "$config_digest" \
      --arg worker_config_digest "$worker_config_digest" --arg precondition_digest "$precondition_digest" \
      --arg required_section "$required_section" --arg planning_snapshot_id "$planning_snapshot_id" \
      --arg planning_observed_at "$planning_observed_at" '
      $readiness[0] as $r |
      $draft[0].privilege_request.action_id as $action |
      first($r.observed_action_contexts[] | select(.action_id == $action and
        .context_id == $contracts[$action].context and
        .constraint_kind == $contracts[$action].constraint_kind)) as $a |
      {
        schema:"roundhouse.plan",schema_version:3,created_at:$created_at,
        domain:$draft[0].domain,target:$draft[0].target,operations:$draft[0].operations,
        required_section:$required_section,planning_snapshot_id:$planning_snapshot_id,
        planning_observed_at:$planning_observed_at,
        configuration_digest:{algorithm:"sha256",value:$config_digest},
        worker_configuration_digest:{algorithm:"sha256",value:$worker_config_digest},
        precondition_digest:{algorithm:"sha256",value:$precondition_digest},
        required_executor:($executor[0] | {plugin,marketplace,version,integrity_manifest_sha256,files}),
        privilege:{
          contract_version:1,
          broker:{adapter:$r.platform_adapter,protocol_version:$r.broker_protocol.observed,
            version:$r.broker_version,digest:$r.broker_digest},
          policy:{catalog_version:$r.policy.catalog_version,version:$r.policy.version,
            action_manifest_version:$r.policy.action_manifest_version,digest:$r.observed_policy_digest,
            proposal_digest:$r.policy_proposal_digest,constraint_kind:$a.constraint_kind,
            constraint_digest:$a.constraint_digest,constraint_generation:$a.constraint_generation,
            constraints_digest:$r.observed_constraints_digest},
          action:{id:$action,policy_token:$draft[0].privilege_request.policy_token},
          context:{required:$a.context_id,
            observed_execution_principal:(if ($a.context_id | IN("posix-root-v1","macos-root-v1")) then "root"
              elif $a.context_id == "windows-system-v1" then "LocalSystem" else "enrolled-s4u-user" end),
            session_requirement:$r.session_requirement,platform_boundary:$r.platform_boundary,
            manager_source_identity:$a.manager_source_identity,canary_digest:$r.context_canary_digest},
          request:{id:$draft[0].privilege_request.request_id,created_at:$created_at,
            expires_at:$draft[0].privilege_request.expires_at,transport:$r.transport,
            principal:$r.request_principal,originating_node_id:$r.originating_node_identity.node_id,
            node_key_fingerprint:$r.originating_node_identity.node_key_fingerprint,
            certificate_serial:$r.originating_node_identity.certificate_serial},
          enrollment:{epoch:$r.enrollment_epoch,fleet_domain:$r.originating_node_identity.fleet_domain,
            fleet_ca_fingerprint:$r.originating_node_identity.fleet_ca_fingerprint,
            ca_generation:$r.originating_node_identity.ca_generation,
            certificate_valid_after:$r.originating_node_identity.certificate_valid_after,
            certificate_valid_before:$r.originating_node_identity.certificate_valid_before,
            pinned_host_key_fingerprint:$r.pinned_host_key_fingerprint},
          precondition:{digest:{algorithm:"sha256",value:$precondition_digest}}
        }
      }' >"$tmp/base.json"
  elif [ "$mixed_privileged" = true ]; then
    jq -s 'first(.[] | select(.kind == "privilege_broker" and .id == "readiness")) | .data' \
      "$snapshot" >"$tmp/readiness.json"
    mkdir "$tmp/privilege-metadata"
    jq -c '.operations[] | select(.type == "semantic-action")' "$draft" >"$tmp/privileged-operations.jsonl"
    while IFS= read -r operation; do
      printf '%s\n' "$operation" >"$tmp/operation.json"
      request_id=$(jq -r '.privilege_request.request_id' "$tmp/operation.json")
      action_id=$(jq -r '.privilege_request.action_id' "$tmp/operation.json")
      action_token=$(jq -r '.privilege_request.policy_token // "-"' "$tmp/operation.json")
      action_precondition=$(jq -r --arg action "$action_id" --arg token "$action_token" '
        first(.observed_preconditions[] | select(.action_id == $action) |
          select(.policy_token == $token) |
          select(.digest.algorithm == "sha256") | .digest.value) // empty
      ' "$tmp/readiness.json")
      case $action_precondition in
        ""|*[!0-9a-f]*)
          printf 'roundhouse: privileged action has no sealed protected precondition\n' >&2
          exit 65
          ;;
      esac
      [ "${#action_precondition}" -eq 64 ] || {
        printf 'roundhouse: privileged action has an invalid protected precondition\n' >&2
        exit 65
      }
      write_v4_privilege_metadata "$tmp/operation.json" "$tmp/readiness.json" "$created_at" \
        "$action_precondition" "$tmp/privilege-metadata/$request_id.json"
    done <"$tmp/privileged-operations.jsonl"
    jq -s 'map({key:.request.id,value:.}) | from_entries' \
      "$tmp"/privilege-metadata/*.json >"$tmp/privilege-metadata.json"
    jq -S -n \
      --slurpfile draft "$draft" --slurpfile executor "$tmp/executor.json" \
      --slurpfile metadata "$tmp/privilege-metadata.json" \
      --arg created_at "$created_at" --arg config_digest "$config_digest" \
      --arg worker_config_digest "$worker_config_digest" --arg precondition_digest "$precondition_digest" \
      --arg required_section "$required_section" --arg planning_snapshot_id "$planning_snapshot_id" \
      --arg planning_observed_at "$planning_observed_at" '
      $metadata[0] as $metadata |
      {
        schema:"roundhouse.plan",schema_version:4,created_at:$created_at,
        domain:$draft[0].domain,target:$draft[0].target,
        operations:[
          $draft[0].operations[] |
          if .type == "semantic-action" then
            . as $operation | $operation.privilege_request.request_id as $request_id |
            {id:$operation.id,kind:$operation.kind,type:$operation.type,
              privilege:$metadata[$request_id]}
          else . end
        ],
        required_section:$required_section,planning_snapshot_id:$planning_snapshot_id,
        planning_observed_at:$planning_observed_at,
        configuration_digest:{algorithm:"sha256",value:$config_digest},
        worker_configuration_digest:{algorithm:"sha256",value:$worker_config_digest},
        precondition_digest:{algorithm:"sha256",value:$precondition_digest},
        required_executor:($executor[0] | {plugin,marketplace,version,integrity_manifest_sha256,files})
      }' >"$tmp/base.json"
  else
    jq -S -n \
      --slurpfile draft "$draft" \
      --slurpfile executor "$tmp/executor.json" \
      --arg created_at "$created_at" \
      --arg config_digest "$config_digest" \
      --arg worker_config_digest "$worker_config_digest" \
      --arg precondition_digest "$precondition_digest" \
      --arg required_section "$required_section" \
      --arg planning_snapshot_id "$planning_snapshot_id" \
      --arg planning_observed_at "$planning_observed_at" '
        {
          schema:"roundhouse.plan",
          schema_version:2,
          created_at:$created_at,
          domain:$draft[0].domain,
          target:$draft[0].target,
          operations:$draft[0].operations,
          required_section:$required_section,
          planning_snapshot_id:$planning_snapshot_id,
          planning_observed_at:$planning_observed_at,
          configuration_digest:{algorithm:"sha256",value:$config_digest},
          worker_configuration_digest:{algorithm:"sha256",value:$worker_config_digest},
          precondition_digest:{algorithm:"sha256",value:$precondition_digest},
          required_executor:(
            $executor[0] |
            {plugin,marketplace,version,integrity_manifest_sha256,files}
          )
        }' >"$tmp/base.json"
  fi
  plan_digest=$(jq -cS . "$tmp/base.json" | sha256_stream)
  plan_id="plan-$(printf '%s' "$plan_digest" | cut -c 1-16)"
  jq -S --arg plan_id "$plan_id" --arg plan_digest "$plan_digest" \
    '. + {plan_id:$plan_id,plan_digest:{algorithm:"sha256",value:$plan_digest}}' \
    "$tmp/base.json" >"$tmp/plan.json"
  if [ "$privileged" = true ]; then
    validate_privileged_plan_file "$tmp/plan.json"
  elif [ "$mixed_privileged" = true ]; then
    validate_mixed_privileged_plan_file "$tmp/plan.json"
    mixed_plan_integrity_check "$tmp/plan.json"
  fi
  safe_output "$tmp/plan.json" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
}
