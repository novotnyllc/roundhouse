# roundhouse self-check — Claude marker, agreement, and report regressions.
# roundhouse-test: parts=4
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
    mkdir -p "$store" "$CLAUDE_CONFIG_DIR" "$capture_root/pass"
    state_dir=$(fleet_run_state_dir)
    mkdir -p "$state_dir"
    baseline="$state_dir/agent-baseline.json"

    if section_part 1; then
      (
        printf '%s\n' '{"type":"agent-update","kind":"agent_artifact",
          "id":"claude:test-market:claude-example:user",
          "argv":["claude","plugin","update","claude-example@test-market","--scope","user"]}' \
          >"$capture_root/update.json"
        execute_plan_operation "$capture_root/update.json" /dev/null mac
        id=claude:claude-example@test-market
        marker=$(fleet_agent_pending_path "$id")
        [ ! -e "$marker" ] || fail "A2 completed standalone update left a state marker"

        desired='{"plugins":{"claude-example":{"state":"disabled","marketplace":"test-market"}}}'
        observed='{"claude":{"claude-example@test-market":{"value":"enabled"}}}'
        printf '%s\n' '{"claude:claude-example@test-market":{"value":"disabled"}}' >"$baseline"
        fleet_agent_pending_mark claude claude-example@test-market disabled absent
        fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
        jq -e 'has("plugins.claude-example")' <<<"$fleet_capture_skip" >/dev/null ||
          fail "A2 an interrupted uninstall marker masked the owner's enable"
        fleet_agent_pending_mark claude claude-example@test-market absent enabled
        fleet_capture_mark_claude claude-example disabled enabled
        fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
        jq -e 'has("plugins.claude-example")' <<<"$fleet_capture_skip" >/dev/null ||
          fail "A2 a wrong origin or unqualified marker masked the owner's enable"

        export CLAUDE_PLUGIN_ACTION_LOG="$capture_root/actions"
        : >"$capture_root/owned"
        fleet_run_installed_plugins() { printf '%s\n' '{"claude-example@test-market":[{"scope":"user"}]}'; }
        fleet_run_plugin_identity_matches() { [ -s "$CLAUDE_PLUGIN_ACTION_LOG" ]; }
        rm -f "$baseline" "$marker" "$(fleet_agent_pending_path claude:claude-example@__unqualified__)"
        fleet_capture_observed='{"claude":null}'
        fleet_capture_prepare "$store" mac '{}' "$fleet_capture_observed" true true "$capture_root/pass"
        fleet_plugins_claude_update_unowned '{}' test-market "$capture_root/owned" ||
          fail "A6 a globally unavailable observation blocked an unowned version update"
        grep -Fqx 'update claude-example@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
          fail "A6 a globally unavailable observation silently skipped version convergence"
      )
    fi

    if section_part 2; then
      rm -f "$baseline"
      desired='{"plugins":{"keeper":{"state":"enabled","marketplace":"m"}}}'
      observed='{"claude":{"keeper@m":{"value":"enabled"},"stale@m":{"value":"unknown"}}}'
      fleet_capture_rebaseline "$store" mac "$desired" "$observed" true
      jq -e '.["claude:keeper@m"].value == "enabled"' "$baseline" >/dev/null ||
        fail "A3 the healthy item did not record agreement"
      observed=$(jq -c '.claude["keeper@m"].value = "disabled"' <<<"$observed")
      fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
      jq -e 'has("plugins.keeper")' <<<"$fleet_capture_skip" >/dev/null ||
        fail "A3 an unrelated stale settings key masked the owner's disable"
    fi

    if section_part 3; then
      desired='{"plugins":{"bad":{"state":{"invalid":true},"marketplace":"m"},
        "later":{"state":"absent","marketplace":"m"}}}'
      observed='{"claude":{"later@m":{"value":"disabled"}}}'
      printf '%s\n' '{"claude:later@m":{"value":"absent"}}' >"$baseline"
      fleet_capture_prepare "$store" mac "$desired" "$observed" true true "$capture_root/pass"
      jq -e 'keys == ["plugins.bad","plugins.later"]' <<<"$fleet_capture_skip" >/dev/null ||
        fail "A5 malformed desired state dropped the later owner's install hold"
    fi

    if section_part 4; then
      rm -f "$baseline"
      fleet_capture_before_observed=$(jq -cn '
        {claude:[range(0;12) | {key:("existing-fixture-plugin-number-" + tostring + "@test-market"),
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
    fi
  )
fi
