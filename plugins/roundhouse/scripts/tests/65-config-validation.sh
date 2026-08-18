# roundhouse self-check — configuration rejection sweep.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

jq '.capabilities."example-research".requires_auth = ["missing-auth"]' \
  "$tmp/config.json" >"$tmp/invalid-capability-reference.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-capability-reference.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "capability accepted an unknown auth dependency"
fi
jq '.handoff_project = "missing-project"' \
  "$tmp/config.json" >"$tmp/invalid-handoff-project.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-handoff-project.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "handoff project accepted an unknown project reference"
fi
jq '.auth_artifacts."test-auth".mode = "0644"' \
  "$tmp/config.json" >"$tmp/invalid-auth-mode.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-auth-mode.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "encrypted auth artifact accepted a non-private mode"
fi
jq '.agent_artifacts[] |= if .id == "claude-settings" then .settings.apiKey = "unsafe" else . end' \
  "$tmp/config.json" >"$tmp/invalid-agent-setting.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-agent-setting.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "agent settings accepted a non-allowlisted key"
fi
jq '.agent_artifacts[] |= if .id == "claude-settings" then .settings.remoteControlAtStartup = "yes" else . end' \
  "$tmp/config.json" >"$tmp/invalid-agent-setting-type.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-agent-setting-type.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "agent settings accepted an invalid desired value type"
fi
jq '.agent_artifacts[] |= if .id == "claude-settings" then .settings.availableModels = [range(0;3000) | "xx"] else . end' \
  "$tmp/config.json" >"$tmp/invalid-agent-setting-aggregate-size.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-agent-setting-aggregate-size.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "agent settings accepted an oversized aggregate desired value"
fi
jq '.agent_artifacts[] |= if .id == "claude-settings" then .agents = ["codex"] else . end' \
  "$tmp/config.json" >"$tmp/invalid-agent-setting-owner.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-agent-setting-owner.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "agent settings accepted the wrong owning agent"
fi
jq '.agent_artifacts[] |= if .id == "codex-settings" then .paths.typo = .paths["test-host"] else . end' \
  "$tmp/config.json" >"$tmp/invalid-agent-path-host.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-agent-path-host.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "agent artifact accepted a path override for an unknown host"
fi
jq 'del(.auth_artifacts["native-test-auth"].verify)' "$tmp/config.json" \
  >"$tmp/invalid-native-auth.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-native-auth.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "pathless native auth accepted no verification command"
fi
jq 'del(.auth_artifacts["native-test-auth"].reauth)' "$tmp/config.json" \
  >"$tmp/invalid-reauth-command.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-reauth-command.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "reauth strategy accepted no reauthentication command"
fi
jq 'del(.auth_artifacts["test-auth"].path) | .auth_artifacts["test-auth"].portability = "per-machine"' \
  "$tmp/config.json" >"$tmp/invalid-pathless-encrypted-auth.json"
if ROUNDHOUSE_CONFIG="$tmp/invalid-pathless-encrypted-auth.json" \
  "$cli" validate-config >/dev/null 2>&1; then
  fail "pathless encrypted auth install was accepted"
fi
ROUNDHOUSE_CONFIG="$tmp/ignore-native-auth.json" "$cli" validate-config
jq '.agent_artifacts += [{id:"missing-host-path",paths:{"test-windows":"~/.missing"},kind:"config",format:"json",settings:{fallbackModel:null,model:"fixture-model"},agents:["claude"],groups:["development"]}]' \
  "$tmp/config.json" >"$tmp/missing-agent-path.json"
set +e
ROUNDHOUSE_CONFIG="$tmp/missing-agent-path.json" "$cli" collect --target test-host \
  --section agents --section auth --output "$tmp/missing-agent-path.jsonl"
missing_agent_path_rc=$?
set -e
[ "$missing_agent_path_rc" -eq 2 ] || fail "missing per-host artifact path was not partial"
"$cli" validate "$tmp/missing-agent-path.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "missing-host-path" and .status == "unavailable" and .errors[0].code == "artifact_path_missing")) | length' "$tmp/missing-agent-path.jsonl")" -eq 1 ] ||
  fail "missing per-host artifact path was not explicit"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "missing-host-path" and .status == "unavailable" and .data.path == null and .errors[0].code == "artifact_path_missing")) | length' "$tmp/missing-agent-path.jsonl")" -eq 2 ] ||
  fail "missing per-host artifact path dropped configured settings or treated them as observed absent"
[ "$(test_file_mode "$tmp/snapshot.jsonl")" = 600 ] ||
  fail "snapshot mode is not 600"
"$cli" validate "$tmp/snapshot.jsonl"
if [ "$(uname -s)" = Linux ]; then
  [ "$(jq -r 'select(.kind == "startup_task" and .data.scheduler == "systemd-system") |
    .data.active' "$tmp/snapshot.jsonl" | sort -u)" = inactive ] ||
    fail "inactive systemd status was duplicated after a nonzero query exit"
fi

json=$("$cli" render --format json "$tmp/snapshot.jsonl")
human=$("$cli" render --format human "$tmp/snapshot.jsonl")
assert_contains "$json" '"kind":"package"'
assert_contains "$json" '"id":"homebrew:git"'
assert_contains "$json" '"id":"homebrew-cask:visual-tool"'
assert_contains "$json" '"candidate_version":"2.51.0"'
assert_contains "$json" '"update_available":true'
assert_contains "$json" '"kind":"project"'
assert_contains "$json" '"origin_matches":true'
assert_contains "$json" '"codex_saved_project_status":"requires-controller-check"'
assert_contains "$json" '"kind":"operation"'
assert_contains "$json" '"operation_status":"completed"'
assert_contains "$json" '"id":"jsm:example-jsm"'
[ "$(printf '%s' "$json" | jq -r '.records[] | select(.id == "jsm:example-jsm") | .data.version | type')" = string ] ||
  fail "POSIX JSM version was not normalized to a string"
assert_contains "$json" '"id":"example-research"'
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "capability" and .id == "shared-example" and ([.data.providers[].agent] | sort) == ["claude","codex"])] | length')" -eq 1 ] ||
  fail "shared POSIX capability did not expand to both agents"
