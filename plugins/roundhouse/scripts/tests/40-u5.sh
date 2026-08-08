# roundhouse self-check — U5 — the protected route: fixed dispatch, result
# lookup and previews.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

test_u5_contracts() {
  jq '
    .machines["test-apt"].transport="ssh" |
    .machines["test-apt"].ssh_alias="hostile-ordinary-ssh-alias" |
    .machines["test-apt"].privilege_broker.automation_transport={
      mode:"posix-ssh",host:"linux.example.invalid",port:22,
      request_user:"roundhouse",
      pinned_host_key_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      management_networks:["192.0.2.0/24"]
    } |
    .machines["test-windows"].privilege_broker.automation_transport={
      mode:"windows-sftp",host:"windows.example.invalid",port:22,
      request_user:"RoundhouseRequest",
      request_sid:"S-1-5-21-1-2-3-2001",
      pinned_host_key_fingerprint:"SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
      management_networks:["192.0.2.0/24"]
    } |
    .machines["test-wsl"]={platform:"wsl",transport:"local",
      expected_hostname:.machines["test-apt"].expected_hostname,
      expected_user:.machines["test-apt"].expected_user,groups:["development"],
      package_managers:["apt"],dev_root:"~/dev"}
  ' "$tmp/config.json" >"$tmp/u5-config.json"
  chmod 600 "$tmp/u5-config.json"
  jq 'del(.machines["test-windows"].privilege_broker.automation_transport.request_sid)' \
    "$tmp/u5-config.json" >"$tmp/u5-config-without-request-sid.json"
  chmod 600 "$tmp/u5-config-without-request-sid.json"
  if ROUNDHOUSE_CONFIG="$tmp/u5-config-without-request-sid.json" \
      "$cli" validate-config >/dev/null 2>&1; then
    fail "U5 Windows SFTP configuration accepted a missing ceremony-derived request SID"
  fi

  ROUNDHOUSE_CONFIG="$tmp/u5-config.json" \
    "$cli" prepare-privilege-enrollment test-apt "$tmp/u5-linux-enrollment.json"
  jq -e '
    .schema == "roundhouse.privilege-enrollment-preparation" and
    .state == "needs_human_enrollment" and .reason == "local_passworded_sudo_required" and
    .activation_performed == false and
    (.fixed_entrypoints | map(.path) | index("scripts/enroll-privilege-posix") != null) and
    (.fixed_entrypoints | map(.path) | index("scripts/enroll-ssh-posix") != null) and
    (.credential_handling | contains("never_requests_or_relays"))
  ' "$tmp/u5-linux-enrollment.json" >/dev/null ||
    fail "U5 Linux enrollment preparation crossed or omitted the human boundary"

  ROUNDHOUSE_CONFIG="$tmp/u5-config.json" \
    "$cli" prepare-privilege-enrollment test-windows "$tmp/u5-windows-enrollment.json"
  jq -e '
    .platform == "windows" and .route == "windows-sftp" and
    .state == "needs_human_enrollment" and .activation_performed == false and
    (.fixed_entrypoints | map(.path) | index("scripts/enroll-privilege-windows.ps1") != null) and
    (.fixed_entrypoints | map(.path) | index("scripts/enroll-windows-sftp.ps1") != null) and
    .configured_request_sid == "S-1-5-21-1-2-3-2001" and
    .request_sid_source == "authenticated_signed_controller_intent_or_receipt_only" and
    (.required_public_artifacts | index("windows-winget-provider.lock") != null)
  ' "$tmp/u5-windows-enrollment.json" >/dev/null ||
    fail "U5 Windows enrollment preparation omitted WinGet, SFTP, or UAC guidance"

  set +e
  ROUNDHOUSE_CONFIG="$tmp/u5-config.json" \
    "$cli" prepare-privilege-enrollment test-wsl "$tmp/u5-wsl-enrollment.json"
  u5_wsl_rc=$?
  set -e
  [ "$u5_wsl_rc" -eq 69 ] &&
    [ "$(jq -r '.reason' "$tmp/u5-wsl-enrollment.json")" = unsupported_security_boundary ] ||
    fail "U5 WSL enrollment preparation did not fail as unsupported_security_boundary"

  ROUNDHOUSE_CONFIG="$tmp/u5-config.json" \
    "$cli" preview-privilege-upgrade test-apt "$tmp/u5-upgrade.json"
  ROUNDHOUSE_CONFIG="$tmp/u5-config.json" \
    "$cli" preview-privilege-revocation test-windows "$tmp/u5-revocation.json"
  jq -e '.activation_performed == false and .allow_submit == false and
    .allow_result_query == true and (.credential_handling | contains("never_requests_or_relays"))' \
    "$tmp/u5-upgrade.json" "$tmp/u5-revocation.json" >/dev/null ||
    fail "U5 lifecycle previews authorized a mutation or credential relay"
  jq -e '.normal_sequence == ["drain","reject_new_submissions","recover_terminal_result",
    "revoke_adapter_grant","remove_transport_authorization"]' "$tmp/u5-revocation.json" >/dev/null ||
    fail "U5 revocation preview omitted drain and result recovery"

  "$plugin_cache/scripts/prepare-ssh-identity" preview fleet.example u5-node \
    roundhouse-posix,roundhouse-windows 192.0.2.0/24 \
    >"$tmp/u5-identity-preview"
  grep -Fq 'operation|prepare' "$tmp/u5-identity-preview" &&
    grep -Fq 'private-key-storage|owner-only-nonsynced-local-state' "$tmp/u5-identity-preview" &&
    cli_function_body prepare_privilege_identity_command |
      grep -Fq '"$script_dir/prepare-ssh-identity" prepare' ||
    fail "U5 identity preparation was not a thin public-only fixed-helper wrapper"

  set +e
  "$cli" not-a-command >"$tmp/u5-usage.stdout" 2>"$tmp/u5-usage.stderr"
  u5_usage_rc=$?
  set -e
  [ "$u5_usage_rc" -eq 64 ] || fail "U5 CLI usage did not reject an unknown command"
  for u5_command in privilege-status prepare-privilege-identity prepare-privilege-enrollment \
      verify-privilege-plan submit-privilege-plan lookup-privilege-result \
      preview-privilege-upgrade preview-privilege-revocation; do
    grep -Fq "roundhouse $u5_command" "$tmp/u5-usage.stderr" ||
      fail "U5 CLI usage omitted $u5_command"
  done
  jq -n '{schema_version:2}' >"$tmp/u5-ordinary-plan.json"
  chmod 600 "$tmp/u5-ordinary-plan.json"
  if "$cli" verify-privilege-plan "$tmp/u5-ordinary-plan.json" "$tmp/missing-snapshot" \
      >/dev/null 2>&1; then
    fail "U5 privilege verifier accepted an ordinary plan"
  fi
  if "$cli" submit-privilege-plan "$tmp/u5-ordinary-plan.json" plan-0000000000000000 \
      "$tmp/u5-ordinary-result" >/dev/null 2>&1; then
    fail "U5 privilege submitter accepted an ordinary plan"
  fi
  cli_function_body lookup_privilege_result_command >"$tmp/u5-result-lookup-body"
  grep -Fq 'broker.query-result.v1' "$tmp/u5-result-lookup-body" &&
    grep -Fq 'windows_sftp_poll_result' "$tmp/u5-result-lookup-body" &&
    ! grep -Fq 'windows_sftp_submit_slot' "$tmp/u5-result-lookup-body" ||
    fail "U5 result lookup did not remain a result-only wrapper"

  # A protected POSIX broker route is not an ordinary SSH lane. The fixture
  # deliberately supplies an hostile SSH alias and agent, but observes only
  # the pinned route tuple, a no-config/no-agent client, and a framed stdin
  # request. The target UID is intentionally unlike the controller UID.
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    u5_fixture_root=$tmp
    u5_ssh_root="$tmp/u5-fixed-ssh"
    mkdir -p "$u5_ssh_root/bin"
    cat >"$u5_ssh_root/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cat >"$root/stdin"
{
  printf 'ssh-auth-sock-present|%s\n' "${SSH_AUTH_SOCK+x}"
  printf 'ssh-auth-sock-value|%s\n' "${SSH_AUTH_SOCK-}"
  printf 'home|%s\n' "${HOME-}"
  for arg in "$@"; do printf 'arg|%s\n' "$arg"; done
} >"$root/invocation"
payload="$root/payload"
if grep -Fqx 'mode|readiness' "$root/stdin"; then
  snapshot=$(awk -F '|' '$1 == "snapshot-id" { print $2; exit }' "$root/stdin")
  [ -n "$snapshot" ]
  printf '%s\n' \
    "{\"schema\":\"roundhouse.inventory\",\"schema_version\":1,\"snapshot_id\":\"$snapshot\",\"host_id\":\"test-apt\",\"kind\":\"privilege_broker\",\"id\":\"readiness\",\"observed_at\":\"2026-08-03T00:00:00Z\",\"status\":\"present\",\"confidence\":\"high\",\"data\":{\"lifecycle_status\":\"ready\",\"transport\":\"posix-ssh\",\"transport_ready\":false,\"node_identity_ready\":false,\"originating_node_identity\":null,\"broker_ready\":true,\"action_context_ready\":true,\"adapter_mechanism_ready\":true,\"protected_identity\":{\"host_id\":\"test-apt\",\"uid\":4242,\"request_principal\":\"roundhouse\",\"pinned_host_key_fingerprint\":\"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"fleet_ca_fingerprint\":\"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"ca_generation\":1},\"pinned_host_key_fingerprint\":\"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"request_principal\":\"roundhouse\"},\"evidence\":[],\"errors\":[]}" >"$payload"
