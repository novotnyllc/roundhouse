# roundhouse self-check — plugin ownership through a signed fixture fleet pass.
# Reuses the fixture manager commands from 07 and the local jj remote from 90.
# roundhouse-test: parts=15
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
    untrusted_message="roundhouse: Claude plugin inventory not trusted; making no Claude plugin changes this pass"

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
    journal="${baseline%/*}/agent-journal/claude.keeper@test-market"
    capture_interrupted_alert() {
      capture_remote grep -Eq 'kind: agent-capture-interrupted' main -- alerts/vireo
    }
    capture_pass first
    jq -e '
      ._initialized.claude == true and
      .["claude:ponytail@test-market"].value == "absent" and
      .["claude:keeper@test-market"].value == "enabled" and
      .["claude:stale-local@test-market"].value == "absent" and
      (.["claude:local-extra@test-market"] | .value == "enabled" and .ignored == true)
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
    jq -e '.["claude:stale-local@test-market"].value == "absent"' "$baseline" >/dev/null ||
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
      [ "$(grep -Fxc "$untrusted_message" "$rjj/pass.log")" -eq 1 ] ||
        fail "$listing inventory did not report untrusted inventory once"
    done
    capture_owner_install keeper@test-market
    jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"

    # Failed inventory must defer store changes when the owner changed first.
    for owner_change in settings-and-cli cli-only uninstall; do
      jq -e '.["claude:keeper@test-market"].value == "enabled"' "$baseline" >/dev/null ||
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

    # A fleet removal still waits for trust when the owner has made no edit.
    printf '%s\n' '{"enabledPlugins":{"keeper@test-market":true}}' >"$settings"
    yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    ROUNDHOUSE_SEED_SNAPSHOT="$rjj/failed.jsonl" capture_pass unknown-inventory-unchanged-owner
    ! grep -Fqx 'uninstall keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "unknown inventory let a fleet removal bypass the boundary"
    [ -e "${baseline%/*}/retry-owed" ] || fail "unknown inventory did not leave retry debt"
    yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
    capture_owner_install keeper@test-market
    jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{}\n' >"$settings"
    fi

    if section_part 2; then
    # A legacy pre-action marker records no proof of who disabled the plugin.
    legacy="${baseline%/*}/agent-pending/claude.keeper@test-market"
    mkdir -p "${legacy%/*}"
    printf '%s\n' '{"id":"claude:keeper@test-market","from":"enabled","to":"disabled"}' >"$legacy"
    jq '.["keeper@test-market"] = false' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{"fixture_touch":true}\n' >"$settings"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass interrupted-owner-disable
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] ||
      fail "A1 interrupted disable let the next pass revert the owner's disable"
    capture_interrupted_alert || fail "A1 migrated interrupted disable did not publish its alert"
    [ ! -e "$legacy" ] && jq -e '.intent != null and .receipt == null' "$journal" >/dev/null ||
      fail "A1 legacy marker was not migrated to unresolved intent"
    jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    capture_pass interrupted-owner-agreement
    [ ! -e "$journal" ] || fail "agreement did not clear the migrated intent"

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
    jq -e '.["claude:keeper@test-market"].value == "absent"' "$baseline" >/dev/null ||
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
    # #135: a fresh empty scan settles the last Roundhouse removal.
    jq -cn --arg sha "$sha" '{version:2,plugins:{
      "keeper@test-market":[{scope:"user",version:"1.0.0",gitCommitSha:$sha}]
    }}' >"$installed"
    printf '%s\n' '{"keeper@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{}\n' >"$settings"
    yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
    capture_pass last-plugin-baseline
    jq -e '.["claude:keeper@test-market"].value == "enabled" and
      ([to_entries[] | select(.value | type == "object") |
        select(.value.value | IN("enabled","disabled"))] | length) == 1' \
      "$baseline" >/dev/null || fail "last-plugin regression did not start with exactly one agreed install"
    [ ! -e "$journal" ] || fail "last-plugin baseline retained a pending receipt or intent"
    cat >"$rjj/last-installed.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"present","data":{"agent":"claude","authoritative":true,"installed_count":1}}
{"kind":"plugin","status":"present","data":{"agent":"claude","inventory_source":"manager","manager_id":"keeper@test-market","name":"keeper","marketplace":"test-market","scope":"user","enabled":true,"installed_version":"1.0.0"}}
JSONL
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
    # Freeze the pre-apply listing so agreement requires the next fresh pass.
    ROUNDHOUSE_SEED_SNAPSHOT="$rjj/last-installed.jsonl" capture_pass last-plugin-removal
    [ "$(cat "$CLAUDE_PLUGIN_ACTION_LOG")" = 'uninstall keeper@test-market' ] ||
      fail "last-plugin tombstone did not uninstall exactly the agreed plugin"
    jq -e '.plugins == {}' "$installed" >/dev/null || fail "last-plugin removal left a nonempty inventory"
    jq -e '.id == "claude:keeper@test-market" and .intent == null and
      .receipt.op == "uninstall" and .receipt.installed == false and .receipt.state == null and
      (.receipt.seq | type) == "number"' "$journal" >/dev/null ||
      fail "last-plugin removal did not leave its verified receipt"
    removal_seq=$(jq -r '.receipt.seq' "$journal")
    jq -e --argjson receipt "$removal_seq" '.["claude:keeper@test-market"] |
      .value == "enabled" and .seq < $receipt' "$baseline" >/dev/null ||
      fail "the stale listing advanced last-plugin agreement before a fresh pass"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass last-plugin-agreement
    jq -e --argjson receipt "$removal_seq" '.["claude:keeper@test-market"] |
      .value == "absent" and .seq > $receipt' "$baseline" >/dev/null ||
      fail "#135: empty inventory did not advance last-plugin agreement beyond the removal receipt"
    [ ! -e "$journal" ] || fail "#135: last-plugin agreement did not clear the removal receipt"
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "last-plugin agreement mutated an empty inventory"

    capture_owner_install keeper@test-market
    printf '%s\n' '{"keeper@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    capture_pass last-plugin-owner-reinstall
    [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "#135: the tombstone reverted the owner's reinstall"
    jq -e --arg sha "$sha" '.plugins["keeper@test-market"] == [{scope:"user",version:"1.0.0",gitCommitSha:$sha}]' \
      "$installed" >/dev/null || fail "#135: the owner's reinstall did not stay installed"
    capture_report claude:keeper@test-market added
    jq -e '.["claude:keeper@test-market"].value == "absent"' "$baseline" >/dev/null ||
      fail "#135: the held reinstall advanced agreement"
    printf 'real-jj: OK (#135 last-plugin removal, empty agreement, and held owner reinstall)\n'
    fi

    if section_part 4; then
    # The same observation could mean the operation never ran or the owner reverted it.
    mkdir -p "${journal%/*}"
    jq -cn --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" '{
      id:"claude:keeper@test-market", home:$home,
      intent:{op:"disable",to:"disabled",from:{installed:true,state:"enabled"},
        op_id:"dead",pid:2147483647,start:"dead",seq:1}
    }' >"$journal"
    yq -i '.plugins.keeper.state = "disabled" | .plugins.ponytail.state = "enabled"' \
      "$store/fleet/capture-probe.yaml"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass interrupted-without-owner-change
    ! grep -Eq '^(disable|uninstall) keeper@test-market$' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "A1 unchanged interrupted intent let the pass disable the plugin"
    capture_interrupted_alert || fail "A1 unchanged interrupted intent did not publish its alert"
    jq -e '.intent.op_id == "dead" and .receipt == null' "$journal" >/dev/null ||
      fail "A1 observation alone cleared the unchanged interrupted intent"
    grep -Fqx 'install ponytail@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "A1 the interrupted keeper blocked an unrelated plugin's convergence"

    yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
    capture_pass interrupted-agreement
    [ ! -e "$journal" ] || fail "A1 trusted agreement did not clear the interrupted intent"
    if capture_interrupted_alert; then
      fail "A1 interrupted alert outlived trusted agreement"
    fi
    fi

    if section_part 5; then
    yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
    memo=$(capture_lib fleet_run_tombstone_memo_path plugins.keeper)
    before_owned=$(capture_lib fleet_applied_digest "$store" vireo plugins.keeper)
    [ -n "$before_owned" ] || fail "Attack #11 fixture did not start with applied ownership"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    (
      trap 'rc=$?; if [ "$rc" -ne 0 ]; then cat "$rjj/pass.log" >&6; fi' EXIT
      # shellcheck source=/dev/null
      ROUNDHOUSE_LIB_ONLY=1 . "$cli"
      eval "$(declare -f fleet_run_tombstone_target | sed '1s/fleet_run_tombstone_target/capture_original_target/')"
      eval "$(declare -f fleet_capture_pass_observe_after | sed '1s/fleet_capture_pass_observe_after/capture_original_observe_after/')"
      fleet_run_tombstone_target() {
        if [ "$2" = keeper ]; then
          if [ -e "$rjj/keeper-target-seen" ] && [ ! -e "$rjj/keeper-owner-removed" ]; then
            capture_owner_remove keeper@test-market
            : >"$rjj/keeper-owner-removed"
          else
            : >"$rjj/keeper-target-seen"
          fi
        fi
        capture_original_target "$@"
      }
      fleet_capture_pass_observe_after() {
        # Reinstall before the post-pass observation can agree on absence.
        capture_owner_install keeper@test-market
        jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
          mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
        capture_original_observe_after "$@"
      }
      fleet_run_command --fast
    ) 6>&2 >"$rjj/pass.log" 2>&1
    [ -e "$rjj/keeper-owner-removed" ] || fail "Attack #11 fixture did not remove keeper before apply lookup"
    [ ! -e "$memo" ] || fail "Attack #11 already-absent owner removal wrote a tombstone memo"
    [ "$(capture_lib fleet_applied_digest "$store" vireo plugins.keeper)" = "$before_owned" ] ||
      fail "Attack #11 already-absent owner removal changed ownership"
    ! grep -Fqx 'uninstall keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "Attack #11 pass ran an uninstall after the owner removed keeper"

    capture_pass raced-removal-reinstall
    ! grep -Fqx 'uninstall keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "Attack #11 a later pass uninstalled the owner's reinstall"
    jq -e '.plugins | has("keeper@test-market")' "$installed" >/dev/null ||
      fail "Attack #11 the owner's reinstall did not stay installed"
    fi

    if section_part 6; then
      capture_owner_remove local-extra@test-market
      jq '.plugins["keeper@test-market"] += [{scope:"future-scope",version:"1.0.0"}]' "$installed" >"$installed.next" &&
        mv "$installed.next" "$installed"
      printf '%s\n' '{"keeper@test-market":false}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
      printf '%s\n' '{"enabledPlugins":{"keeper@test-market":false}}' >"$settings"
      yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      capture_pass future-scope-owner-disable
      ! grep -Fqx 'uninstall keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
        fail "A2 untrusted future scope allowed uninstall after the owner disabled keeper"
    fi

    if section_part 7; then
      receipt_dir="${journal%/*}"
      cp "$baseline" "$rjj/before-last-removal.json"
      failed=0
      for evidence in none partial; do
        cp "$rjj/before-last-removal.json" "$baseline"
        capture_owner_remove local-extra@test-market
        capture_owner_remove keeper@test-market
        printf '{}\n' >"$settings"
        if [ "$evidence" = partial ]; then
          jq '.["claude:ponytail@test-market"] = {value:"enabled"}' "$baseline" >"$baseline.next" &&
            mv "$baseline.next" "$baseline"
          mkdir -p "$receipt_dir"
          jq -cn --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" '{
            id:"claude:ponytail@test-market",home:$home,
            receipt:{op:"uninstall",installed:false,state:null,seq:1}
          }' >"$receipt_dir/claude.ponytail@test-market"
        fi
        cp "$baseline" "$rjj/expected-empty-agreement.json"
        yq -i '.plugins.keeper.state = "disabled"' "$store/fleet/capture-probe.yaml"
        : >"$CLAUDE_PLUGIN_ACTION_LOG"
        capture_pass "owner-removed-last-$evidence"
        if grep -Fqx 'install keeper@test-market' "$CLAUDE_PLUGIN_ACTION_LOG"; then
          printf 'FAIL: #136 reinstalled the last plugin removed by the owner (%s receipts)\n' "$evidence" >&2
          failed=1
        else
          cmp "$baseline" "$rjj/expected-empty-agreement.json" >/dev/null ||
            fail "#136 empty inventory changed agreement ($evidence receipts)"
        fi
        yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
      done
      [ "$failed" = 0 ] || exit 1
    fi

    if section_part 8; then
      cat >"$rjj/no-claude.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"absent","data":{"agent":"claude","authoritative":false}}
