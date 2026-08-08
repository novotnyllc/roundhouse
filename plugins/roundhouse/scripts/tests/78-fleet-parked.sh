# roundhouse self-check — the parked survivors of the v1 sync subsystem.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

# --- parked fleet-store predicates ---

# These predicates outlived the subsystem that called them and have no command
# wired to them yet, so the only thing keeping them honest until the v2 store
# lands is this section. Each assertion below cost a review round to find.
(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  for parked_url in 'https://example.invalid/fleet-store.git' \
      'ssh://fleet.invalid/store.git' 'git@fleet.invalid:novotnyllc/fleet-store.git' \
      '/srv/fleet-store' 'file:///srv/fleet-store'; do
    fleet_validate_fetch_url "$parked_url" ||
      fail "parked fleet_validate_fetch_url rejected a supported URL: $parked_url"
  done
  # Option-looking, whitespace-bearing, credential-bearing, and alternate
  # transports never reach git as an argument.
  for parked_url in '' '--upload-pack=touch /tmp/pwn' '-o ProxyCommand=x' \
      'ext::sh -c touch% /tmp/pwn' 'https://user:token@example.invalid/store.git' \
      'https://example.invalid/store.git --upload-pack=x' \
      'ssh://fleet.invalid/store.git?x=1'; do
    ! fleet_validate_fetch_url "$parked_url" ||
      fail "parked fleet_validate_fetch_url accepted a hostile URL: $parked_url"
  done

  for parked_secret in '-----BEGIN OPENSSH PRIVATE KEY-----' \
      'token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc' \
      'use ghp_abcdefghijklmnopqrstuvwxyz0123' \
      'export KEY=sk-abcdefghijklmnop0123' \
      'aws AKIAIOSFODNN7EXAMPLE key' \
      'blob aGVsbG9Xb3JsZDEyMzQ1Njc4OTBhYmNkZWY='; do
    fleet_quote_is_secret "$parked_secret" ||
      fail "parked fleet_quote_is_secret missed a secret class: $parked_secret"
  done
  for parked_clear in 'the plugin update landed cleanly on mac-mini' \
      'held: this diff argues for its own approval'; do
    ! fleet_quote_is_secret "$parked_clear" ||
      fail "parked fleet_quote_is_secret flagged ordinary text: $parked_clear"
  done

  # A .pub comment is free text and must never survive into a signers entry,
  # where it would be parsed as a principal.
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI0000000000000000000000000000000000000000000 * cert-authority evil\n' \
    >"$tmp/parked-signer.pub"
  [ "$(fleet_signer_entry "$tmp/parked-signer.pub")" = \
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI0000000000000000000000000000000000000000000' ] ||
    fail "parked fleet_signer_entry carried the .pub comment into a signers entry"

  # Test-gated hooks are inert without the suite's own kill-switch. $TRUST is
  # where allowed_signers, reviewed-ref, generation and the KRL live, so
  # relocating it IS relocating the trust root.
  mkdir -p "$tmp/parked-trust"
  ROUNDHOUSE_TRUST_ROOT="$tmp/parked-trust" fleet_trust_root |
    grep -Fqx "$tmp/parked-trust" ||
    fail "parked fleet_trust_root ignored the test hook under ROUNDHOUSE_SELFTEST"
  (
    unset ROUNDHOUSE_SELFTEST
    ROUNDHOUSE_TRUST_ROOT="$tmp/parked-trust" fleet_trust_root |
      grep -Fqxv "$tmp/parked-trust"
  ) || fail "parked fleet_trust_root relocated the trust root without ROUNDHOUSE_SELFTEST"

  # An allowed key that intersects an excluded namespace in either direction is
  # a collision; disjoint keys are not.
  jq -n '{allowed:["ui.theme","hooks.state.a.enabled"],excluded_namespaces:["hooks"]}' \
    >"$tmp/parked-allowlist.json"
  [ "$(jq "$fleet_allowed_paths_filter"'excluded_collisions | length' \
    "$tmp/parked-allowlist.json")" -eq 1 ] ||
    fail "parked fleet_allowed_paths_filter missed an excluded-namespace collision"
  jq -n '{allowed:["ui.theme"],excluded_namespaces:["hooks"]}' >"$tmp/parked-allowlist.json"
  [ "$(jq "$fleet_allowed_paths_filter"'excluded_collisions | length' \
    "$tmp/parked-allowlist.json")" -eq 0 ] ||
    fail "parked fleet_allowed_paths_filter invented an excluded-namespace collision"
)

# The v1 command surface is gone from the entrypoint, not merely undocumented:
# a resurrected `sync-*` case would make the doctrine text above a lie.
! grep -qE '^  sync-[a-z-]+\)' "$cli" ||
  fail "the CLI still dispatches a v1 sync-* command"

# Deleting the `.sync` validation block must not turn every enrolled host's
# live config.json into an invalid one: the key is unvalidated now, not
# forbidden, until the v2 host-local files replace it.
jq -n '{version:1,machines:{"parked-host":{platform:"macos",transport:"local",
  groups:["development"]}},
  sync:{enabled:true,remote:{url:"ssh://fleet.invalid/store.git"},
    cadence_hours:12,canary_group:"canary",canary_wait_hours:24}}' \
  >"$tmp/parked-legacy-sync-config.json"
ROUNDHOUSE_CONFIG="$tmp/parked-legacy-sync-config.json" "$cli" validate-config ||
  fail "a config still carrying the v1 .sync block no longer validates"
