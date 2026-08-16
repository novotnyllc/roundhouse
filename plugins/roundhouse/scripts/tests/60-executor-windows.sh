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
# N17: an INSTALLED plugin cache nested inside a git repo whose .gitignore
# excludes .claude/ (a dotfiles repo - common, and likely across a fleet
# given roundhouse's own chezmoi tooling) must NOT have its manifest-
# coverage check bypassed. `rev-parse --is-inside-work-tree` alone cannot
# tell "a real roundhouse source checkout" apart from "some unrelated
# directory that happens to sit inside a work tree" - it would make
# check-ignore match every scripts/* path in the cache, filtering the
# enumerated set down to nothing and letting an unmanifested executable
# through undetected. Only whether the plugin manifest is a TRACKED file
# in that repo tells the two apart. This is the assertion that matters
# most in this file: it must fail if the weak rev-parse-only gate is ever
# restored.
dotfiles_home="$tmp/dotfiles-home"
mkdir -p "$dotfiles_home"
git -C "$dotfiles_home" init -q
printf '.claude/\n.codex/\n' >"$dotfiles_home/.gitignore"
git -C "$dotfiles_home" add .gitignore
git -C "$dotfiles_home" -c user.email=test@test.invalid -c user.name=test commit -q -m dotfiles
nested_cache="$dotfiles_home/.claude/plugins/cache/novotnyllc/roundhouse/$plugin_version"
mkdir -p "$nested_cache"
cp -R "$script_dir/../." "$nested_cache/"
# Same stripping the plugin_cache fixture above does: cp is byte-for-byte,
# so it also copies whatever git-ignored local tooling artifact (this repo
# checkout's own, e.g. .impeccable/) sits under the live source tree - not
# release content, and not what this test is about. Ignore rules are
# evaluated against the REAL checkout ($script_dir/..), not the fake nested
# copy, since that is the repo whose .gitignore/.git/info/exclude actually
# apply here.
if git -C "$script_dir/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ignore_status=0
  ignored_fixture_paths=$(
    (cd "$script_dir/.." && find . ! -type d -print | sed 's#^\./##' | git check-ignore --stdin) 2>/dev/null
  ) || ignore_status=$?
  if [ "$ignore_status" -le 1 ] && [ -n "$ignored_fixture_paths" ]; then
    printf '%s\n' "$ignored_fixture_paths" | while IFS= read -r rel; do
      [ -n "$rel" ] && rm -f "$nested_cache/$rel"
    done
  fi
fi
chmod -R go-w "$nested_cache"
printf '#!/bin/sh\nexit 0\n' >"$nested_cache/scripts/evil.sh"
chmod 700 "$nested_cache/scripts/evil.sh"
if "$nested_cache/scripts/roundhouse" executor-status - >/dev/null 2>&1; then
  fail "N17: an unmanifested scripts/ file in a plugin cache nested under a dotfiles repo bypassed the manifest-coverage check"
fi
rm -f "$nested_cache/scripts/evil.sh"
"$nested_cache/scripts/roundhouse" executor-status - >/dev/null ||
  fail "the same nested-under-dotfiles cache must pass once the unmanifested file is gone"
rm -rf "$dotfiles_home"

