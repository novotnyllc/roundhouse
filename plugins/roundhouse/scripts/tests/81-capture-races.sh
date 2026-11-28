# roundhouse self-check — Claude changes between capture and apply.
# roundhouse-test: parts=5
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
  enabled='{"state":"enabled","marketplace":"test-market"}'
  desired='{"plugins":{"racer":{"state":"enabled","marketplace":"test-market"}}}'
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

  jq -cn --arg sha "$sha" \
    '{available:[{pluginId:"racer@test-market",version:"2.0.0",source:{source:"git",sha:$sha}}]}' \
    >"$CLAUDE_PLUGIN_CATALOG_FILE"
  for race_case in 2 3 4; do
    if section_part "$race_case"; then
      (
        store="$race/verb-$race_case/store"
        export ROUNDHOUSE_FLEET_STORE="$store"
        mkdir -p "$store"
        printf '%s\n' '{"plugins":{}}' >"$registry"
        printf '{}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
        printf '{}\n' >"$CLAUDE_PLUGIN_ENABLED_FILE"
        fixture_observed='{"trusted":true,"claude":{}}'
        if [ "$race_case" != 4 ]; then
          race_install racer@test-market
          printf '%s\n' '{"racer@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
          fixture_observed='{"trusted":true,"claude":{"racer@test-market":{"value":"enabled","user_scope":true}}}'
          fleet_capture_rebaseline "$store" mac "$desired" "$fixture_observed" true
        fi
        race_prepare "$desired"
        case $race_case in
          2)
            printf '%s\n' '{"plugins":{}}' >"$registry"
            printf '{}\n' >"$CLAUDE_PLUGIN_ENABLED_FILE"
            status=0
            fleet_run_apply_item "$store" mac '{}' plugins.racer "$enabled" '' || status=$?
            [ "$status" -eq 74 ] && [ ! -s "$CLAUDE_PLUGIN_ACTION_LOG" ] ||
              fail "A3 reinstalled a plugin removed after capture (status $status)"
            ;;
          3)
            plugin_cache_seal_permissions() {
              # The refresh changed the bytes, then the owner disabled it.
              printf '%s\n' '{"racer@test-market":false}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
            }
            status=0
            fleet_run_apply_item "$store" mac '{}' plugins.racer "$enabled" '' || status=$?
            [ "$status" -eq 74 ] &&
              [ "$(cat "$CLAUDE_PLUGIN_ACTION_LOG")" = 'update racer@test-market' ] ||
              fail "A3 re-enabled a plugin disabled during its version refresh (status $status)"
            ;;
          4)
            fleet_run_apply_item "$store" mac '{}' plugins.racer "$enabled" '' ||
              fail "A3 rejected its own install followed by enable"
            [ "$(cat "$CLAUDE_PLUGIN_ACTION_LOG")" = $'install racer@test-market\nenable racer@test-market' ] &&
              jq -e '.receipt | .op == "enable" and .installed and .state == "enabled"' \
                "$(fleet_run_state_dir)/agent-journal/claude.racer@test-market" >/dev/null 2>&1 ||
              fail "A3 fresh install followed by enable did not leave a verified enable receipt"
            ;;
        esac
      )
    fi
  done
  if ! section_part 1; then exit 0; fi

  for fixture_observed in \
    '{"trusted":true,"claude":{"untouched@test-market":{"value":"enabled","user_scope":true}}}' \
    '{"claude":null,"retry":true}'; do
    printf '%s\n' '{"plugins":{}}' >"$registry"
    printf '%s\n' '{"untouched@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '%s\n' '{"enabledPlugins":{"untouched@test-market":true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
    race_install untouched@test-market
    race_prepare '{"plugins":{"late":{"state":"absent","marketplace":"test-market"}}}'
    race_install late@test-market
    # The registry proves a late install even when the manager scan was unavailable.
    [ "$(fleet_run_tombstone_target '{}' late "$absent")" = late@test-market ] ||
      fail "the live removal scan did not find the owner install"
    race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
    if jq -e '.trusted == true' >/dev/null <<<"$fixture_observed"; then
      fleet_run_uninstall_plugin '{}' plugins.untouched untouched "$absent" ||
        fail "the late install prevented a stable unrelated uninstall"
      grep -Fqx 'uninstall untouched@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
        fail "the stable unrelated tombstone did not converge"
    else
      race_deferred fleet_run_uninstall_plugin '{}' plugins.untouched untouched "$absent"
    fi
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

  # A trusted pre-scan catches a late install; a later outage keeps that race held.
  store="$race/retry/store"
  export ROUNDHOUSE_FLEET_STORE="$store"
  mkdir -p "$store"
  printf 'name: mac\n' >"${store%/*}/identity.yaml"
  race_desired='{"plugins":{"late":{"state":"absent","marketplace":"test-market"}}}'
  fixture_observed='{"trusted":true,"claude":{}}'
  printf '%s\n' '{"plugins":{}}' >"$registry"
  race_prepare "$race_desired"
  race_install late@test-market
  race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
  fixture_observed='{"claude":null,"retry":true}'
  fleet_capture_rebaseline "$store" mac "$race_desired" "$fixture_observed" true
  race_install stable@test-market
  race_prepare "$race_desired"
  race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
  race_deferred fleet_run_uninstall_plugin '{}' plugins.stable stable "$absent"
  fixture_observed='{"trusted":true,"claude":{"late@test-market":{"value":"disabled","user_scope":true}}}'
  race_prepare "$race_desired"
  jq -e 'keys == ["plugins.late"]' <<<"$fleet_capture_skip" >/dev/null ||
    fail "the next healthy scan forgot the late tombstone install"

  # Drop the healthy scan's unpublished fixture alert to exercise discard
  # during the outage, where only the recorded physical ID is available.
  rm -f "$store/alerts/mac/$(fleet_alert_name agent-local-change agent-local-change plugins.late)"
  discard_status=0
  fleet_discard_command claude:late@wrong-market >/dev/null 2>&1 || discard_status=$?
  [ "$discard_status" -eq 65 ] || fail "a race discard did not reject the wrong marketplace"
  [ ! -e "$(fleet_lock_path)" ] || fail "the rejected discard did not release the run lock"
  printf '%s\n' '{"late@test-market":false}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
  fleet_discard_command plugins.late >/dev/null || fail "could not discard the recorded race"
  jq -e 'keys == ["claude:late@test-market"] and (."claude:late@test-market" |
    .id == "claude:late@test-market" and .observed == {installed:true,state:"disabled"} and
    (.seq | type == "number"))' "$(fleet_run_state_dir)/agent-discard.json" >/dev/null ||
    fail "a race discard was not bound to the observed physical ID and state"
  fixture_observed='{"claude":null,"retry":true}'
  race_prepare "$race_desired"
  race_deferred fleet_run_uninstall_plugin '{}' plugins.late late "$absent"
  fixture_observed='{"trusted":true,"claude":{"late@test-market":{"value":"disabled","user_scope":true}}}'
  race_prepare "$race_desired"
  fleet_run_uninstall_plugin '{}' plugins.late late "$absent" ||
    fail "the explicit discard did not release the raced target with trusted inventory"
  fleet_capture_rebaseline "$store" mac "$race_desired" '{"trusted":true,"claude":{}}' true
  jq -e '."claude:late@test-market" | .value == "absent" and .raced == null and
    (.seq | type == "number")' "$(fleet_run_state_dir)/agent-baseline.json" >/dev/null ||
    fail "verified agreement did not clear the race evidence"

  race_install claude-example@test-market
  jq -cn --arg sha "$sha" \
    '{available:[{pluginId:"claude-example@test-market",version:"1.0.0",source:{source:"git",sha:$sha}}]}' \
    >"$CLAUDE_PLUGIN_CATALOG_FILE"
  fixture_observed='{"trusted":true,"claude":{"claude-example@test-market":{"value":"disabled","user_scope":true}}}'
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
  # A fresh install starts enabled, so the requested disable must really run.
  printf '%s\n' '{"claude-example@test-market":true}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
  fixture_observed='{"trusted":true,"claude":{}}'
  race_prepare '{"plugins":{"claude-example":{"state":"disabled","marketplace":"test-market"}}}'
  fleet_run_apply_item "$store" mac '{}' plugins.claude-example "$disabled" '' ||
    fail "the destructive guard rejected a pass's own fresh install"
  grep -Fqx 'disable claude-example@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
    fail "the pass did not disable its own fresh install"
)
fi