assert_contains "$json" '"consistent":true'
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "capability" and .id == "example-research" and .data.ready == true and .data.dependencies.ready == true)] | length')" -eq 1 ] ||
  fail "satisfied POSIX capability dependencies were not ready"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "test-auth" and .status == "healthy" and .ready == true)] | length')" -eq 1 ] ||
  fail "POSIX capability did not report healthy auth dependency state"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "native-test-auth" and .status == "healthy" and .ready == true)] | length')" -eq 1 ] ||
  fail "POSIX capability did not use status-only authentication"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.artifacts[] | select(.id == "shared-agent-definition" and .status == "present" and .ready == true)] | length')" -eq 1 ] ||
  fail "POSIX capability did not report present artifact dependency state"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.artifacts[] | select(.id == "paths-only-agent-definition" and .status == "present" and .ready == true)] | length')" -eq 1 ] ||
  fail "POSIX capability did not resolve a per-host artifact path"
if printf '%s' "$json" | grep -q 'other-group'; then fail "capability group filter leaked another group"; fi
assert_contains "$json" '"id":"standalone:manual:manual-example"'
assert_contains "$json" '"id":"shared-agent-definition"'
assert_contains "$json" '"id":"empty-agent-definitions"'
assert_contains "$json" '"scope":"directory-files"'
assert_contains "$json" '"manager":"manual"'
assert_contains "$json" '"health":"healthy"'
assert_contains "$json" '"portability":"per-machine"'
assert_contains "$json" '"id":"claude-settings:remoteControlAtStartup"'
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "agent_setting" and .id == "claude-settings:remoteControlAtStartup" and .data.observed == false and .data.desired == true and .data.in_sync == false)] | length')" -eq 1 ] ||
  fail "Claude Remote Control setting drift was not reported"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "agent_setting" and .id == "claude-settings:fallbackModel" and .data.observed_present == false and .data.in_sync == true)] | length')" -eq 1 ] ||
  fail "absent Claude fallback setting was not recognized as desired"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "agent_setting" and .id == "codex-settings:check_for_update_on_startup" and .data.in_sync == true)] | length')" -eq 1 ] ||
  fail "Codex TOML setting was not parsed"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "agent_setting" and .id == "codex-settings:model" and .data.observed == "fixture#model" and .data.in_sync == true)] | length')" -eq 1 ] ||
  fail "Codex literal TOML string was not parsed"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "agent_setting" and .id == "codex-settings:service_tier" and .data.observed_present == false and .data.in_sync == true)] | length')" -eq 1 ] ||
  fail "nested TOML key was mistaken for a top-level Codex setting"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "auth_artifact" and .id == "native-test-auth" and .status == "present" and .data.type == "native-status" and .data.path == null and .data.health == "healthy")] | length')" -eq 1 ] ||
  fail "pathless native auth health was not inventoried"
if printf '%s' "$json" | grep -q 'must-not-leak'; then
  fail "unlisted agent setting leaked into inventory"
fi
assert_contains "$human" 'false -> true (drift)'
assert_contains "$json" '"id":"codex:test-market:example:1.2.3"'
assert_contains "$json" '"id":"claude:test-market:claude-example:2.0.0"'
assert_contains "$json" '"inferred_installed_at_evidence":"filesystem_birthtime"'
assert_contains "$json" '"inferred_installed_at_confidence":"low"'
assert_contains "$json" '"algorithm":"sha256"'
assert_contains "$human" 'test-host'
assert_contains "$human" "$(printf 'HOST\tKIND')"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.id == "codex:test-market:example:1.2.3")] | length')" -eq 1 ] ||
  fail "dual manifests produced duplicate plugin records"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "plugin" and .id == "codex:test-market:example:1.2.3" and .confidence == "high" and .data.install_state == "installed")] | length')" -eq 1 ] ||
  fail "Codex manager-listed plugin was not authoritative POSIX inventory"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "plugin" and .id == "claude:test-market:claude-example:2.0.0" and .data.installed_at == "2026-01-03T04:05:06.000Z" and .data.last_updated == "2026-01-04T05:06:07.000Z")] | length')" -eq 1 ] ||
  fail "Claude manager timestamps were not preserved in POSIX inventory"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "plugin_cache" and (.id == "codex:test-market:example:0.9.0" or .id == "claude:test-market:claude-example:1.0.0") and .data.install_state == "cache-only")] | length')" -eq 2 ] ||
  fail "stale POSIX plugin cache versions were not preserved as cache-only evidence"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "plugin" and (.id == "codex:test-market:example:0.9.0" or .id == "claude:test-market:claude-example:1.0.0"))] | length')" -eq 0 ] ||
  fail "stale POSIX plugin cache version was classified as installed"
[ "$(printf '%s' "$json" | jq '[.records[] | select(.kind == "capability" and .id == "example-research") | .data.providers[] | select(.agent == "codex") | .matches[]] | length')" -eq 1 ] ||
  fail "POSIX capability reconciliation did not use exactly one active Codex plugin"
