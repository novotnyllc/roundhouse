# roundhouse self-check — the WSL interop lane to native Windows: config
# validation, collect, executor fail-closed, and sealed apply (the lane
# fixtures are skipped without pwsh).
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

interop_config="$tmp/interop-config.json"
jq --arg hostname "$(hostname)" --arg user "$(id -un)" '
  .machines["test-wsl"] = {
    platform:"wsl",transport:"ssh",ssh_alias:"fake-wsl",
    expected_hostname:$hostname,expected_user:$user,
    groups:["development"],package_managers:[],dev_root:"~/dev",physical_host:"fixture-hardware"
  } |
  .machines["test-windows"].wsl_interop_via = "test-wsl" |
  .machines["test-windows"].physical_host = "fixture-hardware" |
  del(.machines["test-windows"].codex_control_project)
' "$ROUNDHOUSE_CONFIG" >"$interop_config"
chmod 600 "$interop_config"
ROUNDHOUSE_CONFIG="$interop_config" "$cli" validate-config ||
  fail "a native-Windows entry with a valid WSL interop sibling was rejected"
for interop_invalid in \
  '.machines["test-windows"].wsl_interop_via = "missing-machine"' \
  '.machines["test-windows"].wsl_interop_via = "test-ssh"' \
  '.machines["test-wsl"].transport = "local" | del(.machines["test-wsl"].ssh_alias)' \
  '.machines["test-windows"].wsl_interop_via = "../test-wsl"' \
  '.machines["test-windows"].wsl_interop_via = ["test-wsl"]' \
  '.machines["test-windows"].physical_host = "other-hardware"' \
  '.machines["test-ssh"].wsl_interop_via = "test-wsl"'; do
  jq "$interop_invalid" "$interop_config" >"$tmp/interop-invalid-config.json"
  chmod 600 "$tmp/interop-invalid-config.json"
  if ROUNDHOUSE_CONFIG="$tmp/interop-invalid-config.json" "$cli" validate-config >/dev/null 2>&1; then
    fail "config validation accepted an invalid WSL interop sibling: $interop_invalid"
  fi
done
# The bounded worker config carries only its own target, so its dangling
# sibling reference is expected there and must still validate.
ROUNDHOUSE_CONFIG="$interop_config" "$cli" worker-config test-windows inventory \
  "$tmp/interop-worker-config.json"
[ "$(jq -r '.machines | keys | join(",")' "$tmp/interop-worker-config.json")" = test-windows ] ||
  fail "interop worker config leaked the WSL sibling machine"

# A sealed Windows plan with neither a Codex control project nor an interop
# sibling has no native lane, so sealing still refuses it; the refusal and the
# interop acceptance are both covered once a real snapshot exists below.

# Local refusals: nothing may reach the target for a malformed, tampered, or
# misconfirmed plan. These need no pwsh: the lane must refuse before launch.
cat >"$tmp/interop-unsealed-plan.json" <<'JSON'
{"schema":"roundhouse.plan","schema_version":2,"plan_id":"plan-0000000000000000","domain":"updates","target":"test-windows","operations":[{"type":"package-upgrade","kind":"package","id":"winget:Example.Package","candidate_version":"2.0.0","argv":["winget","upgrade","--id","Example.Package","--exact","--version","2.0.0","--accept-package-agreements","--accept-source-agreements","--disable-interactivity"]}],"required_section":"packages","planning_snapshot_id":"x","planning_observed_at":"2026-01-01T00:00:00Z","configuration_digest":{"algorithm":"sha256","value":"0000000000000000000000000000000000000000000000000000000000000000"},"worker_configuration_digest":{"algorithm":"sha256","value":"0000000000000000000000000000000000000000000000000000000000000000"},"precondition_digest":{"algorithm":"sha256","value":"0000000000000000000000000000000000000000000000000000000000000000"},"required_executor":{"plugin":"roundhouse","marketplace":"novotnyllc","version":"0.0.0","integrity_manifest_sha256":"0000000000000000000000000000000000000000000000000000000000000000","files":[]},"plan_digest":{"algorithm":"sha256","value":"0000000000000000000000000000000000000000000000000000000000000000"},"created_at":"2026-01-01T00:00:00Z"}
JSON
chmod 600 "$tmp/interop-unsealed-plan.json"
: >"$SSH_COMMAND_LOG"
if ROUNDHOUSE_CONFIG="$interop_config" "$cli" apply-interop-plan "$tmp/interop-unsealed-plan.json" \
  plan-0000000000000000 "$tmp/interop-unsealed-result.jsonl" 2>"$tmp/interop-unsealed.err"; then
  fail "apply-interop-plan accepted a plan whose digest does not match"
