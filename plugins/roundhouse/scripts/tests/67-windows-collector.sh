# roundhouse self-check — the native Windows collector fixtures (skipped
# without pwsh).
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$pwsh_command" ]; then
  "$cli" worker-config test-windows inventory "$tmp/windows-worker-config.json"
  jq '.agent_artifacts += [{id:"missing-host-path",paths:{"test-host":"~/.missing"},kind:"config",format:"json",settings:{fallbackModel:null,model:"fixture-model"},agents:["claude"],groups:["development"]}]' \
    "$tmp/windows-worker-config.json" >"$tmp/missing-agent-path-windows-config.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/missing-agent-path-windows-config.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents -AllowAuthVerify \
    >"$tmp/missing-agent-path-windows.jsonl"
  "$cli" validate "$tmp/missing-agent-path-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "missing-host-path" and .status == "unavailable" and .errors[0].code == "artifact_path_missing")) | length' "$tmp/missing-agent-path-windows.jsonl")" -eq 1 ] ||
    fail "missing Windows per-host artifact path was not explicit"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "missing-host-path" and .status == "unavailable" and .data.path == null and .errors[0].code == "artifact_path_missing")) | length' "$tmp/missing-agent-path-windows.jsonl")" -eq 2 ] ||
    fail "missing Windows per-host artifact path dropped configured settings or treated them as observed absent"
  jq '.auth_artifacts["test-auth"].paths = {"TEST-WINDOWS":"~/.wrong-case-auth"}' \
    "$tmp/windows-worker-config.json" >"$tmp/wrong-case-host-path-windows-config.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/wrong-case-host-path-windows-config.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections auth -AllowAuthVerify \
    >"$tmp/wrong-case-host-path-windows.jsonl"
  "$cli" validate "$tmp/wrong-case-host-path-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "auth_artifact" and .id == "test-auth" and .data.health == "healthy" and (.data.path | endswith("/.test-auth")))) | length' "$tmp/wrong-case-host-path-windows.jsonl")" -eq 1 ] ||
    fail "Windows auth path lookup accepted a differently cased host ID"
  jq '.machines["test-windows"].groups = ["Development"]' \
    "$tmp/windows-worker-config.json" >"$tmp/wrong-case-group-windows-config.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/wrong-case-group-windows-config.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents >"$tmp/wrong-case-group-windows.jsonl"
  "$cli" validate "$tmp/wrong-case-group-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "capability" and .id == "example-research")) | length' "$tmp/wrong-case-group-windows.jsonl")" -eq 0 ] ||
    fail "Windows group matching accepted a differently cased group ID"
  jq '.capabilities["example-research"].requires_auth = ["TEST-AUTH"] |
      .capabilities["example-research"].requires_artifacts = ["SHARED-AGENT-DEFINITION"]' \
    "$tmp/windows-worker-config.json" >"$tmp/wrong-case-dependencies-windows-config.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/wrong-case-dependencies-windows-config.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents -AllowAuthVerify \
    >"$tmp/wrong-case-dependencies-windows.jsonl"
  "$cli" validate "$tmp/wrong-case-dependencies-windows.jsonl"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[],.data.dependencies.artifacts[] | select(.status == "unconfigured" and .ready == false)] | length' "$tmp/wrong-case-dependencies-windows.jsonl")" -eq 2 ] ||
    fail "Windows capability dependencies accepted differently cased identifiers"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections packages >"$tmp/windows-packages.jsonl"
  "$cli" validate "$tmp/windows-packages.jsonl"
  [ "$(jq -r 'select(.kind == "package" and .id == "winget:Example.Package") | .data.candidate_version' \
    "$tmp/windows-packages.jsonl")" = 2.0.0 ] ||
    fail "authoritative winget table did not produce a candidate"

  WINGET_MODE=invalid HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile \
    -File "$script_dir/collect-windows.ps1" -ConfigPath "$tmp/windows-worker-config.json" \
    -HostId test-windows -ControllerConfigDigest "$config_hash" -Sections packages \
    >"$tmp/windows-packages-unknown.jsonl"
  "$cli" validate "$tmp/windows-packages-unknown.jsonl"
  [ "$(jq -r 'select(.kind == "operation") | .data.operation_status' \
    "$tmp/windows-packages-unknown.jsonl")" = partial ] ||
    fail "unverified winget output did not produce partial inventory"
  [ "$(jq -r 'select(.kind == "package" and .id == "winget:Example.Package") |
    (.data.candidate_version == null and .data.update_available == null)' \
    "$tmp/windows-packages-unknown.jsonl")" = true ] ||
    fail "unverified winget output produced an actionable candidate"

  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/windows.jsonl"
  "$cli" validate "$tmp/windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:remoteControlAtStartup" and .data.observed == false and .data.desired == true and .data.in_sync == false)) | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows collector did not report Claude Remote Control setting drift"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "codex-settings:check_for_update_on_startup" and .data.in_sync == true)) | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows collector did not parse the allowlisted Codex TOML setting"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "codex-settings:model" and .data.observed == "fixture#model" and .data.in_sync == true)) | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows collector did not parse the Codex literal TOML string"
  if grep -q 'must-not-leak' "$tmp/windows.jsonl"; then
    fail "Windows collector leaked an unlisted agent setting"
  fi
  cp -p "$tmp/home/.codex/config.toml" "$tmp/codex-settings-before-triple-windows.toml"
  printf '%s\n' 'model = """fixture#model""" # triple-basic string' \
    >"$tmp/home/.codex/config.toml"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/triple-basic-setting-windows.jsonl"
  "$cli" validate "$tmp/triple-basic-setting-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "codex-settings:model" and .status == "present" and .data.observed == "fixture#model" and .data.in_sync == true)) | length' "$tmp/triple-basic-setting-windows.jsonl")" -eq 1 ] ||
    fail "Windows collector rejected a basic triple-quoted TOML setting"
  printf '%s\n' "model = '''" "fixture#model''' # triple-literal string" \
    >"$tmp/home/.codex/config.toml"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/triple-literal-setting-windows.jsonl"
  mv "$tmp/codex-settings-before-triple-windows.toml" "$tmp/home/.codex/config.toml"
  "$cli" validate "$tmp/triple-literal-setting-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "codex-settings:model" and .status == "present" and .data.observed == "fixture#model" and .data.in_sync == true)) | length' "$tmp/triple-literal-setting-windows.jsonl")" -eq 1 ] ||
    fail "Windows collector rejected a delimiter-newline literal triple-quoted TOML setting"
  mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-absent-windows.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/absent-settings-windows.jsonl"
  mv "$tmp/claude-settings-absent-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/absent-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings")) | length' "$tmp/absent-settings-windows.jsonl")" -eq 5 ] ||
    fail "absent Windows settings artifact did not emit every configured setting"
  [ "$(jq -s 'map(select(.id == "claude-settings:remoteControlAtStartup" and .data.observed_present == false and .data.in_sync == false)) | length' "$tmp/absent-settings-windows.jsonl")" -eq 1 ] ||
    fail "absent Windows non-null setting was not reported as drift"
  [ "$(jq -s 'map(select(.id == "claude-settings:fallbackModel" and .data.observed_present == false and .data.in_sync == true)) | length' "$tmp/absent-settings-windows.jsonl")" -eq 1 ] ||
    fail "absent Windows desired-null setting was not reported in sync"
  cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-case-windows.json"
  printf '%s\n' '{"RemoteControlAtStartup":true,"remoteControlAtStartup":false}' >"$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/case-sensitive-settings-windows.jsonl"
  mv "$tmp/claude-settings-case-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/case-sensitive-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.id == "claude-settings:remoteControlAtStartup" and .data.observed_present == true and .data.observed == false and .data.in_sync == false)) | length' "$tmp/case-sensitive-settings-windows.jsonl")" -eq 1 ] ||
    fail "Windows JSON setting lookup did not select the exact-case key"
  cp -p "$tmp/home/.codex/config.toml" "$tmp/codex-settings-case-windows.toml"
  printf '%s\n' "Model = 'wrong-case'" "model = 'fixture#model'" \
    'check_for_update_on_startup = True' >"$tmp/home/.codex/config.toml"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/case-sensitive-toml-settings-windows.jsonl"
  mv "$tmp/codex-settings-case-windows.toml" "$tmp/home/.codex/config.toml"
  "$cli" validate "$tmp/case-sensitive-toml-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.id == "codex-settings:model" and .data.observed_present == true and .data.observed == "fixture#model" and .data.in_sync == true)) | length' "$tmp/case-sensitive-toml-settings-windows.jsonl")" -eq 1 ] ||
    fail "Windows TOML setting lookup did not select the exact-case key"
  [ "$(jq -s 'map(select(.id == "codex-settings:check_for_update_on_startup" and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/case-sensitive-toml-settings-windows.jsonl")" -eq 1 ] ||
    fail "Windows TOML parser accepted a mixed-case boolean literal"
  jq '(.agent_artifacts[] | select(.id == "claude-settings").settings.autoUpdatesChannel) = "latest" |
      (.agent_artifacts[] | select(.id == "codex-settings").settings.cli_auth_credentials_store) = "auto"' \
    "$tmp/windows-worker-config.json" >"$tmp/enum-settings-windows-config.json"
  cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-enum-windows.json"
  cp -p "$tmp/home/.codex/config.toml" "$tmp/codex-settings-enum-windows.toml"
  printf '%s\n' '{"autoUpdatesChannel":"Latest"}' >"$tmp/home/.claude/settings.json"
  printf '%s\n' "cli_auth_credentials_store = 'Auto'" >"$tmp/home/.codex/config.toml"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/enum-settings-windows-config.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents -AllowAuthVerify \
    >"$tmp/mixed-case-enum-settings-windows.jsonl"
  mv "$tmp/claude-settings-enum-windows.json" "$tmp/home/.claude/settings.json"
  mv "$tmp/codex-settings-enum-windows.toml" "$tmp/home/.codex/config.toml"
  "$cli" validate "$tmp/mixed-case-enum-settings-windows.jsonl"
  [ "$(jq -s 'map(select((.id == "claude-settings:autoUpdatesChannel" or .id == "codex-settings:cli_auth_credentials_store") and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/mixed-case-enum-settings-windows.jsonl")" -eq 2 ] ||
    fail "Windows observed settings accepted mixed-case enum values"
  cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-null-windows.json"
  printf '%s\n' '{"fallbackModel":null}' >"$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/explicit-null-setting-windows.jsonl"
  mv "$tmp/claude-settings-null-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/explicit-null-setting-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:fallbackModel" and .status == "present" and .data.observed_present == true and .data.observed == null and .data.desired == null and .data.in_sync == false)) | length' "$tmp/explicit-null-setting-windows.jsonl")" -eq 1 ] ||
    fail "explicit Windows null setting was not reported as observed drift"
  cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-valid-windows.json"
  printf '%s\n' '{"model":{"apiKey":"nested-observed-secret"},"fallbackModel":{"apiKey":"nested-null-desired-secret"}}' >"$tmp/home/.claude/settings.json"
  set +e
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/invalid-observed-setting-windows.jsonl"
  invalid_observed_setting_windows_rc=$?
  set -e
  mv "$tmp/claude-settings-valid-windows.json" "$tmp/home/.claude/settings.json"
  [ "$invalid_observed_setting_windows_rc" -eq 0 ] || fail "Windows invalid-setting inventory did not return JSONL"
  "$cli" validate "$tmp/invalid-observed-setting-windows.jsonl"
  [ "$(jq -r 'select(.kind == "operation") | .data.operation_status' "$tmp/invalid-observed-setting-windows.jsonl")" = partial ] ||
    fail "invalid observed Windows setting did not mark inventory partial"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:model" and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/invalid-observed-setting-windows.jsonl")" -eq 1 ] ||
    fail "invalid observed Windows setting value was not suppressed"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:fallbackModel" and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/invalid-observed-setting-windows.jsonl")" -eq 1 ] ||
    fail "nested Windows value for a null-desired setting was not suppressed"
  if grep -q 'nested-observed-secret' "$tmp/invalid-observed-setting-windows.jsonl"; then
    fail "nested data under an allowlisted Windows setting leaked into inventory"
  fi
  if grep -q 'nested-null-desired-secret' "$tmp/invalid-observed-setting-windows.jsonl"; then
    fail "nested data under a null-desired Windows setting leaked into inventory"
  fi
  cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-single-document-windows.json"
  printf '%s\n' '{"model":"fixture-model"}' '{"model":"fixture-model"}' \
    >"$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/multi-document-settings-windows.jsonl"
  mv "$tmp/claude-settings-single-document-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/multi-document-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "setting_parse_failed")) | length' "$tmp/multi-document-settings-windows.jsonl")" -eq 5 ] ||
    fail "multi-document Windows JSON dropped configured setting records"
  mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-file-windows.json"
  mkdir "$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/directory-settings-windows.jsonl"
  rmdir "$tmp/home/.claude/settings.json"
  mv "$tmp/claude-settings-file-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/directory-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "claude-settings" and .status == "present" and .data.digest.scope == "directory-files")) | length' "$tmp/directory-settings-windows.jsonl")" -eq 1 ] ||
    fail "Windows settings directory artifact type was not reported truthfully"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "setting_parse_failed")) | length' "$tmp/directory-settings-windows.jsonl")" -eq 5 ] ||
    fail "Windows settings directory dropped configured setting records"
  mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-file-before-link-windows.json"
  printf '%s\n' '{"model":"linked-settings-secret-windows"}' \
    >"$tmp/linked-claude-settings-windows.json"
  ln -s "$tmp/linked-claude-settings-windows.json" "$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/linked-settings-windows.jsonl"
  rm "$tmp/home/.claude/settings.json" "$tmp/linked-claude-settings-windows.json"
  mv "$tmp/claude-settings-file-before-link-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/linked-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "claude-settings" and .status == "partial" and .errors[0].code == "symlink_not_followed")) | length' "$tmp/linked-settings-windows.jsonl")" -eq 1 ] ||
    fail "linked Windows settings artifact was not reported without following it"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "symlink_not_followed")) | length' "$tmp/linked-settings-windows.jsonl")" -eq 5 ] ||
    fail "linked Windows settings artifact dropped configured setting records"
  if grep -q 'linked-settings-secret-windows' "$tmp/linked-settings-windows.jsonl"; then
    fail "Windows settings inventory followed a linked artifact"
  fi
  mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-file-before-dangling-link-windows.json"
  ln -s "$tmp/missing-claude-settings-windows.json" "$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/dangling-linked-settings-windows.jsonl"
  rm "$tmp/home/.claude/settings.json"
  mv "$tmp/claude-settings-file-before-dangling-link-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/dangling-linked-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "claude-settings" and .status == "partial" and .errors[0].code == "symlink_not_followed")) | length' "$tmp/dangling-linked-settings-windows.jsonl")" -eq 1 ] ||
    fail "dangling Windows settings link was reported as an absent artifact"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "symlink_not_followed")) | length' "$tmp/dangling-linked-settings-windows.jsonl")" -eq 5 ] ||
    fail "dangling Windows settings link dropped configured setting records"
  cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-bounded-windows.json"
  jq -cn --arg value "$oversized_setting" '{model:$value,availableModels:[range(0;3000)|"xx"]}' \
    >"$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/oversized-observed-settings-windows.jsonl"
  mv "$tmp/claude-settings-bounded-windows.json" "$tmp/home/.claude/settings.json"
  "$cli" validate "$tmp/oversized-observed-settings-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and (.id == "claude-settings:model" or .id == "claude-settings:availableModels") and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/oversized-observed-settings-windows.jsonl")" -eq 2 ] ||
    fail "oversized scalar or array Windows setting was not suppressed"
  printf '%s\n' '[{"fallbackModel":"nested-array-value"}]' >"$tmp/home/.claude/settings.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/invalid-root-setting-windows.jsonl"
  [ "$(jq -r 'select(.kind == "operation") | .data.operation_status' "$tmp/invalid-root-setting-windows.jsonl")" = partial ] ||
    fail "Windows JSON array root did not mark setting inventory partial"
  [ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:fallbackModel" and .status == "unavailable")) | length' "$tmp/invalid-root-setting-windows.jsonl")" -eq 1 ] ||
    fail "Windows JSON array root was treated as an object with absent settings"
  printf '%s\n' \
    '{"remoteControlAtStartup":false,"switchModelsOnFlag":false,"model":"fixture-model","unlistedSecret":"must-not-leak"}' \
    >"$tmp/home/.claude/settings.json"
  [ "$(jq -s 'map(select(.kind == "operation")) | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows collector did not emit one operation record"
  [ "$(jq -s 'map(select(.kind == "plugin" and .id == "codex:test-market:example:1.2.3" and .confidence == "high" and .data.install_state == "installed" and .data.inferred_installed_at_confidence == "low")) | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows collector did not use authoritative Codex inventory with inferred creation time"
  windows_claude_plugin=$(jq -c 'select(.kind == "plugin" and .id == "claude:test-market:claude-example:2.0.0")' "$tmp/windows.jsonl")
  [ "$(printf '%s' "$windows_claude_plugin" | jq -s 'map(select(.data.installed_at == "2026-01-03T04:05:06Z" and .data.last_updated == "2026-01-04T05:06:07Z")) | length')" -eq 1 ] ||
    fail "Windows collector did not preserve Claude manager timestamps: $windows_claude_plugin"
  [ "$(jq -s 'map(select(.kind == "plugin_cache" and (.id == "codex:test-market:example:0.9.0" or .id == "claude:test-market:claude-example:1.0.0") and .data.install_state == "cache-only")) | length' "$tmp/windows.jsonl")" -eq 2 ] ||
    fail "Windows collector did not preserve stale versions as cache-only evidence"
  [ "$(jq -s 'map(select(.kind == "plugin" and (.id == "codex:test-market:example:0.9.0" or .id == "claude:test-market:claude-example:1.0.0"))) | length' "$tmp/windows.jsonl")" -eq 0 ] ||
    fail "Windows collector classified stale cache versions as installed"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.providers[] | select(.agent == "codex") | .matches[]] | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows capability reconciliation did not use exactly one active Codex plugin"
  [ "$(jq -s 'map(select(.kind == "capability" and .id == "shared-example" and ([.data.providers[].agent] | sort) == ["claude","codex"])) | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "shared Windows capability did not expand to both agents"
  [ "$(jq -s 'map(select(.kind == "capability" and .id == "example-research" and .data.ready == true and .data.dependencies.ready == true)) | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "satisfied Windows capability dependencies were not ready"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "test-auth" and .status == "healthy" and .ready == true)] | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows capability did not report healthy auth dependency state"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "native-test-auth" and .status == "healthy" and .ready == true)] | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows capability did not use status-only authentication"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.artifacts[] | select(.id == "shared-agent-definition" and .status == "present" and .ready == true)] | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows capability did not report present artifact dependency state"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.artifacts[] | select(.id == "paths-only-agent-definition" and .status == "present" and .ready == true)] | length' "$tmp/windows.jsonl")" -eq 1 ] ||
    fail "Windows capability did not resolve a per-host artifact path"
  windows_plugin_eval=$(grep 'plugin-eval' "$tmp/windows.jsonl" || true)
  if [ -n "$windows_plugin_eval" ]; then
    fail "transient plugin-eval fixture was classified as Windows plugin evidence: $windows_plugin_eval"
  fi
  if grep -q 'nested-fixture' "$tmp/windows.jsonl"; then
    fail "nested Windows plugin fixture was classified as cache evidence"
  fi
  [ "$(jq -r 'select(.kind == "operation") | .data.transport' "$tmp/windows.jsonl")" = codex-remote-control ] ||
    fail "Windows operation did not preserve configured transport"
  [ "$(jq -r 'select(.id == "jsm:example-jsm") | .data.version | type' "$tmp/windows.jsonl")" = string ] ||
    fail "Windows JSM version was not normalized to a string"
  [ "$(jq -r 'select(.kind == "snapshot") | .data.configuration_digest.value' "$tmp/windows.jsonl")" = "$config_hash" ] ||
    fail "Windows snapshot did not preserve controller config digest"
  posix_skill_hash=$(jq -r 'select(.id == "standalone:manual:manual-example") | .data.digest.value' "$tmp/snapshot.jsonl")
  windows_skill_hash=$(jq -r 'select(.id == "standalone:manual:manual-example") | .data.digest.value' "$tmp/windows.jsonl")
  [ "$posix_skill_hash" = "$windows_skill_hash" ] ||
    fail "standalone skill digest is not cross-platform canonical"

  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents >"$tmp/agents-without-auth-verify-windows.jsonl"
  "$cli" validate "$tmp/agents-without-auth-verify-windows.jsonl"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "test-auth" and .status == "not-authorized" and .ready == false)] | length' "$tmp/agents-without-auth-verify-windows.jsonl")" -eq 1 ] ||
    fail "ordinary Windows agents inventory trusted auth without authorization"

  AUTH_CHECK_FAIL=1 HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/unhealthy-capability-auth-windows.jsonl"
  "$cli" validate "$tmp/unhealthy-capability-auth-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "capability" and .id == "example-research" and .status == "partial" and .data.available == false and .data.ready == false and .data.dependencies.ready == false)) | length' "$tmp/unhealthy-capability-auth-windows.jsonl")" -eq 1 ] ||
    fail "unhealthy required auth did not make the Windows capability unavailable"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "test-auth" and .status == "unhealthy" and .ready == false)] | length' "$tmp/unhealthy-capability-auth-windows.jsonl")" -eq 1 ] ||
    fail "Windows capability did not report unhealthy auth dependency state"

  jq '.auth_artifacts["native-test-auth"].strategy = "ignore"' \
    "$tmp/windows-worker-config.json" >"$tmp/ignore-native-auth-windows.json"
  AUTH_CHECK_FAIL=1 HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/ignore-native-auth-windows.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections auth -AllowAuthVerify \
    >"$tmp/ignore-unhealthy-auth-windows.jsonl"
  "$cli" validate "$tmp/ignore-unhealthy-auth-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "auth_artifact" and .id == "native-test-auth" and
    .status == "partial" and .data.strategy == "ignore" and .data.health == "unhealthy" and
    .data.reauth_required == false and .data.manual_action == null)) | length' \
    "$tmp/ignore-unhealthy-auth-windows.jsonl")" -eq 1 ] ||
    fail "unhealthy ignored Windows auth emitted actionable reauthentication state"

  mv "$tmp/home/.agents/agents/example.md" "$tmp/missing-agent-definition-windows"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents -AllowAuthVerify >"$tmp/missing-capability-artifact-windows.jsonl"
  mv "$tmp/missing-agent-definition-windows" "$tmp/home/.agents/agents/example.md"
  "$cli" validate "$tmp/missing-capability-artifact-windows.jsonl"
  [ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.artifacts[] | select(.id == "shared-agent-definition" and .status == "absent" and .ready == false)] | length' "$tmp/missing-capability-artifact-windows.jsonl")" -eq 1 ] ||
    fail "Windows capability did not report absent artifact dependency state"

  CODEX_PLUGIN_LIST_INVALID=1 HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents >"$tmp/invalid-codex-plugins-windows.jsonl"
  "$cli" validate "$tmp/invalid-codex-plugins-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "plugin_manager" and .id == "codex" and .status == "unavailable")) | length' "$tmp/invalid-codex-plugins-windows.jsonl")" -eq 1 ] ||
    fail "invalid Codex plugin manager JSON was not reported on Windows"
  [ "$(jq -s 'map(select(.kind == "plugin" and .data.agent == "codex")) | length' "$tmp/invalid-codex-plugins-windows.jsonl")" -eq 0 ] ||
    fail "Windows cache evidence was promoted when the Codex manager query failed"
  [ "$(jq -s 'map(select(.kind == "plugin_cache" and .id == "codex:test-market:example:1.2.3")) | length' "$tmp/invalid-codex-plugins-windows.jsonl")" -eq 1 ] ||
    fail "Windows manager failure discarded distinct Codex cache evidence"
  [ "$(jq -s 'map(select(.kind == "plugin_cache" and .id == "codex:test-market:example:1.2.3" and .data.install_state == "manager-unverified" and .data.active == null)) | length' "$tmp/invalid-codex-plugins-windows.jsonl")" -eq 1 ] ||
    fail "Windows manager failure mislabeled unknown active cache state"

  CODEX_PLUGIN_LIST_INVALID_SHAPE=1 HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents >"$tmp/invalid-codex-plugin-shape-windows.jsonl"
  "$cli" validate "$tmp/invalid-codex-plugin-shape-windows.jsonl"
  [ "$(jq -s 'map(select(.kind == "plugin_manager" and .id == "codex" and .status == "unavailable")) | length' "$tmp/invalid-codex-plugin-shape-windows.jsonl")" -eq 1 ] ||
    fail "invalid Codex plugin manager shape was not reported on Windows"
  [ "$(jq -s 'map(select(.kind == "plugin" and .data.agent == "codex")) | length' "$tmp/invalid-codex-plugin-shape-windows.jsonl")" -eq 0 ] ||
    fail "Windows invalid manager shape produced active Codex plugins"
  [ "$(jq -s 'map(select(.kind == "plugin_cache" and .id == "codex:test-market:example:1.2.3" and .data.install_state == "manager-unverified" and .data.active == null)) | length' "$tmp/invalid-codex-plugin-shape-windows.jsonl")" -eq 1 ] ||
    fail "Windows invalid manager shape did not preserve unverified cache evidence"

  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections projects >"$tmp/windows-projects.jsonl"
  "$cli" validate "$tmp/windows-projects.jsonl"
  [ "$(jq -r 'select(.kind == "project" and .id == "example") | .data.repository_readiness' "$tmp/windows-projects.jsonl")" = ready ] ||
    fail "Windows collector did not recognize a readable Git checkout"

  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections auth -AllowAuthVerify >"$tmp/windows-auth.jsonl"
  "$cli" validate "$tmp/windows-auth.jsonl"
  [ "$(jq -r 'select(.id == "test-auth") | .data.health' "$tmp/windows-auth.jsonl")" = healthy ] ||
    fail "Windows native auth health check was not healthy"
  [ "$(jq -s 'map(select(.kind == "auth_artifact" and .id == "native-test-auth" and .status == "present" and .data.type == "native-status" and .data.path == null and .data.health == "healthy")) | length' "$tmp/windows-auth.jsonl")" -eq 1 ] ||
    fail "Windows pathless native auth health was not inventoried"

  JSM_INVALID_SHAPE=1 HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents >"$tmp/windows-invalid-jsm.jsonl"
  "$cli" validate "$tmp/windows-invalid-jsm.jsonl"
  assert_contains "$(cat "$tmp/windows-invalid-jsm.jsonl")" '"id":"agents:jsm"'

  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections chezmoi >"$tmp/windows-chezmoi.jsonl"
  "$cli" validate "$tmp/windows-chezmoi.jsonl"
  [ "$(jq -r 'select(.kind == "chezmoi_state" and .id == "live") | .status' "$tmp/windows-chezmoi.jsonl")" = present ] ||
    fail "Windows collector did not recognize an empty clean chezmoi status"
  [ "$(jq -r 'select(.kind == "chezmoi_state" and .id == "live") | .data.drift_count' "$tmp/windows-chezmoi.jsonl")" -eq 0 ] ||
    fail "Windows clean chezmoi status reported drift"

  printf '{invalid\n' >"$tmp/home/.agents/.skill-lock.json"
  HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/windows-worker-config.json" -HostId test-windows -ControllerConfigDigest "$config_hash" \
    -Sections agents >"$tmp/invalid-lock-windows.jsonl"
  "$cli" validate "$tmp/invalid-lock-windows.jsonl"
  assert_contains "$(cat "$tmp/invalid-lock-windows.jsonl")" '"id":"agents:skills-cli-lock"'
  rm -f "$tmp/home/.agents/.skill-lock.json"

  jq '.projects.example.path = "../escape"' "$tmp/windows-worker-config.json" >"$tmp/invalid-worker-config.json"
  if HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/invalid-worker-config.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections projects >/dev/null 2>&1; then
    fail "Windows worker accepted a traversal project path"
  fi
  jq '.agent_artifacts[] |= if .id == "claude-settings" then .settings.availableModels = [range(0;3000) | "xx"] else . end' \
    "$tmp/windows-worker-config.json" >"$tmp/invalid-agent-setting-aggregate-windows.json"
  if HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/invalid-agent-setting-aggregate-windows.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents >/dev/null 2>&1; then
    fail "Windows worker accepted an oversized aggregate desired setting"
  fi
  jq '(.agent_artifacts[] | select(.id == "claude-settings").settings.autoUpdatesChannel) = "Latest"' \
    "$tmp/windows-worker-config.json" >"$tmp/mixed-case-desired-enum-windows.json"
  if HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/mixed-case-desired-enum-windows.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents >/dev/null 2>&1; then
    fail "Windows worker accepted a mixed-case desired setting enum"
  fi
  jq '(.agent_artifacts[] | select(.id == "claude-settings").settings.AutoUpdatesChannel) = "latest"' \
    "$tmp/windows-worker-config.json" >"$tmp/mixed-case-desired-key-windows.json"
  if HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/mixed-case-desired-key-windows.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents >/dev/null 2>&1; then
    fail "Windows worker accepted a mixed-case desired setting key"
  fi
  jq '.capabilities["example-research"].Codex = .capabilities["example-research"].codex |
      .capabilities["example-research"].Claude = .capabilities["example-research"].claude |
      del(.capabilities["example-research"].codex,.capabilities["example-research"].claude)' \
    "$tmp/windows-worker-config.json" >"$tmp/wrong-case-provider-windows.json"
  if HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/wrong-case-provider-windows.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections agents >/dev/null 2>&1; then
    fail "Windows worker accepted a differently cased capability provider key"
  fi
  jq 'del(.auth_artifacts["test-auth"].path) | .auth_artifacts["test-auth"].portability = "per-machine"' \
    "$tmp/windows-worker-config.json" >"$tmp/invalid-pathless-encrypted-windows.json"
  if HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/invalid-pathless-encrypted-windows.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections auth >/dev/null 2>&1; then
    fail "Windows worker accepted a pathless encrypted auth install"
  fi
  jq 'del(.auth_artifacts["native-test-auth"].reauth)' \
    "$tmp/windows-worker-config.json" >"$tmp/invalid-reauth-command-windows.json"
  if HOME="$tmp/home" "$pwsh_command" -NoLogo -NoProfile -File "$script_dir/collect-windows.ps1" \
    -ConfigPath "$tmp/invalid-reauth-command-windows.json" -HostId test-windows \
    -ControllerConfigDigest "$config_hash" -Sections auth >/dev/null 2>&1; then
    fail "Windows worker accepted a reauth strategy without a command"
  fi
fi