if printf '%s' "$json" | grep -q 'plugin-eval'; then
  fail "transient plugin-eval fixture was classified as an installed POSIX plugin"
fi
if printf '%s' "$json" | grep -q 'nested-fixture'; then
  fail "nested POSIX plugin fixture was classified as cache evidence"
fi

cp -p "$tmp/home/.codex/config.toml" "$tmp/codex-settings-before-triple-posix.toml"
printf '%s\n' 'model = """fixture#model""" # triple-basic string' \
  >"$tmp/home/.codex/config.toml"
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/triple-basic-setting-posix.jsonl"
"$cli" validate "$tmp/triple-basic-setting-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "codex-settings:model" and .status == "present" and .data.observed == "fixture#model" and .data.in_sync == true)) | length' "$tmp/triple-basic-setting-posix.jsonl")" -eq 1 ] ||
  fail "POSIX collector rejected a basic triple-quoted TOML setting"
printf '%s\n' "model = '''" "fixture#model''' # triple-literal string" \
  >"$tmp/home/.codex/config.toml"
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/triple-literal-setting-posix.jsonl"
mv "$tmp/codex-settings-before-triple-posix.toml" "$tmp/home/.codex/config.toml"
"$cli" validate "$tmp/triple-literal-setting-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "codex-settings:model" and .status == "present" and .data.observed == "fixture#model" and .data.in_sync == true)) | length' "$tmp/triple-literal-setting-posix.jsonl")" -eq 1 ] ||
  fail "POSIX collector rejected a delimiter-newline literal triple-quoted TOML setting"

set +e
"$cli" collect --target test-host --section agents --output "$tmp/agents-without-auth-verify-posix.jsonl"
agents_without_auth_verify_rc=$?
set -e
[ "$agents_without_auth_verify_rc" -eq 2 ] ||
  fail "ordinary POSIX agents inventory did not report unverified auth dependency"
[ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "test-auth" and .status == "not-authorized" and .ready == false)] | length' "$tmp/agents-without-auth-verify-posix.jsonl")" -eq 1 ] ||
  fail "ordinary POSIX agents inventory executed or trusted auth verification"

stdin_human=$("$cli" render --format human - <"$tmp/snapshot.jsonl")
assert_contains "$stdin_human" 'test-host'

if grep -q 'super-secret-value' "$tmp/snapshot.jsonl"; then
  fail "secret value leaked into inventory"
fi
if grep -q 'user:secret' "$tmp/snapshot.jsonl"; then
  fail "authenticated Git remote leaked into inventory"
fi
if grep -q 'lock-secret' "$tmp/snapshot.jsonl"; then
  fail "authenticated skills lock URL leaked into inventory"
fi
mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-absent-posix.json"
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/absent-settings-posix.jsonl"
mv "$tmp/claude-settings-absent-posix.json" "$tmp/home/.claude/settings.json"
"$cli" validate "$tmp/absent-settings-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings")) | length' "$tmp/absent-settings-posix.jsonl")" -eq 5 ] ||
  fail "absent POSIX settings artifact did not emit every configured setting"
[ "$(jq -s 'map(select(.id == "claude-settings:remoteControlAtStartup" and .data.observed_present == false and .data.in_sync == false)) | length' "$tmp/absent-settings-posix.jsonl")" -eq 1 ] ||
  fail "absent POSIX non-null setting was not reported as drift"
[ "$(jq -s 'map(select(.id == "claude-settings:fallbackModel" and .data.observed_present == false and .data.in_sync == true)) | length' "$tmp/absent-settings-posix.jsonl")" -eq 1 ] ||
  fail "absent POSIX desired-null setting was not reported in sync"
cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-null-posix.json"
printf '%s\n' '{"fallbackModel":null}' >"$tmp/home/.claude/settings.json"
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/explicit-null-setting-posix.jsonl"
mv "$tmp/claude-settings-null-posix.json" "$tmp/home/.claude/settings.json"
"$cli" validate "$tmp/explicit-null-setting-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:fallbackModel" and .status == "present" and .data.observed_present == true and .data.observed == null and .data.desired == null and .data.in_sync == false)) | length' "$tmp/explicit-null-setting-posix.jsonl")" -eq 1 ] ||
  fail "explicit POSIX null setting was not reported as observed drift"
cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-valid.json"
printf '%s\n' '{"model":{"apiKey":"nested-observed-secret"},"fallbackModel":{"apiKey":"nested-null-desired-secret"}}' >"$tmp/home/.claude/settings.json"
set +e
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/invalid-observed-setting-posix.jsonl"
invalid_observed_setting_rc=$?
set -e
mv "$tmp/claude-settings-valid.json" "$tmp/home/.claude/settings.json"
[ "$invalid_observed_setting_rc" -eq 2 ] || fail "invalid observed POSIX setting was not partial"
"$cli" validate "$tmp/invalid-observed-setting-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:model" and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/invalid-observed-setting-posix.jsonl")" -eq 1 ] ||
  fail "invalid observed POSIX setting value was not suppressed"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .id == "claude-settings:fallbackModel" and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/invalid-observed-setting-posix.jsonl")" -eq 1 ] ||
  fail "nested POSIX value for a null-desired setting was not suppressed"
invalid_observed_setting_human=$("$cli" render --format human "$tmp/invalid-observed-setting-posix.jsonl")
assert_contains "$invalid_observed_setting_human" 'setting_parse_failed'
if printf '%s' "$invalid_observed_setting_human" |
  awk -F '\t' '$3 == "claude-settings:model" && $5 ~ /null ->/ { found=1 } END { exit !found }'; then
  fail "human renderer presented an unavailable setting as observed drift"
