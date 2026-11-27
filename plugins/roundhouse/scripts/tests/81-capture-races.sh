# roundhouse self-check — Claude changes between capture and destructive apply.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
(
  set -eu
  export PATH="$fleet_fixture_path"
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  race="$tmp/capture-race"
  store="$race/store"
  export ROUNDHOUSE_FLEET_STORE="$store"
  export CLAUDE_CONFIG_DIR="$race/claude"
  export CLAUDE_PLUGIN_LIST_FROM_RECORDS=1
  export CLAUDE_PLUGIN_ENABLED_FILE="$race/enabled.json"
  export CLAUDE_PLUGIN_CATALOG_FILE="$race/catalog.json"
  export CLAUDE_PLUGIN_ACTION_LOG="$race/actions"
  export CLAUDE_INSTALL_MARKER="$race/installs"
  mkdir -p "$store" "$race/pass" "$CLAUDE_CONFIG_DIR/plugins"
  registry="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  absent='{"state":"absent","marketplace":"test-market"}'
  disabled='{"state":"disabled","marketplace":"test-market"}'
  fixture_observed='{"claude":null,"retry":true}'

  fleet_capture_collect() { printf '%s\n' "$fixture_observed"; }
  fleet_run_claude_running() { return 1; }
  fleet_run_claude_desktop_running() { return 1; }
  fleet_run_marketplace_source_ok() { return 0; }

  race_install() {
    jq -c --arg id "$1" --arg sha "$sha" '
      .plugins[$id] = [{scope:"user",version:"1.0.0",gitCommitSha:$sha}]
    ' "$registry" >"$race/registry.next"
    mv "$race/registry.next" "$registry"
  }

  race_prepare() {
    fleet_capture_pass_prepare "$store" mac "$1" true true "$race/pass" "$store"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
  }

  race_deferred() {
    local status=0
    "$@" >"$race/deferred" || status=$?
    [ "$status" -eq 74 ] && [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] ||
      fail "capture race allowed a destructive plugin verb ($1, status $status)"
  }

  for fixture_observed in \
    '{"claude":{"untouched@test-market":{"value":"enabled","user_scope":true}}}' \
    '{"claude":null,"retry":true}'; do
    printf '%s\n' '{"plugins":{}}' >"$registry"
    printf '%s\n' '{}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '%s\n' '{"enabledPlugins":{"untouched@test-market":true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
    race_install untouched@test-market
    race_prepare '{"plugins":{"late":{"state":"absent","marketplace":"test-market"}}}'
    race_install late@test-market
    # The registry proves a late install even when the manager scan was unavailable.
    [ "$(fleet_run_tombstone_target '{}' late "$absent")" = late@test-market ] ||
      fail "the live removal scan did not find the owner install"
    race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
    fleet_run_uninstall_plugin '{}' plugins.untouched untouched "$absent" ||
      fail "the late install prevented a stable unrelated uninstall"
    grep -Fqx 'uninstall untouched@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "the stable unrelated tombstone did not converge"
  done
  printf '%s\n' '{}' >"$CLAUDE_CONFIG_DIR/settings.json"

  # The session decision relied on a cached disabled row during a scan outage.
  # The final read must detect the owner enable even with unchanged disk records.
  (
    fixture_observed='{"claude":null,"retry":true}'
    fleet_run_apply_ctx="$race/stale"
    mkdir -p "$fleet_run_apply_ctx"
    printf '%s\n' '[{"id":"late@test-market","scope":"user","enabled":false}]' >"$fleet_run_apply_ctx/cli.installed"
    printf '%s\n' '{"late@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    race_prepare '{"plugins":{"late":{"state":"absent","marketplace":"test-market"}}}'
    race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
  )

  # Simulate a first pass whose before and after manager scans both failed.
  # The next healthy pass must remember the exact tombstone's pre-verb absence.
  store="$race/retry/store"
  export ROUNDHOUSE_FLEET_STORE="$store"
  mkdir -p "$store"
  printf 'name: mac\n' >"${store%/*}/identity.yaml"
  race_desired='{"plugins":{"late":{"state":"absent","marketplace":"test-market"}}}'
  fixture_observed='{"claude":null,"retry":true}'
  printf '%s\n' '{"plugins":{}}' >"$registry"
  race_prepare "$race_desired"
  race_install late@test-market
  race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
  fleet_capture_rebaseline "$store" mac "$race_desired" "$fixture_observed" true
  race_install stable@test-market
  race_prepare "$race_desired"
  race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
  fleet_run_uninstall_plugin '{}' plugins.stable stable "$absent" ||
    fail "the previous race stopped an unrelated uninstall during a second outage"
  fixture_observed='{"claude":{"late@test-market":{"value":"disabled","user_scope":true}}}'
  race_prepare "$race_desired"
  jq -e 'keys == ["plugins.late"]' <<<"$fleet_capture_skip" >/dev/null ||
    fail "the next healthy scan forgot the late tombstone install"

  # Drop the healthy scan's unpublished fixture alert to exercise discard
  # during the outage, where only the recorded physical ID is available.
  rm -f "$store/alerts/mac/$(fleet_alert_name agent-local-change agent-local-change plugins.late)"
  if fleet_discard_command claude:late@wrong-market >/dev/null 2>&1; then
    fail "a race discard accepted the wrong marketplace"
  fi
  fleet_discard_command plugins.late >/dev/null || fail "could not discard the recorded race"
  jq -e '. == {"claude:late@test-market":true}' "$(fleet_run_state_dir)/agent-discard.json" >/dev/null ||
    fail "a race discard was not bound to the observed physical ID"
  fixture_observed='{"claude":null,"retry":true}'
  race_prepare "$race_desired"
  fleet_run_uninstall_plugin '{}' plugins.late late "$absent" ||
    fail "the explicit discard did not release the raced target during an outage"
  fleet_capture_rebaseline "$store" mac "$race_desired" '{"claude":{}}' true
  jq -e '.["claude:late@test-market"] == {value:"absent"}' "$(fleet_run_state_dir)/agent-baseline.json" >/dev/null ||
    fail "verified agreement did not clear the race evidence"

  race_install claude-example@test-market
  jq -cn --arg sha "$sha" \
    '{available:[{pluginId:"claude-example@test-market",version:"1.0.0",source:{source:"git",sha:$sha}}]}' \
    >"$CLAUDE_PLUGIN_CATALOG_FILE"
  fixture_observed='{"claude":{"claude-example@test-market":{"value":"disabled","user_scope":true}}}'
  race_prepare '{"plugins":{"claude-example":{"state":"disabled","marketplace":"test-market"}}}'
  # The owner enables it after capture without changing the registry or settings.
  printf '%s\n' '{"claude-example@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
  race_deferred fleet_run_apply_item "$store" mac '{}' plugins.claude-example "$disabled" ''
  fleet_run_resolved_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  race_deferred fleet_run_plugin_reinstall claude-example@test-market "$sha"

  # A pass may still disable a plugin that it just installed itself.
  store="$race/fresh/store"
  export ROUNDHOUSE_FLEET_STORE="$store"
  mkdir -p "$store"
  printf '%s\n' '{"plugins":{}}' >"$registry"
  printf '%s\n' '{}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
  fixture_observed='{"claude":{}}'
  race_prepare '{"plugins":{"claude-example":{"state":"disabled","marketplace":"test-market"}}}'
  fleet_run_apply_item "$store" mac '{}' plugins.claude-example "$disabled" '' ||
    fail "the destructive guard rejected a pass's own fresh install"
  grep -Fqx 'disable claude-example@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
    fail "the pass did not disable its own fresh install"
)
fi