# N18: strengthens the tracked-manifest test with path identity. A repo
# that deliberately TRACKS an installed cache's .claude-plugin/plugin.json
# (a backup repo that commits everything, say) would still pass the
# tracked-file test above; the plugin root must also sit at the expected
# plugins/roundhouse path within that repo's toplevel, which a cache nested
# under .claude/plugins/cache/... never does. Defense in depth, not a
# boundary - someone who can already write into the cache and commit its
# manifest can edit integrity.json directly regardless - but cheap and
# real: this must fail if the path-identity check is ever dropped.
backup_home="$tmp/backup-home"
mkdir -p "$backup_home"
git -C "$backup_home" init -q
nested_backup_cache="$backup_home/.claude/plugins/cache/novotnyllc/roundhouse/$plugin_version"
mkdir -p "$nested_backup_cache"
cp -R "$script_dir/../." "$nested_backup_cache/"
if git -C "$script_dir/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ignore_status=0
  ignored_fixture_paths=$(
    (cd "$script_dir/.." && find . ! -type d -print | sed 's#^\./##' | git check-ignore --stdin) 2>/dev/null
  ) || ignore_status=$?
  if [ "$ignore_status" -le 1 ] && [ -n "$ignored_fixture_paths" ]; then
    printf '%s\n' "$ignored_fixture_paths" | while IFS= read -r rel; do
      [ -n "$rel" ] && rm -f "$nested_backup_cache/$rel"
    done
  fi
fi
chmod -R go-w "$nested_backup_cache"
# The backup repo's own pre-existing ignore convention (unrelated to the
# plugin content, narrow enough that the manifest itself still gets
# tracked normally) happens to match the smuggled file once it is added.
printf '.claude/plugins/cache/novotnyllc/roundhouse/%s/scripts/evil.sh\n' "$plugin_version" >"$backup_home/.gitignore"
git -C "$backup_home" add .
git -C "$backup_home" -c user.email=test@test.invalid -c user.name=test commit -q -m "backup everything"
printf '#!/bin/sh\nexit 0\n' >"$nested_backup_cache/scripts/evil.sh"
chmod 700 "$nested_backup_cache/scripts/evil.sh"
if "$nested_backup_cache/scripts/roundhouse" executor-status - >/dev/null 2>&1; then
  fail "N18: a cache nested under a repo that TRACKS its manifest bypassed the manifest-coverage check via an unrelated ignore rule"
fi
rm -rf "$backup_home"

# N40: plugin_root (scripts/roundhouse's `cd -- ... && pwd`, logical) can
# be reached through a symlinked ANCESTOR directory (a symlinked dev-repo
# checkout, common for local dev setups) while `git rev-parse
# --show-toplevel` always resolves through symlinks to the physical repo
# root - a straight string-prefix comparison between the two then fails
# for that invocation even though it is the exact same checkout as a
# direct one: a real gitignored artifact under scripts/ (present here)
# gets filtered out and passes invoked directly, but is NOT filtered out
# and fails invoked through the symlinked ancestor. Symlink the REPO ROOT
# (two levels above plugin_root), not plugin_root itself - plugin_root's
# own leaf directory must stay a real directory (check_safe_owned_directory
# above already, separately, rejects plugin_root itself being a symlink;
# this is testing the path-identity comparison, not that guard). Assert
# both invocations of the SAME checkout agree. .DS_Store matches this
# repo's own real top-level .gitignore rule (confirmed: `git check-ignore`
# reports it ignored) - a genuine artifact, not a contrived one.
symlinked_repo_root="$tmp/n40-symlinked-repo-root"
ln -s "$script_dir/../../.." "$symlinked_repo_root"
: >"$script_dir/../scripts/.DS_Store"
set +e
"$cli" executor-status - >/dev/null 2>"$tmp/n40-direct.err"
n40_direct_rc=$?
"$symlinked_repo_root/plugins/roundhouse/scripts/roundhouse" executor-status - >/dev/null 2>"$tmp/n40-symlinked.err"
n40_symlinked_rc=$?
set -e
rm -f "$script_dir/../scripts/.DS_Store" "$symlinked_repo_root"
[ "$n40_direct_rc" -eq 0 ] ||
  fail "N40: direct invocation of a source checkout with a gitignored scripts/ artifact must pass ($(cat "$tmp/n40-direct.err"))"
[ "$n40_symlinked_rc" -eq 0 ] ||
  fail "N40: an invocation through a symlinked ancestor of the SAME checkout must agree with the direct one, not misdetect it as an installed cache ($(cat "$tmp/n40-symlinked.err"))"

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