fi
if grep -q 'nested-observed-secret' "$tmp/invalid-observed-setting-posix.jsonl"; then
  fail "nested data under an allowlisted POSIX setting leaked into inventory"
fi
if grep -q 'nested-null-desired-secret' "$tmp/invalid-observed-setting-posix.jsonl"; then
  fail "nested data under a null-desired POSIX setting leaked into inventory"
fi
cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-single-document-posix.json"
printf '%s\n' '{"model":"fixture-model"}' '{"model":"fixture-model"}' \
  >"$tmp/home/.claude/settings.json"
set +e
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/multi-document-settings-posix.jsonl"
multi_document_settings_posix_rc=$?
set -e
mv "$tmp/claude-settings-single-document-posix.json" "$tmp/home/.claude/settings.json"
[ "$multi_document_settings_posix_rc" -eq 2 ] || fail "multi-document POSIX settings were not partial"
"$cli" validate "$tmp/multi-document-settings-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "setting_parse_failed")) | length' "$tmp/multi-document-settings-posix.jsonl")" -eq 5 ] ||
  fail "multi-document POSIX JSON dropped configured setting records"
mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-file-posix.json"
mkdir "$tmp/home/.claude/settings.json"
set +e
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/directory-settings-posix.jsonl"
directory_settings_posix_rc=$?
set -e
rmdir "$tmp/home/.claude/settings.json"
mv "$tmp/claude-settings-file-posix.json" "$tmp/home/.claude/settings.json"
[ "$directory_settings_posix_rc" -eq 2 ] || fail "directory POSIX settings artifact was not partial"
"$cli" validate "$tmp/directory-settings-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "claude-settings" and .status == "present" and .data.digest.scope == "directory-files")) | length' "$tmp/directory-settings-posix.jsonl")" -eq 1 ] ||
  fail "POSIX settings directory artifact type was not reported truthfully"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "setting_parse_failed")) | length' "$tmp/directory-settings-posix.jsonl")" -eq 5 ] ||
  fail "POSIX settings directory dropped configured setting records"
mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-file-before-link-posix.json"
printf '%s\n' '{"model":"linked-settings-secret-posix"}' \
  >"$tmp/linked-claude-settings-posix.json"
ln -s "$tmp/linked-claude-settings-posix.json" "$tmp/home/.claude/settings.json"
set +e
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/linked-settings-posix.jsonl"
linked_settings_posix_rc=$?
set -e
rm "$tmp/home/.claude/settings.json" "$tmp/linked-claude-settings-posix.json"
mv "$tmp/claude-settings-file-before-link-posix.json" "$tmp/home/.claude/settings.json"
[ "$linked_settings_posix_rc" -eq 2 ] || fail "linked POSIX settings artifact was not partial"
"$cli" validate "$tmp/linked-settings-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "claude-settings" and .status == "partial" and .errors[0].code == "symlink_not_followed")) | length' "$tmp/linked-settings-posix.jsonl")" -eq 1 ] ||
  fail "linked POSIX settings artifact was not reported without following it"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "symlink_not_followed")) | length' "$tmp/linked-settings-posix.jsonl")" -eq 5 ] ||
  fail "linked POSIX settings artifact dropped configured setting records"
if grep -q 'linked-settings-secret-posix' "$tmp/linked-settings-posix.jsonl"; then
  fail "POSIX settings inventory followed a linked artifact"
fi
mv "$tmp/home/.claude/settings.json" "$tmp/claude-settings-file-before-fifo-posix.json"
mkfifo "$tmp/home/.claude/settings.json"
(printf '%s\n' '{"model":"fifo-settings-secret-posix"}' >"$tmp/home/.claude/settings.json") &
fifo_settings_writer=$!
set +e
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/fifo-settings-posix.jsonl"
fifo_settings_posix_rc=$?
set -e
kill "$fifo_settings_writer" >/dev/null 2>&1 || true
wait "$fifo_settings_writer" >/dev/null 2>&1 || true
rm "$tmp/home/.claude/settings.json"
mv "$tmp/claude-settings-file-before-fifo-posix.json" "$tmp/home/.claude/settings.json"
[ "$fifo_settings_posix_rc" -eq 2 ] || fail "FIFO POSIX settings artifact was not partial"
"$cli" validate "$tmp/fifo-settings-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_artifact" and .id == "claude-settings" and .status == "partial" and .errors[0].code == "non_regular_file")) | length' "$tmp/fifo-settings-posix.jsonl")" -eq 1 ] ||
  fail "FIFO POSIX settings artifact was not reported as non-regular"
[ "$(jq -s 'map(select(.kind == "agent_setting" and .data.artifact == "claude-settings" and .status == "unavailable" and .errors[0].code == "non_regular_file")) | length' "$tmp/fifo-settings-posix.jsonl")" -eq 5 ] ||
  fail "FIFO POSIX settings artifact dropped configured setting records"
if grep -q 'fifo-settings-secret-posix' "$tmp/fifo-settings-posix.jsonl"; then
  fail "POSIX settings inventory read a FIFO artifact"
fi
cp -p "$tmp/home/.claude/settings.json" "$tmp/claude-settings-bounded-posix.json"
jq -cn --arg value "$oversized_setting" '{model:$value,availableModels:[range(0;3000)|"xx"]}' \
  >"$tmp/home/.claude/settings.json"
