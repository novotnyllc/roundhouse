# roundhouse self-check — macOS root actions: the closed catalog, sealed cask
# payloads and enrollment.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

test_macos_privilege_contracts() {
  # macOS-only by construction: it pins platform_boundary=macos, validates the
  # macos-root-v1 privileged-action catalog, and its inline stat stubs use the
  # BSD `stat -f` idiom. The cross-platform lifecycle guard it also exercises is
  # covered on Linux by u2/u4, so skip the whole section off darwin.
  if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf 'skip: macOS privilege contracts run only on darwin\n'
    return 0
  fi
  macos_broker="$plugin_cache/scripts/privilege-broker-posix"
  macos_policy="$plugin_cache/references/privilege-policy.default"
  macos_functions="$tmp/macos-contract-functions.sh"

  {
    cli_function_body privileged_action_contract_json
    cli_function_body validate_privileged_draft
    cli_function_body validate_privileged_plan_file
  } >"$macos_functions"
  # shellcheck source=/dev/null
  . "$macos_functions"
  macos_contracts=$(privileged_action_contract_json)

  jq -e '
    ([to_entries[] | select(.value.context == "macos-root-v1") | .key] | sort) ==
      ["macos.apply-system-setting.v1","macos.install-signed-pkg.v1"] and
    all(."macos.install-signed-pkg.v1", ."macos.apply-system-setting.v1";
      .domain == "updates" and .context == "macos-root-v1" and
      .token == "protected" and .payload == "empty" and .protocols == [1])
  ' <<EOF >/dev/null || fail "macOS root catalog is not exactly the two closed token-only actions"
$macos_contracts
EOF

  macos_app_constraint_record='macos-cask-app|macos.install-signed-pkg.v1|visual-studio-code|Visual Studio Code.app'
  macos_constraint_record="macos-pkg|macos.install-signed-pkg.v1|fixture-cask|sealed-cask-payload-v1|16|$(printf 'a%.0s' {1..64})|com.example.fixture|1.2.3|TEAMID1234|$(printf 'b%.0s' {1..64})|com.example.fixture|1.2.3"
  printf '%s\n%s\n' "$macos_app_constraint_record" "$macos_constraint_record" >"$tmp/macos-constraint-group"
  macos_constraint_digest=$(shasum -a 256 "$tmp/macos-constraint-group" | awk '{print $1}')
  awk -F '|' -v OFS='|' -v digest="$macos_constraint_digest" '
    $2 == "macos.install-signed-pkg.v1" { $4="enabled"; $6=digest } { print }
  ' "$macos_policy" >"$tmp/macos-sealed-policy"
  macos_policy_digest=$(shasum -a 256 "$tmp/macos-sealed-policy" | awk '{print $1}')
  printf 'constraints|1|generation=1|policy-sha256=%s\n%s\n%s\n' \
    "$macos_policy_digest" "$macos_app_constraint_record" "$macos_constraint_record" \
    >"$tmp/macos-sealed.constraints"
  "$cli" inspect-privilege-constraints "$tmp/macos-sealed-policy" \
    "$tmp/macos-sealed.constraints" >"$tmp/macos-sealed-constraints.json"
  jq -e '.actions[] | select(.action_id == "macos.install-signed-pkg.v1") |
    .policy_tokens == ["fixture-cask","visual-studio-code"]' \
    "$tmp/macos-sealed-constraints.json" >/dev/null ||
    fail "sealed package and app-target cask constraints were not accepted canonically"
  macos_invalid_app_constraint=${macos_app_constraint_record/Visual Studio Code.app/..\/Other.app}
  printf '%s\n' "$macos_invalid_app_constraint" >"$tmp/macos-invalid-app-group"
  macos_invalid_app_digest=$(shasum -a 256 "$tmp/macos-invalid-app-group" | awk '{print $1}')
  awk -F '|' -v OFS='|' -v digest="$macos_invalid_app_digest" '
    $2 == "macos.install-signed-pkg.v1" { $4="enabled"; $6=digest } { print }
  ' "$macos_policy" >"$tmp/macos-invalid-app-policy"
  macos_invalid_app_policy_digest=$(shasum -a 256 "$tmp/macos-invalid-app-policy" | awk '{print $1}')
  printf 'constraints|1|generation=1|policy-sha256=%s\n%s\n' \
    "$macos_invalid_app_policy_digest" "$macos_invalid_app_constraint" \
    >"$tmp/macos-invalid-app.constraints"
  if "$cli" inspect-privilege-constraints "$tmp/macos-invalid-app-policy" \
      "$tmp/macos-invalid-app.constraints" >/dev/null 2>&1; then
    fail "protected app-target constraint accepted path traversal"
  fi
  cli_program_contains 'sealed-cask-payload-v1' ||
    fail "sealed cask payload mode is missing from a protected policy parser: $cli"
  for macos_policy_parser in "$macos_broker" \
      "$plugin_cache/scripts/enroll-privilege-posix" "$plugin_cache/scripts/collect-posix" \
      "$plugin_cache/scripts/collect-windows.ps1"; do
    grep -Fq 'sealed-cask-payload-v1' "$macos_policy_parser" ||
      fail "sealed cask payload mode is missing from a protected policy parser: $macos_policy_parser"
  done
  macos_invalid_constraint=${macos_constraint_record/sealed-cask-payload-v1/caller-controlled}
  printf '%s\n' "$macos_invalid_constraint" >"$tmp/macos-invalid-constraint-group"
  macos_invalid_digest=$(shasum -a 256 "$tmp/macos-invalid-constraint-group" | awk '{print $1}')
  awk -F '|' -v OFS='|' -v digest="$macos_invalid_digest" '
    $2 == "macos.install-signed-pkg.v1" { $4="enabled"; $6=digest } { print }
  ' "$macos_policy" >"$tmp/macos-invalid-policy"
  macos_invalid_policy_digest=$(shasum -a 256 "$tmp/macos-invalid-policy" | awk '{print $1}')
  printf 'constraints|1|generation=1|policy-sha256=%s\n%s\n' \
    "$macos_invalid_policy_digest" "$macos_invalid_constraint" >"$tmp/macos-invalid.constraints"
  if "$cli" inspect-privilege-constraints "$tmp/macos-invalid-policy" \
      "$tmp/macos-invalid.constraints" >/dev/null 2>&1; then
    fail "protected policy parser accepted an unknown cask payload mode"
  fi

  for macos_action in macos.install-signed-pkg.v1 macos.apply-system-setting.v1; do
    macos_kind=$(jq -r --arg action "$macos_action" '.[$action].constraint_kind' <<EOF
$macos_contracts
EOF
)
    awk -F '|' -v action="$macos_action" -v kind="$macos_kind" '
      $1=="action" && $2==action && $3=="macos-root-v1" && $4=="disabled" && $5==kind { found++ }
      END { exit found == 1 ? 0 : 1 }
    ' "$macos_policy" || fail "$macos_action is not uniquely default-disabled in macos-root-v1"
  done

  jq '.machines["test-host"].privilege_broker.automation_transport={
      mode:"posix-ssh",host:"mac.example.invalid",port:22,
      request_user:"roundhouse",
      pinned_host_key_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      management_networks:["192.0.2.0/24"]}' "$tmp/config.json" >"$tmp/macos-config.json"
  (
    require_jq() { :; }
    validate_config_file() { :; }
    config_path() { printf '%s\n' "$tmp/macos-config.json"; }
    safe_output() { cp "$1" "$2"; }
    cli_function_body prepare_privilege_enrollment_command >"$tmp/macos-enrollment-function.sh"
    # shellcheck source=/dev/null
    . "$tmp/macos-enrollment-function.sh"
    prepare_privilege_enrollment_command test-host "$tmp/macos-enrollment.json"
  )
  jq -e '
    .platform == "macos" and .route == "posix-ssh" and
    .state == "needs_human_enrollment" and .activation_performed == false and
    (.credential_handling | contains("never_requests_or_relays")) and
    any(.fixed_entrypoints[]; .path == "scripts/enroll-privilege-posix" and
      .elevation == "local_passworded_sudo")
  ' "$tmp/macos-enrollment.json" >/dev/null ||
    fail "macOS privilege enrollment crossed the human/default-disabled boundary"

  macos_expiry=2099-01-01T00:05:00Z
  for macos_action in macos.install-signed-pkg.v1 macos.apply-system-setting.v1; do
    macos_kind=$(jq -r --arg action "$macos_action" '.[$action].constraint_kind' <<EOF
$macos_contracts
EOF
)
    jq -n --arg action "$macos_action" --arg expiry "$macos_expiry" '{
      domain:"updates",target:"test-host",
      operations:[{type:"semantic-action",kind:"privileged_action",id:$action}],
      privilege_request:{action_id:$action,policy_token:"macos-token",
        request_id:"request-0123456789abcdef0123456789abcdef",expires_at:$expiry}
    }' >"$tmp/macos-draft.json"
    validate_privileged_draft "$tmp/macos-draft.json"
    for macos_control in command argv path url dependencies package setting_id setting_value; do
      jq --arg control "$macos_control" '.privilege_request[$control]="caller-controlled"' \
        "$tmp/macos-draft.json" >"$tmp/macos-forbidden-draft.json"
      if validate_privileged_draft "$tmp/macos-forbidden-draft.json" >/dev/null 2>&1; then
        fail "$macos_action accepted request-supplied $macos_control"
      fi
    done

    jq -n --arg action "$macos_action" --arg kind "$macos_kind" '{
      schema:"roundhouse.plan",schema_version:3,created_at:"2026-08-03T00:00:00Z",
      domain:"updates",target:"test-host",required_section:"packages",
      planning_snapshot_id:"macos-contract",planning_observed_at:"2026-08-03T00:00:00Z",
      operations:[{type:"semantic-action",kind:"privileged_action",id:$action}],
      configuration_digest:{algorithm:"sha256",value:("a"*64)},
      worker_configuration_digest:{algorithm:"sha256",value:("b"*64)},
      precondition_digest:{algorithm:"sha256",value:("c"*64)},
      plan_digest:{algorithm:"sha256",value:("d"*64)},plan_id:"plan-0123456789abcdef",
      required_executor:{plugin:"roundhouse",marketplace:"novotnyllc",version:"1.0.0",
        integrity_manifest_sha256:("e"*64),files:[{path:"scripts/privilege-broker-posix",sha256:("f"*64)}]},
      privilege:{contract_version:1,
        action:{id:$action,policy_token:"macos-token"},
        broker:{adapter:"posix-sudo-v1",protocol_version:1,version:"1.0.0",
          digest:{algorithm:"sha256",value:("1"*64)}},
        policy:{catalog_version:1,version:1,action_manifest_version:1,
          digest:{algorithm:"sha256",value:("2"*64)},proposal_digest:{algorithm:"sha256",value:("3"*64)},
          constraints_digest:{algorithm:"sha256",value:("4"*64)},constraint_generation:1,
          constraint_kind:$kind,constraint_digest:("5"*64)},
        context:{required:"macos-root-v1",observed_execution_principal:"root",
          platform_boundary:"macos",session_requirement:"no-console-session",
          manager_source_identity:("5"*64),canary_digest:{algorithm:"sha256",value:("6"*64)}},
        request:{id:"request-0123456789abcdef0123456789abcdef",created_at:"2026-08-03T00:00:00Z",
          expires_at:"2099-01-01T00:05:00Z",transport:"posix-ssh",principal:"roundhouse",
          originating_node_id:"origin-a",node_key_fingerprint:("SHA256:"+("A"*43)),certificate_serial:"1"},
        enrollment:{epoch:1,fleet_domain:"fleet.example",fleet_ca_fingerprint:("SHA256:"+("B"*43)),
          ca_generation:1,certificate_valid_after:"2026-01-01T00:00:00Z",
          certificate_valid_before:"2099-01-01T00:00:00Z",
          pinned_host_key_fingerprint:("SHA256:"+("C"*43))},
        precondition:{digest:{algorithm:"sha256",value:("c"*64)}}}
    }' >"$tmp/macos-plan.json"
    validate_privileged_plan_file "$tmp/macos-plan.json"
    for macos_mutation in \
        '.privilege.context.platform_boundary="linux"' \
        '.privilege.context.required="posix-root-v1"' \
        '.privilege.action.policy_token=null' \
        '.privilege.policy.constraint_digest="not-a-digest"' \
        '.privilege.action.path="/tmp/caller.pkg"'; do
      jq "$macos_mutation" "$tmp/macos-plan.json" >"$tmp/macos-invalid-plan.json"
      if validate_privileged_plan_file "$tmp/macos-invalid-plan.json" >/dev/null 2>&1; then
        fail "$macos_action accepted invalid sealed platform/context/token/digest/extra fields"
      fi
    done
  done

  if "$macos_broker" arbitrary >/dev/null 2>&1; then
    fail "macOS-capable broker accepted direct arguments"
  fi
  sed -n '/read_field request request_version/,/read_field end-request end_request/p' \
    "$macos_broker" >"$tmp/macos-request-fields"
  if grep -Ei 'read_field[[:space:]]+[^[:space:]]*(command|argv|path|url|depend|package|setting|plist)' \
      "$tmp/macos-request-fields"; then
    fail "macOS broker wire format accepts caller operation controls"
  fi
  grep -Fq '/usr/sbin/pkgutil' "$macos_broker" &&
    grep -Fq -- '--check-signature' "$macos_broker" &&
    grep -Fq '/usr/sbin/installer' "$macos_broker" &&
    grep -Eq -- '-target[[:space:]]+/' "$macos_broker" &&
    grep -Fq -- '-name Scripts' "$macos_broker" &&
    grep -Fq 'sealed-cask-payload-v1' "$macos_broker" ||
    fail "signed package action does not bind the sealed cask payload mode before fixed installer execution"
  if grep -Eq "(^|[[:space:]\"'])((/[^[:space:]\"']*)?brew)([[:space:]\"']|$)" "$macos_broker"; then
    fail "protected macOS broker contains a root Homebrew path"
  fi
  macos_apply_functions="$tmp/macos-apply-functions.sh"
  cli_function_body execute_plan_operation >"$macos_apply_functions"
  jq -n '{type:"package-upgrade",kind:"package",id:"homebrew-cask:fixture-cask",
    candidate_version:"2.0",argv:["env","HOMEBREW_NO_AUTO_UPDATE=1","brew","upgrade","--cask","fixture-cask"]}' \
    >"$tmp/macos-cask-operation.json"
  mkdir -p "$tmp/macos-homebrew/bin" "$tmp/macos-homebrew/repository/Library/Homebrew"
  : >"$tmp/macos-homebrew/repository/Library/Homebrew/brew.rb"
  cat >"$tmp/macos-homebrew/bin/brew" <<'SH'
