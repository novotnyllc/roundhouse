# roundhouse self-check — U4 — sealed privileged plans over both broker
# transports.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

test_u4_contracts() {
  # U4 builds on the signed U1 fixture but adds only the protected fields that
  # a live U2 collector publishes. It never enrolls or invokes the real sudo
  # broker: the native-elevation path remains an explicit canary.
  test_u1_contracts
  u4_expiry=$(jq -nr 'now + 600 | todateiso8601')
  u4_uid=$(id -u)
  u4_snapshot_id=$(jq -r 'select(.kind == "snapshot") | .snapshot_id' "$tmp/u1-ready.jsonl")
  u4_observed_at=$(jq -r 'select(.kind == "snapshot") | .observed_at' "$tmp/u1-ready.jsonl")
  jq --argjson uid "$u4_uid" '
    if .kind == "privilege_broker" then
      .data.protected_identity={host_id:"test-apt",uid:$uid,request_principal:"roundhouse",
        fleet_domain:"fleet.example",fleet_ca_fingerprint:.data.originating_node_identity.fleet_ca_fingerprint,
        ca_generation:1,pinned_host_key_fingerprint:.data.pinned_host_key_fingerprint,
        endpoint_principals:["roundhouse-posix","roundhouse-windows"]} |
      .data.observed_preconditions=[{action_id:"apt.update-metadata.v1",policy_token:"-",
        digest:{algorithm:"sha256",value:("f" * 64)},
        evidence:{kind:"fixture",digest:{algorithm:"sha256",value:("e" * 64)}}}]
    else . end
  ' "$tmp/u1-ready.jsonl" >"$tmp/u4-ready-base.jsonl"
  jq -cn --arg schema roundhouse.inventory --argjson schema_version 1 \
    --arg snapshot_id "$u4_snapshot_id" --arg host_id test-apt --arg observed_at "$u4_observed_at" \
    --arg hostname "$(hostname)" --arg user "$(id -un)" '
    {schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"host",id:"local",observed_at:$observed_at,status:"present",confidence:"high",
      data:{hostname:$hostname,user:$user},evidence:[],errors:[]}
  ' >"$tmp/u4-host.jsonl"
  jq -sc 'sort_by(.host_id,.kind,.id)[]' "$tmp/u4-ready-base.jsonl" "$tmp/u4-host.jsonl" >"$tmp/u4-ready.jsonl"
  "$cli" validate "$tmp/u4-ready.jsonl"
  jq -n --arg expiry "$u4_expiry" '{domain:"updates",target:"test-apt",operations:[
    {type:"package-metadata-refresh",kind:"package",id:"apt:example",argv:["brew","update"]},
    {type:"semantic-action",kind:"privileged_action",id:"apt.update-metadata.v1",
      privilege_request:{action_id:"apt.update-metadata.v1",policy_token:null,
        request_id:"request-2123456789abcdef0123456789abcdef",expires_at:$expiry}}
  ]}' >"$tmp/u4-draft.json"
  "$cli" seal-plan "$tmp/u4-draft.json" "$tmp/u4-ready.jsonl" "$tmp/u4-plan.json"
  [ "$(jq -r --argjson uid "$u4_uid" '
    .schema_version == 4 and
    (.operations[1] | (has("argv") | not) and (has("privilege_request") | not) and
      .privilege.request.target_uid == ($uid | tostring) and
      .privilege.precondition.digest.value == ("f" * 64))
  ' "$tmp/u4-plan.json")" = true ] || fail "U4 did not seal only derived POSIX identity and protected precondition evidence"
  if grep -Eq 'target_(uid|sid)' "$tmp/u4-draft.json"; then
    fail "U4 fixture unexpectedly retained a caller identity binding"
  fi
  jq --arg snapshot_id u4-fresh --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.snapshot_id=$snapshot_id | .observed_at=$observed_at' "$tmp/u4-ready.jsonl" >"$tmp/u4-fresh.jsonl"
  "$cli" verify-preconditions "$tmp/u4-plan.json" "$tmp/u4-fresh.jsonl" >/dev/null

  u4_schema3_posix_expiry=$(jq -nr 'now + 600 | todateiso8601')
  jq -n --arg expiry "$u4_schema3_posix_expiry" '{domain:"updates",target:"test-apt",operations:[
    {type:"semantic-action",kind:"privileged_action",id:"apt.update-metadata.v1"}
  ],privilege_request:{action_id:"apt.update-metadata.v1",policy_token:null,
    request_id:"request-3123456789abcdef0123456789abcdef",expires_at:$expiry}}' \
    >"$tmp/u4-schema3-posix-draft.json"
  "$cli" seal-plan "$tmp/u4-schema3-posix-draft.json" "$tmp/u4-ready.jsonl" \
    "$tmp/u4-schema3-posix-plan.json"
  [ "$(jq -r '.precondition_digest.value == ("f" * 64) and
    .privilege.precondition.digest.value == ("f" * 64)' "$tmp/u4-schema3-posix-plan.json")" = true ] ||
    fail "U4 schema-3 POSIX sealing did not retain the action-specific precondition"
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    u4_schema3_posix_expected=$(printf 'f%.0s' {1..64})
    invoke_fixed_posix_broker() {
      u4_schema3_posix_envelope=$1
      u4_schema3_posix_output=$2
      if [ "$(awk -F '|' '$1 == "action-id" { print $2; exit }' "$u4_schema3_posix_envelope")" = \
          apt.update-metadata.v1 ]; then
        awk -F '|' '$1 == "precondition-sha256" { print $2; exit }' \
          "$u4_schema3_posix_envelope" >"$tmp/u4-schema3-posix-envelope-precondition"
      fi
      printf '%s\n' transport-interrupted >"$u4_schema3_posix_output"
      return 70
    }
    normalize_privileged_plan_for_broker_execution "$tmp/u4-schema3-posix-plan.json" \
      "$tmp/u4-fresh.jsonl" "$tmp/u4-schema3-posix-executable.json"
    mkdir "$tmp/u4-schema3-posix-work"
    set +e
    execute_sealed_posix_broker_operation "$tmp/u4-schema3-posix-executable.json" 0 \
      "$tmp/u4-schema3-posix-work" "$tmp/u4-schema3-posix-outcome"
    u4_schema3_posix_execute_rc=$?
    set -e
    [ "$u4_schema3_posix_execute_rc" -eq 70 ] &&
      [ "$(cat "$tmp/u4-schema3-posix-envelope-precondition")" = "$u4_schema3_posix_expected" ] ||
      fail "U4 schema-3 POSIX execution did not send the sealed action precondition"
  )

  jq '.operations[1].privilege_request.caller_uid="999"' "$tmp/u4-draft.json" >"$tmp/u4-caller-uid.json"
  if "$cli" seal-plan "$tmp/u4-caller-uid.json" "$tmp/u4-ready.jsonl" "$tmp/u4-caller-uid-plan.json" >/dev/null 2>&1; then
    fail "U4 accepted caller-supplied UID"
  fi
  jq '.operations[1].privilege_request.caller_sid="S-1-5-18"' "$tmp/u4-draft.json" >"$tmp/u4-caller-sid.json"
  if "$cli" seal-plan "$tmp/u4-caller-sid.json" "$tmp/u4-ready.jsonl" "$tmp/u4-caller-sid-plan.json" >/dev/null 2>&1; then
    fail "U4 accepted caller-supplied SID"
  fi
  jq '.operations[1].argv=["sudo","apt-get","update"]' "$tmp/u4-draft.json" >"$tmp/u4-command.json"
  if "$cli" seal-plan "$tmp/u4-command.json" "$tmp/u4-ready.jsonl" "$tmp/u4-command-plan.json" >/dev/null 2>&1; then
    fail "U4 accepted a command-bearing privileged request"
  fi
  jq '.operations[0].argv=["/usr/bin/apt-get","update"]' "$tmp/u4-draft.json" >"$tmp/u4-direct-apt.json"
  if "$cli" seal-plan "$tmp/u4-direct-apt.json" "$tmp/u4-ready.jsonl" "$tmp/u4-direct-apt-plan.json" >/dev/null 2>&1; then
    fail "U4 accepted a direct APT ordinary operation"
  fi
  jq '.operations[1].id=.operations[0].id' "$tmp/u4-draft.json" >"$tmp/u4-duplicate-operation.json"
  if "$cli" seal-plan "$tmp/u4-duplicate-operation.json" "$tmp/u4-ready.jsonl" "$tmp/u4-duplicate-operation-plan.json" >/dev/null 2>&1; then
    fail "U4 accepted duplicate operation IDs"
  fi
  jq '.operations[1].id="apt.install-package-version.v1" | .operations[1].privilege_request.action_id="apt.install-package-version.v1"' \
    "$tmp/u4-draft.json" >"$tmp/u4-unobserved-action.json"
  if "$cli" seal-plan "$tmp/u4-unobserved-action.json" "$tmp/u4-ready.jsonl" "$tmp/u4-unobserved-action-plan.json" >/dev/null 2>&1; then
    fail "U4 sealed an action without protected observed precondition evidence"
  fi

  jq 'if .kind == "privilege_broker" then .data.observed_policy_digest.value=("0" * 64) else . end' \
    "$tmp/u4-fresh.jsonl" >"$tmp/u4-policy-drift.jsonl"
  if "$cli" verify-preconditions "$tmp/u4-plan.json" "$tmp/u4-policy-drift.jsonl" >/dev/null 2>&1; then
    fail "U4 accepted broker policy drift after sealing"
  fi
  jq 'if .kind == "privilege_broker" then .data.broker_protocol.observed=0 else . end' \
    "$tmp/u4-ready.jsonl" >"$tmp/u4-previous-ready.jsonl"
  "$cli" seal-plan "$tmp/u4-draft.json" "$tmp/u4-previous-ready.jsonl" "$tmp/u4-previous-plan.json"
  jq --arg snapshot_id u4-previous-fresh --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.snapshot_id=$snapshot_id | .observed_at=$observed_at' "$tmp/u4-previous-ready.jsonl" >"$tmp/u4-previous-fresh.jsonl"
  set +e
  "$cli" verify-preconditions "$tmp/u4-previous-plan.json" "$tmp/u4-previous-fresh.jsonl" \
    >"$tmp/u4-previous-verify.json" 2>"$tmp/u4-previous-verify.stderr"
  u4_previous_rc=$?
  set -e
  [ "$u4_previous_rc" -eq 69 ] && grep -Fqx 'roundhouse: needs_broker_upgrade' "$tmp/u4-previous-verify.stderr" ||
    fail "U4 did not reject a previous-only mutation protocol as needs_broker_upgrade"

  # A broker result query must be freshly authenticated even when it is bound
  # to a mutation whose original admission timestamp is now stale. This is a
  # client-only fixture: it replaces the fixed broker function only inside a
  # sourced test subshell, never invokes sudo, and verifies the SSH signature
  # before returning a canonical retained terminal journal.
  u4_query_now=$(/bin/date -u +%s)
  u4_original_created=$((u4_query_now - 301))
  u4_original_expires=$((u4_query_now + 600))
  jq --argjson created "$u4_original_created" --argjson expires "$u4_original_expires" '
    .created_at = ($created | strftime("%Y-%m-%dT%H:%M:%SZ")) |
    .operations[1].privilege.request.created_at = ($created | strftime("%Y-%m-%dT%H:%M:%SZ")) |
    .operations[1].privilege.request.expires_at = ($expires | strftime("%Y-%m-%dT%H:%M:%SZ")) |
    .operations[1].privilege.enrollment.certificate_valid_after = (($created - 60) | strftime("%Y-%m-%dT%H:%M:%SZ")) |
    del(.plan_id,.plan_digest)
  ' "$tmp/u4-plan.json" >"$tmp/u4-recovery-base.json"
  u4_recovery_digest=$(jq -cS . "$tmp/u4-recovery-base.json" | shasum -a 256 | awk '{print $1}')
  u4_recovery_plan_id="plan-${u4_recovery_digest:0:16}"
  jq -S --arg plan_id "$u4_recovery_plan_id" --arg plan_digest "$u4_recovery_digest" \
    '. + {plan_id:$plan_id,plan_digest:{algorithm:"sha256",value:$plan_digest}}' \
    "$tmp/u4-recovery-base.json" >"$tmp/u4-recovery-plan.json"
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    u4_recovery_request_id=$(jq -r '.operations[1].privilege.request.id' "$tmp/u4-recovery-plan.json")
    u4_recovery_target=$(jq -r '.target' "$tmp/u4-recovery-plan.json")
    u4_recovery_uid=$(jq -r '.operations[1].privilege.request.target_uid' "$tmp/u4-recovery-plan.json")
    u4_recovery_principal=$(jq -r '.operations[1].privilege.request.principal' "$tmp/u4-recovery-plan.json")
    u4_recovery_broker_version=$(jq -r '.operations[1].privilege.broker.version' "$tmp/u4-recovery-plan.json")
    u4_recovery_broker_digest=$(jq -r '.operations[1].privilege.broker.digest.value' "$tmp/u4-recovery-plan.json")
    u4_recovery_policy_digest=$(jq -r '.operations[1].privilege.policy.digest.value' "$tmp/u4-recovery-plan.json")
    u4_recovery_constraints_digest=$(jq -r '.operations[1].privilege.policy.constraints_digest.value' "$tmp/u4-recovery-plan.json")
    u4_recovery_precondition_digest=$(jq -r '.operations[1].privilege.precondition.digest.value' "$tmp/u4-recovery-plan.json")
    u4_recovery_context_digest=$(jq -r '.operations[1].privilege.context.canary_digest.value' "$tmp/u4-recovery-plan.json")
    u4_recovery_host_fingerprint=$(jq -r '.operations[1].privilege.enrollment.pinned_host_key_fingerprint' "$tmp/u4-recovery-plan.json")
    u4_recovery_node_id=$(jq -r '.operations[1].privilege.request.originating_node_id' "$tmp/u4-recovery-plan.json")
    u4_recovery_domain=$(jq -r '.operations[1].privilege.enrollment.fleet_domain' "$tmp/u4-recovery-plan.json")
    u4_recovery_ca_fingerprint=$(jq -r '.operations[1].privilege.enrollment.fleet_ca_fingerprint' "$tmp/u4-recovery-plan.json")
    u4_recovery_ca_generation=$(jq -r '.operations[1].privilege.enrollment.ca_generation' "$tmp/u4-recovery-plan.json")
    u4_recovery_node_fingerprint=$(jq -r '.operations[1].privilege.request.node_key_fingerprint' "$tmp/u4-recovery-plan.json")
    u4_recovery_certificate_serial=$(jq -r '.operations[1].privilege.request.certificate_serial' "$tmp/u4-recovery-plan.json")
    u4_recovery_certificate_after=$(jq -r '.operations[1].privilege.enrollment.certificate_valid_after | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$tmp/u4-recovery-plan.json")
    u4_recovery_certificate_before=$(jq -r '.operations[1].privilege.enrollment.certificate_valid_before | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$tmp/u4-recovery-plan.json")
    u4_recovery_placeholder=$(printf 'a%.0s' {1..64})
    u4_query_calls=$tmp/u4-query-calls
    : >"$u4_query_calls"
    u4_expected_journal_value() {
      awk -F '|' -v key="$1" '$1 == key { print $2; exit }' \
        "$tmp/u4-recovery-work/journal-expectations-1"
    }
    u4_write_terminal_journal() {
      u4_journal_output=$1
      {
        printf '%s\n' 'journal|2' 'sequence|1' 'state|completed' 'reason|post_state_verified' \
          'effect-phase|verified' "retain-until|$((u4_original_expires + 300))"
        printf '%s\n' "request-id|$u4_recovery_request_id" "plan-id|$u4_recovery_plan_id" \
          'action-id|apt.update-metadata.v1' 'broker-protocol|1' \
          "target-host-id|$u4_recovery_target" "target-uid|$u4_recovery_uid" \
          "broker-version|$u4_recovery_broker_version" "broker-sha256|$u4_recovery_broker_digest" \
          "policy-sha256|$u4_recovery_policy_digest" "constraints-sha256|$u4_recovery_constraints_digest" \
          "precondition-sha256|$u4_recovery_precondition_digest" "created-at|$u4_original_created" \
          "expires-at|$u4_original_expires" 'transport|posix-ssh' \
          "request-principal|$u4_recovery_principal" 'required-context|posix-root-v1' \
          'observed-execution-principal|root' 'console-session-state|none' 'platform-boundary|linux' \
          'enrollment-epoch|1' "context-canary-sha256|$u4_recovery_context_digest" \
          "pinned-host-key-fingerprint|$u4_recovery_host_fingerprint" \
          "originating-node-id|$u4_recovery_node_id" "fleet-domain|$u4_recovery_domain" \
          "fleet-ca-fingerprint|$u4_recovery_ca_fingerprint" "ca-generation|$u4_recovery_ca_generation" \
          "node-key-fingerprint|$u4_recovery_node_fingerprint" \
          "certificate-serial|$u4_recovery_certificate_serial" \
          "certificate-valid-after|$u4_recovery_certificate_after" \
          "certificate-valid-before|$u4_recovery_certificate_before" \
          "source-addresses-sha256|$(u4_expected_journal_value source-addresses-sha256)" \
          'manager-source-identity|not-applicable' \
          "request-sha256|$(u4_expected_journal_value request-sha256)" \
          "certificate-sha256|$(u4_expected_journal_value certificate-sha256)" \
          "signature-sha256|$(u4_expected_journal_value signature-sha256)" \
          "action-evidence-sha256|$u4_recovery_placeholder" \
          "launch-record-sha256|$u4_recovery_placeholder" 'native-pid|123' 'native-pgid|123' \
          "native-process-start|$u4_recovery_placeholder" "native-boot|$u4_recovery_placeholder" 'native-exit|0' \
          "metadata-sha256|$u4_recovery_placeholder" "pre-state-sha256|$u4_recovery_placeholder" \
          "post-state-sha256|$u4_recovery_placeholder" 'artifact-sha256|-' 'closure-sha256|-' \
          'closure-members-sha256|-' 'end-journal|'
      } >"$u4_journal_output"
    }
    invoke_fixed_posix_broker() {
      u4_envelope=$1
      u4_broker_output=$2
      u4_envelope_action=$(awk -F '|' '$1 == "action-id" { print $2; exit }' "$u4_envelope")
      case $u4_envelope_action in
        apt.update-metadata.v1)
          u4_original_envelope_created=$(awk -F '|' '$1 == "created-at" { print $2; exit }' "$u4_envelope")
          [ $(( $(/bin/date -u +%s) - u4_original_envelope_created )) -gt 300 ] || return 70
          printf '%s\n' 'transport-interrupted' >"$u4_broker_output"
          return 70
          ;;
        broker.query-result.v1)
          u4_query_created=$(awk -F '|' '$1 == "created-at" { print $2; exit }' "$u4_envelope")
          u4_query_expires=$(awk -F '|' '$1 == "expires-at" { print $2; exit }' "$u4_envelope")
          u4_query_checked_at=$(/bin/date -u +%s)
          [ "$u4_query_created" -ge $((u4_query_checked_at - 5)) ] &&
            [ "$u4_query_expires" -gt "$u4_query_checked_at" ] &&
            [ $((u4_query_expires - u4_query_created)) -le 300 ] || return 70
          awk -F '|' -v request="$u4_recovery_request_id" -v plan="$u4_recovery_plan_id" \
            -v host="$u4_recovery_target" -v uid="$u4_recovery_uid" -v principal="$u4_recovery_principal" '
            $1 == "request-id" { seen[$1]++; ok[$1]=($2 == request) }
            $1 == "plan-id" { seen[$1]++; ok[$1]=($2 == plan) }
            $1 == "target-host-id" { seen[$1]++; ok[$1]=($2 == host) }
            $1 == "target-uid" { seen[$1]++; ok[$1]=($2 == uid) }
            $1 == "request-principal" { seen[$1]++; ok[$1]=($2 == principal) }
            END { for (key in ok) if (seen[key] != 1 || !ok[key]) exit 1
              exit !(seen["request-id"] && seen["plan-id"] && seen["target-host-id"] && seen["target-uid"] && seen["request-principal"]) }
          ' "$u4_envelope" || return 70
          awk '/^certificate\|/{exit} {print}' "$u4_envelope" >"$tmp/u4-recovery-query-request"
          awk '/^signature-begin$/{inside=1; next} /^end-envelope$/{exit} inside {print}' \
            "$u4_envelope" >"$tmp/u4-recovery-query-signature"
          awk -v identity="$u4_recovery_node_id@$u4_recovery_domain" \
            'NR == 1 { print identity " cert-authority " $1 " " $2 }' "$tmp/fleet-ca.pub" \
            >"$tmp/u4-recovery-allowed-signers"
          /usr/bin/ssh-keygen -Y verify -f "$tmp/u4-recovery-allowed-signers" \
            -I "$u4_recovery_node_id@$u4_recovery_domain" -n roundhouse-request \
            -s "$tmp/u4-recovery-query-signature" <"$tmp/u4-recovery-query-request" >/dev/null || return 70
          printf '%s\n' query >>"$u4_query_calls"
          u4_write_terminal_journal "$u4_broker_output"
          ;;
        *) return 70 ;;
      esac
    }
    mkdir "$tmp/u4-recovery-work"
    execute_sealed_posix_broker_operation "$tmp/u4-recovery-plan.json" 1 "$tmp/u4-recovery-work" \
      "$tmp/u4-recovery-outcome"
    IFS='|' read -r u4_recovered_state u4_recovered_reason u4_recovered_kind \
      u4_recovered_digest u4_recovered_projection <"$tmp/u4-recovery-outcome"
    u4_recovered_expected_digest=$(sha256_file "$tmp/u4-recovery-work/broker-query-1")
    [ "$(wc -l <"$u4_query_calls" | tr -d ' ')" -eq 1 ] && [ "$u4_recovered_state" = completed ] &&
      [ "$u4_recovered_reason" = post_state_verified ] &&
      [ "$u4_recovered_kind" = posix-journal-sha256 ] &&
      [ "$u4_recovered_digest" = "$u4_recovered_expected_digest" ] &&
      [ "$u4_recovered_projection" = "$u4_recovered_expected_digest" ] ||
      fail "U4 did not recover a retained terminal journal with a fresh signed query"
    for u4_journal_line in $(seq 2 54); do
      awk -F '|' -v line="$u4_journal_line" 'NR == line { $0=$1 "|" } { print }' \
        "$tmp/u4-recovery-work/broker-query-1" >"$tmp/u4-mutated-journal"
      if posix_broker_terminal_result "$tmp/u4-mutated-journal" "$u4_recovery_request_id" \
          "$u4_recovery_plan_id" apt.update-metadata.v1 false 1 \
          "$tmp/u4-recovery-work/journal-expectations-1" >/dev/null 2>&1; then
        fail "U4 accepted a terminal journal with field $u4_journal_line removed"
      fi
    done
    sed '$s/|$/|unexpected/' "$tmp/u4-recovery-work/broker-query-1" >"$tmp/u4-mutated-journal"
    if posix_broker_terminal_result "$tmp/u4-mutated-journal" "$u4_recovery_request_id" \
        "$u4_recovery_plan_id" apt.update-metadata.v1 false 1 \
        "$tmp/u4-recovery-work/journal-expectations-1" >/dev/null 2>&1; then
      fail "U4 accepted a terminal journal with a non-canonical end marker"
    fi
  )

  # Result queries authenticate with the caller's current overlay certificate,
  # while terminal matching stays bound to the original mutation journal.
  mkdir "$tmp/identity-a-renewed"
  cp "$tmp/identity-a/node-key" "$tmp/identity-a/node-key.pub" \
    "$tmp/identity-a/known-hosts" "$tmp/identity-a-renewed/"
  "$ssh_keygen" -q -s "$tmp/fleet-ca" -I 'origin-a@fleet.example' -z 101 \
    -n 'origin-a@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    -O source-address=192.0.2.0/24 -O no-agent-forwarding -O no-port-forwarding -O no-pty \
    -O no-user-rc -O no-X11-forwarding "$tmp/identity-a-renewed/node-key.pub"
  chmod 600 "$tmp/identity-a-renewed/node-key" "$tmp/identity-a-renewed/node-key-cert.pub" \
    "$tmp/identity-a-renewed/known-hosts"
  make_identity_fixture "$tmp/identity-a-renewed" origin-a 101 "$tmp/identity-a-renewed.json"
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    u4_assert_current_query_identity() {
      u4_query_identity_file=$1
      u4_query_expected_node=$2
      u4_query_expected_serial=$3
      u4_query_output=$4
      ROUNDHOUSE_IDENTITY="$u4_query_identity_file" \
        make_posix_broker_envelope "$tmp/u4-recovery-plan.json" 1 broker.query-result.v1 \
          "$u4_query_output"
      u4_query_expected_domain=$(jq -r '.fleet_domain' "$u4_query_identity_file")
      u4_query_expected_fingerprint=$(jq -r '.node_key_fingerprint' "$u4_query_identity_file")
      [ "$(awk -F '|' '$1 == "node-id" { print $2; exit }' "$u4_query_output")" = \
          "$u4_query_expected_node" ] &&
        [ "$(awk -F '|' '$1 == "certificate-serial" { print $2; exit }' "$u4_query_output")" = \
          "$u4_query_expected_serial" ] &&
        [ "$(awk -F '|' '$1 == "node-key-fingerprint" { print $2; exit }' "$u4_query_output")" = \
          "$u4_query_expected_fingerprint" ] &&
        [ "$(awk -F '|' '$1 == "action-id" { print $2; exit }' "$u4_query_output")" = \
          broker.query-result.v1 ] ||
        fail "U4 result query did not use the current $u4_query_expected_node overlay identity"
      awk '/^certificate\|/{exit} {print}' "$u4_query_output" >"$tmp/u4-current-query-request"
      awk '/^signature-begin$/{inside=1; next} /^end-envelope$/{exit} inside {print}' \
        "$u4_query_output" >"$tmp/u4-current-query-signature"
      awk -v identity="$u4_query_expected_node@$u4_query_expected_domain" \
        'NR == 1 { print identity " cert-authority " $1 " " $2 }' "$tmp/fleet-ca.pub" \
        >"$tmp/u4-current-query-allowed-signers"
      /usr/bin/ssh-keygen -Y verify -f "$tmp/u4-current-query-allowed-signers" \
        -I "$u4_query_expected_node@$u4_query_expected_domain" -n roundhouse-request \
        -s "$tmp/u4-current-query-signature" <"$tmp/u4-current-query-request" >/dev/null ||
        fail "U4 result query signature did not verify as the current overlay identity"
    }
    u4_assert_current_query_identity "$tmp/identity-b.json" target-b 2 \
      "$tmp/u4-peer-query-envelope"
    [ "$(awk -F '|' '$1 == "originating-node-id" { print $2; exit }' \
        "$tmp/u4-recovery-work/journal-expectations-1")" = origin-a ] ||
      fail "U4 peer result query replaced the original mutation journal identity"
    u4_assert_current_query_identity "$tmp/identity-a-renewed.json" origin-a 101 \
      "$tmp/u4-renewed-query-envelope"
    [ "$(awk -F '|' '$1 == "certificate-serial" { print $2; exit }' \
        "$tmp/u4-recovery-work/journal-expectations-1")" = 1 ] ||
      fail "U4 renewed result query replaced the original mutation certificate serial"
  )

  # The same descriptor drives all four APT actions. Tokenless actions bind
  # `-`; protected install/upgrade actions bind one exact enrolled token and
  # never admit source, dependency, or argv controls from the caller.
  u4_action_number=0
  for u4_action_spec in \
    'apt.autoremove.v1|none|none' \
    'apt.install-package-version.v1|package-source-version-closure-set-sha256|protected' \
    'apt.update-metadata.v1|none|none' \
    'apt.upgrade-package.v1|package-source-channel-set-sha256|protected'; do
    IFS='|' read -r u4_action u4_constraint_kind u4_token_kind <<EOF