# The lock protects a bounded manager after both the standalone shell and its group die.
if [ -n "$fleet_fixture_yq" ] && section_part 5; then
  (
    set -eu
    export PATH="$fleet_fixture_path"
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    lock_fixture="$tmp/capture-mutator"
    export ROUNDHOUSE_FLEET_STORE="$lock_fixture/store"
    export CLAUDE_CONFIG_DIR="$lock_fixture/claude"
    export CLAUDE_PLUGIN_LIST_FROM_RECORDS=1
    export CLAUDE_PLUGIN_ENABLED_FILE="$lock_fixture/enabled.json"
    export CAPTURE_MUTATOR_READY="$lock_fixture/ready"
    export CAPTURE_MUTATOR_CLI
    CAPTURE_MUTATOR_CLI=$(command -v claude)
    mkdir -p "$ROUNDHOUSE_FLEET_STORE/hosts" "$CLAUDE_CONFIG_DIR/plugins" "$lock_fixture/bin"
    printf 'name: mac\n' >"$lock_fixture/identity.yaml"
    printf '%s\n' 'plugins:' '  demo: {state: absent, marketplace: test-market}' >"$ROUNDHOUSE_FLEET_STORE/fleet.yaml"
    printf 'platform: macos\n' >"$ROUNDHOUSE_FLEET_STORE/hosts/mac.yaml"
    printf '%s\n' '{"plugins":{"demo@test-market":[{"scope":"user","version":"1.0.0"}]}}' \
      >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    printf '%s\n' '{"enabledPlugins":{"demo@test-market":false}}' >"$CLAUDE_CONFIG_DIR/settings.json"
    printf '%s\n' '{"demo@test-market":false}' >"$CLAUDE_PLUGIN_ENABLED_FILE"
    cat >"$lock_fixture/bin/claude" <<'SH'
#!/bin/bash
if [ "$*" = 'plugin uninstall --scope user --keep-data demo@test-market' ]; then
  printf '%s\n' "$$" >"$CAPTURE_MUTATOR_READY"
  exec sleep 20
fi
exec "$CAPTURE_MUTATOR_CLI" "$@"
SH
    chmod +x "$lock_fixture/bin/claude"
    export PATH="$lock_fixture/bin:$PATH"
    lock=$(fleet_lock_path)
    mkdir -p "$(fleet_run_state_dir)"
    printf '%s\n' '{"claude:demo@test-market":{"value":"disabled","seq":0}}' \
      >"$(fleet_run_state_dir)/agent-baseline.json"
    "$cli" fleet-review plugins.demo pass 'fixture mutation' >/dev/null
    # A private session gives fleet-apply no tty without making it a group leader.
    perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!";
      my $pid = fork(); die "fork: $!" unless defined $pid;
      if (!$pid) { exec @ARGV; die "exec: $!"; }
      waitpid($pid, 0); exit($? >> 8)' "$cli" fleet-apply plugins.demo \
      >"$lock_fixture/apply.log" 2>&1 </dev/null &
    launcher=$!
    native=
    trap 'if [ -n "$native" ]; then kill "$native" 2>/dev/null || :; fi
      kill "$launcher" 2>/dev/null || :' EXIT
    for ((attempt=0; attempt<200; attempt++)); do
      [ ! -s "$CAPTURE_MUTATOR_READY" ] || break
      kill -0 "$launcher" 2>/dev/null || break
      sleep 0.05
    done
    if [ ! -s "$CAPTURE_MUTATOR_READY" ]; then
      cat "$lock_fixture/apply.log" >&2
      fail "standalone fleet-apply did not start the bounded mutator"
    fi
    native=$(cat "$CAPTURE_MUTATOR_READY")
    holder=$(jq -er .pid "$lock/meta.json")
    group=$(fleet_lock_proc_pgid "$holder")
    native_group=$(fleet_lock_proc_pgid "$native")
    [ -n "$group" ] && [ -n "$native_group" ] && [ "$native_group" != "$group" ] ||
      fail "the bounded mutator did not start in a separate process group"
    kill -KILL "$holder"
    for ((attempt=0; attempt<100; attempt++)); do
      [ -n "$(fleet_lock_proc_start "$holder")" ] || break
      sleep 0.05
    done
    fleet_lock_holder_state "$lock"
    [ "$fleet_lock_state" = live ] ||
      fail "standalone lock was $fleet_lock_state after its recorded PID died with a live mutator"
    lock_rc=0
    fleet_run_lock_take "$ROUNDHOUSE_FLEET_STORE" mac "$lock" || lock_rc=$?
    [ "$lock_rc" -eq 10 ] || fail "fleet-run lock take after holder death returned $lock_rc (expected 10)"
    [ "$group" = "$holder" ] && [ "$group" != "$(fleet_lock_proc_pgid "$$")" ] ||
      fail "standalone fleet-apply did not lead a private process group"
    jq -e --argjson pid "$native" --argjson pgid "$native_group" \
      '.mutator.pid == $pid and .mutator.pgid == $pgid' "$lock/meta.json" >/dev/null ||
      fail "the lock did not record the bounded mutator PID and PGID"
    kill -KILL -- "-$group"
    for ((attempt=0; attempt<100; attempt++)); do
      [ "$(fleet_lock_group_state "$group")" != live ] && break
      sleep 0.05
    done
    [ "$(fleet_lock_group_state "$group")" = empty ] && [ -n "$(fleet_lock_proc_start "$native")" ] ||
      fail "the recorded group did not die independently of the bounded mutator"
    fleet_lock_holder_state "$lock"
    [ "$fleet_lock_state" = live ] ||
      fail "standalone lock was $fleet_lock_state after its group died with a live mutator"
    lock_rc=0
    fleet_run_lock_take "$ROUNDHOUSE_FLEET_STORE" mac "$lock" || lock_rc=$?
    [ "$lock_rc" -eq 10 ] || fail "fleet-run lock take after group death returned $lock_rc (expected 10)"
    (
      ps() { return 1; }
      fleet_lock_holder_state "$lock"
      [ "$fleet_lock_state" = live ] ||
        fail "a denied process inspection hid the reachable bounded mutator"
    )
    kill -TERM "$native"
    for ((attempt=0; attempt<100; attempt++)); do
      [ -n "$(fleet_lock_proc_start "$native")" ] || break
      sleep 0.05
    done
    native=
    fleet_lock_holder_state "$lock"
    [ "$fleet_lock_state" = dead ] ||
      fail "standalone lock was $fleet_lock_state after the holder, group and mutator exited"
    lock_rc=0
    fleet_lock_take "$lock" 86400 || lock_rc=$?
    [ "$lock_rc" -eq 11 ] || fail "dead standalone lock takeover returned $lock_rc (expected 11)"
    fleet_lock_release "$lock" "$fleet_lock_nonce_held"
  )
fi
