# roundhouse — node identity, privilege identity and enrollment preparation,
# and the Codex plugin-hook shim.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

identity_path() {
  if [ -n "${ROUNDHOUSE_IDENTITY:-}" ]; then
    printf '%s\n' "$ROUNDHOUSE_IDENTITY"
  else
    printf '%s/roundhouse/identity.json\n' "${XDG_CONFIG_HOME:-"$HOME/.config"}"
  fi
}

validate_node_identity_file() (
  identity=$1
  config=$2
  check_private_owned_file "$identity" "node identity overlay"
  jq -e --slurpfile config "$config" '
    . as $identity |
    type == "object" and
    (keys | sort) == ([
      "ca_generation","certificate_path","certificate_serial",
      "certificate_principals","certificate_source_addresses",
      "certificate_valid_after","certificate_valid_before","enrollment_receipts",
      "fleet_ca_fingerprint","fleet_domain","known_hosts_path","node_id",
      "node_key_fingerprint","private_key_path","schema","schema_version"
    ] | sort) and
    .schema == "roundhouse.node-identity" and .schema_version == 1 and
    (.fleet_domain | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$")) and
    (.node_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    ([.private_key_path,.certificate_path,.known_hosts_path] |
      all(type == "string" and startswith("/") and length <= 4096)) and
    ([.private_key_path,.certificate_path,.known_hosts_path] | unique | length) == 3 and
    (.node_key_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
    (.fleet_ca_fingerprint | test("^SHA256:[A-Za-z0-9+/]{43}=?$")) and
    (.ca_generation | type == "number" and floor == . and . >= 1 and . <= 2147483647) and
    (.certificate_serial | type == "string" and test("^(0|[1-9][0-9]{0,19})$")) and
    (.certificate_principals | type == "array" and length >= 2 and length <= 16 and
      unique == . and all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._@:-]{0,127}$"))) and
    (.certificate_source_addresses | type == "array" and length <= 16 and unique == . and
      all(.[]; type == "string" and test("^[0-9A-Fa-f:.]+/[0-9]{1,3}$"))) and
    ((.node_id + "@" + .fleet_domain) as $signing | .certificate_principals | index($signing) != null) and
    (.certificate_valid_after | type == "string" and fromdateiso8601 > 0 and fromdateiso8601 <= now) and
    (.certificate_valid_before | type == "string" and fromdateiso8601 >
      ($identity.certificate_valid_after | fromdateiso8601)) and
    (.enrollment_receipts | type == "object") and
    ([.enrollment_receipts | to_entries[] |
      (.key | test("^[A-Za-z0-9._-]+$") and
        (($config[0].worker // null) != null or $config[0].machines[.] != null)) and
      (.value | type == "object") and
      (.value | keys | sort) == (["broker_digest","context_canary_digest","enrollment_epoch","policy_digest",
        "winget_context_digest"] | sort) and
      (.value.enrollment_epoch | type == "number" and floor == . and . >= 1 and . <= 2147483647) and
      ([.value.broker_digest,.value.context_canary_digest,.value.policy_digest,.value.winget_context_digest] |
        all(type == "string" and test("^[0-9a-f]{64}$")))
    ] | all) and
    ([.. | strings | length <= 8192 and (test("[[:cntrl:]]") | not)] | all)
  ' "$identity" >/dev/null || {
    printf 'roundhouse: invalid node identity overlay: %s\n' "$identity" >&2
    return 64
  }
  private_key=$(jq -r '.private_key_path' "$identity")
  certificate=$(jq -r '.certificate_path' "$identity")
  known_hosts=$(jq -r '.known_hosts_path' "$identity")
  case $identity in
    /*) ;;
    *)
      printf 'roundhouse: node identity overlay path must be absolute\n' >&2
      exit 64
      ;;
  esac
  for local_path in "$identity" "$private_key" "$certificate" "$known_hosts"; do
    case $local_path in
      "$repository_root"/*|*/.codex/plugins/cache/*|*/.claude/plugins/cache/*|*/CloudStorage/*|*/Dropbox/*|*/OneDrive*/*)
        printf 'roundhouse: node identity path is inside a repository, plugin cache, or synced root\n' >&2
        exit 64
        ;;
    esac
  done
  check_owner_only_file "$private_key" "node private key"
  check_private_owned_file "$certificate" "node certificate"
  check_private_owned_file "$known_hosts" "automation known-hosts file"
  ssh_keygen=$(system_ssh_keygen_path)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-identity.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  if ! {
    "$ssh_keygen" -y -f "$private_key" >"$tmp/private.pub" 2>/dev/null &&
      "$ssh_keygen" -lf "$tmp/private.pub" -E sha256 >"$tmp/private.fingerprint" 2>/dev/null &&
      TZ=UTC "$ssh_keygen" -Lf "$certificate" >"$tmp/certificate.details" 2>/dev/null &&
      "$ssh_keygen" -lf "$certificate" -E sha256 >"$tmp/certificate.fingerprint" 2>/dev/null &&
      "$ssh_keygen" -lf "$known_hosts" -E sha256 >"$tmp/known-hosts.fingerprints" 2>/dev/null
  }; then
      printf 'roundhouse: node identity OpenSSH material is malformed\n' >&2
      exit 64
  fi
  [ -s "$tmp/known-hosts.fingerprints" ] || {
    printf 'roundhouse: automation known-hosts file contains no valid host key\n' >&2
    exit 64
  }
  private_fingerprint=$(awk 'NR == 1 { print $2 }' "$tmp/private.fingerprint")
  certificate_fingerprint=$(awk 'NR == 1 { print $2 }' "$tmp/certificate.fingerprint")
  signing_ca_fingerprint=$(awk '/^[[:space:]]*Signing CA:/ { for (i=1; i<=NF; i++) if ($i ~ /^SHA256:/) { print $i; exit } }' "$tmp/certificate.details")
  certificate_key_id=$(awk -F '"' '/^[[:space:]]*Key ID:/ { print $2; exit }' "$tmp/certificate.details")
  observed_serial=$(awk '/^[[:space:]]*Serial:/ { print $2; exit }' "$tmp/certificate.details")
  observed_valid_after=$(awk '/^[[:space:]]*Valid: from / { print $3 "Z"; exit }' "$tmp/certificate.details")
  observed_valid_before=$(awk '/^[[:space:]]*Valid: from / { print $5 "Z"; exit }' "$tmp/certificate.details")
  awk '
    /^[[:space:]]*Principals:/ { section=1; next }
    /^[[:space:]]*Critical Options:/ { section=0 }
    section {
      sub(/^[[:space:]]+/, "")
      if ($0 != "(none)") print
    }
  ' "$tmp/certificate.details" | LC_ALL=C sort >"$tmp/observed.principals"
  jq -r '.certificate_principals[]' "$identity" | LC_ALL=C sort >"$tmp/expected.principals"
  awk '
    /^[[:space:]]*Critical Options:/ { section=1; next }
    /^[[:space:]]*Extensions:/ { section=0 }
    section {
      sub(/^[[:space:]]+/, "")
      if ($0 != "(none)" && $1 != "source-address") exit 1
      if ($1 == "source-address") {
        count=split($2, addresses, ",")
        for (i=1; i<=count; i++) print addresses[i]
      }
    }
  ' "$tmp/certificate.details" | LC_ALL=C sort >"$tmp/observed.sources" || {
    printf 'roundhouse: node certificate contains an unapproved critical option\n' >&2
    exit 64
  }
  jq -r '.certificate_source_addresses[]' "$identity" | LC_ALL=C sort >"$tmp/expected.sources"
  expected_node_fingerprint=$(jq -r '.node_key_fingerprint' "$identity")
  expected_ca_fingerprint=$(jq -r '.fleet_ca_fingerprint' "$identity")
  expected_key_id=$(jq -r '.node_id + "@" + .fleet_domain' "$identity")
  expected_serial=$(jq -r '.certificate_serial' "$identity")
  expected_valid_after=$(jq -r '.certificate_valid_after' "$identity")
  expected_valid_before=$(jq -r '.certificate_valid_before' "$identity")
  if ! {
    [ "$private_fingerprint" = "$expected_node_fingerprint" ] &&
      [ "$certificate_fingerprint" = "$expected_node_fingerprint" ] &&
      [ "$signing_ca_fingerprint" = "$expected_ca_fingerprint" ] &&
      [ "$certificate_key_id" = "$expected_key_id" ] &&
      [ "$observed_serial" = "$expected_serial" ] &&
      [ "$observed_valid_after" = "$expected_valid_after" ] &&
      [ "$observed_valid_before" = "$expected_valid_before" ] &&
      cmp -s "$tmp/observed.principals" "$tmp/expected.principals" &&
      cmp -s "$tmp/observed.sources" "$tmp/expected.sources" &&
      grep -Eq '^[[:space:]]*Extensions:[[:space:]]+\(none\)[[:space:]]*$' "$tmp/certificate.details"
  }; then
      printf 'roundhouse: node key, certificate, CA, identity, validity, principal, source, or extension mismatch\n' >&2
      exit 64
  fi
  jq -r '
    .machines[] | .privilege_broker.automation_transport // empty |
    [.host,(.port | tostring),.pinned_host_key_fingerprint] | @tsv
  ' "$config" >"$tmp/automation-routes"
  route_number=0
  tab=$(printf '\t')
  while IFS="$tab" read -r route_host route_port route_fingerprint; do
    [ -n "$route_host" ] || continue
    route_number=$((route_number + 1))
    route_lookup="[$route_host]:$route_port"
    if ! "$ssh_keygen" -F "$route_lookup" -f "$known_hosts" \
        >"$tmp/route-$route_number.matches" 2>/dev/null ||
      ! "$ssh_keygen" -lf "$tmp/route-$route_number.matches" -E sha256 \
        >"$tmp/route-$route_number.fingerprints" 2>/dev/null; then
      printf 'roundhouse: automation known-hosts has no key for %s\n' "$route_lookup" >&2
      exit 64
    fi
    awk '{ print $2 }' "$tmp/route-$route_number.fingerprints" | LC_ALL=C sort -u \
      >"$tmp/route-$route_number.unique"
    if [ "$(wc -l <"$tmp/route-$route_number.unique" | tr -d ' ')" -ne 1 ] ||
      [ "$(sed -n '1p' "$tmp/route-$route_number.unique")" != "$route_fingerprint" ]; then
      printf 'roundhouse: automation known-hosts fingerprint does not match route %s\n' "$route_lookup" >&2
      exit 64
    fi
  done <"$tmp/automation-routes"
)

public_node_identity() (
  identity=$1
  config=$2
  validate_node_identity_file "$identity" "$config"
  jq -S '{
    schema:"roundhouse.originating-node-identity",schema_version:1,
    fleet_domain,node_id,node_key_fingerprint,fleet_ca_fingerprint,ca_generation,
    certificate_serial,certificate_valid_after,certificate_valid_before,
    certificate_principals,certificate_source_addresses
  }' "$identity"
)

privilege_status_command() {
  target=$1
  output=$2
  require_jq
  validate_config_file
  config=$(config_path)
  check_private_owned_file "$config" "collection configuration"
  platform=$(jq -r --arg target "$target" '.machines[$target].platform // empty' "$config")
  transport=$(jq -r --arg target "$target" '.machines[$target].transport // empty' "$config")
  route=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // empty' "$config")
  if { [ "$platform" = linux ] || [ "$platform" = macos ]; } &&
    [ "$transport:$route" = ssh:posix-ssh ]; then
    posix_dispatch_readiness_snapshot "$target" "$output"
    return
  fi
  if [ "$platform:$transport:$route" = windows:codex-remote-control:windows-sftp ]; then
    windows_sftp_readiness_snapshot "$target" "$output"
    return
  fi
  # Readiness is emitted by every native collector independently of the
  # requested inventory section. The wrapper deliberately retains the full
  # canonical snapshot so transport errors remain useful evidence.
  collect_command --target "$target" --section host --output "$output"
}

verify_privilege_plan_command() {
  plan=$1
  snapshot=$2
  require_jq
  jq -e '.schema_version == 3 or .schema_version == 4' "$plan" >/dev/null 2>&1 || {
    printf 'roundhouse: verify-privilege-plan requires a sealed privilege plan\n' >&2
    return 64
  }
  verify_preconditions_command "$plan" "$snapshot"
}

submit_privilege_plan_command() {
  plan=$1
  confirmation=$2
  output=$3
  require_jq
  jq -e '.schema_version == 3 or .schema_version == 4' "$plan" >/dev/null 2>&1 || {
    printf 'roundhouse: submit-privilege-plan requires a sealed privilege plan\n' >&2
    return 64
  }
  apply_plan_command "$plan" "$confirmation" "$output"
}

prepare_privilege_identity_command() (
  fleet_domain=$1
  node_id=$2
  endpoint_principals=$3
  source_cidrs=$4
  output=$5
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-identity-prepare.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  "$script_dir/prepare-ssh-identity" prepare "$fleet_domain" "$node_id" \
    "$endpoint_principals" "$source_cidrs" >"$tmp/public-preparation"
  safe_output "$tmp/public-preparation" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

prepare_privilege_enrollment_command() (
  target=$1
  output=$2
  require_jq
  validate_config_file
  config=$(config_path)
  jq -e --arg target "$target" '.machines[$target] != null' "$config" >/dev/null || {
    printf 'roundhouse: unknown enrollment target: %s\n' "$target" >&2
    exit 64
  }
  platform=$(jq -r --arg target "$target" '.machines[$target].platform' "$config")
  route=$(jq -r --arg target "$target" \
    '.machines[$target].privilege_broker.automation_transport.mode // "not-configured"' "$config")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-enrollment-prepare.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  case $platform:$route in
    wsl:*)
      jq -S -n --arg target "$target" --arg route "$route" '{
        schema:"roundhouse.privilege-enrollment-preparation",schema_version:1,
        target:$target,platform:"wsl",route:$route,state:"unsupported",
        reason:"unsupported_security_boundary",activation_performed:false,
        credential_handling:"no_password_or_administrator_credential_requested_or_relayed",
        fixed_entrypoints:[],required_public_artifacts:[],next_action:"use_a_native_linux_or_windows_target"
      }' >"$tmp/preparation"
      safe_output "$tmp/preparation" "$output"
      exit 69
      ;;
    linux:posix-ssh|macos:posix-ssh)
      jq -S -n --arg target "$target" --arg platform "$platform" '{
        schema:"roundhouse.privilege-enrollment-preparation",schema_version:1,
        target:$target,platform:$platform,route:"posix-ssh",state:"needs_human_enrollment",
        reason:"local_passworded_sudo_required",activation_performed:false,
        credential_handling:"agent_stops_before_password_and_never_requests_or_relays_it",
        fixed_entrypoints:[
          {path:"scripts/prepare-ssh-identity",mode:"prepare",elevation:"none"},
          {path:"scripts/certify-ssh-node",mode:"sign",elevation:"isolated_owner_signer"},
          {path:"scripts/enroll-privilege-posix",mode:"preview_then_install",elevation:"local_passworded_sudo"},
          {path:"scripts/enroll-ssh-posix",mode:"preview_then_install",elevation:"local_passworded_sudo"}
        ],
        required_public_artifacts:["certificate-request","fleet-ca.pub","node-certificate",
          "revoked.krl","privilege-policy.default","release-integrity","native-canary-receipts"],
        next_action:"inspect_previews_then_complete_the_local_owner_enrollment_ceremony"
      }' >"$tmp/preparation"
      ;;
    windows:windows-sftp)
      request_sid=$(jq -r --arg target "$target" \
        '.machines[$target].privilege_broker.automation_transport.request_sid' "$config")
      jq -S -n --arg target "$target" --arg request_sid "$request_sid" '{
        schema:"roundhouse.privilege-enrollment-preparation",schema_version:1,
        target:$target,platform:"windows",route:"windows-sftp",state:"needs_human_enrollment",
        reason:"local_uac_required",activation_performed:false,
        configured_request_sid:$request_sid,
        request_sid_source:"authenticated_signed_controller_intent_or_receipt_only",
        credential_handling:"agent_stops_before_uac_and_never_requests_or_relays_an_administrator_credential",
        fixed_entrypoints:[
          {path:"scripts/prepare-ssh-identity",mode:"prepare",elevation:"none_on_originating_node"},
          {path:"scripts/certify-ssh-node",mode:"sign",elevation:"isolated_owner_signer"},
          {path:"scripts/register-profile-task-windows.ps1",mode:"Register",elevation:"target_user_only"},
          {path:"scripts/enroll-privilege-windows.ps1",mode:"Preview_then_Install",elevation:"local_uac"},
          {path:"scripts/enroll-windows-sftp.ps1",mode:"Preview_then_Install",elevation:"local_uac"}
        ],
        required_public_artifacts:["certificate-request","fleet-ca.pub","node-certificate",
          "revoked.krl","privilege-policy.default","windows-winget-provider.lock",
          "release-integrity","native-canary-receipts"],
        next_action:"inspect_both_previews_then_complete_the_local_owner_uac_ceremony"
      }' >"$tmp/preparation"
      ;;
    *)
      jq -S -n --arg target "$target" --arg platform "$platform" --arg route "$route" '{
        schema:"roundhouse.privilege-enrollment-preparation",schema_version:1,
        target:$target,platform:$platform,route:$route,state:"needs_configuration",
        reason:"fixed_automation_route_not_configured",activation_performed:false,
        credential_handling:"no_password_or_administrator_credential_requested_or_relayed",
        fixed_entrypoints:[],required_public_artifacts:[],
        next_action:"configure_the_platform_specific_posix_ssh_or_windows_sftp_route"
      }' >"$tmp/preparation"
      ;;
  esac
  safe_output "$tmp/preparation" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

fleet_node_path() {
  # Scheduled fleet runs normally inherit the scheduler's PATH. Homebrew Node
  # is not on launchd's minimal PATH on every macOS host, so keep the same
  # fixed-path fallback used by the other system tools instead of making hook
  # approval depend on an interactive shell.
  fleet_node=$(command -v node 2>/dev/null || true)
  [ -n "$fleet_node" ] && [ -x "$fleet_node" ] && {
    printf '%s\n' "$fleet_node"
    return 0
  }
  case $(uname -s) in
    Darwin)
      for fleet_node_candidate in /opt/homebrew/bin/node /usr/local/bin/node \
        /usr/bin/node; do
        [ -x "$fleet_node_candidate" ] || continue
        printf '%s\n' "$fleet_node_candidate"
        return 0
      done
      ;;
    Linux)
      for fleet_node_candidate in /usr/local/bin/node /usr/bin/node; do
        [ -x "$fleet_node_candidate" ] || continue
        printf '%s\n' "$fleet_node_candidate"
        return 0
      done
      ;;
  esac
  # Native Windows Claude bundles Node beside claude.exe rather than
  # necessarily exposing it to a scheduled task. Resolve that sibling before
  # declaring automatic hook approval unavailable.
  fleet_claude_bin=$(command -v claude.exe 2>/dev/null ||
    command -v claude 2>/dev/null || true)
  if [ -z "$fleet_claude_bin" ] && command -v cmd.exe >/dev/null 2>&1; then
    fleet_claude_bin=$(cmd.exe /c where claude.exe 2>/dev/null |
      tr -d '\r' | head -1 || true)
  fi
  case $fleet_claude_bin in
    [A-Za-z]:\\*)
      command -v wslpath >/dev/null 2>&1 &&
        fleet_claude_bin=$(wslpath -u "$fleet_claude_bin" 2>/dev/null || true)
      ;;
  esac
  if [ -n "$fleet_claude_bin" ]; then
    fleet_claude_dir=$(CDPATH='' cd -- "$(dirname -- "$fleet_claude_bin")" 2>/dev/null && pwd -P) ||
      fleet_claude_dir=
    for fleet_node_candidate in "$fleet_claude_dir/node.exe" \
      "$fleet_claude_dir/resources/node.exe" \
      "$fleet_claude_dir/../node.exe" \
      "$fleet_claude_dir/../resources/node.exe"; do
      [ -x "$fleet_node_candidate" ] || continue
      printf '%s\n' "$fleet_node_candidate"
      return 0
    done
  fi
  return 69
}

codex_plugin_hooks_command() {
  action=$1
  shift
  plugin_id=$1
  require_jq
  printf '%s\n' "$plugin_id" |
    jq -eR 'test("^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$")' >/dev/null || {
      printf 'roundhouse: invalid Codex plugin ID\n' >&2
      exit 64
    }
  codex_hooks_node=$(fleet_node_path) || {
    printf 'roundhouse: Node.js is required for Codex hook approval\n' >&2
    exit 69
  }
  "$codex_hooks_node" "$script_dir/codex-plugin-hooks.mjs" "$action" "$plugin_id"
}
