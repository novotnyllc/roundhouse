# roundhouse self-check — plugins are always current (lib/fleet-plugins.sh):
# the read-only upstream probe, the Codex marketplace refresh and its
# hook-preserving updates, and the Claude refresh's handling of plugins the
# fleet does not own.
#
# Every upstream is a local repository, every manager a stub; nothing here
# reaches the network or a real harness. The run-level story (a non-canary host
# applying a plugin with no canary evidence, the poll floor seeing a moved
# marketplace) is tests/93-jj-run.sh's `plugins` scenario.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'plugin currency: upstream probe, Codex refresh, unowned Claude updates\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    pc="$tmp/plugin-currency"
    rm -rf "$pc"
    mkdir -p "$pc/store" "$pc/home/.claude/plugins" "$pc/bin"
    ROUNDHOUSE_FLEET_STORE="$pc/store"
    HOME="$pc/home"
    CLAUDE_CONFIG_DIR="$HOME/.claude"
    export ROUNDHOUSE_FLEET_STORE HOME CLAUDE_CONFIG_DIR
    pc_git() {
      "$REAL_GIT" -c user.name=x -c user.email=x@example.invalid \
        -c commit.gpgsign=false -c tag.gpgsign=false "$@"
    }
    pc_upstream() {
      # pc_upstream NAME -> a bare upstream with one commit on main
      pc_git init -q --bare -b main "$pc/$1.git"
      pc_git init -q -b main "$pc/$1-work"
      pc_commit "$1" 'first'
    }
    pc_commit() {
      pc_git -C "$pc/$1-work" commit -q --allow-empty -m "$2"
      pc_git -C "$pc/$1-work" push -q "$pc/$1.git" main
      pc_git -C "$pc/$1-work" rev-parse HEAD
    }

    # --- the upstream head: read-only, by branch, peeled tag or HEAD ---
    pc_upstream heads >/dev/null
    pc_head=$(pc_git -C "$pc/heads-work" rev-parse HEAD)
    pc_git -C "$pc/heads-work" tag -a v1 -m 'release v1'
    pc_git -C "$pc/heads-work" push -q "$pc/heads.git" v1
    [ "$(fleet_plugins_remote_head "$pc/heads.git" '')" = "$pc_head" ] ||
      fail "the upstream head at HEAD was not read"
    [ "$(fleet_plugins_remote_head "$pc/heads.git" main)" = "$pc_head" ] ||
      fail "the upstream head of a branch was not read"
    [ "$(fleet_plugins_remote_head "$pc/heads.git" v1)" = "$pc_head" ] ||
      fail "an annotated tag was not peeled to the commit it names"
    ! fleet_plugins_remote_head "$pc/heads.git" nope >/dev/null ||
      fail "a ref the upstream does not have answered a head"
    ! fleet_plugins_remote_head "$pc/missing.git" '' >/dev/null 2>&1 ||
      fail "an unreachable upstream answered a head"
    for pc_bad in '-uhttps://x' 'has space' ''; do
      ! fleet_plugins_remote_head "$pc_bad" '' >/dev/null 2>&1 ||
        fail "an option-shaped or empty upstream URL was passed to git: $pc_bad"
    done
    ! fleet_plugins_remote_head "$pc/heads.git" '--upload-pack=x' >/dev/null 2>&1 ||
      fail "an option-shaped ref was passed to git"

    # --- Claude sources: only marketplaces with an installed plugin ---
    pc_upstream claude-up >/dev/null
    jq -n --arg url "$pc/claude-up.git" '{
      "git-market": {source: {source: "git", url: $url}, installLocation: "/nowhere"},
      "gh-market": {source: {source: "github", repo: "owner/repo", ref: "stable"}},
      "dir-market": {source: {source: "directory", path: "/somewhere"}},
      "idle-market": {source: {source: "git", url: $url}}}' \
      >"$HOME/.claude/plugins/known_marketplaces.json"
    printf '%s\n' '{"version":2,"plugins":{
      "a@git-market":[{"scope":"user","version":"1"}],
      "b@gh-market":[{"scope":"user","version":"1"}],
      "c@dir-market":[{"scope":"user","version":"1"}],
      "d@idle-market":[{"scope":"project","version":"1"}]}}' \
      >"$HOME/.claude/plugins/installed_plugins.json"
    us=$(printf '\037')
    fleet_plugins_claude_sources | tr "$us" '|' | LC_ALL=C sort >"$pc/sources"
    printf '%s\n' "claude|gh-market|https://github.com/owner/repo.git|stable|" \
      "claude|git-market|$pc/claude-up.git||/nowhere" >"$pc/sources.want"
    cmp -s "$pc/sources" "$pc/sources.want" ||
      fail "the Claude marketplace sources were wrong: $(tr '\n' ' ' <"$pc/sources")"

    # --- the probe: moved against the head this host last refreshed at ---
    # Only the local upstream is probed from here on: a GitHub source would be
    # a network call.
    printf '%s\n' '{"version":2,"plugins":{"a@git-market":[{"scope":"user","version":"1"}]}}' \
      >"$HOME/.claude/plugins/installed_plugins.json"
    pc_claude_head=$(pc_git -C "$pc/claude-up-work" rev-parse HEAD)
    fleet_plugins_probe ||
      fail "a marketplace this host never refreshed did not read as moved"
    [ "$fleet_plugins_probed" = true ] || fail "the probe did not say it ran"
    [ "$(printf '%s' "$fleet_plugins_moved" | tr "$us" '|')" = \
      "claude|git-market|$pc_claude_head|/nowhere" ] ||
      fail "the probe's moved line was wrong: $fleet_plugins_moved"
    fleet_plugins_memo_write claude git-market attempted "$pc_claude_head"
    ! fleet_plugins_probe ||
      fail "an upstream at the head this host refreshed at read as moved: $fleet_plugins_moved"
    pc_claude_head=$(pc_commit claude-up 'a release')
    fleet_plugins_probe || fail "an upstream that moved did not read as moved"
    case $fleet_plugins_moved in
      *"$pc_claude_head"*) ;;
      *) fail "the probe did not report the new upstream head: $fleet_plugins_moved" ;;
    esac
    # Unreachable is "not known to have moved", never "moved": it must not
    # keep every fast pass open while the network is down.
    jq --arg url "$pc/gone.git" '."git-market".source.url = $url' \
      "$HOME/.claude/plugins/known_marketplaces.json" >"$pc/known.next"
    mv "$pc/known.next" "$HOME/.claude/plugins/known_marketplaces.json"
    ! fleet_plugins_probe || fail "an unreachable upstream read as moved"

    # --- Codex: Roundhouse only TRIGGERS Codex's own marketplace sync ---
    # Codex syncs its Git marketplaces, and reinstalls what is installed from
    # them, in the background whenever an app server starts. Roundhouse never
    # upgrades or reinstalls a Codex plugin: it holds an app server open until
    # Codex records the probed head, and remembers the head only then.
    cat >"$pc/bin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = app-server ] && [ "${2:-}" = --stdio ]; then
  printf 'app-server\n' >>"$PC_CODEX_LOG"
  while IFS= read -r req; do
    id=$(printf '%s\n' "$req" | jq -r '.id // empty')
    case $(printf '%s\n' "$req" | jq -r '.method // empty') in
      initialize)
        # The sync runs in the background, announces nothing, and is cut off
        # when the app server is closed before it finishes, as Codex's is.
        server=$$
        [ ! -s "$PC_CODEX_SYNC_TO" ] || (sleep 1
          kill -0 "$server" 2>/dev/null || exit 0
          jq -n --arg rev "$(cat "$PC_CODEX_SYNC_TO")" '{source_type: "git", revision: $rev}' \
            >"$PC_CODEX_ROOT/.codex-marketplace-install.json") >/dev/null 2>&1 </dev/null &
        jq -cn --argjson id "$id" '{id:$id,result:{}}'
        ;;
    esac
  done
  exit 0