else
  printf '%s\n' 'remote-broker-result' >"$payload"
fi
if command -v sha256sum >/dev/null 2>&1; then digest=$(sha256sum "$payload" | awk '{print $1}')
else digest=$(shasum -a 256 "$payload" | awk '{print $1}'); fi
printf '%s\n' 'posix-dispatch-result|1' "mode|$(awk -F '|' '$1 == "mode" { print $2; exit }' "$root/stdin")" \
  'status|completed' 'exit-code|0' "payload-length|$(wc -c <"$payload" | tr -d ' ')" \
  "payload-sha256|$digest" 'end-header|'
cat "$payload"
SH
    chmod +x "$u5_ssh_root/bin/ssh"
    cat >"$tmp/u5-origin.json" <<'JSON'
{"schema":"roundhouse.originating-node-identity","schema_version":1,"fleet_domain":"fleet.example","node_id":"origin-a","node_key_fingerprint":"SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC","fleet_ca_fingerprint":"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ca_generation":1,"certificate_serial":"1","certificate_valid_after":"2025-01-01T00:00:00Z","certificate_valid_before":"2099-01-01T00:00:00Z","certificate_principals":["roundhouse-posix"],"certificate_source_addresses":["192.0.2.0/24"]}
JSON
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureCertificate fixture' >"$tmp/u5-cert.pub"
    jq -n --arg certificate "$tmp/u5-cert.pub" '{
      certificate_path:$certificate,node_id:"origin-a",fleet_domain:"fleet.example",
      fleet_ca_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",ca_generation:1,
      node_key_fingerprint:"SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
      certificate_serial:"1",certificate_valid_after:"2025-01-01T00:00:00Z",
      certificate_valid_before:"2099-01-01T00:00:00Z",certificate_source_addresses:["192.0.2.0/24"]
    }' >"$tmp/u5-identity.json"
    chmod 600 "$tmp/u5-origin.json" "$tmp/u5-cert.pub" "$tmp/u5-identity.json"
    cat >"$tmp/u5-ssh-keygen" <<'SH'
#!/bin/sh
if [ "${1:-}" = -Y ] && [ "${2:-}" = sign ]; then
  last=
  for argument in "$@"; do last=$argument; done
  printf '%s\n' 'fixture-signature' >"$last.sig"
