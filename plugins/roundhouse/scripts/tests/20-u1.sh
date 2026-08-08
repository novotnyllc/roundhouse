# roundhouse self-check — U1 — characterization and the signed identity
# contracts.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

characterize_u1_contracts() {
  "$cli" collect --target test-host --section packages --output "$tmp/u1-planning.jsonl"
  cat >"$tmp/u1-unprivileged-draft.json" <<'JSON'
{
  "domain": "updates",
  "target": "test-host",
  "operations": [
    {
      "type": "package-upgrade",
      "kind": "package",
      "id": "homebrew:git",
      "candidate_version": "2.51.0",
      "argv": ["env", "HOMEBREW_NO_AUTO_UPDATE=1", "brew", "upgrade", "git"]
    }
  ]
}
JSON
  "$cli" seal-plan "$tmp/u1-unprivileged-draft.json" "$tmp/u1-planning.jsonl" \
    "$tmp/u1-unprivileged-plan.json"
  [ "$(jq -r '.schema_version' "$tmp/u1-unprivileged-plan.json")" -eq 2 ] ||
    fail "U1 characterization changed the existing unprivileged plan schema"
  [ "$(jq -r 'has("privilege")' "$tmp/u1-unprivileged-plan.json")" = false ] ||
    fail "U1 characterization added broker fields to an unprivileged plan"

  "$cli" worker-config test-ssh agents "$tmp/u1-ssh-worker-config.json"
  u1_worker_digest=$(shasum -a 256 "$tmp/u1-ssh-worker-config.json" | awk '{print $1}')
  mkdir -p "$tmp/home/.codex/plugins/cache/characterization/roundhouse/1.0.0/scripts"
  cat >"$tmp/home/.codex/plugins/cache/characterization/roundhouse/1.0.0/scripts/roundhouse" <<'SH'
#!/usr/bin/env sh
case ${1:-} in
  verify-executor) exit 0 ;;
  apply-native-plan)
    output=$4
    printf '%s\n' '{"schema":"roundhouse.inventory","schema_version":1,"snapshot_id":"u1-partial","host_id":"test-ssh","kind":"operation","id":"apply:plan-0000000000000000","observed_at":"2026-01-01T00:00:00Z","status":"partial","confidence":"high","data":{"run_id":"u1-partial","host_id":"test-ssh","scope":["agents"],"phase":"verify","operation_status":"partial","plan_id":"plan-0000000000000000","transport":"ssh"},"evidence":[],"errors":[{"code":"apply_partial","severity":"error","retryable":false,"message":"fixture"}]}' >"$output"
    exit 70
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$tmp/home/.codex/plugins/cache/characterization/roundhouse/1.0.0/scripts/roundhouse"
  jq -n --arg digest "$u1_worker_digest" '{
    schema:"roundhouse.plan",schema_version:2,
    created_at:"2026-01-01T00:00:00Z",plan_id:"plan-0000000000000000",
    plan_digest:{algorithm:"sha256",value:("0" * 64)},target:"test-ssh",domain:"agents",
    operations:[{type:"agent-update",kind:"agent_runtime",id:"codex",argv:["codex","update"]}],
    required_section:"agents",planning_snapshot_id:"u1-characterization",
    planning_observed_at:"2026-01-01T00:00:00Z",
    configuration_digest:{algorithm:"sha256",value:("0" * 64)},
    worker_configuration_digest:{algorithm:"sha256",value:$digest},
    precondition_digest:{algorithm:"sha256",value:("0" * 64)},
    required_executor:{marketplace:"characterization",version:"1.0.0"}
  }' >"$tmp/u1-partial-plan.json"
  chmod 600 "$tmp/u1-partial-plan.json"
  set +e
  "$cli" apply-ssh-plan "$tmp/u1-partial-plan.json" plan-0000000000000000 \
    "$tmp/u1-authoritative-partial.jsonl" >/dev/null 2>&1
  u1_partial_rc=$?
  set -e
  [ "$u1_partial_rc" -eq 70 ] ||
    fail "U1 characterization lost the authoritative partial SSH result"
  [ "$(jq -r 'select(.kind == "operation") | .data.operation_status' \
    "$tmp/u1-authoritative-partial.jsonl")" = partial ] ||
    fail "U1 characterization did not preserve the partial terminal record"
}

characterize_u1_contracts
[ "${ROUNDHOUSE_TEST_SCOPE:-}" != u1-characterization ] || {
  printf 'PASS: U1 characterization\n'
  exit 0
}

