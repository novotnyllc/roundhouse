# roundhouse — the POSIX privilege broker transport: framed dispatch requests,
# readiness snapshots, broker envelopes, and expectation records.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

write_posix_dispatch_request() (
  mode=$1
  worker=$2
  request=$3
  output=$4
  case $mode in
    ordinary-plan)
      [ -f "$worker" ] && [ ! -L "$worker" ] || return 64
      ;;
    readiness)
      [ -f "$worker" ] && [ ! -L "$worker" ] || return 64
      ;;
    broker-envelope)
      [ "$worker" = - ] || return 64
      ;;
    *) return 64 ;;
  esac
  [ -f "$request" ] && [ ! -L "$request" ] || return 64
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-posix-dispatch-client.XXXXXX")
  if [ "$mode" = ordinary-plan ] || [ "$mode" = readiness ]; then
    cp "$worker" "$tmp/worker"
  else
    : >"$tmp/worker"
  fi
  {
    printf '%s\n' 'posix-dispatch|1'
    printf 'mode|%s\n' "$mode"
    printf 'worker-length|%s\n' "$(wc -c <"$tmp/worker" | tr -d ' ')"
    printf 'worker-sha256|%s\n' "$(sha256_file "$tmp/worker")"
    printf 'request-length|%s\n' "$(wc -c <"$request" | tr -d ' ')"
    printf 'request-sha256|%s\n' "$(sha256_file "$request")"
    printf '%s\n' 'end-header|'
    cat "$tmp/worker" "$request"
  } >"$tmp/framed"
  safe_output "$tmp/framed" "$output"
  rm -rf "$tmp"
)

write_posix_readiness_request() (
  target=$1
  snapshot_id=$2
  output=$3
  printf '%s\n' "$target" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]{1,128}$' || return 64
  printf '%s\n' "$snapshot_id" | LC_ALL=C grep -Eq '^readiness-[0-9]{8}T[0-9]{6}Z-[1-9][0-9]{0,9}$' || return 64
  {
    printf '%s\n' 'posix-readiness|1'
    printf 'target-host-id|%s\n' "$target"
    printf 'snapshot-id|%s\n' "$snapshot_id"
    printf '%s\n' 'sections|host' 'end-readiness|'
  } >"$output"
)

read_posix_dispatch_result() (
  expected_mode=$1
  response=$2
  payload=$3
  maximum_payload=${4:-8388608}
  [ -f "$response" ] && [ ! -L "$response" ] || return 1
  response_size=$(wc -c <"$response" | tr -d ' ')
  case $response_size in ''|*[!0-9]*) return 1 ;; esac
  [ "$response_size" -le $((maximum_payload + 4096)) ] || return 1
  exec 9<"$response"
  IFS= read -r line_1 <&9 && IFS= read -r line_2 <&9 &&
    IFS= read -r line_3 <&9 && IFS= read -r line_4 <&9 &&
    IFS= read -r line_5 <&9 && IFS= read -r line_6 <&9 &&
    IFS= read -r line_7 <&9 || {
      exec 9<&-
      return 1
    }
  [ "$line_1" = 'posix-dispatch-result|1' ] && [ "$line_7" = 'end-header|' ] || {
    exec 9<&-
    return 1
  }
  mode=${line_2#mode|}
  status=${line_3#status|}
  result_code=${line_4#exit-code|}
  payload_length=${line_5#payload-length|}
  payload_digest=${line_6#payload-sha256|}
  [ "$line_2" = "mode|$mode" ] && [ "$line_3" = "status|$status" ] &&
    [ "$line_4" = "exit-code|$result_code" ] &&
    [ "$line_5" = "payload-length|$payload_length" ] &&
    [ "$line_6" = "payload-sha256|$payload_digest" ] &&
    [ "$mode" = "$expected_mode" ] || {
      exec 9<&-
      return 1
    }
  case $status in completed|partial) ;; *) exec 9<&-; return 1 ;; esac
  case $result_code in 0|[1-9][0-9]*) ;; *) exec 9<&-; return 1 ;; esac
  case $payload_length in 0|[1-9][0-9]*) ;; *) exec 9<&-; return 1 ;; esac
  [ "$result_code" -le 255 ] && [ "$payload_length" -le "$maximum_payload" ] &&
    printf '%s\n' "$payload_digest" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || {
      exec 9<&-
      return 1
    }
  if [ "$result_code" -eq 0 ]; then [ "$status" = completed ] || { exec 9<&-; return 1; }
  else [ "$status" = partial ] || { exec 9<&-; return 1; }
  fi
  : >"$payload"
  dd bs=1 count="$payload_length" of="$payload" <&9 2>/dev/null || {
    exec 9<&-
    return 1
  }
  dd bs=1 count=1 of="${payload}.trailing" <&9 2>/dev/null || true
  exec 9<&-
  [ "$(wc -c <"$payload" | tr -d ' ')" -eq "$payload_length" ] &&
    [ ! -s "${payload}.trailing" ] && [ "$(sha256_file "$payload")" = "$payload_digest" ] || return 1
  rm -f "${payload}.trailing"
  printf '%s|%s\n' "$status" "$result_code"
)

invoke_fixed_posix_dispatch() (
  target=$1
  request=$2
  output=$3
  config=$(config_path)
  identity=$(identity_path)
  validate_config_file
  check_private_owned_file "$config" "collection configuration"
  validate_node_identity_file "$identity" "$config"
  [ -f "$request" ] && [ ! -L "$request" ] || return 64
  route=$(jq -c --arg target "$target" '.machines[$target] | select(.platform | IN("linux","macos")) |
    .privilege_broker.automation_transport | select(.mode == "posix-ssh")' "$config") || {
      printf 'roundhouse: target has no dedicated POSIX SSH route\n' >&2
      return 64
    }
  ssh_client=$(system_ssh_path)
  env -i HOME=/nonexistent PATH=/usr/bin:/bin LC_ALL=C LANG=C TZ=UTC SSH_AUTH_SOCK= \
    "$ssh_client" -F /dev/null -p "$(printf '%s\n' "$route" | jq -r '.port')" \
    -i "$(jq -r '.private_key_path' "$identity")" \
    -o "CertificateFile=$(jq -r '.certificate_path' "$identity")" \
    -o "UserKnownHostsFile=$(jq -r '.known_hosts_path' "$identity")" \
    -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o UpdateHostKeys=no \
    -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o PreferredAuthentications=publickey -o NumberOfPasswordPrompts=0 \
    -o ProxyCommand=none -o ProxyJump=none -o CanonicalizeHostname=no \
    -o RequestTTY=no -o RemoteCommand=none -o EscapeChar=none \
    -o ClearAllForwardings=yes -o ForwardAgent=no -o ForwardX11=no \
    -o ControlMaster=no -o ControlPath=none -o PermitLocalCommand=no \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    -l "$(printf '%s\n' "$route" | jq -r '.request_user')" -- \
    "$(printf '%s\n' "$route" | jq -r '.host')" <"$request" >"$output"
)

