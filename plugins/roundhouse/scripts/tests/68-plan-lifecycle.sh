# roundhouse self-check — seal, verify-preconditions and apply across the
# ordinary lanes.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

AUTH_CHECK_FAIL=1 "$cli" collect --target test-host --section auth \
  --output "$tmp/reauth-required-auth-posix.jsonl"
"$cli" validate "$tmp/reauth-required-auth-posix.jsonl"
cat >"$tmp/reauth-plan-draft.json" <<'JSON'
{
  "domain": "auth",
  "target": "test-host",
  "operations": [{
    "type": "auth-reauth",
    "kind": "auth_artifact",
    "id": "native-test-auth",
    "argv": ["auth-check", "login"]
  }]
}
JSON
if ROUNDHOUSE_CONFIG="$tmp/ignore-native-auth.json" \
  "$cli" seal-plan "$tmp/reauth-plan-draft.json" "$tmp/reauth-required-auth-posix.jsonl" \
  "$tmp/ignored-reauth-plan.json" >/dev/null 2>&1; then
  fail "seal-plan accepted reauthentication for an ignored auth artifact"
fi
jq '.operations[0].argv += ["--unexpected"]' "$tmp/reauth-plan-draft.json" \
  >"$tmp/mismatched-reauth-plan-draft.json"
if "$cli" seal-plan "$tmp/mismatched-reauth-plan-draft.json" \
  "$tmp/reauth-required-auth-posix.jsonl" "$tmp/mismatched-reauth-plan.json" \
  >/dev/null 2>&1; then
  fail "seal-plan accepted a reauthentication command that did not match configuration"
fi
"$cli" seal-plan "$tmp/reauth-plan-draft.json" "$tmp/reauth-required-auth-posix.jsonl" \
  "$tmp/reauth-plan.json"
[ "$(jq -r '.operations[0].type' "$tmp/reauth-plan.json")" = auth-reauth ] ||
  fail "seal-plan rejected a configured reauthentication operation"

cat >"$tmp/plan-draft.json" <<JSON
{
  "domain": "updates",
  "target": "test-host",
  "operations": [
    {
      "type": "package-upgrade",
      "kind": "package",
      "id": "homebrew:git",
      "candidate_version": "2.51.0",
      "argv": ["touch", "$tmp/plan-must-stay-inert"]
    }
  ]
}
JSON
jq '.operations[0].kind = "project"' "$tmp/plan-draft.json" >"$tmp/wrong-kind-plan-draft.json"
if "$cli" seal-plan "$tmp/wrong-kind-plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/wrong-kind-plan.json" >/dev/null 2>&1; then
  fail "update plan sealed against an unrelated same-ID entity kind"
fi
jq '.domain = "agents" |
  .operations[0] = {
    type:"agent-install",kind:"skill",id:"skills-cli:capability-example",
    argv:["npx","skills","add","capability-example"]
  }' "$tmp/plan-draft.json" >"$tmp/unsupported-plan-draft.json"
if "$cli" seal-plan "$tmp/unsupported-plan-draft.json" "$tmp/snapshot.jsonl" \
  "$tmp/unsupported-plan.json" >/dev/null 2>&1; then
  fail "unsupported agent install survived plan sealing"
fi
"$cli" seal-plan "$tmp/plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/plan.json"
[ "$(jq -r '.schema_version' "$tmp/plan.json")" -eq 2 ] ||
  fail "sealed plan did not use executor-bound schema version"
[ "$(jq -r '.required_executor.version' "$tmp/plan.json")" = "$plugin_version" ] ||
  fail "sealed plan did not bind the exact executor"
"$cli" worker-config test-host updates "$tmp/local-worker-config.json"
[ "$(jq -r '.worker_configuration_digest.value' "$tmp/plan.json")" = \
  "$(shasum -a 256 "$tmp/local-worker-config.json" | awk '{print $1}')" ] ||
  fail "sealed plan did not bind the deterministic worker config"
[ "$(test_file_mode "$tmp/plan.json")" = 600 ] ||
  fail "sealed plan mode is not 600"
verification=$("$cli" verify-preconditions "$tmp/plan.json" "$tmp/snapshot-2.jsonl")
assert_contains "$verification" '"verified":true'
[ ! -e "$tmp/plan-must-stay-inert" ] || fail "plan text was executed"
plan_id=$(jq -r '.plan_id' "$tmp/plan.json")
if "$cli" apply-plan "$tmp/plan.json" "$plan_id" "$tmp/unsafe-apply.jsonl" >/dev/null 2>&1; then
  fail "apply executor ran a non-manager command from a package plan"
fi
[ ! -e "$tmp/plan-must-stay-inert" ] || fail "unsafe apply command was executed"

if "$cli" verify-preconditions "$tmp/plan.json" "$tmp/snapshot.jsonl" >/dev/null 2>&1; then
  fail "planning snapshot was accepted as a fresh recapture"
fi

"$cli" collect --target test-host --section host --output "$tmp/host-only.jsonl"
if "$cli" seal-plan "$tmp/plan-draft.json" "$tmp/host-only.jsonl" "$tmp/host-only-plan.json" >/dev/null 2>&1; then
  fail "update plan sealed without package inventory"
fi

jq '.operations[0].id = "homebrew:tampered"' "$tmp/plan.json" >"$tmp/tampered-plan.json"
chmod 600 "$tmp/tampered-plan.json"
if "$cli" verify-preconditions "$tmp/tampered-plan.json" "$tmp/snapshot-2.jsonl" >/dev/null 2>&1; then
  fail "tampered plan passed integrity check"
fi