#!/bin/sh
if [ "$1" = --repository ]; then
  printf '%s\n' "$ROUNDHOUSE_TEST_BREW_REPOSITORY"
  exit 0
fi
printf '%s\n' "$@" >"$ROUNDHOUSE_TEST_BREW_LOG"
SH
  chmod 755 "$tmp/macos-homebrew/bin/brew"
  (
    # shellcheck source=/dev/null
    . "$macos_apply_functions"
    # Referenced by the extracted execute_plan_operation function.
    # shellcheck disable=SC2034
    plugin_root=$plugin_cache
    PATH="$tmp/macos-homebrew/bin:$PATH"
    ROUNDHOUSE_TEST_BREW_REPOSITORY="$tmp/macos-homebrew/repository"
    ROUNDHOUSE_TEST_BREW_LOG="$tmp/macos-homebrew/invocation"
    export PATH ROUNDHOUSE_TEST_BREW_REPOSITORY ROUNDHOUSE_TEST_BREW_LOG
    execute_plan_operation "$tmp/macos-cask-operation.json" "$tmp/config.json" test-host
  ) || fail "ordinary-user Homebrew cask transaction did not start through the typed bridge hook"
  grep -Fqx -- "-r$plugin_cache/scripts/homebrew-bridge.rb" "$tmp/macos-homebrew/invocation" &&
    grep -Fqx "$tmp/macos-homebrew/repository/Library/Homebrew/brew.rb" "$tmp/macos-homebrew/invocation" &&
    grep -Fqx fixture-cask "$tmp/macos-homebrew/invocation" ||
    fail "Homebrew cask transaction did not bind the packaged bridge hook and selected cask"
  grep -Fq -- '--homebrew-bridge-v1' "$macos_broker" &&
    grep -Fq 'prepare-app' "$macos_broker" &&
    grep -Fq 'macos-cask-app' "$macos_broker" &&
    grep -Fq 'exact_sealed_package_not_enrolled' "$macos_broker" &&
    grep -Fq 'unsupported_privileged_cask_artifact' "$macos_broker" ||
    fail "Homebrew bridge does not fail closed around the exact sealed package contract"
  if command -v ruby >/dev/null 2>&1; then
    ruby -c "$plugin_cache/scripts/homebrew-bridge.rb" >/dev/null ||
      fail "Homebrew bridge hook is not valid Ruby"
  fi

  macos_bridge_root=$tmp/macos-app-bridge
  macos_bridge_generation=$macos_bridge_root/etc/roundhouse/generations/1
  macos_bridge_broker=$macos_bridge_root/usr/local/libexec/roundhouse/posix-broker
  mkdir -p "$macos_bridge_generation" "$macos_bridge_root/etc/roundhouse/generations" \
    "$macos_bridge_root/var/lib/roundhouse" "$macos_bridge_root/usr/local/libexec/roundhouse" \
    "$macos_bridge_root/usr/sbin" "$macos_bridge_root/Applications/Visual Studio Code.app/Contents"
  chmod 755 "$macos_bridge_root" "$macos_bridge_root/etc" "$macos_bridge_root/etc/roundhouse" \
    "$macos_bridge_root/etc/roundhouse/generations" "$macos_bridge_generation" \
    "$macos_bridge_root/usr" "$macos_bridge_root/usr/local" "$macos_bridge_root/usr/local/libexec" \
    "$macos_bridge_root/usr/local/libexec/roundhouse" "$macos_bridge_root/usr/sbin" \
    "$macos_bridge_root/Applications" "$macos_bridge_root/Applications/Visual Studio Code.app" \
    "$macos_bridge_root/Applications/Visual Studio Code.app/Contents"
  chmod 700 "$macos_bridge_root/var" "$macos_bridge_root/var/lib" \
    "$macos_bridge_root/var/lib/roundhouse"
  cat >"$macos_bridge_root/usr/sbin/chown" <<SH