prepare_posix_readiness_worker_config() (
  target=$1
  output=$2
  config=$(config_path)
  jq -S --arg target "$target" '{
    version,
    machines:{($target):.machines[$target]},
    projects:{},capabilities:{},skill_roots:[],agent_artifacts:[],auth_artifacts:{},policy:(.policy // {})
  }' "$config" >"$output"
  chmod 600 "$output"
  ROUNDHOUSE_CONFIG="$output" ROUNDHOUSE_IDENTITY="${output}.no-node-identity" \
    "$script_dir/roundhouse" validate-config >/dev/null
)

posix_dispatch_readiness_records() (
  target=$1
  output=$2
  output_snapshot_id=${3:-}
  output_observed_at=${4:-}
  config=$(config_path)
  identity=$(identity_path)
  validate_config_file
  check_private_owned_file "$config" "collection configuration"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-posix-readiness.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  public_node_identity "$identity" "$config" >"$tmp/origin.json"
  route=$(jq -c --arg target "$target" '.machines[$target] | select((.platform | IN("linux","macos")) and .transport == "ssh") |
    .privilege_broker.automation_transport | select(.mode == "posix-ssh")' "$config") || {
      printf 'roundhouse: protected POSIX readiness requires linux or macos over ssh:posix-ssh\n' >&2
      exit 64
    }
  snapshot_id="readiness-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  prepare_posix_readiness_worker_config "$target" "$tmp/worker.json"
  write_posix_readiness_request "$target" "$snapshot_id" "$tmp/request"
  write_posix_dispatch_request readiness "$tmp/worker.json" "$tmp/request" "$tmp/framed"
  set +e
  invoke_fixed_posix_dispatch "$target" "$tmp/framed" "$tmp/response"
  ssh_rc=$?
  set -e
  metadata=$(read_posix_dispatch_result readiness "$tmp/response" "$tmp/raw.jsonl" 1048576) || {
    printf 'roundhouse: protected POSIX readiness response is invalid\n' >&2
    exit 70
  }
  IFS='|' read -r response_status response_code <<EOF
$metadata
EOF
  [ "$response_status" = completed ] && [ "$response_code" -eq 0 ] && [ "$ssh_rc" -eq 0 ] || {
    printf 'roundhouse: protected POSIX readiness did not complete\n' >&2
    exit 70
  }
  jq -e -s --slurpfile origin "$tmp/origin.json" --arg target "$target" --arg snapshot "$snapshot_id" \
    --arg request_principal "$(printf '%s\n' "$route" | jq -r '.request_user')" \
    --arg pinned_host_key "$(printf '%s\n' "$route" | jq -r '.pinned_host_key_fingerprint')" '
    (length > 0) and
    all(.[]; .schema == "roundhouse.inventory" and .schema_version == 1 and
      .host_id == $target and .snapshot_id == $snapshot) and
    ([.[] | select(.kind == "privilege_broker" and .id == "readiness")] | length) == 1 and
    (first(.[] | select(.kind == "privilege_broker" and .id == "readiness")) as $r |
      $r.status == "present" and $r.data.lifecycle_status == "ready" and
      $r.data.transport == "posix-ssh" and $r.data.transport_ready == false and
      $r.data.node_identity_ready == false and $r.data.originating_node_identity == null and
      $r.data.broker_ready == true and $r.data.action_context_ready == true and
      $r.data.adapter_mechanism_ready == true and
      $r.data.protected_identity.host_id == $target and
      ($r.data.protected_identity.uid | type == "number" and floor == . and . >= 1) and
      $r.data.protected_identity.request_principal == $request_principal and
      $r.data.protected_identity.pinned_host_key_fingerprint == $pinned_host_key and
      $r.data.pinned_host_key_fingerprint == $pinned_host_key and
      $r.data.request_principal == $request_principal and
      $r.data.protected_identity.fleet_ca_fingerprint == $origin[0].fleet_ca_fingerprint and
      $r.data.protected_identity.ca_generation == $origin[0].ca_generation)
  ' "$tmp/raw.jsonl" >/dev/null || {
    printf 'roundhouse: protected POSIX readiness binding is invalid\n' >&2
    exit 70
  }
  jq -cS --slurpfile origin "$tmp/origin.json" --arg snapshot "$output_snapshot_id" \
    --arg observed "$output_observed_at" '
    select(.kind == "privilege_broker" and .id == "readiness") |
    if $snapshot != "" then .snapshot_id = $snapshot else . end |
    if $observed != "" then .observed_at = $observed else . end |
    .data.node_identity_ready = true |
    .data.transport_ready = true |
    .data.transport_receipt_status = "forced-dispatcher-readiness" |
    .data.node_identity = {
      node_id:$origin[0].node_id,fleet_domain:$origin[0].fleet_domain,
      node_key_fingerprint:$origin[0].node_key_fingerprint,
      fleet_ca_fingerprint:$origin[0].fleet_ca_fingerprint,ca_generation:$origin[0].ca_generation,
      certificate_serial:$origin[0].certificate_serial,
      certificate_valid_after:$origin[0].certificate_valid_after,
      certificate_valid_before:$origin[0].certificate_valid_before,
      certificate_principals:$origin[0].certificate_principals,
      certificate_source_addresses:$origin[0].certificate_source_addresses
    } |
    .data.originating_node_identity = $origin[0] |
    .evidence += [{source:"fixed-posix-dispatcher",method:"protected-readiness-collector"}]
  ' "$tmp/raw.jsonl" >"$tmp/readiness.jsonl"
  safe_output "$tmp/readiness.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

