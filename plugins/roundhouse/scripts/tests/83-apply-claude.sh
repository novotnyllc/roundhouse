# roundhouse self-check — the Claude plugin surface (lib/apply-claude.sh):
# marketplace identity and its self-repair, relative-source catalogs, the
# live-session probe, and the tombstone uninstall with its deferral.
#
# Every manager call goes to the fixture `claude` stub (tests/07-stubs.sh);
# nothing here touches a real harness.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'apply-claude: identity repair, relative sources, live sessions, tombstones\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    run_root="$tmp/apply-claude"
    run_store="$run_root/store"
    mkdir -p "$run_store/hosts"
    ROUNDHOUSE_FLEET_STORE=$run_store
    HOME="$run_root/home"
    export ROUNDHOUSE_FLEET_STORE HOME
    mkdir -p "$HOME/.claude/plugins"
    run_defs='{"packages":{"jj":{"homebrew":"jj","apt":"unavailable"}}}'
    run_plugin_defs='{"plugins":{"example":{"marketplace":"test-market"}}}'
    run_sha_old=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    run_sha_new=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    run_plugin_installed="$HOME/.claude/plugins/installed_plugins.json"
    run_plugin_missing_catalog="$run_root/plugin-catalog-missing.json"
    printf '%s\n' '{"available":[]}' >"$run_plugin_missing_catalog"
    run_plugin_enabled_file="$run_root/plugin-enabled.json"
    run_plugin_order_log="$run_root/plugin-order.log"
    : >"$run_plugin_order_log"
    export CLAUDE_PLUGIN_ACTION_LOG="$run_plugin_order_log"

    # The tree digest's file hasher (host.sh) answers one line per file, in
    # the same form whichever tool the host has, and takes its list on stdin.
    printf 'one\n' >"$run_root/hash-a"
    printf 'two\n' >"$run_root/hash-b"
    [ "$(printf '%s\0' "$run_root/hash-a" "$run_root/hash-b" | sha256_file_list |
      awk '{ print $1 }' | tr '\n' ' ')" = \
      "$(sha256_file "$run_root/hash-a") $(sha256_file "$run_root/hash-b") " ] ||
      fail "sha256_file_list did not hash each file the way sha256_file does"
    [ -z "$(sha256_file_list </dev/null)" ] || fail "sha256_file_list with no files hashed stdin"

    # --- §3.5 identity self-repair: re-register and refresh before holding ---
    # The hold this replaces was permanent: a marketplace never registered on a
    # headless host, or a stale checkout, held every plugin from it as
    # "identity unavailable" on every pass. Now the marketplace is registered
    # from its configured source and refreshed, and the catalog asked once more.
    run_repair_root="$run_root/repair"
    run_repair_checkout="$run_repair_root/checkout"
    run_repair_markets="$run_repair_root/marketplaces.json"
    run_repair_adds="$run_repair_root/adds"
    run_repair_updates="$run_repair_root/updates"
    mkdir -p "$run_repair_checkout/.claude-plugin"
    cat >"$run_repair_checkout/.claude-plugin/marketplace.json" <<JSON
{"name":"test-market","plugins":[{"name":"example","version":"1.2.3","source":{"source":"git","url":"https://example.invalid/roundhouse.git","sha":"$run_sha_old"}}]}
JSON
    printf '%s\n' "{\"version\":2,\"plugins\":{\"example@test-market\":[{\"scope\":\"user\",\"version\":\"1.2.3\",\"gitCommitSha\":\"$run_sha_old\"}]}}" \
      >"$run_plugin_installed"
    run_repair_saved_settings=$(cat "$HOME/.claude/settings.json" 2>/dev/null || printf '{}')
    mkdir -p "$HOME/.claude"
    printf '%s\n' '{"extraKnownMarketplaces":{"test-market":{"source":{"source":"github","repo":"owner/test-market"}}}}' \
      >"$HOME/.claude/settings.json"
    run_repair_identity() {
      run_identity_status=0
      CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
        CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_repair_markets" \
        CLAUDE_MARKETPLACE_ADD_LOG="$run_repair_adds" \
        CLAUDE_MARKETPLACE_ADD_NAME=test-market \
        CLAUDE_MARKETPLACE_ADD_LOCATION="$run_repair_checkout" \
        CLAUDE_MARKETPLACE_UPDATE_MARKER="$run_repair_updates" \
        CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
        "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
        run_identity_status=$?
    }
    # Unregistered: registered from the declaration, refreshed, and resolved.
    printf '[]\n' >"$run_repair_markets"
    : >"$run_repair_adds"
    : >"$run_repair_updates"
    fleet_run_marketplace_repair_reset
    run_repair_identity
    [ "$run_identity_status" -eq 0 ] ||
      fail "an unregistered marketplace was not repaired before the identity hold (got $run_identity_status: $fleet_run_identity_reason)"
    [ "$(cat "$run_repair_adds")" = owner/test-market ] ||
      fail "the repair did not register the marketplace from its configured source"
    grep -Fqx test-market "$run_repair_updates" ||
      fail "the repair did not refresh the marketplace"
    # Registered (here with its checkout gone): refreshed from its OWN
    # registered source, and never re-added — every `marketplace add` writes a
    # declaration, and this host did not make one.
    printf '%s\n' "[{\"name\":\"test-market\",\"source\":\"github\",\"repo\":\"owner/test-market\",\"installLocation\":\"$run_repair_root/gone\"}]" \
      >"$run_repair_markets"
    : >"$run_repair_adds"
    : >"$run_repair_updates"
    fleet_run_marketplace_repair_reset
    run_repair_identity
    [ "$run_identity_status" -eq 75 ] ||
      fail "a marketplace whose checkout stayed gone resolved anyway (got $run_identity_status)"
    [ ! -s "$run_repair_adds" ] ||
      fail "a registered marketplace was re-added, writing a declaration: $(cat "$run_repair_adds")"
    grep -Fqx test-market "$run_repair_updates" ||
      fail "a registered marketplace was not refreshed from its registered source"
    # The same NAME registered from a DIFFERENT source than the declaration is
    # a repoint: held, not refreshed, and the hold says so. The declared repo
    # spelled as its GitHub URL is the same source and is not a repoint.
    printf '%s\n' "[{\"name\":\"test-market\",\"source\":\"github\",\"repo\":\"attacker/test-market\",\"installLocation\":\"$run_repair_checkout\"}]" \
      >"$run_repair_markets"
    printf '%s\n' "{\"available\":[]}" >"$run_plugin_missing_catalog"
    mv "$run_repair_checkout/.claude-plugin/marketplace.json" "$run_repair_root/manifest.saved"
    : >"$run_repair_updates"
    fleet_run_marketplace_repair_reset
    run_repair_identity
    [ "$run_identity_status" -eq 75 ] ||
      fail "a same-name repoint was repaired (got $run_identity_status)"
    case $fleet_run_identity_reason in
      *'same-name repoint'*) ;;
      *) fail "the repoint hold did not say why: $fleet_run_identity_reason" ;;
    esac
    [ ! -s "$run_repair_updates" ] || fail "a repointed marketplace was refreshed"
    printf '%s\n' "[{\"name\":\"test-market\",\"source\":\"git\",\"url\":\"https://github.com/Owner/test-market.git\",\"installLocation\":\"$run_repair_checkout\"}]" \
      >"$run_repair_markets"
    fleet_run_marketplace_repair_reset
    run_repair_identity
    grep -Fqx test-market "$run_repair_updates" ||
      fail "the declared repo spelled as its GitHub URL read as a repoint"
    # The REF is part of the source: a marketplace declared at `stable` and
    # registered at `experimental` (in the list, or only in the manager's own
    # record) is a repoint; the same ref is not.
    printf '%s\n' '{"extraKnownMarketplaces":{"test-market":{"source":{"source":"github","repo":"owner/test-market","ref":"stable"}}}}' \
      >"$HOME/.claude/settings.json"
    for run_ref_case in experimental:list experimental:known stable:list stable:known; do
      run_ref=${run_ref_case%%:*}
      rm -f "$HOME/.claude/plugins/known_marketplaces.json"
      if [ "${run_ref_case#*:}" = list ]; then
        printf '%s\n' "[{\"name\":\"test-market\",\"source\":\"github\",\"repo\":\"owner/test-market\",\"ref\":\"$run_ref\",\"installLocation\":\"$run_repair_checkout\"}]" \
          >"$run_repair_markets"
      else
        printf '%s\n' "[{\"name\":\"test-market\",\"source\":\"github\",\"repo\":\"owner/test-market\",\"installLocation\":\"$run_repair_checkout\"}]" \
          >"$run_repair_markets"
        mkdir -p "$HOME/.claude/plugins"
        printf '%s\n' "{\"test-market\":{\"source\":{\"source\":\"github\",\"repo\":\"owner/test-market\",\"ref\":\"$run_ref\"}}}" \
          >"$HOME/.claude/plugins/known_marketplaces.json"
      fi
      : >"$run_repair_updates"
      fleet_run_marketplace_repair_reset
      run_repair_identity
      if [ "$run_ref" = stable ]; then
        grep -Fqx test-market "$run_repair_updates" ||
          fail "a marketplace registered at its declared ref read as a repoint ($run_ref_case)"
      else
        [ ! -s "$run_repair_updates" ] ||
          fail "a marketplace registered at another ref was refreshed ($run_ref_case)"
        case $fleet_run_identity_reason in
          *'#experimental'*'#stable'*'same-name repoint'*) ;;
          *) fail "a ref repoint was not held as one ($run_ref_case): $fleet_run_identity_reason" ;;
        esac
      fi
    done
    rm -f "$HOME/.claude/plugins/known_marketplaces.json"
    # A catalog entry WITH a SHA is still only accepted from the declared
    # source: a repointed registration holds before its catalog is read, and
    # nothing is refreshed to find out.
    printf '%s\n' '{"extraKnownMarketplaces":{"test-market":{"source":{"source":"github","repo":"owner/test-market"}}}}' \
      >"$HOME/.claude/settings.json"
    printf '%s\n' "[{\"name\":\"test-market\",\"source\":\"github\",\"repo\":\"attacker/test-market\",\"installLocation\":\"$run_repair_checkout\"}]" \
      >"$run_repair_markets"
    run_sha_catalog="$run_repair_root/catalog-with-sha.json"
    printf '%s\n' "{\"available\":[{\"pluginId\":\"example@test-market\",\"version\":\"1.2.3\",\"source\":{\"source\":\"git\",\"url\":\"https://example.invalid/roundhouse.git\",\"sha\":\"$run_sha_old\"}}]}" \
      >"$run_sha_catalog"
    : >"$run_repair_updates"
    fleet_run_marketplace_repair_reset
    run_identity_status=0
    CLAUDE_PLUGIN_CATALOG_FILE="$run_sha_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_repair_markets" \
      CLAUDE_MARKETPLACE_UPDATE_MARKER="$run_repair_updates" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
      "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
      run_identity_status=$?
    [ "$run_identity_status" -eq 75 ] ||
      fail "a catalog SHA from a repointed marketplace was accepted (got $run_identity_status)"
    case $fleet_run_identity_reason in
      *'same-name repoint'*) ;;
      *) fail "the repointed catalog hold did not say why: $fleet_run_identity_reason" ;;
    esac
    [ ! -s "$run_repair_updates" ] || fail "checking a marketplace's source refreshed it"
    # The same registration from the declared source is accepted, and the
    # check refreshed nothing.
    printf '%s\n' "[{\"name\":\"test-market\",\"source\":\"github\",\"repo\":\"owner/test-market\",\"installLocation\":\"$run_repair_checkout\"}]" \
      >"$run_repair_markets"
    fleet_run_marketplace_repair_reset
    CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_repair_markets" CLAUDE_CONFIG_DIR="$HOME/.claude" \
      fleet_run_marketplace_source_ok test-market ||
      fail "a marketplace registered from its declared source failed the source check"
    [ ! -s "$run_repair_updates" ] || fail "a healthy marketplace was refreshed by its source check"
    # #91: after a SUCCESSFUL repair the catalog is read once more, and when
    # `--available` has no SHA that re-read falls back to the marketplace
    # list. A list that fails or times out there proves nothing about the
    # entry: the hold stays transient (74, retry owed), not a standing 75.
    run_mlist_bin="$run_repair_root/mlist-bin"
    run_mlist_updated="$run_repair_root/mlist-updated"
    mkdir -p "$run_mlist_bin"
    cat >"$run_mlist_bin/claude" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-} \${3:-}" in
  'plugin marketplace list') [ ! -e "$run_mlist_updated" ] || exit 1 ;;
  'plugin marketplace update') : >"$run_mlist_updated" ;;
