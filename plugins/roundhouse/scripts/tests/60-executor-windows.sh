# roundhouse self-check — executor status, integrity coverage, the native
# Windows hook path and worker config.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

"$cli" validate-config
"$cli" executor-status "$tmp/executor.json"
[ "$(jq -r '.version' "$tmp/executor.json")" = "$plugin_version" ] ||
  fail "executor status did not report release version"
[ "$(jq -r '.verified' "$tmp/executor.json")" = true ] ||
  fail "executor status was not verified"
"$cli" verify-executor "$tmp/executor.json" >/dev/null

# An unlisted file under scripts/ used to ship unhashed: update-integrity
# hand-listed what it covered and executor-status verified only what the
# manifest listed, so neither ever saw it. Both now enumerate the tree.
integrity_cover="$tmp/integrity-cover"
mkdir -p "$integrity_cover"
cp -R "$script_dir/../." "$integrity_cover/"
chmod -R go-w "$integrity_cover"
"$integrity_cover/scripts/update-integrity"
"$integrity_cover/scripts/roundhouse" executor-status "$tmp/integrity-cover-executor.json"
jq -e '.files | any(.path == "references/codex-remote-control.md")' \
  "$integrity_cover/integrity.json" >/dev/null ||
  fail "integrity manifest omitted an enumerated references file"
jq -e '.files | any(.path == "scripts/lib/host.sh")' \
  "$integrity_cover/integrity.json" >/dev/null ||
  fail "integrity manifest omitted a sourced CLI unit"
jq -e '.files | all(.path != "scripts/test-roundhouse" and .path != "scripts/update-integrity" and
  (.path | startswith("scripts/tests/") | not))' \
  "$integrity_cover/integrity.json" >/dev/null ||
  fail "integrity manifest covered a non-release script"
# The self-check sections are excluded on purpose, exactly like their driver:
# hashing them would make every fixture edit a release-content change. Pin that
# so the closed-world check below cannot silently start covering them either.
printf '# not release content\n' >"$integrity_cover/scripts/tests/zz-smuggled-section.sh"
"$integrity_cover/scripts/roundhouse" executor-status - >/dev/null ||
  fail "executor status rejected a self-check section, which is not release content"
rm -f "$integrity_cover/scripts/tests/zz-smuggled-section.sh"
printf '#!/bin/sh\nexit 0\n' >"$integrity_cover/scripts/smuggled-helper"
chmod 700 "$integrity_cover/scripts/smuggled-helper"
if "$integrity_cover/scripts/roundhouse" executor-status - >/dev/null 2>&1; then
  fail "executor status accepted a scripts/ file absent from the integrity manifest"
fi
"$integrity_cover/scripts/update-integrity"
"$integrity_cover/scripts/roundhouse" executor-status - >/dev/null ||
  fail "integrity enumeration did not pick up a new scripts/ file"
rm -rf "$integrity_cover"

if [ -n "$pwsh_command" ]; then
  rm -f "$CODEX_HOOK_WRITES_FILE"
  windows_hook_approval=$(CODEX_HOOK_SCENARIO=approve "$pwsh_command" -NoLogo -NoProfile \
    -File "$plugin_cache/scripts/apply-windows.ps1" \
    -ApproveCodexPluginHooks example@test-market \
    -ExecutorRequirementPath "$tmp/executor.json")
  [ "$(printf '%s\n' "$windows_hook_approval" | jq -r '.approved')" = true ] ||
    fail "native Windows hook approval path did not complete"
  [ "$(jq -s '.[0].edits | length' "$CODEX_HOOK_WRITES_FILE")" -eq 4 ] ||
    fail "native Windows hook approval path did not trust exact current hooks"
  rm -f "$CODEX_HOOK_WRITES_FILE"
fi
mkdir -p "$tmp/gnu-stat-bin"
cat >"$tmp/gnu-stat-bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -f ] && [ "${2:-}" = %Su ]; then
  printf '  File: fake GNU stat filesystem report\n'
  exit 1
fi
if [ "${1:-}" = -c ] && [ "${2:-}" = %U ]; then
  id -un
  exit
fi
if [ "${1:-}" = -f ] && [ "${2:-}" = %Lp ]; then
  printf '  File: fake GNU stat filesystem report\n'
  exit 1
fi
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then
  exec "$REAL_STAT" -f %Lp "$3" 2>/dev/null || exec "$REAL_STAT" -c %a "$3"
fi
if [ "${1:-}" = -c ] && [ "${2:-}" = %s ]; then
  exec "$REAL_STAT" -f %z "$3" 2>/dev/null || exec "$REAL_STAT" -c %s "$3"
fi
if [ "${1:-}" = -c ] && [ "${2:-}" = %y ]; then
  printf '2026-01-01 00:00:00.000000000 +0000\n'
  exit
fi
if [ "${1:-}" = -c ] && [ "${2:-}" = %W ]; then
  printf '0\n'
  exit
fi
if [ "${1:-}" = -f ]; then
  printf '  File: fake GNU stat filesystem report\n'
  exit 1
fi
exec "$REAL_STAT" "$@"
SH
chmod +x "$tmp/gnu-stat-bin/stat"
REAL_STAT="$real_stat" PATH="$tmp/gnu-stat-bin:$PATH" \
  "$cli" executor-status "$tmp/gnu-stat-executor.json"
[ "$(jq -r '.verified' "$tmp/gnu-stat-executor.json")" = true ] ||
  fail "executor status captured failed GNU stat output as the file owner"
REAL_STAT="$real_stat" PATH="$tmp/gnu-stat-bin:$PATH" \
  "$cli" collect --target test-host --section auth --output "$tmp/gnu-stat-auth.jsonl"
"$cli" validate "$tmp/gnu-stat-auth.jsonl"
jq '.files[0].sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$tmp/executor.json" >"$tmp/stale-executor.json"
if "$cli" verify-executor "$tmp/stale-executor.json" >/dev/null 2>&1; then
  fail "executor verification accepted a stale file hash"
fi
"$cli" worker-config test-ssh inventory "$tmp/ssh-worker-config.json"
[ "$(jq -r '.worker.target' "$tmp/ssh-worker-config.json")" = test-ssh ] ||
  fail "bounded worker config did not retain its target"
[ "$(jq '.machines | length' "$tmp/ssh-worker-config.json")" -eq 1 ] ||
  fail "bounded worker config leaked unrelated machines"
[ "$(jq -r '.handoff_project' "$tmp/ssh-worker-config.json")" = example ] ||
  fail "inventory worker config did not retain its configured handoff project"
"$cli" worker-config test-windows updates "$tmp/windows-updates-worker-config.json"
[ "$(jq -r '.machines["test-windows"].codex_control_project' \
  "$tmp/windows-updates-worker-config.json")" = example ] ||
  fail "Windows worker config did not retain its Codex control project"
[ "$(jq -r '.projects | keys == ["example"]' \
  "$tmp/windows-updates-worker-config.json")" = true ] ||
  fail "Windows worker config did not retain only its required control project"
