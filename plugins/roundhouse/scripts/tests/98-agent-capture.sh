# roundhouse self-check — authoritative observation, merge, and capture gates.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'agent capture: merge, observations, layer edits and cap\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    while read -r base ours theirs answer; do
      [ "$(fleet_merge3 "$base" "$ours" "$theirs")" = "$answer" ] ||
        fail "merge3 $base $ours $theirs did not yield $answer"
    done <<'MERGE'
enabled enabled enabled same
enabled enabled disabled converge
enabled absent enabled local
enabled disabled disabled agree
enabled absent disabled conflict
absent enabled absent local
enabled unknown disabled unknown
enabled enabled missing ignore
enabled absent missing ignore
missing enabled missing local
missing absent missing same
missing absent enabled converge
missing enabled disabled conflict
ignored:enabled enabled missing ignore
ignored:enabled disabled missing ignore
ignored:enabled absent missing forget
ignored:enabled enabled disabled converge
ignored:enabled absent disabled conflict
MERGE

    rh_capture_root="$tmp/agent-capture"
    rh_capture_store="$rh_capture_root/store"
    rh_capture_tmp="$rh_capture_root/pass"
    ROUNDHOUSE_FLEET_STORE=$rh_capture_store
    CLAUDE_CONFIG_DIR="$rh_capture_root/claude"
    CODEX_HOME="$rh_capture_root/codex"
    export ROUNDHOUSE_FLEET_STORE CLAUDE_CONFIG_DIR CODEX_HOME
    mkdir -p "$rh_capture_store/fleet" "$rh_capture_store/hosts" "$rh_capture_tmp" \
      "$CLAUDE_CONFIG_DIR/plugins" "$CODEX_HOME"
    rh_capture_dir=$(fleet_instance_path store.run)
    cat >"$rh_capture_store/fleet.yaml" <<'YAML'
# fleet comment
policy:
  max_change_fraction: 1
plugins:
  ponytail: {state: disabled, marketplace: m}
  keeper: {state: enabled, marketplace: m}
YAML
    cat >"$rh_capture_store/fleet/10-retired.yaml" <<'YAML'
# give this layer precedence
plugins:
  ponytail: {state: absent, marketplace: m}