#!/bin/sh
printf '%s\n' "\$@" >'$tmp/macos-app-chown.log'
SH
  chmod 755 "$macos_bridge_root/usr/sbin/chown"
  cp "$macos_broker" "$macos_bridge_broker"
  chmod 755 "$macos_bridge_broker"
  macos_bridge_app_record='macos-cask-app|macos.install-signed-pkg.v1|visual-studio-code|Visual Studio Code.app'
  printf '%s\n' "$macos_bridge_app_record" >"$tmp/macos-app-constraint-group"
  macos_bridge_group_digest=$(shasum -a 256 "$tmp/macos-app-constraint-group" | awk '{print $1}')
  awk -F '|' -v OFS='|' -v digest="$macos_bridge_group_digest" '
    $2 == "macos.install-signed-pkg.v1" { $4="enabled"; $6=digest } { print }
  ' "$macos_policy" >"$macos_bridge_generation/policy.actions"
  macos_bridge_policy_digest=$(shasum -a 256 "$macos_bridge_generation/policy.actions" | awk '{print $1}')
  printf 'constraints|1|generation=1|policy-sha256=%s\n%s\n' \
    "$macos_bridge_policy_digest" "$macos_bridge_app_record" \
    >"$macos_bridge_generation/policy.constraints"
  printf 'identity|1|test-mac|%s|roundhouse|fleet.example|SHA256:%s|1|SHA256:%s|roundhouse-posix,roundhouse-windows\n' \
    "$(id -u)" "$(printf 'A%.0s' {1..43})" "$(printf 'B%.0s' {1..43})" \
    >"$macos_bridge_generation/host.identity"
  cat >"$macos_bridge_generation/macos.context" <<EOF
