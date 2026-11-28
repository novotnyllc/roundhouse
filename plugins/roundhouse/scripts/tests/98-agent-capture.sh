# roundhouse self-check — Claude observation, its agreed baseline, and merge.
# roundhouse-test: parts=14
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'agent observation: merge, baseline, and inventory trust\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    rh_tombstone='{"state":"absent","marketplace":"m"}'
    rh_tombstone_fold='{"plugins":{"keeper":{"state":"absent","marketplace":"m"}}}'
    rh_installed='{"plugins":{"keeper@m":[{"scope":"user","version":"1"}]}}'
    rh_installed_base='{"_initialized":{"claude":true},"claude:keeper@m":{"value":"enabled"}}'
    capture_fixture() {
      rh_capture_root="$tmp/agent-capture/$1"
      rh_capture_store="$rh_capture_root/store"
      rh_capture_tmp="$rh_capture_root/pass"
      ROUNDHOUSE_FLEET_STORE=$rh_capture_store
      CLAUDE_CONFIG_DIR="$rh_capture_root/claude"
      export ROUNDHOUSE_FLEET_STORE CLAUDE_CONFIG_DIR
      mkdir -p "$rh_capture_store/fleet" "$rh_capture_store/hosts" "$rh_capture_tmp" \
        "$CLAUDE_CONFIG_DIR/plugins"
      rh_capture_dir=$(fleet_instance_path store.run)
      rh_registry="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
      rh_settings_path="$CLAUDE_CONFIG_DIR/settings.json"
      printf '%s\n' '{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":0}}' \
        >"$rh_capture_root/empty.jsonl"
    }
    capture_snapshot() {
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_SEED_SNAPSHOT=$1 fleet_capture_collect "$rh_capture_tmp/scan"
    }

    if section_part 1; then
    (
      capture_fixture wiped
      printf '%s\n' '{"plugins":{}}' >"$rh_registry"
      printf '%s\n' '{}' >"$rh_settings_path"
      fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" "$rh_installed_base"
      printf '%s\n' 'plugins: {keeper: {state: enabled, marketplace: m}}' >"$rh_capture_store/fleet.yaml"
      rh_observed=$(capture_snapshot "$rh_capture_root/empty.jsonl")
      rh_desired=$(fleet_run_desired "$rh_capture_store" mac)
      fleet_capture_rebaseline "$rh_capture_store" mac "$rh_desired" "$rh_observed" true
      jq -e '.claude == {} and .trusted == false' <<<"$rh_observed" >/dev/null &&
        jq -e --argjson expected "$rh_installed_base" '. == $expected' \
          "$rh_capture_dir/agent-baseline.json" >/dev/null ||
        fail "a wiped Claude home did not yield an untrusted observation with agreement unchanged"
      fleet_capture_rows "$rh_capture_store" "$rh_desired" "$rh_observed" "$rh_installed_base" |
        jq -e 'any(.[]; .item == "plugins.keeper" and .ours == "unobserved")' >/dev/null ||
        fail "a wiped inventory was read as a known local removal"
    )
    fi

    if section_part 2; then
    (
      capture_fixture transient-empty
      printf '%s\n' "$rh_installed" >"$rh_registry"
      printf '%s\n' '{"enabledPlugins":{"keeper@m":true}}' >"$rh_settings_path"
      fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" "$rh_installed_base"
      fleet_run_claude_running() { return 1; }
      fleet_run_plugin_enabled() { printf '%s\n' "$rh_manager_state"; }
      bounded_verb() { printf '%s\n' "$3" >>"$rh_capture_root/actions"; return 1; }
      rh_manager_state=true
      fleet_capture_before_records=$(fleet_capture_guard_records)
      fleet_capture_before_observed='{"trusted":true,"claude":{"keeper@m":{"value":"enabled"}}}'
      rh_status=0
      fleet_run_uninstall_plugin '{}' plugins.keeper keeper "$rh_tombstone" || rh_status=$?
      [ "$rh_status" = 75 ] && [ "$(cat "$rh_capture_root/actions")" = uninstall ] ||
        fail "B1 fixture did not reach the failing native uninstall"
      [ ! -e "$rh_capture_dir/agent-journal/claude.keeper@m" ] ||
        fail "B1 fixture's failed native uninstall left a journal record"
      : >"$rh_capture_root/actions"

      rh_manager_state=false
      printf '%s\n' '{"enabledPlugins":{"keeper@m":false}}' >"$rh_settings_path"
      if fleet_capture_guard_destructive keeper@m; then fail "B1 fixture did not detect the owner disable"; fi
      jq -e '.["claude:keeper@m"].raced == true' "$rh_capture_dir/agent-baseline.json" >/dev/null ||
        fail "B1 fixture did not persist the race"

      # Present a coherent empty view during the scan, restoring real records
      # before the collector takes the second independent guard read.
      eval "$(declare -f fleet_capture_claude_observe | sed '1s/fleet_capture_claude_observe/capture_real_claude_observe/')"
      fleet_capture_claude_observe() {
        local result
        mv "$rh_registry" "$rh_capture_root/race-registry"
        mv "$rh_settings_path" "$rh_capture_root/race-settings"
        printf '%s\n' '{"plugins":{}}' >"$rh_registry"
        printf '%s\n' '{}' >"$rh_settings_path"
        result=$(capture_real_claude_observe "$@") || return 1
        mv "$rh_capture_root/race-registry" "$rh_registry"
        mv "$rh_capture_root/race-settings" "$rh_settings_path"
        printf '%s\n' "$result"
      }
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_SEED_SNAPSHOT="$rh_capture_root/empty.jsonl" \
        fleet_capture_pass_prepare "$rh_capture_store" mac "$rh_tombstone_fold" true true \
          "$rh_capture_tmp" "$rh_capture_store"
      fleet_run_uninstall_plugin '{}' plugins.keeper keeper "$rh_tombstone" || :
      jq -e '.claude == {} and .trusted == false' <<<"$fleet_capture_observed" >/dev/null &&
        fleet_capture_race_held keeper@m && [ ! -s "$rh_capture_root/actions" ] ||
        fail "B1 transient empty inventory lost the recorded owner race or reached native uninstall"
    )
    fi

    if section_part 3; then
    (
      capture_fixture timeout
      printf '%s\n' "$rh_installed" >"$rh_registry"
      fleet_capture_before_records=$(fleet_capture_guard_records)
      fleet_capture_before_observed='{"trusted":true,"claude":{"keeper@m":{"value":"enabled"}}}'
      fleet_run_plugin_enabled() { return 124; }
      if fleet_capture_guard_destructive keeper@m || [ -e "$rh_capture_dir/agent-baseline.json" ]; then
        fail "a timed-out Claude guard must defer without recording a race"
      fi
    )
    fi

    if section_part 5; then
    (
      capture_fixture first-disagreement
      rh_desired='{"plugins":{"keeper":{"state":"enabled","marketplace":"m"}}}'
      fleet_capture_before_observed='{"trusted":true,"claude":{
        "keeper@m":{"value":"disabled","user_scope":true},
        "anchor@m":{"value":"enabled","user_scope":true}}}'
      fleet_capture_prepare "$rh_capture_store" mac "$rh_desired" "$fleet_capture_before_observed" \
        true true "$rh_capture_tmp"
      rh_after=$(jq -c 'del(.claude["keeper@m"])' <<<"$fleet_capture_before_observed")
      fleet_capture_rebaseline "$rh_capture_store" mac "$rh_desired" "$rh_after" true
      jq -e '.["claude:keeper@m"].value == "enabled"' "$rh_capture_dir/agent-baseline.json" >/dev/null ||
        fail "post-pass absence erased an installed first-pass disagreement"
    )
    fi

    if section_part 6; then
    (
      capture_fixture unmanaged-race
      rh_raced=$(jq -c '.["claude:keeper@m"].raced = true' <<<"$rh_installed_base")
      fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" "$rh_raced"
      rh_observed='{"trusted":true,"claude":{"keeper@m":{"value":"disabled","user_scope":true}}}'
      fleet_capture_prepare "$rh_capture_store" mac '{}' "$rh_observed" true true "$rh_capture_tmp"
      fleet_capture_rebaseline "$rh_capture_store" mac '{}' "$rh_observed" true
      jq -e '.["claude:keeper@m"] | .raced == true and .value == "enabled"' \
        "$rh_capture_dir/agent-baseline.json" >/dev/null ||
        fail "trusted inventory erased a race without store agreement or discard"
    )
    fi

    if section_part 7; then
    (
      capture_fixture untrusted-tombstone
      printf '%s\n' '{"plugins":{}}' >"$rh_registry"
      fleet_capture_before_records=$(fleet_capture_guard_records)
      fleet_capture_observed='{"claude":{},"trusted":false,"inapplicable":false,"retry":true}'
      fleet_capture_before_observed=$fleet_capture_observed
      rh_status=0
      fleet_run_uninstall_plugin '{}' plugins.keeper keeper "$rh_tombstone" || rh_status=$?
      [ "$rh_status" = 74 ] || fail "an untrusted empty inventory settled an applicable tombstone"
    )
    fi

    if section_part 8; then
    (
      capture_fixture malformed-settings
      printf '%s\n' "$rh_installed" >"$rh_registry"
      printf '%s\n' '{"enabledPlugins":{"keeper@m":true}}' >"$rh_settings_path"
      fleet_capture_before_records=$(fleet_capture_guard_records)
      fleet_capture_before_observed='{"trusted":true,"claude":{"keeper@m":{"value":"enabled"}}}'
      printf '%s\n' '{"enabledPlugins":{"keeper@m":"unreadable"}}' >"$rh_settings_path"
      fleet_run_plugin_enabled() { printf 'true\n'; }
      if fleet_capture_guard_destructive keeper@m || [ -e "$rh_capture_dir/agent-baseline.json" ]; then
        fail "malformed Claude settings must defer without recording a race"
      fi
    )
    fi

    if section_part 9; then
    (
      capture_fixture native-target
      printf '%s\n' "$rh_installed" >"$rh_registry"
      printf '%s\n' '{}' >"$rh_settings_path"
      cat >"$rh_capture_root/native.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":1}}
{"kind":"plugin","status":"present","data":{"agent":"claude","inventory_source":"manager","manager_id":"keeper@m","name":"keeper","marketplace":"m","scope":"user","enabled":true}}
JSONL
      collect_command() {
        local target= native=false dest=
        while [ "$#" -gt 0 ]; do
          case $1 in
            --target) target=$2; shift ;;
            --native-target) native=true ;;
            --section) [ "$2" = agents ] || return 64; shift ;;
            --output) dest=$2; shift ;;
            *) return 64 ;;
          esac
          shift
        done
        [ "$target" = fixture-native ] && [ "$native" = true ] && [ -n "$dest" ] || return 64
        cp "$rh_capture_root/native.jsonl" "$dest"
      }
      unset ROUNDHOUSE_SEED_SNAPSHOT
      fleet_capture_target=fixture-native fleet_capture_native_target=true \
        fleet_capture_collect "$rh_capture_tmp/native" |
        jq -e '.trusted and .claude["keeper@m"].value == "enabled"' >/dev/null ||
        fail "a native Claude operation did not collect trusted inventory for its target"
    )
    fi

    if section_part 10; then
    (
      capture_fixture first-disagreement-retry
      rh_desired='{"plugins":{"keeper":{"state":"enabled","marketplace":"m"}}}'
      rh_before='{"trusted":true,"claude":{
        "keeper@m":{"value":"disabled","user_scope":true},
        "anchor@m":{"value":"enabled","user_scope":true}}}'
      (
        fleet_capture_prepare "$rh_capture_store" mac "$rh_desired" "$rh_before" true true "$rh_capture_tmp"
        fleet_capture_rebaseline "$rh_capture_store" mac "$rh_desired" '{"trusted":false,"claude":null}' true
      )
      rh_after=$(jq -c 'del(.claude["keeper@m"])' <<<"$rh_before")
      fleet_capture_prepare "$rh_capture_store" mac "$rh_desired" "$rh_after" true true "$rh_capture_tmp"
      fleet_capture_skip_id claude keeper@m ||
        fail "an unavailable post-scan and restart lost the first-pass hold on an owner removal"
    )
    fi

    if section_part 11; then
    (
      capture_fixture standalone-race
      printf '%s\n' "$rh_installed" >"$rh_registry"
      printf '%s\n' '{"enabledPlugins":{"keeper@m":false}}' >"$rh_settings_path"
      fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" \
        '{"_initialized":{"claude":true},"claude:keeper@m":{"value":"enabled","raced":true}}'
      fleet_capture_observed='{"trusted":true,"claude":{"keeper@m":{"value":"disabled"}}}'
      unset fleet_capture_before_records fleet_capture_race_holds
      fleet_run_plugin_enabled() { printf 'false\n'; }
      bounded_verb() { : >"$rh_capture_root/actions"; return 1; }
      for rh_discard in '{}' '{"plugins.keeper":true}'; do
        fleet_capture_json_write "$rh_capture_dir/agent-discard.json" "$rh_discard"
        rm -f "$rh_capture_root/actions"
        rh_status=0
        fleet_run_uninstall_plugin '{}' plugins.keeper keeper "$rh_tombstone" || rh_status=$?
        [ "$rh_status" = 74 ] && [ ! -e "$rh_capture_root/actions" ] ||
          fail "a standalone Claude verb ignored a remembered owner race"
      done
    )
    fi

    if section_part 12; then
    (
      capture_fixture empty-agreement
      printf '%s\n' '{"plugins":{}}' >"$rh_registry"
      printf '%s\n' '{}' >"$rh_settings_path"
      fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" \
        '{"_initialized":{"claude":true},"claude:keeper@m":{"value":"enabled"},"claude:extra@m":{"value":"disabled"}}'
      for rh_state in wanted absent; do
        if [ "$rh_state" = wanted ]; then
          rh_desired='{"plugins":{"keeper":{"state":"enabled","marketplace":"m"},"extra":{"state":"disabled","marketplace":"m"}}}'
        else
          rh_desired='{"plugins":{"keeper":{"state":"absent","marketplace":"m"},"extra":{"state":"absent","marketplace":"m"}}}'
        fi
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_SEED_SNAPSHOT="$rh_capture_root/empty.jsonl" \
          fleet_capture_pass_prepare "$rh_capture_store" mac "$rh_desired" true true "$rh_capture_tmp" "$rh_capture_store"
        if [ "$rh_state" = wanted ]; then
          [ "$fleet_capture_authoritative" = false ] || fail "#136 owner-empty inventory was trusted while the store still wanted every plugin"
        else
          [ "$fleet_capture_authoritative" = true ] && [ ! -s "$rh_capture_tmp/capture-skip" ] ||
            fail "#136 an empty inventory stayed untrusted or held after the store agreed all plugins were absent"
          fleet_capture_rebaseline "$rh_capture_store" mac "$rh_desired" "$fleet_capture_observed" true
          jq -e 'all(.["claude:keeper@m"], .["claude:extra@m"]; .value == "absent" and .seq > 0)' \
            "$rh_capture_dir/agent-baseline.json" >/dev/null ||
            fail "#136 store agreement did not advance both plugins to absent"
        fi
      done
    )
    fi

    for rh_empty_part in 13 14; do
      section_part "$rh_empty_part" || continue
      (
        capture_fixture "empty-journal-$rh_empty_part"
        printf '%s\n' '{"plugins":{}}' >"$rh_registry"
        printf '%s\n' '{}' >"$rh_settings_path"
        fleet_capture_json_write "$rh_capture_dir/agent-baseline.json" \
          '{"_initialized":{"claude":true},"claude:keeper@m":{"value":"enabled","seq":1}}'
        rh_record=$(jq -cn --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" '{id:"claude:keeper@m",home:$home}')
        if [ "$rh_empty_part" = 13 ]; then
          rh_record=$(jq -c '.receipt = {installed:true,state:null,seq:2,op:"install"}' <<<"$rh_record")
          rh_empty_failure="an installed receipt with unknown enabled state made empty inventory trusted"
        else
          rh_record=$(jq -c '.intent = {op:"install",to:"installed",from:{installed:false,state:null},
            seq:3,op_id:"dead",pid:2147483647,start:"dead"}' <<<"$rh_record")
          fleet_capture_json_write "$rh_capture_dir/agent-discard.json" \
            '{"claude:keeper@m":{"id":"claude:keeper@m","observed":{"installed":false,"state":null},"seq":2}}'
          rh_empty_failure="a discard older than an interrupted operation made empty inventory trusted"
        fi
        fleet_capture_json_write "$rh_capture_dir/agent-journal/claude.keeper@m" "$rh_record"
        rh_desired='{"plugins":{"keeper":{"state":"enabled","marketplace":"m"}}}'
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_SEED_SNAPSHOT="$rh_capture_root/empty.jsonl" \
          fleet_capture_pass_prepare "$rh_capture_store" mac "$rh_desired" true true "$rh_capture_tmp" "$rh_capture_store"
        jq -e '.claude == {} and .trusted == false' <<<"$fleet_capture_observed" >/dev/null ||
          fail "$rh_empty_failure"
      )
    done

    if section_part 4; then
    capture_fixture baseline
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

    capture_receipt() {
      local id=$1 state=$2 record seq
      seq=$(fleet_capture_next_seq)
      record=$(jq -cn --arg id "$id" --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
        --arg state "$state" --argjson seq "$seq" '{id:$id,home:$home,receipt:{installed:($state != "absent"),
          state:(if $state == "absent" then null else $state end),seq:$seq,
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
    rh_capture_ours='{"trusted":true,"claude":{
      "keeper@m":{"value":"enabled","marketplace":"m"},
      "capped@m":{"value":"disabled","marketplace":"m"},
      "extra@m":{"value":"enabled","marketplace":"m"},
      "ambiguous@m":{"value":"enabled","marketplace":"m"},
      "ambiguous@m2":{"value":"disabled","marketplace":"m2"}
    }}'

    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" '{"trusted":false,"claude":null}' true
    [ ! -e "$rh_capture_dir/agent-baseline.json" ] ||
      fail "an unavailable first scan initialized Claude"
    fleet_capture_prepare "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true true "$rh_capture_tmp"
    jq -e 'keys == ["plugins.ambiguous", "plugins.capped"]' <<<"$fleet_capture_skip" >/dev/null ||
      fail "Claude's first usable observation did not hold the ambiguous item and disabled local install against absent"
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" "$rh_capture_ours" true
    rh_capture_base=$(cat "$rh_capture_dir/agent-baseline.json")
    jq -e '._initialized.claude == true and
      (.["claude:extra@m"] | .value == "enabled" and .ignored == true and .seq > 0) and
      .["plugins.retired"].value == "absent" and .["claude:capped@m"].value == "absent" and
      .["claude:keeper@m"].value == "enabled" and
      all(keys[]; startswith("claude:ambiguous@") | not)' <<<"$rh_capture_base" >/dev/null ||
      fail "first observation lost agreed values, extras, or wrote an ambiguous value"

    fleet_capture_fingerprint >"$rh_capture_dir/agent-fingerprint"
    if fleet_capture_dirty; then fail "agreed fingerprints kept polling open"; fi
    capture_receipt claude:keeper@m disabled
    fleet_capture_dirty || fail "a pending receipt let the fast pass skip re-observation"
    rh_journal=$(fleet_agent_journal_path claude:keeper@m)
    cp "$rh_journal" "$rh_capture_root/before-update.json"
    (
      fleet_capture_observed='{"trusted":true,"claude":{"keeper@m":{"value":"disabled"}}}'
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
    fleet_capture_rebaseline "$rh_capture_store" mac "$rh_capture_fold" '{"trusted":false,"claude":null}' true
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
    printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"user","installPath":"/missing-fixture"}]}}' >"$rh_registry"
    printf '%s\n' '{"enabledPlugins":{"keeper@m":true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
    cat >"$rh_capture_root/inventory.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":1}}
{"kind":"plugin","status":"present","data":{"agent":"claude","inventory_source":"manager","manager_id":"keeper@m","name":"keeper","marketplace":"m","scope":"user","enabled":true,"installed_version":"100"}}
JSONL
    capture_snapshot "$rh_capture_root/inventory.jsonl" |
      jq -e '.trusted and .claude["keeper@m"].value == "enabled"' >/dev/null ||
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
    rh_observed=$(capture_snapshot "$rh_capture_root/scope.jsonl")
    rh_scope_fold=$(jq -c '.plugins += {
      uncertain:{state:"enabled",marketplace:"m"}, untouched:{state:"enabled",marketplace:"m"}
    }' <<<"$rh_capture_fold")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_scope_fold" "$rh_observed" true true "$rh_capture_tmp"
    jq -e 'keys == ["plugins.uncertain"]' <<<"$fleet_capture_skip" >/dev/null ||
      fail "one unknown scope did not hold only its own plugin"
    rh_changed_fold=$(jq -c '.plugins.keeper.state = "disabled"' <<<"$rh_scope_fold")
    fleet_capture_prepare "$rh_capture_store" mac "$rh_changed_fold" '{"trusted":false,"claude":null,"retry":true}' \
      true true "$rh_capture_tmp"
    [ "$fleet_capture_retry_unknown" = true ] && [ "$fleet_capture_skip" = '{}' ] ||
      fail "an unavailable listing did not request retry or skipped plan rows"

    sed 's/"scope":"user"/"scope":"project"/' "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/project.jsonl"
    fleet_capture_observe "$rh_capture_root/project.jsonl" | jq -e '.claude == null' >/dev/null ||
      fail "a project-only CLI listing overruled the registry's user install"
    printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"project"}]}}' >"$rh_registry"
    fleet_capture_observe "$rh_capture_root/project.jsonl" |
      jq -e '.claude["keeper@m"] | .value == "absent" and .user_scope == false' >/dev/null ||
      fail "matching project-only records did not count as absent in user scope"

    printf '%s\n' '{"plugins":{"keeper@m":[{"scope":"user"}],"keeper@other":[{"scope":"project"}]}}' \
      >"$rh_registry"
    jq -c 'if .kind == "plugin_manager" then .data.installed_count=2 else . end' \
      "$rh_capture_root/inventory.jsonl" >"$rh_capture_root/mixed.jsonl"
    jq -c 'select(.kind == "plugin") | .data |= (.manager_id="keeper@other" | .marketplace="other")' \
      "$rh_capture_root/project.jsonl" >>"$rh_capture_root/mixed.jsonl"
    rh_observed=$(capture_snapshot "$rh_capture_root/mixed.jsonl")
    rh_unqualified=$(jq -c '.plugins.keeper = "enabled"' <<<"$rh_capture_fold")
    fleet_capture_rows "$rh_capture_store" "$rh_unqualified" "$rh_observed" "$rh_capture_base" |
      jq -e 'any(.[]; .item == "plugins.keeper" and .id == "claude:keeper@m" and
        .ours == "enabled" and .ambiguous == false)' >/dev/null ||
      fail "a project-only alias made a user-scope installation ambiguous"
    fleet_capture_state_matches plugins.keeper '"enabled"' "$rh_observed" '{}' ||
      fail "a project-only alias prevented user-scope state matching"

    printf '%s\n' '{"plugins":{}}' >"$rh_registry"

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
        rh_empty_observed=$(capture_snapshot "$rh_capture_root/empty.jsonl")
        jq -e '.claude == {} and .trusted == false' <<<"$rh_empty_observed" >/dev/null ||
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
        rh_empty_observed=$(capture_snapshot "$rh_capture_root/$rh_bad_listing.jsonl")
        jq -e '.claude == null and .trusted == false and .retry == true' \
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
    rh_observed=$(capture_snapshot "$rh_capture_root/scope-only.jsonl")
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
    fi
  )
fi
