# roundhouse self-check — Codex's own plugin state commands and hook trust.
# shellcheck shell=bash

printf 'apply-codex: native add, toggle, remove and per-host hook trust\n'
(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"
  codex_state_root="$tmp/codex-state-apply"
  codex_state_fixture_init "$codex_state_root"
  export PATH="$codex_state_root/bin:$fleet_fixture_path"
  export CODEX_HOME="$codex_state_root/home" ROUNDHOUSE_FLEET_STORE="$codex_state_root/store"
  export CODEX_STATE_ID=widget.v2@test-market
  export CODEX_STATE_RECORD="$codex_state_root/record" CODEX_STATE_ACTIONS="$codex_state_root/actions"
  export CODEX_STATE_HOOK_TRUST=trusted
  CODEX_STATE_PENDING=$(fleet_agent_pending_path "codex:$CODEX_STATE_ID")
  export CODEX_STATE_PENDING
  printf '%s\n' absent >"$CODEX_STATE_RECORD"

  # The updater must respect a pass holding the lock before it marks or changes anything.
  codex_state_lock=$(fleet_lock_path)
  fleet_lock_acquire "$codex_state_lock"
  codex_state_nonce=$fleet_lock_nonce_held
  status=0
  "$cli" update-codex-plugin "$CODEX_STATE_ID" >"$codex_state_root/locked-updater" 2>&1 || status=$?
  [ "$status" -eq 75 ] && [ ! -e "$CODEX_STATE_PENDING" ] && [ ! -e "$CODEX_STATE_ACTIONS" ] ||
    fail "a concurrent Codex updater ignored the fleet run lock"
  assert_contains "$(cat "$codex_state_root/locked-updater")" 'a fleet run holds'
  fleet_lock_release "$codex_state_lock" "$codex_state_nonce" || fail "the updater changed another run's lock"

  # Refusal to write a marker must leave the harness untouched.
  (
    fleet_agent_pending_mark() { return 1; }
    status=0
    fleet_run_apply_codex "$CODEX_STATE_ID" enabled || status=$?
    [ "$status" -eq 75 ] && [ ! -e "$CODEX_STATE_ACTIONS" ]
  ) || fail "Codex mutated despite a failed pending marker"

  status=0
  CODEX_STATE_HOOK_TRUST=untrusted fleet_run_apply_item "$ROUNDHOUSE_FLEET_STORE" test-host '{}' \
    "codex_plugins.$CODEX_STATE_ID" '{"state":"enabled"}' '[]' \
    >"$codex_state_root/untrusted" 2>&1 || status=$?
  [ "$status" -eq 75 ] || fail "Codex accepted a never-trusted hook after installing"
  assert_contains "$(cat "$codex_state_root/untrusted")" "not approved"
  [ "$(cat "$CODEX_STATE_RECORD")" = enabled ] || fail "Codex did not register the add"
  [ "$(cat "$CODEX_STATE_ACTIONS")" = add ] ||
    fail "Codex wrote settings while refusing the untrusted hook"
  rm "$CODEX_STATE_PENDING"
  fleet_run_apply_codex "$CODEX_STATE_ID" disabled || fail "Codex disable failed"
  [ "$(cat "$CODEX_STATE_RECORD")" = disabled ] || fail "Codex did not save disabled state"
  rm "$CODEX_STATE_PENDING"
  fleet_run_apply_codex "$CODEX_STATE_ID" enabled || fail "Codex enable failed"
  [ "$(cat "$CODEX_STATE_RECORD")" = enabled ] || fail "Codex did not save enabled state"
  rm "$CODEX_STATE_PENDING"

  fleet_run_apply_item "$ROUNDHOUSE_FLEET_STORE" test-host '{}' \
    "codex_plugins.$CODEX_STATE_ID" '{"state":"absent"}' '[]' || fail "Codex remove failed"
  [ "$(cat "$CODEX_STATE_RECORD")" = absent ] || fail "Codex still listed the removed plugin"
  status=0
  fleet_run_apply_codex "$CODEX_STATE_ID" absent || status=$?
  [ "$status" -eq 70 ] || fail "Codex did not recognize a satisfied tombstone"

  printf '%s\n' malformed >"$CODEX_STATE_RECORD"
  status=0
  fleet_run_apply_codex "$CODEX_STATE_ID" enabled || status=$?
  [ "$status" -eq 74 ] || fail "Codex treated a malformed listing as absent"
  [ "$(cat "$CODEX_STATE_ACTIONS")" = "$(printf '%s\n' add disabled enabled remove)" ] ||
    fail "Codex emitted unexpected mutations"

  # A still-populated global list can conceal a sibling loss from scoped apply.
  export CODEX_STATE_SIBLINGS="$codex_state_root/siblings"
  CODEX_STATE_LOST_MARKER=$(fleet_agent_pending_path codex:lost@other-market)
  export CODEX_STATE_DROP_SIBLING=true
  printf '%s\n' '[{"pluginId":"lost@other-market","enabled":true},
    {"pluginId":"healthy@other-market","enabled":false}]' >"$CODEX_STATE_SIBLINGS"
  printf '%s\n' absent >"$CODEX_STATE_RECORD"
  status=0
  fleet_run_apply_codex "$CODEX_STATE_ID" enabled >"$codex_state_root/collateral" 2>&1 || status=$?
  jq -e 'map(.pluginId) == ["healthy@other-market"]' "$CODEX_STATE_SIBLINGS" >/dev/null ||
    fail "the fixture did not remove the sibling registration"
  [ "$status" -eq 74 ] && [ "$(cat "$CODEX_STATE_RECORD")" = enabled ] &&
    [ -f "$CODEX_STATE_LOST_MARKER" ] && [ ! -e "$(fleet_agent_pending_path codex:healthy@other-market)" ] ||
    fail "a Codex add did not retain only the lost sibling's marker"
  assert_contains "$(cat "$codex_state_root/collateral")" 'lost@other-market'

  # The scoped target remains verifiable even if another marketplace breaks the global listing.
  mkdir -p "$CODEX_HOME"
  printf '%s\n' '[plugins."registered@other-market"]' 'enabled = true' >"$CODEX_HOME/config.toml"
  fleet_capture_json_write "$(fleet_instance_path store.run)/agent-baseline.json" \
    '{"codex:baseline-only@other-market":{"value":"enabled"}}'
  CODEX_STATE_GLOBAL_FAILURE=true fleet_run_apply_codex "$CODEX_STATE_ID" absent ||
    fail "an unrelated global listing failure blocked a scoped Codex mutation"
  [ "$(cat "$CODEX_STATE_RECORD")" = absent ] &&
    [ -f "$(fleet_agent_pending_path codex:registered@other-market)" ] &&
    [ -f "$(fleet_agent_pending_path codex:baseline-only@other-market)" ] ||
    fail "scoped Codex apply did not retain both sibling markers"
)