set +e
"$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/oversized-observed-settings-posix.jsonl"
oversized_observed_settings_posix_rc=$?
set -e
mv "$tmp/claude-settings-bounded-posix.json" "$tmp/home/.claude/settings.json"
[ "$oversized_observed_settings_posix_rc" -eq 2 ] || fail "oversized observed POSIX settings were not partial"
"$cli" validate "$tmp/oversized-observed-settings-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "agent_setting" and (.id == "claude-settings:model" or .id == "claude-settings:availableModels") and .status == "unavailable" and (.data | has("observed") | not))) | length' "$tmp/oversized-observed-settings-posix.jsonl")" -eq 2 ] ||
  fail "oversized scalar or array POSIX setting was not suppressed"
assert_contains "$json" '"origin":"ssh://github.com/owner/example.git"'

"$cli" record-codex-readiness "$tmp/snapshot.jsonl" "$tmp/codex-readiness.json" "$tmp/enriched.jsonl"
"$cli" validate "$tmp/enriched.jsonl"
[ "$(jq -r 'select(.kind == "project" and .id == "example") | .data.codex_saved_project_status' "$tmp/enriched.jsonl")" = available ] ||
  fail "Codex saved-project readiness was not recorded"
[ "$(jq -r 'select(.kind == "operation") | .data.task_id' "$tmp/enriched.jsonl")" = task-opaque-id ] ||
  fail "Codex task correlation was not recorded"
sleep 1
"$cli" record-codex-readiness "$tmp/snapshot.jsonl" "$tmp/codex-readiness.json" "$tmp/enriched-2.jsonl"
"$cli" compare "$tmp/enriched.jsonl" "$tmp/enriched-2.jsonl" >"$tmp/enriched-compare.json"
[ "$(jq 'length' "$tmp/enriched-compare.json")" -eq 0 ] ||
  fail "volatile Codex readiness check time reported as drift"
jq '.host_id = "wrong-host"' "$tmp/codex-readiness.json" >"$tmp/wrong-readiness.json"
chmod 600 "$tmp/wrong-readiness.json"
if "$cli" record-codex-readiness "$tmp/snapshot.jsonl" "$tmp/wrong-readiness.json" "$tmp/wrong-enriched.jsonl" >/dev/null 2>&1; then
  fail "Codex readiness metadata for the wrong host was accepted"
fi
cp "$tmp/codex-readiness.json" "$tmp/public-readiness.json"
chmod 644 "$tmp/public-readiness.json"
if "$cli" record-codex-readiness "$tmp/snapshot.jsonl" "$tmp/public-readiness.json" "$tmp/public-enriched.jsonl" >/dev/null 2>&1; then
  fail "non-0600 Codex readiness metadata was accepted"
fi

"$cli" compare "$tmp/snapshot.jsonl" "$tmp/snapshot.jsonl" >"$tmp/compare.json"
[ "$(jq 'length' "$tmp/compare.json")" -eq 0 ] || fail "identical snapshot comparison reported drift"

"$cli" compare "$tmp/snapshot.jsonl" "$tmp/snapshot-2.jsonl" >"$tmp/compare-2.json"
[ "$(jq 'length' "$tmp/compare-2.json")" -eq 0 ] || fail "timestamps and run IDs reported as inventory drift"

set +e
AUTH_CHECK_FAIL=1 "$cli" collect --target test-host --section agents --section auth --output "$tmp/unhealthy-capability-auth-posix.jsonl"
unhealthy_capability_auth_rc=$?
set -e
[ "$unhealthy_capability_auth_rc" -eq 2 ] ||
  fail "unhealthy required auth did not produce partial POSIX capability inventory"
[ "$(jq -s 'map(select(.kind == "capability" and .id == "example-research" and .status == "partial" and .data.available == false and .data.ready == false and .data.dependencies.ready == false)) | length' "$tmp/unhealthy-capability-auth-posix.jsonl")" -eq 1 ] ||
  fail "unhealthy required auth did not make the POSIX capability unavailable"
[ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.auth[] | select(.id == "test-auth" and .status == "unhealthy" and .ready == false)] | length' "$tmp/unhealthy-capability-auth-posix.jsonl")" -eq 1 ] ||
  fail "POSIX capability did not report unhealthy auth dependency state"

set +e
AUTH_CHECK_FAIL=1 ROUNDHOUSE_CONFIG="$tmp/ignore-native-auth.json" \
  "$cli" collect --target test-host --section auth --output "$tmp/ignore-unhealthy-auth-posix.jsonl"
ignore_unhealthy_auth_rc=$?
set -e
[ "$ignore_unhealthy_auth_rc" -eq 2 ] ||
  fail "unhealthy ignored POSIX auth did not remain report-only"
"$cli" validate "$tmp/ignore-unhealthy-auth-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "auth_artifact" and .id == "native-test-auth" and
  .status == "partial" and .data.strategy == "ignore" and .data.health == "unhealthy" and
  .data.reauth_required == false and .data.manual_action == null)) | length' \
  "$tmp/ignore-unhealthy-auth-posix.jsonl")" -eq 1 ] ||
  fail "unhealthy ignored POSIX auth emitted actionable reauthentication state"

mv "$tmp/home/.agents/agents/example.md" "$tmp/missing-agent-definition"
set +e
"$cli" collect --target test-host --section agents --output "$tmp/missing-capability-artifact-posix.jsonl"
missing_capability_artifact_rc=$?
set -e
mv "$tmp/missing-agent-definition" "$tmp/home/.agents/agents/example.md"
[ "$missing_capability_artifact_rc" -eq 2 ] ||
  fail "missing required artifact did not produce partial POSIX capability inventory"
