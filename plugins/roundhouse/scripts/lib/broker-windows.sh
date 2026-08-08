# roundhouse — the Windows privilege broker transport: SFTP slots, readiness
# snapshots, and result polling.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

assert_windows_broker_payload_length() (
  length=$1
  case $length in ''|*[!0-9]*) return 64 ;; esac
  [ "${#length}" -le 8 ] && [ "$length" -le "$maximum_windows_broker_payload_bytes" ] || {
    printf 'roundhouse: Windows broker payload exceeds the protected 64 MiB transport limit\n' >&2
    return 64
  }
)

make_windows_broker_slot() (
  plan=$1
  index=$2
  payload=$3
  slot_root=$4
  profile_snapshot=${5:-}
  trusted_projection=${6:-false}
  if [ "$trusted_projection" != true ]; then
    validate_mixed_privileged_plan_file "$plan"
    mixed_plan_integrity_check "$plan"
  fi
  config=$(config_path)
  identity=$(identity_path)
  check_mutation_config
  validate_node_identity_file "$identity" "$config"
  [ -d "$slot_root" ] && [ ! -L "$slot_root" ] || {
    printf 'roundhouse: Windows broker slot staging root is unavailable\n' >&2
    exit 64
  }
  jq -e --argjson index "$index" '
    .operations[$index] | select(.type == "semantic-action" and
      (.privilege.context.required | startswith("windows-")) and
      .privilege.request.transport == "windows-sftp")
  ' "$plan" >"$slot_root/operation.json" || {
    printf 'roundhouse: operation is not a sealed Windows broker request\n' >&2
    exit 64
  }
  action_id=$(jq -r '.id' "$slot_root/operation.json")
  expected_payload=$(privileged_action_contract_json | jq -r --arg action "$action_id" '.[$action].payload')
  if [ "$payload" = - ]; then
    : >"$slot_root/payload"
  else
    [ -f "$payload" ] && [ ! -L "$payload" ] || {
      printf 'roundhouse: Windows broker payload must be a regular non-symlink file\n' >&2
      exit 64
    }
    assert_windows_broker_payload_length "$(wc -c <"$payload" | tr -d ' ')" || exit $?
    cp "$payload" "$slot_root/payload"
  fi
  payload_length=$(wc -c <"$slot_root/payload" | tr -d ' ')
  assert_windows_broker_payload_length "$payload_length" || exit $?
  if { [ "$expected_payload" = profile-bundle ] && [ "$payload_length" -eq 0 ]; } ||
    { [ "$expected_payload" = empty ] && [ "$payload_length" -ne 0 ]; }; then
    printf 'roundhouse: payload does not match the closed Windows action contract\n' >&2
    exit 64
  fi
  if [ "$expected_payload" = profile-bundle ]; then
    [ -n "$profile_snapshot" ] && [ -f "$profile_snapshot" ] && [ ! -L "$profile_snapshot" ] || {
      printf 'roundhouse: current public profile authorization projection is unavailable\n' >&2
      exit 65
    }
    profile_authorization_from_snapshot "$profile_snapshot" "$slot_root/operation.json" \
      "$slot_root/profile-authorization.json" "$trusted_projection" || exit $?
    validate_profile_bundle_for_operation "$slot_root/payload" "$slot_root/operation.json" \
      "$slot_root/profile-authorization.json" || {
      printf 'roundhouse: profile bundle does not match the sealed request\n' >&2
      exit 64
    }
  fi
  payload_digest=$(sha256_file "$slot_root/payload")
  policy_token=$(jq -r '.privilege.action.policy_token // "-"' "$slot_root/operation.json")
  source_addresses=$(jq -r '
    .privilege.request.certificate_source_addresses | if length == 0 then "-" else join(",") end
  ' "$slot_root/operation.json")
  created_at=$(jq -r '.privilege.request.created_at | fromdateiso8601' "$slot_root/operation.json")
  expires_at=$(jq -r '.privilege.request.expires_at | fromdateiso8601' "$slot_root/operation.json")
  certificate_valid_after=$(jq -r '.privilege.enrollment.certificate_valid_after |
    fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$slot_root/operation.json")
  certificate_valid_before=$(jq -r '.privilege.enrollment.certificate_valid_before |
    fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$slot_root/operation.json")
  {
    printf '%s\n' 'request|1'
    printf 'target-host-id|%s\n' "$(jq -r '.target' "$plan")"
    printf 'request-sid|%s\n' "$(jq -r '.privilege.request.request_sid' "$slot_root/operation.json")"
    printf 'plan-id|%s\n' "$(jq -r '.plan_id' "$plan")"
    printf 'request-id|%s\n' "$(jq -r '.privilege.request.id' "$slot_root/operation.json")"
    printf 'action-id|%s\n' "$action_id"
    printf 'policy-token|%s\n' "$policy_token"
    printf 'broker-protocol|%s\n' "$(jq -r '.privilege.broker.protocol_version' "$slot_root/operation.json")"
    printf 'broker-version|%s\n' "$(jq -r '.privilege.broker.version' "$slot_root/operation.json")"
    printf 'broker-sha256|%s\n' "$(jq -r '.privilege.broker.digest.value' "$slot_root/operation.json")"
    printf 'policy-sha256|%s\n' "$(jq -r '.privilege.policy.digest.value' "$slot_root/operation.json")"
    printf 'constraints-sha256|%s\n' "$(jq -r '.privilege.policy.constraints_digest.value' "$slot_root/operation.json")"
    printf 'payload-length|%s\n' "$payload_length"
    printf 'payload-sha256|%s\n' "$payload_digest"
    printf 'precondition-sha256|%s\n' "$(jq -r '.privilege.precondition.digest.value' "$slot_root/operation.json")"
    printf 'created-at|%s\n' "$created_at"
    printf 'expires-at|%s\n' "$expires_at"
    printf '%s\n' 'transport|windows-sftp'
    printf 'request-principal|%s\n' "$(jq -r '.privilege.request.principal' "$slot_root/operation.json")"
    printf 'required-context|%s\n' "$(jq -r '.privilege.context.required' "$slot_root/operation.json")"
    printf 'observed-execution-principal|%s\n' \
      "$(jq -r '.privilege.context.observed_execution_principal' "$slot_root/operation.json")"
    printf '%s\n' 'console-session-state|none' 'platform-boundary|windows'
    printf 'enrollment-epoch|%s\n' "$(jq -r '.privilege.enrollment.epoch' "$slot_root/operation.json")"
    printf 'winget-context-sha256|%s\n' \
      "$(jq -r '.privilege.context.platform_context_digest.value' "$slot_root/operation.json")"
    printf 'context-canary-sha256|%s\n' "$(jq -r '.privilege.context.canary_digest.value' "$slot_root/operation.json")"
    printf 'pinned-host-key-fingerprint|%s\n' \
      "$(jq -r '.privilege.enrollment.pinned_host_key_fingerprint' "$slot_root/operation.json")"
    printf 'node-id|%s\n' "$(jq -r '.privilege.request.originating_node_id' "$slot_root/operation.json")"
    printf 'fleet-domain|%s\n' "$(jq -r '.privilege.enrollment.fleet_domain' "$slot_root/operation.json")"
    printf 'fleet-ca-fingerprint|%s\n' "$(jq -r '.privilege.enrollment.fleet_ca_fingerprint' "$slot_root/operation.json")"
    printf 'ca-generation|%s\n' "$(jq -r '.privilege.enrollment.ca_generation' "$slot_root/operation.json")"
    printf 'node-key-fingerprint|%s\n' "$(jq -r '.privilege.request.node_key_fingerprint' "$slot_root/operation.json")"
    printf 'certificate-serial|%s\n' "$(jq -r '.privilege.request.certificate_serial' "$slot_root/operation.json")"
    printf 'certificate-valid-after|%s\n' "$certificate_valid_after"
    printf 'certificate-valid-before|%s\n' "$certificate_valid_before"
    printf 'certificate-source-addresses|%s\n' "$source_addresses"
    printf 'manager-source-identity|%s\n' \
      "$(jq -r '.privilege.context.manager_source_identity' "$slot_root/operation.json")"
    printf '%s\n' 'end-request|'
  } >"$slot_root/request"
  certificate_path=$(jq -r '.certificate_path' "$identity")
  ssh_keygen=$(system_ssh_keygen_path)
  SSH_AUTH_SOCK='' "$ssh_keygen" -Y sign -f "$certificate_path" -n roundhouse-request \
    "$slot_root/request" >/dev/null 2>&1
  [ -s "$slot_root/request.sig" ] && [ ! -L "$slot_root/request.sig" ] || {
    printf 'roundhouse: failed to sign Windows broker request\n' >&2
    exit 70
  }
  request_id=$(jq -r '.privilege.request.id' "$slot_root/operation.json")
  request_length=$(wc -c <"$slot_root/request" | tr -d ' ')
  signature_length=$(wc -c <"$slot_root/request.sig" | tr -d ' ')
  {
    printf '%s\n' 'windows-slot-commit|1'
    printf 'request-id|%s\n' "$request_id"
    printf 'request-length|%s\n' "$request_length"
    printf 'request-sha256|%s\n' "$(sha256_file "$slot_root/request")"
    printf 'signature-length|%s\n' "$signature_length"
    printf 'signature-sha256|%s\n' "$(sha256_file "$slot_root/request.sig")"
    printf 'payload-length|%s\n' "$payload_length"
    printf 'payload-sha256|%s\n' "$payload_digest"
    printf '%s\n' 'end-commit|'
  } >"$slot_root/commit"
  rm -f "$slot_root/operation.json" "$slot_root/profile-authorization.json"
)

validate_windows_broker_slot_files() (
  slot_root=$1
  for name in request request.sig payload commit; do
    [ -f "$slot_root/$name" ] && [ ! -L "$slot_root/$name" ] || exit 64
  done
  [ "$(find "$slot_root" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 4 ] &&
    [ "$(find "$slot_root" -mindepth 1 -maxdepth 1 ! -type f | wc -l | tr -d ' ')" -eq 0 ] || exit 64
  request_id=$(awk -F '|' '$1 == "request-id" { if (seen++) exit 1; value=$2 }
    END { if (seen != 1 || value !~ /^request-[0-9a-f]{32}$/) exit 1; print value }' "$slot_root/request") || exit 64
  request_length=$(wc -c <"$slot_root/request" | tr -d ' ')
  signature_length=$(wc -c <"$slot_root/request.sig" | tr -d ' ')
  payload_length=$(wc -c <"$slot_root/payload" | tr -d ' ')
  assert_windows_broker_payload_length "$payload_length" || exit $?
  request_digest=$(sha256_file "$slot_root/request")
  signature_digest=$(sha256_file "$slot_root/request.sig")
  payload_digest=$(sha256_file "$slot_root/payload")
  LC_ALL=C awk -F '|' -v request="$request_id" -v request_length="$request_length" \
    -v request_digest="$request_digest" -v signature_length="$signature_length" \
    -v signature_digest="$signature_digest" -v payload_length="$payload_length" \
    -v payload_digest="$payload_digest" '
    NR == 1 { if ($0 != "windows-slot-commit|1") exit 1; next }
    NR == 2 { if ($1 != "request-id" || $2 != request) exit 1; next }
    NR == 3 { if ($1 != "request-length" || $2 != request_length) exit 1; next }
    NR == 4 { if ($1 != "request-sha256" || $2 != request_digest) exit 1; next }
    NR == 5 { if ($1 != "signature-length" || $2 != signature_length) exit 1; next }
    NR == 6 { if ($1 != "signature-sha256" || $2 != signature_digest) exit 1; next }
    NR == 7 { if ($1 != "payload-length" || $2 != payload_length) exit 1; next }
    NR == 8 { if ($1 != "payload-sha256" || $2 != payload_digest) exit 1; next }
    NR == 9 { if ($0 != "end-commit|") exit 1; ended=1; next }
    { exit 1 }
    END { exit !(ended && NR == 9) }
  ' "$slot_root/commit" || exit 64
  awk -F '|' -v payload_size="$payload_length" -v digest="$payload_digest" '
    $1 == "payload-length" { count_length++; valid_length=($2 == payload_size) }
    $1 == "payload-sha256" { count_digest++; valid_digest=($2 == digest) }
    END { exit !(count_length == 1 && valid_length && count_digest == 1 && valid_digest) }
  ' "$slot_root/request" || exit 64
  ssh_keygen=$(system_ssh_keygen_path)
  SSH_AUTH_SOCK='' "$ssh_keygen" -Y check-novalidate -n roundhouse-request \
    -s "$slot_root/request.sig" <"$slot_root/request" >/dev/null 2>&1 || exit 64
)

make_windows_readiness_slot() (
  target=$1
  slot_root=$2
  umask 077
  config=$(config_path)
  identity=$(identity_path)
  check_mutation_config
  validate_node_identity_file "$identity" "$config"
  [ -d "$slot_root" ] && [ ! -L "$slot_root" ] &&
    [ "$(find "$slot_root" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 0 ] || {
      printf 'roundhouse: Windows readiness slot staging root is unavailable\n' >&2
      exit 64
    }
  route=$(jq -ce --arg target "$target" '
    .machines[$target] |
    select(.platform == "windows" and .transport == "codex-remote-control") |
    .privilege_broker.automation_transport |
    select(.mode == "windows-sftp" and
      (.request_sid | type == "string" and test("^S-[0-9]+(?:-[0-9]+){1,14}$")))
  ' "$config") || {
    printf 'roundhouse: protected Windows readiness requires a pinned Windows SFTP SID\n' >&2
    exit 64
  }
  request_nonce=$(/usr/bin/od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || exit 70
  printf '%s\n' "$request_nonce" | LC_ALL=C grep -Eq '^[0-9a-f]{32}$' || {
    printf 'roundhouse: failed to create a Windows readiness request identity\n' >&2
    exit 70
  }
  request_id="request-$request_nonce"
  plan_digest=$(printf '%s' "$request_id" | sha256_stream)
  plan_id="plan-$(printf '%s' "$plan_digest" | cut -c1-16)"
  created_at=$(windows_poll_clock) || exit 70
  case $created_at in ''|*[!0-9]*) exit 70 ;; esac
  # The broker requires two poll intervals plus its 300-second clock-skew
  # allowance. Six hundred seconds remains inside the normal 3600-second cap.
  expires_at=$((created_at + 600))
  certificate_expires=$(jq -r '.certificate_valid_before | fromdateiso8601' "$identity")
  [ "$certificate_expires" -gt "$expires_at" ] || {
    printf 'roundhouse: node certificate expires before the readiness request\n' >&2
    exit 65
  }
  : >"$slot_root/payload"
  payload_digest=$(sha256_file "$slot_root/payload")
  source_addresses=$(jq -r '
    .certificate_source_addresses | if length == 0 then "-" else join(",") end
  ' "$identity")
  certificate_valid_after=$(jq -r '
    .certificate_valid_after | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")
  ' "$identity")
  certificate_valid_before=$(jq -r '
    .certificate_valid_before | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")
  ' "$identity")
  {
    printf '%s\n' 'request|1'
    printf 'target-host-id|%s\n' "$target"
    printf 'request-sid|%s\n' "$(printf '%s\n' "$route" | jq -r '.request_sid')"
    printf 'plan-id|%s\n' "$plan_id"
    printf 'request-id|%s\n' "$request_id"
    printf '%s\n' 'action-id|broker.readiness.v1'
    printf '%s\n' 'policy-token|-'
    printf '%s\n' 'broker-protocol|1'
    printf '%s\n' 'broker-version|-'
    printf '%s\n' 'broker-sha256|-'
    printf '%s\n' 'policy-sha256|-'
    printf '%s\n' 'constraints-sha256|-'
    printf '%s\n' 'payload-length|0'
    printf 'payload-sha256|%s\n' "$payload_digest"
    printf '%s\n' 'precondition-sha256|-'
    printf 'created-at|%s\n' "$created_at"
    printf 'expires-at|%s\n' "$expires_at"
    printf '%s\n' 'transport|windows-sftp'
    printf 'request-principal|%s\n' "$(printf '%s\n' "$route" | jq -r '.request_user')"
    printf '%s\n' 'required-context|windows-system-v1'
    printf '%s\n' 'observed-execution-principal|LocalSystem'
    printf '%s\n' 'console-session-state|none'
    printf '%s\n' 'platform-boundary|windows'
    printf '%s\n' 'enrollment-epoch|-'
    printf '%s\n' 'winget-context-sha256|-'
    printf '%s\n' 'context-canary-sha256|-'
    printf 'pinned-host-key-fingerprint|%s\n' \
      "$(printf '%s\n' "$route" | jq -r '.pinned_host_key_fingerprint')"
    printf 'node-id|%s\n' "$(jq -r '.node_id' "$identity")"
    printf 'fleet-domain|%s\n' "$(jq -r '.fleet_domain' "$identity")"
    printf 'fleet-ca-fingerprint|%s\n' "$(jq -r '.fleet_ca_fingerprint' "$identity")"
    printf 'ca-generation|%s\n' "$(jq -r '.ca_generation' "$identity")"
    printf 'node-key-fingerprint|%s\n' "$(jq -r '.node_key_fingerprint' "$identity")"
    printf 'certificate-serial|%s\n' "$(jq -r '.certificate_serial' "$identity")"
    printf 'certificate-valid-after|%s\n' "$certificate_valid_after"
    printf 'certificate-valid-before|%s\n' "$certificate_valid_before"
    printf 'certificate-source-addresses|%s\n' "$source_addresses"
    printf '%s\n' 'manager-source-identity|not-applicable'
    printf '%s\n' 'end-request|'
  } >"$slot_root/request"
  certificate_path=$(jq -r '.certificate_path' "$identity")
  ssh_keygen=$(system_ssh_keygen_path)
  SSH_AUTH_SOCK='' "$ssh_keygen" -Y sign -f "$certificate_path" -n roundhouse-request \
    "$slot_root/request" >/dev/null 2>&1
  [ -s "$slot_root/request.sig" ] && [ ! -L "$slot_root/request.sig" ] || {
    printf 'roundhouse: failed to sign Windows readiness request\n' >&2
    exit 70
  }
  request_length=$(wc -c <"$slot_root/request" | tr -d ' ')
  signature_length=$(wc -c <"$slot_root/request.sig" | tr -d ' ')
  {
    printf '%s\n' 'windows-slot-commit|1'
    printf 'request-id|%s\n' "$request_id"
    printf 'request-length|%s\n' "$request_length"
    printf 'request-sha256|%s\n' "$(sha256_file "$slot_root/request")"
    printf 'signature-length|%s\n' "$signature_length"
    printf 'signature-sha256|%s\n' "$(sha256_file "$slot_root/request.sig")"
    printf '%s\n' 'payload-length|0'
    printf 'payload-sha256|%s\n' "$payload_digest"
    printf '%s\n' 'end-commit|'
  } >"$slot_root/commit"
  validate_windows_broker_slot_files "$slot_root" || {
    printf 'roundhouse: Windows readiness slot failed local validation\n' >&2
    exit 70
  }
)

invoke_windows_sftp_batch() {
  host=$1
  port=$2
  request_user=$3
  private_key=$4
  certificate=$5
  known_hosts=$6
  batch=$7
  SSH_AUTH_SOCK='' /usr/bin/sftp -q -b "$batch" -F /dev/null -P "$port" \
    -i "$private_key" \
    -o "CertificateFile=$certificate" -o "UserKnownHostsFile=$known_hosts" \
    -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o PreferredAuthentications=publickey -o ProxyCommand=none -o ProxyJump=none \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=yes -o ControlMaster=no -o ControlPath=none \
    -o ClearAllForwardings=yes -o PermitLocalCommand=no -- "$request_user@$host"
}

windows_sftp_submit_slot() (
  target=$1
  slot_root=$2
  config=$(config_path)
  identity=$(identity_path)
  check_mutation_config
  validate_node_identity_file "$identity" "$config"
  validate_windows_broker_slot_files "$slot_root" || {
    printf 'roundhouse: Windows broker slot changed before transport\n' >&2
    exit 64
  }
  request_id=$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$slot_root/request")
  printf '%s\n' "$request_id" | LC_ALL=C grep -Eq '^request-[0-9a-f]{32}$' || exit 64
  route=$(jq -c --arg target "$target" '.machines[$target].privilege_broker.automation_transport |
    select(.mode == "windows-sftp")' "$config") || {
      printf 'roundhouse: target has no dedicated Windows SFTP route\n' >&2
      exit 64
    }
  host=$(printf '%s\n' "$route" | jq -r '.host')
  port=$(printf '%s\n' "$route" | jq -r '.port')
  request_user=$(printf '%s\n' "$route" | jq -r '.request_user')
  {
    printf 'put "%s" "/ingress/slot/request"\n' "$slot_root/request"
    printf 'put "%s" "/ingress/slot/request.sig"\n' "$slot_root/request.sig"
    printf 'put "%s" "/ingress/slot/payload"\n' "$slot_root/payload"
    # The commit marker is the only claim trigger and is always transferred last.
    printf 'put "%s" "/ingress/slot/commit"\n' "$slot_root/commit"
  } >"$slot_root/submit.batch"
  invoke_windows_sftp_batch "$host" "$port" "$request_user" \
    "$(jq -r '.private_key_path' "$identity")" "$(jq -r '.certificate_path' "$identity")" \
    "$(jq -r '.known_hosts_path' "$identity")" "$slot_root/submit.batch"
)

windows_public_terminal_result() {
  result=$1
  expected_request=$2
  expected_plan=$3
  expected_action=$4
  expected_epoch=$5
  parsed=$(LC_ALL=C awk -F '|' -v request="$expected_request" -v plan="$expected_plan" \
    -v action="$expected_action" -v epoch="$expected_epoch" '
    NR == 1 { if ($0 != "windows-broker-public|1") exit 1; next }
    NR == 2 { if ($1 != "state" || $2 !~ /^(completed|partial|rejected|stale)$/) exit 1; state=$2; next }
    NR == 3 { if ($1 != "reason" || $2 !~ /^[a-z][a-z0-9_]{0,127}$/) exit 1; reason=$2; next }
    NR == 4 { if ($1 != "request-id" || $2 != request) exit 1; next }
    NR == 5 { if ($1 != "plan-id" || $2 != plan) exit 1; next }
    NR == 6 { if ($1 != "action-id" || $2 != action) exit 1; next }
    NR == 7 { if ($1 != "enrollment-epoch" || $2 != epoch) exit 1; next }
    NR == 8 { if ($1 != "protected-result-sha256" || $2 !~ /^[0-9a-f]{64}$/) exit 1; protected=$2; next }
    NR == 9 { if ($0 != "end-public|") exit 1; next }
    { exit 1 }
    END { if (NR != 9) exit 1; print state "|" reason "|windows-protected-result-sha256|" protected }
  ' "$result") || return 1
  printf '%s|%s\n' "$parsed" "$(sha256_file "$result")"
}

windows_poll_sleep() {
  /bin/sleep 60
}

windows_poll_clock() {
  /bin/date -u +%s
}

parse_windows_broker_readiness_result() (
  result=$1
  expected_request=$2
  expected_sid=$3
  expected_principal=$4
  now=$5
  output=$6
  [ -f "$result" ] && [ ! -L "$result" ] &&
    [ "$(wc -c <"$result" | tr -d ' ')" -le 65536 ] &&
    [ "$(tail -c 1 "$result" | wc -l | tr -d ' ')" -eq 1 ] || return 70
  case $now in 0|[1-9][0-9]*) ;; *) return 70 ;; esac
  if LC_ALL=C awk -F '|' -v request="$expected_request" '
    $0 !~ /^[ -~]*$/ || length($0) > 8192 { exit 1 }
    NR == 1 { if ($0 != "windows-broker-readiness-result|1") exit 1; next }
    NR == 2 { if (NF != 2 || $1 != "request-id" || $2 != request) exit 1; next }
    NR == 3 { if ($0 != "state|unavailable") exit 1; next }
    NR == 4 { if ($0 != "reason|fresh_probe_failed") exit 1; next }
    NR == 5 { if ($0 != "end-readiness|") exit 1; ended=1; next }
    { exit 1 }
    END { exit !(ended && NR == 5) }
  ' "$result"; then
    jq -cn --arg request_id "$expected_request" --arg digest "$(sha256_file "$result")" '{
      state:"unavailable",reason:"fresh_probe_failed",request_id:$request_id,result_sha256:$digest
    }' >"$output"
    return 75
  fi
  LC_ALL=C awk -F '|' -v request="$expected_request" -v sid="$expected_sid" \
    -v principal="$expected_principal" -v now="$now" '
    function digest(value) { return value ~ /^[0-9a-f]{64}$/ }
    function uint(value) { return value ~ /^(0|[1-9][0-9]{0,18})$/ }
    function positive(value, maximum) {
      return value ~ /^[1-9][0-9]*$/ && length(value) <= 10 && (value + 0) <= maximum
    }
    function token(value) { return value ~ /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/ }
    function windows_sid(value) { return value ~ /^S-[0-9]+(-[0-9]+){1,14}$/ }
    BEGIN {
      names[1]="request-id"; names[2]="state"; names[3]="reason"
      names[4]="broker-protocol"; names[5]="broker-version"; names[6]="broker-sha256"
      names[7]="policy-version"; names[8]="policy-sha256"; names[9]="constraint-version"
      names[10]="constraints-sha256"; names[11]="generation"; names[12]="generation-sha256"
      names[13]="winget-context-version"; names[14]="winget-context-sha256"
      names[15]="provider-lock-sha256"; names[16]="request-sid"; names[17]="request-principal"
      names[18]="system-task-ready"; names[19]="profile-task-ready"; names[20]="transport-ready"
      names[21]="native-canary-ready"; names[22]="observed-at"; names[23]="expires-at"
      names[24]="action-count"
      context["profile.apply-managed-bundle.v1"]="windows-user-s4u-v1"
      context["profile.inventory-managed-state.v1"]="windows-user-s4u-v1"
      context["winget.install-machine-package.v1"]="windows-system-v1"
      context["winget.inventory-machine.v1"]="windows-system-v1"
      context["winget.upgrade-machine-package.v1"]="windows-system-v1"
    }
    $0 !~ /^[ -~]*$/ || length($0) > 8192 { exit 1 }
    NR == 1 { if ($0 != "windows-broker-readiness-result|1") exit 1; next }
    NR >= 2 && NR <= 25 {
      field_index=NR-1
      if (NF != 2 || $1 != names[field_index]) exit 1
      values[$1]=$2
      if (NR == 25) {
        if (values["request-id"] != request || values["state"] != "ready" ||
            values["reason"] != "fresh_probes_verified" || values["broker-protocol"] != "1" ||
            values["broker-version"] !~ /^[0-9]+[.][0-9]+[.][0-9]+$/ ||
            !digest(values["broker-sha256"]) || values["policy-version"] != "1" ||
            !digest(values["policy-sha256"]) || values["constraint-version"] != "1" ||
            !digest(values["constraints-sha256"]) || !positive(values["generation"],2147483647) ||
            !digest(values["generation-sha256"]) || values["winget-context-version"] != "1" ||
            !digest(values["winget-context-sha256"]) || !digest(values["provider-lock-sha256"]) ||
            values["request-sid"] != sid || !windows_sid(values["request-sid"]) ||
            values["request-principal"] != principal || !token(values["request-principal"]) ||
            values["system-task-ready"] != "true" ||
            (values["profile-task-ready"] != "true" && values["profile-task-ready"] != "false") ||
            values["transport-ready"] != "true" || values["native-canary-ready"] != "true" ||
            !uint(values["observed-at"]) || !uint(values["expires-at"]) ||
            values["expires-at"] + 0 <= values["observed-at"] + 0 ||
            values["expires-at"] - values["observed-at"] > 300 ||
            values["observed-at"] + 0 > now + 300 || values["expires-at"] + 0 <= now ||
            !positive(values["action-count"],64)) exit 1
        action_count=values["action-count"] + 0
      }
      next
    }
    action_seen < action_count {
      if (NF != 5 || $1 != "action" || !($2 in context) || $3 != context[$2] ||
          ($2 == "winget.inventory-machine.v1" && $4 != "-") ||
          ($2 != "winget.inventory-machine.v1" && !token($4)) || !digest($5) ||
          (previous_action != "" && previous_action >= $0) || seen_action[$2 SUBSEP $4]++) exit 1
      previous_action=$0
      if ($2 ~ /^profile[.]/) {
        profile_action_token[$4]=1
        if (($4 in profile_precondition) && profile_precondition[$4] != $5) exit 1
        profile_precondition[$4]=$5
      }
      action_seen++
      next
    }
    !profile_count_seen {
      if (NF != 2 || $1 != "profile-constraint-count" || !uint($2) ||
          length($2) > 2 || ($2 + 0) > 64) exit 1
      profile_count=$2 + 0
      profile_count_seen=1
      next
    }
    profile_seen < profile_count {
      if (NF != 10 || $1 != "profile-constraint" || !token($2) || !windows_sid($3) || $3 == sid ||
          !digest($4) || !digest($5) || !digest($6) ||
          ($7 != "managed-only" && $7 != "managed-and-prune") ||
          !positive($8,100000) || !positive($9,1073741824) || !digest($10) ||
          !($2 in profile_precondition) || $10 != profile_precondition[$2] ||
          (previous_profile != "" && previous_profile >= $0) || seen_profile[$2]++) exit 1
      previous_profile=$0
      profile_constraint_token[$2]=1
      profile_seen++
      next
    }
    {
      if ($0 != "end-readiness|" || ended) exit 1
      ended=1
      next
    }
    END {
      if (!ended || NR != 27 + action_count + profile_count ||
          action_seen != action_count || profile_seen != profile_count) exit 1
      for (value in profile_action_token) if (!profile_constraint_token[value]) exit 1
      for (value in profile_constraint_token) if (!profile_action_token[value]) exit 1
      if ((values["profile-task-ready"] == "true") != (profile_count > 0)) exit 1
    }
  ' "$result" || return 70
  jq -Rsc --arg result_sha256 "$(sha256_file "$result")" '
    split("\n")[:-1] as $lines |
    ($lines[1:25] | map(split("|") | {key:.[0],value:.[1]}) | from_entries) as $fields |
    ($fields["action-count"] | tonumber) as $action_count |
    ($lines[25:25+$action_count] | map(split("|") | {
      action_id:.[1],context_id:.[2],policy_token:.[3],observed_precondition_sha256:.[4]
    })) as $actions |
    ($lines[25+$action_count] | split("|")[1] | tonumber) as $profile_count |
    ($lines[26+$action_count:26+$action_count+$profile_count] | map(split("|") | {
      policy_token:.[1],target_sid:.[2],profile_root_id:.[3],entry_map_digest:.[4],
      marketplace_set_digest:.[5],delete_mode:.[6],max_entries:(.[7]|tonumber),
      max_bytes:(.[8]|tonumber),observed_precondition_sha256:.[9]
    })) as $profiles |
    {
      state:$fields.state,reason:$fields.reason,request_id:$fields["request-id"],
      broker_protocol:($fields["broker-protocol"]|tonumber),broker_version:$fields["broker-version"],
      broker_sha256:$fields["broker-sha256"],policy_version:($fields["policy-version"]|tonumber),
      policy_sha256:$fields["policy-sha256"],constraint_version:($fields["constraint-version"]|tonumber),
      constraints_sha256:$fields["constraints-sha256"],generation:($fields.generation|tonumber),
      generation_sha256:$fields["generation-sha256"],
      winget_context_version:($fields["winget-context-version"]|tonumber),
      winget_context_sha256:$fields["winget-context-sha256"],
      provider_lock_sha256:$fields["provider-lock-sha256"],request_sid:$fields["request-sid"],
      request_principal:$fields["request-principal"],
      system_task_ready:($fields["system-task-ready"] == "true"),
      profile_task_ready:($fields["profile-task-ready"] == "true"),
      transport_ready:($fields["transport-ready"] == "true"),
      native_canary_ready:($fields["native-canary-ready"] == "true"),
      observed_at:($fields["observed-at"]|tonumber),
      expires_at:($fields["expires-at"]|tonumber),actions:$actions,profile_constraints:$profiles,
      result_sha256:$result_sha256
    }
  ' "$result" >"$output"
)

windows_sftp_readiness_unavailable_snapshot() (
  target=$1
  request_id=$2
  reason=$3
  output=$4
  config=$(config_path)
  route=$(jq -ce --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport | select(.mode == "windows-sftp")' \
    "$config") || exit 64
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-windows-readiness-unavailable.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  observed_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
  snapshot_id="windows-readiness-unavailable-$(printf '%s' "$observed_at" | tr -d ':-')-$$"
  config_digest=$(sha256_file "$config")
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" \
    --arg config_digest "$config_digest" '{
      schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"snapshot",id:"snapshot",observed_at:$observed_at,status:"present",confidence:"high",
      data:{configuration_digest:{algorithm:"sha256",value:$config_digest,scope:"raw-bytes"},sections:["host"]},
      evidence:[],errors:[]
    }' >"$tmp/snapshot.jsonl"
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" \
    --arg request_id "$request_id" --arg reason "$reason" \
    --arg request_sid "$(printf '%s\n' "$route" | jq -r '.request_sid')" \
    --arg request_principal "$(printf '%s\n' "$route" | jq -r '.request_user')" \
    --arg pinned_host_key "$(printf '%s\n' "$route" | jq -r '.pinned_host_key_fingerprint')" '{
      schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"privilege_broker",id:"readiness",observed_at:$observed_at,status:"unavailable",confidence:"high",
      data:{contract_version:1,platform_adapter:"windows-scheduled-task-v1",platform_boundary:"windows",
        lifecycle_status:"transport_unavailable",transport:"windows-sftp",transport_ready:false,
        node_identity_ready:false,broker_ready:false,action_context_ready:false,adapter_mechanism_ready:false,
        readiness_request_id:$request_id,readiness_reason:$reason,configured_request_sid:$request_sid,
        request_principal:$request_principal,pinned_host_key_fingerprint:$pinned_host_key,
        mixed_inventory_authority:false},
      evidence:[],errors:[{code:$reason,severity:"error",retryable:true,
        message:"Protected Windows readiness did not return a valid fresh projection"}]
    }' >"$tmp/readiness.jsonl"
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" '{
      schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"operation",id:"collect",observed_at:$observed_at,status:"partial",confidence:"high",
      data:{run_id:$snapshot_id,host_id:$host_id,scope:["host"],phase:"collect",operation_status:"partial",
        transport:"windows-sftp",task_id:null,correlation_id:null},evidence:[],errors:[]
    }' >"$tmp/operation.jsonl"
  jq -sc 'sort_by(.host_id,.kind,.id)[]' "$tmp/snapshot.jsonl" "$tmp/readiness.jsonl" \
    "$tmp/operation.jsonl" >"$tmp/result.jsonl"
  validate_file "$tmp/result.jsonl"
  safe_output "$tmp/result.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

windows_sftp_readiness_snapshot_from_result() (
  target=$1
  request=$2
  parsed=$3
  output=$4
  config=$(config_path)
  identity=$(identity_path)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-windows-readiness-snapshot.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  public_node_identity "$identity" "$config" >"$tmp/origin.json"
  observed_at=$(jq -r '.observed_at | todateiso8601' "$parsed")
  snapshot_id="windows-readiness-$(jq -r '.request_id | sub("^request-";"")' "$parsed")"
  config_digest=$(sha256_file "$config")
  route=$(jq -ce --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport | select(.mode == "windows-sftp")' \
    "$config") || exit 64
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" \
    --arg config_digest "$config_digest" '{
      schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"snapshot",id:"snapshot",observed_at:$observed_at,status:"present",confidence:"high",
      data:{configuration_digest:{algorithm:"sha256",value:$config_digest,scope:"raw-bytes"},sections:["host"]},
      evidence:[],errors:[]
    }' >"$tmp/snapshot.jsonl"
  jq -cn --slurpfile r "$parsed" --slurpfile origin "$tmp/origin.json" \
    --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" \
    --arg pinned_host_key "$(printf '%s\n' "$route" | jq -r '.pinned_host_key_fingerprint')" \
    --arg request_sha256 "$(sha256_file "$request")" '
    def constraint_kind($action):
      if $action == "profile.apply-managed-bundle.v1" or $action == "profile.inventory-managed-state.v1"
      then "profile-bundle-set-sha256"
      elif $action == "winget.install-machine-package.v1" then "winget-package-version-set-sha256"
      elif $action == "winget.upgrade-machine-package.v1" then "winget-package-channel-set-sha256"
      else "none" end;
    $r[0] as $readiness |
    ($readiness.actions | sort_by(.action_id,.context_id) | group_by([.action_id,.context_id]) |
      map(. as $rows | $rows[0] as $first | {
        action_id:$first.action_id,context_id:$first.context_id,
        constraint_kind:constraint_kind($first.action_id),constraint_digest:null,
        manager_source_identity:(if ($first.action_id | startswith("profile.")) then null else "not-applicable" end),
        constraint_generation:$readiness.generation,
        policy_tokens:([$rows[].policy_token | select(. != "-")] | unique),
        profile_constraints:(if ($first.action_id | startswith("profile."))
          then $readiness.profile_constraints else [] end)
      })) as $contexts |
    {
      schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"privilege_broker",id:"readiness",observed_at:$observed_at,status:"present",confidence:"high",
      data:{
        contract_version:1,platform_adapter:"windows-scheduled-task-v1",platform_boundary:"windows",
        lifecycle_status:"ready",transport:"windows-sftp",transport_ready:true,node_identity_ready:true,
        broker_ready:true,action_context_ready:true,protected_artifacts_ready:true,
        adapter_mechanism_ready:true,adapter_verifier_status:"signed-remote-readiness-control",
        transport_receipt_status:"fresh-signed-control",mixed_inventory_authority:false,
        mixed_inventory_note:"ordinary inventory and context-canary capture remain separate",
        request_principal:$readiness.request_principal,
        protected_identity:{host_id:$host_id,sid:$readiness.request_sid,
          request_principal:$readiness.request_principal},
        execution_principals:["LocalSystem","enrolled-s4u-user"],session_requirement:"no-console-session",
        broker_protocol:{supported:[$readiness.broker_protocol],observed:$readiness.broker_protocol},
        broker_version:$readiness.broker_version,
        broker_digest:{algorithm:"sha256",value:$readiness.broker_sha256},
        policy:{catalog_version:1,version:$readiness.policy_version,action_manifest_version:1},
        policy_proposal_digest:null,policy_proposal_status:"not-attested-by-remote-readiness",
        observed_policy_digest:{algorithm:"sha256",value:$readiness.policy_sha256},
        observed_constraints_digest:{algorithm:"sha256",value:$readiness.constraints_sha256},
        observed_winget_context_digest:{algorithm:"sha256",value:$readiness.winget_context_sha256},
        provider_lock_digest:{algorithm:"sha256",value:$readiness.provider_lock_sha256},
        generation_digest:{algorithm:"sha256",value:$readiness.generation_sha256},
        constraint_generation:$readiness.generation,observed_action_contexts:$contexts,
        observed_preconditions:($readiness.actions | map({action_id,policy_token,
          digest:{algorithm:"sha256",value:.observed_precondition_sha256}})),
        context_canary_digest:null,
        node_identity:{node_id:$origin[0].node_id,fleet_domain:$origin[0].fleet_domain,
          node_key_fingerprint:$origin[0].node_key_fingerprint,
          fleet_ca_fingerprint:$origin[0].fleet_ca_fingerprint,ca_generation:$origin[0].ca_generation,
          certificate_serial:$origin[0].certificate_serial,
          certificate_valid_after:$origin[0].certificate_valid_after,
          certificate_valid_before:$origin[0].certificate_valid_before,
          certificate_principals:$origin[0].certificate_principals,
          certificate_source_addresses:$origin[0].certificate_source_addresses},
        originating_node_identity:$origin[0],pinned_host_key_fingerprint:$pinned_host_key,
        enrollment_epoch:$readiness.generation,
        system_task_ready:$readiness.system_task_ready,profile_task_ready:$readiness.profile_task_ready,
        native_canary_ready:$readiness.native_canary_ready,
        independent_native_canary:{ready:true,authority:"fresh-protected-broker-probe"},
        readiness_response:{request_id:$readiness.request_id,state:$readiness.state,reason:$readiness.reason,
          observed_at:($readiness.observed_at|todateiso8601),expires_at:($readiness.expires_at|todateiso8601),
          request_sha256:$request_sha256,result_sha256:$readiness.result_sha256},
        request_ttl:{poll_interval_seconds:60,clock_skew_bound_seconds:300,
          minimum_seconds:420,maximum_seconds:3600},
        readiness_ttl:{maximum_seconds:300}
      },
      evidence:[{source:"fixed-windows-sftp",method:"signed-broker-readiness-control"}],errors:[]
    }
  ' >"$tmp/readiness.jsonl"
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" '{
      schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"operation",id:"collect",observed_at:$observed_at,status:"present",confidence:"high",
      data:{run_id:$snapshot_id,host_id:$host_id,scope:["host"],phase:"collect",operation_status:"completed",
        transport:"windows-sftp",task_id:null,correlation_id:null},evidence:[],errors:[]
    }' >"$tmp/operation.jsonl"
  jq -sc 'sort_by(.host_id,.kind,.id)[]' "$tmp/snapshot.jsonl" "$tmp/readiness.jsonl" \
    "$tmp/operation.jsonl" >"$tmp/result.jsonl"
  validate_file "$tmp/result.jsonl"
  safe_output "$tmp/result.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

windows_sftp_readiness_snapshot() (
  target=$1
  output=$2
  config=$(config_path)
  identity=$(identity_path)
  check_mutation_config
  validate_node_identity_file "$identity" "$config"
  route=$(jq -ce --arg target "$target" '
    .machines[$target] | select(.platform == "windows" and .transport == "codex-remote-control") |
    .privilege_broker.automation_transport | select(.mode == "windows-sftp")
  ' "$config") || {
    printf 'roundhouse: protected Windows readiness requires windows-sftp\n' >&2
    exit 64
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-windows-readiness.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  mkdir "$tmp/slot"
  if ! make_windows_readiness_slot "$target" "$tmp/slot"; then
    windows_sftp_readiness_unavailable_snapshot "$target" - readiness_request_creation_failed "$output"
    exit 70
  fi
  request_id=$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/slot/request")
  if ! windows_sftp_submit_slot "$target" "$tmp/slot"; then
    windows_sftp_readiness_unavailable_snapshot "$target" "$request_id" readiness_submission_failed "$output"
    exit 70
  fi
  printf 'get "/results/%s.readiness" "%s"\n' "$request_id" "$tmp/readiness" >"$tmp/poll.batch"
  expires_at=$(awk -F '|' '$1 == "expires-at" { print $2; exit }' "$tmp/slot/request")
  misses=0
  while [ "$misses" -lt 5 ]; do
    now=$(windows_poll_clock) || exit 70
    case $now in 0|[1-9][0-9]*) ;; *) exit 70 ;; esac
    if [ "$now" -ge "$expires_at" ]; then
      windows_sftp_readiness_unavailable_snapshot "$target" "$request_id" readiness_request_expired "$output"
      exit 70
    fi
    rm -f "$tmp/readiness"
    if invoke_windows_sftp_batch "$(printf '%s\n' "$route" | jq -r '.host')" \
        "$(printf '%s\n' "$route" | jq -r '.port')" \
        "$(printf '%s\n' "$route" | jq -r '.request_user')" \
        "$(jq -r '.private_key_path' "$identity")" "$(jq -r '.certificate_path' "$identity")" \
        "$(jq -r '.known_hosts_path' "$identity")" "$tmp/poll.batch" >/dev/null 2>&1; then
      sftp_result=0
    else
      sftp_result=$?
    fi
    if [ -e "$tmp/readiness" ] && [ "$sftp_result" -ne 0 ]; then
      windows_sftp_readiness_unavailable_snapshot "$target" "$request_id" \
        readiness_transport_status_mismatch "$output"
      exit 70
    fi
    if [ -f "$tmp/readiness" ] && [ ! -L "$tmp/readiness" ]; then
      set +e
      parse_windows_broker_readiness_result "$tmp/readiness" "$request_id" \
        "$(printf '%s\n' "$route" | jq -r '.request_sid')" \
        "$(printf '%s\n' "$route" | jq -r '.request_user')" "$now" "$tmp/parsed.json"
      parse_result=$?
      set -e
      case $parse_result in
        0)
          windows_sftp_readiness_snapshot_from_result "$target" "$tmp/slot/request" \
            "$tmp/parsed.json" "$output"
          trap - EXIT HUP INT TERM
          rm -rf "$tmp"
          return 0
          ;;
        75)
          windows_sftp_readiness_unavailable_snapshot "$target" "$request_id" \
            fresh_probe_failed "$output"
          exit 70
          ;;
        *)
          windows_sftp_readiness_unavailable_snapshot "$target" "$request_id" \
            invalid_readiness_response "$output"
          exit 70
          ;;
      esac
    fi
    misses=$((misses + 1))
    [ "$misses" -ge 5 ] || windows_poll_sleep
  done
  windows_sftp_readiness_unavailable_snapshot "$target" "$request_id" \
    readiness_transport_unavailable "$output"
  exit 70
)