$u4_action_spec
EOF
    u4_action_number=$((u4_action_number + 1))
    u4_request_id=$(printf 'request-%032x' "$u4_action_number")
    if [ "$u4_token_kind" = protected ]; then
      u4_policy_token="token-$u4_action_number"
      u4_constraint_digest=$(printf 'a%.0s' {1..64})
      u4_manager_identity=$u4_constraint_digest
      u4_policy_tokens=$(jq -cn --arg token "$u4_policy_token" '[$token]')
    else
      u4_policy_token=null
      u4_constraint_digest=-
      u4_manager_identity=not-applicable
      u4_policy_tokens='[]'
    fi
    jq --arg action "$u4_action" --arg kind "$u4_constraint_kind" \
      --arg constraint "$u4_constraint_digest" --arg manager "$u4_manager_identity" \
      --arg policy_token "$(if [ "$u4_token_kind" = protected ]; then printf '%s' "$u4_policy_token"; else printf '%s' -; fi)" \
      --argjson tokens "$u4_policy_tokens" '
      if .kind == "privilege_broker" then
        .data.observed_action_contexts=[{action_id:$action,context_id:"posix-root-v1",
          constraint_kind:$kind,constraint_digest:$constraint,constraint_generation:1,
          policy_tokens:$tokens,manager_source_identity:$manager}] |
        .data.observed_preconditions=[{action_id:$action,policy_token:$policy_token,
          digest:{algorithm:"sha256",value:("f" * 64)},
          evidence:{kind:"fixture",digest:{algorithm:"sha256",value:("e" * 64)}}}]
      else . end
    ' "$tmp/u4-ready.jsonl" >"$tmp/u4-action-ready-$u4_action_number.jsonl"
    jq -n --arg expiry "$u4_expiry" --arg action "$u4_action" --arg request "$u4_request_id" \
      --arg token "$u4_policy_token" --arg token_kind "$u4_token_kind" '{
      domain:"updates",target:"test-apt",operations:[
        {type:"package-metadata-refresh",kind:"package",id:"apt:example",argv:["brew","update"]},
        {type:"semantic-action",kind:"privileged_action",id:$action,
          privilege_request:{action_id:$action,policy_token:(if $token_kind == "protected" then $token else null end),
            request_id:$request,expires_at:$expiry}}
      ]}' >"$tmp/u4-action-draft-$u4_action_number.json"
    "$cli" seal-plan "$tmp/u4-action-draft-$u4_action_number.json" \
      "$tmp/u4-action-ready-$u4_action_number.jsonl" "$tmp/u4-action-plan-$u4_action_number.json"
    [ "$(jq -r --arg action "$u4_action" --arg token "$u4_policy_token" --arg token_kind "$u4_token_kind" '
      .operations[1].id == $action and
      (if $token_kind == "protected" then .operations[1].privilege.action.policy_token == $token
       else .operations[1].privilege.action.policy_token == null end) and
      (.operations[1] | has("argv") | not)' "$tmp/u4-action-plan-$u4_action_number.json")" = true ] ||
      fail "U4 did not seal the shared descriptor for $u4_action"
    jq '.operations[1].privilege_request.source="caller"' "$tmp/u4-action-draft-$u4_action_number.json" \
      >"$tmp/u4-action-source-$u4_action_number.json"
    if "$cli" seal-plan "$tmp/u4-action-source-$u4_action_number.json" \
        "$tmp/u4-action-ready-$u4_action_number.jsonl" "$tmp/u4-action-source-plan-$u4_action_number.json" \
        >/dev/null 2>&1; then
      fail "U4 accepted caller source controls for $u4_action"
    fi
  done

  # Every standalone schema-3 catalog action enters the same fixed broker
  # executor. The trusted internal Windows projection adds current protected
  # SID/source-address/context plus the action-specific broker precondition;
  # it never invents caller command controls.
  jq '
    if .kind == "privilege_broker" then
      .data.protected_identity={host_id:.host_id,sid:"S-1-5-21-1-2-3-1001",
        request_principal:"RoundhouseRequest"} |
      .data.observed_winget_context_digest={algorithm:"sha256",value:("9" * 64)}
    else . end
  ' "$tmp/u4-ready.jsonl" >"$tmp/u4-schema3-windows-ready.jsonl"
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    u4_schema3_fixture_root=$tmp
    : >"$u4_schema3_fixture_root/u4-schema3-dispatches"
    apply_privileged_plan_command() {
      jq -r '.operations[0].id' "$1" >>"$u4_schema3_fixture_root/u4-schema3-dispatches"
    }
    u4_schema3_number=0
    for u4_schema3_spec in \
      'apt.autoremove.v1|updates|packages|posix-root-v1|none|none' \
      'apt.install-package-version.v1|updates|packages|posix-root-v1|package-source-version-closure-set-sha256|protected' \
      'apt.update-metadata.v1|updates|packages|posix-root-v1|none|none' \
      'apt.upgrade-package.v1|updates|packages|posix-root-v1|package-source-channel-set-sha256|protected' \
      'winget.install-machine-package.v1|updates|packages|windows-system-v1|winget-package-version-set-sha256|protected' \
      'winget.inventory-machine.v1|updates|packages|windows-system-v1|none|none' \
      'winget.upgrade-machine-package.v1|updates|packages|windows-system-v1|winget-package-channel-set-sha256|protected' \
      'profile.apply-managed-bundle.v1|agents|agents|windows-user-s4u-v1|profile-bundle-set-sha256|protected' \
      'profile.inventory-managed-state.v1|agents|agents|windows-user-s4u-v1|profile-bundle-set-sha256|protected'; do
      IFS='|' read -r u4_schema3_action u4_schema3_domain u4_schema3_section \
        u4_schema3_context u4_schema3_constraint u4_schema3_token <<EOF
$u4_schema3_spec
EOF
      u4_schema3_number=$((u4_schema3_number + 1))
      case $u4_schema3_context in
        posix-root-v1)
          u4_schema3_adapter=posix-sudo-v1
          u4_schema3_principal=root
          u4_schema3_boundary=linux
          u4_schema3_transport=posix-ssh
          u4_schema3_request_principal=roundhouse
          u4_schema3_target=test-apt
          u4_schema3_snapshot=$tmp/u4-ready.jsonl
          ;;
        windows-system-v1)
          u4_schema3_adapter=windows-scheduled-task-v1
          u4_schema3_principal=LocalSystem
          u4_schema3_boundary=windows
          u4_schema3_transport=windows-sftp
          u4_schema3_request_principal=RoundhouseRequest
          u4_schema3_target=test-windows
          u4_schema3_snapshot=$tmp/u4-schema3-windows-ready.jsonl
          ;;
        windows-user-s4u-v1)
          u4_schema3_adapter=windows-scheduled-task-v1
          u4_schema3_principal=enrolled-s4u-user
          u4_schema3_boundary=windows
          u4_schema3_transport=windows-sftp
          u4_schema3_request_principal=RoundhouseRequest
          u4_schema3_target=test-windows
          u4_schema3_snapshot=$tmp/u4-schema3-windows-ready.jsonl
          ;;
      esac
      if [ "$u4_schema3_token" = protected ]; then
        u4_schema3_policy_token=fixture-token
        u4_schema3_constraint_digest=$(printf 'a%.0s' {1..64})
        u4_schema3_manager=$u4_schema3_constraint_digest
      else
        u4_schema3_policy_token=null
        u4_schema3_constraint_digest=-
        u4_schema3_manager=not-applicable
      fi
      if [ "$u4_schema3_boundary" = windows ]; then
        u4_schema3_action_precondition=$(printf '7%.0s' {1..64})
      else
        u4_schema3_action_precondition=
      fi
      jq --arg action "$u4_schema3_action" --arg domain "$u4_schema3_domain" \
        --arg section "$u4_schema3_section" --arg context "$u4_schema3_context" \
        --arg constraint "$u4_schema3_constraint" --arg constraint_digest "$u4_schema3_constraint_digest" \
        --arg policy_token "$u4_schema3_policy_token" --arg adapter "$u4_schema3_adapter" \
        --arg principal "$u4_schema3_principal" --arg boundary "$u4_schema3_boundary" \
        --arg transport "$u4_schema3_transport" --arg request_principal "$u4_schema3_request_principal" \
        --arg manager "$u4_schema3_manager" --arg target "$u4_schema3_target" \
        --arg precondition "$u4_schema3_action_precondition" '
        .domain=$domain | .required_section=$section | .target=$target |
        .operations[0].id=$action | .privilege.action.id=$action |
        .privilege.action.policy_token=(if $policy_token == "null" then null else $policy_token end) |
        .privilege.policy.constraint_kind=$constraint |
        .privilege.policy.constraint_digest=$constraint_digest |
        .privilege.broker.adapter=$adapter |
        .privilege.context.required=$context |
        .privilege.context.observed_execution_principal=$principal |
        .privilege.context.platform_boundary=$boundary |
        .privilege.context.manager_source_identity=$manager |
        .privilege.request.transport=$transport |
        .privilege.request.principal=$request_principal |
        if $precondition == "" then . else
          .precondition_digest.value=$precondition |
          .privilege.precondition.digest.value=$precondition
        end |
        del(.plan_id,.plan_digest)
      ' "$tmp/u1-privileged-plan.json" >"$tmp/u4-schema3-base-$u4_schema3_number.json"
      u4_schema3_digest=$(jq -cS . "$tmp/u4-schema3-base-$u4_schema3_number.json" | sha256_stream)
      u4_schema3_plan_id="plan-$(printf '%s' "$u4_schema3_digest" | cut -c 1-16)"
      jq -S --arg plan_id "$u4_schema3_plan_id" --arg digest "$u4_schema3_digest" \
        '. + {plan_id:$plan_id,plan_digest:{algorithm:"sha256",value:$digest}}' \
        "$tmp/u4-schema3-base-$u4_schema3_number.json" >"$tmp/u4-schema3-$u4_schema3_number.json"
      validate_privileged_plan_file "$tmp/u4-schema3-$u4_schema3_number.json" ||
        fail "U4 did not retain a valid standalone schema-3 contract for $u4_schema3_action"
      if [ "$u4_schema3_boundary" = windows ]; then
        u4_schema3_observed_token=$u4_schema3_policy_token
        [ "$u4_schema3_observed_token" != null ] || u4_schema3_observed_token=-
        jq --arg action "$u4_schema3_action" --arg token "$u4_schema3_observed_token" \
          --arg digest "$u4_schema3_action_precondition" '
          if .kind == "privilege_broker" then
            .data.observed_preconditions=[{action_id:$action,policy_token:$token,
              digest:{algorithm:"sha256",value:$digest}}]
          else . end
        ' "$u4_schema3_snapshot" >"$tmp/u4-schema3-current-ready.jsonl"
        u4_schema3_snapshot=$tmp/u4-schema3-current-ready.jsonl
      fi
      normalize_privileged_plan_for_broker_execution "$tmp/u4-schema3-$u4_schema3_number.json" \
        "$u4_schema3_snapshot" "$tmp/u4-schema3-executable-$u4_schema3_number.json"
      jq -e --arg action "$u4_schema3_action" --arg context "$u4_schema3_context" '
        .schema_version == 4 and (.operations | length) == 1 and
        (has("privilege") | not) and .operations[0].id == $action and
        .operations[0].privilege.context.required == $context and
        (.operations[0] | has("argv") | not) and
        ([.. | objects | has("command") or has("dependency_controls") or has("source_controls")] | any | not) and
        (if ($context | startswith("windows-")) then
          .operations[0].privilege.request.target_uid == "-" and
          .operations[0].privilege.request.request_sid == "S-1-5-21-1-2-3-1001" and
          .operations[0].privilege.context.platform_context_digest.value == ("9" * 64) and
          .operations[0].privilege.precondition.digest.value == ("7" * 64)
        else
          (.operations[0].privilege.request.target_uid | test("^(0|[1-9][0-9]*)$")) and
          .operations[0].privilege.request.request_sid == "-" and
          .operations[0].privilege.context.platform_context_digest == null
        end)
      ' "$tmp/u4-schema3-executable-$u4_schema3_number.json" >/dev/null ||
        fail "U4 schema-3 normalization widened $u4_schema3_action"
      apply_plan_command "$tmp/u4-schema3-$u4_schema3_number.json" "$u4_schema3_plan_id" \
        "$tmp/u4-schema3-result-$u4_schema3_number.jsonl" false
    done
    [ "$(wc -l <"$u4_schema3_fixture_root/u4-schema3-dispatches" | tr -d ' ')" -eq 9 ] ||
      fail "U4 did not route every standalone catalog action to the fixed schema-3 executor"
  )

  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    for u4_protocol in 0 1; do
      for u4_control in readiness result_query drain revocation; do
        privilege_protocol_supports_control "$u4_protocol" "$u4_control" ||
          fail "U4 protocol $u4_protocol lost $u4_control compatibility"
      done
    done
    privilege_protocol_supports_action 1 apt.update-metadata.v1 ||
      fail "U4 current protocol lost a shared action"
    if privilege_protocol_supports_action 0 apt.update-metadata.v1; then
      fail "U4 previous read-only protocol admitted a mutation"
    fi
  )

  # The portable profile builder emits the worker's exact length-prefixed,
  # uncompressed manifest/payload form and excludes filesystem aliases.
  mkdir "$tmp/u4-profile-source"
  printf '%s\n' '{"model":"gpt-5.6"}' >"$tmp/u4-profile-source/codex.json"
  printf '%s\n' 'service_tier = "priority"' >"$tmp/u4-profile-source/codex.toml"
  jq -n '{schema:"roundhouse.profile-bundle-spec",schema_version:1,
    request_id:"request-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    action_id:"profile.apply-managed-bundle.v1",policy_token:"profile-token",
    target_sid:"S-1-5-21-1-2-3-2001",profile_root_id:("b" * 64),entries:[
      {path:".codex/settings.json",handler:"json-scalar",artifact:"codex-settings",manager:"codex",
        logical_identity:"codex-settings",operation:"write",source:"codex.json",
        expected_presence:"absent",expected_sha256:"-",expected_manager:"-"},
      {path:".codex/config.toml",handler:"toml-scalar",artifact:"codex-settings",manager:"codex",
        logical_identity:"codex-settings",operation:"write",source:"codex.toml",
        expected_presence:"absent",expected_sha256:"-",expected_manager:"-"}
    ]}' >"$tmp/u4-profile-spec.json"
  ROUNDHOUSE_CALLER=codex "$cli" profile-bundle "$tmp/u4-profile-spec.json" \
    "$tmp/u4-profile-source" "$tmp/u4-codex.bundle"
  ROUNDHOUSE_CALLER=claude "$cli" profile-bundle "$tmp/u4-profile-spec.json" \
    "$tmp/u4-profile-source" "$tmp/u4-claude.bundle"
  cmp -s "$tmp/u4-codex.bundle" "$tmp/u4-claude.bundle" ||
    fail "U4 profile bundle bytes varied by caller"
  jq '.extra="forbidden"' "$tmp/u4-profile-spec.json" >"$tmp/u4-profile-extra-spec.json"
  if "$cli" profile-bundle "$tmp/u4-profile-extra-spec.json" "$tmp/u4-profile-source" \
      "$tmp/u4-profile-extra-spec.bundle" >/dev/null 2>&1; then
    fail "U4 profile builder accepted an unknown top-level control"
  fi
  jq '.entries[0].extra="forbidden"' "$tmp/u4-profile-spec.json" \
    >"$tmp/u4-profile-extra-entry.json"
  if "$cli" profile-bundle "$tmp/u4-profile-extra-entry.json" "$tmp/u4-profile-source" \
      "$tmp/u4-profile-extra-entry.bundle" >/dev/null 2>&1; then
    fail "U4 profile builder accepted an unknown per-entry control"
  fi
  u4_manifest_length=$(od -An -t u1 -N 8 "$tmp/u4-codex.bundle" |
    awk '{ for (i=1; i<=NF; i++) value=(value*256)+$i } END { printf "%.0f", value }')
  u4_payload_length=$(od -An -t u1 -j 8 -N 8 "$tmp/u4-codex.bundle" |
    awk '{ for (i=1; i<=NF; i++) value=(value*256)+$i } END { printf "%.0f", value }')
  dd if="$tmp/u4-codex.bundle" of="$tmp/u4-profile-manifest" bs=1 skip=16 \
    count="$u4_manifest_length" 2>/dev/null
  [ "$u4_payload_length" -eq $(( $(wc -c <"$tmp/u4-profile-source/codex.toml") +
    $(wc -c <"$tmp/u4-profile-source/codex.json") )) ] &&
    grep -Fqx "payload-length|$u4_payload_length" "$tmp/u4-profile-manifest" &&
    [ "$(grep -c '^entry|' "$tmp/u4-profile-manifest")" -eq 2 ] ||
    fail "U4 profile bundle did not publish canonical uncompressed lengths"
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    /bin/dd if=/dev/zero of="$tmp/u4-windows-payload-boundary" bs=1048576 count=0 seek=64 \
      2>/dev/null
    u4_sparse_blocks=$(stat -f %b "$tmp/u4-windows-payload-boundary" 2>/dev/null || \
      stat -c %b "$tmp/u4-windows-payload-boundary")
    [ $((u4_sparse_blocks * 512)) -lt 1048576 ] ||
      fail "U4 Windows payload boundary fixture was physically allocated"
    u4_boundary_length=$(wc -c <"$tmp/u4-windows-payload-boundary" | tr -d ' ')
    assert_windows_broker_payload_length "$u4_boundary_length"
    printf x >>"$tmp/u4-windows-payload-boundary"
    if assert_windows_broker_payload_length \
        "$(wc -c <"$tmp/u4-windows-payload-boundary" | tr -d ' ')" >/dev/null 2>&1; then
      fail "U4 accepted a Windows payload one byte over the protected transport limit"
    fi
  )
  ln -s codex.json "$tmp/u4-profile-source/codex-link.json"
  jq '.entries[0].source="codex-link.json"' "$tmp/u4-profile-spec.json" >"$tmp/u4-profile-symlink.json"
  if "$cli" profile-bundle "$tmp/u4-profile-symlink.json" "$tmp/u4-profile-source" \
      "$tmp/u4-profile-symlink.bundle" >/dev/null 2>&1; then
    fail "U4 profile builder followed a source symlink"
  fi
  ln "$tmp/u4-profile-source/codex.json" "$tmp/u4-profile-source/codex-hard.json"
  jq '.entries[0].source="codex-hard.json"' "$tmp/u4-profile-spec.json" >"$tmp/u4-profile-hardlink.json"
  if "$cli" profile-bundle "$tmp/u4-profile-hardlink.json" "$tmp/u4-profile-source" \
      "$tmp/u4-profile-hardlink.bundle" >/dev/null 2>&1; then
    fail "U4 profile builder accepted a multiply-linked source"
  fi
  jq '.entries += [(.entries[0] | .path=".CODEX/settings.json")]' "$tmp/u4-profile-spec.json" \
    >"$tmp/u4-profile-case-collision.json"
  if "$cli" profile-bundle "$tmp/u4-profile-case-collision.json" "$tmp/u4-profile-source" \
      "$tmp/u4-profile-case-collision.bundle" >/dev/null 2>&1; then
    fail "U4 profile builder accepted a case-colliding destination"
  fi
  dd if="$tmp/u4-codex.bundle" of="$tmp/u4-profile-payload" bs=1 \
    skip=$((16 + u4_manifest_length)) count="$u4_payload_length" 2>/dev/null
  u4_profile_entry_map=$(printf 'c%.0s' {1..64})
  jq -n --arg entry_map "$u4_profile_entry_map" '{
    id:"profile.apply-managed-bundle.v1",
    privilege:{
      action:{policy_token:"profile-token"},
      request:{id:"request-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        request_sid:"S-1-5-21-1-2-3-1001"},
      policy:{digest:{algorithm:"sha256",value:("c" * 64)},
        constraints_digest:{algorithm:"sha256",value:("e" * 64)},constraint_generation:1,
        constraint_digest:$entry_map},
      enrollment:{epoch:1},context:{manager_source_identity:$entry_map}
    }
  }' >"$tmp/u4-profile-operation.json"
  jq -n --arg entry_map "$u4_profile_entry_map" '{
    policy_token:"profile-token",target_sid:"S-1-5-21-1-2-3-2001",
    profile_root_id:("b" * 64),entry_map_digest:$entry_map,
    marketplace_set_digest:("d" * 64),delete_mode:"managed-only",max_entries:2,max_bytes:1048576
  }' >"$tmp/u4-profile-authorization.json"
  jq --arg entry_map "$u4_profile_entry_map" '
    if .kind == "privilege_broker" then
      .status="present" | .data.lifecycle_status="ready" |
      .data.protected_identity={host_id:.host_id,sid:"S-1-5-21-1-2-3-1001",
        request_principal:"RoundhouseRequest"} |
      .data.observed_action_contexts=[{
        action_id:"profile.apply-managed-bundle.v1",context_id:"windows-user-s4u-v1",
        constraint_kind:"profile-bundle-set-sha256",constraint_digest:$entry_map,
        constraint_generation:1,policy_tokens:["profile-token"],manager_source_identity:$entry_map,
        profile_constraints:[{policy_token:"profile-token",target_sid:"S-1-5-21-1-2-3-2001",
          profile_root_id:("b" * 64),entry_map_digest:$entry_map,
          marketplace_set_digest:("d" * 64),delete_mode:"managed-only",max_entries:2,max_bytes:1048576}]
      }]
    else . end
  ' "$tmp/u4-ready.jsonl" >"$tmp/u4-profile-ready.jsonl"
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    profile_authorization_from_snapshot "$tmp/u4-profile-ready.jsonl" \
      "$tmp/u4-profile-operation.json" "$tmp/u4-profile-derived-authorization.json"
    cmp -s "$tmp/u4-profile-derived-authorization.json" "$tmp/u4-profile-authorization.json" ||
      fail "U4 did not preserve the distinct request SID and protected S4U target authorization"
    validate_profile_bundle_for_operation "$tmp/u4-codex.bundle" \
      "$tmp/u4-profile-operation.json" "$tmp/u4-profile-derived-authorization.json" ||
      fail "U4 rejected a canonical profile bundle against its protected entry map"
    jq '.privilege.request.request_sid="S-1-5-21-1-2-3-2001"' \
      "$tmp/u4-profile-operation.json" >"$tmp/u4-profile-same-sid-operation.json"
    if profile_authorization_from_snapshot "$tmp/u4-profile-ready.jsonl" \
        "$tmp/u4-profile-same-sid-operation.json" "$tmp/u4-profile-same-sid-authorization.json" \
        >/dev/null 2>&1; then
      fail "U4 accepted one SID as both the SFTP request identity and S4U target identity"
    fi
    for u4_profile_projection_case in $(seq 1 10); do
      jq --argjson case "$u4_profile_projection_case" '
        if .kind == "privilege_broker" then
          .data.observed_action_contexts[0].profile_constraints as $profiles |
          if $case == 1 then .data.observed_action_contexts[0].profile_constraints[0].policy_token=""
          elif $case == 2 then .data.observed_action_contexts[0].profile_constraints[0].target_sid="not-a-sid"
          elif $case == 3 then .data.observed_action_contexts[0].profile_constraints[0].profile_root_id="bad"
          elif $case == 4 then .data.observed_action_contexts[0].profile_constraints[0].entry_map_digest="bad"
          elif $case == 5 then .data.observed_action_contexts[0].profile_constraints[0].marketplace_set_digest="bad"
          elif $case == 6 then .data.observed_action_contexts[0].profile_constraints[0].delete_mode="all"
          elif $case == 7 then .data.observed_action_contexts[0].profile_constraints[0].max_entries=0
          elif $case == 8 then .data.observed_action_contexts[0].profile_constraints[0].max_bytes=0
          elif $case == 9 then .data.observed_action_contexts[0].profile_constraints[0].extra="forbidden"
          else .data.observed_action_contexts[0].profile_constraints += [$profiles[0]] end
        else . end
      ' "$tmp/u4-profile-ready.jsonl" >"$tmp/u4-profile-projection-tampered.jsonl"
      if profile_authorization_from_snapshot "$tmp/u4-profile-projection-tampered.jsonl" \
          "$tmp/u4-profile-operation.json" "$tmp/u4-profile-tampered-authorization.json" \
          >/dev/null 2>&1; then
        fail "U4 accepted malformed protected profile projection case $u4_profile_projection_case"
      fi
    done
    u4_rebuild_profile_bundle() {
      u4_bundle_manifest=$1
      u4_bundle_output=$2
      u4_bundle_manifest_length=$(wc -c <"$u4_bundle_manifest" | tr -d ' ')
      {
        write_u64_be "$u4_bundle_manifest_length"
        write_u64_be "$u4_payload_length"
        cat "$u4_bundle_manifest" "$tmp/u4-profile-payload"
      } >"$u4_bundle_output"
    }
    for u4_profile_header_line in $(seq 2 9); do
      awk -F '|' -v line="$u4_profile_header_line" 'NR == line { $0=$1 "|" } { print }' \
        "$tmp/u4-profile-manifest" >"$tmp/u4-profile-mutated-manifest"
      u4_rebuild_profile_bundle "$tmp/u4-profile-mutated-manifest" \
        "$tmp/u4-profile-mutated.bundle"
      if validate_profile_bundle_for_operation "$tmp/u4-profile-mutated.bundle" \
          "$tmp/u4-profile-operation.json" "$tmp/u4-profile-authorization.json" \
          >/dev/null 2>&1; then
        fail "U4 accepted a profile bundle with header field $u4_profile_header_line removed"
      fi
    done
    for u4_profile_entry_field in $(seq 1 14); do
      awk -F '|' -v OFS='|' -v field="$u4_profile_entry_field" \
        'NR == 10 { $field="" } { print }' "$tmp/u4-profile-manifest" \
        >"$tmp/u4-profile-mutated-manifest"
      u4_rebuild_profile_bundle "$tmp/u4-profile-mutated-manifest" \
        "$tmp/u4-profile-mutated.bundle"
      if validate_profile_bundle_for_operation "$tmp/u4-profile-mutated.bundle" \
          "$tmp/u4-profile-operation.json" "$tmp/u4-profile-authorization.json" \
          >/dev/null 2>&1; then
        fail "U4 accepted a profile bundle with entry field $u4_profile_entry_field removed"
      fi
    done
  )

  # A protected plan is classified before any legacy SSH/SCP call.
  mkdir "$tmp/u4-fake-transport"
  for u4_transport_command in ssh scp; do
    printf '#!/bin/sh\nprintf invoked >"%s"\nexit 99\n' "$tmp/u4-legacy-transport-invoked" \
      >"$tmp/u4-fake-transport/$u4_transport_command"
    chmod +x "$tmp/u4-fake-transport/$u4_transport_command"
  done
  if PATH="$tmp/u4-fake-transport:$PATH" "$cli" apply-ssh-plan "$tmp/u4-plan.json" \
      "$(jq -r '.plan_id' "$tmp/u4-plan.json")" "$tmp/u4-legacy-result.jsonl" \
      >"$tmp/u4-legacy.stdout" 2>"$tmp/u4-legacy.stderr"; then
    fail "U4 routed schema 4 through the legacy SSH workspace"
  fi
  [ ! -e "$tmp/u4-legacy-transport-invoked" ] &&
    grep -Fq 'legacy SSH accepts only ordinary schema 2 plans' "$tmp/u4-legacy.stderr" ||
    fail "U4 protected-plan classifier ran after legacy transport"
  jq '.operations[0].policy_token="forbidden"' "$tmp/u1-unprivileged-plan.json" \
    >"$tmp/u4-schema2-protected.json"
  chmod 600 "$tmp/u4-schema2-protected.json"
  if PATH="$tmp/u4-fake-transport:$PATH" "$cli" apply-ssh-plan "$tmp/u4-schema2-protected.json" \
      "$(jq -r '.plan_id' "$tmp/u4-schema2-protected.json")" "$tmp/u4-schema2-protected-result.jsonl" \
      >/dev/null 2>&1; then
    fail "U4 legacy SSH accepted protected fields injected into schema 2"
  fi
  [ ! -e "$tmp/u4-legacy-transport-invoked" ] ||
    fail "U4 schema-2 protected-field rejection reached transport"

  # A mocked Windows SFTP route observes exactly four preallocated uploads,
  # commit last, an empty machine payload, and one sanitized result download.
  jq '
    .target="test-windows" |
    .operations[1].id="winget.inventory-machine.v1" |
    .operations[1].privilege.action={id:"winget.inventory-machine.v1",policy_token:null} |
    .operations[1].privilege.broker.adapter="windows-scheduled-task-v1" |
    .operations[1].privilege.policy.constraint_kind="none" |
    .operations[1].privilege.policy.constraint_digest="-" |
    .operations[1].privilege.context.required="windows-system-v1" |
    .operations[1].privilege.context.observed_execution_principal="LocalSystem" |
    .operations[1].privilege.context.platform_boundary="windows" |
    .operations[1].privilege.context.manager_source_identity="not-applicable" |
    .operations[1].privilege.context.platform_context_digest={algorithm:"sha256",value:("9" * 64)} |
    .operations[1].privilege.request.transport="windows-sftp" |
    .operations[1].privilege.request.principal="RoundhouseRequest" |
    .operations[1].privilege.request.target_uid="-" |
    .operations[1].privilege.request.request_sid="S-1-5-21-1-2-3-2001" |
    del(.plan_id,.plan_digest)
  ' "$tmp/u4-plan.json" >"$tmp/u4-windows-base.json"
  u4_windows_digest=$(jq -cS . "$tmp/u4-windows-base.json" | shasum -a 256 | awk '{print $1}')
  u4_windows_plan_id="plan-${u4_windows_digest:0:16}"
  jq -S --arg plan_id "$u4_windows_plan_id" --arg digest "$u4_windows_digest" \
    '. + {plan_id:$plan_id,plan_digest:{algorithm:"sha256",value:$digest}}' \
    "$tmp/u4-windows-base.json" >"$tmp/u4-windows-plan.json"
  mkdir "$tmp/u4-windows-slot"
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    u4_windows_fixture_root=$tmp
    u4_windows_plan_path=$tmp/u4-windows-plan.json
    make_windows_broker_slot "$tmp/u4-windows-plan.json" 1 - "$tmp/u4-windows-slot"
    [ ! -s "$tmp/u4-windows-slot/payload" ] || fail "U4 machine request carried payload bytes"
    invoke_windows_sftp_batch() { cp "$7" "$tmp/u4-windows-submit.batch"; }
    windows_sftp_submit_slot test-windows "$tmp/u4-windows-slot"
    awk -F '"' '{ print $4 }' "$tmp/u4-windows-submit.batch" >"$tmp/u4-windows-remotes"
    printf '%s\n' '/ingress/slot/request' '/ingress/slot/request.sig' \
      '/ingress/slot/payload' '/ingress/slot/commit' >"$tmp/u4-windows-expected-remotes"
    [ "$(wc -l <"$tmp/u4-windows-submit.batch" | tr -d ' ')" -eq 4 ] &&
      cmp -s "$tmp/u4-windows-remotes" "$tmp/u4-windows-expected-remotes" &&
      ! grep -Eiq '(^|[[:space:]])(mkdir|ls|exec|scp|shell)([[:space:]]|$)' \
        "$tmp/u4-windows-submit.batch" ||
      fail "U4 Windows SFTP submission did not use the four canonical slot paths with commit last"
    invoke_windows_sftp_batch() {
      u4_poll_local=$(awk -F '"' 'NR == 1 { print $4 }' "$7")
      {
        printf '%s\n' 'windows-broker-public|1' 'state|completed' 'reason|post_state_verified'
        printf 'request-id|%s\n' "$(jq -r '.operations[1].privilege.request.id' "$u4_windows_plan_path")"
        printf 'plan-id|%s\n' "$u4_windows_plan_id"
        printf '%s\n' 'action-id|winget.inventory-machine.v1' 'enrollment-epoch|1'
        printf 'protected-result-sha256|%s\n' "$(printf '8%.0s' {1..64})"
        printf '%s\n' 'end-public|'
      } >"$u4_poll_local"
      cp "$u4_poll_local" "$u4_windows_fixture_root/u4-windows-public-result"
      cp "$7" "$u4_windows_fixture_root/u4-windows-poll.batch"
    }
    windows_sftp_poll_result test-windows "$tmp/u4-windows-plan.json" 1 "$tmp/u4-windows-outcome"
    IFS='|' read -r u4_windows_state u4_windows_reason u4_windows_kind \
      u4_windows_protected_digest u4_windows_projection_digest <"$tmp/u4-windows-outcome"
    [ "$u4_windows_state" = completed ] && [ "$u4_windows_reason" = post_state_verified ] &&
      [ "$u4_windows_kind" = windows-protected-result-sha256 ] &&
      [ "$u4_windows_protected_digest" = "$(printf '8%.0s' {1..64})" ] &&
      [ "$u4_windows_projection_digest" = "$(sha256_file "$tmp/u4-windows-public-result")" ] &&
      [ "$(wc -l <"$tmp/u4-windows-poll.batch" | tr -d ' ')" -eq 1 ] &&
      grep -Fq "/results/$(jq -r '.operations[1].privilege.request.id' "$u4_windows_plan_path").result" \
        "$tmp/u4-windows-poll.batch" &&
      ! grep -Eq '(^|[[:space:]])put([[:space:]]|$)' "$tmp/u4-windows-poll.batch" ||
      fail "U4 Windows result polling was not one canonical result-only lookup"
    : >"$tmp/u4-windows-operation-record.jsonl"
    write_mixed_apply_operation_record "$tmp/u4-windows-operation-record.jsonl" \
      "$tmp/u4-windows-plan.json" 1 u4-result-snapshot test-windows \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" completed "$u4_windows_reason" "$u4_windows_state" \
      "$u4_windows_kind" "$u4_windows_protected_digest" "$u4_windows_projection_digest"
    jq -e --arg protected "$u4_windows_protected_digest" \
      --arg projection "$u4_windows_projection_digest" '
      .data.authoritative_result_evidence.kind == "windows-protected-result-sha256" and
      .data.authoritative_result_evidence.digest.value == $protected and
      .data.authoritative_result_evidence.public_projection_digest.value == $projection and
      any(.evidence[]; .source == "protected-terminal" and .digest.value == $protected and
        .public_projection_digest.value == $projection)
    ' "$tmp/u4-windows-operation-record.jsonl" >/dev/null ||
      fail "U4 operation record discarded protected Windows terminal evidence"
    for u4_public_line in $(seq 2 8); do
      awk -F '|' -v line="$u4_public_line" 'NR == line { $0=$1 "|" } { print }' \
        "$tmp/u4-windows-public-result" >"$tmp/u4-windows-mutated-result"
      if windows_public_terminal_result "$tmp/u4-windows-mutated-result" \
          "$(jq -r '.operations[1].privilege.request.id' "$u4_windows_plan_path")" \
          "$u4_windows_plan_id" winget.inventory-machine.v1 1 >/dev/null 2>&1; then
        fail "U4 accepted a Windows terminal result with field $u4_public_line removed"
      fi
    done
    {
      sed '$d' "$tmp/u4-windows-public-result"
      printf '%s\n' 'unexpected|secret' 'end-public|'
    } >"$tmp/u4-windows-leaky-result"
    if windows_public_terminal_result "$tmp/u4-windows-leaky-result" \
        "$(jq -r '.operations[1].privilege.request.id' "$tmp/u4-windows-plan.json")" \
        "$u4_windows_plan_id" winget.inventory-machine.v1 1 >/dev/null 2>&1; then
      fail "U4 accepted an extended/leaky Windows public result"
    fi

    # Result lookup is bounded to five fixed reads. It never resubmits the
    # request slot, and expiry is distinct from a broker-authored terminal.
    : >"$u4_windows_fixture_root/u4-windows-poll-calls"
    invoke_windows_sftp_batch() {
      printf x >>"$u4_windows_fixture_root/u4-windows-poll-calls"
      cp "$7" "$u4_windows_fixture_root/u4-windows-miss.batch"
      return 1
    }
    windows_poll_sleep() { :; }
    set +e
    windows_sftp_poll_result test-windows "$tmp/u4-windows-plan.json" 1 \
      "$tmp/u4-windows-miss-outcome"
    u4_windows_miss_rc=$?
    set -e
    [ "$u4_windows_miss_rc" -eq 70 ] &&
      [ "$(wc -c <"$tmp/u4-windows-poll-calls" | tr -d ' ')" -eq 5 ] &&
      [ "$(cat "$tmp/u4-windows-miss-outcome")" = \
        'partial|windows_result_queued_or_transport_unavailable|-|-|-' ] &&
      grep -Fq "/results/$(jq -r '.operations[1].privilege.request.id' "$u4_windows_plan_path").result" \
        "$tmp/u4-windows-miss.batch" &&
      ! grep -Eq '(^|[[:space:]])put([[:space:]]|$)' "$tmp/u4-windows-miss.batch" ||
      fail "U4 Windows result polling was not bounded to five result-only reads"
    rm -f "$u4_windows_fixture_root/u4-windows-expiry-invoked"
    windows_poll_clock() { printf '%s\n' 9999999999; }
    invoke_windows_sftp_batch() {
      : >"$u4_windows_fixture_root/u4-windows-expiry-invoked"
      return 1
    }
    set +e
    windows_sftp_poll_result test-windows "$tmp/u4-windows-plan.json" 1 \
      "$tmp/u4-windows-expired-outcome"
    u4_windows_expired_rc=$?
    set -e
    [ "$u4_windows_expired_rc" -eq 70 ] && [ ! -e "$tmp/u4-windows-expiry-invoked" ] &&
      [ "$(cat "$tmp/u4-windows-expired-outcome")" = \
        'stale|windows_result_expired_without_terminal|-|-|-' ] ||
      fail "U4 Windows result expiry did not terminate before transport"
    invoke_windows_sftp_batch() {
      u4_lookup_local=$(awk -F '"' 'NR == 1 { print $4 }' "$7")
      {
        printf '%s\n' 'windows-broker-public|1' 'state|completed' 'reason|post_state_verified'
        printf 'request-id|%s\n' "$(jq -r '.operations[1].privilege.request.id' "$u4_windows_plan_path")"
        printf 'plan-id|%s\n' "$u4_windows_plan_id"
        printf '%s\n' 'action-id|winget.inventory-machine.v1' 'enrollment-epoch|1'
        printf 'protected-result-sha256|%s\n' "$(printf '8%.0s' {1..64})"
        printf '%s\n' 'end-public|'
      } >"$u4_lookup_local"
      cp "$7" "$u4_windows_fixture_root/u4-windows-expired-lookup.batch"
    }
    lookup_privilege_result_command "$tmp/u4-windows-plan.json" 1 \
      "$tmp/u4-windows-expired-lookup-outcome"
    [ "$(cut -d '|' -f 1 "$tmp/u4-windows-expired-lookup-outcome")" = completed ] &&
      [ "$(wc -l <"$tmp/u4-windows-expired-lookup.batch" | tr -d ' ')" -eq 1 ] &&
      grep -Eq '^get "/results/request-[0-9a-f]{32}[.]result" "[^"]+"$' \
        "$tmp/u4-windows-expired-lookup.batch" &&
      ! grep -Eq '(^|[[:space:]])put([[:space:]]|$)' "$tmp/u4-windows-expired-lookup.batch" ||
      fail "U4 expired Windows result lookup did not remain a bounded result-only poll"
  )

  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    write_posix_dispatch_request ordinary-plan "$tmp/u1-ssh-worker-config.json" \
      "$tmp/u1-partial-plan.json" "$tmp/u4-posix-dispatch"
    [ "$(sed -n '1p' "$tmp/u4-posix-dispatch")" = 'posix-dispatch|1' ] &&
      grep -Fqx 'mode|ordinary-plan' "$tmp/u4-posix-dispatch" ||
      fail "U4 did not emit the fixed bounded POSIX dispatcher framing"
  )
  if SSH_ORIGINAL_COMMAND=whoami "$cli" dispatch-posix-request <"$tmp/u4-posix-dispatch" \
      >/dev/null 2>"$tmp/u4-posix-dispatch.stderr"; then
    fail "U4 fixed POSIX dispatcher accepted SSH_ORIGINAL_COMMAND"
  fi
  grep -Fq 'rejects SSH_ORIGINAL_COMMAND' "$tmp/u4-posix-dispatch.stderr" ||
    fail "U4 POSIX dispatcher did not classify the original command before payload processing"

  set +e
  "$cli" apply-plan "$tmp/u4-plan.json" "$(jq -r '.plan_id' "$tmp/u4-plan.json")" "$tmp/u4-no-canary-result.jsonl" >/dev/null
  u4_apply_rc=$?
  set -e
  [ "$u4_apply_rc" -eq 70 ] || fail "U4 readiness failure was not an authoritative partial apply"
  "$cli" validate "$tmp/u4-no-canary-result.jsonl"
  u4_operation_statuses=$(jq -c -s '[.[] | select(.kind == "operation" and (.id | startswith("apply:"))) | .data.operation_status] | sort' "$tmp/u4-no-canary-result.jsonl")
  [ "$u4_operation_statuses" = '["failed","partial","skipped"]' ] ||
    fail "U4 did not emit indexed failed/skipped operation records"
  cli_program_contains 'Linux) fixed_broker=/usr/libexec/roundhouse/posix-broker' &&
    cli_program_contains 'Darwin) fixed_broker=/usr/local/libexec/roundhouse/posix-broker' &&
    cli_program_contains 'broker.query-result.v1' ||
    fail "U4 did not retain a fixed broker-only submit/query path"
}

[ "${ROUNDHOUSE_TEST_SCOPE:-}" != u4-contracts ] || {
  test_u4_contracts
  printf 'PASS: U4 contracts\n'
  exit 0
}