[ "$(jq -s '[.[] | select(.kind == "capability" and .id == "example-research") | .data.dependencies.artifacts[] | select(.id == "shared-agent-definition" and .status == "absent" and .ready == false)] | length' "$tmp/missing-capability-artifact-posix.jsonl")" -eq 1 ] ||
  fail "POSIX capability did not report absent artifact dependency state"

"$cli" collect --target test-ssh --section host --output "$tmp/ssh.jsonl"
"$cli" validate "$tmp/ssh.jsonl"
[ "$(jq -r 'select(.kind == "operation") | .data.transport' "$tmp/ssh.jsonl")" = ssh ] ||
  fail "SSH transport did not complete through the remote collector"
[ -s "$SSH_LOGIN_SHELL_LOG" ] || fail "SSH transport did not use the configured login shell"
if grep -vF 'exec "$SHELL" -lc' "$SSH_COMMAND_LOG" >/dev/null; then
  fail "SSH transport bypassed the configured login shell"
fi

set +e
BREW_FAIL=1 "$cli" collect --target test-host --section packages --output "$tmp/brew-failed.jsonl"
brew_failed_rc=$?
set -e
[ "$brew_failed_rc" -eq 2 ] || fail "failed brew query did not produce partial inventory"
assert_contains "$(cat "$tmp/brew-failed.jsonl")" '"code":"manager_query_failed"'

set +e
BREW_CASK_FAIL=1 "$cli" collect --target test-host --section packages --output "$tmp/brew-cask-failed.jsonl"
brew_cask_failed_rc=$?
set -e
[ "$brew_cask_failed_rc" -eq 2 ] || fail "failed brew cask query did not produce partial inventory"
assert_contains "$(cat "$tmp/brew-cask-failed.jsonl")" '"id":"packages:homebrew-cask"'

"$cli" collect --target test-apt --section packages --output "$tmp/apt.jsonl"
"$cli" validate "$tmp/apt.jsonl"
[ "$(jq -r 'select(.id == "apt:native-qualified:amd64") | .data.candidate_version' \
  "$tmp/apt.jsonl")" = 2.0.0 ] ||
  fail "unqualified APT candidate did not join its native architecture-qualified package"
[ "$(jq -r 'select(.id == "apt:foreign-unqualified:i386") | .data.candidate_version' \
  "$tmp/apt.jsonl")" = null ] ||
  fail "unqualified APT candidate was conflated with a foreign architecture package"
[ "$(jq -r 'select(.id == "apt:foreign-explicit:i386") | .data.candidate_version' \
  "$tmp/apt.jsonl")" = 3.0.0 ] ||
  fail "explicit foreign-architecture APT candidate did not join its installed package"

set +e
APT_LIST_FAIL=1 "$cli" collect --target test-apt --section packages \
  --output "$tmp/apt-candidate-failed.jsonl"
apt_candidate_failed_rc=$?
set -e
[ "$apt_candidate_failed_rc" -eq 2 ] ||
  fail "failed apt candidate query did not produce partial inventory"
"$cli" validate "$tmp/apt-candidate-failed.jsonl"
assert_contains "$(cat "$tmp/apt-candidate-failed.jsonl")" '"code":"candidate_query_failed"'
[ "$(jq -s 'map(select(.kind == "package" and .id == "apt:example" and .status == "present")) | length' \
  "$tmp/apt-candidate-failed.jsonl")" -eq 1 ] ||
  fail "failed apt candidate query discarded installed package inventory"

jq --arg marker "$tmp/untrusted-config-executed" \
  '.auth_artifacts["test-auth"].verify = ["touch", $marker]' "$tmp/config.json" >"$tmp/untrusted-config.json"
chmod 666 "$tmp/untrusted-config.json"
if ROUNDHOUSE_CONFIG="$tmp/untrusted-config.json" "$cli" collect --target test-host --section auth >/dev/null 2>&1; then
  fail "collection accepted a group/world-writable executable config"
fi
[ ! -e "$tmp/untrusted-config-executed" ] || fail "untrusted auth verification command executed"

mv "$tmp/home/.local/share/chezmoi" "$tmp/home/.local/share/chezmoi-git-fixture"
mkdir -p "$tmp/home/.local/share/chezmoi"
set +e
"$cli" collect --target test-host --section chezmoi --output "$tmp/partial.jsonl"
partial_rc=$?
set -e
[ "$partial_rc" -eq 2 ] || fail "partial inventory did not exit 2"
"$cli" validate "$tmp/partial.jsonl"
[ "$(jq -r 'select(.kind == "operation") | .data.operation_status' "$tmp/partial.jsonl")" = partial ] ||
  fail "partial record did not mark operation partial"
rm -rf "$tmp/home/.local/share/chezmoi"
mv "$tmp/home/.local/share/chezmoi-git-fixture" "$tmp/home/.local/share/chezmoi"

cp "$tmp/snapshot.jsonl" "$tmp/invalid.jsonl"
printf '%s\n' '{"schema":"roundhouse.inventory","schema_version":99}' >>"$tmp/invalid.jsonl"
if "$cli" validate "$tmp/invalid.jsonl" >/dev/null 2>&1; then
  fail "invalid schema version passed validation"
fi

jq -sc '.[0].snapshot_id = "other-snapshot" | .[]' "$tmp/snapshot.jsonl" >"$tmp/mixed.jsonl"
if "$cli" validate "$tmp/mixed.jsonl" >/dev/null 2>&1; then
  fail "mixed snapshot IDs passed validation"
