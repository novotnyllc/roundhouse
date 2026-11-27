# roundhouse self-check — Claude journal, agreement, and report regressions.
# roundhouse-test: parts=5
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  (
    set -eu
    export PATH="$fleet_fixture_path"
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    capture_root="$tmp/capture-repairs"
    store="$capture_root/store"
    export ROUNDHOUSE_FLEET_STORE="$store" CLAUDE_CONFIG_DIR="$capture_root/claude"
    mkdir -p "$store" "$CLAUDE_CONFIG_DIR/plugins" "$capture_root/pass"
    state_dir=$(fleet_run_state_dir)
    mkdir -p "$state_dir"
    baseline="$state_dir/agent-baseline.json"

    if section_part 1; then
      (
        fleet_capture_observed='{"trusted":true}'
        printf '%s\n' '{"plugins":{"claude-example@test-market":[{"scope":"user"}]}}' \
          >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
        printf '%s\n' '{"type":"agent-update","kind":"agent_artifact",
          "id":"claude:test-market:claude-example:user",
          "argv":["claude","plugin","update","claude-example@test-market","--scope","user"]}' \
          >"$capture_root/update.json"
        execute_plan_operation "$capture_root/update.json" /dev/null mac
        id=claude:claude-example@test-market
        journal=$(fleet_agent_journal_path "$id")
        [ ! -e "$journal" ] || fail "A2 completed standalone update left a state receipt"

        desired='{"plugins":{"claude-example":{"state":"disabled","marketplace":"test-market"}}}'
        observed='{"trusted":true,"claude":{"claude-example@test-market":{"value":"enabled"}}}'
        printf '%s\n' '{"claude:claude-example@test-market":{"value":"disabled"}}' >"$baseline"
        claude_home=$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)
        fleet_capture_json_write "$journal" "$(jq -cn --arg id "$id" --arg home "$claude_home" '
          {id:$id,home:$home,intent:{op:"uninstall",to:"absent",from:{installed:true,state:"disabled"},
            op_id:"interrupted",pid:1,start:"interrupted",seq:1}}')"
        fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
        jq -e 'has("plugins.claude-example")' <<<"$fleet_capture_skip" >/dev/null ||
          fail "A2 an interrupted uninstall intent masked the owner's enable"
        rm -f "$journal"
        sibling=claude:claude-example@other-market
        sibling_journal=$(fleet_agent_journal_path "$sibling")
        fleet_capture_json_write "$sibling_journal" "$(jq -cn --arg id "$sibling" --arg home "$claude_home" '
          {id:$id,home:$home,receipt:{installed:true,state:"enabled",seq:1,op:"enable"}}')"
        fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
        jq -e 'has("plugins.claude-example")' <<<"$fleet_capture_skip" >/dev/null ||
          fail "A2 a receipt for a same-name plugin masked the owner's enable"

        # The native verb fixtures below supply their own per-item state.
        fleet_capture_observed=$observed
        interrupted=0
        (
          fleet_run_plugin_market() { printf 'm\n'; }
          fleet_run_marketplace_source_ok() { :; }
          fleet_run_plugin_catalog_proven() {
            printf '%s\n' '{"source":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
          }
          fleet_run_installed_plugins() {
            if [ -e "$capture_root/fresh-installed" ]; then
              printf '%s\n' '{"fresh@m":[{"scope":"user","gitCommitSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
            else
              printf '{}\n'
            fi
          }
          fleet_run_plugin_enabled() {
            if [ -e "$capture_root/fresh-installed" ]; then printf 'true\n'
            else printf 'unknown\n'; fi
          }
          bounded_verb() {
            case $3 in
              install) : >"$capture_root/fresh-installed" ;;
              disable) exit 42 ;;
              *) exit 1 ;;
            esac
          }
          fleet_run_apply_item "$store" mac '{}' plugins.fresh '"disabled"' '{}'
        ) || interrupted=$?
        [ "$interrupted" = 42 ] || fail "A2 fixture did not interrupt the install before it disabled"
        fresh_journal=$(fleet_agent_journal_path claude:fresh@m)
        jq -e '.receipt.installed == true and .receipt.state == "enabled" and
          .receipt.op == "install" and .intent.op == "disable"' "$fresh_journal" >/dev/null ||
          fail "A2 an interrupted disable erased the verified install or lost its intent"
        jq '.["claude:fresh@m"] = {value:"absent"}' "$baseline" >"$baseline.next"
        mv "$baseline.next" "$baseline"
        fleet_capture_prepare "$store" mac '{"plugins":{"fresh":{"state":"disabled","marketplace":"m"}}}' \
          '{"trusted":true,"claude":{"fresh@m":{"value":"enabled"}}}' true true "$capture_root/pass"
        jq -e 'has("plugins.fresh")' <<<"$fleet_capture_skip" >/dev/null ||
          fail "A2 an interrupted disable did not hold the installed plugin"

        (
          fleet_run_claude_running() { return 1; }
          fleet_run_claude_desktop_running() { return 1; }
          : >"$capture_root/example-installed"
          fleet_run_installed_plugins() {
            if [ -e "$capture_root/example-installed" ]; then
              printf '%s\n' '{"claude-example@test-market":[{"scope":"user","gitCommitSha":"previous"}]}'
            else printf '{}\n'; fi
          }
          fleet_run_plugin_enabled() {
            if [ -e "$capture_root/example-installed" ]; then printf 'false\n'
            else printf 'unknown\n'; fi
          }
          bounded_query() { printf '{"configured":[]}\n'; }
          bounded_verb() { [ "$3" = uninstall ] && rm -f "$capture_root/example-installed"; }
          fleet_run_resolved_sha=fixture
          rc=0
          fleet_run_plugin_reinstall claude-example@test-market previous || rc=$?
          [ "$rc" = 74 ] || fail "A2 fixture did not report an install failure after uninstall"
          fleet_capture_prepare "$store" mac "$desired" \
            '{"trusted":true,"claude":{"anchor@m":{"value":"enabled"}}}' true true "$capture_root/pass"
          jq -e 'has("plugins.claude-example") | not' <<<"$fleet_capture_skip" >/dev/null ||
            fail "A2 failed reinstall was mistaken for an owner removal"
          fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
          jq -e 'has("plugins.claude-example")' <<<"$fleet_capture_skip" >/dev/null ||
            fail "A2 failed reinstall masked the owner's later install"
        )

      )
    fi

    if section_part 2; then
      rm -f "$baseline"
      desired='{"plugins":{"keeper":{"state":"enabled","marketplace":"m"}}}'
      observed='{"trusted":true,"claude":{"keeper@m":{"value":"enabled"},"stale@m":{"value":"unknown"}}}'
      fleet_capture_rebaseline "$store" mac "$desired" "$observed" true
      jq -e '.["claude:keeper@m"].value == "enabled"' "$baseline" >/dev/null ||
        fail "A3 the healthy item did not record agreement"
      jq '._initialized.claude = false' "$baseline" >"$baseline.next"
      mv "$baseline.next" "$baseline"
      observed=$(jq -c '.claude["keeper@m"].value = "disabled"' <<<"$observed")
      fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
      jq -e 'has("plugins.keeper")' <<<"$fleet_capture_skip" >/dev/null ||
        fail "A3 an unrelated stale settings key masked the owner's disable"
    fi

    if section_part 3; then
      desired='{"plugins":{"bad":{"state":{"invalid":true},"marketplace":"m"},
        "later":{"state":"absent","marketplace":"m"}}}'
      observed='{"trusted":true,"claude":{"later@m":{"value":"disabled"}}}'
      printf '%s\n' '{"claude:later@m":{"value":"absent"}}' >"$baseline"
      fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
      jq -e 'keys == ["plugins.bad","plugins.later"]' <<<"$fleet_capture_skip" >/dev/null ||
        fail "A5 malformed desired state dropped the later owner's install hold"
    fi

    if section_part 4; then
      rm -f "$baseline"
      fleet_capture_before_observed=$(jq -cn '
        {trusted:true,claude:[range(0;12) | {key:("existing-fixture-plugin-number-" + tostring + "@test-market"),
          value:{value:"enabled"}}] | from_entries}')
      fleet_capture_retry_unknown=false
      fleet_capture_before_fingerprint=fixture
      fleet_capture_collect() { printf '%s\n' "$fleet_capture_before_observed"; }
      log=$(fleet_capture_pass_observe_after "$store" mac "$capture_root/pass" '{}' "$store") ||
        fail "A7 a long list prevented recording the ignored plugins alert"
      assert_contains "$log" 'claude:existing-fixture-plugin-number-0@test-market'
      assert_contains "$log" 'claude:existing-fixture-plugin-number-11@test-market'
      alert="$store/alerts/mac/agent-capture-ignored.yaml"
      jq -e '.detail | test("12") and length < 400' <<<"$(yq -o=json "$alert")" >/dev/null ||
        fail "A7 ignored extras alert was missing or unbounded"

      # Qualified hold reports stay bounded while local output keeps the identity.
      long_name=$(printf '%080d' 0 | tr 0 n)
      for market_length in 70 350; do
        long_market=$(printf "%0${market_length}d" 0 | tr 0 m)
        long_id="$long_name@$long_market"
        printf '%s\n' '{"_initialized":{"claude":true}}' >"$baseline"
        desired=$(jq -cn --arg name "$long_name" '{plugins:{($name):{state:"enabled",marketplace:"m"}}}')
        observed=$(jq -cn --arg id "$long_id" '{trusted:true,claude:{($id):{value:"enabled",user_scope:true}}}')
        fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass" \
          >"$capture_root/long-report"
        assert_contains "$(cat "$capture_root/long-report")" "claude:$long_id added locally"
        alert="$store/alerts/mac/$(fleet_alert_name agent-local-change agent-local-change "plugins.$long_id")"
        yq -o=json "$alert" | jq -e '.detail | utf8bytelength <= 400' >/dev/null ||
          fail "A7 a qualified local change exceeded the alert bound"
        (
          fleet_run_env() { :; }
          fleet_host_name() { printf 'mac\n'; }
          fleet_store_path() { printf '%s\n' "$store"; }
          fleet_lock_path() { printf '%s\n' "$capture_root/discard.lock"; }
          fleet_run_stale_after() { printf '600\n'; }
          fleet_discard_command "claude:$long_id" >/dev/null
        ) || fail "A7 a bounded qualified report could not be discarded"
      done

      (
        fleet_run_env() { :; }
        fleet_host_name() { printf 'mac\n'; }
        fleet_store_path() { printf '%s\n' "$store"; }
        fleet_lock_path() { printf '%s\n' "$capture_root/discard.lock"; }
        fleet_run_stale_after() { printf '600\n'; }
        fleet_alert_write "$store" mac agent-local-change agent-local-change \
          'claude:foo@m added locally' plugins.foo@m
        rm -f "$state_dir/agent-discard.json"
        status=0
        fleet_discard_command claude:plugins.foo@m >/dev/null 2>&1 || status=$?
        [ "$status" = 65 ] && [ ! -e "$state_dir/agent-discard.json" ] ||
          fail "discard stripped a second prefix and authorized another plugin"
        [ ! -e "$(fleet_lock_path)" ] || fail "rejected discard leaked its run lock"
        fleet_alert_write "$store" mac agent-local-change agent-local-change \
          'claude:plugins.foo@m added locally' plugins.plugins.foo@m
        for item in claude:plugins.foo@m plugins.plugins.foo@m; do
          fleet_discard_command "$item" >/dev/null || fail "discard rejected a plugins.-prefixed name"
          jq -e '. == {"claude:plugins.foo@m":true}' "$state_dir/agent-discard.json" >/dev/null ||
            fail "discard did not preserve the plugin name's own prefix"
        done
      )
    fi

    if section_part 5; then
      export CLAUDE_PLUGIN_ACTION_LOG="$capture_root/actions"
      : >"$CLAUDE_PLUGIN_ACTION_LOG"
      : >"$capture_root/owned"
      fleet_run_installed_plugins() { printf '%s\n' '{"claude-example@test-market":[{"scope":"user"}]}'; }
      fleet_run_plugin_identity_matches() { [ -s "$CLAUDE_PLUGIN_ACTION_LOG" ]; }
      fleet_capture_observed='{"claude":null,"trusted":false}'
      fleet_capture_prepare "$store" mac '{}' "$fleet_capture_observed" true true "$capture_root/pass"
      rc=0
      fleet_plugins_claude_update_unowned '{}' test-market "$capture_root/owned" || rc=$?
      [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] ||
        fail "A6 unavailable Claude inventory allowed an unowned version update"
      [ "$rc" = 74 ] || fail "A6 deferring an unowned version update did not leave retry debt"
    fi
  )
fi
