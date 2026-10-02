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

    # --- Codex: the routine refresh, unattended ---
    cat >"$pc/bin/codex" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'plugin marketplace list --json') cat "$PC_CODEX_MARKETS"; exit 0 ;;
  'plugin list --json') cat "$PC_CODEX_PLUGINS"; exit 0 ;;
esac
if [ "$1 $2 $3" = 'plugin marketplace upgrade' ] && [ "${5:-}" = --json ]; then
  printf 'upgrade %s\n' "$4" >>"$PC_CODEX_LOG"
  [ "${PC_CODEX_UPGRADE_FAIL:-0}" != 1 ] || exit 1
  jq -n --arg rev "$(cat "$PC_CODEX_NEXT_REV")" '{source_type: "git", ref_name: null, revision: $rev}' \
    >"$PC_CODEX_ROOT/.codex-marketplace-install.json"
  exit 0
fi
exit 64
SH
    cat >"$pc/bin/fake-node" <<'SH'
#!/usr/bin/env bash
printf 'helper %s %s\n' "$2" "$3" >>"$PC_CODEX_LOG"
[ "$3" != "${PC_NODE_FAIL_ID:-}" ] || exit 1
SH
    chmod +x "$pc/bin/codex" "$pc/bin/fake-node"
    mkdir -p "$pc/codex-root"
    export PC_CODEX_MARKETS="$pc/codex-markets.json" PC_CODEX_PLUGINS="$pc/codex-plugins.json" \
      PC_CODEX_LOG="$pc/codex.log" PC_CODEX_NEXT_REV="$pc/codex-next-rev" \
      PC_CODEX_ROOT="$pc/codex-root"
    jq -n --arg root "$pc/codex-root" '{marketplaces: [
      {name: "novotnyllc", root: $root,
       marketplaceSource: {sourceType: "git", source: "https://example.invalid/m.git"}},
      {name: "openai-bundled", root: "/bundled", marketplaceSource: {sourceType: "local", source: "/bundled"}}]}' \
      >"$PC_CODEX_MARKETS"
    printf '%s\n' '{"installed":[
      {"pluginId":"roundhouse@novotnyllc","marketplaceName":"novotnyllc","installed":true,"enabled":true},
      {"pluginId":"railyard@novotnyllc","marketplaceName":"novotnyllc","installed":true,"enabled":true},
      {"pluginId":"agent-utilities@novotnyllc","marketplaceName":"novotnyllc","installed":true,"enabled":true},
      {"pluginId":"tart-xcode-runner@novotnyllc","marketplaceName":"novotnyllc","installed":true,"enabled":true},
      {"pluginId":"dormant@novotnyllc","marketplaceName":"novotnyllc","installed":true,"enabled":false},
      {"pluginId":"gone@novotnyllc","marketplaceName":"novotnyllc","installed":false},
      {"pluginId":"browser@openai-bundled","marketplaceName":"openai-bundled","installed":true}]}' \
      >"$PC_CODEX_PLUGINS"
    pc_rev1=1111111111111111111111111111111111111111
    pc_rev2=2222222222222222222222222222222222222222
    printf '%s\n' "$pc_rev1" >"$PC_CODEX_NEXT_REV"
    (
      PATH="$pc/bin:$PATH"
      fleet_node_path() { printf '%s\n' "$pc/bin/fake-node"; }
      # Local and remote-catalog marketplaces advance with Codex itself.
      [ "$(fleet_plugins_codex_markets | tr "$us" '|')" = \
        "novotnyllc|https://example.invalid/m.git||$pc/codex-root" ] ||
        fail "the Codex Git marketplaces were wrong: $(fleet_plugins_codex_markets)"
      # A full refresh: upgrade the Git marketplace, then every installed,
      # enabled plugin from it through the hook-preserving helper, roundhouse
      # last. A fleet item is the item loop's — held or not, a tombstone
      # (`railyard: absent`, outside the fold) or a definition — and a
      # disabled install is never handed to a helper that rewrites hook trust.
      : >"$PC_CODEX_LOG"
      pc_out=$(fleet_plugins_refresh "$pc/store" vireo '{}' \
        '{"plugins":{"agent-utilities":{"marketplace":"novotnyllc"}}}' full "$pc" \
        '{"plugins":{"railyard":"absent"}}')
      printf '%s\n' 'upgrade novotnyllc' 'helper update tart-xcode-runner@novotnyllc' \
        'helper update roundhouse@novotnyllc' >"$pc/codex.want"
      cmp -s "$PC_CODEX_LOG" "$pc/codex.want" ||
        fail "the Codex refresh touched a fleet item or a disabled install: $(tr '\n' ';' <"$PC_CODEX_LOG")"
      rm -f "$(fleet_plugins_memo_path codex novotnyllc complete)"
      : >"$PC_CODEX_LOG"
      pc_out=$(fleet_plugins_refresh "$pc/store" vireo '{}' '{}' full "$pc")
      printf '%s\n' 'upgrade novotnyllc' 'helper update agent-utilities@novotnyllc' \
        'helper update railyard@novotnyllc' 'helper update tart-xcode-runner@novotnyllc' \
        'helper update roundhouse@novotnyllc' \
        >"$pc/codex.want"
      cmp -s "$PC_CODEX_LOG" "$pc/codex.want" ||
        fail "the Codex refresh did not run the routine sequence: $(tr '\n' ';' <"$PC_CODEX_LOG")"
      case $pc_out in
        *'update plugin roundhouse@novotnyllc (codex)'*) ;;
        *) fail "the Codex refresh did not report its updates: $pc_out" ;;
      esac
      [ "$(fleet_plugins_memo_read codex novotnyllc complete)" = "$pc_rev1" ] ||
        fail "a completed Codex refresh did not remember its revision"
      # The same revision again costs one upgrade and nothing more.
      : >"$PC_CODEX_LOG"
      fleet_plugins_codex_refresh novotnyllc "$pc/codex-root" >/dev/null
      [ "$(cat "$PC_CODEX_LOG")" = 'upgrade novotnyllc' ] ||
        fail "an unchanged Codex marketplace re-ran its plugin updates: $(tr '\n' ';' <"$PC_CODEX_LOG")"
      # A new revision with one failing update: every plugin is still tried,
      # and the revision is not recorded complete, so the next pass retries.
      printf '%s\n' "$pc_rev2" >"$PC_CODEX_NEXT_REV"
      : >"$PC_CODEX_LOG"
      pc_out=$(PC_NODE_FAIL_ID=railyard@novotnyllc \
        fleet_plugins_codex_refresh novotnyllc "$pc/codex-root" "$pc_rev2")
      [ "$(grep -c '^helper update' "$PC_CODEX_LOG")" -eq 4 ] ||
        fail "one failed Codex update stopped the rest: $(tr '\n' ';' <"$PC_CODEX_LOG")"
      case $pc_out in
        *'hold  plugin railyard@novotnyllc (codex)'*) ;;
        *) fail "a failed Codex update was not reported as a hold: $pc_out" ;;
      esac
      [ "$(fleet_plugins_memo_read codex novotnyllc complete)" = "$pc_rev1" ] ||
        fail "a Codex refresh with a failed update was recorded complete"
      [ "$(fleet_plugins_memo_read codex novotnyllc attempted)" = "$pc_rev2" ] ||
        fail "the attempted upstream head was not remembered"
      # A listing that exits 0 but is not the documented shape fails CLOSED:
      # no upgrade, and neither memo moves, so the revision is never recorded
      # complete with nothing updated.
      pc_rev3=3333333333333333333333333333333333333333
      printf '%s\n' "$pc_rev3" >"$PC_CODEX_NEXT_REV"
      cp "$PC_CODEX_PLUGINS" "$pc/codex-plugins.good"
      for pc_bad_list in '{"installed":"nope"}' '{invalid' '[]' '{"installed":["x"]}'; do
        printf '%s\n' "$pc_bad_list" >"$PC_CODEX_PLUGINS"
        : >"$PC_CODEX_LOG"
        pc_out=$(fleet_plugins_codex_refresh novotnyllc "$pc/codex-root" "$pc_rev3")
        [ ! -s "$PC_CODEX_LOG" ] ||
          fail "a malformed codex plugin list ($pc_bad_list) still upgraded or updated: $(tr '\n' ';' <"$PC_CODEX_LOG")"
        case $pc_out in
          *'hold  marketplace novotnyllc (codex) — codex plugin list is unreadable'*) ;;
          *) fail "a malformed codex plugin list ($pc_bad_list) was not held: $pc_out" ;;
        esac
        [ "$(fleet_plugins_memo_read codex novotnyllc complete)" = "$pc_rev1" ] &&
          [ "$(fleet_plugins_memo_read codex novotnyllc attempted)" = "$pc_rev2" ] ||
          fail "a malformed codex plugin list ($pc_bad_list) advanced a memo"
      done
      cp "$pc/codex-plugins.good" "$PC_CODEX_PLUGINS"
      # A failed upgrade updates nothing.
      : >"$PC_CODEX_LOG"
      pc_out=$(PC_CODEX_UPGRADE_FAIL=1 \
        fleet_plugins_codex_refresh novotnyllc "$pc/codex-root")
      ! grep -q '^helper' "$PC_CODEX_LOG" ||
        fail "plugins were updated from a marketplace whose upgrade failed"
      case $pc_out in
        *'hold  marketplace novotnyllc (codex)'*) ;;
        *) fail "a failed Codex marketplace upgrade was not reported: $pc_out" ;;
      esac
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

    # --- an owned, enabled plugin whose hooks change upstream ends approved ---
    # The item loop updates Claude's copy; automatic approval reads Codex's. A
    # Codex copy left at the old bytes refused (source mismatch) and held the
    # item for good. Codex here models hook trust by hash: a hook is trusted
    # only while its current hash is the one trust was written for.
    mkdir -p "$pc/hooks-bin" "$pc/hooks-state"
    cat >"$pc/hooks-bin/codex" <<'SH'