jq -c 'if .kind == "package" and .id == "homebrew:git" then .data.installed_version = "9.9.9" else . end' \
  "$tmp/snapshot-2.jsonl" >"$tmp/drifted-snapshot.jsonl"
if "$cli" verify-preconditions "$tmp/plan.json" "$tmp/drifted-snapshot.jsonl" >/dev/null 2>&1; then
  fail "changed preconditions passed apply authorization"
fi

cat >"$tmp/safe-plan-draft.json" <<'JSON'
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
jq '.machines["test-host"].expected_hostname = "definitely-not-this-host"' \
  "$tmp/config.json" >"$tmp/mismatched-local-config.json"
chmod 600 "$tmp/mismatched-local-config.json"
ROUNDHOUSE_CONFIG="$tmp/mismatched-local-config.json" \
  "$cli" collect --target test-host --section host --section packages \
  --output "$tmp/mismatched-local-snapshot.jsonl"
ROUNDHOUSE_CONFIG="$tmp/mismatched-local-config.json" \
  "$cli" seal-plan "$tmp/safe-plan-draft.json" "$tmp/mismatched-local-snapshot.jsonl" \
  "$tmp/mismatched-local-plan.json"
mismatched_local_plan_id=$(jq -r '.plan_id' "$tmp/mismatched-local-plan.json")
rm -f "$BREW_EXEC_MARKER"
if ROUNDHOUSE_CONFIG="$tmp/mismatched-local-config.json" \
  "$cli" apply-plan "$tmp/mismatched-local-plan.json" "$mismatched_local_plan_id" \
  "$tmp/mismatched-local-result.jsonl" >/dev/null 2>&1; then
  fail "local mutation accepted a mismatched configured host identity"
fi
[ ! -e "$BREW_EXEC_MARKER" ] ||
  fail "local identity mismatch reached the package manager"

"$cli" seal-plan "$tmp/safe-plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/safe-plan.json"
safe_plan_id=$(jq -r '.plan_id' "$tmp/safe-plan.json")
printf '%s\n' 9.9.9 >"$BREW_STATE_FILE"
if "$cli" apply-plan "$tmp/safe-plan.json" \
  "$safe_plan_id" "$tmp/replayed-apply.jsonl" >/dev/null 2>&1; then
  fail "apply trusted the supplied snapshot instead of recapturing live state"
fi
printf '%s\n' 2.50.0 >"$BREW_STATE_FILE"
if BREW_UPGRADE_VERSION=2.52.0 "$cli" apply-plan "$tmp/safe-plan.json" \
  "$safe_plan_id" "$tmp/wrong-candidate-apply.jsonl" >/dev/null 2>&1; then
  fail "apply accepted a package version other than the sealed candidate"
fi
printf '%s\n' 2.50.0 >"$BREW_STATE_FILE"
"$cli" apply-plan "$tmp/safe-plan.json" "$safe_plan_id" "$tmp/applied.jsonl"
"$cli" validate "$tmp/applied.jsonl"
[ "$(jq -r 'select(.kind == "package" and .id == "homebrew:git") | .data.installed_version' "$tmp/applied.jsonl")" = 2.51.0 ] ||
  fail "package apply did not verify the upgraded native-manager version"
[ "$(jq -r 'select(.kind == "operation" and (.id | startswith("apply:"))) | .data.operation_status' "$tmp/applied.jsonl")" = completed ] ||
  fail "package apply emitted no completed verification operation"

cp "$tmp/skill-lock-fixture.json" "$tmp/home/.agents/.skill-lock.json"
cat >"$tmp/runtime-plan-draft.json" <<'JSON'
{
  "domain": "agents",
  "target": "test-host",
  "operations": [{
    "type": "agent-update",
    "kind": "agent_runtime",
    "id": "codex",
    "argv": ["codex", "update"]
  }]
}
JSON
jq -c 'if .kind == "agent_runtime" and .id == "codex" then
  .status = "absent" | .data = {runtime:"codex"}
else . end' "$tmp/snapshot.jsonl" >"$tmp/runtime-absent-snapshot.jsonl"
if "$cli" seal-plan "$tmp/runtime-plan-draft.json" "$tmp/runtime-absent-snapshot.jsonl" \
  "$tmp/runtime-absent-plan.json" >/dev/null 2>&1; then
  fail "absent runtime sealed an update instead of requiring installer flow"
fi
"$cli" seal-plan "$tmp/runtime-plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/runtime-plan.json"
runtime_plan_id=$(jq -r '.plan_id' "$tmp/runtime-plan.json")
rm -f "$RUNTIME_UPDATE_MARKER"
"$cli" apply-plan "$tmp/runtime-plan.json" "$runtime_plan_id" "$tmp/runtime-result.jsonl"
[ "$(cat "$RUNTIME_UPDATE_MARKER")" = codex ] || fail "exact Codex runtime updater was not executed"
[ "$(jq -r --arg plan "$runtime_plan_id" 'select(.kind == "operation" and .id == ("apply:" + $plan)) | .data.operation_status' "$tmp/runtime-result.jsonl")" = completed ] ||
  fail "already-current runtime update was not accepted after post-inventory"
jq '.operations[0].argv += ["--force"]' "$tmp/runtime-plan-draft.json" >"$tmp/unsafe-runtime-plan-draft.json"
"$cli" seal-plan "$tmp/unsafe-runtime-plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/unsafe-runtime-plan.json"
unsafe_runtime_plan_id=$(jq -r '.plan_id' "$tmp/unsafe-runtime-plan.json")
rm -f "$RUNTIME_UPDATE_MARKER"
if "$cli" apply-plan "$tmp/unsafe-runtime-plan.json" "$unsafe_runtime_plan_id" \
  "$tmp/unsafe-runtime-result.jsonl" >/dev/null 2>&1; then
  fail "runtime update accepted extra argv"