fi
SH
    chmod +x "$tmp/u5-ssh-keygen"
    validate_node_identity_file() { :; }
    public_node_identity() { cat "$u5_fixture_root/u5-origin.json"; }
    system_ssh_path() { printf '%s\n' "$u5_ssh_root/bin/ssh"; }
    system_ssh_keygen_path() { printf '%s\n' "$u5_fixture_root/u5-ssh-keygen"; }
    export ROUNDHOUSE_CONFIG="$tmp/u5-config.json"
    export ROUNDHOUSE_IDENTITY="$tmp/u5-identity.json"
    export HOME="$tmp/u5-hostile-home"
    export SSH_AUTH_SOCK="$tmp/u5-hostile-agent"

    # The forced remote entrypoint accepts only the bounded readiness request:
    # no command argument, no original command, no workerless request.
    prepare_posix_readiness_worker_config test-apt "$tmp/u5-dispatch-worker.json"
    write_posix_readiness_request test-apt readiness-20260803T000000Z-1 "$tmp/u5-dispatch-request"
    write_posix_dispatch_request readiness "$tmp/u5-dispatch-worker.json" \
      "$tmp/u5-dispatch-request" "$tmp/u5-dispatch-frame"
    "$cli" dispatch-posix-request <"$tmp/u5-dispatch-frame" >"$tmp/u5-dispatch-response"
    u5_dispatch_metadata=$(read_posix_dispatch_result readiness "$tmp/u5-dispatch-response" \
      "$tmp/u5-dispatch-records.jsonl")
    [ "$u5_dispatch_metadata" = 'completed|0' ] &&
      jq -e -s '[.[] | select(.kind == "privilege_broker" and .id == "readiness")] | length == 1' \
        "$tmp/u5-dispatch-records.jsonl" >/dev/null ||
      fail "U5 fixed dispatcher did not run the bounded readiness collector"
    if SSH_ORIGINAL_COMMAND=hostile "$cli" dispatch-posix-request <"$tmp/u5-dispatch-frame" \
        >/dev/null 2>&1; then
      fail "U5 fixed dispatcher accepted an SSH original command for readiness"
    fi
    write_posix_dispatch_request broker-envelope - "$tmp/u5-dispatch-request" "$tmp/u5-workerless-frame"
    sed 's/^mode|broker-envelope$/mode|readiness/' "$tmp/u5-workerless-frame" \
      >"$tmp/u5-workerless-readiness-frame"
    if "$cli" dispatch-posix-request <"$tmp/u5-workerless-readiness-frame" >/dev/null 2>&1; then
      fail "U5 fixed dispatcher accepted a workerless readiness request"
    fi

    printf '%s\n' 'request|1' 'target-host-id|test-apt' 'target-uid|4242' >"$tmp/u5-envelope"
    invoke_posix_broker_for_target test-apt "$tmp/u5-envelope" "$tmp/u5-broker-output"
    [ "$(cat "$tmp/u5-broker-output")" = remote-broker-result ] &&
      grep -Fqx 'mode|broker-envelope' "$u5_ssh_root/stdin" &&
      grep -Fqx 'worker-length|0' "$u5_ssh_root/stdin" &&
      grep -Fqx 'target-uid|4242' "$u5_ssh_root/stdin" &&
      grep -Fqx 'ssh-auth-sock-present|x' "$u5_ssh_root/invocation" &&
      grep -Fqx 'ssh-auth-sock-value|' "$u5_ssh_root/invocation" &&
      grep -Fqx 'home|/nonexistent' "$u5_ssh_root/invocation" &&
      grep -Fqx 'arg|-F' "$u5_ssh_root/invocation" &&
      grep -Fqx 'arg|/dev/null' "$u5_ssh_root/invocation" &&
      grep -Fqx 'arg|linux.example.invalid' "$u5_ssh_root/invocation" &&
      ! grep -Fq 'hostile-ordinary-ssh-alias' "$u5_ssh_root/invocation" ||
      fail "U5 protected POSIX submit used ambient SSH configuration or local routing"

    u5_digest=$(printf 'a%.0s' {1..64})
    jq -n --arg digest "$u5_digest" '{
      plan_id:"plan-u5-remote",target:"test-apt",operations:[{
        type:"semantic-action",id:"apt.update-metadata.v1",privilege:{
          context:{required:"posix-root-v1",manager_source_identity:"not-applicable",canary_digest:{value:$digest}},
          request:{id:"request-u5-remote",target_uid:"4242",created_at:"2026-08-03T00:00:00Z",expires_at:"2099-01-01T00:00:00Z",originating_node_id:"origin-a",principal:"roundhouse",certificate_source_addresses:["192.0.2.0/24"]},
          action:{policy_token:null},broker:{protocol_version:1,version:"1",digest:{value:$digest}},
          policy:{digest:{value:$digest},constraints_digest:{value:$digest}},
          enrollment:{fleet_domain:"fleet.example",fleet_ca_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",ca_generation:1,certificate_valid_after:"2025-01-01T00:00:00Z",certificate_valid_before:"2099-01-01T00:00:00Z",epoch:1,pinned_host_key_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
        }
      }]
    }' >"$tmp/u5-remote-plan.json"
    make_posix_broker_envelope "$tmp/u5-remote-plan.json" 0 apt.update-metadata.v1 "$tmp/u5-submit-envelope"
    make_posix_broker_envelope "$tmp/u5-remote-plan.json" 0 broker.query-result.v1 "$tmp/u5-query-envelope"
    [ "$(awk -F '|' '$1 == "target-uid" { print $2; exit }' "$tmp/u5-submit-envelope")" = 4242 ] &&
      [ "$(awk -F '|' '$1 == "target-uid" { print $2; exit }' "$tmp/u5-query-envelope")" = 4242 ] ||
      fail "U5 replaced the remote protected UID with the controller UID"
    invoke_posix_broker_for_target test-apt "$tmp/u5-query-envelope" "$tmp/u5-query-output"
    grep -Fqx 'action-id|broker.query-result.v1' "$u5_ssh_root/stdin" &&
      grep -Fqx 'target-uid|4242' "$u5_ssh_root/stdin" ||
      fail "U5 recovery query did not use the dedicated remote broker lane"

    posix_dispatch_readiness_records test-apt "$tmp/u5-remote-readiness.jsonl"
    jq -e '.data.transport_ready == true and .data.node_identity_ready == true and
      .data.transport_receipt_status == "forced-dispatcher-readiness" and
      .data.protected_identity.uid == 4242 and .data.originating_node_identity.node_id == "origin-a"' \
      "$tmp/u5-remote-readiness.jsonl" >/dev/null &&
      grep -Fqx 'mode|readiness' "$u5_ssh_root/stdin" &&
      ! grep -Fq 'hostile-ordinary-ssh-alias' "$u5_ssh_root/invocation" ||
      fail "U5 remote readiness was not a locally-bound forced dispatcher projection"

    # Windows readiness is a new signed broker control over the fixed SFTP
    # route. The response fixture is intentionally the only source of broker,
    # action, profile, and observed-precondition data.
    u5_readiness_a=$(printf 'a%.0s' {1..64})
    u5_readiness_b=$(printf 'b%.0s' {1..64})
    u5_readiness_c=$(printf 'c%.0s' {1..64})
    u5_readiness_d=$(printf 'd%.0s' {1..64})
    u5_readiness_e=$(printf 'e%.0s' {1..64})
    u5_readiness_f=$(printf 'f%.0s' {1..64})
    u5_operation_readiness_digest=$u5_readiness_c
    windows_poll_clock() { printf '%s\n' 2000000000; }
    windows_poll_sleep() { :; }
    invoke_windows_sftp_batch() (
      batch=$7
      if grep -Fq 'put "' "$batch"; then
        request_path=$(awk -F '"' 'NR == 1 { print $2 }' "$batch")
        request_action=$(awk -F '|' '$1 == "action-id" { print $2; exit }' "$request_path")
        if [ "$request_action" = broker.readiness.v1 ]; then
          cp "$batch" "$u5_fixture_root/u5-windows-submit.batch"
          cp "$request_path" "$u5_fixture_root/u5-windows-readiness-request"
          cp "$(dirname "$request_path")/commit" "$u5_fixture_root/u5-windows-readiness-commit"
        else
          cp "$batch" "$u5_fixture_root/u5-windows-operation-submit.batch"
          cp "$request_path" "$u5_fixture_root/u5-windows-operation-request"
        fi
        return 0
      fi
      cp "$batch" "$u5_fixture_root/u5-windows-poll.batch"
      remote_path=$(awk -F '"' 'NR == 1 { print $2 }' "$batch")
      destination=$(awk -F '"' 'NR == 1 { print $4 }' "$batch")
      case $remote_path in
        /results/request-[0-9a-f]*.result)
          [ -f "$u5_fixture_root/u5-windows-operation-request" ] || return 70
          operation_request=$u5_fixture_root/u5-windows-operation-request
          printf '%s\n' 'windows-broker-public|1' 'state|completed' 'reason|inventory_verified' \
            "request-id|$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$operation_request")" \
            "plan-id|$(awk -F '|' '$1 == "plan-id" { print $2; exit }' "$operation_request")" \
            "action-id|$(awk -F '|' '$1 == "action-id" { print $2; exit }' "$operation_request")" \
            "enrollment-epoch|$(awk -F '|' '$1 == "enrollment-epoch" { print $2; exit }' "$operation_request")" \
            "protected-result-sha256|$u5_readiness_f" 'end-public|' >"$destination"
          return 0
          ;;
        /results/request-[0-9a-f]*.readiness) ;;
        *) return 70 ;;
      esac
      readiness_request=${remote_path#/results/}
      readiness_request=${readiness_request%.readiness}
      readiness_observed=$(windows_poll_clock)
      readiness_expires=$((readiness_observed + 300))
      cat >"$destination" <<EOF
windows-broker-readiness-result|1
request-id|$readiness_request
state|ready
reason|fresh_probes_verified
broker-protocol|1
broker-version|1.0.0
broker-sha256|$u5_readiness_a
policy-version|1
policy-sha256|$u5_readiness_b
constraint-version|1
constraints-sha256|$u5_readiness_c
generation|7
generation-sha256|$u5_readiness_d
winget-context-version|1
winget-context-sha256|$u5_readiness_e
provider-lock-sha256|$u5_readiness_f
request-sid|S-1-5-21-1-2-3-2001
request-principal|RoundhouseRequest
system-task-ready|true
profile-task-ready|true
transport-ready|true
native-canary-ready|true
observed-at|$readiness_observed
expires-at|$readiness_expires
action-count|3
action|profile.apply-managed-bundle.v1|windows-user-s4u-v1|profile-token|$u5_readiness_a
action|profile.inventory-managed-state.v1|windows-user-s4u-v1|profile-token|$u5_readiness_a
action|winget.inventory-machine.v1|windows-system-v1|-|$u5_operation_readiness_digest
profile-constraint-count|1
profile-constraint|profile-token|S-1-5-21-1-2-3-3001|$u5_readiness_d|$u5_readiness_e|$u5_readiness_f|managed-only|100|1048576|$u5_readiness_a
end-readiness|
EOF
      cp "$destination" "$u5_fixture_root/u5-windows-readiness-result"
    )

    privilege_status_command test-windows "$tmp/u5-windows-status.jsonl"
    validate_file "$tmp/u5-windows-status.jsonl"
    jq -e -s '
      ([.[] | select(.kind == "privilege_broker" and .id == "readiness")] | length) == 1 and
      (first(.[] | select(.kind == "privilege_broker" and .id == "readiness")) as $r |
        $r.status == "present" and $r.data.lifecycle_status == "ready" and
        $r.data.transport == "windows-sftp" and $r.data.transport_ready == true and
        $r.data.protected_identity.sid == "S-1-5-21-1-2-3-2001" and
        $r.data.request_principal == "RoundhouseRequest" and
        $r.data.broker_digest.value == ("a" * 64) and
        $r.data.observed_policy_digest.value == ("b" * 64) and
        $r.data.observed_constraints_digest.value == ("c" * 64) and
        $r.data.observed_winget_context_digest.value == ("e" * 64) and
        ($r.data.observed_action_contexts | length) == 3 and
        ($r.data.observed_preconditions | length) == 3 and
        $r.data.policy_proposal_digest == null and $r.data.context_canary_digest == null and
        $r.data.mixed_inventory_authority == false and
        $r.data.originating_node_identity.node_id == "origin-a")
    ' "$tmp/u5-windows-status.jsonl" >/dev/null ||
      fail "U5 signed Windows SFTP readiness did not preserve the exact remote projection"
    grep -Fqx 'action-id|broker.readiness.v1' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'request-sid|S-1-5-21-1-2-3-2001' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'broker-version|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'broker-sha256|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'policy-sha256|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'constraints-sha256|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'precondition-sha256|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'enrollment-epoch|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'winget-context-sha256|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'context-canary-sha256|-' "$tmp/u5-windows-readiness-request" &&
      grep -Fqx 'manager-source-identity|not-applicable' "$tmp/u5-windows-readiness-request" &&
      awk -F '|' '$1 == "created-at" { created=$2 } $1 == "expires-at" { expires=$2 }
        END { exit !(expires-created == 600) }' "$tmp/u5-windows-readiness-request" ||
      fail "U5 Windows readiness request diverged from the closed broker control"
    [ "$(wc -l <"$tmp/u5-windows-submit.batch" | tr -d ' ')" -eq 4 ] &&
      [ "$(basename "$(awk -F '"' 'NR == 4 { print $2 }' "$tmp/u5-windows-submit.batch")")" = commit ] &&
      [ "$(awk -F '"' 'NR == 4 { print $4 }' "$tmp/u5-windows-submit.batch")" = \
        /ingress/slot/commit ] &&
      grep -Eq '^get "/results/request-[0-9a-f]{32}[.]readiness" "[^\"]+"$' \
        "$tmp/u5-windows-poll.batch" &&
      ! grep -Eq '[.]result|/active|/last|(^|[[:space:]])ls([[:space:]]|$)' \
        "$tmp/u5-windows-poll.batch" ||
      fail "U5 Windows readiness widened the four-put or readiness-only SFTP batch"

    set +e
    parse_windows_broker_readiness_result "$tmp/u5-windows-readiness-result" \
      "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
      S-1-5-21-1-2-3-9999 RoundhouseRequest 2000000000 "$tmp/u5-windows-wrong-sid.json"
    u5_wrong_sid_rc=$?
    set -e
    [ "$u5_wrong_sid_rc" -eq 70 ] || fail "U5 Windows readiness accepted a SID other than the configured pin"

    sed -e 's/^observed-at|2000000000$/observed-at|1999999000/' \
      -e 's/^expires-at|2000000300$/expires-at|1999999300/' \
      "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-stale-readiness"
    if parse_windows_broker_readiness_result "$tmp/u5-windows-stale-readiness" \
        "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
        S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 "$tmp/u5-windows-stale.json"; then
      fail "U5 Windows readiness accepted a locally expired result"
    fi
    awk '
      /^action\|profile[.]apply-managed-bundle[.]v1\|/ { first=$0; next }
      /^action\|profile[.]inventory-managed-state[.]v1\|/ { print; print first; next }
      { print }
    ' "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-unsorted-readiness"
    if parse_windows_broker_readiness_result "$tmp/u5-windows-unsorted-readiness" \
        "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
        S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 "$tmp/u5-windows-unsorted.json"; then
      fail "U5 Windows readiness accepted unsorted action rows"
    fi
    sed 's/^action|profile.inventory-managed-state.v1|/action|profile.apply-managed-bundle.v1|/' \
      "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-duplicate-readiness"
    if parse_windows_broker_readiness_result "$tmp/u5-windows-duplicate-readiness" \
        "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
        S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 "$tmp/u5-windows-duplicate.json"; then
      fail "U5 Windows readiness accepted duplicate action/token rows"
    fi
    awk -F '|' -v digest="$u5_readiness_b" 'BEGIN { OFS="|" }
      $1 == "action" && $2 == "profile.inventory-managed-state.v1" { $5=digest }
      { print }
    ' "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-profile-precondition-conflict"
    if parse_windows_broker_readiness_result "$tmp/u5-windows-profile-precondition-conflict" \
        "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
        S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 \
        "$tmp/u5-windows-profile-precondition-conflict.json"; then
      fail "U5 Windows readiness accepted conflicting profile action preconditions"
    fi
    awk -F '|' 'BEGIN { OFS="|" }
      $1 == "profile-constraint" { $10="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
      { print }
    ' "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-profile-precondition-mismatch"
    if parse_windows_broker_readiness_result "$tmp/u5-windows-profile-precondition-mismatch" \
        "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
        S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 \
        "$tmp/u5-windows-profile-precondition-mismatch.json"; then
      fail "U5 Windows readiness accepted inconsistent profile precondition evidence"
    fi
    awk '
      /^action-count\|/ { print "action-count|2"; next }
      /^action\|profile[.]inventory-managed-state[.]v1\|/ { next }
      { print }
    ' "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-profile-apply-only-readiness"
    parse_windows_broker_readiness_result "$tmp/u5-windows-profile-apply-only-readiness" \
      "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-profile-apply-only-readiness")" \
      S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 \
      "$tmp/u5-windows-profile-apply-only.json"
    jq -e '
      (.actions | map(.action_id)) == ["profile.apply-managed-bundle.v1", "winget.inventory-machine.v1"] and
      (.profile_constraints | length) == 1
    ' "$tmp/u5-windows-profile-apply-only.json" >/dev/null ||
      fail "U5 Windows readiness lost apply-only profile authorization"
    awk '
      /^action-count\|/ { print "action-count|2"; next }
      /^action\|profile[.]apply-managed-bundle[.]v1\|/ { next }
      { print }
    ' "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-profile-inventory-only-readiness"
    parse_windows_broker_readiness_result "$tmp/u5-windows-profile-inventory-only-readiness" \
      "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-profile-inventory-only-readiness")" \
      S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 \
      "$tmp/u5-windows-profile-inventory-only.json"
    jq -e '
      (.actions | map(.action_id)) == ["profile.inventory-managed-state.v1", "winget.inventory-machine.v1"] and
      (.profile_constraints | length) == 1
    ' "$tmp/u5-windows-profile-inventory-only.json" >/dev/null ||
      fail "U5 Windows readiness lost inventory-only profile authorization"
    awk '
      /^profile-task-ready\|/ { print "profile-task-ready|false"; next }
      /^action-count\|/ { print "action-count|1"; next }
      /^action\|profile[.]/ { next }
      /^profile-constraint-count\|/ { print "profile-constraint-count|0"; next }
      /^profile-constraint\|/ { next }
      { print }
    ' "$tmp/u5-windows-readiness-result" >"$tmp/u5-windows-machine-only-readiness"
    parse_windows_broker_readiness_result "$tmp/u5-windows-machine-only-readiness" \
      "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-machine-only-readiness")" \
      S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 "$tmp/u5-windows-machine-only.json"
    windows_sftp_readiness_snapshot_from_result test-windows \
      "$tmp/u5-windows-readiness-request" "$tmp/u5-windows-machine-only.json" \
      "$tmp/u5-windows-machine-only.jsonl"
    jq -e -s '
      first(.[] | select(.kind == "privilege_broker" and .id == "readiness")) as $r |
      $r.data.system_task_ready == true and $r.data.profile_task_ready == false and
      $r.data.mixed_inventory_authority == false and
      ($r.data.observed_action_contexts | map(.action_id)) == ["winget.inventory-machine.v1"]
    ' "$tmp/u5-windows-machine-only.jsonl" >/dev/null ||
      fail "U5 machine-only Windows readiness lost its conditional profile-task state"

    # Protected SFTP readiness deliberately omits the action constraint digest.
    # Only the trusted standalone projection may use that null while all sealed
    # profile constraints remain bound.
    jq -n --arg broker "$u5_readiness_b" --arg constraints "$u5_readiness_c" \
      --arg constraint "$u5_readiness_a" --arg entry_map "$u5_readiness_e" '{
      id:"profile.apply-managed-bundle.v1",privilege:{
        policy:{digest:{algorithm:"sha256",value:$broker},
          constraints_digest:{algorithm:"sha256",value:$constraints},
          constraint_digest:$constraint,constraint_generation:7},
        enrollment:{epoch:7},request:{request_sid:"S-1-5-21-1-2-3-2001"},
        action:{policy_token:"profile-token"},
        context:{manager_source_identity:$entry_map}}
    }' >"$tmp/u5-profile-operation.json"
    if profile_authorization_from_snapshot "$tmp/u5-windows-status.jsonl" \
        "$tmp/u5-profile-operation.json" "$tmp/u5-profile-ordinary-authorization.json" \
        >/dev/null 2>&1; then
      fail "U5 ordinary profile authorization accepted an unattested constraint digest"
    fi
    profile_authorization_from_snapshot "$tmp/u5-windows-status.jsonl" \
      "$tmp/u5-profile-operation.json" "$tmp/u5-profile-sftp-authorization.json" true
    jq -e --arg entry_map "$u5_readiness_e" '
      .policy_token == "profile-token" and .target_sid == "S-1-5-21-1-2-3-3001" and
      .entry_map_digest == $entry_map
    ' "$tmp/u5-profile-sftp-authorization.json" >/dev/null ||
      fail "U5 trusted SFTP profile authorization lost its sealed constraints"
    sed 's/^profile-task-ready|false$/profile-task-ready|true/' \
      "$tmp/u5-windows-machine-only-readiness" >"$tmp/u5-windows-machine-only-overclaim"
    if parse_windows_broker_readiness_result "$tmp/u5-windows-machine-only-overclaim" \
        "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-machine-only-overclaim")" \
        S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 \
        "$tmp/u5-windows-machine-only-overclaim.json"; then
      fail "U5 machine-only Windows readiness accepted a profile-task overclaim"
    fi
    printf '%s\n' 'windows-broker-readiness-result|1' \
      "request-id|$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
      'state|unavailable' 'reason|fresh_probe_failed' 'end-readiness|' \
      >"$tmp/u5-windows-unavailable-readiness"
    set +e
    parse_windows_broker_readiness_result "$tmp/u5-windows-unavailable-readiness" \
      "$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/u5-windows-readiness-result")" \
      S-1-5-21-1-2-3-2001 RoundhouseRequest 2000000000 "$tmp/u5-windows-unavailable.json"
    u5_unavailable_rc=$?
    set -e
    [ "$u5_unavailable_rc" -eq 75 ] &&
      [ "$(jq -r '.state+"|"+.reason' "$tmp/u5-windows-unavailable.json")" = \
        'unavailable|fresh_probe_failed' ] ||
      fail "U5 Windows readiness did not preserve the exact unavailable result"

    # A standalone sealed Windows action executes from the sign-in screen over
    # the fixed SFTP broker lane. Ordinary Codex collection remains unavailable
    # and the protected readiness projection remains explicitly non-inventory.
    u5_loggedoff_created=$(jq -nr 'now | todateiso8601')
    u5_loggedoff_expires=$(jq -nr 'now + 600 | todateiso8601')
    u5_loggedoff_config_digest=$(sha256_file "$tmp/u5-config.json")
    executor_status_command "$tmp/u5-loggedoff-executor.json"
    jq -n --slurpfile executor "$tmp/u5-loggedoff-executor.json" \
      --slurpfile origin "$tmp/u5-origin.json" \
      --arg created "$u5_loggedoff_created" --arg expires "$u5_loggedoff_expires" \
      --arg config_digest "$u5_loggedoff_config_digest" \
      --arg broker "$u5_readiness_a" --arg policy "$u5_readiness_b" \
      --arg constraints "$u5_readiness_c" --arg canary "$u5_readiness_d" \
      --arg precondition "$u5_readiness_c" \
      --arg host_key "$(jq -r '.machines["test-windows"].privilege_broker.automation_transport.pinned_host_key_fingerprint' \
        "$tmp/u5-config.json")" '{
      schema:"roundhouse.plan",schema_version:3,created_at:$created,
      domain:"updates",target:"test-windows",
      operations:[{type:"semantic-action",kind:"privileged_action",id:"winget.inventory-machine.v1"}],
      required_section:"packages",planning_snapshot_id:"u5-visible-planning-snapshot",
      planning_observed_at:$created,
      configuration_digest:{algorithm:"sha256",value:$config_digest},
      worker_configuration_digest:{algorithm:"sha256",value:$config_digest},
      precondition_digest:{algorithm:"sha256",value:$precondition},
      required_executor:($executor[0] | {plugin,marketplace,version,integrity_manifest_sha256,files}),
      privilege:{contract_version:1,
        broker:{adapter:"windows-scheduled-task-v1",protocol_version:1,version:"1.0.0",
          digest:{algorithm:"sha256",value:$broker}},
        policy:{catalog_version:1,version:1,action_manifest_version:1,
          digest:{algorithm:"sha256",value:$policy},proposal_digest:{algorithm:"sha256",value:("f" * 64)},
          constraint_kind:"none",constraint_digest:"-",constraint_generation:7,
          constraints_digest:{algorithm:"sha256",value:$constraints}},
        action:{id:"winget.inventory-machine.v1",policy_token:null},
        context:{required:"windows-system-v1",observed_execution_principal:"LocalSystem",
          session_requirement:"no-console-session",platform_boundary:"windows",
          manager_source_identity:"not-applicable",canary_digest:{algorithm:"sha256",value:$canary}},
        request:{id:"request-7123456789abcdef0123456789abcdef",created_at:$created,expires_at:$expires,
          transport:"windows-sftp",principal:"RoundhouseRequest",
          originating_node_id:$origin[0].node_id,node_key_fingerprint:$origin[0].node_key_fingerprint,
          certificate_serial:$origin[0].certificate_serial},
        enrollment:{epoch:7,fleet_domain:$origin[0].fleet_domain,
          fleet_ca_fingerprint:$origin[0].fleet_ca_fingerprint,ca_generation:$origin[0].ca_generation,
          certificate_valid_after:$origin[0].certificate_valid_after,
          certificate_valid_before:$origin[0].certificate_valid_before,
          pinned_host_key_fingerprint:$host_key},
        precondition:{digest:{algorithm:"sha256",value:$precondition}}}
    }' >"$tmp/u5-loggedoff-base.json"
    u5_loggedoff_digest=$(jq -cS . "$tmp/u5-loggedoff-base.json" | sha256_stream)
    u5_loggedoff_plan_id="plan-$(printf '%s' "$u5_loggedoff_digest" | cut -c1-16)"
    jq -S --arg plan_id "$u5_loggedoff_plan_id" --arg digest "$u5_loggedoff_digest" \
      '. + {plan_id:$plan_id,plan_digest:{algorithm:"sha256",value:$digest}}' \
      "$tmp/u5-loggedoff-base.json" >"$tmp/u5-loggedoff-plan.json"
    chmod 600 "$tmp/u5-loggedoff-plan.json"
    validate_privileged_plan_file "$tmp/u5-loggedoff-plan.json"
    mkdir "$tmp/u5-no-codex"
    printf '%s\n' '#!/bin/sh' ': >"${U5_CODEX_COLLECT_MARKER:?}"' 'exit 70' \
      >"$tmp/u5-no-codex/roundhouse"
    chmod +x "$tmp/u5-no-codex/roundhouse"
    export U5_CODEX_COLLECT_MARKER=$tmp/u5-codex-collect-invoked
    rm -f "$U5_CODEX_COLLECT_MARKER" "$tmp/u5-windows-operation-request" \
      "$tmp/u5-windows-operation-submit.batch"
    u5_saved_script_dir=$script_dir
    script_dir=$tmp/u5-no-codex
    windows_poll_clock() { /bin/date -u +%s; }
    apply_privileged_plan_command "$tmp/u5-loggedoff-plan.json" "$u5_loggedoff_plan_id" \
      "$tmp/u5-loggedoff-result.jsonl" false
    script_dir=$u5_saved_script_dir
    [ ! -e "$U5_CODEX_COLLECT_MARKER" ] &&
      [ "$(awk -F '|' '$1 == "action-id" { print $2; exit }' \
        "$tmp/u5-windows-operation-request")" = winget.inventory-machine.v1 ] &&
      [ "$(awk -F '|' '$1 == "precondition-sha256" { print $2; exit }' \
        "$tmp/u5-windows-operation-request")" = "$u5_readiness_c" ] &&
      [ "$(wc -l <"$tmp/u5-windows-operation-submit.batch" | tr -d ' ')" -eq 4 ] &&
      [ "$(awk -F '"' 'NR == 4 { print $4 }' "$tmp/u5-windows-operation-submit.batch")" = \
        /ingress/slot/commit ] ||
      fail "U5 logged-off Windows apply used Codex collection or widened the SFTP slot"
    validate_file "$tmp/u5-loggedoff-result.jsonl"
    jq -e -s '
      first(.[] | select(.kind == "privilege_broker" and .id == "readiness")) as $readiness |
      first(.[] | select(.kind == "operation" and (.id | startswith("apply:plan-")) and
        .data.phase == "verify")) as $apply |
      $readiness.data.mixed_inventory_authority == false and
      $apply.data.operation_status == "completed" and
      $apply.data.post_inventory_status == "protected-readiness-only" and
      $apply.data.transport == "windows-sftp" and
      ($apply.data.authoritative_result_evidence | length) == 1
    ' "$tmp/u5-loggedoff-result.jsonl" >/dev/null ||
      fail "U5 logged-off Windows apply overclaimed inventory or lost protected terminal evidence"

    u5_operation_readiness_digest=$u5_readiness_b
    rm -f "$tmp/u5-windows-operation-request" "$tmp/u5-windows-operation-submit.batch"
    script_dir=$tmp/u5-no-codex
    set +e
    apply_privileged_plan_command "$tmp/u5-loggedoff-plan.json" "$u5_loggedoff_plan_id" \
      "$tmp/u5-loggedoff-drift-result.jsonl" false \
      >"$tmp/u5-loggedoff-drift.stdout" 2>"$tmp/u5-loggedoff-drift.stderr"
    u5_loggedoff_drift_rc=$?
    set -e
    script_dir=$u5_saved_script_dir
    u5_operation_readiness_digest=$u5_readiness_c
    [ "$u5_loggedoff_drift_rc" -eq 65 ] &&
      [ ! -e "$tmp/u5-windows-operation-request" ] &&
      [ ! -e "$tmp/u5-windows-operation-submit.batch" ] ||
      fail "U5 changed Windows readiness after sealing reached an action SFTP slot"

    normalize_privileged_plan_for_broker_execution "$tmp/u5-loggedoff-plan.json" \
      "$tmp/u5-windows-status.jsonl" "$tmp/u5-direct-mixed-plan.json"
    rm -f "$U5_CODEX_COLLECT_MARKER"
    script_dir=$tmp/u5-no-codex
    set +e
    apply_mixed_privileged_plan_command "$tmp/u5-direct-mixed-plan.json" \
      "$u5_loggedoff_plan_id" "$tmp/u5-direct-mixed-result.jsonl" false \
      >"$tmp/u5-direct-mixed.stdout" 2>"$tmp/u5-direct-mixed.stderr"
    u5_direct_mixed_rc=$?
    set -e
    script_dir=$u5_saved_script_dir
    [ "$u5_direct_mixed_rc" -eq 69 ] && [ ! -e "$U5_CODEX_COLLECT_MARKER" ] &&
      grep -Fq 'mixed Windows plans require ordinary Codex inventory' \
        "$tmp/u5-direct-mixed.stderr" ||
      fail "U5 direct mixed Windows plan reached collection or treated SFTP readiness as inventory"

    mkdir -p "$tmp/u5-bad-ssh/bin"
    cat >"$tmp/u5-bad-ssh/bin/ssh" <<'SH'
#!/bin/sh
payload=$(mktemp)
printf '%s\n' 'remote-broker-result' >"$payload"
if command -v sha256sum >/dev/null 2>&1; then digest=$(sha256sum "$payload" | awk '{print $1}')
else digest=$(shasum -a 256 "$payload" | awk '{print $1}'); fi
printf '%s\n' 'posix-dispatch-result|1' 'mode|broker-envelope' 'status|completed' 'exit-code|0' \
  "payload-length|$(wc -c <"$payload" | tr -d ' ')" "payload-sha256|$digest" 'end-header|'
cat "$payload"
rm -f "$payload"
exit 70
SH
    chmod +x "$tmp/u5-bad-ssh/bin/ssh"
    system_ssh_path() { printf '%s\n' "$u5_fixture_root/u5-bad-ssh/bin/ssh"; }
    if invoke_posix_broker_for_target test-apt "$tmp/u5-envelope" "$tmp/u5-bad-output" >/dev/null 2>&1; then
      fail "U5 accepted a protected dispatcher frame whose SSH status did not match"
    fi
  )

  for u5_skill in fleet-inventory fleet-update fleet-agents fleet-auth fleet-chezmoi fleet-projects; do
    u5_skill_file="$script_dir/../skills/$u5_skill/SKILL.md"
    [ "$(sed -n '1p' "$u5_skill_file")" = --- ] &&
      [ "$(sed -n '2p' "$u5_skill_file")" = "name: $u5_skill" ] &&
      [ "$(sed -n '3s/^description: //p' "$u5_skill_file" | wc -c | tr -d ' ')" -gt 1 ] ||
      fail "U5 invalid frontmatter for $u5_skill"
    for u5_term in privilege-status prepare-privilege-identity prepare-privilege-enrollment \
        verify-privilege-plan submit-privilege-plan lookup-privilege-result \
        preview-privilege-upgrade preview-privilege-revocation; do
      grep -Fq "$u5_term" "$u5_skill_file" || fail "U5 $u5_skill omitted $u5_term"
    done
    grep -Eiq 'never (ask for|request).*(sudo|Administrator) password' "$u5_skill_file" ||
      fail "U5 $u5_skill omitted the password boundary"
  done

  for u5_integrity_path in \
      references/privilege-policy.default references/windows-winget-provider.lock \
      scripts/certify-ssh-node scripts/enroll-privilege-posix \
      scripts/enroll-privilege-windows.ps1 scripts/enroll-ssh-posix \
      scripts/enroll-windows-sftp.ps1 scripts/prepare-ssh-identity \
      scripts/privilege-broker-posix scripts/privilege-broker-windows.ps1 \
      scripts/profile-worker-windows.ps1 scripts/register-profile-task-windows.ps1 \
      scripts/windows-native-canary-runner.ps1; do
    jq -e --arg path "$u5_integrity_path" '.files | any(.path == $path)' \
      "$plugin_cache/integrity.json" >/dev/null ||
      fail "U5 release integrity omitted $u5_integrity_path"
  done
  cp "$plugin_cache/scripts/privilege-broker-posix" "$tmp/u5-broker-backup"
  printf '\n# integrity tamper fixture\n' >>"$plugin_cache/scripts/privilege-broker-posix"
  if "$cli" executor-status "$tmp/u5-tampered-executor.json" >/dev/null 2>&1; then
    fail "U5 executor integrity accepted a modified protected broker source"
  fi
  cp "$tmp/u5-broker-backup" "$plugin_cache/scripts/privilege-broker-posix"
}

[ "${ROUNDHOUSE_TEST_SCOPE:-}" != u5-contracts ] || {
  test_u5_contracts
  printf 'PASS: U5 contracts\n'
  exit 0
}