windows_sftp_poll_result() (
  target=$1
  plan=$2
  index=$3
  destination=$4
  trusted_projection=${5:-false}
  poll_mode=${6:-apply}
  case $poll_mode in apply|lookup) ;; *) exit 64 ;; esac
  config=$(config_path)
  identity=$(identity_path)
  check_mutation_config
  if [ "$trusted_projection" != true ]; then
    validate_mixed_privileged_plan_file "$plan"
    mixed_plan_integrity_check "$plan"
  fi
  validate_node_identity_file "$identity" "$config"
  request_id=$(jq -r --argjson index "$index" '.operations[$index].privilege.request.id' "$plan")
  plan_id=$(jq -r '.plan_id' "$plan")
  action_id=$(jq -r --argjson index "$index" '.operations[$index].id' "$plan")
  epoch=$(jq -r --argjson index "$index" '.operations[$index].privilege.enrollment.epoch' "$plan")
  expires_at=$(jq -r --argjson index "$index" \
    '.operations[$index].privilege.request.expires_at | fromdateiso8601' "$plan")
  route=$(jq -c --arg target "$target" '.machines[$target].privilege_broker.automation_transport |
    select(.mode == "windows-sftp")' "$config") || exit 64
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-windows-poll.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  printf 'get "/results/%s.result" "%s"\n' "$request_id" "$tmp/result" >"$tmp/poll.batch"
  misses=0
  while [ "$misses" -lt 5 ]; do
    now=$(windows_poll_clock) || exit 70
    case $now in ''|*[!0-9]*) exit 70 ;; esac
    if [ "$poll_mode" = apply ] && [ "$now" -gt $((expires_at + 300)) ]; then
      printf 'stale|windows_result_expired_without_terminal|-|-|-\n' >"$tmp/outcome"
      safe_output "$tmp/outcome" "$destination"
      exit 70
    fi
    rm -f "$tmp/result"
    invoke_windows_sftp_batch "$(printf '%s\n' "$route" | jq -r '.host')" \
      "$(printf '%s\n' "$route" | jq -r '.port')" "$(printf '%s\n' "$route" | jq -r '.request_user')" \
      "$(jq -r '.private_key_path' "$identity")" "$(jq -r '.certificate_path' "$identity")" \
      "$(jq -r '.known_hosts_path' "$identity")" "$tmp/poll.batch" >/dev/null 2>&1 || true
    if [ -f "$tmp/result" ] && [ ! -L "$tmp/result" ]; then
      terminal=$(windows_public_terminal_result "$tmp/result" "$request_id" "$plan_id" "$action_id" "$epoch") || {
        printf 'stale|windows_public_result_invalid|-|-|%s\n' "$(sha256_file "$tmp/result")" >"$tmp/outcome"
        safe_output "$tmp/outcome" "$destination"
        exit 70
      }
      printf '%s\n' "$terminal" >"$tmp/outcome"
      safe_output "$tmp/outcome" "$destination"
      trap - EXIT HUP INT TERM
      rm -rf "$tmp"
      return 0
    fi
    misses=$((misses + 1))
    [ "$misses" -ge 5 ] || windows_poll_sleep
  done
  printf 'partial|windows_result_queued_or_transport_unavailable|-|-|-\n' >"$tmp/outcome"
  safe_output "$tmp/outcome" "$destination"
  exit 70
)