fi
assert_contains "$(cat "$tmp/interop-unsealed.err")" 'apply plan integrity check failed'
jq '.schema_version = 3' "$tmp/interop-unsealed-plan.json" >"$tmp/interop-protected-plan.json"
chmod 600 "$tmp/interop-protected-plan.json"
if ROUNDHOUSE_CONFIG="$interop_config" "$cli" apply-interop-plan "$tmp/interop-protected-plan.json" \
  plan-0000000000000000 "$tmp/interop-protected-result.jsonl" >/dev/null 2>&1; then
  fail "apply-interop-plan accepted a protected plan schema"
fi
[ ! -s "$SSH_COMMAND_LOG" ] || fail "a locally refused interop plan reached the WSL sibling"
[ ! -e "$tmp/interop-unsealed-result.jsonl" ] && [ ! -e "$tmp/interop-protected-result.jsonl" ] ||
  fail "a locally refused interop plan wrote a result"

if [ -n "$pwsh_command" ]; then
  # The WSL sibling: the ssh stub runs the lane's remote sh locally. The fake
  # drive root stands in for /mnt/c and its pwsh.exe for full-path PowerShell
  # 7; it asserts the lane changed to the drive root first, then runs real
  # pwsh as the "Windows" user whose profile holds the installed executor.
  interop_drive="$tmp/interop-drive"
  mkdir -p "$interop_drive/Program Files/PowerShell/7" "$tmp/interop-windows-temp" "$tmp/interop-bin"
  cat >"$interop_drive/Program Files/PowerShell/7/pwsh.exe" <<'SH'
#!/usr/bin/env bash
[ "$(pwd -P)" = "$(CDPATH='' cd -P -- "$INTEROP_DRIVE" && pwd -P)" ] || {
  printf 'interop fixture: Windows process did not start from the drive root\n' >&2
  exit 97
}
[ -z "${INTEROP_PWSH_LOG:-}" ] || printf '%s\n' "$*" >>"$INTEROP_PWSH_LOG"
if [ -n "${INTEROP_FAKE_ENVELOPE:-}" ]; then
  cat >/dev/null
  printf 'stray native output\r\n'
  cat "$INTEROP_FAKE_ENVELOPE"
  exit 0
fi
export HOME="$INTEROP_WINDOWS_HOME"
export TMPDIR="$INTEROP_WINDOWS_TEMP"
exec "$REAL_PWSH" "$@"
SH
  chmod +x "$interop_drive/Program Files/PowerShell/7/pwsh.exe"
  # Probes the private staging directory while the native worker runs.
  cat >"$tmp/interop-bin/winget" <<'SH'
#!/usr/bin/env bash
if [ -n "${INTEROP_STAGE_LOG:-}" ]; then
  for stage in "$INTEROP_WINDOWS_TEMP"/roundhouse-interop-*; do
    [ -d "$stage" ] || continue
    printf 'stage %s %s\n' "$(stat -c %a "$stage" 2>/dev/null || stat -f %Lp "$stage")" \
      "$(cd "$stage" && ls | tr '\n' ' ')" >>"$INTEROP_STAGE_LOG"
  done