fi
case "$*" in
  'plugin marketplace list --json') cat "$PC_CODEX_MARKETS"; exit 0 ;;
esac
# Roundhouse must never drive Codex's own updates.
printf 'FORBIDDEN %s\n' "$*" >>"$PC_CODEX_LOG"
exit 64
SH
    chmod +x "$pc/bin/codex"
    pc_upstream codex-up >/dev/null
    pc_codex_head=$(pc_git -C "$pc/codex-up-work" rev-parse HEAD)
    mkdir -p "$pc/codex-root"
    export PC_CODEX_MARKETS="$pc/codex-markets.json" PC_CODEX_LOG="$pc/codex.log" \
      PC_CODEX_SYNC_TO="$pc/codex-sync-to" PC_CODEX_ROOT="$pc/codex-root"
    jq -n --arg root "$pc/codex-root" --arg url "$pc/codex-up.git" '{marketplaces: [
      {name: "novotnyllc", root: $root, marketplaceSource: {sourceType: "git", source: $url}},
      {name: "openai-bundled", root: "/bundled", marketplaceSource: {sourceType: "local", source: "/bundled"}}]}' \
      >"$PC_CODEX_MARKETS"
    (
      PATH="$pc/bin:$PATH"
      # Local and remote-catalog marketplaces advance with Codex itself.
      [ "$(fleet_plugins_codex_markets | tr "$us" '|')" = \
        "novotnyllc|$pc/codex-up.git||$pc/codex-root" ] ||
        fail "the Codex Git marketplaces were wrong: $(fleet_plugins_codex_markets)"
      # Full pass: Codex syncs to the upstream head; the head is remembered.
      printf '%s\n' "$pc_codex_head" >"$PC_CODEX_SYNC_TO"
      : >"$PC_CODEX_LOG"
      pc_out=$(fleet_plugins_refresh "$pc/store" vireo '{}' '{}' full "$pc")
      [ "$(cat "$PC_CODEX_LOG")" = app-server ] ||
        fail "the pass did more than start Codex's own sync: $(tr '\n' ';' <"$PC_CODEX_LOG")"
      [ "$(fleet_plugins_memo_read codex novotnyllc attempted)" = "$pc_codex_head" ] ||
        fail "a Codex sync that reached the upstream head was not remembered: $pc_out"
      # The probe now reads Codex as current.
      ! fleet_plugins_probe ||
        fail "a marketplace Codex had synced still read as moved: $fleet_plugins_moved"
      # Upstream moves; Codex's sync does not get there this pass: nothing is
      # remembered, so the next pass asks again, and the pass says so.
      pc_codex_head=$(pc_commit codex-up 'a release')
      : >"$PC_CODEX_SYNC_TO"
      : >"$PC_CODEX_LOG"
      fleet_plugins_probe || fail "a moved Codex marketplace did not read as moved"
      pc_out=$(ROUNDHOUSE_CODEX_SYNC_WAIT_MS=1500 \
        fleet_plugins_refresh "$pc/store" vireo '{}' '{}' fast "$pc")
      [ "$(cat "$PC_CODEX_LOG")" = app-server ] ||
        fail "the fast pass did more than start Codex's own sync: $(tr '\n' ';' <"$PC_CODEX_LOG")"
      [ "$(fleet_plugins_memo_read codex novotnyllc attempted)" != "$pc_codex_head" ] ||
        fail "a Codex sync that never happened was remembered as done"
      case $pc_out in
        *'hold  marketplace novotnyllc (codex) — Codex did not sync it'*) ;;
        *) fail "a Codex sync that did not reach the head was not reported: $pc_out" ;;
      esac
      # The next fast pass, with Codex reaching it, remembers it.
      printf '%s\n' "$pc_codex_head" >"$PC_CODEX_SYNC_TO"
      fleet_plugins_probe || fail "an unsynced Codex marketplace stopped reading as moved"
      fleet_plugins_refresh "$pc/store" vireo '{}' '{}' fast "$pc" >/dev/null
      [ "$(fleet_plugins_memo_read codex novotnyllc attempted)" = "$pc_codex_head" ] ||
        fail "a fast-pass Codex sync was not remembered"
      ! grep -q FORBIDDEN "$PC_CODEX_LOG" ||
        fail "Roundhouse drove a Codex upgrade or install: $(tr '\n' ';' <"$PC_CODEX_LOG")"
    )

    # The run hands the refresh its whole desired universe (fleet_run_desired:
    # the fold plus tombstones), not the bare fold, which drops `absent`.
    cli_function_body fleet_run_pass | tr -d '\\\n' |
      grep -Fq '"$run_mode" "$run_tmp" "$run_desired"' ||
      fail "the pass does not name its tombstones to the plugin refresh"

    # --- Claude: plugins the fleet does not own are updated in place ---
    pc_sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    pc_sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    # DESIRED is the fold plus its tombstones (`retired: absent`): a
    # tombstone whose uninstall is held is still the fleet's, not an
    # unowned plugin to update. A definition is a fleet item too.
    pc_fold='{"plugins":{"widget":{"state":"enabled","marketplace":"m"},"bare":"enabled","qual@m":"enabled","retired":{"state":"absent","marketplace":"m"}}}'
    pc_defs='{"plugins":{"defined":{"marketplace":"m"}}}'
    fleet_plugins_owned "$pc_fold" "$pc_defs" | LC_ALL=C sort >"$pc/owned"
    printf '%s\n' 'id qual@m' 'id retired@m' 'id widget@m' 'name bare' 'name defined' \
      >"$pc/owned.want"
    cmp -s "$pc/owned" "$pc/owned.want" ||
      fail "the fleet's own plugins were not named: $(tr '\n' ';' <"$pc/owned")"
    jq -n --arg a "$pc_sha_a" '{version: 2, plugins: (
      ["widget", "bare", "qual", "gadget", "current", "retired", "defined"] |
      map({key: "\(.)@m", value: [{scope: "user", version: "1.0.0", gitCommitSha: $a}]}) |
      from_entries)}' >"$HOME/.claude/plugins/installed_plugins.json"
    jq -n --arg a "$pc_sha_a" --arg b "$pc_sha_b" '{available: (
      ["widget", "bare", "qual", "gadget", "retired", "defined"] |
      map({pluginId: "\(.)@m", version: "1.1.0", source: {source: "git", sha: $b}})) +
      [{pluginId: "current@m", version: "1.0.0", source: {source: "git", sha: $a}}]}' \
      >"$pc/catalog.json"
    : >"$pc/actions"
    fleet_run_marketplace_repair_reset
    pc_out=$(CLAUDE_PLUGIN_CATALOG_FILE="$pc/catalog.json" CLAUDE_PLUGIN_ACTION_LOG="$pc/actions" \
      fleet_plugins_claude_update_unowned "$pc_defs" m "$pc/owned")
    [ "$(cat "$pc/actions")" = 'update gadget@m' ] ||
      fail "the unowned update touched a fleet item or a current plugin: $(tr '\n' ';' <"$pc/actions")"
    case $pc_out in
      *'update plugin gadget@m (claude)'*) ;;
      *) fail "the unowned update was not reported: $pc_out" ;;
    esac
    [ "$(jq -r '.plugins["gadget@m"][0].gitCommitSha' \
      "$HOME/.claude/plugins/installed_plugins.json")" = "$pc_sha_b" ] ||
      fail "the unowned plugin did not reach the catalog identity"
    # An update the manager claims and does not deliver is a hold, not done.
    jq --arg a "$pc_sha_a" '.plugins["gadget@m"][0].gitCommitSha = $a' \
      "$HOME/.claude/plugins/installed_plugins.json" >"$pc/installed.next"
    mv "$pc/installed.next" "$HOME/.claude/plugins/installed_plugins.json"
    pc_out=$(CLAUDE_PLUGIN_CATALOG_FILE="$pc/catalog.json" CLAUDE_INSTALL_SKIP_RECORD=1 \
      fleet_plugins_claude_update_unowned "$pc_defs" m "$pc/owned")
    case $pc_out in
      *'hold  plugin gadget@m — claude plugin update did not reach the catalog identity'*) ;;
      *) fail "a no-op update read as done: $pc_out" ;;
    esac

    # --- the fleet's own plugins: source-verified approval of Codex's copy ---
    # The item loop updates Claude's copy; automatic approval reads Codex's.
    # Codex here models hook trust by hash (a hook is trusted only while its
    # current hash is the one trust was written for) and its startup sync: a
    # `pending` version is installed the moment an app server starts.
    mkdir -p "$pc/hooks-bin" "$pc/hooks-state"
    cat >"$pc/hooks-bin/codex" <<'SH'