macos-context|2
binary|chown|$(shasum -a 256 "$macos_bridge_root/usr/sbin/chown" | awk '{print $1}')
binary|installer|$(printf 'a%.0s' {1..64})
binary|pkgutil|$(printf 'b%.0s' {1..64})
binary|pmset|$(printf 'c%.0s' {1..64})
binary|systemsetup|$(printf 'd%.0s' {1..64})
EOF
  printf '%s\n' "$(shasum -a 256 "$macos_bridge_broker" | awk '{print $1}')" \
    >"$macos_bridge_generation/broker.sha256"
  chmod 644 "$macos_bridge_generation"/*
  ln -s generations/1 "$macos_bridge_root/etc/roundhouse/active"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$macos_bridge_root" ROUNDHOUSE_U2_FIXTURE_PLATFORM=macos \
    SUDO_UID="$(id -u)" SUDO_USER=roundhouse \
    "$macos_bridge_broker" --homebrew-bridge-v1 prepare-app visual-studio-code ||
    fail "typed app-target bridge rejected the exact protected cask target"
  printf '%s\n' -R -P -h -- "$(id -u)" \
    "$macos_bridge_root/Applications/Visual Studio Code.app" >"$tmp/macos-app-chown.expected"
  cmp -s "$tmp/macos-app-chown.expected" "$tmp/macos-app-chown.log" ||
    fail "typed app-target bridge did not derive the fixed non-following chown invocation"
  for macos_bad_bridge_args in \
      'prepare-app ../visual-studio-code' \
      'prepare-app visual-studio-code-insiders' \
      'prepare-app visual-studio-code /Applications/Other.app'; do
    # shellcheck disable=SC2086
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$macos_bridge_root" ROUNDHOUSE_U2_FIXTURE_PLATFORM=macos \
        SUDO_UID="$(id -u)" SUDO_USER=roundhouse \
        "$macos_bridge_broker" --homebrew-bridge-v1 $macos_bad_bridge_args >/dev/null 2>&1; then
      fail "typed app-target bridge accepted traversal, another token, or a caller path"
    fi
  done
  mv "$macos_bridge_root/Applications/Visual Studio Code.app" \
    "$macos_bridge_root/Applications/Visual Studio Code.real.app"
  ln -s 'Visual Studio Code.real.app' "$macos_bridge_root/Applications/Visual Studio Code.app"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$macos_bridge_root" ROUNDHOUSE_U2_FIXTURE_PLATFORM=macos \
      SUDO_UID="$(id -u)" SUDO_USER=roundhouse \
      "$macos_bridge_broker" --homebrew-bridge-v1 prepare-app visual-studio-code >/dev/null 2>&1; then
    fail "typed app-target bridge accepted a symlink target"
  fi
  grep -Fq 'policy_token_not_found' "$macos_broker" &&
    grep -Fq 'macos.install-signed-pkg.v1)' "$macos_broker" &&
    grep -Fq 'macos.apply-system-setting.v1)' "$macos_broker" ||
    fail "macOS actions do not derive their finite operation from protected token constraints"

  grep -Fq '/usr/local/libexec/roundhouse/posix-broker' "$macos_broker" ||
    fail "macOS broker is not fixed to the SIP-safe Darwin launcher path"
  macos_collector="$plugin_cache/scripts/collect-posix"
  sed -n '/^u2_macos_preconditions()/,/^}/p' "$macos_collector" >"$tmp/macos-collector-contract"
  grep -Fq '/usr/bin/pmset' "$macos_collector" &&
    grep -Fq '/etc/localtime' "$macos_collector" &&
    grep -Fq '/etc/ntp.conf' "$macos_collector" &&
    grep -Fq 'binary[5]="pmset"' "$macos_collector" &&
    grep -Fq 'if(NR!=6)' "$macos_collector" &&
    grep -Fq 'binary[2]="chown"' "$macos_collector" ||
    fail "macOS readiness does not attest chown, pmset, and native unprivileged sources"
  if grep -Eq '/usr/bin/sudo|systemsetup|observe-macos-preconditions|broker\.observe-macos-preconditions' \
      "$tmp/macos-collector-contract"; then
    fail "macOS readiness invokes a privileged broker or systemsetup for observation"
  fi

  macos_enroller="$plugin_cache/scripts/enroll-privilege-posix"
  macos_lifecycle_helpers="$tmp/macos-lifecycle-helpers.sh"
  for macos_helper in capture_current_process_id acquire_lifecycle_guard release_lifecycle_guard; do
    sed -n "/^$macos_helper()/,/^}/p" "$macos_enroller" >>"$macos_lifecycle_helpers"
  done
  (
    root_prefix="$tmp/macos-lifecycle-root"
    fixture_mode=true
    platform_boundary=macos
    export fixture_mode platform_boundary
    macos_lifecycle_pid=
    lifecycle_guard=
    mkdir -p "$root_prefix/var/lib"
    protected_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(wc -c <"$1")" -le "$2" ]; }
    exact_mode() { [ "$(stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1")" = "$2" ]; }
    # shellcheck source=/dev/null
    . "$macos_lifecycle_helpers"
    capture_current_process_id macos_lifecycle_pid &&
      kill -0 "$macos_lifecycle_pid" 2>/dev/null ||
      fail "macOS Bash lifecycle PID capture did not identify the live owner"
    acquire_lifecycle_guard || fail "macOS shlock lifecycle guard was not acquired"
    [ -f "$lifecycle_guard" ] || fail "macOS shlock lifecycle guard was not materialized"
    release_lifecycle_guard || fail "macOS shlock lifecycle guard was not released"
    [ ! -e "$lifecycle_guard" ] || fail "macOS shlock lifecycle guard survived release"
  )

  # Exercise the broker helpers in isolation. The native tools are stubs, but
  # the parsing, normalization, and fail-closed decisions are the production
  # functions copied from the packaged broker.
  macos_broker_helpers="$tmp/macos-broker-helpers.sh"
  for macos_helper in macos_setting_value_valid macos_pkg_payload_mode_valid macos_receipt_version \
      macos_setting_snapshot inspect_macos_package; do
    sed -n "/^$macos_helper()/,/^}/p" "$macos_broker" >>"$macos_broker_helpers"
  done
  macos_native_fixture="$tmp/macos-native-fixture"
  mkdir -p "$macos_native_fixture"
  cat >"$macos_native_fixture/pkgutil" <<'SH'
#!/bin/sh
case $1 in
  --check-signature)
    printf '%s\n' \
      'Package "fixture.pkg":' \
      '   Status: signed by a developer certificate issued by Apple for distribution' \
      '   Certificate Chain:' \
      '    1. Developer ID Installer: Fixture Publisher (TEAMID1234)' \
      '       SHA256 Fingerprint:' \
      '           AA AA AA AA AA AA AA AA AA AA AA AA AA AA AA AA' \
      '           AA AA AA AA AA AA AA AA AA AA AA AA AA AA AA AA'
    ;;
  --expand)
    artifact=$2
    destination=$3
    mkdir -p "$destination"
    case ${artifact##*/} in
      bad-colon.pkg) package_id=com.example:bad ;;
      bad-plus.pkg) package_id=com.example+bad ;;
      bad-at.pkg) package_id=com.example@bad ;;
      bad-comma.pkg) package_id=com.example,bad ;;
      *) package_id=com.example.fixture ;;
    esac
    printf '<pkg-info format-version="2" identifier="%s" version="1.2.3">\n' \
      "$package_id" >"$destination/PackageInfo"
    if [ "${artifact##*/}" = script.pkg ]; then
      mkdir -p "$destination/Scripts"
      printf '#!/bin/sh\nexit 0\n' >"$destination/Scripts/preinstall"
    elif [ "${artifact##*/}" = distribution.pkg ]; then
      printf '%s\n' '<installer-gui-script minSpecVersion="2">' \
        '<script>system.run("/bin/sh")</script>' \
        '<pkg-ref id="com.example.fixture">https://example.invalid/fixture.pkg</pkg-ref>' \
        '</installer-gui-script>' >"$destination/Distribution"
    fi
    ;;
  --pkg-info-plist)
    receipt=$2
    case $receipt in
      com.example.missing)
        printf "No receipt for '%s' found at '/'.\n" "$receipt" >&2
        exit 1
        ;;
      com.example.broken)
        printf 'receipt database unavailable\n' >&2
        exit 1
        ;;
    esac
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0">' '<dict>' \
      '<key>pkg-version</key>' '<string>1.2.3</string>' \
      '<key>pkgid</key>' "<string>$receipt</string>" '</dict>' '</plist>'
    ;;
  *) exit 64 ;;