fi
exec "$INTEROP_REAL_WINGET" "$@"
SH
  chmod +x "$tmp/interop-bin/winget"
  export INTEROP_DRIVE="$interop_drive" INTEROP_WINDOWS_TEMP="$tmp/interop-windows-temp"
  export INTEROP_REAL_WINGET="$tmp/bin/winget" REAL_PWSH="$pwsh_command"
  export ROUNDHOUSE_INTEROP_ROOT="$interop_drive"
  export ROUNDHOUSE_INTEROP_PWSH="$interop_drive/Program Files/PowerShell/7/pwsh.exe"
  interop_stage_clean() {
    [ -z "$(ls -A "$tmp/interop-windows-temp")" ] ||
      fail "interop staging directory was not removed: $1"
  }

  # Collect: the installed, integrity-verified executor in the "Windows"
  # profile runs natively and its records come back validated and unchanged.
  : >"$SSH_COMMAND_LOG"
  : >"$tmp/interop-stage.log"
  INTEROP_WINDOWS_HOME="$tmp/home" INTEROP_STAGE_LOG="$tmp/interop-stage.log" \
    INTEROP_PWSH_LOG="$tmp/interop-pwsh.log" PATH="$tmp/interop-bin:$PATH" \
    ROUNDHOUSE_CONFIG="$interop_config" "$cli" collect --target test-windows \
    --section packages --section chezmoi --output "$tmp/interop-collect.jsonl" ||
    fail "collect over the WSL interop lane did not complete"
  "$cli" validate "$tmp/interop-collect.jsonl"
  interop_config_hash=$(shasum -a 256 "$interop_config" | awk '{print $1}')
  interop_worker_hash=$(shasum -a 256 "$tmp/interop-worker-config.json" | awk '{print $1}')
  jq -e -s --arg digest "$interop_config_hash" --arg worker "$interop_worker_hash" '
    all(.[]; .host_id == "test-windows") and
    ([.[] | select(.kind == "snapshot")] | length == 1 and
      .[0].data.configuration_digest.value == $digest and
      .[0].data.configuration_digest.scope == "controller-raw-bytes" and
      .[0].data.worker_configuration_digest.value == $worker and
      (.[0].data.sections | sort) == ["chezmoi","packages"]) and
    any(.[]; .kind == "chezmoi_state" and .id == "live") and
    any(.[]; .kind == "package" and .id == "winget:Example.Package" and .data.candidate_version == "2.0.0") and
    ([.[] | select(.kind == "operation")] | length == 1 and .[0].id == "collect" and
      .[0].data.operation_status == "completed")
  ' "$tmp/interop-collect.jsonl" >/dev/null ||
    fail "interop collect did not return the native worker's bound snapshot"
  assert_contains "$(cat "$SSH_COMMAND_LOG")" 'fake-wsl'
  assert_contains "$(cat "$tmp/interop-pwsh.log")" '-NoProfile -NonInteractive -EncodedCommand'
  grep -q '^stage 700 config.json executor.json $' "$tmp/interop-stage.log" ||
    fail "interop collect did not stage exactly its bounded inputs in an owner-only directory"
  interop_stage_clean collect

  # The Codex task lane is still the answer when no interop sibling exists.
  jq 'del(.machines["test-windows"].wsl_interop_via)' "$interop_config" >"$tmp/interop-no-lane-config.json"
  chmod 600 "$tmp/interop-no-lane-config.json"
  if ROUNDHOUSE_CONFIG="$tmp/interop-no-lane-config.json" "$cli" collect --target test-windows \
    --section host --output "$tmp/interop-no-lane.jsonl" 2>/dev/null; then
    fail "collect without an interop sibling claimed a native Windows inventory"
  fi
  jq -e -s 'any(.[]; .kind == "error" and .errors[0].code == "codex_task_required")' \
    "$tmp/interop-no-lane.jsonl" >/dev/null || fail "collect without an interop sibling lost the Codex task fallback"

  # Executor fail-closed: no installed executor of the controller's version,
  # and an installed one whose bytes differ. Neither may run the collector.
  mkdir -p "$tmp/interop-empty-home/.codex/plugins/cache/novotnyllc/roundhouse/0.0.1"
  : >"$tmp/interop-stage.log"
  if INTEROP_WINDOWS_HOME="$tmp/interop-empty-home" INTEROP_STAGE_LOG="$tmp/interop-stage.log" \
    PATH="$tmp/interop-bin:$PATH" ROUNDHOUSE_CONFIG="$interop_config" "$cli" collect \
    --target test-windows --section packages --output "$tmp/interop-missing-executor.jsonl" \
    2>"$tmp/interop-missing-executor.err"; then
    fail "interop collect succeeded without the controller's executor installed"
  fi
  assert_contains "$(cat "$tmp/interop-missing-executor.err")" \
    "executor_update_required: test-windows has no verified roundhouse $plugin_version executor"
  assert_contains "$(cat "$tmp/interop-missing-executor.err")" 'installed: 0.0.1'
  jq -e -s 'any(.[]; .kind == "error" and .id == "executor:wsl-interop" and
    .errors[0].code == "executor_update_required") and
    any(.[]; .kind == "operation" and .data.operation_status == "blocked")' \
    "$tmp/interop-missing-executor.jsonl" >/dev/null ||
    fail "interop executor mismatch was not recorded as executor_update_required"
  [ ! -s "$tmp/interop-stage.log" ] || fail "interop collect ran the collector without a matching executor"
  interop_stage_clean missing-executor

  interop_stale_root="$tmp/interop-stale-home/.claude/plugins/cache/novotnyllc/roundhouse/$plugin_version"
  mkdir -p "$interop_stale_root"
  cp -R "$plugin_cache/." "$interop_stale_root/"
  printf '\nNew-Item -ItemType File -Path "%s" -Force | Out-Null\n' "$tmp/interop-stale-ran" \
    >>"$interop_stale_root/scripts/collect-windows.ps1"
  : >"$tmp/interop-stage.log"
  if INTEROP_WINDOWS_HOME="$tmp/interop-stale-home" INTEROP_STAGE_LOG="$tmp/interop-stage.log" \
    PATH="$tmp/interop-bin:$PATH" ROUNDHOUSE_CONFIG="$interop_config" "$cli" collect \
    --target test-windows --section packages --output "$tmp/interop-stale-executor.jsonl" \
    2>"$tmp/interop-stale-executor.err"; then
    fail "interop collect ran a modified installed executor"
  fi
  assert_contains "$(cat "$tmp/interop-stale-executor.err")" 'failed integrity verification against the controller'
  [ ! -e "$tmp/interop-stale-ran" ] && [ ! -s "$tmp/interop-stage.log" ] ||
    fail "interop collect executed an installed executor that failed verification"
  interop_stage_clean stale-executor
  # A tampered installed verifier never executes at all.
  cp "$plugin_cache/scripts/collect-windows.ps1" "$interop_stale_root/scripts/collect-windows.ps1"
  printf '\nNew-Item -ItemType File -Path "%s" -Force | Out-Null\n' "$tmp/interop-stale-verifier-ran" \
    >>"$interop_stale_root/scripts/apply-windows.ps1"
  if INTEROP_WINDOWS_HOME="$tmp/interop-stale-home" PATH="$tmp/interop-bin:$PATH" \
    ROUNDHOUSE_CONFIG="$interop_config" "$cli" collect --target test-windows --section packages \
    --output "$tmp/interop-stale-verifier.jsonl" 2>"$tmp/interop-stale-verifier.err"; then
    fail "interop collect accepted a modified installed verifier"
  fi
  assert_contains "$(cat "$tmp/interop-stale-verifier.err")" 'installed apply-windows.ps1 does not match the controller'
  [ ! -e "$tmp/interop-stale-verifier-ran" ] || fail "interop executed an installed verifier whose bytes did not match"
  interop_stage_clean stale-verifier

  # Sealed apply. The fixture executor is a copy of this release whose only
  # change lets apply-windows.ps1 run off Windows; the controller and the
  # "installed" Windows executor are that same copy, so verification is real.
  interop_executor="$tmp/interop-executor"
  mkdir -p "$interop_executor"
  cp -R "$plugin_cache/." "$interop_executor/"
  interop_before=$(shasum -a 256 "$interop_executor/scripts/apply-windows.ps1")
  sed 's/if (-not \$IsWindows -or \$Machine.platform -ne "windows" -or/if ($Machine.platform -ne "windows" -or/' \
    "$interop_executor/scripts/apply-windows.ps1" >"$tmp/interop-apply-windows.ps1"
  cat "$tmp/interop-apply-windows.ps1" >"$interop_executor/scripts/apply-windows.ps1"
  [ "$(shasum -a 256 "$interop_executor/scripts/apply-windows.ps1")" != "$interop_before" ] ||
    fail "interop fixture could not relax the native platform check"
  chmod -R go-w "$interop_executor"
  "$interop_executor/scripts/update-integrity"
  interop_cli="$interop_executor/scripts/roundhouse"
  interop_apply_root="$tmp/interop-apply-home/.codex/plugins/cache/novotnyllc/roundhouse/$plugin_version"
  mkdir -p "$interop_apply_root"
  cp -R "$interop_executor/." "$interop_apply_root/"
  chmod -R go-w "$tmp/interop-apply-home"
  export INTEROP_WINDOWS_HOME="$tmp/interop-apply-home"
  export WINGET_STATE_FILE="$tmp/interop-winget-state"
  rm -f "$WINGET_STATE_FILE"

  ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" collect --target test-windows \
    --section packages --output "$tmp/interop-plan-snapshot.jsonl" ||
    fail "interop planning inventory did not complete"
  cat >"$tmp/interop-package-draft.json" <<'JSON'
{"domain":"updates","target":"test-windows","operations":[{"type":"package-upgrade","kind":"package","id":"winget:Example.Package","candidate_version":"2.0.0","argv":["winget","upgrade","--id","Example.Package","--exact","--version","2.0.0","--accept-package-agreements","--accept-source-agreements","--disable-interactivity"]}]}
JSON
  # With neither a Codex control project nor an interop sibling there is no
  # native lane, so sealing refuses; either one is enough.
  if ROUNDHOUSE_CONFIG="$tmp/interop-no-lane-config.json" "$interop_cli" seal-plan \
    "$tmp/interop-package-draft.json" "$tmp/interop-plan-snapshot.jsonl" \
    "$tmp/interop-no-lane-plan.json" 2>"$tmp/interop-no-lane-seal.err"; then
    fail "a Windows plan sealed without a Codex control project or interop sibling"
  fi
  assert_contains "$(cat "$tmp/interop-no-lane-seal.err")" 'a configured Codex control project or WSL interop sibling'
  ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" seal-plan "$tmp/interop-package-draft.json" \
    "$tmp/interop-plan-snapshot.jsonl" "$tmp/interop-plan.json" ||
    fail "a Windows plan did not seal with only a WSL interop sibling"
  jq '.operations[0].type = "chezmoi-external-reset"' "$tmp/interop-package-draft.json" \
    >"$tmp/interop-reset-draft.json"
  if ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" seal-plan "$tmp/interop-reset-draft.json" \
    "$tmp/interop-plan-snapshot.jsonl" "$tmp/interop-reset-plan.json" >/dev/null 2>&1; then
    fail "the interop lane relaxed the native Windows operation restrictions"
  fi
  interop_plan_id=$(jq -r '.plan_id' "$tmp/interop-plan.json")
  t_next_second

  # A tampered sealed plan or a wrong confirmation never reaches the target.
  jq '.operations[0].candidate_version = "3.0.0"' "$tmp/interop-plan.json" >"$tmp/interop-tampered-plan.json"
  chmod 600 "$tmp/interop-tampered-plan.json"
  : >"$SSH_COMMAND_LOG"
  if ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" apply-interop-plan "$tmp/interop-tampered-plan.json" \
    "$interop_plan_id" "$tmp/interop-tampered-result.jsonl" 2>"$tmp/interop-tampered.err"; then
    fail "apply-interop-plan accepted a tampered sealed plan"
  fi
  assert_contains "$(cat "$tmp/interop-tampered.err")" 'apply plan integrity check failed'
  if ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" apply-interop-plan "$tmp/interop-plan.json" \
    plan-0000000000000000 "$tmp/interop-tampered-result.jsonl" 2>"$tmp/interop-wrong-id.err"; then
    fail "apply-interop-plan accepted the wrong plan ID"
  fi
  assert_contains "$(cat "$tmp/interop-wrong-id.err")" 'apply confirmation must equal the sealed plan ID'
  [ ! -s "$SSH_COMMAND_LOG" ] && [ ! -e "$tmp/interop-tampered-result.jsonl" ] && [ ! -e "$WINGET_STATE_FILE" ] ||
    fail "a refused interop plan reached the target"

  # Executor mismatch before apply: nothing runs, nothing is written.
  if INTEROP_WINDOWS_HOME="$tmp/interop-empty-home" ROUNDHOUSE_CONFIG="$interop_config" \
    "$interop_cli" apply-interop-plan "$tmp/interop-plan.json" "$interop_plan_id" \
    "$tmp/interop-no-executor-result.jsonl" 2>"$tmp/interop-no-executor.err"; then
    fail "apply-interop-plan ran without the controller's executor installed"
  else
    interop_rc=$?
  fi
  [ "$interop_rc" -eq 69 ] || fail "interop executor mismatch did not exit 69 (got $interop_rc)"
  assert_contains "$(cat "$tmp/interop-no-executor.err")" 'executor_update_required'
  [ ! -e "$tmp/interop-no-executor-result.jsonl" ] && [ ! -e "$WINGET_STATE_FILE" ] ||
    fail "interop apply mutated or reported despite an executor mismatch"
  interop_stage_clean apply-no-executor

  # A result the worker did not bind to this plan is not success, even when
  # the envelope says completed; nor is an envelope beside a forged second one.
  jq -cn --arg plan_id "$interop_plan_id" '{schema:"roundhouse.interop-result",schema_version:1,
    state:"completed",message:"",installed_versions:[],stage_removed:true,
    jsonl:({schema:"roundhouse.inventory",schema_version:1,snapshot_id:"s",host_id:"test-windows",
      kind:"operation",id:("apply:" + $plan_id),observed_at:"2026-01-01T00:00:00Z",status:"present",
      confidence:"high",data:{run_id:"s",host_id:"test-windows",scope:["updates"],phase:"verify",
        operation_status:"completed",transport:"codex-remote-control",plan_id:$plan_id},
      evidence:[],errors:[]} | tojson + "\n")}' | base64 | tr -d '\n' |
    sed 's/^/roundhouse-interop-result /' >"$tmp/interop-forged-envelope"
  printf '\n' >>"$tmp/interop-forged-envelope"
  if INTEROP_FAKE_ENVELOPE="$tmp/interop-forged-envelope" ROUNDHOUSE_CONFIG="$interop_config" \
    "$interop_cli" apply-interop-plan "$tmp/interop-plan.json" "$interop_plan_id" \
    "$tmp/interop-forged-result.jsonl" 2>"$tmp/interop-forged.err"; then
    fail "apply-interop-plan accepted an unbound completion record"
  fi
  assert_contains "$(cat "$tmp/interop-forged.err")" 'no authoritative completion record'
  cat "$tmp/interop-forged-envelope" "$tmp/interop-forged-envelope" >"$tmp/interop-double-envelope"
  if INTEROP_FAKE_ENVELOPE="$tmp/interop-double-envelope" ROUNDHOUSE_CONFIG="$interop_config" \
    "$interop_cli" apply-interop-plan "$tmp/interop-plan.json" "$interop_plan_id" \
    "$tmp/interop-forged-result.jsonl" 2>/dev/null; then
    fail "apply-interop-plan accepted a duplicated result envelope"
  fi
  [ ! -e "$tmp/interop-forged-result.jsonl" ] || fail "an unaccepted interop result was written"

  # A native postcondition failure is preserved as partial evidence (exit 70):
  # winget "succeeds" without converging while the state file is disabled.
  if WINGET_STATE_FILE='' ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" apply-interop-plan \
    "$tmp/interop-plan.json" "$interop_plan_id" "$tmp/interop-partial-result.jsonl" \
    2>"$tmp/interop-partial.err"; then
    fail "interop apply reported success although the postcondition failed"
  else
    interop_rc=$?
  fi
  [ "$interop_rc" -eq 70 ] || fail "interop partial apply did not exit 70 (got $interop_rc)"
  jq -e -s --arg plan_id "$interop_plan_id" '
    any(.[]; .kind == "operation" and .id == ("apply:" + $plan_id) and .status == "partial" and
      .data.operation_status == "partial" and .data.phase == "verify")
  ' "$tmp/interop-partial-result.jsonl" >/dev/null ||
    fail "interop partial apply evidence was not preserved"
  interop_stage_clean apply-partial

  # A failing native command names its own error: the controller log and the
  # failed operation record carry a bounded, sanitized tail of its output,
  # with styling and progress redraws stripped and secret-shaped lines
  # redacted. Exit code and partial-apply contract are unchanged.
  interop_known_error='Register-ScheduledTask : Access is denied.'
  if WINGET_UPGRADE_FAILURE="$interop_known_error" ROUNDHOUSE_CONFIG="$interop_config" \
    "$interop_cli" apply-interop-plan "$tmp/interop-plan.json" "$interop_plan_id" \
    "$tmp/interop-failed-result.jsonl" 2>"$tmp/interop-failed.err"; then
    fail "interop apply reported success although the native command failed"
  else
    interop_rc=$?
  fi
  [ "$interop_rc" -eq 70 ] || fail "interop execute failure did not exit 70 (got $interop_rc)"
  assert_contains "$(cat "$tmp/interop-failed.err")" 'native Windows worker reported a partial apply'
  assert_contains "$(cat "$tmp/interop-failed.err")" \
    'Windows apply failed at execute: Native command failed: winget (exit 1); output tail:'
  assert_contains "$(cat "$tmp/interop-failed.err")" "$interop_known_error"
  assert_contains "$(cat "$tmp/interop-failed.err")" 'Found Example package [Example.Package]'
  assert_contains "$(cat "$tmp/interop-failed.err")" '[redacted: line matched a secret pattern]'
  ! grep -q 'ghp_' "$tmp/interop-failed.err" "$tmp/interop-failed-result.jsonl" ||
    fail "a secret-shaped line from the failing command reached the controller"
  ! LC_ALL=C grep -q "$(printf '\033')" "$tmp/interop-failed.err" ||
    fail "ANSI styling from the failing command reached the controller log"
  jq -e -s --arg plan_id "$interop_plan_id" --arg known "$interop_known_error" '
    any(.[]; .kind == "operation" and .id == ("apply:" + $plan_id + ":0") and
      .status == "error" and .data.phase == "execute" and .data.exit_code == 1 and
      (.data.output_tail | type == "array" and length <= 20 and index($known) != null and
        all(.[]; type == "string" and length <= 240)) and
      # stdout and stderr reach the worker on separate pipes, so only order
      # WITHIN a stream is defined: the error follows the redacted secret
      # line, and the message ends with the whole sanitized tail.
      (.data.output_tail | index("[redacted: line matched a secret pattern]") as $secret |
        $secret != null and $secret < index($known)) and
      (.data.output_tail as $tail |
        .errors[0].message | endswith($tail | map(select(length > 0)) | join(" | ")))) and
    any(.[]; .kind == "operation" and .id == ("apply:" + $plan_id) and .status == "partial" and
      .data.phase == "execute" and (.errors[0].message | contains($known)))
  ' "$tmp/interop-failed-result.jsonl" >/dev/null ||
    fail "the failed operation record did not carry the sanitized output tail"
  [ ! -e "$WINGET_STATE_FILE" ] || fail "a failed interop upgrade converged the package"
  interop_stage_clean apply-execute-failure

  # Success requires the worker's matching final record.
  ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" apply-interop-plan "$tmp/interop-plan.json" \
    "$interop_plan_id" "$tmp/interop-apply-result.jsonl" ||
    fail "sealed apply over the WSL interop lane did not complete"
  [ "$(cat "$WINGET_STATE_FILE")" = 2.0.0 ] || fail "interop apply did not run the exact sealed argv"
  jq -e -s --arg plan_id "$interop_plan_id" --arg plan_sha "$(shasum -a 256 "$tmp/interop-plan.json" | awk '{print $1}')" \
    --slurpfile plan "$tmp/interop-plan.json" '
    any(.[]; .kind == "operation" and .id == ("apply:" + $plan_id) and .status == "present" and
      .data.operation_status == "completed" and .data.plan_file_sha256 == $plan_sha and
      .data.executor == $plan[0].required_executor) and
    any(.[]; .kind == "package" and .id == "winget:Example.Package" and .data.installed_version == "2.0.0")
  ' "$tmp/interop-apply-result.jsonl" >/dev/null ||
    fail "interop apply result lacked the bound completion record or post-state"
  interop_stage_clean apply

  # A chezmoi apply that exits 0 but leaves drift reports why: what apply
  # itself printed, then the read-only `chezmoi status` lines still drifting.
  cat >"$tmp/interop-chezmoi-draft.json" <<'JSON'
{"domain":"chezmoi","target":"test-windows","operations":[{"type":"chezmoi-apply","kind":"chezmoi_state","id":"live","argv":["chezmoi","--no-tty","apply"]}]}
JSON
  CHEZMOI_STATUS_DRIFT=1 ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" collect \
    --target test-windows --section chezmoi --output "$tmp/interop-chezmoi-snapshot.jsonl" ||
    fail "interop chezmoi planning inventory did not complete"
  ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" seal-plan "$tmp/interop-chezmoi-draft.json" \
    "$tmp/interop-chezmoi-snapshot.jsonl" "$tmp/interop-chezmoi-plan.json" ||
    fail "a Windows chezmoi apply plan did not seal over the interop lane"
  interop_chezmoi_plan_id=$(jq -r '.plan_id' "$tmp/interop-chezmoi-plan.json")
  t_next_second
  interop_chezmoi_note='chezmoi: warning: .chezmoiscripts/run_onchange_after_10-register-task.ps1: skipped by fixture'
  if CHEZMOI_STATUS_DRIFT=1 CHEZMOI_APPLY_STDERR="$interop_chezmoi_note" \
    ROUNDHOUSE_CONFIG="$interop_config" "$interop_cli" apply-interop-plan \
    "$tmp/interop-chezmoi-plan.json" "$interop_chezmoi_plan_id" \
    "$tmp/interop-chezmoi-result.jsonl" 2>"$tmp/interop-chezmoi.err"; then
    fail "interop chezmoi apply reported success although drift remained"
  else
    interop_rc=$?
  fi
  [ "$interop_rc" -eq 70 ] || fail "interop chezmoi drift did not exit 70 (got $interop_rc)"
  assert_contains "$(cat "$tmp/interop-chezmoi.err")" \
    'Windows apply failed at verify: Chezmoi still reports drift after apply; output tail:'
  assert_contains "$(cat "$tmp/interop-chezmoi.err")" "$interop_chezmoi_note"
  assert_contains "$(cat "$tmp/interop-chezmoi.err")" '|  M .zshrc'
  jq -e -s --arg plan_id "$interop_chezmoi_plan_id" --arg note "$interop_chezmoi_note" '
    any(.[]; .kind == "operation" and .id == ("apply:" + $plan_id + ":0") and
      .data.phase == "verify" and .data.operation_status == "failed" and
      .data.output_tail == [$note, " M .zshrc"]) and
    any(.[]; .kind == "operation" and .id == ("apply:" + $plan_id) and .status == "partial" and
      .data.phase == "verify")
  ' "$tmp/interop-chezmoi-result.jsonl" >/dev/null ||
    fail "the chezmoi drift record did not carry the apply output and remaining status"
  interop_stage_clean apply-chezmoi-drift
  unset WINGET_STATE_FILE INTEROP_WINDOWS_HOME ROUNDHOUSE_INTEROP_ROOT ROUNDHOUSE_INTEROP_PWSH
fi
