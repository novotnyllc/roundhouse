# roundhouse self-check — plugin ownership through a signed fixture fleet pass.
# Reuses the fixture manager commands from 07 and the local jj remote from 90.
# roundhouse-test: parts=3
# shellcheck shell=bash

if [ "$real_jj_ok" = true ]; then
  (
    set -eu
    rjj="$tmp/capture-pass"
    mkdir -p "$rjj/bin" "$rjj/vireo" "$rjj/home"
    ln -s "$real_jj" "$rjj/bin/jj"
    ln -s "$real_yq" "$rjj/bin/yq"
    # Fixture plugins have no live sessions; keep enabled-removal checks off the host.
    capture_ps=$(command -v ps)
    cat >"$rjj/bin/ps" <<SH
#!/bin/sh
case "\$*" in '-A -o comm='|'-A -ww -o command=') exit 0 ;; esac
exec "$capture_ps" "\$@"
SH
    chmod +x "$rjj/bin/ps"
    export PATH="$rjj/bin:$tmp/bin:$PATH"
    export HOME="$rjj/home" XDG_CONFIG_HOME="$rjj/xdg" JJ_CONFIG="$rjj/jj.toml"
    cat >"$JJ_CONFIG" <<'TOML'
[user]
name = "roundhouse selfcheck"
email = "roundhouse-selfcheck@example.invalid"
[ui]
paginate = "never"
editor = "true"
TOML
    rjj_key vireo
    rjj_krl seed.krl
    "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"
    printf 'name: vireo\ndomain: fleet.example.invalid\n' >"$rjj/vireo/identity.yaml"
    store="$rjj/vireo/store"
    export ROUNDHOUSE_FLEET_STORE="$store" ROUNDHOUSE_SELFTEST=1
    export ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/vireo-key" ROUNDHOUSE_TRUST_ROOT="$rjj/vireo"
    "$cli" fleet-init >/dev/null
    jj -R "$store" git remote add origin "$rjj/remote.git" >/dev/null
    "$cli" fleet-enroll >/dev/null
    ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "Permission denied (publickey)\n" >&2; exit 128' \
      "$cli" fleet-verify-remote >/dev/null
    mkdir -p "$store/fleet" "$store/hosts"
    printf 'platform: macos\ngroups: [canary]\n' >"$store/hosts/vireo.yaml"
    cat >"$store/fleet/capture-probe.yaml" <<'YAML'
# Owner declarations must stay byte-for-byte intact during a hold.
policy:
  max_removal_fraction: 1
plugins:
  keeper: {state: enabled, marketplace: test-market}
  ponytail: {state: absent, marketplace: test-market}
  stale-local: {state: absent, marketplace: test-market}