fi
[ ! -e "$RUNTIME_UPDATE_MARKER" ] || fail "unsafe runtime argv reached the native command"

cat >"$tmp/agent-plan-draft.json" <<'JSON'
{
  "domain": "agents",
  "target": "test-host",
  "operations": [
    {
      "type": "agent-update",
      "kind": "skill",
      "id": "skills-cli:capability-example",
      "argv": ["npx", "skills", "update", "capability-example", "-g", "-y"]
    }
  ]
}
JSON
"$cli" seal-plan "$tmp/agent-plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/agent-plan.json"
agent_plan_id=$(jq -r '.plan_id' "$tmp/agent-plan.json")
jq '.operations[0].argv[3] = "different-skill"' "$tmp/agent-plan-draft.json" \
  >"$tmp/unsafe-agent-plan-draft.json"
"$cli" seal-plan "$tmp/unsafe-agent-plan-draft.json" "$tmp/snapshot.jsonl" \
  "$tmp/unsafe-agent-plan.json"
unsafe_agent_plan_id=$(jq -r '.plan_id' "$tmp/unsafe-agent-plan.json")
rm -f "$AGENT_EXEC_MARKER"
if "$cli" apply-plan "$tmp/unsafe-agent-plan.json" "$unsafe_agent_plan_id" \
  "$tmp/unsafe-agent-result.jsonl" >/dev/null 2>&1; then
  fail "agent mutation accepted argv for a different skill"
fi
[ ! -e "$AGENT_EXEC_MARKER" ] ||
  fail "unsafe agent argv reached the native manager"
if SKILLS_UPDATE_NOOP=1 "$cli" apply-plan "$tmp/agent-plan.json" \
  "$agent_plan_id" "$tmp/agent-noop.jsonl" >/dev/null 2>&1; then
  fail "agent update reported success without changing manager state"
fi
if SKILLS_UPDATE_TIMESTAMP_ONLY=1 "$cli" apply-plan "$tmp/agent-plan.json" \
  "$agent_plan_id" "$tmp/agent-timestamp-only.jsonl" >/dev/null 2>&1; then
  fail "agent update treated a timestamp-only change as updated manager state"
fi
cp "$tmp/skill-lock-fixture.json" "$tmp/home/.agents/.skill-lock.json"
rm -f "$SKILLS_UPDATE_MARKER"
"$cli" apply-plan "$tmp/agent-plan.json" \
  "$agent_plan_id" "$tmp/agent-applied.jsonl"
[ -e "$SKILLS_UPDATE_MARKER" ] || fail "safe skills-cli update was not executed"

printf '%s\n' 1.2.3 >"$CODEX_STATE_FILE"
cat >"$tmp/codex-plugin-agent-plan-draft.json" <<'JSON'
{
  "domain": "agents",
  "target": "test-host",
  "operations": [
    {
      "type": "agent-update",
      "kind": "plugin",
      "id": "codex:test-market:example:1.2.3",
      "argv": ["codex", "plugin", "add", "example@test-market", "--json"]
    }
  ]
}
JSON
"$cli" seal-plan "$tmp/codex-plugin-agent-plan-draft.json" "$tmp/snapshot.jsonl" \
  "$tmp/codex-plugin-agent-plan.json"
codex_plugin_agent_plan_id=$(jq -r '.plan_id' "$tmp/codex-plugin-agent-plan.json")
"$cli" apply-plan "$tmp/codex-plugin-agent-plan.json" \
  "$codex_plugin_agent_plan_id" "$tmp/codex-plugin-agent-result.jsonl"
[ "$(jq -s 'map(select(.kind == "plugin" and .id == "codex:test-market:example:1.3.0")) | length' \
  "$tmp/codex-plugin-agent-result.jsonl")" -eq 1 ] ||
  fail "Codex plugin update did not execute the exact native manager command"

printf '%s\n' 2.0.0 >"$CLAUDE_STATE_FILE"
cat >"$tmp/plugin-agent-plan-draft.json" <<'JSON'
{
  "domain": "agents",
  "target": "test-host",
  "operations": [
    {
      "type": "agent-update",
      "kind": "plugin",
      "id": "claude:test-market:claude-example:2.0.0",
      "argv": ["claude", "plugin", "update", "claude-example@test-market", "--scope", "user"]
    }
  ]
}
JSON
"$cli" seal-plan "$tmp/plugin-agent-plan-draft.json" "$tmp/snapshot.jsonl" \
  "$tmp/plugin-agent-plan.json"
plugin_agent_plan_id=$(jq -r '.plan_id' "$tmp/plugin-agent-plan.json")
CLAUDE_MANAGER_STDOUT=1 "$cli" apply-plan "$tmp/plugin-agent-plan.json" \
  "$plugin_agent_plan_id" "$tmp/plugin-agent-result.jsonl"
"$cli" validate "$tmp/plugin-agent-result.jsonl"
[ "$(jq -s 'map(select(.kind == "plugin" and .id == "claude:test-market:claude-example:3.0.0")) | length' \
  "$tmp/plugin-agent-result.jsonl")" -eq 1 ] ||
  fail "plugin update did not match the changed versioned record by stable identity"