test_u1_contracts() {
  policy_file="$plugin_cache/references/privilege-policy.default"
  "$cli" validate-privilege-policy "$policy_file"
  expires_at=$(jq -nr 'now + 600 | todateiso8601')
  ssh_keygen=/usr/bin/ssh-keygen
  [ -x "$ssh_keygen" ] || fail "U1 requires absolute system ssh-keygen"
  mkdir -p "$tmp/identity-a" "$tmp/identity-b" "$tmp/identity-future"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/fleet-ca"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/route-host-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/identity-a/node-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/identity-b/node-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/identity-future/node-key"
  "$ssh_keygen" -q -s "$tmp/fleet-ca" -I 'origin-a@fleet.example' -z 1 \
    -n 'origin-a@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    -O source-address=192.0.2.0/24 -O no-agent-forwarding -O no-port-forwarding -O no-pty \
    -O no-user-rc -O no-X11-forwarding "$tmp/identity-a/node-key.pub"
  "$ssh_keygen" -q -s "$tmp/fleet-ca" -I 'target-b@fleet.example' -z 2 \
    -n 'target-b@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    -O source-address=192.0.2.0/24 -O no-agent-forwarding -O no-port-forwarding -O no-pty \
    -O no-user-rc -O no-X11-forwarding "$tmp/identity-b/node-key.pub"
  "$ssh_keygen" -q -s "$tmp/fleet-ca" -I 'future-c@fleet.example' -z 3 \
    -n 'future-c@fleet.example,roundhouse-posix,roundhouse-windows' -V '+1h:+2h' \
    -O source-address=192.0.2.0/24 -O no-agent-forwarding -O no-port-forwarding -O no-pty \
    -O no-user-rc -O no-X11-forwarding "$tmp/identity-future/node-key.pub"
  awk 'NR == FNR { key=$0; next } END {
    print "[linux.example.invalid]:22 " key
    print "[windows.example.invalid]:22 " key
  }' "$tmp/route-host-key.pub" "$tmp/route-host-key.pub" >"$tmp/identity-a/known-hosts"
  cp "$tmp/identity-a/known-hosts" "$tmp/identity-b/known-hosts"
  cp "$tmp/identity-a/known-hosts" "$tmp/identity-future/known-hosts"
  "$ssh_keygen" -H -f "$tmp/identity-a/known-hosts" >/dev/null 2>&1
  "$ssh_keygen" -H -f "$tmp/identity-b/known-hosts" >/dev/null 2>&1
  "$ssh_keygen" -H -f "$tmp/identity-future/known-hosts" >/dev/null 2>&1
  chmod 600 "$tmp/identity-a/node-key" "$tmp/identity-a/node-key-cert.pub" "$tmp/identity-a/known-hosts" \
    "$tmp/identity-b/node-key" "$tmp/identity-b/node-key-cert.pub" "$tmp/identity-b/known-hosts" \
    "$tmp/identity-future/node-key" "$tmp/identity-future/node-key-cert.pub" "$tmp/identity-future/known-hosts"
  ca_fingerprint=$("$ssh_keygen" -lf "$tmp/fleet-ca.pub" -E sha256 | awk '{print $2}')
  # certificate_principals is canonical form — sorted and deduplicated, the
  # `unique == .` the CLI, the config validator and the plan verifier all
  # require, and what certify-ssh-node's own `sort -u` emits. Build it the
  # same way rather than in authoring order.
  make_identity_fixture() {
    fixture_directory=$1
    fixture_node=$2
    fixture_serial=$3
    fixture_output=$4
    fixture_fingerprint=$("$ssh_keygen" -lf "$fixture_directory/node-key.pub" -E sha256 | awk '{print $2}')
    fixture_after=$(TZ=UTC "$ssh_keygen" -Lf "$fixture_directory/node-key-cert.pub" | awk '/Valid: from/{print $3 "Z"}')
    fixture_before=$(TZ=UTC "$ssh_keygen" -Lf "$fixture_directory/node-key-cert.pub" | awk '/Valid: from/{print $5 "Z"}')
    jq -n --arg key "$fixture_directory/node-key" --arg cert "$fixture_directory/node-key-cert.pub" \
      --arg hosts "$fixture_directory/known-hosts" --arg node "$fixture_node" \
      --arg node_fp "$fixture_fingerprint" --arg ca_fp "$ca_fingerprint" \
      --arg after "$fixture_after" --arg before "$fixture_before" --arg serial "$fixture_serial" '{
        schema:"roundhouse.node-identity",schema_version:1,fleet_domain:"fleet.example",node_id:$node,
        private_key_path:$key,certificate_path:$cert,known_hosts_path:$hosts,
        node_key_fingerprint:$node_fp,fleet_ca_fingerprint:$ca_fp,ca_generation:1,
        certificate_serial:$serial,certificate_valid_after:$after,certificate_valid_before:$before,
        certificate_principals:(["roundhouse-posix","roundhouse-windows",($node+"@fleet.example")] | unique),
        certificate_source_addresses:["192.0.2.0/24"],enrollment_receipts:{}
      }' >"$fixture_output"
    chmod 600 "$fixture_output"
  }
  make_identity_fixture "$tmp/identity-a" origin-a 1 "$tmp/identity-a.json"
  make_identity_fixture "$tmp/identity-b" target-b 2 "$tmp/identity-b.json"
  make_identity_fixture "$tmp/identity-future" future-c 3 "$tmp/identity-future.json"
  fingerprint_a=$(jq -r '.node_key_fingerprint' "$tmp/identity-a.json")
  fingerprint_b=$ca_fingerprint
  target_fingerprint=$(jq -r '.node_key_fingerprint' "$tmp/identity-b.json")
  host_fingerprint=$("$ssh_keygen" -lf "$tmp/route-host-key.pub" -E sha256 | awk '{print $2}')
  export ROUNDHOUSE_IDENTITY="$tmp/identity-a.json"
  jq --rawfile policy "$policy_file" --arg hostname "$(hostname)" --arg user "$(id -un)" \
    --arg fingerprint "$host_fingerprint" '
    ($policy | split("\n") | map(select(length > 0))) as $records |
    .machines["test-apt"].privilege_broker = {
      policy_proposal:$records,
      automation_transport:{mode:"posix-ssh",host:"linux.example.invalid",port:22,
        request_user:"roundhouse",pinned_host_key_fingerprint:$fingerprint,
        management_networks:["192.0.2.0/24"]}
    } |
    .machines["test-windows"].privilege_broker = {
      automation_transport:{mode:"windows-sftp",host:"windows.example.invalid",port:22,
        request_user:"RoundhouseRequest",pinned_host_key_fingerprint:$fingerprint,
        request_sid:"S-1-5-21-1-2-3-2001",
        management_networks:["192.0.2.0/24"]}
    } |
    .machines["test-wsl"] = {platform:"wsl",transport:"local",expected_hostname:$hostname,
      expected_user:$user,groups:[],package_managers:[],dev_root:"~/dev"}
  ' "$tmp/config.json" >"$tmp/u1-config.json"
  mv "$tmp/u1-config.json" "$tmp/config.json"
  chmod 600 "$tmp/config.json"
  config_hash=$(shasum -a 256 "$tmp/config.json" | awk '{print $1}')
  "$cli" validate-config

  "$cli" worker-config test-apt inventory "$tmp/u1-worker.json"
  [ "$(jq -r '.worker.policy_proposal_source' "$tmp/u1-worker.json")" = user-configuration ] ||
    fail "U1 worker did not label the user policy proposal"
  [ "$(jq -r '.worker.node_identity_projected' "$tmp/u1-worker.json")" = false ] ||
    fail "U1 worker projected node-local identity"
  [ "$(jq -r '.worker.originating_node_identity.node_id' "$tmp/u1-worker.json")" = origin-a ] ||
    fail "U1 worker did not project sanitized originating-node metadata"
  if grep -q "$tmp/identity" "$tmp/u1-worker.json"; then
    fail "U1 worker leaked node-local identity paths"
  fi

  jq '.machines["test-apt"].privilege_broker.policy_proposal[1] += "|argv"' \
    "$tmp/config.json" >"$tmp/u1-invalid-policy.json"
  chmod 600 "$tmp/u1-invalid-policy.json"
  if ROUNDHOUSE_CONFIG="$tmp/u1-invalid-policy.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 accepted an extended privilege policy record"
  fi
  jq '.machines["test-apt"].privilege_broker.automation_transport.argv = ["sudo"]' \
    "$tmp/config.json" >"$tmp/u1-invalid-route.json"
  chmod 600 "$tmp/u1-invalid-route.json"
  if ROUNDHOUSE_CONFIG="$tmp/u1-invalid-route.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 accepted command-bearing automation transport"
  fi
  jq '.machines["test-apt"].privilege_broker.automation_transport.management_networks =
    ["999.999.999.999/32"]' "$tmp/config.json" >"$tmp/u1-invalid-ipv4-route.json"
  chmod 600 "$tmp/u1-invalid-ipv4-route.json"
  if ROUNDHOUSE_CONFIG="$tmp/u1-invalid-ipv4-route.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 accepted malformed IPv4 management network octets"
  fi
  jq '.machines["test-apt"].privilege_broker.automation_transport.management_networks =
    ["2001:db8::/64"]' "$tmp/config.json" >"$tmp/u1-ipv6-route.json"
  chmod 600 "$tmp/u1-ipv6-route.json"
  ROUNDHOUSE_CONFIG="$tmp/u1-ipv6-route.json" "$cli" validate-config
  jq '.private_key_path = "relative-key"' "$tmp/identity-a.json" >"$tmp/u1-invalid-identity.json"
  chmod 600 "$tmp/u1-invalid-identity.json"
  if ROUNDHOUSE_IDENTITY="$tmp/u1-invalid-identity.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 accepted a relative node private-key path"
  fi
  jq --arg fingerprint "$target_fingerprint" '.node_key_fingerprint = $fingerprint' \
    "$tmp/identity-a.json" >"$tmp/u1-tampered-identity.json"
  chmod 600 "$tmp/u1-tampered-identity.json"
  if ROUNDHOUSE_IDENTITY="$tmp/u1-tampered-identity.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 trusted claimed identity metadata over OpenSSH key material"
  fi
  awk '{print "[wrong-host.example.invalid]:22 " $0}' "$tmp/route-host-key.pub" \
    >"$tmp/wrong-hosts"
  chmod 600 "$tmp/wrong-hosts"
  jq --arg hosts "$tmp/wrong-hosts" '.known_hosts_path=$hosts' "$tmp/identity-a.json" \
    >"$tmp/u1-wrong-host-identity.json"
  chmod 600 "$tmp/u1-wrong-host-identity.json"
  if ROUNDHOUSE_IDENTITY="$tmp/u1-wrong-host-identity.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 accepted known-hosts without the configured host and port"
  fi
  jq --arg fingerprint "$target_fingerprint" \
    '.machines["test-apt"].privilege_broker.automation_transport.pinned_host_key_fingerprint=$fingerprint' \
    "$tmp/config.json" >"$tmp/u1-wrong-host-fingerprint.json"
  chmod 600 "$tmp/u1-wrong-host-fingerprint.json"
  if ROUNDHOUSE_CONFIG="$tmp/u1-wrong-host-fingerprint.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 accepted a route pin that mismatched dedicated known-hosts"
  fi
  if ROUNDHOUSE_IDENTITY="$tmp/identity-future.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "U1 accepted a cryptographically matching node certificate before valid_after"
  fi

  ROUNDHOUSE_CONFIG="$tmp/u1-worker.json" ROUNDHOUSE_IDENTITY="$tmp/identity-b.json" \
    "$cli" collect --target test-apt --section packages --output "$tmp/u1-posix.jsonl"
  [ "$(jq -r 'select(.kind == "privilege_broker") | .data.lifecycle_status' "$tmp/u1-posix.jsonl")" = needs_enrollment ] ||
    fail "U1 POSIX readiness did not report needs_enrollment"
  [ "$(jq -r 'select(.kind == "privilege_broker") |
    (.data.policy_proposal_digest != null and .data.observed_policy_digest == null)' "$tmp/u1-posix.jsonl")" = true ] ||
    fail "U1 conflated policy proposal and observed policy"
  [ "$(jq -r 'select(.kind == "privilege_broker") |
    [.data.originating_node_identity.node_id,.data.node_identity.node_id] | @tsv' "$tmp/u1-posix.jsonl")" = \
    "$(printf 'origin-a\ttarget-b')" ] || fail "U1 conflated originating and target node identities"
  "$cli" collect --target test-wsl --section host --output "$tmp/u1-wsl.jsonl"
  [ "$(jq -r 'select(.kind == "privilege_broker") | .data.lifecycle_status' "$tmp/u1-wsl.jsonl")" = unsupported_security_boundary ] ||
    fail "U1 WSL readiness widened the unsupported security boundary"

  constraint_record_a="apt-install|apt.install-package-version.v1|token-a|fixture-pkg|fixture-source|1.2.3-1|$(printf 'e%.0s' {1..64})|$(printf 'f%.0s' {1..64})"
  constraint_record_b="apt-install|apt.install-package-version.v1|token-b|fixture-pkg|fixture-source|1.2.3-1|$(printf 'e%.0s' {1..64})|$(printf 'f%.0s' {1..64})"
  printf '%s\n%s\n' "$constraint_record_a" "$constraint_record_b" >"$tmp/u1-constraint-group"
  constraint_group_digest=$(shasum -a 256 "$tmp/u1-constraint-group" | awk '{print $1}')
  awk -F '|' -v OFS='|' -v digest="$constraint_group_digest" '
    $2 == "apt.install-package-version.v1" { $4="enabled"; $6=digest } { print }
  ' "$policy_file" >"$tmp/u1-constrained-policy"
  constrained_policy_digest=$(shasum -a 256 "$tmp/u1-constrained-policy" | awk '{print $1}')
  printf 'constraints|1|generation=1|policy-sha256=%s\n%s\n%s\n' \
    "$constrained_policy_digest" "$constraint_record_a" "$constraint_record_b" >"$tmp/u1-policy.constraints"
  "$cli" inspect-privilege-constraints "$tmp/u1-constrained-policy" "$tmp/u1-policy.constraints" \
    >"$tmp/u1-constraints.json"
  jq -e '.generation == 1 and
    (.actions[] | select(.action_id == "apt.install-package-version.v1") | .policy_tokens) == ["token-a","token-b"]' \
    "$tmp/u1-constraints.json" >/dev/null || fail "U1 did not expose exact protected token membership"
  printf 'constraints|1|generation=1|policy-sha256=%s\n%s\n%s\n' \
    "$constrained_policy_digest" "$constraint_record_b" "$constraint_record_a" >"$tmp/u1-reordered.constraints"
  if "$cli" inspect-privilege-constraints "$tmp/u1-constrained-policy" "$tmp/u1-reordered.constraints" >/dev/null 2>&1; then
    fail "U1 accepted reordered constraint records"
  fi
  printf 'constraints|1|generation=1|policy-sha256=%s\n%s\n%s\n' \
    "$constrained_policy_digest" "$constraint_record_a" "$constraint_record_a" >"$tmp/u1-duplicate.constraints"
  if "$cli" inspect-privilege-constraints "$tmp/u1-constrained-policy" "$tmp/u1-duplicate.constraints" >/dev/null 2>&1; then
    fail "U1 accepted duplicate constraint records"
  fi
  constraint_record_same_token="apt-install|apt.install-package-version.v1|token-a|fixture-pkg-two|fixture-source|1.2.3-1|$(printf 'e%.0s' {1..64})|$(printf 'f%.0s' {1..64})"
  printf '%s\n%s\n' "$constraint_record_a" "$constraint_record_same_token" | LC_ALL=C sort \
    >"$tmp/u1-same-token-group"
  same_token_digest=$(shasum -a 256 "$tmp/u1-same-token-group" | awk '{print $1}')
  awk -F '|' -v OFS='|' -v digest="$same_token_digest" '
    $2 == "apt.install-package-version.v1" { $4="enabled"; $6=digest } { print }
  ' "$policy_file" >"$tmp/u1-same-token-policy"
  same_token_policy_digest=$(shasum -a 256 "$tmp/u1-same-token-policy" | awk '{print $1}')
  printf 'constraints|1|generation=1|policy-sha256=%s\n' "$same_token_policy_digest" \
    >"$tmp/u1-same-token.constraints"
  awk '{print}' "$tmp/u1-same-token-group" >>"$tmp/u1-same-token.constraints"
  if "$cli" inspect-privilege-constraints "$tmp/u1-same-token-policy" \
      "$tmp/u1-same-token.constraints" >/dev/null 2>&1; then
    fail "U1 accepted two different canonical records for one action token"
  fi
  if [ -n "$pwsh_command" ]; then
    U1_COLLECTOR="$script_dir/collect-windows.ps1" U1_POLICY="$tmp/u1-same-token-policy" \
      U1_CONSTRAINTS="$tmp/u1-same-token.constraints" "$pwsh_command" -NoLogo -NoProfile -Command '
      $tokens=$null; $errors=$null
      $ast=[Management.Automation.Language.Parser]::ParseFile($env:U1_COLLECTOR,[ref]$tokens,[ref]$errors)
      foreach($name in @("Get-TextSha256","Test-PrivilegeConstraints")) {
        $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $name},$true)
        Invoke-Expression $function.Extent.Text
      }
      $policyLines=[string[]]@(Get-Content -LiteralPath $env:U1_POLICY)
      $constraintLines=[string[]]@(Get-Content -LiteralPath $env:U1_CONSTRAINTS)
      if ($null -ne (Test-PrivilegeConstraints $policyLines $constraintLines ("0" * 64))) { exit 1 }
    ' ||
      fail "U1 PowerShell parser accepted two different canonical records for one action token"

    u1_readiness_digest=$(printf 'a%.0s' {1..64})
    {
      printf '%s\n' \
        'windows-broker-readiness|1' \
        'lifecycle|needs_native_canary' \
        'broker-version|1.0.0' \
        'broker-protocol|1' \
        "broker-sha256|$u1_readiness_digest" \
        'generation|1' \
        "generation-sha256|$u1_readiness_digest" \
        "policy-sha256|$u1_readiness_digest" \
        "constraints-sha256|$u1_readiness_digest" \
        "winget-context-sha256|$u1_readiness_digest" \
        'context-canary-sha256|-' \
        'clock-skew-bound-seconds|300' \
        'request-account-state|disabled' \
        'request-sid|S-1-5-21-1-2-3-2001' \
        'request-principal|RoundhouseRequest' \
        'system-task-ready|true' \
        'profile-task-ready|true' \
        'transport-ready|false' \
        'native-canary-ready|false' \
        'end-readiness|'
    } >"$tmp/u1-windows-readiness"
    U1_COLLECTOR="$script_dir/collect-windows.ps1" U1_READINESS="$tmp/u1-windows-readiness" \
      "$pwsh_command" -NoLogo -NoProfile -Command '
      $tokens=$null; $errors=$null
      $ast=[Management.Automation.Language.Parser]::ParseFile($env:U1_COLLECTOR,[ref]$tokens,[ref]$errors)
      foreach($name in @("Get-CanonicalAsciiLines","Read-WindowsBrokerReadiness")) {
        $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $name},$true)
        if ($null -eq $function) { exit 1 }
        Invoke-Expression $function.Extent.Text
      }
      function Test-WindowsPublicProjectionFile([string]$Path) { return $true }
      $readiness=Read-WindowsBrokerReadiness $env:U1_READINESS
      if ($null -eq $readiness -or [int]$readiness."broker-protocol" -ne 1) { exit 1 }
    ' || fail "U1 Windows readiness did not publish canonical broker protocol 1"
  fi

  target_valid_after=$(jq -r '.certificate_valid_after' "$tmp/identity-b.json")
  target_valid_before=$(jq -r '.certificate_valid_before' "$tmp/identity-b.json")
  jq --slurpfile worker "$tmp/u1-worker.json" \
    --arg broker "$(printf 'b%.0s' {1..64})" --arg policy "$(printf 'c%.0s' {1..64})" \
    --arg context "$(printf 'd%.0s' {1..64})" --arg node_fp "$fingerprint_a" \
    --arg target_fp "$target_fingerprint" --arg ca_fp "$fingerprint_b" --arg host_fp "$host_fingerprint" \
    --arg after "$target_valid_after" --arg before "$target_valid_before" \
    --arg constraints "$(printf 'e%.0s' {1..64})" '
    if .kind == "privilege_broker" then
      .status="present" | .data.lifecycle_status="ready" | .data.transport="posix-ssh" |
      .data.transport_ready=true | .data.node_identity_ready=true | .data.broker_ready=true |
      .data.action_context_ready=true | .data.adapter_mechanism_ready=true |
      .data.protected_artifacts_ready=true | .data.adapter_verifier_status="verified-fixture" |
      .data.platform_adapter="posix-sudo-v1" |
      .data.platform_boundary="linux" | .data.request_principal="roundhouse" |
      .data.execution_principals=["root"] | .data.session_requirement="no-console-session" |
      .data.broker_protocol.observed=1 | .data.broker_version="1.0.0" |
      .data.broker_digest={algorithm:"sha256",value:$broker} |
      .data.observed_policy_digest={algorithm:"sha256",value:$policy} |
      .data.observed_constraints_digest={algorithm:"sha256",value:$constraints} |
      .data.constraint_generation=1 |
      .data.context_canary_digest={algorithm:"sha256",value:$context} |
      .data.observed_action_contexts=[{action_id:"apt.update-metadata.v1",context_id:"posix-root-v1",
        constraint_kind:"none",constraint_digest:"-",constraint_generation:1,policy_tokens:[],
        manager_source_identity:"not-applicable"}] |
      .data.observed_preconditions=[{action_id:"apt.update-metadata.v1",policy_token:"-",
        digest:{algorithm:"sha256",value:("f" * 64)},
        evidence:{kind:"fixture",digest:{algorithm:"sha256",value:("e" * 64)}}}] |
      .data.node_identity={node_id:"target-b",fleet_domain:"fleet.example",node_key_fingerprint:$target_fp,
        fleet_ca_fingerprint:$ca_fp,ca_generation:1,certificate_serial:"2",
        certificate_valid_after:$after,certificate_valid_before:$before,
        certificate_principals:["roundhouse-posix","roundhouse-windows","target-b@fleet.example"],
        certificate_source_addresses:["192.0.2.0/24"]} |
      .data.originating_node_identity=$worker[0].worker.originating_node_identity |
      .data.pinned_host_key_fingerprint=$host_fp | .data.enrollment_epoch=1 |
      .data.request_ttl={minimum_seconds:0,maximum_seconds:3600}
    else . end
  ' "$tmp/u1-posix.jsonl" >"$tmp/u1-ready.jsonl"
  jq -n --arg expiry "$expires_at" '{domain:"updates",target:"test-apt",
    operations:[{type:"semantic-action",kind:"privileged_action",id:"apt.update-metadata.v1"}],
    privilege_request:{action_id:"apt.update-metadata.v1",policy_token:null,
      request_id:"request-0123456789abcdef0123456789abcdef",expires_at:$expiry}}
  ' >"$tmp/u1-privileged-draft.json"
  "$cli" seal-plan "$tmp/u1-privileged-draft.json" "$tmp/u1-ready.jsonl" "$tmp/u1-privileged-plan.json"
  [ "$(jq -r '.schema_version == 3 and .privilege.action.id == "apt.update-metadata.v1" and
    .privilege.request.originating_node_id == "origin-a" and
    (.operations[0] | has("argv") | not)' "$tmp/u1-privileged-plan.json")" = true ] ||
    fail "U1 did not seal the closed privileged plan contract"
  future_after=$(jq -nr 'now + 3600 | todateiso8601')
  future_before=$(jq -nr 'now + 7200 | todateiso8601')
  jq --arg after "$future_after" --arg before "$future_before" '
    if .kind == "privilege_broker" then
      .data.node_identity.certificate_valid_after=$after |
      .data.node_identity.certificate_valid_before=$before |
      .data.originating_node_identity.certificate_valid_after=$after |
      .data.originating_node_identity.certificate_valid_before=$before
    else . end
  ' "$tmp/u1-ready.jsonl" >"$tmp/u1-future-certificate-readiness.jsonl"
  if "$cli" seal-plan "$tmp/u1-privileged-draft.json" "$tmp/u1-future-certificate-readiness.jsonl" \
      "$tmp/u1-future-certificate-plan.json" >/dev/null 2>&1; then
    fail "U1 sealed readiness for a node certificate before valid_after"
  fi

  constraints_file_digest=$(shasum -a 256 "$tmp/u1-policy.constraints" | awk '{print $1}')
  jq --arg policy "$constrained_policy_digest" --arg constraints "$constraints_file_digest" \
    --arg group "$constraint_group_digest" '
    if .kind == "privilege_broker" then
      .data.observed_policy_digest.value=$policy |
      .data.observed_constraints_digest.value=$constraints |
      .data.observed_action_contexts=[{
        action_id:"apt.install-package-version.v1",context_id:"posix-root-v1",
        constraint_kind:"package-source-version-closure-set-sha256",constraint_digest:$group,
        constraint_generation:1,policy_tokens:["token-a","token-b"],manager_source_identity:$group
      }] |
      .data.observed_preconditions=[
        {action_id:"apt.install-package-version.v1",policy_token:"token-a",
          digest:{algorithm:"sha256",value:("f" * 64)},
          evidence:{kind:"fixture",digest:{algorithm:"sha256",value:("e" * 64)}}},
        {action_id:"apt.install-package-version.v1",policy_token:"token-b",
          digest:{algorithm:"sha256",value:("f" * 64)},
          evidence:{kind:"fixture",digest:{algorithm:"sha256",value:("e" * 64)}}}
      ]
    else . end
  ' "$tmp/u1-ready.jsonl" >"$tmp/u1-constrained-ready.jsonl"
  jq -n --arg expiry "$expires_at" '{domain:"updates",target:"test-apt",
    operations:[{type:"semantic-action",kind:"privileged_action",id:"apt.install-package-version.v1"}],
    privilege_request:{action_id:"apt.install-package-version.v1",policy_token:"token-a",
      request_id:"request-1123456789abcdef0123456789abcdef",expires_at:$expiry}}
  ' >"$tmp/u1-constrained-draft.json"
  "$cli" seal-plan "$tmp/u1-constrained-draft.json" "$tmp/u1-constrained-ready.jsonl" \
    "$tmp/u1-constrained-plan.json"
  [ "$(jq -r '.privilege.action.policy_token == "token-a" and
    .privilege.policy.constraint_generation == 1' "$tmp/u1-constrained-plan.json")" = true ] ||
    fail "U1 did not seal active protected constraint membership"
  jq '.privilege_request.policy_token="token-z"' "$tmp/u1-constrained-draft.json" \
    >"$tmp/u1-unknown-token-draft.json"
  if "$cli" seal-plan "$tmp/u1-unknown-token-draft.json" "$tmp/u1-constrained-ready.jsonl" \
      "$tmp/u1-unknown-token-plan.json" >/dev/null 2>&1; then
    fail "U1 sealed a token absent from protected constraints"
  fi
  jq 'if .kind == "privilege_broker" then .data.constraint_generation=2 |
    .data.observed_action_contexts[0].constraint_generation=2 else . end' \
    "$tmp/u1-constrained-ready.jsonl" >"$tmp/u1-generation-mismatch.jsonl"
  if "$cli" seal-plan "$tmp/u1-constrained-draft.json" "$tmp/u1-generation-mismatch.jsonl" \
      "$tmp/u1-generation-mismatch-plan.json" >/dev/null 2>&1; then
    fail "U1 sealed generation-mismatched protected constraints"
  fi
  awk -F '|' -v OFS='|' '
    $2 == "apt.install-package-version.v1" { $6="0000000000000000000000000000000000000000000000000000000000000000" }
    { print }
  ' "$tmp/u1-constrained-policy" >"$tmp/u1-constraint-digest-mismatch-policy"
  if "$cli" inspect-privilege-constraints "$tmp/u1-constraint-digest-mismatch-policy" \
      "$tmp/u1-policy.constraints" >/dev/null 2>&1; then
    fail "U1 accepted digest-mismatched protected constraint records"
  fi
  jq '.privilege_request.constraints={dependency_mode:"caller-selected"}' "$tmp/u1-constrained-draft.json" \
    >"$tmp/u1-request-constraints.json"
  if "$cli" seal-plan "$tmp/u1-request-constraints.json" "$tmp/u1-constrained-ready.jsonl" \
      "$tmp/u1-request-constraints-plan.json" >/dev/null 2>&1; then
    fail "U1 accepted request-supplied constraint or dependency controls"
  fi
  jq '.operations[0].argv=["sudo"]' "$tmp/u1-privileged-draft.json" >"$tmp/u1-command-draft.json"
  if "$cli" seal-plan "$tmp/u1-command-draft.json" "$tmp/u1-ready.jsonl" "$tmp/u1-command-plan.json" >/dev/null 2>&1; then
    fail "U1 accepted argv in a privileged request"
  fi
  jq --arg snapshot "u1-fresh" --arg observed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.snapshot_id=$snapshot | .observed_at=$observed' "$tmp/u1-ready.jsonl" >"$tmp/u1-fresh.jsonl"
  "$cli" verify-preconditions "$tmp/u1-privileged-plan.json" "$tmp/u1-fresh.jsonl" >/dev/null
  if "$cli" apply-plan "$tmp/u1-privileged-plan.json" \
    "$(jq -r '.plan_id' "$tmp/u1-privileged-plan.json")" "$tmp/u1-should-not-run.jsonl" >/dev/null 2>&1; then
    fail "U1 exposed native privileged execution"
  fi

  if [ -n "$pwsh_command" ]; then
    "$cli" worker-config test-windows inventory "$tmp/u1-windows-worker.json"
    mkdir -p "$tmp/programdata/Roundhouse/active"
    printf '%s\n' '# user-writable broker fixture; never executable' >"$tmp/programdata/Roundhouse/active/broker.ps1"
    printf '%s\n' '1.0.0' >"$tmp/programdata/Roundhouse/active/broker.version"
    cp "$policy_file" "$tmp/programdata/Roundhouse/active/policy.actions"
    windows_policy_digest=$(shasum -a 256 "$tmp/programdata/Roundhouse/active/policy.actions" | awk '{print $1}')
    printf 'constraints|1|generation=1|policy-sha256=%s\n' "$windows_policy_digest" \
      >"$tmp/programdata/Roundhouse/active/policy.constraints"
    printf '%s\n' 'protected-winget-context' >"$tmp/programdata/Roundhouse/active/winget.context"
    printf '%s\n' 'unattested-context' >"$tmp/programdata/Roundhouse/active/context.canary"
    windows_broker_digest=$(shasum -a 256 "$tmp/programdata/Roundhouse/active/broker.ps1" | awk '{print $1}')
    windows_winget_context_digest=$(shasum -a 256 "$tmp/programdata/Roundhouse/active/winget.context" | awk '{print $1}')
    windows_context_digest=$(shasum -a 256 "$tmp/programdata/Roundhouse/active/context.canary" | awk '{print $1}')
    jq --arg broker "$windows_broker_digest" --arg policy "$windows_policy_digest" \
      --arg winget_context "$windows_winget_context_digest" --arg context "$windows_context_digest" \
      '.enrollment_receipts["test-windows"]={
        enrollment_epoch:1,broker_digest:$broker,policy_digest:$policy,
        winget_context_digest:$winget_context,context_canary_digest:$context
      }' "$tmp/identity-b.json" >"$tmp/identity-b-with-receipt.json"
    chmod 600 "$tmp/identity-b-with-receipt.json"
    HOME="$tmp/home" TZ=UTC ProgramData="$tmp/programdata" \
      ROUNDHOUSE_IDENTITY="$tmp/identity-b-with-receipt.json" \
      "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
      -ConfigPath "$tmp/u1-windows-worker.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
      -Sections packages >"$tmp/u1-windows.jsonl"
    "$cli" validate "$tmp/u1-windows.jsonl"
    [ "$(jq -r 'select(.kind == "privilege_broker") |
      [.data.platform_adapter,.data.lifecycle_status] | @tsv' "$tmp/u1-windows.jsonl")" = "$(printf 'windows-scheduled-task-v1\tneeds_enrollment')" ] ||
      fail "U1 Windows readiness shape diverged"
    [ "$(jq -r 'select(.kind == "privilege_broker") |
      .data.node_identity_ready == true and .data.adapter_mechanism_ready == false and
      .data.broker_ready == false and .data.action_context_ready == false' "$tmp/u1-windows.jsonl")" = true ] ||
      fail "U1 treated matching user-writable artifacts and receipt as a verified platform mechanism"
    jq --arg hosts "$tmp/wrong-hosts" '.known_hosts_path=$hosts' \
      "$tmp/identity-b-with-receipt.json" >"$tmp/identity-b-wrong-host.json"
    chmod 600 "$tmp/identity-b-wrong-host.json"
    HOME="$tmp/home" TZ=UTC ProgramData="$tmp/programdata" \
      ROUNDHOUSE_IDENTITY="$tmp/identity-b-wrong-host.json" \
      "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
      -ConfigPath "$tmp/u1-windows-worker.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
      -Sections packages >"$tmp/u1-windows-wrong-host.jsonl"
    jq --arg fingerprint "$target_fingerprint" \
      '.machines["test-windows"].privilege_broker.automation_transport.pinned_host_key_fingerprint=$fingerprint' \
      "$tmp/u1-windows-worker.json" >"$tmp/u1-windows-wrong-pin-worker.json"
    HOME="$tmp/home" TZ=UTC ProgramData="$tmp/programdata" \
      ROUNDHOUSE_IDENTITY="$tmp/identity-b-with-receipt.json" \
      "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
      -ConfigPath "$tmp/u1-windows-wrong-pin-worker.json" -HostId test-windows \
      -ControllerConfigDigest "$config_hash" -Sections packages >"$tmp/u1-windows-wrong-pin.jsonl"
    for mismatch_snapshot in "$tmp/u1-windows-wrong-host.jsonl" "$tmp/u1-windows-wrong-pin.jsonl"; do
      [ "$(jq -r 'select(.kind == "privilege_broker") |
        .data.node_identity_ready == false and .data.transport_ready == false' "$mismatch_snapshot")" = true ] ||
        fail "U1 reported transport ready for mismatched dedicated known-hosts"
    done
  fi
}

[ "${ROUNDHOUSE_TEST_SCOPE:-}" != u1-contracts ] || {
  test_u1_contracts
  printf 'PASS: U1 contracts\n'
  exit 0
}