YAML
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    export CLAUDE_PLUGIN_LIST_FROM_RECORDS=1
    export CLAUDE_PLUGIN_CATALOG_FILE="$rjj/catalog.json"
    export CLAUDE_PLUGIN_ENABLED_FILE="$rjj/enabled.json"
    export CLAUDE_PLUGIN_ACTION_LOG="$rjj/actions"
    export CLAUDE_INSTALL_MARKER="$rjj/installs"
    export CLAUDE_PLUGIN_MARKETPLACE_FILE="$rjj/markets.json"
    mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
    installed="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    settings="$CLAUDE_CONFIG_DIR/settings.json"
    sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    jq -cn --arg sha "$sha" '{available: [
      {pluginId:"keeper@test-market",version:"1.0.0",source:{source:"git",sha:$sha}},
      {pluginId:"ponytail@test-market",version:"1.0.0",source:{source:"git",sha:$sha}}]}' \
      >"$CLAUDE_PLUGIN_CATALOG_FILE"
    printf '%s\n' '[{"name":"test-market","source":"url","url":"https://market.example.invalid/catalog.json"}]' \
      >"$CLAUDE_PLUGIN_MARKETPLACE_FILE"
    printf '%s\n' '{"test-market":{"source":{"source":"url","url":"https://market.example.invalid/catalog.json"}}}' \
      >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
    jq -cn --arg sha "$sha" '
      {version:2,plugins: {
        "stale-local@test-market":[{scope:"user",version:"1.0.0",gitCommitSha:$sha}],
        "local-extra@test-market":[{scope:"user",version:"1.0.0",gitCommitSha:$sha}]
      }}' >"$installed"
    printf '%s\n' '{"stale-local@test-market":true,"local-extra@test-market":true}' \
      >"$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{}\n' >"$settings"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"

    capture_pass() {
      "$cli" fleet-run --fast >"$rjj/pass.log" 2>&1 || {
        cat "$rjj/pass.log" >&2
        fail "signed fixture pass failed ($1)"
      }
    }
    capture_owner_remove() {
      jq --arg id "$1" 'del(.plugins[$id])' "$installed" >"$installed.next" &&
        mv "$installed.next" "$installed"
      jq --arg id "$1" 'del(.[$id])' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
        mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    }
    capture_report() {
      assert_contains "$(cat "$rjj/pass.log")" "$1 $2 locally"
      local doctor_rows
      doctor_rows=$("$cli" fleet-doctor 2>&1) || :
      grep '^FINDING .*agent-local-change' <<<"$doctor_rows" | grep -Fq "$1 $2 locally" ||
        fail "fleet-doctor did not report $1 $2 locally"
    }
    capture_store_unchanged() {
      # Alerts and ordinary run records can still travel through the publisher.
      capture_remote diff --exit-code "$1" main -- . \
        ':(exclude,glob)alerts/**' ':(exclude,glob)journal/**' ':(exclude,glob)applied/**' ||
        fail "the held pass changed bytes outside normal published records"
      cmp "$store/fleet/capture-probe.yaml" "$rjj/before-layer.yaml" >/dev/null ||
        fail "the held pass changed local declaration bytes"
      if capture_remote grep -q 'outcome: captured' main -- journal/vireo; then
        fail "the held pass wrote a capture journal entry"
      fi
      [ "$(jj -R "$store" log -r @ --no-graph -T 'if(empty,"empty","dirty")')" = empty ] ||
        fail "the held pass left its working copy dirty"
    }
    capture_remote() {
      "$REAL_GIT" --git-dir="$rjj/remote.git" "$@"
    }
    capture_layer() {
      capture_remote show main:fleet/capture-probe.yaml
    }
    capture_lib() (
      # shellcheck source=/dev/null
      ROUNDHOUSE_LIB_ONLY=1 . "$cli"
      "$@"
    )
    capture_owner_install() {
      jq --arg id "$1" --arg sha "$sha" '.plugins[$id] = [{scope:"user",version:"1.0.0",gitCommitSha:$sha}]' \
        "$installed" >"$installed.next" && mv "$installed.next" "$installed"
      # A disabled install can be discarded without probing for live sessions.
      jq --arg id "$1" '.[$id] = false' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
        mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    }
    baseline="$rjj/vireo/store.run/agent-baseline.json"
    capture_pass first
    jq -e '
      ._initialized.claude == true and
      .["claude:ponytail@test-market"] == {value:"absent"} and
      .["claude:keeper@test-market"] == {value:"enabled"} and
      .["claude:stale-local@test-market"] == {value:"absent"} and
      .["claude:local-extra@test-market"] == {value:"enabled", ignored:true}
    ' "$baseline" >/dev/null || fail "first pass did not record agreement and ignore its extra"
    grep -Fqx 'install keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "the first pass did not install a store-enabled missing plugin"
    if grep -Eq '^uninstall ' "$CLAUDE_PLUGIN_ACTION_LOG"; then
      fail "the first pass uninstalled a local plugin"
    fi
    capture_report claude:stale-local@test-market added
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass first-pass-hold-retry
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "the second pass reverted the first-pass local add"
    capture_report claude:stale-local@test-market added
    jq -e '.["claude:stale-local@test-market"] == {value:"absent"}' "$baseline" >/dev/null ||
      fail "the second pass advanced agreement for the held local add"
    capture_owner_remove stale-local@test-market
    capture_pass first-pass-hold-agreement
    capture_layer >"$rjj/before-layer.yaml"
    if section_part 1; then
    before_hold=$(capture_remote rev-parse main)

    capture_owner_install ponytail@test-market
    # Unknown inventory must not revert either an owner install or removal.
    cat >"$rjj/partial.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":2}}