posix_dispatch_readiness_snapshot() (
  target=$1
  output=$2
  config=$(config_path)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-posix-readiness-snapshot.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  posix_dispatch_readiness_records "$target" "$tmp/readiness.jsonl"
  snapshot_id=$(jq -r '.snapshot_id' "$tmp/readiness.jsonl")
  observed_at=$(jq -r '.observed_at' "$tmp/readiness.jsonl")
  config_digest=$(sha256_file "$config")
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" \
    --arg config_digest "$config_digest" '
    {schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"snapshot",id:"snapshot",observed_at:$observed_at,status:"present",confidence:"high",
      data:{configuration_digest:{algorithm:"sha256",value:$config_digest,scope:"raw-bytes"},sections:["host"]},
      evidence:[],errors:[]}' >"$tmp/snapshot.jsonl"
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed_at" '
    {schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"operation",id:"collect",observed_at:$observed_at,status:"present",confidence:"high",
      data:{run_id:$snapshot_id,host_id:$host_id,scope:["host"],phase:"collect",operation_status:"completed",
        transport:"posix-ssh",task_id:null,correlation_id:null},evidence:[],errors:[]}' >"$tmp/operation.jsonl"
  jq -sc 'sort_by(.host_id,.kind,.id)[]' "$tmp/snapshot.jsonl" "$tmp/readiness.jsonl" \
    "$tmp/operation.jsonl" >"$tmp/result.jsonl"
  validate_file "$tmp/result.jsonl"
  safe_output "$tmp/result.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

emit_posix_dispatch_result() {
  mode=$1
  status=$2
  result_code=$3
  payload=$4
  printf '%s\n' 'posix-dispatch-result|1'
  printf 'mode|%s\n' "$mode"
  printf 'status|%s\n' "$status"
  printf 'exit-code|%s\n' "$result_code"
  printf 'payload-length|%s\n' "$(wc -c <"$payload" | tr -d ' ')"
  printf 'payload-sha256|%s\n' "$(sha256_file "$payload")"
  printf '%s\n' 'end-header|'
  cat "$payload"
}

dispatch_posix_request_command() (
  require_jq
  [ -z "${SSH_ORIGINAL_COMMAND:-}" ] || {
    printf 'roundhouse: the fixed POSIX dispatcher rejects SSH_ORIGINAL_COMMAND\n' >&2
    exit 64
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-posix-dispatch.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  IFS= read -r line_1 && IFS= read -r line_2 && IFS= read -r line_3 &&
    IFS= read -r line_4 && IFS= read -r line_5 && IFS= read -r line_6 && IFS= read -r line_7 || {
      printf 'roundhouse: truncated POSIX dispatcher header\n' >&2
      exit 64
    }
  [ "$line_1" = 'posix-dispatch|1' ] && [ "$line_7" = 'end-header|' ] || {
    printf 'roundhouse: invalid POSIX dispatcher framing\n' >&2
    exit 64
  }
  mode=${line_2#mode|}
  worker_length=${line_3#worker-length|}
  worker_digest=${line_4#worker-sha256|}
  request_length=${line_5#request-length|}
  request_digest=${line_6#request-sha256|}
  [ "$line_2" = "mode|$mode" ] && [ "$line_3" = "worker-length|$worker_length" ] &&
    [ "$line_4" = "worker-sha256|$worker_digest" ] &&
    [ "$line_5" = "request-length|$request_length" ] &&
    [ "$line_6" = "request-sha256|$request_digest" ] || exit 64
  case $mode in ordinary-plan|broker-envelope|readiness) ;; *) exit 64 ;; esac
  case $worker_length:$request_length in
    *[!0-9:]*|:*|*:0) exit 64 ;;
  esac
  [ "$worker_length" -le 1048576 ] && [ "$request_length" -le 8388608 ] || exit 64
  printf '%s\n%s\n' "$worker_digest" "$request_digest" |
    LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || exit 64
  dd bs=1 count="$worker_length" of="$tmp/worker" 2>/dev/null
  dd bs=1 count="$request_length" of="$tmp/request" 2>/dev/null
  dd bs=1 count=1 of="$tmp/trailing" 2>/dev/null || true
  [ "$(wc -c <"$tmp/worker" | tr -d ' ')" -eq "$worker_length" ] &&
    [ "$(wc -c <"$tmp/request" | tr -d ' ')" -eq "$request_length" ] &&
    [ ! -s "$tmp/trailing" ] && [ "$(sha256_file "$tmp/worker")" = "$worker_digest" ] &&
    [ "$(sha256_file "$tmp/request")" = "$request_digest" ] || {
      printf 'roundhouse: POSIX dispatcher length or digest mismatch\n' >&2
      exit 64
    }
  chmod 600 "$tmp/worker" "$tmp/request"
  result_code=0
  case $mode in
    ordinary-plan)
      [ "$worker_length" -gt 0 ] || exit 64
      validate_legacy_ssh_plan_file "$tmp/request"
      ROUNDHOUSE_CONFIG="$tmp/worker" apply_plan_command "$tmp/request" \
        "$(jq -r '.plan_id' "$tmp/request")" "$tmp/result" true || result_code=$?
      [ -f "$tmp/result" ] || : >"$tmp/result"
      ;;
    broker-envelope)
      [ "$worker_length" -eq 0 ] && [ "$worker_digest" = "$(printf '' | sha256_stream)" ] || exit 64
      native_platform=$(uname -s)
      case $native_platform in Linux|Darwin) ;; *)
        : >"$tmp/result"
        emit_posix_dispatch_result "$mode" partial 69 "$tmp/result"
        exit 69
      esac
      request_id=$(awk -F '|' '$1 == "request-id" { print $2; exit }' "$tmp/request")
      plan_id=$(awk -F '|' '$1 == "plan-id" { print $2; exit }' "$tmp/request")
      action_id=$(awk -F '|' '$1 == "action-id" { print $2; exit }' "$tmp/request")
      protocol=$(awk -F '|' '$1 == "broker-protocol" { print $2; exit }' "$tmp/request")
      case $native_platform:$action_id in
        Linux:apt.autoremove.v1|Linux:apt.install-package-version.v1|Linux:apt.update-metadata.v1|Linux:apt.upgrade-package.v1|\
        Linux:broker.query-result.v1|Darwin:macos.apply-system-setting.v1|Darwin:macos.install-signed-pkg.v1|\
        Darwin:broker.query-result.v1) ;;
        *) exit 64 ;;
      esac
      invoke_fixed_posix_broker "$tmp/request" "$tmp/result" || result_code=$?
      if [ -s "$tmp/result" ]; then
        result_action=$action_id
        if [ "$action_id" = broker.query-result.v1 ] && [ "$(sed -n '1p' "$tmp/result")" = 'journal|2' ]; then
          result_action=$(awk -F '|' 'NR == 9 && $1 == "action-id" { print $2 }' "$tmp/result")
          case $native_platform:$result_action in
            Linux:apt.autoremove.v1|Linux:apt.install-package-version.v1|Linux:apt.update-metadata.v1|Linux:apt.upgrade-package.v1|\
            Darwin:macos.apply-system-setting.v1|Darwin:macos.install-signed-pkg.v1) ;;
            *) exit 70 ;;
          esac
        fi
        posix_broker_terminal_result "$tmp/result" "$request_id" "$plan_id" "$result_action" true "$protocol" \
          >/dev/null || exit 70
      else
        result_code=70
      fi
      ;;
    readiness)
      [ "$worker_length" -gt 0 ] && [ "$worker_length" -le 262144 ] &&
        [ "$request_length" -le 4096 ] || exit 64
      ROUNDHOUSE_CONFIG="$tmp/worker" ROUNDHOUSE_IDENTITY="$tmp/no-node-identity" \
        "$script_dir/roundhouse" validate-config >/dev/null || exit 64
      readiness_binding=$(jq -er '
        (.machines | keys) as $targets |
        if ((.worker // null) == null and
            ($targets | length) == 1 and
            (.machines[$targets[0]].platform | IN("linux","macos")) and
            (.machines[$targets[0]].transport == "ssh") and
            (.machines[$targets[0]].privilege_broker.automation_transport.mode == "posix-ssh"))
        then $targets[0]
        else error("invalid bounded readiness worker")
        end
      ' "$tmp/worker") || exit 64
      readiness_request=$(LC_ALL=C awk -F '|' '
        function fail() { bad=1; exit 1 }
        NR == 1 { if ($0 != "posix-readiness|1") fail(); next }
        NR == 2 {
          if (NF != 2 || $1 != "target-host-id" || length($2) < 1 || length($2) > 128 ||
              $2 !~ /^[A-Za-z0-9._-]+$/) fail()
          target=$2
          next
        }
        NR == 3 {
          if (NF != 2 || $1 != "snapshot-id" ||
              $2 !~ /^readiness-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[1-9][0-9]*$/) fail()
          snapshot=$2
          next
        }
        NR == 4 { if ($0 != "sections|host") fail(); next }
        NR == 5 { if ($0 != "end-readiness|") fail(); next }
        { fail() }
        END { if (bad || NR != 5) exit 1; print target "|" snapshot }
      ' "$tmp/request") || exit 64
      readiness_target=${readiness_request%%|*}
      readiness_snapshot=${readiness_request#*|}
      [ "$readiness_target" = "$readiness_binding" ] || exit 64
      observed_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) || exit 70
      /usr/bin/env -i HOME=/nonexistent PATH=/usr/bin:/bin LC_ALL=C LANG=C TZ=UTC \
        ROUNDHOUSE_CONFIG="$tmp/worker" ROUNDHOUSE_IDENTITY="$tmp/no-node-identity" \
        ROUNDHOUSE_OBSERVED_AT="$observed_at" \
        "$script_dir/collect-posix" "$tmp/worker" "$readiness_target" "$readiness_snapshot" host \
        >"$tmp/result" || result_code=$?
      [ -f "$tmp/result" ] || : >"$tmp/result"
      ;;
  esac
  if [ "$result_code" -eq 0 ]; then status=completed; else status=partial; fi
  emit_posix_dispatch_result "$mode" "$status" "$result_code" "$tmp/result"
  exit "$result_code"
)

make_posix_broker_envelope() (
  plan=$1
  index=$2
  requested_action=$3
  output=$4
  case $requested_action in
    apt.autoremove.v1|apt.install-package-version.v1|apt.update-metadata.v1|apt.upgrade-package.v1|\
    macos.apply-system-setting.v1|macos.install-signed-pkg.v1|broker.query-result.v1) ;;
    *)
      printf 'roundhouse: unsupported sealed POSIX broker action\n' >&2
      exit 64
      ;;
  esac
  config=$(config_path)
  identity=$(identity_path)
  validate_node_identity_file "$identity" "$config"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-posix-envelope.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  jq -e --argjson index "$index" '
    .operations[$index] | select(.type == "semantic-action" and
      ((.privilege.context.required == "posix-root-v1" and (.id | startswith("apt."))) or
       (.privilege.context.required == "macos-root-v1" and (.id | startswith("macos.")))))
  ' "$plan" >"$tmp/operation.json" || {
    printf 'roundhouse: mixed plan operation is not a supported sealed POSIX action\n' >&2
    exit 64
  }
  sealed_context=$(jq -r '.privilege.context.required' "$tmp/operation.json")
  case $sealed_context in
    posix-root-v1) platform_boundary=linux ;;
    macos-root-v1) platform_boundary=macos ;;
    *) exit 64 ;;
  esac
  # target_uid is an attested property of the protected target readiness
  # projection. It is intentionally not compared with the controller UID:
  # a dedicated broker route can (and normally does) target another host.
  target_uid=$(jq -r '.privilege.request.target_uid' "$tmp/operation.json")
  action_id=$requested_action
  if [ "$action_id" = broker.query-result.v1 ]; then
    policy_token=-
    manager_source_identity=not-applicable
  else
    [ "$(jq -r '.id' "$tmp/operation.json")" = "$action_id" ] || {
      printf 'roundhouse: requested POSIX action does not match the sealed operation\n' >&2
      exit 64
    }
    privilege_protocol_supports_action "$(jq -r '.privilege.broker.protocol_version' "$tmp/operation.json")" \
      "$action_id" || {
      printf 'roundhouse: needs_broker_upgrade\n' >&2
      exit 69
    }
    policy_token=$(jq -r '.privilege.action.policy_token // "-"' "$tmp/operation.json")
    manager_source_identity=$(jq -r '.privilege.context.manager_source_identity' "$tmp/operation.json")
  fi
  request_id=$(jq -r '.privilege.request.id' "$tmp/operation.json")
  plan_id=$(jq -r '.plan_id' "$plan")
  target=$(jq -r '.target' "$plan")
  if [ "$action_id" = broker.query-result.v1 ]; then
    # A recovery query is a fresh signed read-only request, not a replay of
    # the mutation admission timestamp. Terminal journal retention can outlive
    # the broker's five-minute admission-freshness window.
    created_at=$(/bin/date -u +%s)
    case $created_at in
      ''|*[!0-9]*)
        printf 'roundhouse: could not obtain a current POSIX query timestamp\n' >&2
        exit 70
        ;;
    esac
    expires_at=$((created_at + 300))
    jq -e '(.certificate_valid_after | fromdateiso8601) <= now and
      (.certificate_valid_before | fromdateiso8601) > now' "$identity" >/dev/null || {
      printf 'roundhouse: current node certificate is not valid for a POSIX result query\n' >&2
      exit 65
    }
    node_id=$(jq -r '.node_id' "$identity")
    fleet_domain=$(jq -r '.fleet_domain' "$identity")
    fleet_ca_fingerprint=$(jq -r '.fleet_ca_fingerprint' "$identity")
    ca_generation=$(jq -r '.ca_generation' "$identity")
    node_key_fingerprint=$(jq -r '.node_key_fingerprint' "$identity")
    certificate_serial=$(jq -r '.certificate_serial' "$identity")
    certificate_valid_after=$(jq -r '.certificate_valid_after | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$identity")
    certificate_valid_before=$(jq -r '.certificate_valid_before | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$identity")
    source_addresses=$(jq -r '.certificate_source_addresses | if length == 0 then "-" else join(",") end' "$identity")
  else
    created_at=$(jq -r '.privilege.request.created_at | fromdateiso8601' "$tmp/operation.json")
    expires_at=$(jq -r '.privilege.request.expires_at | fromdateiso8601' "$tmp/operation.json")
    node_id=$(jq -r '.privilege.request.originating_node_id' "$tmp/operation.json")
    fleet_domain=$(jq -r '.privilege.enrollment.fleet_domain' "$tmp/operation.json")
    fleet_ca_fingerprint=$(jq -r '.privilege.enrollment.fleet_ca_fingerprint' "$tmp/operation.json")
    ca_generation=$(jq -r '.privilege.enrollment.ca_generation' "$tmp/operation.json")
    node_key_fingerprint=$(jq -r '.privilege.request.node_key_fingerprint' "$tmp/operation.json")
    certificate_serial=$(jq -r '.privilege.request.certificate_serial' "$tmp/operation.json")
    certificate_valid_after=$(jq -r '.privilege.enrollment.certificate_valid_after | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$tmp/operation.json")
    certificate_valid_before=$(jq -r '.privilege.enrollment.certificate_valid_before | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$tmp/operation.json")
    source_addresses=$(jq -r '
      .privilege.request.certificate_source_addresses | if length == 0 then "-" else join(",") end
    ' "$tmp/operation.json")
  fi
  certificate_path=$(jq -r '.certificate_path' "$identity")
  ssh_keygen=$(system_ssh_keygen_path)
  certificate=$(sed -n '1p' "$certificate_path")
  [ -n "$certificate" ] || {
    printf 'roundhouse: node certificate is empty\n' >&2
    exit 64
  }
  {
    printf 'request|1\n'
    printf 'target-host-id|%s\n' "$target"
    printf 'target-uid|%s\n' "$target_uid"
    printf 'plan-id|%s\n' "$plan_id"
    printf 'request-id|%s\n' "$request_id"
    printf 'action-id|%s\n' "$action_id"
    printf 'policy-token|%s\n' "$policy_token"
    printf 'broker-protocol|%s\n' "$(jq -r '.privilege.broker.protocol_version' "$tmp/operation.json")"
    printf 'broker-version|%s\n' "$(jq -r '.privilege.broker.version' "$tmp/operation.json")"
    printf 'broker-sha256|%s\n' "$(jq -r '.privilege.broker.digest.value' "$tmp/operation.json")"
    printf 'policy-sha256|%s\n' "$(jq -r '.privilege.policy.digest.value' "$tmp/operation.json")"
    printf 'constraints-sha256|%s\n' "$(jq -r '.privilege.policy.constraints_digest.value' "$tmp/operation.json")"
    printf 'precondition-sha256|%s\n' "$(jq -r '.privilege.precondition.digest.value' "$tmp/operation.json")"
    printf 'created-at|%s\n' "$created_at"
    printf 'expires-at|%s\n' "$expires_at"
    printf 'transport|posix-ssh\n'
    printf 'request-principal|%s\n' "$(jq -r '.privilege.request.principal' "$tmp/operation.json")"
    printf 'required-context|%s\n' "$sealed_context"
    printf 'observed-execution-principal|root\n'
    printf 'console-session-state|none\n'
    printf 'platform-boundary|%s\n' "$platform_boundary"
    printf 'enrollment-epoch|%s\n' "$(jq -r '.privilege.enrollment.epoch' "$tmp/operation.json")"
    printf 'context-canary-sha256|%s\n' "$(jq -r '.privilege.context.canary_digest.value' "$tmp/operation.json")"
    printf 'pinned-host-key-fingerprint|%s\n' "$(jq -r '.privilege.enrollment.pinned_host_key_fingerprint' "$tmp/operation.json")"
    printf 'node-id|%s\n' "$node_id"
    printf 'fleet-domain|%s\n' "$fleet_domain"
    printf 'fleet-ca-fingerprint|%s\n' "$fleet_ca_fingerprint"
    printf 'ca-generation|%s\n' "$ca_generation"
    printf 'node-key-fingerprint|%s\n' "$node_key_fingerprint"
    printf 'certificate-serial|%s\n' "$certificate_serial"
    printf 'certificate-valid-after|%s\n' "$certificate_valid_after"
    printf 'certificate-valid-before|%s\n' "$certificate_valid_before"
    printf 'certificate-source-addresses|%s\n' "$source_addresses"
    printf 'manager-source-identity|%s\n' "$manager_source_identity"
    printf 'end-request|\n'
  } >"$tmp/request"
  SSH_AUTH_SOCK='' "$ssh_keygen" -Y sign -f "$certificate_path" -n roundhouse-request \
    "$tmp/request" >/dev/null 2>&1
  [ -f "$tmp/request.sig" ] && [ ! -L "$tmp/request.sig" ] || {
    printf 'roundhouse: failed to create sealed POSIX request signature\n' >&2
    exit 70
  }
  sed -n '1,$p' "$tmp/request" >"$tmp/envelope"
  printf 'certificate|%s\nsignature-begin\n' "$certificate" >>"$tmp/envelope"
  sed -n '1,$p' "$tmp/request.sig" >>"$tmp/envelope"
  printf 'end-envelope\n' >>"$tmp/envelope"
  safe_output "$tmp/envelope" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

invoke_fixed_posix_broker() {
  envelope=$1
  output=$2
  [ -x /usr/bin/sudo ] || return 69
  case $(uname -s) in
    Darwin) fixed_broker=/usr/local/libexec/roundhouse/posix-broker ;;
    Linux) fixed_broker=/usr/libexec/roundhouse/posix-broker ;;
    *) return 69 ;;
  esac
  /usr/bin/env -i HOME="$HOME" LC_ALL=C LANG=C TZ=UTC \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin SSH_AUTH_SOCK= \
    /usr/bin/sudo -n "$fixed_broker" <"$envelope" >"$output" 2>"$output.stderr"
}

invoke_posix_broker_for_target() (
  target=$1
  envelope=$2
  output=$3
  config=$(config_path)
  validate_config_file
  check_private_owned_file "$config" "collection configuration"
  [ -f "$envelope" ] && [ ! -L "$envelope" ] || return 64
  platform=$(jq -r --arg target "$target" '.machines[$target].platform // empty' "$config")
  transport=$(jq -r --arg target "$target" '.machines[$target].transport // empty' "$config")
  route=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // empty' "$config")
  case $platform:$transport:$route in
    linux:local:posix-ssh|macos:local:posix-ssh)
      # The only direct sudo path is the explicitly local target route.
      invoke_fixed_posix_broker "$envelope" "$output"
      ;;
    linux:ssh:posix-ssh|macos:ssh:posix-ssh)
      tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-posix-broker-dispatch.XXXXXX")
      trap 'rm -rf "$tmp"' EXIT HUP INT TERM
      write_posix_dispatch_request broker-envelope - "$envelope" "$tmp/framed" || exit 64
      if invoke_fixed_posix_dispatch "$target" "$tmp/framed" "$tmp/response"; then
        ssh_result=0
      else
        ssh_result=$?
      fi
      metadata=$(read_posix_dispatch_result broker-envelope "$tmp/response" "$tmp/payload") || {
        printf 'roundhouse: protected POSIX broker response is invalid\n' >&2
        exit 70
      }
      IFS='|' read -r response_status response_code <<EOF
$metadata
EOF
      [ "$ssh_result" -eq "$response_code" ] || {
        printf 'roundhouse: protected POSIX broker exit status does not match its frame\n' >&2
        exit 70
      }
      case $response_status:$response_code in
        completed:0|partial:*) ;;
        *) exit 70 ;;
      esac
      safe_output "$tmp/payload" "$output"
      trap - EXIT HUP INT TERM
      rm -rf "$tmp"
      return "$response_code"
      ;;
    *)
      printf 'roundhouse: protected POSIX broker has no dedicated target route\n' >&2
      return 69
      ;;
  esac
)