#!/usr/bin/env bash
st=$PC_HOOKS_STATE
ver=$(cat "$st/version")
if [ "${1:-}" = app-server ] && [ "${2:-}" = --stdio ]; then
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
    jq -cn --arg v "$ver" --arg sha "$(cat "$st/sha-$ver")" '{installed:[{
      pluginId:"widget@m",name:"widget",marketplaceName:"m",version:$v,
      installed:true,enabled:true,source:{source:"local",path:"x",sha:$sha}}]}'
    ;;
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
      : >"$pc/hooks-state/log"
      jq -n --arg a "$pc_sha_a" '{version: 2, plugins: {"widget@m":
        [{scope: "user", version: "1.0.0", gitCommitSha: $a}]}}' \
        >"$HOME/.claude/plugins/installed_plugins.json"
      jq -n --arg b "$pc_sha_b" '{available: [{pluginId: "widget@m", version: "1.1.0",
        source: {source: "git", sha: $b}}]}' >"$pc/hooks-catalog.json"
      printf '%s\n' '{"widget@m":true}' >"$pc/hooks-enabled.json"
    }
    pc_hooks_apply() {
      PATH="$pc/hooks-bin:$PATH" PC_HOOKS_STATE="$pc/hooks-state" \
        CLAUDE_PLUGIN_CATALOG_FILE="$pc/hooks-catalog.json" \
        CLAUDE_PLUGIN_ENABLED_FILE="$pc/hooks-enabled.json" \
        CLAUDE_INSTALL_MARKER="$pc/hooks-installs" \
        fleet_run_apply_item "$pc/store" vireo '{}' plugins.widget \
          '{"state":"enabled","marketplace":"m"}' '' >/dev/null 2>&1
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