JSONL
    sed 's/"status":"present"/"status":"unavailable"/' "$rjj/partial.jsonl" >"$rjj/failed.jsonl"
    cp "$installed" "$rjj/registry"
    printf '{broken\n' >"$installed"
    capture_pass unreadable-registered-state
    if grep -Fq 'ponytail@test-market added locally' "$rjj/pass.log"; then
      fail "an unreadable registry generated a local change alert"
    fi
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] ||
      fail "an unreadable registry caused a plugin mutation"
    mv "$rjj/registry" "$installed"
    capture_owner_remove keeper@test-market
    for listing in partial failed; do
      capture_owner_install ponytail@test-market
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      ROUNDHOUSE_SEED_SNAPSHOT="$rjj/$listing.jsonl" capture_pass "$listing-listing"
      if grep -Eq ' (added|removed|enabled|disabled) locally' "$rjj/pass.log"; then
        fail "$listing inventory generated a local change alert"
      fi
      [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] ||
        fail "$listing inventory reverted an owner install or removal"
      [ "$(grep -Ec 'Claude plugin inventory unavailable; making no plugin reverts this pass \([0-9]+ items held, retried next pass\)\.' "$rjj/pass.log")" -eq 1 ] ||
        fail "$listing inventory did not report held items once"
    done
    capture_owner_install keeper@test-market
    jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"

    # Failed inventory must defer store changes when the owner changed first.
    mkdir -p "$rjj/unknown-change"
    capture_unknown_prepare() {
      ROUNDHOUSE_SEED_SNAPSHOT="$rjj/failed.jsonl" capture_lib fleet_capture_pass_prepare \
        "$store" vireo "$(capture_lib fleet_run_desired "$store" vireo)" \
        true true "$rjj/unknown-change" "$store"
    }
    capture_lib fleet_capture_observe "$rjj/failed.jsonl" |
      jq -e '.claude == null' >/dev/null || fail "failed listing was not unknown"
    for owner_change in settings-and-cli cli-only uninstall; do
      jq -e '.["claude:keeper@test-market"] == {value:"enabled"}' "$baseline" >/dev/null ||
        fail "unknown-inventory $owner_change did not start from agreed enabled"
      capture_owner_install keeper@test-market
      printf '%s\n' '{"enabledPlugins":{"keeper@test-market":true}}' >"$settings"
      case $owner_change in
        settings-and-cli)
          printf '%s\n' '{"enabledPlugins":{"keeper@test-market":false}}' >"$settings" ;;
        cli-only) : ;;
        uninstall) capture_owner_remove keeper@test-market ;;
      esac
      store_state=absent
      [ "$owner_change" != uninstall ] || store_state=disabled
      yq -i ".plugins.keeper.state = \"$store_state\"" "$store/fleet/capture-probe.yaml"
      capture_unknown_prepare
      grep -Fqx plugins.keeper "$rjj/unknown-change/capture-skip" ||
        fail "unknown inventory did not hold $owner_change in capture-skip"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      ROUNDHOUSE_SEED_SNAPSHOT="$rjj/failed.jsonl" capture_pass "unknown-inventory-$owner_change"
      if grep -Eq '^(uninstall|install|disable) keeper@test-market$' "$CLAUDE_PLUGIN_ACTION_LOG"; then
        cat "$CLAUDE_PLUGIN_ACTION_LOG" >&2
        fail "unknown inventory let a store change overwrite owner $owner_change"
      fi
      yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
    done
    capture_owner_install keeper@test-market
    jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{}\n' >"$settings"
    if capture_remote grep -Eq '(ponytail@test-market added|keeper@test-market removed) locally' main -- alerts/vireo; then
      fail "unavailable or incomplete inventory published a local hold alert"
    fi

    capture_owner_install ponytail@test-market
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass owner-install
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "the pass reverted the owner's install"
    capture_report claude:ponytail@test-market added
    capture_store_unchanged "$before_hold"
    capture_remote grep -q 'ponytail@test-market added locally' main -- alerts/vireo ||
      fail "the added alert was not replicated through the normal publisher"
    jq -e '.["claude:ponytail@test-market"].value == "absent"' "$baseline" >/dev/null ||
      fail "a held install advanced agreement"

    for bad_discard in plugins.not-held claude:ponytail@wrong-market; do
      discard_status=0
      "$cli" fleet-discard "$bad_discard" >/dev/null 2>&1 || discard_status=$?
      [ "$discard_status" -eq 65 ] || fail "discard accepted an item without a hold: $bad_discard"
    done
    [ ! -e "${baseline%/*}/agent-discard.json" ] || fail "invalid discard left a queued decision"
    before_discard=$(capture_remote rev-parse main)
    "$cli" fleet-discard plugins.ponytail >/dev/null
    [ "$(capture_remote rev-parse main)" = "$before_discard" ] ||
      fail "discard published to the store"
    capture_pass discarded-install
    grep -Fqx 'uninstall ponytail@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "discard did not let the fleet uninstall the local add"
    jq -e '(.plugins | has("ponytail@test-market")) | not' "$installed" >/dev/null ||
      fail "the discarded install stayed installed"
    [ ! -e "${baseline%/*}/agent-discard.json" ] || fail "agreed discard was not consumed"

    # Store changes still act with failed inventory when all pre-pass records agree.
    printf '%s\n' '{"enabledPlugins":{"keeper@test-market":true}}' >"$settings"
    yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
    capture_unknown_prepare
    if grep -Fqx plugins.keeper "$rjj/unknown-change/capture-skip"; then
      fail "unknown inventory held a store change despite unchanged owner records"
    fi
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    ROUNDHOUSE_SEED_SNAPSHOT="$rjj/failed.jsonl" capture_pass unknown-inventory-unchanged-owner
    grep -Fqx 'uninstall keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" || {
      cat "$rjj/pass.log" >&2
      fail "unknown inventory blocked the unchanged owner's fleet removal"
    }
    yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
    capture_owner_install keeper@test-market
    jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{}\n' >"$settings"
    fi

    if section_part 2; then
    # An interrupted Roundhouse mutation may leave a state change and marker.
    capture_lib fleet_agent_pending_mark claude keeper@test-market enabled disabled
    marker=$(capture_lib fleet_agent_pending_path claude:keeper@test-market)
    jq '.["keeper@test-market"] = false' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{"fixture_touch":true}\n' >"$settings"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass marked-disable
    grep -Fqx 'enable keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "the interrupted apply was not converged back to the fleet"
    [ ! -e "$marker" ] || fail "agreement did not clear the crash marker"
    if grep -Fq 'keeper@test-market disabled locally' "$rjj/pass.log"; then
      fail "a marked change was reported as local"
    fi

    before_hold=$(capture_remote rev-parse main)
    capture_owner_remove keeper@test-market
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass owner-uninstall
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] ||
      fail "the pass reinstalled the plugin the owner removed"
    capture_report claude:keeper@test-market removed
    capture_store_unchanged "$before_hold"

    # The owner changes the fleet side too. A conflict still protects local state.
    yq -i '.plugins.keeper.state = "disabled"' "$store/fleet/capture-probe.yaml"
    capture_pass owner-conflict
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "the pass reverted a conflict"
    assert_contains "$(cat "$rjj/pass.log")" 'claude:keeper@test-market removed locally and changed in the fleet'
    capture_remote grep -q 'keeper@test-market removed locally and changed in the fleet' main -- alerts/vireo ||
      fail "the pass did not report the conflict"
    [ ! -e "${baseline%/*}/agent-conflicts.json" ] || fail "the pass persisted a conflict record"

    yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
    capture_pass agreement
    jq -e '.["claude:keeper@test-market"] == {value:"absent"}' "$baseline" >/dev/null ||
      fail "store agreement did not settle the held removal"
    if capture_remote grep -q 'keeper@test-market.*removed locally' main -- alerts/vireo; then
      fail "the local change alert outlived store agreement"
    fi

    capture_owner_install discard-probe@test-market
    capture_pass unmanaged-add
    assert_contains "$(cat "$rjj/pass.log")" 'claude:discard-probe@test-market added locally'
    "$cli" fleet-discard plugins.discard-probe >/dev/null
    capture_owner_remove discard-probe@test-market
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass disappeared-discard
    [ ! -e "${baseline%/*}/agent-discard.json" ] ||
      fail "an authoritatively disappeared unmanaged plugin stranded its discard"
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "discard mutated a disappeared plugin"
    fi

    if section_part 3; then
    # #133: the last Roundhouse removal must settle before an owner reinstall.
    jq -cn --arg sha "$sha" '{version:2,plugins:{
      "keeper@test-market":[{scope:"user",version:"1.0.0",gitCommitSha:$sha}]
    }}' >"$installed"
    printf '%s\n' '{"keeper@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{}\n' >"$settings"
    yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
    capture_pass last-plugin-baseline
    jq -e '.["claude:keeper@test-market"] == {value:"enabled"} and
      ([to_entries[] | select(.value | type == "object") |
        select(.value.value | IN("enabled","disabled"))] | length) == 1' \
      "$baseline" >/dev/null || fail "last-plugin regression did not start with exactly one agreed install"
    marker=$(capture_lib fleet_agent_pending_path claude:keeper@test-market)
    [ ! -e "$marker" ] || fail "last-plugin baseline retained a pending marker"
    cat >"$rjj/last-installed.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":1}}
{"kind":"plugin","status":"present","data":{"agent":"claude","inventory_source":"manager","manager_id":"keeper@test-market","name":"keeper","marketplace":"test-market","scope":"user","enabled":true,"installed_version":"1.0.0"}}
JSONL
    yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    cp "$installed" "$rjj/last-installed.json"
    cp "$CLAUDE_PLUGIN_ENABLED_FILE" "$rjj/last-enabled.json"
    cp "$baseline" "$rjj/last-baseline.json"
    capture_owner_remove keeper@test-market
    capture_pass last-plugin-unexplained-empty
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "an unexplained empty inventory caused a plugin mutation"
    cmp "$baseline" "$rjj/last-baseline.json" >/dev/null ||
      fail "an unexplained empty inventory changed signed-pass agreement"
    [ ! -e "$marker" ] || fail "an unexplained empty inventory manufactured a removal marker"
    if grep -Eq ' (added|removed|enabled|disabled) locally' "$rjj/pass.log"; then
      fail "an unexplained empty inventory generated a local hold"
    fi
    mv "$rjj/last-installed.json" "$installed"
    mv "$rjj/last-enabled.json" "$CLAUDE_PLUGIN_ENABLED_FILE"
    # Freeze the pre-apply listing so agreement requires the next fresh pass.
    ROUNDHOUSE_SEED_SNAPSHOT="$rjj/last-installed.jsonl" capture_pass last-plugin-removal
    [ "$(cat "$CLAUDE_PLUGIN_ACTION_LOG")" = 'uninstall keeper@test-market' ] ||
      fail "last-plugin tombstone did not uninstall exactly the agreed plugin"
    jq -e '.plugins == {}' "$installed" >/dev/null || fail "last-plugin removal left a nonempty inventory"
    jq -e '. == {id:"claude:keeper@test-market",from:"enabled",to:"absent"}' "$marker" >/dev/null ||
      fail "last-plugin removal did not leave its Roundhouse marker"
    jq -e '.["claude:keeper@test-market"] == {value:"enabled"}' "$baseline" >/dev/null ||
      fail "the stale listing advanced last-plugin agreement before a fresh pass"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass last-plugin-agreement
    jq -e '.["claude:keeper@test-market"] == {value:"absent"}' "$baseline" >/dev/null ||
      fail "#133: empty inventory did not advance last-plugin agreement to absent"
    [ ! -e "$marker" ] || fail "#133: last-plugin agreement did not clear the removal marker"
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "last-plugin agreement mutated an empty inventory"

    capture_owner_install keeper@test-market
    printf '%s\n' '{"keeper@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    capture_pass last-plugin-owner-reinstall
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "#133: the tombstone reverted the owner's reinstall"
    jq -e --arg sha "$sha" '.plugins["keeper@test-market"] == [{scope:"user",version:"1.0.0",gitCommitSha:$sha}]' \
      "$installed" >/dev/null || fail "#133: the owner's reinstall did not stay installed"
    capture_report claude:keeper@test-market added
    jq -e '.["claude:keeper@test-market"] == {value:"absent"}' "$baseline" >/dev/null ||
      fail "#133: the held reinstall advanced agreement"
    printf 'real-jj: OK (#133 last-plugin removal, empty agreement, and held owner reinstall)\n'
    fi

    printf 'real-jj: OK (silent baseline, guarded local changes, discard, and agreement)\n'
  )
else
  printf 'NOTICE: plugin observation pass fixture requires real jj >= 0.43 and yq\n'
fi