esac
exec "$(command -v claude)" "\$@"
SH
    chmod +x "$run_mlist_bin/claude"
    rm -f "$run_mlist_updated"
    : >"$run_repair_updates"
    fleet_run_marketplace_repair_reset
    run_status=0
    PATH="$run_mlist_bin:$PATH" CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_repair_markets" \
      CLAUDE_MARKETPLACE_UPDATE_MARKER="$run_repair_updates" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null 2>&1 || run_status=$?
    grep -Fqx test-market "$run_repair_updates" ||
      fail "the post-repair fixture did not repair the marketplace first"
    [ "$run_status" -eq 74 ] ||
      fail "a catalog re-read whose marketplace list failed after a repair held as standing (got $run_status)"
    # The identity proof the unowned updates use says the same: transient.
    rm -f "$run_mlist_updated"
    fleet_run_marketplace_repair_reset
    PATH="$run_mlist_bin:$PATH" run_repair_identity
    [ "$run_identity_status" -eq 74 ] ||
      fail "an identity proof cut off by a failed marketplace list held as standing (got $run_identity_status)"
    # ...while a re-read that answers with no entry still holds as standing.
    fleet_run_marketplace_repair_reset
    run_status=0
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_repair_markets" \
      CLAUDE_MARKETPLACE_UPDATE_MARKER="$run_repair_updates" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null 2>&1 || run_status=$?
    [ "$run_status" -eq 75 ] ||
      fail "a catalog with no entry after a repair did not hold as standing (got $run_status)"
    mv "$run_repair_root/manifest.saved" "$run_repair_checkout/.claude-plugin/marketplace.json"
    rm -f "$HOME/.claude/settings.json"
    # Still unproven after the refresh: hold, once, and say why.
    printf '%s\n' "[{\"name\":\"test-market\",\"installLocation\":\"$run_repair_checkout\"}]" \
      >"$run_repair_markets"
    cat >"$run_repair_checkout/.claude-plugin/marketplace.json" <<JSON
{"name":"test-market","plugins":[{"name":"example","version":"1.2.3","source":{"source":"git","url":"https://example.invalid/roundhouse.git"}}]}
JSON
    : >"$run_repair_updates"
    fleet_run_marketplace_repair_reset
    run_repair_identity
    [ "$run_identity_status" -eq 75 ] ||
      fail "a catalog entry that stays SHA-less after a refresh did not hold (got $run_identity_status)"
    case $fleet_run_identity_reason in
      *'carries no source SHA'*) ;;
      *) fail "the identity hold did not say which proof was missing: $fleet_run_identity_reason" ;;
    esac
    # ONE refresh per marketplace per run, however many plugins it carries.
    run_repair_identity
    [ "$(grep -c . "$run_repair_updates")" -eq 1 ] ||
      fail "a second plugin from the same marketplace refreshed it again in one pass"
    # …and the memo is per PASS: the next pass forgets it and tries again.
    fleet_run_marketplace_repair_reset
    run_repair_identity
    [ "$(grep -c . "$run_repair_updates")" -eq 2 ] ||
      fail "a new pass did not retry a marketplace repair an earlier pass failed"
    # The pass body is fleet_run_pass: fleet_run_command takes the lock and
    # runs it, re-running it in-process when a trigger lands mid-pass.
    cli_function_body fleet_run_pass | grep -B4 'fleet_run_marketplace_repair_reset' |
      grep -q 'review -> verdict -> apply' ||
      fail "the repair memo is no longer reset at the start of each pass's apply step"
    printf '%s\n' "$run_repair_saved_settings" >"$HOME/.claude/settings.json"

    # --- §3.5 relative-source catalogs take the checkout commit as identity ---
    run_rel_checkout="$run_repair_root/rel-checkout"
    mkdir -p "$run_rel_checkout/.claude-plugin" "$run_rel_checkout/plugin/.claude-plugin"
    printf '{"name":"rel","version":"2.0.0"}\n' >"$run_rel_checkout/plugin/.claude-plugin/plugin.json"
    printf 'rel contents\n' >"$run_rel_checkout/plugin/SKILL.md"
    printf '%s\n' '{"name":"rel-market","plugins":[{"name":"rel","version":"2.0.0","source":"./plugin"}]}' \
      >"$run_rel_checkout/.claude-plugin/marketplace.json"
    "$REAL_GIT" -C "$run_rel_checkout" init -q
    "$REAL_GIT" -C "$run_rel_checkout" -c user.email=t@example.invalid -c user.name=t \
      -c commit.gpgsign=false add -A
    "$REAL_GIT" -C "$run_rel_checkout" -c user.email=t@example.invalid -c user.name=t \
      -c commit.gpgsign=false commit -qm one
    run_rel_head=$("$REAL_GIT" -C "$run_rel_checkout" rev-parse HEAD)
    run_rel_markets="$run_repair_root/rel-markets.json"
    printf '%s\n' "[{\"name\":\"rel-market\",\"installLocation\":\"$run_rel_checkout\"}]" \
      >"$run_rel_markets"
    run_rel_defs='{"plugins":{"rel":{"marketplace":"rel-market"}}}'
    run_rel_identity() {
      run_identity_status=0
      CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
        CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_rel_markets" \
        CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
        "$run_rel_defs" rel '{"state":"enabled","marketplace":"rel-market"}' ||
        run_identity_status=$?
    }
    run_rel_installed() {
      printf '%s\n' "{\"version\":2,\"plugins\":{\"rel@rel-market\":[{\"scope\":\"user\",\"version\":\"2.0.0\",\"gitCommitSha\":\"$1\",\"installPath\":\"$2\"}]}}" \
        >"$run_plugin_installed"
    }
    [ "$(CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_rel_markets" CLAUDE_CONFIG_DIR="$HOME/.claude" \
      fleet_run_plugin_catalog rel@rel-market | jq -r '.source.sha')" = "$run_rel_head" ] ||
      fail "a relative-source catalog entry did not take the checkout commit as its SHA"
    fleet_run_marketplace_repair_reset
    run_rel_installed "$run_rel_head" "$run_repair_root/nowhere"
    run_rel_identity
    [ "$run_identity_status" -eq 0 ] ||
      fail "a relative-source plugin installed at the checkout commit did not pass the gate (got $run_identity_status: $fleet_run_identity_reason)"
    # The marketplace moved but this plugin's bytes did not: an installed copy
    # identical to the checkout (Claude's own `.in_use` marker aside) is still
    # the same identity, so the gate does not demand an update the manager
    # would decline.
    run_rel_copy="$run_repair_root/rel-installed"
    rm -rf "$run_rel_copy"
    cp -R "$run_rel_checkout/plugin" "$run_rel_copy"
    : >"$run_rel_copy/.in_use"
    run_rel_installed "$run_sha_old" "$run_rel_copy"
    run_rel_identity
    [ "$run_identity_status" -eq 0 ] ||
      fail "identical relative-source bytes under an older checkout commit failed the gate (got $run_identity_status)"
    # The managers' install markers are not plugin content, in either harness:
    # a per-session `.in_use/PID` directory (Claude) and Codex's
    # `.codex-marketplace-install.json` leave the digest unchanged — but the
    # same names below the root are plugin content.
    run_rel_plain=$(fleet_run_tree_digest "$run_rel_copy") ||
      fail "the tree digest failed on the relative-source copy"
    rm -f "$run_rel_copy/.in_use"
    mkdir -p "$run_rel_copy/.in_use"
    : >"$run_rel_copy/.in_use/12345"
    printf '{"marketplace":"m"}\n' >"$run_rel_copy/.codex-marketplace-install.json"
    [ "$(fleet_run_tree_digest "$run_rel_copy")" = "$run_rel_plain" ] ||
      fail "a .in_use/PID session directory or Codex's install marker changed the tree digest"
    mkdir -p "$run_rel_copy/sub"
    printf '{"marketplace":"m"}\n' >"$run_rel_copy/sub/.codex-marketplace-install.json"
    [ "$(fleet_run_tree_digest "$run_rel_copy")" != "$run_rel_plain" ] ||
      fail "a nested .codex-marketplace-install.json was dropped from the tree digest"
    rm -rf "$run_rel_copy/sub" "$run_rel_copy/.in_use" "$run_rel_copy/.codex-marketplace-install.json"
    # A tree too big for one argument list is hashed in BATCHES, and gives the
    # same digest as one batch: xargs is stubbed to two files per call, and
    # the tool is counted.
    run_rel_big="$run_repair_root/rel-big"
    rm -rf "$run_rel_big"
    mkdir -p "$run_rel_big/sub"
    for run_rel_n in 1 2 3 4 5 6 7; do
      printf 'file %s\n' "$run_rel_n" >"$run_rel_big/sub/f$run_rel_n"
    done
    run_rel_one=$(fleet_run_tree_digest "$run_rel_big") ||
      fail "the tree digest failed on a plain tree"
    run_rel_stubs="$run_repair_root/hash-stubs"
    mkdir -p "$run_rel_stubs"
    run_rel_real_xargs=$(command -v xargs)
    printf '#!/bin/sh\nexec %s -n 2 "$@"\n' "$run_rel_real_xargs" >"$run_rel_stubs/xargs"
    run_rel_real_shasum=$(command -v shasum || command -v sha256sum)
    case $run_rel_real_shasum in
      */shasum) run_rel_tool='-a 256' ;;
      *) run_rel_tool= ;;
    esac
    printf '#!/bin/sh\necho call >>"%s"\n[ "${ROUNDHOUSE_TEST_HASH_FAIL:-0}" != 1 ] || exit 1\nexec %s %s "$@"\n' \
      "$run_repair_root/hash-calls" "$run_rel_real_shasum" "$run_rel_tool" \
      >"$run_rel_stubs/sha256sum"
    chmod +x "$run_rel_stubs/xargs" "$run_rel_stubs/sha256sum"
    : >"$run_repair_root/hash-calls"
    [ "$(PATH="$run_rel_stubs:$PATH" fleet_run_tree_digest "$run_rel_big")" = "$run_rel_one" ] ||
      fail "a batched tree digest differed from the one-batch digest"
    [ "$(grep -c . "$run_repair_root/hash-calls")" -ge 4 ] ||
      fail "the tree was not hashed in batches ($(grep -c . "$run_repair_root/hash-calls") calls)"
    [ -n "$run_rel_one" ] || fail "the tree digest was empty"
    # The digest is of the tree's CONTENT, modes and links included: a file
    # made executable, or a symlink pointed elsewhere, is a different plugin.
    chmod +x "$run_rel_big/sub/f1"
    run_rel_exec=$(fleet_run_tree_digest "$run_rel_big") ||
      fail "the tree digest failed on an executable file"
    [ "$run_rel_exec" != "$run_rel_one" ] ||
      fail "a chmod +x did not change the tree digest"
    chmod -x "$run_rel_big/sub/f1"
    [ "$(fleet_run_tree_digest "$run_rel_big")" = "$run_rel_one" ] ||
      fail "the tree digest did not return when the mode did"
    ln -s f1 "$run_rel_big/sub/link"
    run_rel_link1=$(fleet_run_tree_digest "$run_rel_big") ||
      fail "the tree digest failed on a symlink"
    rm -f "$run_rel_big/sub/link"
    ln -s f2 "$run_rel_big/sub/link"
    run_rel_link2=$(fleet_run_tree_digest "$run_rel_big")
    [ "$run_rel_link1" != "$run_rel_one" ] && [ "$run_rel_link1" != "$run_rel_link2" ] ||
      fail "a symlink, or a change of its target, did not change the tree digest"
    rm -f "$run_rel_big/sub/link"
    # A hasher that FAILS is a failed digest, never an empty one — two failed
    # digests used to compare equal and read as identical bytes.
    run_status=0
    ROUNDHOUSE_TEST_HASH_FAIL=1 PATH="$run_rel_stubs:$PATH" \
      fleet_run_tree_digest "$run_rel_big" >/dev/null || run_status=$?
    [ "$run_status" -ne 0 ] || fail "a failing hasher produced a tree digest"
    run_status=0
    mkdir -p "$run_repair_root/rel-empty"
    fleet_run_tree_digest "$run_repair_root/rel-empty" >/dev/null || run_status=$?
    [ "$run_status" -ne 0 ] || fail "a tree with no files produced a digest"
    # …so a sabotaged hasher over IDENTICAL bytes is a mismatch, not a match.
    run_identity_status=0
    ROUNDHOUSE_TEST_HASH_FAIL=1 PATH="$run_rel_stubs:$PATH" \
      CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_rel_markets" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
      "$run_rel_defs" rel '{"state":"enabled","marketplace":"rel-market"}' ||
      run_identity_status=$?
    [ "$run_identity_status" -eq 1 ] ||
      fail "identical bytes under a failing hasher read as a match (got $run_identity_status)"
    printf 'changed\n' >>"$run_rel_checkout/plugin/SKILL.md"
    run_rel_identity
    [ "$run_identity_status" -eq 1 ] ||
      fail "changed relative-source bytes did not require a reinstall (got $run_identity_status)"
    # An archive-downloaded marketplace (no .git) names its commit in .gcs-sha.
    rm -rf "$run_rel_checkout/.git"
    printf '%s\n' "$run_sha_new" >"$run_rel_checkout/.gcs-sha"
    run_rel_installed "$run_sha_new" "$run_repair_root/nowhere"
    run_rel_identity
    [ "$run_identity_status" -eq 0 ] ||
      fail "a relative-source plugin from an archive checkout did not take its .gcs-sha identity (got $run_identity_status)"
    # A relative path that climbs out of the checkout proves nothing.
    ! fleet_run_relative_source_sha "$run_rel_checkout" ./../elsewhere rel@rel-market \
      >/dev/null || fail "a relative source escaping the checkout was given an identity"
    # A catalog entry that states no version is proven by its SHA alone.
    printf '%s\n' '{"name":"rel-market","plugins":[{"name":"rel","source":"./plugin"}]}' \
      >"$run_rel_checkout/.claude-plugin/marketplace.json"
    printf '%s\n' "{\"version\":2,\"plugins\":{\"rel@rel-market\":[{\"scope\":\"user\",\"version\":\"${run_sha_new%????????????????????????????}\",\"gitCommitSha\":\"$run_sha_new\"}]}}" \
      >"$run_plugin_installed"
    run_rel_identity
    [ "$run_identity_status" -eq 0 ] ||
      fail "a version-less catalog entry demanded a reinstall over a matching SHA (got $run_identity_status)"
    fleet_run_marketplace_repair_reset

    # --- the live-session probe reads the COMMAND LINE ---
    # An npm-installed claude is `node …/cli.js` with comm `node`, so comm
    # alone missed every such session (comm still covers the native binary,
    # including the desktop-bundled copy whose path has spaces). Only
    # argv[0]/argv[1] count, so a process that merely names claude does not.
    for run_claude_line in \
      '/Users/x/.local/bin/claude --resume' 'claude' \
      'node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js' \
      'node /Users/x/.npm-global/bin/claude -p hi' \
      'node /Users/a b/.npm-global/bin/claude --resume' \
      'node /Users/a b/lib/node_modules/@anthropic-ai/claude-code/cli.js'; do
      printf '%s\n' "$run_claude_line" | fleet_run_claude_cmdline_match ||
        fail "a running claude CLI was not recognised: $run_claude_line"
    done
    # #40 review (c): argv[0] itself may carry spaces — a node under a home
    # directory with one, or an nvm tree — and is read as the longest leading
    # path whose basename is node.
    for run_claude_line in \
      '/Users/First Last/.nvm/versions/node/v24.1.0/bin/node /Users/First Last/.nvm/versions/node/v24.1.0/bin/claude --resume' \
      '/Users/First Last/.nvm/versions/node/v24.1.0/bin/node /Users/First Last/.nvm/versions/node/v24.1.0/lib/node_modules/@anthropic-ai/claude-code/cli.js' \
      '/opt/my tools/node22 /opt/my tools/bin/claude' \
      '/Users/First Last/.nvm/versions/node/v24.1.0/bin/node /Users/First Last/.npm-global/bin/claude --worktree /Users/First Last/src/my node'; do
      printf '%s\n' "$run_claude_line" | fleet_run_claude_cmdline_match ||
        fail "a claude CLI under a node path with spaces was not recognised: $run_claude_line"
    done
    # A LATER argument whose basename is node never becomes argv[0]: the
    # first node boundary is argv[0], and the script follows it.
    for run_claude_line in \
      '/usr/local/bin/node /usr/local/bin/claude --worktree /tmp/node' \
      '/usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js --add-dir /srv/node' \
      'node /Users/x/.npm-global/bin/claude --worktree /tmp/node' \
      '/opt/node22 /opt/bin/claude -p hi /var/lib/node22'; do
      printf '%s\n' "$run_claude_line" | fleet_run_claude_cmdline_match ||
        fail "a later argument named node replaced argv[0]: $run_claude_line"
    done
    for run_claude_line in \
      '/Users/First Last/.nvm/versions/node/v24.1.0/bin/node /srv/app/server.js claude' \
      '/Users/First Last/bin/python /tmp/node /x/claude-notes'; do
      ! printf '%s\n' "$run_claude_line" | fleet_run_claude_cmdline_match ||
        fail "something that is not the claude CLI read as one: $run_claude_line"
    done
    for run_claude_line in '/Applications/Claude.app/Contents/MacOS/Claude' \
      'grep claude' 'awk { exe == "claude" }' 'node /srv/app/server.js claude' \
      'vim /tmp/claude-notes'; do
      ! printf '%s\n' "$run_claude_line" | fleet_run_claude_cmdline_match ||
        fail "something that is not the claude CLI read as one: $run_claude_line"
    done

    # --- §3.4 tombstones: `absent` uninstalls a Claude plugin ---
    run_tomb_installed() {
      printf '%s\n' "{\"version\":2,\"plugins\":{\"example@test-market\":[{\"scope\":\"user\",\"version\":\"1.4.0\",\"gitCommitSha\":\"$run_sha_new\"}]}}" \
        >"$run_plugin_installed"
    }
    run_tomb_apply() {
      run_status=0
      CLAUDE_CONFIG_DIR="$HOME/.claude" \
        CLAUDE_PLUGIN_ENABLED_FILE="$run_plugin_enabled_file" \
        fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
          "$1" '' >"$run_root/tomb-out" 2>&1 || run_status=$?
    }
    rm -rf "$(fleet_run_state_dir)/deferrals"
    # Item ids are store content: a host-local record keyed by one is always
    # ONE file directly under its directory, whatever the id carries. A plain
    # id keeps its own name, so records written before this still read.
    [ "$(fleet_run_deferral_path plugins.example@market)" = \
      "$(fleet_run_state_dir)/deferrals/plugins.example@market" ] ||
      fail "a plain item id no longer names its own deferral record"
    for run_evil in 'plugins.x/../../../victim' '..' '.hidden' "$(printf 'plugins.a\nb')"; do
      for run_evil_path in "$(fleet_run_deferral_path "$run_evil")" \
        "$(fleet_run_tombstone_memo_path "$run_evil")"; do
        case ${run_evil_path##*/} in
          sha256-*) ;;
          *) fail "an unsafe item id became a file name: $run_evil_path" ;;
        esac
        [ "$(dirname -- "$run_evil_path")" = "$(fleet_run_state_dir)/deferrals" ] ||
          [ "$(dirname -- "$run_evil_path")" = "$(fleet_run_state_dir)/tombstones" ] ||
          fail "an unsafe item id escaped its state directory: $run_evil_path"
      done
    done
    # A subshell, because the live-session probe is replaced per case below.
    (
    # Not installed: SATISFIED, with no manager call at all — and any deferral
    # window for it is over.
    printf '%s\n' '{"version":2,"plugins":{}}' >"$run_plugin_installed"
    : >"$run_plugin_order_log"
    mkdir -p "$(fleet_run_state_dir)/deferrals"
    printf 'stale 1\n' >"$(fleet_run_deferral_path plugins.example)"
    run_tomb_apply '"absent"'
    [ "$run_status" -eq 70 ] ||
      fail "a tombstone for a plugin that is not installed was not satisfied (got $run_status)"
    [ ! -e "$(fleet_run_deferral_path plugins.example)" ] ||
      fail "a satisfied tombstone left its deferral record behind"
    [ ! -s "$run_plugin_order_log" ] ||
      fail "a satisfied tombstone ran a manager verb: $(cat "$run_plugin_order_log")"
    # Installed and DISABLED: uninstalled immediately even with a session live.
    run_tomb_installed
    printf '%s\n' '{"example@test-market":false}' >"$run_plugin_enabled_file"
    fleet_run_claude_running() { return 0; }
    run_tomb_apply '"absent"'
    [ "$run_status" -eq 0 ] ||
      fail "a disabled tombstoned plugin was not uninstalled (got $run_status): $(cat "$run_root/tomb-out")"
    grep -Fqx 'uninstall example@test-market' "$run_plugin_order_log" ||
      fail "the uninstall did not go through the native manager (with --keep-data)"
    [ "$(jq -c '.plugins["example@test-market"] // null' "$run_plugin_installed")" = null ] ||
      fail "the uninstalled plugin is still in installed_plugins.json"
    # Installed and ENABLED while a claude session runs: DEFERRED, and the
    # window starts at the first deferral.
    run_tomb_installed
    printf '%s\n' '{"example@test-market":true}' >"$run_plugin_enabled_file"
    : >"$run_plugin_order_log"
    run_tomb_apply '"absent"'
    [ "$run_status" -eq 75 ] ||
      fail "an enabled plugin was uninstalled under a live claude session (got $run_status)"
    grep -q 'defer plugins.example' "$run_root/tomb-out" ||
      fail "the deferral did not say why it held: $(cat "$run_root/tomb-out")"
    ! grep -q uninstall "$run_plugin_order_log" ||
      fail "a deferred uninstall still reached the manager"
    run_tomb_deferral=$(fleet_run_deferral_path plugins.example)
    run_tomb_first=$(awk '{ print $2 }' "$run_tomb_deferral")
    run_tomb_apply '"absent"'
    [ "$run_status" -eq 75 ] &&
      [ "$(awk '{ print $2 }' "$run_tomb_deferral")" = "$run_tomb_first" ] ||
      fail "a second deferral restarted the 24h window"
    # A deferral record that cannot be written HOLDS rather than restarting
    # the window on every pass.
    # (A FILE where the directory should be: unwritable even for root.)
    run_tomb_dir=$(dirname "$run_tomb_deferral")
    mv "$run_tomb_dir" "$run_tomb_dir.saved"
    : >"$run_tomb_dir"
    run_tomb_apply '"absent"'
    rm -f "$run_tomb_dir"
    mv "$run_tomb_dir.saved" "$run_tomb_dir"
    [ "$run_status" -eq 75 ] && grep -q 'cannot be written' "$run_root/tomb-out" ||
      fail "an unwritable deferral record did not hold (got $run_status): $(cat "$run_root/tomb-out")"
    ! grep -q uninstall "$run_plugin_order_log" ||
      fail "an unwritable deferral record let the uninstall through"
    # Past 24h from the FIRST deferral it proceeds, session or not.
    printf '%s %s\n' "$(awk '{ print $1 }' "$run_tomb_deferral")" \
      "$(($(date +%s) - 86401))" >"$run_tomb_deferral"
    run_tomb_apply '"absent"'
    [ "$run_status" -eq 0 ] ||
      fail "the deferral did not end after 24h (got $run_status)"
    [ ! -e "$run_tomb_deferral" ] ||
      fail "a completed uninstall left its deferral record behind"
    # Enabled with NO session running: immediate.
    fleet_run_claude_running() { return 1; }
    run_tomb_installed
    run_tomb_apply '{"state":"absent","marketplace":"test-market"}'
    [ "$run_status" -eq 0 ] ||
      fail "an enabled tombstoned plugin with no live session was not uninstalled (got $run_status)"
    # A manager that reports success and leaves the record is not an uninstall.
    run_tomb_installed
    CLAUDE_UNINSTALL_SKIP_RECORD=1 run_tomb_apply '"absent"'
    [ "$run_status" -eq 75 ] ||
      fail "an uninstall that left the record behind was accepted (got $run_status)"
    # An unqualified tombstone names exactly one installed plugin, or holds.
    run_status=0
    printf '%s\n' "{\"version\":2,\"plugins\":{\"solo@one\":[{\"scope\":\"user\",\"version\":\"1\"}],\"dup@one\":[{\"scope\":\"user\",\"version\":\"1\"}],\"dup@two\":[{\"scope\":\"user\",\"version\":\"1\"}]}}" \
      >"$run_plugin_installed"
    [ "$(CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_tombstone_target '{}' solo '"absent"')" = \
      solo@one ] || fail "an unqualified tombstone did not resolve its one installed plugin"
    CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_tombstone_target '{}' dup '"absent"' \
      >/dev/null || run_status=$?
    [ "$run_status" -eq 75 ] ||
      fail "an unqualified tombstone installed from two marketplaces did not hold"
    [ -z "$(CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_tombstone_target '{}' never '"absent"')" ] ||
      fail "a tombstone for a plugin installed nowhere named something"
    # A definition that cannot be resolved holds, never falling back to the
    # unqualified lookup that would pick a same-named plugin elsewhere.
    run_status=0
    CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_tombstone_target \
      '{"plugins":{"solo":"not-a-map"}}' solo '"absent"' >/dev/null || run_status=$?
    [ "$run_status" -eq 75 ] ||
      fail "an unresolvable tombstone definition did not hold (got $run_status)"
    ) || exit 1
    # #40 review (d): a ps that FAILS is "unknown", never "no session" — an
    # enabled plugin is not uninstalled out from under a session nobody could
    # see. A subshell, because the probe is replaced again below.
    (
      run_ps_bin="$run_root/ps-fail-bin"
      mkdir -p "$run_ps_bin"
      printf '#!/bin/sh\nexit 1\n' >"$run_ps_bin/ps"
      chmod +x "$run_ps_bin/ps"
      run_status=0
      PATH="$run_ps_bin:$PATH" fleet_run_claude_running || run_status=$?
      [ "$run_status" -eq 75 ] ||
        fail "a failed process probe did not read as unknown (got $run_status)"
      run_tomb_installed
      printf '%s\n' '{"example@test-market":true}' >"$run_plugin_enabled_file"
      rm -rf "$(fleet_run_state_dir)/deferrals"
      : >"$run_plugin_order_log"
      PATH="$run_ps_bin:$PATH"
      run_tomb_apply '"absent"'
      [ "$run_status" -eq 75 ] && grep -q 'cannot tell whether a claude session is running' \
        "$run_root/tomb-out" ||
        fail "a failed process probe did not hold the uninstall (got $run_status): $(cat "$run_root/tomb-out")"
      ! grep -q uninstall "$run_plugin_order_log" ||
        fail "a failed process probe let the uninstall through"
    ) || exit 1

    # #40 review (b): a declared `url` source with a ref registers WITH the
    # ref, so the registration reads back as its own declaration, not as a
    # same-name repoint held forever.
    (
      run_url_dir="$run_root/url-config"
      mkdir -p "$run_url_dir"
      CLAUDE_CONFIG_DIR=$run_url_dir
      export CLAUDE_CONFIG_DIR
      printf '%s\n' '{"extraKnownMarketplaces":{"url-market":{"source":{"source":"url","url":"https://example.invalid/market.json","ref":"stable"}}}}' \
        >"$run_url_dir/settings.json"
      [ "$(fleet_run_marketplace_source url-market)" = \
        'https://example.invalid/market.json#stable' ] ||
        fail "a declared url source with a ref registers without it: $(fleet_run_marketplace_source url-market || :)"
      run_url_list="$run_root/url-marketplaces.json"
      for run_url_entry in \
        '{"name":"url-market","source":"url","url":"https://example.invalid/market.json#stable"}' \
        '{"name":"url-market","source":"url","url":"https://example.invalid/market.json","ref":"stable"}'; do
        printf '[%s]\n' "$run_url_entry" >"$run_url_list"
        fleet_run_marketplace_repair_reset
        CLAUDE_PLUGIN_MARKETPLACE_FILE=$run_url_list fleet_run_marketplace_source_ok url-market ||
          fail "a url marketplace registered from its own declaration read as a repoint ($fleet_run_repair_reason): $run_url_entry"
      done
      # …while a registration that lost the ref, or names another URL, is one.
      for run_url_entry in \
        '{"name":"url-market","source":"url","url":"https://example.invalid/market.json"}' \
        '{"name":"url-market","source":"url","url":"https://elsewhere.invalid/market.json#stable"}'; do
        printf '[%s]\n' "$run_url_entry" >"$run_url_list"
        fleet_run_marketplace_repair_reset
        ! CLAUDE_PLUGIN_MARKETPLACE_FILE=$run_url_list fleet_run_marketplace_source_ok url-market ||
          fail "a url marketplace registered from another source was accepted: $run_url_entry"
      done
      fleet_run_marketplace_repair_reset
    ) || exit 1

    # #40 review (a): a plugin whose definition does not resolve HOLDS. It
    # used to fall through to the unqualified id and install from the
    # manager's default marketplace.
    run_unresolved_installs="$run_root/unresolved-installs"
    : >"$run_unresolved_installs"
    : >"$run_plugin_order_log"
    run_status=0
    CLAUDE_CONFIG_DIR="$HOME/.claude" CLAUDE_INSTALL_MARKER="$run_unresolved_installs" \
      fleet_run_apply_item "$run_store" vireo '{"plugins":{"solo":"not-a-map"}}' \
      plugins.solo '"enabled"' '' >/dev/null 2>&1 || run_status=$?
    [ "$run_status" -eq 75 ] ||
      fail "a plugin with an unresolvable definition was not held (got $run_status)"
    [ ! -s "$run_unresolved_installs" ] && ! grep -q 'install' "$run_plugin_order_log" ||
      fail "a plugin with an unresolvable definition was installed from the default marketplace"

    # `absent` stays HELD where there is no uninstall verb.
    for run_tomb_other in skills.tdd packages.jj agents.triage-bot; do
      run_status=0
      fleet_run_apply_item "$run_store" vireo "$run_defs" "$run_tomb_other" \
        '"absent"' homebrew >/dev/null 2>&1 || run_status=$?
      [ "$run_status" -eq 75 ] ||
        fail "$run_tomb_other at state absent was not held (got $run_status)"
    done

  )
fi