write_posix_journal_expectations() (
  plan=$1
  index=$2
  envelope=$3
  destination=$4
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-journal-expect.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  awk '/^certificate\|/{exit} {print}' "$envelope" >"$tmp/request"
  awk -F '|' '$1 == "certificate" { sub(/^certificate\|/, ""); print; exit }' "$envelope" |
    awk '{ print $1 " " $2 }' >"$tmp/certificate"
  awk '/^signature-begin$/{inside=1; next} /^end-envelope$/{exit} inside {print}' \
    "$envelope" >"$tmp/signature"
  operation=$tmp/operation.json
  jq -e --argjson index "$index" '.operations[$index] | select(.type == "semantic-action")' \
    "$plan" >"$operation"
  source_addresses=$(jq -r '
    .privilege.request.certificate_source_addresses | if length == 0 then "-" else join(",") end
  ' "$operation")
  source_addresses_digest=$(printf '%s\n' "$source_addresses" | sha256_stream)
  created_at=$(jq -r '.privilege.request.created_at | fromdateiso8601' "$operation")
  expires_at=$(jq -r '.privilege.request.expires_at | fromdateiso8601' "$operation")
  required_context=$(jq -r '.privilege.context.required' "$operation")
  platform_boundary=$(jq -r '.privilege.context.platform_boundary' "$operation")
  {
    printf 'request-id|%s\n' "$(jq -r '.privilege.request.id' "$operation")"
    printf 'plan-id|%s\n' "$(jq -r '.plan_id' "$plan")"
    printf 'action-id|%s\n' "$(jq -r '.id' "$operation")"
    printf 'broker-protocol|%s\n' "$(jq -r '.privilege.broker.protocol_version' "$operation")"
    printf 'target-host-id|%s\n' "$(jq -r '.target' "$plan")"
    printf 'target-uid|%s\n' "$(jq -r '.privilege.request.target_uid' "$operation")"
    printf 'broker-version|%s\n' "$(jq -r '.privilege.broker.version' "$operation")"
    printf 'broker-sha256|%s\n' "$(jq -r '.privilege.broker.digest.value' "$operation")"
    printf 'policy-sha256|%s\n' "$(jq -r '.privilege.policy.digest.value' "$operation")"
    printf 'constraints-sha256|%s\n' "$(jq -r '.privilege.policy.constraints_digest.value' "$operation")"
    printf 'precondition-sha256|%s\n' "$(jq -r '.privilege.precondition.digest.value' "$operation")"
    printf 'created-at|%s\nexpires-at|%s\nretain-until|%s\n' "$created_at" "$expires_at" "$((expires_at + 300))"
    printf '%s\n' 'transport|posix-ssh' "required-context|$required_context" \
      'observed-execution-principal|root' 'console-session-state|none' "platform-boundary|$platform_boundary"
    printf 'request-principal|%s\n' "$(jq -r '.privilege.request.principal' "$operation")"
    printf 'enrollment-epoch|%s\n' "$(jq -r '.privilege.enrollment.epoch' "$operation")"
    printf 'context-canary-sha256|%s\n' "$(jq -r '.privilege.context.canary_digest.value' "$operation")"
    printf 'pinned-host-key-fingerprint|%s\n' "$(jq -r '.privilege.enrollment.pinned_host_key_fingerprint' "$operation")"
    printf 'originating-node-id|%s\n' "$(jq -r '.privilege.request.originating_node_id' "$operation")"
    printf 'fleet-domain|%s\n' "$(jq -r '.privilege.enrollment.fleet_domain' "$operation")"
    printf 'fleet-ca-fingerprint|%s\n' "$(jq -r '.privilege.enrollment.fleet_ca_fingerprint' "$operation")"
    printf 'ca-generation|%s\n' "$(jq -r '.privilege.enrollment.ca_generation' "$operation")"
    printf 'node-key-fingerprint|%s\n' "$(jq -r '.privilege.request.node_key_fingerprint' "$operation")"
    printf 'certificate-serial|%s\n' "$(jq -r '.privilege.request.certificate_serial' "$operation")"
    printf 'certificate-valid-after|%s\n' "$(jq -r '.privilege.enrollment.certificate_valid_after | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$operation")"
    printf 'certificate-valid-before|%s\n' "$(jq -r '.privilege.enrollment.certificate_valid_before | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")' "$operation")"
    printf 'source-addresses-sha256|%s\n' "$source_addresses_digest"
    printf 'manager-source-identity|%s\n' "$(jq -r '.privilege.context.manager_source_identity' "$operation")"
    printf 'request-sha256|%s\n' "$(sha256_file "$tmp/request")"
    printf 'certificate-sha256|%s\n' "$(sha256_file "$tmp/certificate")"
    printf 'signature-sha256|%s\n' "$(sha256_file "$tmp/signature")"
  } >"$destination"
)