esac
SH
  cat >"$macos_native_fixture/installer" <<'SH'
#!/bin/sh
for argument in "$@"; do
  if [ "${argument##*/}" = distribution.pkg ]; then
    printf 'called\n' >"${0%/*}/distribution-installer-called"
  fi
done
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><array><dict><key>Package</key><string>Fixture</string></dict></array></plist>'
SH
  cat >"$macos_native_fixture/systemsetup" <<'SH'
#!/bin/sh
case $1 in
  -gettimezone) printf 'Time Zone: America/New_York\n' ;;
  -getnetworktimeserver) printf 'Network Time Server: time.example.invalid\n' ;;
  -getwakeonnetworkaccess) printf 'Wake On Network Access: Off\n' ;;
  -getrestartpowerfailure) printf 'Restart After Power Failure: On\n' ;;
  -getcomputersleep) printf 'Computer Sleep: Off\n' ;;
  -getdisplaysleep) printf 'Display Sleep: After 20 Minutes\n' ;;
  *) exit 64 ;;
esac
SH
  cat >"$macos_native_fixture/systemsetup-invalid" <<'SH'
#!/bin/sh
printf 'Network Time: Maybe\n'
SH
  chmod +x "$macos_native_fixture/pkgutil" "$macos_native_fixture/installer" \
    "$macos_native_fixture/systemsetup" "$macos_native_fixture/systemsetup-invalid"

  (
    file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
    sha256_file() {
      if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
      else shasum -a 256 "$1" | awk '{print $1}'; fi
    }
    protected_ancestors() { :; }
    protected_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(file_size "$1")" -le "$2" ]; }
    exact_mode() { [ "$(stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1")" = "$2" ]; }
    # shellcheck source=/dev/null
    . "$macos_broker_helpers"

    missing_version=$(macos_receipt_version "$macos_native_fixture/pkgutil" \
      com.example.missing "$macos_native_fixture/receipt-missing") ||
      fail "known-absent macOS receipt did not normalize to absence"
    [ "$missing_version" = - ] || fail "known-absent macOS receipt did not return '-'"
    if macos_receipt_version "$macos_native_fixture/pkgutil" com.example.broken \
        "$macos_native_fixture/receipt-broken" >/dev/null; then
      fail "unexpected pkgutil failure was treated as receipt absence"
    fi
    for prohibited_id in com.example:bad com.example+bad com.example@bad com.example,bad; do
      if macos_receipt_version "$macos_native_fixture/pkgutil" "$prohibited_id" \
          "$macos_native_fixture/receipt-prohibited" >/dev/null; then
        fail "macOS receipt identifier accepted prohibited punctuation: $prohibited_id"
      fi
    done

    [ "$(macos_setting_snapshot "$macos_native_fixture/systemsetup" timezone \
      "$macos_native_fixture/setting-timezone")" = America/New_York ] ||
      fail "macOS timezone snapshot was not normalized"
    [ "$(macos_setting_snapshot "$macos_native_fixture/systemsetup" wake-on-network-access \
      "$macos_native_fixture/setting-wake")" = off ] ||
      fail "macOS boolean setting snapshot was not normalized"
    if macos_setting_snapshot "$macos_native_fixture/systemsetup-invalid" wake-on-network-access \
        "$macos_native_fixture/setting-invalid" >/dev/null; then
      fail "macOS setting snapshot accepted invalid native output"
    fi

    for package_fixture in bad-colon bad-plus bad-at bad-comma script; do
      package_path="$macos_native_fixture/$package_fixture.pkg"
      printf 'fixture package\n' >"$package_path"
      chmod 0644 "$package_path"
      package_size=$(file_size "$package_path")
      package_digest=$(sha256_file "$package_path")
      case $package_fixture in
        bad-colon) expected_id=com.example:bad ;;
        bad-plus) expected_id=com.example+bad ;;
        bad-at) expected_id=com.example@bad ;;
        bad-comma) expected_id=com.example,bad ;;
        script) expected_id=com.example.fixture ;;
      esac
      if inspect_macos_package "$macos_native_fixture/pkgutil" "$macos_native_fixture/installer" \
          "$package_path" "$macos_native_fixture/$package_fixture-inspect" "$package_size" \
          "$package_digest" "$expected_id" 1.2.3 TEAMID1234 \
          aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then
        case $package_fixture in
          script) fail "script-bearing expanded macOS package was accepted" ;;
          *) fail "macOS package identifier accepted prohibited punctuation: $expected_id" ;;
        esac
      fi
    done
    package_path="$macos_native_fixture/script.pkg"
    if ! inspect_macos_package "$macos_native_fixture/pkgutil" "$macos_native_fixture/installer" \
        "$package_path" "$macos_native_fixture/script-cask-inspect" "$(file_size "$package_path")" \
        "$(sha256_file "$package_path")" com.example.fixture 1.2.3 TEAMID1234 \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa sealed-cask-payload-v1; then
      fail "exact sealed cask package payload was rejected"
    fi
    if inspect_macos_package "$macos_native_fixture/pkgutil" "$macos_native_fixture/installer" \
        "$package_path" "$macos_native_fixture/script-invalid-mode-inspect" "$(file_size "$package_path")" \
        "$(sha256_file "$package_path")" com.example.fixture 1.2.3 TEAMID1234 \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa caller-controlled; then
      fail "macOS package accepted an unsealed payload mode"
    fi
    package_path="$macos_native_fixture/distribution.pkg"
    printf 'fixture package\n' >"$package_path"
    chmod 0644 "$package_path"
    if inspect_macos_package "$macos_native_fixture/pkgutil" "$macos_native_fixture/installer" \
        "$package_path" "$macos_native_fixture/distribution-inspect" "$(file_size "$package_path")" \
        "$(sha256_file "$package_path")" com.example.fixture 1.2.3 TEAMID1234 \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then
      fail "distribution-style macOS package was accepted"
    fi
    if inspect_macos_package "$macos_native_fixture/pkgutil" "$macos_native_fixture/installer" \
        "$package_path" "$macos_native_fixture/distribution-sealed-inspect" "$(file_size "$package_path")" \
        "$(sha256_file "$package_path")" com.example.fixture 1.2.3 TEAMID1234 \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa sealed-cask-payload-v1; then
      fail "sealed cask payload accepted a distribution-style macOS package"
    fi
    [ ! -e "$macos_native_fixture/distribution-installer-called" ] ||
      fail "distribution package reached installer inspection before rejection"
  )

  # The collector must derive macOS preconditions without invoking sudo or the
  # broker: a root-owned localtime link, a deliberately tiny ntp.conf, and
  # normalized values from every pmset power profile are the only inputs here.
  macos_collector_helpers="$tmp/macos-collector-helpers.sh"
  for macos_helper in u2_macos_setting_value_valid u2_macos_pmset_snapshot \
      u2_macos_setting_snapshot; do
    sed -n "/^$macos_helper()/,/^}/p" "$macos_collector" >>"$macos_collector_helpers"
  done
  macos_collector_root="$macos_native_fixture/collector-root"
  mkdir -p "$macos_collector_root/etc" "$macos_collector_root/usr/bin" \
    "$macos_collector_root/var/db/timezone/zoneinfo/America"
  printf 'zone fixture\n' >"$macos_collector_root/var/db/timezone/zoneinfo/America/New_York"
  chmod 0644 "$macos_collector_root/var/db/timezone/zoneinfo/America/New_York"
  ln -s /var/db/timezone/zoneinfo/America/New_York "$macos_collector_root/etc/localtime"
  printf 'server time.example.invalid\n' >"$macos_collector_root/etc/ntp.conf"
  chmod 0644 "$macos_collector_root/etc/ntp.conf"
  cat >"$macos_collector_root/usr/bin/pmset" <<'SH'
