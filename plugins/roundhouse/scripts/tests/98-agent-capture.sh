# roundhouse self-check — Claude observation, its agreed baseline, and merge.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'agent observation: merge, baseline, and inventory trust\n'
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
    export ROUNDHOUSE_FLEET_STORE CLAUDE_CONFIG_DIR
    mkdir -p "$rh_capture_store/fleet" "$rh_capture_store/hosts" "$rh_capture_tmp" \
      "$CLAUDE_CONFIG_DIR/plugins"
    rh_capture_dir=$(fleet_instance_path store.run)
    capture_receipt() {
      local id=$1 state=$2 record
      record=$(jq -cn --arg id "$id" --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
        --arg state "$state" '{id:$id,home:$home,receipt:{installed:($state != "absent"),
          state:(if $state == "absent" then null else $state end),seq:1,
          op:(if $state == "absent" then "uninstall" else "disable" end)}}')
      fleet_capture_json_write "$(fleet_agent_journal_path "$id")" "$record"
    }
    cat >"$rh_capture_store/fleet.yaml" <<'YAML'
plugins:
  keeper: {state: enabled, marketplace: m}
  retired: absent
  capped: {state: absent, marketplace: m}
  ambiguous: disabled
YAML
    rh_capture_fold=$(fleet_run_desired "$rh_capture_store" mac)
    # Despite its name, capped tests the first-pass hold: disabled locally, absent in the store, no baseline.
    # Removal-cap coverage with an established baseline lives in 93-jj-run.sh.
    rh_capture_ours='{"claude":{
      "keeper@m":{"value":"enabled","marketplace":"m"},
      "capped@m":{"value":"disabled","marketplace":"m"},
      "extra@m":{"value":"enabled","marketplace":"m"},
      "ambiguous@m":{"value":"enabled","marketplace":"m"},
      "ambiguous@m2":{"value":"disabled","marketplace":"m2"}
    }}'

    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" '{"claude":null}' true
    [ ! -e "$rh_capture_dir/agent-baseline.json" ] ||
      fail "an unavailable first scan initialized Claude"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true true "$rh_capture_tmp"
    jq -e 'keys == ["plugins.ambiguous", "plugins.capped"]' <<<"$fleet_capture_skip" >/dev/null ||
      fail "Claude's first usable observation did not hold the ambiguous item and disabled local install against absent"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true
    rh_capture_base=$(cat "$rh_capture_dir/agent-baseline.json")
    jq -e '._initialized.claude == true and .["claude:extra@m"] == {value:"enabled",ignored:true} and
      .["plugins.retired"] == {value:"absent"} and .["claude:capped@m"] == {value:"absent"} and
      .["claude:keeper@m"] == {value:"enabled"} and
      all(keys[]; startswith("claude:ambiguous@") | not)' <<<"$rh_capture_base" >/dev/null ||
      fail "first observation lost agreed values, extras, or wrote an ambiguous value"

    fleet_capture_fingerprint >"$rh_capture_dir/agent-fingerprint"
    if fleet_capture_dirty; then fail "agreed fingerprints kept polling open"; fi
    capture_receipt claude:keeper@m disabled
    fleet_capture_dirty || fail "a pending receipt let the fast pass skip re-observation"
    rh_journal=$(fleet_agent_journal_path claude:keeper@m)
    cp "$rh_journal" "$rh_capture_root/before-update.json"
    (
      fleet_run_installed_plugins() { printf '%s\n' '{"keeper@m":[{"scope":"user"}]}'; }
      fleet_run_plugin_enabled() { printf 'false\n'; }
      [ "$(fleet_capture_verb claude:keeper@m update unchanged -- printf 'updated\n')" = updated ] &&
        cmp "$rh_journal" "$rh_capture_root/before-update.json"
    ) ||
      fail "a version update did not run or replaced a state receipt"
    rh_capture_changed=$(jq -c '.claude["keeper@m"].value = "disabled"' <<<"$rh_capture_ours")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_changed" true true "$rh_capture_tmp"
    # Keeper's verified state stays eligible; the local install against absent stays held.
    jq -e 'has("plugins.keeper") | not' <<<"$fleet_capture_skip" >/dev/null ||
      fail "a verified plugin change stopped ordinary convergence"
    jq -e 'has("plugins.capped")' <<<"$fleet_capture_skip" >/dev/null ||
      fail "the disabled local install lost its first-pass hold against the absent baseline"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_changed" true
    [ -f "$rh_journal" ] || fail "cleared the receipt before agreement"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true
    [ ! -e "$rh_journal" ] || fail "agreed receipt did not clear"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_changed" true true "$rh_capture_tmp"
    jq -e 'has("plugins.keeper")' <<<"$fleet_capture_skip" >/dev/null ||
      fail "the same difference without a receipt would be reverted"

    rh_capture_legacy=$(jq -c '.plugins.legacy = "absent"' <<<"$rh_capture_fold")
    capture_receipt claude:legacy@m absent
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_legacy" "$rh_capture_ours" true
    jq -e '.["claude:legacy@m"].value == "absent"' "$rh_capture_dir/agent-baseline.json" >/dev/null &&
      [ ! -e "$(fleet_agent_journal_path claude:legacy@m)" ] ||
      fail "an unqualified tombstone lost the identity recorded by its receipt"
    capture_receipt claude:retired@m absent
    rh_journal=$(fleet_agent_journal_path claude:retired@m)
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" '{"claude":null}' true
    [ -f "$rh_journal" ] || fail "an unknown observation cleared the unqualified tombstone's receipt"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true
    [ ! -e "$rh_journal" ] || fail "the agreed unqualified tombstone left its receipt pending"

    # Capture and apply must resolve an empty override through definitions.
    (
      fleet_definitions_load() { printf '%s\n' '{"plugins":{"keeper":{"marketplace":"m"}}}'; }
      rh_empty_market=$(jq -c '.plugins.keeper = {state:"enabled",marketplace:""}' <<<"$rh_capture_fold")
      fleet_capture_prepare "$rh_capture_store" mac "$rh_empty_market" "$rh_capture_changed" true true "$rh_capture_tmp"
      jq -e 'has("plugins.keeper")' <<<"$fleet_capture_skip" >/dev/null ||
        fail "empty marketplace override hid an owner change to the defined plugin"
    )

    rh_aliases=$(jq -c '.claude["keeper@other"] = {value:"enabled",marketplace:"other"}' <<<"$rh_capture_ours")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_aliases" true true "$rh_capture_tmp"
    fleet_capture_skip_id claude keeper@other ||
      fail "a declared marketplace hid a same-name owner install from another marketplace"
    if fleet_capture_skip_id claude keeper@m; then
      fail "holding the owner install blocked convergence of the declared identity"
    fi

    rh_unmanaged_aliases=$(jq -c '.claude["extra@a"] = {value:"enabled",marketplace:"a"}' <<<"$rh_capture_ours")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_unmanaged_aliases" \
      true true "$rh_capture_tmp"
    fleet_capture_skip_id claude extra@a ||
      fail "a same-name unmanaged sibling hid the owner install"
    if fleet_capture_skip_id claude extra@m; then
      fail "an unchanged unmanaged identity was held because its sibling was installed"
    fi

    # A healthy user row is enough to identify a damaged installation.
    rh_registry="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"user","installPath":"/missing-fixture"}]}}' >"$rh_registry"
    printf '%s\n' '{"enabledPlugins":{"keeper@m":true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
    cat >"$rh_capture_root/inventory.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":1}}
{"kind":"plugin","status":"present","data":{"agent":"claude","inventory_source":"manager","manager_id":"keeper@m","name":"keeper","marketplace":"m","scope":"user","enabled":true,"installed_version":"100"}}
JSONL
    fleet_capture_observe "$rh_capture_root/inventory.jsonl" |
      jq -e '.claude["keeper@m"].value == "enabled"' >/dev/null ||
      fail "authoritative CLI and registry did not describe a damaged install as installed"
    for rh_settings in false null; do
      printf '{"enabledPlugins":%s}\n' "$rh_settings" >"$CLAUDE_CONFIG_DIR/settings.json"
      fleet_capture_observe "$rh_capture_root/inventory.jsonl" | jq -e '.claude == null' >/dev/null ||
        fail "invalid enabledPlugins state was read as authoritative"
    done

    # Unreadable and partial records must never manufacture a user removal.
    mv "$rh_registry" "$rh_capture_root/original.json"
    printf '{broken\n' >"$rh_registry"
    fleet_capture_observe "$rh_capture_root/inventory.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "unparseable registry read as authoritative"
    mv "$rh_capture_root/original.json" "$rh_registry"
    head -1 "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/partial.jsonl"
    fleet_capture_observe "$rh_capture_root/partial.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "partial CLI listing read as authoritative"
    sed 's/"status":"present"/"status":"unavailable"/' "$rh_capture_root/partial.jsonl" >"$rh_capture_root/failed.jsonl"
    fleet_capture_observe "$rh_capture_root/failed.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "failed CLI listing read as authoritative"
    printf '{}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
    jq -c 'if .kind == "plugin_manager" then .data.installed_count=2 else . end' \
      "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/scope.jsonl"
    jq -c 'select(.kind == "plugin") |
      .data |= (.manager_id="uncertain@m" | .name="uncertain" | .scope="unrecognized")' \
      "$rh_capture_root/inventory.jsonl" >>"$rh_capture_root/scope.jsonl"
    rh_observed=$(fleet_capture_observe "$rh_capture_root/scope.jsonl")
    rh_scope_fold=$(jq -c '.plugins += {
      uncertain:{state:"enabled",marketplace:"m"}, untouched:{state:"enabled",marketplace:"m"}
    }' <<<"$rh_capture_fold")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_scope_fold" "$rh_observed" true true "$rh_capture_tmp"
    jq -e 'keys == ["plugins.uncertain"]' <<<"$fleet_capture_skip" >/dev/null ||
      fail "one unknown scope did not hold only its own plugin"
    rh_changed_fold=$(jq -c '.plugins.keeper.state = "disabled"' <<<"$rh_scope_fold")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_changed_fold" '{"claude":null,"retry":true}' \
      true true "$rh_capture_tmp"
    jq -e 'keys == ["plugins.ambiguous", "plugins.capped", "plugins.keeper", "plugins.retired", "plugins.uncertain", "plugins.untouched"]' \
      <<<"$fleet_capture_skip" >/dev/null ||
      fail "an unavailable listing did not hold unchanged store values and the changed keeper without agreed pre-pass evidence"

    sed 's/"scope":"user"/"scope":"project"/' "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/project.jsonl"
    fleet_capture_observe "$rh_capture_root/project.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "a project-only CLI listing overruled the registry's user install"
    printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"project"}]}}' >"$rh_registry"
    rh_observed=$(fleet_capture_observe "$rh_capture_root/project.jsonl")
    fleet_capture_rows "$rh_capture_store" "$rh_capture_fold" "$rh_observed" "$rh_capture_base" |
      jq -e 'any(.[]; .item == "plugins.keeper" and .ours == "absent")' >/dev/null ||
      fail "matching project-only records did not count as absent in user scope"

    printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"user"}],"keeper@other":[{"scope":"project"}]}}' \
      >"$rh_registry"
    jq -c 'if .kind == "plugin_manager" then .data.installed_count=2 else . end' \
      "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/mixed.jsonl"
    jq -c 'select(.kind == "plugin") | .data |= (.manager_id="keeper@other" | .marketplace="other")' \
      "$rh_capture_root/project.jsonl" >>"$rh_capture_root/mixed.jsonl"
    rh_observed=$(fleet_capture_observe "$rh_capture_root/mixed.jsonl")
    rh_unqualified=$(jq -c '.plugins.keeper = "enabled"' <<<"$rh_capture_fold")
    fleet_capture_rows "$rh_capture_store" "$rh_unqualified" "$rh_observed" "$rh_capture_base" |
      jq -e 'any(.[]; .item == "plugins.keeper" and .id == "claude:keeper@m" and
        .ours == "enabled" and .ambiguous == false)' >/dev/null ||
      fail "a project-only alias made a user-scope installation ambiguous"
    fleet_capture_state_matches plugins.keeper '"enabled"' "$rh_observed" '{}' ||
      fail "a project-only alias prevented user-scope state matching"

    printf '%s\n' '{"plugins":{}}' >"$rh_registry"
    sed -n '1s/"installed_count":1/"installed_count":0/p' "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/empty.jsonl"
    rh_observed=$(fleet_capture_observe "$rh_capture_root/empty.jsonl")
    jq -e '.claude == {}' <<<"$rh_observed" >/dev/null ||
      fail "matching empty inventories did not yield an empty observation"
    fleet_capture_rows "$rh_capture_store" "$rh_capture_fold" "$rh_observed" "$rh_capture_base" |
      jq -e 'any(.[]; .item == "plugins.keeper" and .ours == "unobserved")' >/dev/null ||
      fail "a wiped inventory was read as a known local removal"

    (
      # #133: a partial set of removal receipts cannot explain an empty inventory.
      ROUNDHOUSE_FLEET_STORE="$rh_capture_root/empty-controls/store"
      mkdir -p "$ROUNDHOUSE_FLEET_STORE/fleet" "$ROUNDHOUSE_FLEET_STORE/hosts"
      rh_empty_dir=$(fleet_instance_path store.run)
      rh_empty_base='{"_initialized":{"claude":true},"claude:keeper@m":{"value":"enabled"},"claude:extra@m":{"value":"disabled"}}'
      rh_empty_fold='{"plugins":{"keeper":{"state":"absent","marketplace":"m"},"extra":{"state":"disabled","marketplace":"m"}}}'
      fleet_capture_json_write "$rh_empty_dir/agent-baseline.json" "$rh_empty_base"
      cp "$rh_empty_dir/agent-baseline.json" "$rh_capture_root/empty-baseline.json"
      for rh_empty_case in unexplained some-receipts; do
        if [ "$rh_empty_case" = some-receipts ]; then
          capture_receipt claude:keeper@m absent
          capture_receipt claude:extra@m disabled
        fi
        rh_empty_observed=$(fleet_capture_observe "$rh_capture_root/empty.jsonl")
        jq -e '.claude == {}' <<<"$rh_empty_observed" >/dev/null ||
          fail "$rh_empty_case empty inventory did not produce an empty observation"
        fleet_capture_rows "$ROUNDHOUSE_FLEET_STORE" "$rh_empty_fold" "$rh_empty_observed" "$rh_empty_base" |
          jq -e 'length == 2 and all(.[]; .ours == "unobserved")' >/dev/null ||
          fail "$rh_empty_case empty inventory manufactured a known absence"
        fleet_capture_prepare "$ROUNDHOUSE_FLEET_STORE" mac "$rh_empty_fold" "$rh_empty_observed" \
          true true "$rh_capture_tmp" >"$rh_capture_root/empty-prepare.log"
        [ "$fleet_capture_authoritative" = false ] && [ "$fleet_capture_skip" = '{}' ] ||
          fail "$rh_empty_case empty inventory became authoritative or held a plugin"
        if grep -Eq ' (added|removed|enabled|disabled) locally' "$rh_capture_root/empty-prepare.log"; then
          fail "$rh_empty_case empty inventory reported a local change"
        fi
        fleet_capture_rebaseline "$ROUNDHOUSE_FLEET_STORE" mac "$rh_empty_fold" "$rh_empty_observed" true
        cmp "$rh_empty_dir/agent-baseline.json" "$rh_capture_root/empty-baseline.json" >/dev/null ||
          fail "$rh_empty_case empty inventory changed agreement"
      done
      for rh_empty_id in keeper@m extra@m; do
        jq -e --arg id "$rh_empty_id" '.id == ("claude:" + $id) and
          (if $id == "keeper@m" then .receipt.installed == false and .receipt.state == null
          else .receipt.installed == true and .receipt.state == "disabled" end)' \
          "$(fleet_agent_journal_path "claude:$rh_empty_id")" >/dev/null ||
          fail "partly explained empty inventory lost $rh_empty_id's receipt"
        capture_receipt "claude:$rh_empty_id" absent
      done
      # Even a complete set of removal receipts cannot authorize a bad listing.
      for rh_bad_listing in partial failed; do
        rh_empty_observed=$(fleet_capture_observe "$rh_capture_root/$rh_bad_listing.jsonl")
        jq -e '.claude == null and .retry == true' \
          <<<"$rh_empty_observed" >/dev/null || fail "removal receipts authorized a $rh_bad_listing listing"
        fleet_capture_rows "$ROUNDHOUSE_FLEET_STORE" "$rh_empty_fold" "$rh_empty_observed" "$rh_empty_base" |
          jq -e 'length == 2 and all(.[]; .ours == "unobserved")' >/dev/null ||
          fail "$rh_bad_listing listing manufactured absence despite unknown inventory"
        fleet_capture_rebaseline "$ROUNDHOUSE_FLEET_STORE" mac "$rh_empty_fold" "$rh_empty_observed" true
        cmp "$rh_empty_dir/agent-baseline.json" "$rh_capture_root/empty-baseline.json" >/dev/null ||
          fail "$rh_bad_listing listing advanced agreement with removal receipts"
        for rh_empty_id in keeper@m extra@m; do
          jq -e '.receipt.installed == false and .receipt.state == null' \
            "$(fleet_agent_journal_path "claude:$rh_empty_id")" >/dev/null ||
            fail "$rh_bad_listing listing lost $rh_empty_id's removal receipt"
        done
      done
    )

    jq -c 'select(.data.manager_id != "keeper@m") |
      if .kind == "plugin_manager" then .data.installed_count=1 else . end' \
      "$rh_capture_root/scope.jsonl" >"$rh_capture_root/scope-only.jsonl"
    rh_observed=$(fleet_capture_observe "$rh_capture_root/scope-only.jsonl")
    fleet_capture_rows "$rh_capture_store" "$rh_scope_fold" "$rh_observed" "$rh_capture_base" |
      jq -e 'length > 0 and all(.[]; .ours == "unobserved")' >/dev/null ||
      fail "an unknown scope row made a wiped user inventory authoritative"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_scope_fold" "$rh_observed" true true "$rh_capture_tmp"
    jq -e 'length == 0' <<<"$fleet_capture_skip" >/dev/null ||
      fail "an unknown scope row held items on a wiped user inventory"

    # Plain publication can recover a remote move after this pass observed its tree.
    (
      fleet_vcs_heads_local() { printf 'published\n'; }
      fleet_vcs_desired_digest() {
        if [ "$2" = observed ]; then printf 'old-tree\n'; else printf 'new-tree\n'; fi
      }
      capture_receipt claude:keeper@m disabled
      cp "$rh_capture_dir/agent-baseline.json" "$rh_capture_root/before-recovery.json"
      fleet_capture_pass_agree "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_store" observed
      cmp "$rh_capture_dir/agent-baseline.json" "$rh_capture_root/before-recovery.json" >/dev/null ||
        fail "publish recovery advanced agreement against the wrong desired tree"
      [ -e "$(fleet_agent_journal_path claude:keeper@m)" ] && [ -e "$rh_capture_dir/retry-owed" ] ||
        fail "publish recovery cleared a receipt or failed to request a fresh pass"
    )

    (
      # Explicit settings false must not mask an owner enable in the live CLI.
      printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"user"}]}}' >"$rh_registry"
      printf '%s\n' '{"enabledPlugins":{"keeper@m":false}}' >"$CLAUDE_CONFIG_DIR/settings.json"
      fleet_capture_before_records=$(fleet_capture_guard_records)
      fleet_capture_before_observed='{"claude":{"keeper@m":{"value":"disabled","marketplace":"m"}}}'
      fleet_capture_race_holds='[]'
      rh_manager_state=false
      fleet_run_plugin_enabled() { printf '%s\n' "$rh_manager_state"; }
      fleet_capture_guard_destructive keeper@m >"$rh_capture_root/guard.log" ||
        fail "unchanged disabled manager and settings did not pass the destructive guard"
      [ ! -s "$rh_capture_root/guard.log" ] || fail "unchanged state printed a deferral"
      rh_manager_state=true
      rh_status=0
      fleet_capture_guard_destructive keeper@m >"$rh_capture_root/guard.log" || rh_status=$?
      [ "$rh_status" -ne 0 ] || fail "settings false masked an owner enable in the live CLI"
      assert_contains "$(cat "$rh_capture_root/guard.log")" 'defer keeper@m'
    )

    (
      fleet_capture_collect() { return 1; }
      fleet_run_plugin_enabled() { printf 'false\n'; }
      bounded_verb() { : >"$rh_capture_root/uninstall-attempt"; }
      rh_removal='{"state":"absent","marketplace":"m"}'
      printf '{unreadable\n' >"$rh_registry"
      fleet_capture_pass_prepare "$rh_capture_store" mac '{"plugins":{"keeper":"absent"}}' \
        true true "$rh_capture_tmp" "$rh_capture_store"
      printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"user"}]}}' >"$rh_registry"
      rh_status=0
      fleet_run_uninstall_plugin '{}' plugins.keeper keeper "$rh_removal" || rh_status=$?
      [ "$rh_status" = 74 ] && [ ! -e "$rh_capture_root/uninstall-attempt" ] ||
        fail "a later readable registry authorized removal without a pre-pass observation"
    )
  )
fi