posix_broker_terminal_result() {
  result_file=$1
  expected_request_id=$2
  expected_plan_id=$3
  expected_action_id=$4
  allow_rejection=${5:-true}
  expected_protocol=${6:-1}
  expectations=${7:-/dev/null}
  parsed=$(LC_ALL=C awk -F '|' -v request="$expected_request_id" -v plan="$expected_plan_id" \
    -v action="$expected_action_id" -v allow_rejection="$allow_rejection" \
    -v protocol="$expected_protocol" -v expectations="$expectations" '
    BEGIN {
      while ((getline line < expectations) > 0) {
        split(line, parts, "|")
        if (parts[1] == "" || seen_expected[parts[1]]++) exit 1
        expected[parts[1]]=substr(line, length(parts[1]) + 2)
      }
      close(expectations)
    }
    function fail() { exit 1 }
    function digest(value) { return value ~ /^[0-9a-f]{64}$/ }
    function dash_digest(value) { return value == "-" || digest(value) }
    function uint(value) { return value ~ /^(0|[1-9][0-9]{0,19})$/ }
    NR == 1 {
      if ($0 == "result|1") mode="result"
      else if ($0 == "journal|2") mode="journal"
      else fail()
      next
    }
    mode == "result" {
      key[2]="state"; key[3]="reason"; key[4]="request-id"; key[5]="plan-id"
      if (NR > 5 || NF != 2 || $1 != key[NR] || $0 !~ /^[ -~]*$/ || length($0) > 4096) fail()
      if (NR == 2 && ($2 != "rejected" || allow_rejection != "true")) fail()
      if (NR == 3 && $2 !~ /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/) fail()
      if (NR == 4 && $2 != request) fail()
      if (NR == 5 && $2 != plan) fail()
      if (NR == 2) state=$2
      if (NR == 3) reason=$2
      next
    }
    mode == "journal" {
      key[2]="sequence"; key[3]="state"; key[4]="reason"; key[5]="effect-phase"; key[6]="retain-until"
      key[7]="request-id"; key[8]="plan-id"; key[9]="action-id"; key[10]="broker-protocol"
      key[11]="target-host-id"; key[12]="target-uid"; key[13]="broker-version"; key[14]="broker-sha256"
      key[15]="policy-sha256"; key[16]="constraints-sha256"; key[17]="precondition-sha256"; key[18]="created-at"
      key[19]="expires-at"; key[20]="transport"; key[21]="request-principal"; key[22]="required-context"
      key[23]="observed-execution-principal"; key[24]="console-session-state"; key[25]="platform-boundary"
      key[26]="enrollment-epoch"; key[27]="context-canary-sha256"; key[28]="pinned-host-key-fingerprint"
      key[29]="originating-node-id"; key[30]="fleet-domain"; key[31]="fleet-ca-fingerprint"; key[32]="ca-generation"
      key[33]="node-key-fingerprint"; key[34]="certificate-serial"; key[35]="certificate-valid-after"
      key[36]="certificate-valid-before"; key[37]="source-addresses-sha256"; key[38]="manager-source-identity"
      key[39]="request-sha256"; key[40]="certificate-sha256"; key[41]="signature-sha256"; key[42]="action-evidence-sha256"
      key[43]="launch-record-sha256"; key[44]="native-pid"; key[45]="native-pgid"; key[46]="native-process-start"
      key[47]="native-boot"; key[48]="native-exit"; key[49]="metadata-sha256"; key[50]="pre-state-sha256"
      key[51]="post-state-sha256"; key[52]="artifact-sha256"; key[53]="closure-sha256"; key[54]="closure-members-sha256"
      key[55]="end-journal"
      if (NR > 55 || NF != 2 || $1 != key[NR] || $0 !~ /^[ -~]*$/ || length($0) > 4096) fail()
      if (NR == 3 && $2 !~ /^(completed|partial|rejected|stale)$/) fail()
      if (NR == 4 && $2 !~ /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/) fail()
      if (NR == 7 && $2 != request) fail()
      if (NR == 8 && $2 != plan) fail()
      if (NR == 9 && $2 != action) fail()
      if (NR == 10 && $2 != protocol) fail()
      if (NR == 55 && $2 != "") fail()
      if ($1 in expected && $2 != expected[$1]) fail()
      if (NR == 2 && (!uint($2) || $2 == 0)) fail()
      if (NR == 5 && $2 !~ /^(none|launch-blocked|possible|exited|verified)$/) fail()
      if ((NR == 6 || NR == 12 || NR == 18 || NR == 19 || NR == 26 || NR == 32 || NR == 34) && !uint($2)) fail()
      if ((NR == 14 || NR == 15 || NR == 16 || NR == 17 || NR == 27 || NR == 37 ||
           NR == 39 || NR == 40 || NR == 41 || NR == 42 || NR == 43 || NR == 46 ||
           NR == 47 || NR == 49 || NR == 50 || NR == 51 || NR == 52 || NR == 53 || NR == 54) &&
          !dash_digest($2)) fail()
      if ((NR == 44 || NR == 45 || NR == 48) && $2 != "-" && !uint($2)) fail()
      if (NR >= 7 && NR <= 38 && NR != 12 && NR != 18 && NR != 19 && NR != 26 && NR != 32 && NR != 34 && $2 == "") fail()
      if (NR == 3) state=$2
      if (NR == 4) reason=$2
      value[$1]=$2
      next
    }
    { fail() }
    END {
      if (mode == "result" && NR == 5) print state "|" reason
      else if (mode == "journal" && NR == 55) {
        if ((state == "completed" &&
             (value["effect-phase"] != "verified" || value["launch-record-sha256"] == "-" ||
              value["native-pid"] == "-" || value["native-pgid"] == "-" ||
              value["native-process-start"] == "-" || value["native-boot"] == "-" ||
              value["native-exit"] == "-" || value["request-sha256"] == "-" ||
              value["certificate-sha256"] == "-" || value["signature-sha256"] == "-" ||
              value["action-evidence-sha256"] == "-" || value["metadata-sha256"] == "-" ||
              value["pre-state-sha256"] == "-" || value["post-state-sha256"] == "-")) ||
            ((state == "completed" || state == "partial") && value["request-sha256"] == "-")) exit 1
        print state "|" reason
      }
      else exit 1
    }
  ' "$result_file") || return 1
  result_digest=$(sha256_file "$result_file")
  if [ "$(sed -n '1p' "$result_file")" = 'journal|2' ]; then
    printf '%s|posix-journal-sha256|%s|%s\n' "$parsed" "$result_digest" "$result_digest"
  else
    printf '%s|posix-rejection-sha256|%s|%s\n' "$parsed" "$result_digest" "$result_digest"
  fi
}

write_posix_result_lookup_expectations() (
  plan=$1
  index=$2
  destination=$3
  operation=$(jq -c --argjson index "$index" '.operations[$index]' "$plan")
  created_at=$(printf '%s\n' "$operation" | jq -r '.privilege.request.created_at | fromdateiso8601')
  expires_at=$(printf '%s\n' "$operation" | jq -r '.privilege.request.expires_at | fromdateiso8601')
  required_context=$(printf '%s\n' "$operation" | jq -r '.privilege.context.required')
  platform_boundary=$(printf '%s\n' "$operation" | jq -r '.privilege.context.platform_boundary')
  {
    printf 'request-id|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.request.id')"
    printf 'plan-id|%s\n' "$(jq -r '.plan_id' "$plan")"
    printf 'action-id|%s\n' "$(printf '%s\n' "$operation" | jq -r '.id')"
    printf 'broker-protocol|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.broker.protocol_version')"
    printf 'target-host-id|%s\n' "$(jq -r '.target' "$plan")"
    printf 'target-uid|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.request.target_uid')"
    printf 'broker-version|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.broker.version')"
    printf 'broker-sha256|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.broker.digest.value')"
    printf 'policy-sha256|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.policy.digest.value')"
    printf 'constraints-sha256|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.policy.constraints_digest.value')"
    printf 'precondition-sha256|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.precondition.digest.value')"
    printf 'created-at|%s\nexpires-at|%s\n' "$created_at" "$expires_at"
    printf '%s\n' 'transport|posix-ssh' "required-context|$required_context" \
      'observed-execution-principal|root' 'console-session-state|none' "platform-boundary|$platform_boundary"
    printf 'request-principal|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.request.principal')"
    printf 'enrollment-epoch|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.enrollment.epoch')"
    printf 'context-canary-sha256|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.context.canary_digest.value')"
    printf 'pinned-host-key-fingerprint|%s\n' \
      "$(printf '%s\n' "$operation" | jq -r '.privilege.enrollment.pinned_host_key_fingerprint')"
    printf 'originating-node-id|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.request.originating_node_id')"
    printf 'fleet-domain|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.enrollment.fleet_domain')"
    printf 'fleet-ca-fingerprint|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.enrollment.fleet_ca_fingerprint')"
    printf 'ca-generation|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.enrollment.ca_generation')"
    printf 'node-key-fingerprint|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.request.node_key_fingerprint')"
    printf 'certificate-serial|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.request.certificate_serial')"
    printf 'certificate-valid-after|%s\n' "$(printf '%s\n' "$operation" | jq -r \
      '.privilege.enrollment.certificate_valid_after | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")')"
    printf 'certificate-valid-before|%s\n' "$(printf '%s\n' "$operation" | jq -r \
      '.privilege.enrollment.certificate_valid_before | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")')"
    printf 'manager-source-identity|%s\n' "$(printf '%s\n' "$operation" | jq -r '.privilege.context.manager_source_identity')"
    if printf '%s\n' "$operation" | jq -e '.privilege.request.certificate_source_addresses != null' >/dev/null; then
      source_addresses=$(printf '%s\n' "$operation" | jq -r \
        '.privilege.request.certificate_source_addresses | if length == 0 then "-" else join(",") end')
      printf 'source-addresses-sha256|%s\n' "$(printf '%s\n' "$source_addresses" | sha256_stream)"
    fi
  } >"$destination"
)