#!/bin/sh
cat "$0.output"
SH
  cat >"$macos_collector_root/usr/bin/pmset.output" <<'EOF'
AC Power:
 Sleep On Power Button 1
 womp 0
 autorestart 1
 sleep 0
 displaysleep 20
Battery Power:
 womp 0
 autorestart 1
 sleep 0
 displaysleep 20
EOF
  chmod 0755 "$macos_collector_root/usr/bin/pmset"
  (
    file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
    u2_validate_protected_ancestors() { :; }
    u2_file_ready() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(file_size "$1")" -le "$3" ]; }
    # shellcheck source=/dev/null
    . "$macos_collector_helpers"

    macos_pmset_values="$macos_native_fixture/pmset-values"
    u2_macos_pmset_snapshot "$macos_collector_root" root "$macos_pmset_values" ||
      fail "macOS pmset snapshot rejected ordinary native output"
    [ "$(u2_macos_setting_snapshot "$macos_collector_root" root timezone "$macos_pmset_values")" = America/New_York ] ||
      fail "macOS localtime snapshot was not normalized"
    [ "$(u2_macos_setting_snapshot "$macos_collector_root" root network-time-server "$macos_pmset_values")" = time.example.invalid ] ||
      fail "macOS ntp.conf snapshot was not normalized"
    [ "$(u2_macos_setting_snapshot "$macos_collector_root" root wake-on-network-access "$macos_pmset_values")" = off ] &&
      [ "$(u2_macos_setting_snapshot "$macos_collector_root" root restart-after-power-failure "$macos_pmset_values")" = on ] &&
      [ "$(u2_macos_setting_snapshot "$macos_collector_root" root computer-sleep "$macos_pmset_values")" = Never ] &&
      [ "$(u2_macos_setting_snapshot "$macos_collector_root" root display-sleep "$macos_pmset_values")" = 20 ] ||
      fail "macOS pmset values were not normalized"

    printf 'server time.example.invalid # forbidden-comment\n' >"$macos_collector_root/etc/ntp.conf"
    if u2_macos_setting_snapshot "$macos_collector_root" root network-time-server \
        "$macos_pmset_values" >/dev/null; then
      fail "macOS ntp.conf accepted a non-canonical server record"
    fi
    cat >"$macos_collector_root/usr/bin/pmset.output" <<'EOF'
AC Power:
 womp 1
 autorestart 1
 sleep 0
 displaysleep 20
Battery Power:
 womp 0
 autorestart 1
 sleep 0
 displaysleep 20
EOF
    if u2_macos_pmset_snapshot "$macos_collector_root" root "$macos_pmset_values"; then
      fail "macOS pmset snapshot accepted conflicting power profiles"
    fi
  )
}

[ "${ROUNDHOUSE_TEST_SCOPE:-}" != macos-privilege-contracts ] || {
  test_macos_privilege_contracts
  printf 'PASS: macOS privilege contracts\n'
  exit 0
}