#!/usr/bin/env bash
st=$PC_HOOKS_STATE
ver=$(cat "$st/version")
if [ "${1:-}" = app-server ] && [ "${2:-}" = --stdio ]; then
  if [ -s "$st/pending" ]; then
    cat "$st/pending" >"$st/version"
    rm -f "$st/pending"
    printf 'codex-sync\n' >>"$st/log"
  fi
  ver=$(cat "$st/version")
  while IFS= read -r req; do
    method=$(printf '%s\n' "$req" | jq -r '.method // empty')
    id=$(printf '%s\n' "$req" | jq -r '.id // empty')
    case $method in
      initialize) jq -cn --argjson id "$id" '{id:$id,result:{}}' ;;
      hooks/list)
        cwd=$(printf '%s\n' "$req" | jq -r '.params.cwds[0]')
        current="sha256:$ver"
        trusted=$(cat "$st/trusted" 2>/dev/null || :)
        status=untrusted
        [ -z "$trusted" ] || status=modified
        [ "$trusted" != "$current" ] || status=trusted
        jq -cn --argjson id "$id" --arg cwd "$cwd" --arg h "$current" --arg s "$status" \
          '{id:$id,result:{data:[{cwd:$cwd,warnings:[],errors:[],hooks:[{
            key:"widget@m:hooks/hooks.json:stop:0:0",pluginId:"widget@m",
            currentHash:$h,trustStatus:$s,enabled:true}]}]}}'
        ;;
      config/batchWrite)
        printf '%s\n' "$req" | jq -r '.params.edits[0].value' >"$st/trusted"
        printf 'trust %s\n' "$(cat "$st/trusted")" >>"$st/log"
        jq -cn --argjson id "$id" '{id:$id,result:{}}'
        ;;
    esac
  done
  exit 0