fi

{ cat "$tmp/snapshot.jsonl"; sed -n '1p' "$tmp/snapshot.jsonl"; } >"$tmp/duplicate-record.jsonl"
if "$cli" validate "$tmp/duplicate-record.jsonl" >/dev/null 2>&1; then
  fail "duplicate entity records passed validation"
fi

jq -cn '{
  schema:"roundhouse.inventory",schema_version:1,snapshot_id:"large",host_id:"test-host",
  kind:"file",id:"large",observed_at:null,status:"present",confidence:"high",
  data:{a:("é"*8192),b:("é"*8192),c:("é"*8192),d:("é"*8192)},evidence:[],errors:[]
}' >"$tmp/multibyte-oversized.jsonl"
if "$cli" validate "$tmp/multibyte-oversized.jsonl" >/dev/null 2>&1; then
  fail "multibyte record over the byte limit passed validation"
fi

jq -c 'if .kind == "host" then .data.hostname = "terminal\u001bcontrol" else . end' \
  "$tmp/snapshot.jsonl" >"$tmp/terminal-control.jsonl"
if "$cli" validate "$tmp/terminal-control.jsonl" >/dev/null 2>&1; then
  fail "terminal control character passed inventory validation"
fi

if "$cli" collect --target test-host --section "host';echo injected" >/dev/null 2>&1; then
  fail "unsupported section passed validation"
fi

jq '.machines["test-host"].transport = "wsl-powershell"' "$tmp/config.json" >"$tmp/wsl-transport.json"
if ROUNDHOUSE_CONFIG="$tmp/wsl-transport.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "unsupported WSL bridge transport passed validation"
fi

jq '.machines["test-windows"].transport = "local"' "$tmp/config.json" >"$tmp/windows-local.json"
if ROUNDHOUSE_CONFIG="$tmp/windows-local.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "Windows host passed validation without direct Codex transport"
fi

jq '.machines.bad = {"platform":"linux","transport":"ssh","ssh_alias":"-oProxyCommand=bad","groups":[],"package_managers":["apt"]}' \
  "$tmp/config.json" >"$tmp/option-alias.json"
if ROUNDHOUSE_CONFIG="$tmp/option-alias.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "option-shaped SSH alias passed validation"
fi

jq '.projects.example.path = "..\\\\outside"' "$tmp/config.json" >"$tmp/windows-escape.json"
if ROUNDHOUSE_CONFIG="$tmp/windows-escape.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "Windows parent traversal project path passed validation"
fi

jq '.capabilities["example-research"].claude.skill = "../escape"' "$tmp/config.json" >"$tmp/capability-escape.json"
if ROUNDHOUSE_CONFIG="$tmp/capability-escape.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "capability skill traversal passed validation"
fi

jq '.capabilities["shared-example"].agents += ["codex"]' "$tmp/config.json" >"$tmp/duplicate-capability-agent.json"
if ROUNDHOUSE_CONFIG="$tmp/duplicate-capability-agent.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "shared capability accepted duplicate agents"
fi

jq '.capabilities["shared-example"].codex = {provider:"manual",source:"manual",name:"manual-example"}' \
  "$tmp/config.json" >"$tmp/mixed-capability-provider.json"
if ROUNDHOUSE_CONFIG="$tmp/mixed-capability-provider.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "shared capability accepted an ambiguous per-agent provider"
fi

jq '.skill_roots += [.skill_roots[0]]' "$tmp/config.json" >"$tmp/duplicate-root.json"
if ROUNDHOUSE_CONFIG="$tmp/duplicate-root.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "duplicate skill root ID passed validation"
fi

jq '.capabilities.oversized = {"value":("x" * 9000)}' "$tmp/config.json" >"$tmp/oversized.json"
if ROUNDHOUSE_CONFIG="$tmp/oversized.json" "$cli" validate-config >/dev/null 2>&1; then
  fail "oversized nested configuration string passed validation"
fi

printf '{invalid\n' >"$tmp/home/.agents/.skill-lock.json"
set +e
"$cli" collect --target test-host --section agents --output "$tmp/invalid-lock-posix.jsonl"
invalid_lock_rc=$?
set -e
[ "$invalid_lock_rc" -eq 2 ] || fail "invalid skills lock did not produce partial POSIX inventory"
"$cli" validate "$tmp/invalid-lock-posix.jsonl"
assert_contains "$(cat "$tmp/invalid-lock-posix.jsonl")" '"id":"agents:skills-cli-lock"'
rm -f "$tmp/home/.agents/.skill-lock.json"

set +e
JSM_INVALID=1 "$cli" collect --target test-host --section agents --output "$tmp/invalid-jsm.jsonl"
invalid_jsm_rc=$?
set -e
[ "$invalid_jsm_rc" -eq 2 ] || fail "invalid JSM JSON did not produce partial inventory"
assert_contains "$(cat "$tmp/invalid-jsm.jsonl")" '"id":"agents:jsm"'

cp "$tmp/skill-lock-fixture.json" "$tmp/home/.agents/.skill-lock.json"
jq '.skills["--danger"] = {
  source:"fixture",sourceUrl:"fixture",skillPath:"skills/danger",
  skillFolderHash:"danger-hash",installedAt:"2026-01-01",updatedAt:"2026-01-02"
}' "$tmp/home/.agents/.skill-lock.json" >"$tmp/option-skill-lock.json"
mv "$tmp/option-skill-lock.json" "$tmp/home/.agents/.skill-lock.json"
JSM_OPTION_NAME=1 "$cli" collect --target test-host --section agents --section auth \
  --output "$tmp/option-agent-snapshot.jsonl"