JSONL
      # Leave the registry behind to model an uninstalled CLI with its old home.
      yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      ROUNDHOUSE_SEED_SNAPSHOT="$rjj/no-claude.jsonl" capture_pass no-claude-tombstone
      [ ! -e "${baseline%/*}/retry-owed" ] ||
        fail "an absent Claude harness left blanket retry debt"
      [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "an absent Claude harness ran a plugin verb"
      grep -Eq '^  satisfied plugins\.keeper([ (]|$)' "$rjj/pass.log" ||
        fail "an absent Claude harness did not satisfy the tombstone"
    fi

    if section_part 9; then
      # New plugin names avoid a previously applied item's version/identity memo.
      rm -f "$baseline"
      for name in first-off first-on; do capture_owner_install "$name@test-market"; done
      jq '.["first-on@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
        mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
      jq --arg sha "$sha" '.available += (["first-off","first-on","first-missing"] |
        map({pluginId:(.+"@test-market"),version:"1.0.0",source:{source:"git",sha:$sha}}))' \
        "$CLAUDE_PLUGIN_CATALOG_FILE" >"$rjj/catalog.next" &&
        mv "$rjj/catalog.next" "$CLAUDE_PLUGIN_CATALOG_FILE"
      yq -i '.plugins."first-off" = {"state":"enabled","marketplace":"test-market"} |
        .plugins."first-on" = {"state":"disabled","marketplace":"test-market"} |
        .plugins."first-missing" = {"state":"enabled","marketplace":"test-market"}' "$store/fleet/capture-probe.yaml"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      capture_pass first-pass-state-disagreement
      failed=0
      for action in 'enable first-off' 'disable first-on'; do
        if grep -Fqx "$action@test-market" "$CLAUDE_PLUGIN_ACTION_LOG"; then
          printf 'FAIL: first observation ran %s@test-market despite owner state\n' "$action" >&2
          failed=1
        fi
      done
      [ "$failed" = 0 ] || exit 1
      grep -Fqx 'install first-missing@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
        fail "the first pass did not install the missing control plugin"
      capture_report claude:first-off@test-market disabled
      capture_report claude:first-on@test-market enabled
      jq -e '.["claude:first-off@test-market"].value == "enabled" and
        .["claude:first-on@test-market"].value == "disabled"' "$baseline" >/dev/null ||
        fail "first observation replaced the store agreement with held local state"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      capture_pass first-pass-state-disagreement-retry
      ! grep -Eq '^(enable first-off|disable first-on)@test-market$' "$CLAUDE_PLUGIN_ACTION_LOG" ||
        fail "the second pass reverted a first-observation state disagreement"
      capture_report claude:first-off@test-market disabled
      capture_report claude:first-on@test-market enabled
    fi

    if section_part 10; then
      cat >"$rjj/claude-unavailable.jsonl" <<'JSONL'
{"kind":"plugin_manager","status":"unavailable","data":{"agent":"claude","authoritative":false}}
JSONL
      (
        # shellcheck source=/dev/null
        ROUNDHOUSE_LIB_ONLY=1 . "$cli"
        fleet_plugins_probe() {
          fleet_plugins_probed=true
          fleet_plugins_moved=$(printf 'codex%sfixture%shead%s%s' \
            "$fleet_run_sep" "$fleet_run_sep" "$fleet_run_sep" "$rjj")
          return 0
        }
        fleet_plugins_codex_sync() {
          [ ! -s "$1" ] || cp "$1" "$rjj/codex-sync"
        }
        fleet_run_codex_hooks_settled() {
          if [ "$1" = keeper@test-market ] && [ "$2" = "$sha" ]; then
            : >"$rjj/hook-retry"
          fi
        }
        ROUNDHOUSE_SEED_SNAPSHOT="$rjj/claude-unavailable.jsonl" fleet_run_command --fast
      ) >"$rjj/pass.log" 2>&1
      [ -s "$rjj/codex-sync" ] || fail "untrusted Claude inventory blocked Codex sync"
      [ -e "$rjj/hook-retry" ] || fail "untrusted Claude inventory skipped the independent hook retry"
      [ "$(grep -Fxc "$untrusted_message" "$rjj/pass.log")" -eq 1 ] ||
        fail "the pass with Codex sync did not report untrusted Claude inventory once"
    fi

    capture_receipt_removal() {
      local timing=$1 rc=0
      yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      set +e
      (
        set -e
        # shellcheck source=/dev/null
        ROUNDHOUSE_LIB_ONLY=1 . "$cli"
        eval "$(declare -f fleet_capture_pass_observe_after | sed '1s/fleet_capture_pass_observe_after/capture_original_observe_after/')"
        fleet_capture_pass_observe_after() {
          [ "$timing" != crash ] || exit 97
          if [ "$timing" = before-collect ]; then capture_reinstall_keeper; fi
          capture_original_observe_after "$@" || return $?
          if [ "$timing" = after-collect ]; then
            jq -r '.trusted' <<<"${fleet_capture_after_observed:-'{}'}" >"$rjj/after-trust"
            exit 97
          fi
        }
        fleet_run_command --fast
      ) >"$rjj/pass.log" 2>&1
      rc=$?
      set -e
      case $timing:$rc in
        crash:97|before-collect:0|after-collect:97) ;;
        *) cat "$rjj/pass.log" >&2; fail "removal fixture exited with $rc ($timing)" ;;
      esac
      [ "$(cat "$CLAUDE_PLUGIN_ACTION_LOG")" = 'uninstall keeper@test-market' ] ||
        fail "removal fixture did not uninstall Keeper exactly once ($timing)"
      [ "$timing" = before-collect ] || jq -e '.plugins | has("keeper@test-market") | not' "$installed" >/dev/null ||
        fail "removal fixture did not leave Keeper absent ($timing)"
    }

    capture_reinstall_keeper() {
      capture_owner_install keeper@test-market
      jq '.["keeper@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
        mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    }

    capture_receipt_b2() {
      local label=$1 timing=$2
      capture_receipt_removal "$timing"
      [ "$timing" = before-collect ] || capture_reinstall_keeper
      jq -e '.["claude:keeper@test-market"].value == "enabled"' "$baseline" >/dev/null ||
        fail "$label did not leave the original enabled agreement pending"
      capture_pass "$label-reinstall"
      [ "$(cat "$CLAUDE_PLUGIN_ACTION_LOG")" = 'uninstall keeper@test-market' ] ||
        fail "$label: a second uninstall reverted the owner's reinstall"
      capture_report claude:keeper@test-market added
    }

    if section_part 11; then
      capture_receipt_b2 B2 before-collect
    fi
    if section_part 12; then
      capture_receipt_b2 'B2 crash' crash
    fi
    if section_part 13; then
      capture_owner_remove local-extra@test-market
      capture_receipt_b2 'B2 Extra' after-collect
      grep -Fqx true "$rjj/after-trust" || fail "B2 Extra: ignored Extra blocked trusted empty observation"
    fi

    capture_accept_reinstall() {
      capture_receipt_removal before-collect
      [ ! -e "$journal" ] || cp "$journal" "$rjj/old-receipt.json"
      yq -i '.plugins.keeper.state = "enabled"' "$store/fleet/capture-probe.yaml"
      capture_pass accept-reinstall
      jq -e --slurpfile receipt "$rjj/old-receipt.json" '.["claude:keeper@test-market"] |
        .value == "enabled" and .seq > $receipt[0].receipt.seq' "$baseline" >/dev/null 2>&1 &&
        [ ! -e "$journal" ] || fail "Attack #4: enabled agreement did not supersede the removal receipt ($1)"
      # Model a crash after agreement was durable and before journal cleanup.
      cp "$rjj/old-receipt.json" "$journal"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
    }

    if section_part 14; then
      capture_accept_reinstall owner-removes
      capture_owner_remove keeper@test-market
      capture_pass owner-removes-after-agreement
      [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] || fail "Attack #4: stale receipt allowed an install after the owner removed Keeper"
      capture_report claude:keeper@test-market removed
    fi
    if section_part 15; then
      capture_accept_reinstall store-removes
      yq -i '.plugins.keeper.state = "absent"' "$store/fleet/capture-probe.yaml"
      capture_pass store-removes-after-agreement
      [ "$(cat "$CLAUDE_PLUGIN_ACTION_LOG")" = 'uninstall keeper@test-market' ] ||
        fail "Attack #4: stale receipt falsely held an unchanged Keeper as added"
    fi

    printf 'real-jj: OK (silent baseline, guarded local changes, discard, and agreement)\n'
  )
else
  printf 'NOTICE: plugin observation pass fixture requires real jj >= 0.43 and yq\n'
fi