[ "$(jq -r --arg plan "$plugin_agent_plan_id" '
  select(.kind == "operation" and .id == ("apply:" + $plan)) |
  .data.operation_status' \
  "$tmp/plugin-agent-result.jsonl")" = completed ] ||
  fail "plugin update with a changed versioned ID was not authoritatively completed"
if grep -q 'manager progress' "$tmp/plugin-agent-result.jsonl"; then
  fail "manager stdout corrupted local apply JSONL"
fi

printf '%s\n' 2.0.0 >"$CLAUDE_STATE_FILE"
"$cli" collect --target test-ssh --section agents --section auth \
  --output "$tmp/ssh-agent-plan-snapshot.jsonl"
jq '.target = "test-ssh"' "$tmp/plugin-agent-plan-draft.json" \
  >"$tmp/ssh-agent-plan-draft.json"
"$cli" seal-plan "$tmp/ssh-agent-plan-draft.json" \
  "$tmp/ssh-agent-plan-snapshot.jsonl" "$tmp/ssh-agent-plan.json"
ssh_agent_plan_id=$(jq -r '.plan_id' "$tmp/ssh-agent-plan.json")
cat >"$tmp/ssh-reauth-plan-draft.json" <<'JSON'
{
  "domain": "auth",
  "target": "test-ssh",
  "operations": [{
    "type": "auth-reauth",
    "kind": "auth_artifact",
    "id": "native-test-auth",
    "argv": ["auth-check", "login"]
  }]
}
JSON
"$cli" seal-plan "$tmp/ssh-reauth-plan-draft.json" \
  "$tmp/ssh-agent-plan-snapshot.jsonl" "$tmp/ssh-reauth-plan.json"
ssh_reauth_plan_id=$(jq -r '.plan_id' "$tmp/ssh-reauth-plan.json")
: >"$SSH_COMMAND_LOG"
: >"$SCP_COMMAND_LOG"
if "$cli" apply-ssh-plan "$tmp/ssh-reauth-plan.json" "$ssh_reauth_plan_id" \
  "$tmp/ssh-reauth-result.jsonl" >/dev/null 2>&1; then
  fail "SSH apply accepted interactive reauthentication"
fi
[ ! -s "$SSH_COMMAND_LOG" ] && [ ! -s "$SCP_COMMAND_LOG" ] ||
  fail "SSH reauthentication rejection contacted the target"
: >"$SSH_COMMAND_LOG"
: >"$SCP_COMMAND_LOG"
: >"$SSH_LOGIN_SHELL_LOG"
rm -f "$SSH_REMOTE_DIR_LOG"
CLAUDE_MANAGER_STDOUT=1 "$cli" apply-ssh-plan "$tmp/ssh-agent-plan.json" \
  "$ssh_agent_plan_id" "$tmp/ssh-agent-result.jsonl"
"$cli" validate "$tmp/ssh-agent-result.jsonl"
[ "$(jq -r --arg plan "$ssh_agent_plan_id" '
  select(.kind == "operation" and .id == ("apply:" + $plan)) |
  .data.operation_status' \
  "$tmp/ssh-agent-result.jsonl")" = completed ] ||
  fail "SSH apply returned no authoritative completed operation"
[ "$(jq -r --arg plan "$ssh_agent_plan_id" '
  select(.kind == "operation" and .id == ("apply:" + $plan)) |
  .data.executor.version' "$tmp/ssh-agent-result.jsonl")" = "$plugin_version" ] ||
  fail "SSH apply did not report the exact sealed executor version"
[ "$(jq -s 'map(select(.kind == "plugin" and .id == "claude:test-market:claude-example:3.0.0")) | length' \
  "$tmp/ssh-agent-result.jsonl")" -eq 1 ] ||
  fail "SSH apply did not return native post-state"
if grep -q 'manager progress' "$tmp/ssh-agent-result.jsonl"; then
  fail "manager stdout corrupted SSH result JSONL"
fi
[ "$(wc -l <"$SCP_COMMAND_LOG" | tr -d ' ')" -eq 2 ] ||
  fail "SSH apply transferred more than bounded config and plan inputs"
assert_contains "$(cat "$SCP_COMMAND_LOG")" '/config.json'
assert_contains "$(cat "$SCP_COMMAND_LOG")" '/plan.json'
assert_contains "$(cat "$SSH_COMMAND_LOG")" 'ConnectTimeout=10'
assert_contains "$(cat "$SSH_COMMAND_LOG")" 'ServerAliveInterval=15'
assert_contains "$(cat "$SSH_COMMAND_LOG")" 'ServerAliveCountMax=2'
[ -s "$SSH_LOGIN_SHELL_LOG" ] || fail "SSH apply did not use the configured login shell"
if grep -vF 'exec "$SHELL" -lc' "$SSH_COMMAND_LOG" >/dev/null; then
  fail "SSH apply bypassed the configured login shell"
fi
ssh_remote_dir=$(cat "$SSH_REMOTE_DIR_LOG")
case $ssh_remote_dir in
  /tmp/roundhouse-apply.*) ;;
  *) fail "SSH apply did not use a /tmp target workspace" ;;
esac
[ ! -e "$ssh_remote_dir" ] || fail "SSH apply did not clean its target workspace"

cat >"$tmp/project-plan-draft.json" <<JSON
{
  "domain": "projects",
  "target": "test-host",
  "operations": [
    {
      "type": "project-clone",
      "kind": "project",
      "id": "clone-example",
      "argv": ["git", "clone", "--", "https://github.com/owner/clone-example.git", "$tmp/home/dev/nested/clone-example"]
    }
  ]
}
JSON
"$cli" seal-plan "$tmp/project-plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/project-plan.json"
project_plan_id=$(jq -r '.plan_id' "$tmp/project-plan.json")
jq --arg path "$tmp/home/dev/outside-clone" '.operations[0].argv[4] = $path' \
  "$tmp/project-plan-draft.json" >"$tmp/unsafe-project-plan-draft.json"
"$cli" seal-plan "$tmp/unsafe-project-plan-draft.json" "$tmp/snapshot.jsonl" \
  "$tmp/unsafe-project-plan.json"
unsafe_project_plan_id=$(jq -r '.plan_id' "$tmp/unsafe-project-plan.json")
rm -rf "$tmp/home/dev/outside-clone"
if "$cli" apply-plan "$tmp/unsafe-project-plan.json" "$unsafe_project_plan_id" \
  "$tmp/unsafe-project-result.jsonl" >/dev/null 2>&1; then
  fail "project mutation accepted a destination outside its configured path"
fi
[ ! -e "$tmp/home/dev/outside-clone" ] ||
  fail "unsafe project argv reached Git"
mkdir -p "$tmp/home/dev/symlink-escape"
ln -s "$tmp/home/dev/symlink-escape" "$tmp/home/dev/nested"
if "$cli" apply-plan "$tmp/project-plan.json" "$project_plan_id" \
  "$tmp/symlink-project-result.jsonl" >/dev/null 2>&1; then
  fail "project clone followed a symlinked parent below dev_root"
fi
[ ! -e "$tmp/home/dev/symlink-escape/clone-example" ] ||
  fail "project clone wrote through a symlinked parent"
rm "$tmp/home/dev/nested"
"$cli" apply-plan "$tmp/project-plan.json" \
  "$project_plan_id" "$tmp/project-applied.jsonl"
[ "$(jq -r 'select(.kind == "project" and .id == "clone-example") | .data.repository_readiness' \
  "$tmp/project-applied.jsonl")" = ready ] ||
  fail "GitHub shorthand project source was not expanded and cloned"
[ -d "$tmp/home/dev/nested/clone-example/.git" ] ||
  fail "project clone did not create its missing nested parent"

clone_branch=$("$REAL_GIT" -C "$tmp/home/dev/nested/clone-example" symbolic-ref --short HEAD)
printf 'updated\n' >>"$tmp/home/dev/example/file.txt"
"$REAL_GIT" -C "$tmp/home/dev/example" add file.txt
"$REAL_GIT" -C "$tmp/home/dev/example" -c commit.gpgsign=false commit -qm update
"$REAL_GIT" -C "$tmp/home/dev/example" push -q "$GIT_CLONE_FIXTURE" \
  "HEAD:refs/heads/$clone_branch"
"$REAL_GIT" -C "$tmp/home/dev/nested/clone-example" fetch -q "$GIT_CLONE_FIXTURE" \
  "refs/heads/$clone_branch:refs/remotes/origin/$clone_branch"

cat >"$tmp/project-update-plan-draft.json" <<JSON
{
  "domain": "projects",
  "target": "test-host",
  "operations": [
    {
      "type": "project-update",
      "kind": "project",
      "id": "clone-example",
      "argv": ["git", "-C", "$tmp/home/dev/nested/clone-example", "pull", "--ff-only"]
    }
  ]
}
JSON
"$cli" collect --target test-host --section projects \
  --output "$tmp/project-update-snapshot.jsonl"
"$cli" seal-plan "$tmp/project-update-plan-draft.json" \
  "$tmp/project-update-snapshot.jsonl" "$tmp/project-update-plan.json"
project_update_plan_id=$(jq -r '.plan_id' "$tmp/project-update-plan.json")
mv "$tmp/home/dev/nested" "$tmp/home/dev/nested-real"
ln -s "$tmp/home/dev/nested-real" "$tmp/home/dev/nested"
rm -f "$GIT_PULL_MARKER"
if "$cli" apply-plan "$tmp/project-update-plan.json" "$project_update_plan_id" \
  "$tmp/symlink-project-update-result.jsonl" >/dev/null 2>&1; then
  fail "project update followed a symlinked parent below dev_root"
fi
[ ! -e "$GIT_PULL_MARKER" ] ||
  fail "symlinked project update reached Git"
rm "$tmp/home/dev/nested"
mv "$tmp/home/dev/nested-real" "$tmp/home/dev/nested"
mv "$tmp/home/dev/nested/clone-example" "$tmp/home/dev/clone-example-real"
ln -s "$tmp/home/dev/clone-example-real" "$tmp/home/dev/nested/clone-example"
if "$cli" apply-plan "$tmp/project-update-plan.json" "$project_update_plan_id" \
  "$tmp/symlink-checkout-update-result.jsonl" >/dev/null 2>&1; then
  fail "project update followed a symlinked checkout"
fi
[ ! -e "$GIT_PULL_MARKER" ] ||
  fail "symlinked checkout update reached Git"
rm "$tmp/home/dev/nested/clone-example"
mv "$tmp/home/dev/clone-example-real" "$tmp/home/dev/nested/clone-example"

if GIT_PULL_NOOP=1 "$cli" apply-plan "$tmp/project-update-plan.json" \
  "$project_update_plan_id" "$tmp/noop-project-update-result.jsonl" >/dev/null 2>&1; then
  fail "project update accepted an unchanged HEAD"
fi
"$cli" apply-plan "$tmp/project-update-plan.json" "$project_update_plan_id" \
  "$tmp/project-update-result.jsonl"
[ "$(jq -r --arg plan "$project_update_plan_id" '
  select(.kind == "operation" and .id == ("apply:" + $plan)) |
  .data.operation_status' "$tmp/project-update-result.jsonl")" = completed ] ||
  fail "behind project update was not verified as completed"
"$cli" collect --target test-host --section projects \
  --output "$tmp/project-current-snapshot.jsonl"
if "$cli" seal-plan "$tmp/project-update-plan-draft.json" \
  "$tmp/project-current-snapshot.jsonl" "$tmp/project-current-plan.json" >/dev/null 2>&1; then
  fail "up-to-date project checkout was accepted for update"
fi

"$cli" record-codex-readiness "$tmp/project-applied.jsonl" "$tmp/codex-readiness.json" \
  "$tmp/project-enriched.jsonl"
[ "$(jq -r --arg plan "$project_plan_id" '
  select(.kind == "operation" and .id == ("apply:" + $plan)) |
  [.data.task_id,.data.correlation_id] | @tsv
' "$tmp/project-enriched.jsonl")" = "$(printf 'task-opaque-id\tcorrelation-opaque-id')" ] ||
  fail "Codex readiness did not enrich the apply operation correlation"

cat >"$tmp/chezmoi-plan-draft.json" <<'JSON'
{
  "domain": "chezmoi",
  "target": "test-host",
  "operations": [
    {
      "type": "chezmoi-pull",
      "kind": "file",
      "id": "chezmoi:source",
      "argv": ["chezmoi", "git", "--", "pull", "--ff-only"]
    },
    {
      "type": "chezmoi-apply",
      "kind": "chezmoi_state",
      "id": "live",
      "argv": ["chezmoi", "--no-tty", "apply"]
    }
  ]
}
JSON
CHEZMOI_STATUS_DRIFT=1 "$cli" collect --target test-host --section chezmoi \
  --output "$tmp/chezmoi-drift-snapshot.jsonl"
[ "$(jq -r 'select(.kind == "chezmoi_state" and .id == "live") |
  [.status,.data.drift_count] | @tsv' "$tmp/chezmoi-drift-snapshot.jsonl")" = "$(printf 'present\t1')" ] ||
  fail "successfully measured chezmoi drift was not usable inventory"
jq -c 'if .kind == "file" and .id == "chezmoi:source" then .status = "absent" else . end' \
  "$tmp/chezmoi-drift-snapshot.jsonl" >"$tmp/chezmoi-absent-source-snapshot.jsonl"
if "$cli" seal-plan "$tmp/chezmoi-plan-draft.json" \
  "$tmp/chezmoi-absent-source-snapshot.jsonl" "$tmp/chezmoi-absent-source-plan.json" \
  >/dev/null 2>&1; then
  fail "chezmoi pull accepted an absent source repository"
fi
"$cli" seal-plan "$tmp/chezmoi-plan-draft.json" "$tmp/chezmoi-drift-snapshot.jsonl" \
  "$tmp/chezmoi-drift-plan.json"
"$cli" seal-plan "$tmp/chezmoi-plan-draft.json" "$tmp/snapshot.jsonl" "$tmp/chezmoi-plan.json"
chezmoi_plan_id=$(jq -r '.plan_id' "$tmp/chezmoi-plan.json")
jq '.operations[0].argv += ["--force"]' "$tmp/chezmoi-plan-draft.json" \
  >"$tmp/unsafe-chezmoi-plan-draft.json"
"$cli" seal-plan "$tmp/unsafe-chezmoi-plan-draft.json" "$tmp/snapshot.jsonl" \
  "$tmp/unsafe-chezmoi-plan.json"
unsafe_chezmoi_plan_id=$(jq -r '.plan_id' "$tmp/unsafe-chezmoi-plan.json")
rm -f "$CHEZMOI_APPLY_MARKER"
rm -f "$CHEZMOI_PULL_MARKER"
if "$cli" apply-plan "$tmp/unsafe-chezmoi-plan.json" "$unsafe_chezmoi_plan_id" \
  "$tmp/unsafe-chezmoi-result.jsonl" >/dev/null 2>&1; then
  fail "chezmoi mutation accepted extra argv"
fi
[ ! -e "$CHEZMOI_APPLY_MARKER" ] ||
  fail "unsafe chezmoi argv reached the native command"
[ ! -e "$CHEZMOI_PULL_MARKER" ] ||
  fail "unsafe chezmoi pull argv reached the native command"
"$cli" apply-plan "$tmp/chezmoi-plan.json" \
  "$chezmoi_plan_id" "$tmp/chezmoi-applied.jsonl"
[ -e "$CHEZMOI_PULL_MARKER" ] || fail "safe chezmoi fast-forward pull was not executed"
[ -e "$CHEZMOI_APPLY_MARKER" ] || fail "safe chezmoi apply was not executed"

targeted_chezmoi_path="$tmp/home/.profile.d/10-env.sh"
mkdir -p "$(dirname -- "$targeted_chezmoi_path")"
: >"$targeted_chezmoi_path"
cat >"$tmp/targeted-chezmoi-plan-draft.json" <<JSON
{
  "domain": "chezmoi",
  "target": "test-host",
  "operations": [{
    "type": "chezmoi-apply",
    "kind": "chezmoi_state",
    "id": "live",
    "targets": ["$targeted_chezmoi_path"],
    "argv": ["chezmoi", "--no-tty", "apply", "--", "$targeted_chezmoi_path"]
  }]
}
JSON
CHEZMOI_STATUS_DRIFT=1 "$cli" collect --target test-host --section chezmoi \
  --output "$tmp/targeted-chezmoi-snapshot.jsonl"
"$cli" seal-plan "$tmp/targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/targeted-chezmoi-plan.json"
targeted_chezmoi_plan_id=$(jq -r '.plan_id' "$tmp/targeted-chezmoi-plan.json")
rm -f "$CHEZMOI_TARGET_APPLY_MARKER"
if "$cli" apply-plan "$tmp/targeted-chezmoi-plan.json" \
  "$targeted_chezmoi_plan_id" "$tmp/targeted-chezmoi-clean-result.jsonl" >"$tmp/targeted-chezmoi-clean.stderr" 2>&1; then
  fail "targeted chezmoi apply accepted a clean target"
fi
grep -F "roundhouse: chezmoi targets are not drifted" "$tmp/targeted-chezmoi-clean.stderr" >/dev/null ||
  fail "targeted chezmoi apply did not reject a clean target"
[ ! -e "$CHEZMOI_TARGET_APPLY_MARKER" ] ||
  fail "clean targeted chezmoi apply reached the native command"
CHEZMOI_TARGET_STATUS_DRIFT=1 "$cli" apply-plan "$tmp/targeted-chezmoi-plan.json" \
  "$targeted_chezmoi_plan_id" "$tmp/targeted-chezmoi-applied.jsonl"
[ -e "$CHEZMOI_TARGET_APPLY_MARKER" ] || fail "targeted chezmoi apply was not executed"
[ "$(jq -r --arg plan "$targeted_chezmoi_plan_id" '
  select(.kind == "operation" and .id == ("apply:" + $plan)) | .data.operation_status
' "$tmp/targeted-chezmoi-applied.jsonl")" = completed ] ||
  fail "targeted chezmoi apply did not report completed verification"
jq '.operations[0].argv += ["--force"]' "$tmp/targeted-chezmoi-plan-draft.json" \
  >"$tmp/unsafe-targeted-chezmoi-plan-draft.json"
"$cli" seal-plan "$tmp/unsafe-targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/unsafe-targeted-chezmoi-plan.json"
unsafe_targeted_chezmoi_plan_id=$(jq -r '.plan_id' "$tmp/unsafe-targeted-chezmoi-plan.json")
rm -f "$CHEZMOI_TARGET_APPLY_MARKER"
if CHEZMOI_TARGET_STATUS_DRIFT=1 "$cli" apply-plan "$tmp/unsafe-targeted-chezmoi-plan.json" \
  "$unsafe_targeted_chezmoi_plan_id" "$tmp/unsafe-targeted-chezmoi-result.jsonl" >/dev/null 2>&1; then
  fail "targeted chezmoi mutation accepted extra argv"
fi
[ ! -e "$CHEZMOI_TARGET_APPLY_MARKER" ] ||
  fail "unsafe targeted chezmoi argv reached the native command"
jq --arg target "$tmp/outside-home" \
  '.operations[0].targets = [$target] | .operations[0].argv[4] = $target' \
  "$tmp/targeted-chezmoi-plan-draft.json" >"$tmp/outside-home-targeted-chezmoi-plan-draft.json"
"$cli" seal-plan "$tmp/outside-home-targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/outside-home-targeted-chezmoi-plan.json"
outside_home_targeted_chezmoi_plan_id=$(jq -r '.plan_id' "$tmp/outside-home-targeted-chezmoi-plan.json")
rm -f "$CHEZMOI_TARGET_APPLY_MARKER"
if CHEZMOI_TARGET_STATUS_DRIFT=1 "$cli" apply-plan "$tmp/outside-home-targeted-chezmoi-plan.json" \
  "$outside_home_targeted_chezmoi_plan_id" "$tmp/outside-home-targeted-chezmoi-result.jsonl" >/dev/null 2>&1; then
  fail "targeted chezmoi mutation accepted a path outside the target home"
fi
[ ! -e "$CHEZMOI_TARGET_APPLY_MARKER" ] ||
  fail "outside-home targeted chezmoi argv reached the native command"
mkdir -p "$tmp/outside-home"
ln -s "$tmp/outside-home" "$tmp/home/target-link"
jq --arg target "$tmp/home/target-link/env.sh" \
  '.operations[0].targets = [$target] | .operations[0].argv[4] = $target' \
  "$tmp/targeted-chezmoi-plan-draft.json" >"$tmp/symlink-targeted-chezmoi-plan-draft.json"
"$cli" seal-plan "$tmp/symlink-targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/symlink-targeted-chezmoi-plan.json"
symlink_targeted_chezmoi_plan_id=$(jq -r '.plan_id' "$tmp/symlink-targeted-chezmoi-plan.json")
rm -f "$CHEZMOI_TARGET_APPLY_MARKER"
if CHEZMOI_TARGET_STATUS_DRIFT=1 "$cli" apply-plan "$tmp/symlink-targeted-chezmoi-plan.json" \
  "$symlink_targeted_chezmoi_plan_id" "$tmp/symlink-targeted-chezmoi-result.jsonl" >/dev/null 2>&1; then
  fail "targeted chezmoi mutation accepted a symbolic-link escape"
fi
[ ! -e "$CHEZMOI_TARGET_APPLY_MARKER" ] ||
  fail "symbolic-link targeted chezmoi argv reached the native command"
jq '.operations[0].targets = ["relative-path"] | .operations[0].argv[4] = "relative-path"' \
  "$tmp/targeted-chezmoi-plan-draft.json" >"$tmp/malformed-targeted-chezmoi-plan-draft.json"
if "$cli" seal-plan "$tmp/malformed-targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/malformed-targeted-chezmoi-plan.json" >/dev/null 2>&1; then
  fail "targeted chezmoi plan accepted a malformed target"
fi
jq '.operations[0].targets = ["C:\\\\Users\\\\Fixture\\\\.config\\\\example"] |
  .operations[0].argv[4] = "C:\\\\Users\\\\Fixture\\\\.config\\\\example"' \
  "$tmp/targeted-chezmoi-plan-draft.json" >"$tmp/cross-platform-targeted-chezmoi-plan-draft.json"
if "$cli" seal-plan "$tmp/cross-platform-targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/cross-platform-targeted-chezmoi-plan.json" >/dev/null 2>&1; then
  fail "POSIX targeted chezmoi plan accepted a Windows target path"
fi
jq '.operations[0].targets = ["C:relative\\\\example"] |
  .operations[0].argv[4] = "C:relative\\\\example"' \
  "$tmp/targeted-chezmoi-plan-draft.json" >"$tmp/drive-relative-targeted-chezmoi-plan-draft.json"
if "$cli" seal-plan "$tmp/drive-relative-targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/drive-relative-targeted-chezmoi-plan.json" >/dev/null 2>&1; then
  fail "targeted chezmoi plan accepted a drive-relative path"
fi
jq --arg target "$targeted_chezmoi_path" \
  '.operations[0].targets = [$target, $target] | .operations[0].argv += [$target]' \
  "$tmp/targeted-chezmoi-plan-draft.json" >"$tmp/duplicate-targeted-chezmoi-plan-draft.json"
if "$cli" seal-plan "$tmp/duplicate-targeted-chezmoi-plan-draft.json" \
  "$tmp/targeted-chezmoi-snapshot.jsonl" "$tmp/duplicate-targeted-chezmoi-plan.json" >/dev/null 2>&1; then
  fail "targeted chezmoi plan accepted duplicate targets"
fi

"$cli" collect --target test-host --section auth --output "$tmp/auth-plan-snapshot.jsonl"
sleep 1
"$cli" collect --target test-host --section auth --output "$tmp/auth-current-snapshot.jsonl"
cat >"$tmp/auth-plan-draft.json" <<'JSON'
{
  "domain": "auth",
  "target": "test-host",
  "operations": [
    {
      "type": "auth-install",
      "kind": "auth_artifact",
      "id": "test-auth",
      "argv": ["op", "read", "op://test/item/value"]
    }
  ]
}
JSON
jq 'del(.auth_artifacts["test-auth"].path) |
  .auth_artifacts["test-auth"].paths = {"test-windows":"~/.test-auth"}' \
  "$tmp/config.json" >"$tmp/auth-other-target-path-config.json"
chmod 600 "$tmp/auth-other-target-path-config.json"
if ROUNDHOUSE_CONFIG="$tmp/auth-other-target-path-config.json" \
  "$cli" seal-plan "$tmp/auth-plan-draft.json" "$tmp/auth-plan-snapshot.jsonl" \
  "$tmp/auth-missing-target-path-plan.json" >/dev/null 2>&1; then
  fail "auth install sealed without a path for its target"
fi
"$cli" seal-plan "$tmp/auth-plan-draft.json" "$tmp/auth-plan-snapshot.jsonl" "$tmp/auth-plan.json"
auth_plan_id=$(jq -r '.plan_id' "$tmp/auth-plan.json")
"$cli" apply-plan "$tmp/auth-plan.json" "$auth_plan_id" "$tmp/auth-applied.jsonl"
"$cli" validate "$tmp/auth-applied.jsonl"
cmp -s "$OP_SECRET_FILE" "$tmp/home/.test-auth" ||
  fail "encrypted auth install did not atomically install the retrieved bytes"
if find "$tmp/home" -name '.roundhouse-auth*' -print -quit | grep -q .; then
  fail "encrypted auth install left a temporary or backup file"
fi

"$cli" collect --target test-host --section auth --output "$tmp/auth-rollback-plan-snapshot.jsonl"
sleep 1
"$cli" collect --target test-host --section auth --output "$tmp/auth-rollback-current-snapshot.jsonl"
"$cli" seal-plan "$tmp/auth-plan-draft.json" "$tmp/auth-rollback-plan-snapshot.jsonl" "$tmp/auth-rollback-plan.json"
auth_rollback_plan_id=$(jq -r '.plan_id' "$tmp/auth-rollback-plan.json")
cp "$tmp/home/.test-auth" "$tmp/auth-before-failed-verify"
printf '%s\n' '{"portable":"invalid"}' >"$OP_SECRET_FILE"
if AUTH_CHECK_FAIL=1 "$cli" apply-plan "$tmp/auth-rollback-plan.json" \
  "$auth_rollback_plan_id" "$tmp/auth-rollback-result.jsonl" >/dev/null 2>&1; then
  fail "encrypted auth install succeeded despite failed native verification"
fi
cmp -s "$tmp/auth-before-failed-verify" "$tmp/home/.test-auth" ||
  fail "failed auth verification did not restore the prior credential file"
if find "$tmp/home" -name '.roundhouse-auth*' -print -quit | grep -q .; then
  fail "failed auth verification left a temporary or backup file"
fi

cp "$tmp/home/.test-auth" "$tmp/auth-before-signal"
auth_mode_before_signal=$(test_file_mode "$tmp/home/.test-auth")
printf '%s\n' '{"portable":"signal-interrupted"}' >"$OP_SECRET_FILE"
rm -f "$tmp/auth-signal-marker"
if AUTH_CHECK_SIGNAL_PARENT=1 AUTH_CHECK_SIGNAL_MARKER="$tmp/auth-signal-marker" \
  "$cli" apply-plan "$tmp/auth-rollback-plan.json" "$auth_rollback_plan_id" \
  "$tmp/auth-signal-result.jsonl" >/dev/null 2>&1; then
  fail "signal-interrupted auth install reported success"
fi
[ -e "$tmp/auth-signal-marker" ] ||
  fail "auth signal fixture did not interrupt verification after installation"
cmp -s "$tmp/auth-before-signal" "$tmp/home/.test-auth" ||
  fail "signal interruption did not restore original credential bytes"
[ "$(test_file_mode "$tmp/home/.test-auth")" = "$auth_mode_before_signal" ] ||
  fail "signal interruption did not restore original credential mode"
if find "$tmp/home" -name '.roundhouse-auth*' -print -quit | grep -q .; then
  fail "signal-interrupted auth install left a temporary or backup file"
fi

chmod 666 "$tmp/config.json"
if "$cli" check-mutation-config >/dev/null 2>&1; then
  fail "writable mutation config passed integrity check"
fi