YAML
    printf 'platform: macos\nplugins:\n  pinned: {state: enabled, marketplace: m}\n' \
      >"$rh_capture_store/hosts/mac.yaml"
    printf 'platform: linux\ncapture: false\ndefault_agent_state: absent\n' \
      >"$rh_capture_store/hosts/grokbox.yaml"
    rh_capture_fold=$(fleet_run_desired "$rh_capture_store" mac)
    rh_capture_ours='{"claude":{
      "keeper@m":{"value":"enabled","marketplace":"m","stageable":true},
      "pinned@m":{"value":"enabled","marketplace":"m","stageable":true},
      "extra@m":{"value":"enabled","marketplace":"m","stageable":true}
    },"codex":{},"codex_markets":{"m":true}}'

    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] || fail "first pass prepared a captured change"
    fleet_capture_publish_alerts "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" "$rh_capture_store"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true
    jq -e '.["claude:ponytail@m"] == {value:"absent"} and
      .["claude:extra@m"] == {value:"enabled",ignored:true}' "$rh_capture_dir/agent-baseline.json" >/dev/null ||
      fail "first pass lost agreed tombstone or ignored extra"
    compgen -G "$rh_capture_store/alerts/mac/agent-capture-ignored--*.yaml" >/dev/null ||
      fail "silent pass did not list extras"

    rh_capture_added=$(jq -c '.claude["ponytail@m"]={value:"enabled",marketplace:"m",stageable:true}' <<<"$rh_capture_ours")
    fleet_agent_pending_mark claude ponytail@m
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_added" true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] || fail "captured Roundhouse's marked install"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_added" true
    [ -f "$(fleet_agent_pending_path claude:ponytail@m)" ] || fail "cleared a crash marker before agreement"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true
    [ ! -e "$(fleet_agent_pending_path claude:ponytail@m)" ] || fail "agreed marker did not clear"
    rh_capture_legacy=$(jq -c '.plugins.legacy = "absent"' <<<"$rh_capture_fold")
    fleet_agent_pending_mark claude legacy@m
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_legacy" "$rh_capture_ours" true
    jq -e '.["claude:legacy@m"].value == "absent"' "$rh_capture_dir/agent-baseline.json" >/dev/null &&
      [ ! -e "$(fleet_agent_pending_path claude:legacy@m)" ] ||
      fail "an unqualified tombstone lost the installed identity recorded by its pending marker"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_added" true false "$rh_capture_tmp"
    jq -e 'has("plugins.ponytail")' <<<"$fleet_capture_skip" >/dev/null ||
      fail "offline local change did not skip convergence"
    [ "$fleet_capture_items" = '[]' ] || fail "offline pass prepared a capture"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_added" true true "$rh_capture_tmp"
    jq -e 'length == 1 and .[0].path == "fleet/10-retired.yaml"' <<<"$fleet_capture_items" >/dev/null ||
      fail "owner install did not capture in the highest declaring layer"
    jq -e 'has("plugins.ponytail")' <<<"$fleet_capture_skip" >/dev/null ||
      fail "owner install would be uninstalled before publication"
    fleet_capture_stage "$rh_capture_store" "$rh_capture_tmp"
    grep -q '^# give this layer precedence' "$rh_capture_store/fleet/10-retired.yaml" ||
      fail "state edit dropped the declaring layer comment"
    [ "$(yq '.plugins.ponytail.state' "$rh_capture_store/fleet/10-retired.yaml")" = enabled ] ||
      fail "tombstoned plugin owner install did not change state"
    [ "$(yq '.plugins.ponytail.state' "$rh_capture_store/fleet.yaml")" = disabled ] ||
      fail "capture changed the lower-precedence declaration"
    yq -o=json '.[]' "$rh_capture_store"/journal/mac/*.yaml | jq -es '
      any(.[]; .outcome == "captured" and .who == "user" and .host == "mac" and .harness == "claude")' >/dev/null ||
      fail "journal omitted captured item attribution"
    fleet_capture_abort "$rh_capture_store" "$rh_capture_tmp"
    [ "$(yq '.plugins.ponytail.state' "$rh_capture_store/fleet/10-retired.yaml")" = absent ] ||
      fail "failed publication left a staged edit"
    fleet_capture_stage "$rh_capture_store" "$rh_capture_tmp"
    fleet_capture_done

    rh_capture_fold=$(fleet_run_desired "$rh_capture_store" mac)
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_added" true
    rh_capture_removed=$(jq -c 'del(.claude["ponytail@m"])' <<<"$rh_capture_added")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_removed" true true "$rh_capture_tmp"
    jq -e 'has("plugins.ponytail")' <<<"$fleet_capture_skip" >/dev/null ||
      fail "owner removal would be reinstalled before publication"
    fleet_capture_stage "$rh_capture_store" "$rh_capture_tmp"
    [ "$(yq '.plugins.ponytail.state' "$rh_capture_store/fleet/10-retired.yaml")" = absent ] ||
      fail "owner uninstall did not keep a tombstone"
    fleet_capture_abort "$rh_capture_store" "$rh_capture_tmp"

    # Both changed, then explicit adoption reads the displaced value after convergence.
    yq -i '.plugins.ponytail.state = "disabled"' "$rh_capture_store/fleet/10-retired.yaml"
    rh_capture_fold=$(fleet_run_desired "$rh_capture_store" mac)
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_removed" true true "$rh_capture_tmp"
    jq -e '.["claude:ponytail@m"].value == "absent" and .["claude:ponytail@m"].theirs == "disabled"' \
      "$rh_capture_dir/agent-conflicts.json" >/dev/null || fail "conflict lost displaced value before convergence"
    [ "$fleet_capture_items:$fleet_capture_skip" = '[]:{}' ] || fail "conflict did not let fleet converge"
    [ -f "$rh_capture_store/alerts/mac/agent-capture-conflict--plugins.ponytail.yaml" ] ||
      fail "conflict alert did not name its item"
    rh_capture_converged=$(jq -c '.claude["ponytail@m"].value="disabled"' <<<"$rh_capture_added")
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_converged" true
    fleet_capture_json_write "$rh_capture_dir/agent-take-local.json" '{"claude:ponytail@m":true}'
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_converged" true true "$rh_capture_tmp"
    jq -e '.[0].value == "absent"' <<<"$fleet_capture_items" >/dev/null ||
      fail "take-local did not recover displaced value"
    fleet_capture_stage "$rh_capture_store" "$rh_capture_tmp"
    fleet_capture_done
    jq -e 'length == 0' "$rh_capture_dir/agent-conflicts.json" >/dev/null ||
      fail "published take-local kept the conflict"

    rh_capture_fold=$(fleet_run_desired "$rh_capture_store" mac)
    rh_capture_host_text=$(cat "$rh_capture_store/hosts/mac.yaml")
    rh_capture_pinned=$(jq -c '.claude["pinned@m"].value="disabled"' <<<"$rh_capture_removed")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_pinned" true true "$rh_capture_tmp"
    jq -e 'has("plugins.pinned")' <<<"$fleet_capture_skip" >/dev/null ||
      fail "pinned local change would be reverted"
    [ "$fleet_capture_items" = '[]' ] &&
      [ "$(cat "$rh_capture_store/hosts/mac.yaml")" = "$rh_capture_host_text" ] &&
      [ -f "$rh_capture_store/alerts/mac/agent-pinned-local-change--plugins.pinned.yaml" ] ||
      fail "pinned item became a capture or failed to alert"

    rh_capture_grok=$(fleet_run_desired "$rh_capture_store" grokbox)
    jq -e '(.plugins.keeper | if type == "object" then .state else . end) == "absent"' <<<"$rh_capture_grok" >/dev/null ||
      fail "grokbox did not default an undeclared fleet plugin to absent"
    fleet_capture_prepare "$rh_capture_store" grokbox "$rh_capture_grok" "$rh_capture_added" true true "$rh_capture_tmp"
    [ "$fleet_capture_items:$fleet_capture_skip" = '[]:{}' ] || fail "grokbox captured or suppressed convergence"

    rh_capture_saved_baseline=$(cat "$rh_capture_dir/agent-baseline.json")
    fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" \
      "$(jq -c '.["claude:keeper@m"].value="absent"' <<<"$rh_capture_saved_baseline")"
    fleet_capture_prepare "$rh_capture_store" grokbox \
      "$(jq -c '.capture=true' <<<"$rh_capture_grok")" "$rh_capture_removed" true true "$rh_capture_tmp"
    jq -e 'has("plugins.keeper")' <<<"$fleet_capture_skip" >/dev/null &&
      [ "$fleet_capture_items" = '[]' ] || fail "a host projection repeatedly captured its local override"
    fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" "$rh_capture_saved_baseline"

    # Cap all six state changes as one batch. Confirming exactly that batch
    # releases it, while discarding the same derived set unblocks converge.
    for rh_i in 1 2 3 4 5 6; do
      rh_key="p$rh_i"
      rh_name=$rh_key yq -i '.plugins[strenv(rh_name)] = {"state":"enabled","marketplace":"m"}' "$rh_capture_store/fleet.yaml"
    done
    rh_capture_fold=$(fleet_run_desired "$rh_capture_store" mac)
    rh_capture_six=$(jq -c 'reduce range(1;7) as $n (.;
      .claude["p\($n)@m"]={value:"enabled",marketplace:"m",stageable:true})' <<<"$rh_capture_removed")
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_six" true
    rh_capture_six=$(jq -c '.claude |= with_entries(if (.key | test("^p[1-6]@")) then .value.value="disabled" else . end)' <<<"$rh_capture_six")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_six" true true "$rh_capture_tmp"
    rh_capture_batch=$(cat "$rh_capture_dir/agent-pending-confirm.json")
    jq -e '.items | length == 6' <<<"$rh_capture_batch" >/dev/null &&
      jq -e 'length == 6' <<<"$fleet_capture_skip" >/dev/null &&
      [ "$fleet_capture_items" = '[]' ] || fail "cap did not hold one six-item batch"
    fleet_capture_json_write "$rh_capture_dir/agent-pending-confirm.json" "$(jq -c '.confirmed=true' <<<"$rh_capture_batch")"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_six" true true "$rh_capture_tmp"
    jq -e 'length == 6' <<<"$fleet_capture_items" >/dev/null || fail "confirmation did not release exact batch"
    rh_capture_unrelated=$(jq -c 'reduce range(1;7) as $n (.;
      .claude["p\($n)@m"].value="enabled" |
      .claude["new\($n)@m"]={value:"enabled",marketplace:"m",stageable:true})' <<<"$rh_capture_six")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_unrelated" true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] &&
      jq -e --arg old "$(jq -r .id <<<"$rh_capture_batch")" '.id != $old and .confirmed == false' \
        "$rh_capture_dir/agent-pending-confirm.json" >/dev/null ||
      fail "confirmation authorized unrelated changes"
    fleet_capture_json_write "$rh_capture_dir/agent-pending-confirm.json" "$(jq -c '.discarded=true' <<<"$rh_capture_batch")"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_six" true true "$rh_capture_tmp"
    [ "$fleet_capture_items:$fleet_capture_skip" = '[]:{}' ] ||
      fail "discard did not let the fleet reapply its values"
    fleet_capture_done

    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" '{"claude":{},"codex":null}' true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] && jq -e 'has("plugins.keeper")' <<<"$fleet_capture_skip" >/dev/null ||
      fail "wiped inventory was interpreted as removals or converged"

    # The CLI can make a nominally successful but incomplete list. The
    # authoritative count alone is insufficient if a registered user row remains.
    printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"user","installPath":"/missing-fixture"}]}}' \
      >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    printf '%s\n' '{"enabledPlugins":{"keeper@m":true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
    cat >"$rh_capture_root/inventory.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":1}}
{"kind":"plugin","status":"present","data":{"agent":"claude","inventory_source":"manager","manager_id":"keeper@m","name":"keeper","marketplace":"m","scope":"user","enabled":true,"installed_version":"100"}}
JSONL
    rh_observed=$(fleet_capture_observe "$rh_capture_root/inventory.jsonl")
    jq -e '.claude["keeper@m"].value == "enabled" and .codex == null' <<<"$rh_observed" >/dev/null ||
      fail "authoritative CLI and native records did not describe a damaged install as installed"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_observed" true true "$rh_capture_tmp"
    jq -e 'all(.[]; .item != "plugins.keeper")' <<<"$fleet_capture_items" >/dev/null ||
      fail "version-only update was captured"
    mv "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" "$rh_capture_root/original.json"
    printf '{broken\n' >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    fleet_capture_observe "$rh_capture_root/inventory.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "unparseable registry read as authoritative"
    mv "$rh_capture_root/original.json" "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    head -1 "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/partial.jsonl"
    fleet_capture_observe "$rh_capture_root/partial.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "partial CLI listing read as authoritative"
    sed 's/"status":"present"/"status":"unavailable"/' "$rh_capture_root/partial.jsonl" >"$rh_capture_root/failed.jsonl"
    fleet_capture_observe "$rh_capture_root/failed.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "failed CLI listing read as authoritative"
    sed 's/"scope":"user"/"scope":"project"/' "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/project.jsonl"
    printf '{}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
    fleet_capture_observe "$rh_capture_root/project.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "project-only CLI row was used as user-scope evidence"
    jq -c 'if .kind == "plugin_manager" then .data.installed_count=2 else . end' \
      "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/mixed.jsonl"
    tail -1 "$rh_capture_root/project.jsonl" |
      jq -c '.data.enabled=false' >>"$rh_capture_root/mixed.jsonl"
    fleet_capture_observe "$rh_capture_root/mixed.jsonl" |
      jq -e '.claude["keeper@m"].value == "enabled"' >/dev/null ||
      fail "the project row interfered with a matching user-scope CLI row"

    # Keeper previously agreed from a network marketplace. A repoint to a
    # local directory followed by removal must not publish a fleet tombstone.
    sed 's/keeper/extra/g' "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/repointed.jsonl"
    printf '%s\n' '{"plugins":{"extra@m":[{"scope":"user"}]}}' \
      >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    printf '%s\n' '{"enabledPlugins":{"extra@m":true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
    printf '%s\n' '{"m":{"source":{"source":"directory","path":"/fixture-market"}}}' \
      >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
    rh_observed=$(fleet_capture_observe "$rh_capture_root/repointed.jsonl")
    fleet_capture_rows "$rh_capture_store" "$rh_capture_fold" "$rh_observed" \
      "$(cat "$rh_capture_dir/agent-baseline.json")" | jq -e '
        any(.[]; .id == "claude:keeper@m" and .base.value == "enabled" and
          .ours == "absent" and .stageable == false)' >/dev/null ||
      fail "removal from a repointed local marketplace remained eligible for capture"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_observed" true true "$rh_capture_tmp"
    jq -e 'all(.[]; .id != "claude:keeper@m")' <<<"$fleet_capture_items" >/dev/null ||
      fail "a local marketplace removal was staged"

    cat >"$rh_capture_root/codex.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"codex","authoritative":true,"installed_count":1}}
{"kind":"plugin","status":"present","data":{"agent":"codex","inventory_source":"manager","manager_id":"cc@m","name":"cc","marketplace":"m","enabled":true,"installed_version":"1"}}
JSONL
    bounded_query() { printf '%s\n' '{"marketplaces":[{"name":"m","marketplaceSource":{"sourceType":"git","source":"https://example.invalid/m"}}]}'; }
    printf '[plugins._default]\nenabled = true\n[plugins."cc@m"]\nenabled = true\n' >"$CODEX_HOME/config.toml"
    fleet_capture_observe "$rh_capture_root/codex.jsonl" | jq -e '.codex["cc@m"].stageable' >/dev/null ||
      fail "Codex user registration did not agree with its plugin listing"
    (
      bounded_query() { return 1; }
      fleet_capture_observe "$rh_capture_root/codex.jsonl" |
        jq -e '.retry == true and .codex["cc@m"].stageable == false' >/dev/null ||
        fail "failed Codex marketplace lookup acknowledged an unprocessed owner add"
      bounded_query() { printf '%s\n' '{"marketplaces":[{"name":"m"}]}'; }
      fleet_capture_observe "$rh_capture_root/codex.jsonl" |
        jq -e '.retry == true and .codex["cc@m"].stageable == false' >/dev/null ||
        fail "partial Codex marketplace metadata permitted capture"
      bounded_query() {
        printf '%s\n' '{"marketplaces":[{"name":"m","marketplaceSource":{"sourceType":"git","source":"/fixture"}}]}'
      }
      fleet_capture_observe "$rh_capture_root/codex.jsonl" | jq -e '.codex["cc@m"].stageable == false' >/dev/null ||
        fail "Codex local Git marketplace permitted capture"
    )
    printf '\n[plugins."listed-only-in-config@m"]\nenabled = true\n' >>"$CODEX_HOME/config.toml"
    fleet_capture_observe "$rh_capture_root/codex.jsonl" | jq -e '.codex == null' >/dev/null ||
      fail "partial Codex listing did not hold the harness"

    rh_capture_new=$(jq -c '.codex["cc@m"]={value:"enabled",marketplace:"m",stageable:true}' <<<"$rh_capture_six")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_new" true true "$rh_capture_tmp"
    jq -e 'all(.[]; .harness != "codex")' <<<"$fleet_capture_items" >/dev/null ||
      fail "default capture policy staged Codex"
    rh_capture_fold=$(jq -c '.policy.capture_codex = true' <<<"$rh_capture_fold")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_new" true true "$rh_capture_tmp"
    jq -e 'any(.[]; .id == "codex:cc@m")' <<<"$fleet_capture_items" >/dev/null ||
      fail "Codex opt-in did not stage its add"
    rh_capture_new=$(jq -c '.claude["fresh@m"]={value:"enabled",marketplace:"m",stageable:true}' <<<"$rh_capture_six")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_new" true true "$rh_capture_tmp"
    jq -e 'any(.[]; .id == "claude:fresh@m") and all(.[]; .harness != "codex")' <<<"$fleet_capture_items" >/dev/null ||
      fail "mirror enabled by default or first-time Claude add was lost"
    rh_capture_fold=$(jq -c '.policy.capture_mirror_codex = true' <<<"$rh_capture_fold")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_new" true true "$rh_capture_tmp"
    jq -e 'any(.[]; .id == "codex:fresh@m" and .decision == "mirror")' <<<"$fleet_capture_items" >/dev/null ||
      fail "enabled mirror did not include the matching Codex marketplace"

    # Independent state for partial first observations, qualified aliases and mirrors.
    rh_capture_store="$rh_capture_root/safety/store"
    ROUNDHOUSE_FLEET_STORE=$rh_capture_store
    rh_capture_dir=$(fleet_instance_path store.run)
    mkdir -p "$rh_capture_store/hosts"
    cat >"$rh_capture_store/fleet.yaml" <<'YAML'
policy:
  capture_codex: true
  capture_mirror_codex: true
  max_changes_per_run: 1
  max_change_fraction: 1
  marketplaces: {m: {}, m2: {}}
plugins:
  retired: absent
  keeper: {state: enabled, marketplace: m}
codex_plugins:
  cc@m: {state: disabled}
YAML
    printf 'platform: macos\nplugins:\n  pinned: {state: absent, marketplace: m}\n' >"$rh_capture_store/hosts/mac.yaml"
    rh_safety_fold=$(fleet_run_desired "$rh_capture_store" mac)
    rh_safety_codex='{"claude":null,"codex":{"cc@m":{"value":"disabled","marketplace":"m","stageable":false}},"codex_markets":{"m":true}}'
    fleet_agent_pending_mark codex cc@m
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_codex" true
    jq -e '._initialized == {claude:false,codex:true} and .["codex:cc@m"].value == "disabled"' \
      "$rh_capture_dir/agent-baseline.json" >/dev/null &&
      [ ! -e "$(fleet_agent_pending_path codex:cc@m)" ] ||
      fail "non-stageable agreement cleared a Codex marker without advancing its baseline"
    rh_safety_ours=$(jq -c '.claude={
      "keeper@m":{value:"enabled",marketplace:"m",stageable:true},
      "old-extra@m":{value:"enabled",marketplace:"m",stageable:true}
    }' <<<"$rh_safety_codex")
    rh_safety_first=$(jq -c '.claude += {
      "ambiguous@m":{value:"enabled",marketplace:"m",stageable:true},
      "ambiguous@m2":{value:"disabled",marketplace:"m2",stageable:true}
    }' <<<"$rh_safety_ours")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_first" true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] && jq -e 'keys == ["plugins.ambiguous"]' <<<"$fleet_capture_skip" >/dev/null ||
      fail "first Claude observation staged a change or held an unrelated destination"
    fleet_capture_publish_alerts "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_first" "$rh_capture_store"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_first" true
    jq -e '._initialized.claude == true and .["claude:old-extra@m"].ignored == true and
      .["plugins.retired"].value == "absent" and .["claude:keeper@m"].value == "enabled" and
      all(keys[]; startswith("claude:ambiguous@") | not)' "$rh_capture_dir/agent-baseline.json" >/dev/null &&
      compgen -G "$rh_capture_store/alerts/mac/agent-capture-ignored--*.yaml" >/dev/null ||
      fail "an ambiguous Claude destination blocked initialization of unrelated plugins"
    fleet_capture_prepare "$rh_capture_store" mac "$(jq -c '.capture=false' <<<"$rh_safety_fold")" \
      "$rh_safety_codex" true true "$rh_capture_tmp"
    jq -e 'has("plugins.keeper")' <<<"$fleet_capture_skip" >/dev/null &&
      [ "$fleet_capture_items" = '[]' ] || fail "capture false bypassed the unknown inventory skip"

    rh_safety_no_mirror=$(jq -c '.policy.capture_mirror_codex=false' <<<"$rh_safety_fold")
    rh_safety_changed=$(jq -c '.claude["retired@m"]={value:"enabled",marketplace:"m",stageable:true}' <<<"$rh_safety_ours")
    mkdir -p "$rh_capture_store/fleet"
    printf 'plugins:\n  retired: {state: absent}\n' >"$rh_capture_store/fleet/90-unqualified.yaml"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_safety_no_mirror" "$rh_safety_changed" true true "$rh_capture_tmp"
    jq -e 'length == 1 and .[0].id == "claude:retired@m" and .[0].value == "enabled"' \
      <<<"$fleet_capture_items" >/dev/null || fail "owner add of an unqualified tombstone became a conflict"
    fleet_capture_stage "$rh_capture_store" "$rh_capture_tmp/unqualified"
    yq -e '.plugins.retired.state == "enabled" and .plugins.retired.marketplace == "m"' \
      "$rh_capture_store/fleet/90-unqualified.yaml" >/dev/null ||
      fail "capturing an unqualified map tombstone lost its physical marketplace"
    fleet_capture_abort "$rh_capture_store" "$rh_capture_tmp/unqualified"
    rm "$rh_capture_store/fleet/90-unqualified.yaml"
    fleet_capture_prepare "$rh_capture_store" mac "$(jq -c 'del(.plugins.retired)' <<<"$rh_safety_no_mirror")" \
      "$rh_safety_changed" true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] || fail "an owner-dropped unqualified tombstone was captured as a new declaration"

    rh_safety_changed=$(jq -c '.claude += {
      "ambiguous@m":{value:"enabled",marketplace:"m",stageable:true},
      "ambiguous@m2":{value:"disabled",marketplace:"m2",stageable:true}
    }' <<<"$rh_safety_ours")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_changed" true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] && jq -e 'has("plugins.ambiguous")' <<<"$fleet_capture_skip" >/dev/null &&
      [ -f "$rh_capture_store/alerts/mac/agent-capture-ambiguous--plugins.ambiguous.yaml" ] ||
      fail "two markets targeting one Claude destination were not held and reported"

    rh_safety_changed=$(jq -c '.claude["fresh@m"]={value:"enabled",marketplace:"m",stageable:true}' <<<"$rh_safety_ours")
    for rh_safety_transform in '.codex = null' '.codex = {}' \
      '.codex["fresh@m"]={value:"unknown",marketplace:"m",stageable:false,user_scope:false}'; do
      rh_safety_unknown=$(jq -c "$rh_safety_transform" <<<"$rh_safety_changed")
      fleet_capture_prepare "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_unknown" true true "$rh_capture_tmp"
      jq -e 'map(.id) == ["claude:fresh@m"]' <<<"$fleet_capture_items" >/dev/null ||
        fail "an unverified Codex observation blocked the Claude add through an optional mirror"
    done
    fleet_capture_prepare "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_changed" true true "$rh_capture_tmp"
    [ "$fleet_capture_items" = '[]' ] &&
      jq -e '[.items[].id] == ["claude:fresh@m","codex:fresh@m"]' \
        "$rh_capture_dir/agent-pending-confirm.json" >/dev/null ||
      fail "Codex mirror bypassed the cap or confirmation payload"
    fleet_capture_json_write "$rh_capture_dir/agent-pending-confirm.json" \
      "$(jq -c '.confirmed=true' "$rh_capture_dir/agent-pending-confirm.json")"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_changed" true true "$rh_capture_tmp"
    jq -e 'map(.id) == ["claude:fresh@m","codex:fresh@m"]' <<<"$fleet_capture_items" >/dev/null ||
      fail "confirmation did not release the exact original change and mirror"
    rm "$rh_capture_dir/agent-pending-confirm.json"
    fleet_capture_json_write "$rh_capture_dir/agent-take-local.json" '{"claude:pinned@m":true}'
    rh_safety_changed=$(jq -c '.claude["pinned@m"]={value:"enabled",marketplace:"m",stageable:true}' <<<"$rh_safety_ours")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_changed" true true "$rh_capture_tmp"
    jq -e 'length == 1 and .[0].id == "claude:pinned@m" and .[0].path == "hosts/mac.yaml"' \
      <<<"$fleet_capture_items" >/dev/null &&
      [ ! -e "$rh_capture_dir/agent-pending-confirm.json" ] ||
      fail "a host-pin take-local mirrored to the shared Codex layer"

    fleet_agent_pending_mark claude old-extra@m
    fleet_agent_pending_mark codex sibling@m
    rh_safety_unknown=$(jq -c '.claude = null | .codex = null' <<<"$rh_safety_ours")
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_unknown" true
    [ -f "$(fleet_agent_pending_path claude:old-extra@m)" ] &&
      [ -f "$(fleet_agent_pending_path codex:sibling@m)" ] ||
      fail "an unavailable observation cleared unmanaged pending markers"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_ours" true
    [ ! -e "$(fleet_agent_pending_path claude:old-extra@m)" ] &&
      [ ! -e "$(fleet_agent_pending_path codex:sibling@m)" ] ||
      fail "agreed ignored and untracked collateral markers did not clear"
    fleet_agent_pending_mark claude old-extra@m
    rh_safety_removed=$(jq -c 'del(.claude["old-extra@m"])' <<<"$rh_safety_ours")
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_safety_fold" "$rh_safety_removed" true
    jq -e 'has("claude:old-extra@m") | not' "$rh_capture_dir/agent-baseline.json" >/dev/null &&
      [ ! -e "$(fleet_agent_pending_path claude:old-extra@m)" ] ||
      fail "authoritative absence forgot an ignored extra but left its marker"
    rh_safety_reinstalled=$(jq -c '.codex["sibling@m"]={value:"enabled",marketplace:"m",stageable:true}' <<<"$rh_safety_ours")
    fleet_capture_prepare "$rh_capture_store" mac "$(jq -c '.policy.max_changes_per_run=2' <<<"$rh_safety_no_mirror")" \
      "$rh_safety_reinstalled" true true "$rh_capture_tmp"
    jq -e 'map(.id) == ["claude:old-extra@m","codex:sibling@m"]' <<<"$fleet_capture_items" >/dev/null ||
      fail "stale unmanaged markers suppressed subsequent owner installs"

    rh_pin_store="$rh_capture_root/pin-aliases"
    mkdir -p "$rh_pin_store/hosts"
    cat >"$rh_pin_store/fleet.yaml" <<'YAML'
plugins:
  explicit: {state: enabled, marketplace: m}
  inverse@m: enabled
  via-definition: enabled
  ambiguous: enabled
  distinct@m2: enabled
YAML
    cat >"$rh_pin_store/hosts/pinned.yaml" <<'YAML'
capture: false
default_agent_state: absent
plugins:
  explicit@m: enabled
  inverse: {state: disabled, marketplace: m}
  via-definition@m: enabled
  ambiguous@m: enabled
  distinct@m: enabled
YAML
    printf 'plugins:\n  via-definition: {marketplace: m}\n' >"$rh_pin_store/definitions.yaml"
    fleet_run_desired "$rh_pin_store" pinned | jq -e '.plugins == {
      "explicit@m":"enabled",inverse:{state:"disabled",marketplace:"m"},
      "via-definition@m":"enabled","ambiguous@m":"enabled","distinct@m":"enabled",
      "distinct@m2":{state:"absent"}}' >/dev/null ||
      fail "the capture-false host default produced a tombstone for a physical pin alias"

    (
      ROUNDHOUSE_FLEET_STORE="$rh_capture_root/currency/store"
      mkdir -p "$ROUNDHOUSE_FLEET_STORE"
      printf 'policy: {max_change_fraction: 1}\nplugins:\n  keeper: {marketplace: m, state: enabled}\n' \
        >"$ROUNDHOUSE_FLEET_STORE/fleet.yaml"
      rh_currency_fold=$(fleet_run_desired "$ROUNDHOUSE_FLEET_STORE" mac)
      fleet_capture_observed='{"claude":{"keeper@m":{"value":"enabled","marketplace":"m","stageable":true}},"codex":null}'
      fleet_capture_rebaseline "$ROUNDHOUSE_FLEET_STORE" mac "$rh_currency_fold" "$fleet_capture_observed" true
      fleet_run_installed_plugins() { printf '%s\n' '{"currency-extra@m":[{"scope":"user"}]}'; }
      fleet_run_plugin_identity_matches() { return 1; }
      bounded_verb() { : >"$rh_capture_tmp/currency-updated"; }
      plugin_cache_seal_permissions() { return 0; }
      : >"$rh_capture_tmp/currency-owned"
      fleet_capture_skip='{}'
      rh_currency_status=0
      fleet_plugins_claude_update_unowned '{}' m "$rh_capture_tmp/currency-owned" || rh_currency_status=$?
      [ "$rh_currency_status" -eq 74 ] && [ ! -e "$rh_capture_tmp/currency-updated" ] &&
        [ ! -e "$(fleet_agent_pending_path claude:currency-extra@m)" ] ||
        fail "unmanaged currency marked an owner install that was newer than the capture scan"
      rh_currency_seen=$(jq -c '.claude["currency-extra@m"]={value:"enabled",marketplace:"m",stageable:true}' \
        <<<"$fleet_capture_observed")
      fleet_capture_prepare "$ROUNDHOUSE_FLEET_STORE" mac "$rh_currency_fold" "$rh_currency_seen" true true "$rh_capture_tmp"
      jq -e 'map(.id) == ["claude:currency-extra@m"]' <<<"$fleet_capture_items" >/dev/null ||
        fail "the next scan did not capture the delayed unmanaged owner install"
    )
  )
fi