cat >"$tmp/option-skills-plan-draft.json" <<'JSON'
{
  "domain": "agents",
  "target": "test-host",
  "operations": [{
    "type": "agent-update",
    "kind": "skill",
    "id": "skills-cli:--danger",
    "argv": ["npx", "skills", "update", "--danger", "-g", "-y"]
  }]
}
JSON
"$cli" seal-plan "$tmp/option-skills-plan-draft.json" \
  "$tmp/option-agent-snapshot.jsonl" "$tmp/option-skills-plan.json"
option_skills_plan_id=$(jq -r '.plan_id' "$tmp/option-skills-plan.json")
rm -f "$AGENT_EXEC_MARKER"
if JSM_OPTION_NAME=1 "$cli" apply-plan "$tmp/option-skills-plan.json" \
  "$option_skills_plan_id" "$tmp/option-skills-result.jsonl" >/dev/null 2>&1; then
  fail "option-shaped skills-cli name was executed"
fi
[ ! -e "$AGENT_EXEC_MARKER" ] ||
  fail "option-shaped skills-cli name reached the native command"

cat >"$tmp/option-jsm-plan-draft.json" <<'JSON'
{
  "domain": "agents",
  "target": "test-host",
  "operations": [{
    "type": "agent-update",
    "kind": "skill",
    "id": "jsm:--danger",
    "argv": ["jsm", "upgrade", "--danger"]
  }]
}
JSON
"$cli" seal-plan "$tmp/option-jsm-plan-draft.json" \
  "$tmp/option-agent-snapshot.jsonl" "$tmp/option-jsm-plan.json"
option_jsm_plan_id=$(jq -r '.plan_id' "$tmp/option-jsm-plan.json")
rm -f "$AGENT_EXEC_MARKER"
if JSM_OPTION_NAME=1 "$cli" apply-plan "$tmp/option-jsm-plan.json" \
  "$option_jsm_plan_id" "$tmp/option-jsm-result.jsonl" >/dev/null 2>&1; then
  fail "option-shaped JSM name was executed"
fi
[ ! -e "$AGENT_EXEC_MARKER" ] ||
  fail "option-shaped JSM name reached the native command"
cp "$tmp/skill-lock-fixture.json" "$tmp/home/.agents/.skill-lock.json"

set +e
CODEX_PLUGIN_LIST_INVALID=1 "$cli" collect --target test-host --section agents --output "$tmp/invalid-codex-plugins-posix.jsonl"
invalid_codex_plugins_rc=$?
set -e
[ "$invalid_codex_plugins_rc" -eq 2 ] ||
  fail "invalid Codex plugin manager JSON did not produce partial POSIX inventory"
"$cli" validate "$tmp/invalid-codex-plugins-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "plugin_manager" and .id == "codex" and .status == "unavailable")) | length' "$tmp/invalid-codex-plugins-posix.jsonl")" -eq 1 ] ||
  fail "invalid Codex plugin manager JSON was not reported on POSIX"
[ "$(jq -s 'map(select(.kind == "plugin" and .data.agent == "codex")) | length' "$tmp/invalid-codex-plugins-posix.jsonl")" -eq 0 ] ||
  fail "POSIX cache evidence was promoted when the Codex manager query failed"
[ "$(jq -s 'map(select(.kind == "plugin_cache" and .id == "codex:test-market:example:1.2.3")) | length' "$tmp/invalid-codex-plugins-posix.jsonl")" -eq 1 ] ||
  fail "POSIX manager failure discarded distinct Codex cache evidence"
[ "$(jq -s 'map(select(.kind == "plugin_cache" and .id == "codex:test-market:example:1.2.3" and .data.install_state == "manager-unverified" and .data.active == null)) | length' "$tmp/invalid-codex-plugins-posix.jsonl")" -eq 1 ] ||
  fail "POSIX manager failure mislabeled unknown active cache state"

set +e
CODEX_PLUGIN_LIST_INVALID_SHAPE=1 "$cli" collect --target test-host --section agents --output "$tmp/invalid-codex-plugin-shape-posix.jsonl"
invalid_codex_plugin_shape_rc=$?
set -e
[ "$invalid_codex_plugin_shape_rc" -eq 2 ] ||
  fail "invalid Codex plugin manager shape did not produce partial POSIX inventory"
"$cli" validate "$tmp/invalid-codex-plugin-shape-posix.jsonl"
[ "$(jq -s 'map(select(.kind == "plugin_manager" and .id == "codex" and .status == "unavailable")) | length' "$tmp/invalid-codex-plugin-shape-posix.jsonl")" -eq 1 ] ||
  fail "invalid Codex plugin manager shape was not reported on POSIX"
[ "$(jq -s 'map(select(.kind == "plugin" and .data.agent == "codex")) | length' "$tmp/invalid-codex-plugin-shape-posix.jsonl")" -eq 0 ] ||
  fail "POSIX invalid manager shape produced active Codex plugins"
[ "$(jq -s 'map(select(.kind == "plugin_cache" and .id == "codex:test-market:example:1.2.3" and .data.install_state == "manager-unverified" and .data.active == null)) | length' "$tmp/invalid-codex-plugin-shape-posix.jsonl")" -eq 1 ] ||
  fail "POSIX invalid manager shape did not preserve unverified cache evidence"

cp "$tmp/skill-lock-fixture.json" "$tmp/home/.agents/.skill-lock.json"