fi
case "$*" in
  'plugin list --json')
    jq -cn --arg v "$ver" --arg sha "$(cat "$st/sha-$ver")" \
      --argjson src "$(cat "$st/source")" --argjson on "$(cat "$st/enabled")" '{installed:[{
      pluginId:"widget@m",name:"widget",marketplaceName:"m",version:$v,
      installed:true,enabled:$on,source:($src + {sha:$sha})}]}'
    ;;
  'plugin marketplace list --json') cat "$st/markets" ;;
  'plugin add widget@m --json')
    printf '%s\n' new >"$st/version"
    printf 'codex-add widget@m\n' >>"$st/log"
    ;;
  *) exit 64 ;;
esac
SH
    chmod +x "$pc/hooks-bin/codex"
    pc_hooks_reset() {
      printf '%s\n' old >"$pc/hooks-state/version"
      printf '%s\n' "$pc_sha_a" >"$pc/hooks-state/sha-old"
      printf '%s\n' "$pc_sha_b" >"$pc/hooks-state/sha-new"
      printf '%s\n' sha256:old >"$pc/hooks-state/trusted"
      printf '%s\n' true >"$pc/hooks-state/enabled"
      printf '%s\n' '{"source":"git","url":"https://example.invalid/widget.git"}' \
        >"$pc/hooks-state/source"
      printf '%s\n' '{"marketplaces":[]}' >"$pc/hooks-state/markets"
      rm -f "$pc/hooks-state/pending"
      : >"$pc/hooks-state/log"
      jq -n --arg a "$pc_sha_a" '{version: 2, plugins: {"widget@m":
        [{scope: "user", version: "1.0.0", gitCommitSha: $a}]}}' \
        >"$HOME/.claude/plugins/installed_plugins.json"
      jq -n --arg b "$pc_sha_b" '{available: [{pluginId: "widget@m", version: "1.1.0",
        source: {source: "git", url: "https://example.invalid/widget.git", sha: $b}}]}' \
        >"$pc/hooks-catalog.json"
      printf '%s\n' '{"widget@m":true}' >"$pc/hooks-enabled.json"
      # The installed trees: Claude's verified install at the new SHA, and
      # Codex's copies by version (`new` is byte-identical to Claude's).
      rm -rf "$pc/claude-installs" "$pc/codex-home"
      for pc_tree in "$pc/claude-installs/widget@m/1.1.0" \
        "$pc/codex-home/plugins/cache/m/widget/new"; do
        mkdir -p "$pc_tree/hooks"
        printf '%s\n' '{"hooks":{"Stop":[{"command":"echo new"}]}}' >"$pc_tree/hooks/hooks.json"
        printf 'widget 1.1.0\n' >"$pc_tree/README.md"
      done
      mkdir -p "$pc/codex-home/plugins/cache/m/widget/old/hooks"
      printf '%s\n' '{"hooks":{"Stop":[{"command":"echo old"}]}}' \
        >"$pc/codex-home/plugins/cache/m/widget/old/hooks/hooks.json"
    }
    pc_hooks_apply() {
      CODEX_HOME="$pc/codex-home" CLAUDE_INSTALL_PATH_ROOT="$pc/claude-installs" \
        PATH="$pc/hooks-bin:$PATH" PC_HOOKS_STATE="$pc/hooks-state" \
        CLAUDE_PLUGIN_CATALOG_FILE="$pc/hooks-catalog.json" \
        CLAUDE_PLUGIN_ENABLED_FILE="$pc/hooks-enabled.json" \
        CLAUDE_INSTALL_MARKER="$pc/hooks-installs" \
        fleet_run_apply_item "$pc/store" vireo '{}' plugins.widget \
          '{"state":"enabled","marketplace":"m"}' '' >/dev/null 2>"$pc/hooks-err"
    }
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 0 ] ||
      fail "an enabled fleet plugin whose hooks changed upstream was held (got $pc_status): $(tr '\n' ';' <"$pc/hooks-state/log")"
    [ "$(head -2 "$pc/hooks-state/log" | tr '\n' ';')" = 'codex-add widget@m;trust sha256:new;' ] ||
      fail "the Codex copy was not refreshed, carrying its hook trust, before approval: $(tr '\n' ';' <"$pc/hooks-state/log")"
    [ "$(cat "$pc/hooks-state/trusted")" = sha256:new ] ||
      fail "the changed hook did not end trusted at its new hash"
    # Codex already at the expected bytes, hooks unchanged upstream: the copy
    # is left alone (no reinstall) and approval passes as it is.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' new >"$pc/hooks-state/version"
    printf '%s\n' sha256:new >"$pc/hooks-state/trusted"
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 0 ] ||
      fail "a Codex copy already at the expected bytes was held (got $pc_status)"
    ! grep -q codex-add "$pc/hooks-state/log" ||
      fail "a Codex copy already at the expected bytes was reinstalled: $(tr '\n' ';' <"$pc/hooks-state/log")"
    # Codex already advanced the copy AND its hooks changed upstream (they
    # read `modified` against the old trusted hash), from the verified source
    # at the expected SHA, its installed tree byte-identical to Claude's
    # verified install: automatic approval CARRIES the existing trust to the
    # new hash, and the item applies. No reinstall.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' new >"$pc/hooks-state/version"
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 0 ] && [ "$(cat "$pc/hooks-state/trusted")" = sha256:new ] &&
      ! grep -q codex-add "$pc/hooks-state/log" ||
      fail "a byte-verified advanced copy's changed hook was not carried to its new hash (got $pc_status): $(tr '\n' ';' <"$pc/hooks-err")"
    # ...a ONE-BYTE local edit in Codex's tree is not the verified bytes.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' new >"$pc/hooks-state/version"
    printf 'widget 1.1.1\n' >"$pc/codex-home/plugins/cache/m/widget/new/README.md"
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 75 ] && [ "$(cat "$pc/hooks-state/trusted")" = sha256:old ] ||
      fail "a locally edited Codex copy had its modified hook trusted (got $pc_status)"
    grep -q "differs byte-for-byte from Claude's verified install" "$pc/hooks-err" ||
      fail "the refusal did not name the byte mismatch: $(tr '\n' ';' <"$pc/hooks-err")"
    # ...a hook that was NEVER trusted is not carried over: no new grants.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' new >"$pc/hooks-state/version"
    : >"$pc/hooks-state/trusted"
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 75 ] && [ ! -s "$pc/hooks-state/trusted" ] ||
      fail "automatic approval granted trust to a never-trusted hook (got $pc_status)"
    # ...and with no Claude install at that SHA there is nothing to compare.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' new >"$pc/hooks-state/version"
    rm -rf "$pc/claude-installs"
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 75 ] && [ "$(cat "$pc/hooks-state/trusted")" = sha256:old ] ||
      fail "a modified hook was trusted with no Claude install to compare against (got $pc_status)"
    grep -q 'no Claude install of widget@m' "$pc/hooks-err" ||
      fail "the refusal did not name the missing Claude install: $(tr '\n' ';' <"$pc/hooks-err")"
    # The helper's update NEVER reports trust it did not carry: when Codex's
    # startup sync advances the copy under its snapshot (trusted hooks then
    # read modified), it says so and fails, and writes nothing.
    pc_hooks_reset
    printf '%s\n' new >"$pc/hooks-state/pending"
    pc_status=0
    pc_err=$(cd "$pc" && PATH="$pc/hooks-bin:$PATH" PC_HOOKS_STATE="$pc/hooks-state" \
      node "$script_dir/codex-plugin-hooks.mjs" update widget@m 2>&1 >/dev/null) || pc_status=$?
    [ "$pc_status" -ne 0 ] ||
      fail "the hook helper reported an update after Codex advanced the copy under its snapshot"
    case $pc_err in
      *'Codex advanced widget@m before the trust snapshot'*) ;;
      *) fail "the hook helper did not say Codex advanced the copy: $pc_err" ;;
    esac
    [ "$(cat "$pc/hooks-state/trusted")" = sha256:old ] &&
      ! grep -q '^trust\|codex-add' "$pc/hooks-state/log" ||
      fail "the hook helper carried or wrote trust after Codex advanced the copy: $(tr '\n' ';' <"$pc/hooks-state/log")"
    # The same ID registered in Codex from ANOTHER source: the helper would
    # install those bytes and re-trust their hooks before the identity check
    # refused, and a hold undoes neither. Refused before anything runs.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' '{"source":"git","url":"https://example.invalid/impostor.git"}' \
      >"$pc/hooks-state/source"
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 75 ] ||
      fail "a Codex copy from another source was approved (got $pc_status)"
    [ ! -s "$pc/hooks-state/log" ] && [ "$(cat "$pc/hooks-state/version")" = old ] &&
      [ "$(cat "$pc/hooks-state/trusted")" = sha256:old ] ||
      fail "a Codex copy from another source was refreshed or re-trusted: $(tr '\n' ';' <"$pc/hooks-state/log")"
    # A Codex registration someone DISABLED is never reinstalled (that would
    # re-enable it) and has no hooks to approve; the Claude item still applies.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' false >"$pc/hooks-state/enabled"
    pc_status=0
    pc_hooks_apply || pc_status=$?
    [ "$pc_status" -eq 0 ] ||
      fail "a disabled Codex copy held the Claude plugin item (got $pc_status)"
    [ ! -s "$pc/hooks-state/log" ] && [ "$(cat "$pc/hooks-state/version")" = old ] ||
      fail "a disabled Codex copy was reinstalled or re-trusted: $(tr '\n' ';' <"$pc/hooks-state/log")"
    # An in-marketplace (relative) catalog entry: the two marketplaces must be
    # the same repository, and the record that path under the Codex root.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    jq -n --arg b "$pc_sha_b" '{available: [{pluginId: "widget@m", version: "1.1.0",
      source: {source: "relative", path: "./plugins/widget", sha: $b}}]}' \
      >"$pc/hooks-catalog.json"
    printf '%s\n' '[{"name":"m","source":"github","repo":"owner/mkt"}]' >"$pc/claude-markets.json"
    pc_relative() {
      # pc_relative CODEX-MARKET-URL RECORD-PATH -> fleet_run_codex_source_ok's status
      jq -n --arg u "$1" '{marketplaces: [{name: "m", root: "/codex/m",
        marketplaceSource: {sourceType: "git", source: $u}}]}' >"$pc/hooks-state/markets"
      jq -n --arg p "$2" '{source: "local", path: $p}' >"$pc/hooks-state/source"
      PATH="$pc/hooks-bin:$PATH" PC_HOOKS_STATE="$pc/hooks-state" \
        CLAUDE_PLUGIN_CATALOG_FILE="$pc/hooks-catalog.json" \
        CLAUDE_PLUGIN_MARKETPLACE_FILE="$pc/claude-markets.json" \
        fleet_run_codex_source_ok widget@m
    }
    pc_relative https://github.com/Owner/mkt.git /codex/m/plugins/widget/ ||
      fail "an in-marketplace Codex copy from the same repository was refused"
    ! pc_relative https://github.com/attacker/mkt.git /codex/m/plugins/widget ||
      fail "an in-marketplace Codex copy from another repository was accepted"
    ! pc_relative https://github.com/owner/mkt.git /codex/m/plugins/other ||
      fail "an in-marketplace Codex copy at another path was accepted"
    # Disabled: the Codex copy and its hook trust are never touched.
    pc_hooks_reset
    fleet_run_marketplace_repair_reset
    printf '%s\n' '{"widget@m":false}' >"$pc/hooks-enabled.json"
    PATH="$pc/hooks-bin:$PATH" PC_HOOKS_STATE="$pc/hooks-state" \
      CLAUDE_PLUGIN_CATALOG_FILE="$pc/hooks-catalog.json" \
      CLAUDE_PLUGIN_ENABLED_FILE="$pc/hooks-enabled.json" \
      CLAUDE_INSTALL_MARKER="$pc/hooks-installs" \
      fleet_run_apply_item "$pc/store" vireo '{}' plugins.widget \
        '{"state":"disabled","marketplace":"m"}' '' >/dev/null 2>&1 ||
      fail "a disabled fleet plugin update failed"
    [ ! -s "$pc/hooks-state/log" ] &&
      [ "$(cat "$pc/hooks-state/trusted")" = sha256:old ] ||
      fail "a disabled desired state refreshed the Codex copy or its hook trust: $(tr '\n' ';' <"$pc/hooks-state/log")"
  )
fi
