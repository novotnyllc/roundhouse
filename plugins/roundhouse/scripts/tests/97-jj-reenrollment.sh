# roundhouse self-check — re-enrollment over a live-shaped SSH lane.
#
# Sourced by scripts/test-roundhouse in a fixed order; not standalone.
# shellcheck shell=bash

if [ "$real_jj_ok" != true ]; then
  printf 'NOTICE: real-jj re-enrollment fixture skipped\n'
else
  printf 'real-jj: retire, re-add, bootstrap, verify, and run\n'
  (
    set -eu
    # The fixture calls the same library predicates as the live CLI path.
    # Source the command in library-only mode before inspecting the hub store.
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    fail() {
      printf 'FAIL: real-jj: %s\n' "$*" >&2
      exit 1
    }

    reenroll_root="$tmp/reenrollment"
    hub_home="$reenroll_root/hub"
    node_home="$reenroll_root/mac-studio"
    hub_store="$hub_home/.config/roundhouse/store"
    hub_remote="$reenroll_root/hub.git"
    node_store="$node_home/.config/roundhouse-custom/store"
    node_identity="$node_home/.config/roundhouse-custom/identity.yaml"
    mkdir -p "$hub_home/.config/roundhouse" "$hub_home/.ssh" \
      "$node_home/.config/roundhouse" "$node_home/.ssh"
    # A login profile may enable failglob. The remote CLI resolver must still
    # skip the absent Claude cache and select the valid Codex cache.
    printf '%s\n' 'shopt -s failglob' >"$node_home/.bash_profile"

    # The fake SSH transport executes the exact remote shell produced by
    # ssh_run, but keeps the two host-local roots disjoint. It also gives the
    # second probe the observed live failure: no answer over the SSH lane.
    cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -eu
reenroll_remote_command=
for reenroll_arg; do
  reenroll_remote_command=$reenroll_arg
done
export HOME="$ROUNDHOUSE_REENROLL_NODE_HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export ROUNDHOUSE_CONFIG="$HOME/.config/roundhouse/config.json"
     export ROUNDHOUSE_FLEET_STORE="$HOME/.config/roundhouse-custom/store"
export ROUNDHOUSE_FLEET_SIGNING_KEY="$HOME/.ssh/roundhouse_node_ed25519"
export ROUNDHOUSE_TRUST_ROOT="$HOME/.config/roundhouse"
export PATH="$ROUNDHOUSE_REENROLL_NODE_BIN:$PATH"
export SHELL=/bin/bash
case "$reenroll_remote_command" in
  *fleet-verify-remote*)
    export ROUNDHOUSE_FLEET_VISIBILITY_PROBE='exit 1'
    ;;
  *)
    export ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf Authentication >&2; exit 1'
    ;;
esac
if [ -n "${ROUNDHOUSE_REENROLL_SSH_LOG:-}" ]; then
  set +e
  /bin/bash -c "$reenroll_remote_command" 2>>"$ROUNDHOUSE_REENROLL_SSH_LOG"
  reenroll_status=$?
  set -e
  printf 'fake-ssh-exit=%s\n' "$reenroll_status" >>"$ROUNDHOUSE_REENROLL_SSH_LOG"
  exit "$reenroll_status"
fi
exec /bin/bash -c "$reenroll_remote_command"
SH
    chmod 755 "$tmp/bin/ssh"

    # The remote prologue must resolve this cache copy, not a command on the
    # sponsor's PATH. The wrapper is only transport plumbing; the bytes are the
    # candidate CLI under test.
    node_bin="$node_home/.codex/plugins/cache/test/roundhouse/0.7.5/scripts"
    mkdir -p "$node_bin"
    cat >"$node_bin/roundhouse" <<'SH'
#!/usr/bin/env bash
exec "$ROUNDHOUSE_REENROLL_CLI" "$@"
SH
    chmod 755 "$node_bin/roundhouse"

    PATH="$(dirname "$real_jj"):$(dirname "$real_yq"):$tmp/bin:$PATH"
    export PATH
    export HOME="$hub_home"
    export XDG_CONFIG_HOME="$hub_home/.config"
    export ROUNDHOUSE_CONFIG="$reenroll_root/config.json"
    export ROUNDHOUSE_FLEET_STORE="$hub_store"
    export ROUNDHOUSE_FLEET_SIGNING_KEY="$hub_home/.ssh/roundhouse_node_ed25519"
    export ROUNDHOUSE_TRUST_ROOT="$hub_home/.config/roundhouse"
    export ROUNDHOUSE_SELFTEST=1
    export ROUNDHOUSE_REENROLL_CLI="$cli"
    export ROUNDHOUSE_REENROLL_NODE_HOME="$node_home"
    export ROUNDHOUSE_REENROLL_NODE_BIN="$(dirname "$real_jj"):$tmp/bin:/usr/bin:/bin"
    reenroll_ssh_log="$reenroll_root/ssh.stderr"
    export ROUNDHOUSE_REENROLL_SSH_LOG="$reenroll_ssh_log"

    cat >"$ROUNDHOUSE_CONFIG" <<'JSON'
{"version":1,"machines":{"hub":{"platform":"macos","transport":"local","groups":["durable"]},"mac-studio":{"ssh_alias":"mac-studio","platform":"macos","transport":"ssh","groups":["durable"]}}}
JSON
    printf 'name: hub\ndomain: fleet.example.invalid\n' \
      >"$hub_home/.config/roundhouse/identity.yaml"

    # Hub genesis and a published checkpoint-shaped baseline.
    "$cli" fleet-init >/dev/null
    "$cli" fleet-enroll >/dev/null
    reenroll_genesis=$(fleet_store_id "$hub_store")
    [ -n "$reenroll_genesis" ] || fail "hub genesis was not created"
    "$real_git" init -q --bare -b main "$hub_remote"
    jj -R "$hub_store" git remote add origin "$hub_remote"
    "$REAL_GIT" -C "$hub_store" push -q origin main
    jj -R "$hub_store" bookmark track main@origin >/dev/null
    reenroll_remote_url=$(fleet_remote_url "$hub_store")
    mkdir -p "$hub_home/.config/roundhouse/store.local"
    cat >"$hub_home/.config/roundhouse/store.local/posture.yaml" <<YAML
remote_visibility_verified: true
remote_visibility_reason: auth-required
remote_visibility_url: $reenroll_remote_url
YAML
    export ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf Authentication >&2; exit 1'
    # Model the durable hub itself as an enrolled host before checkpointing;
    # lineage and alert paths are host-owned, so the sponsor must be present in
    # the host membership set when the re-enrolled peer verifies the history.
    fleet_enroll_seed_host_facts "$hub_store" hub
    reenroll_hub_seed=$(fleet_enroll_commit "$hub_store" hub 'seed hub host facts')
    fleet_vcs_publish "$hub_store" "$reenroll_hub_seed"
    jj -R "$hub_store" new "$reenroll_hub_seed" >/dev/null
    "$cli" fleet-checkpoint >/dev/null
    reenroll_checkpoint_tag=$(git -C "$hub_store" tag --list 'rh-checkpoint-*' | head -1)
    [ -n "$reenroll_checkpoint_tag" ] || fail "hub checkpoint tag was not created"
    reenroll_archive_ref=$(fleet_trust_archive_ref "$(date -u +%Y%m%d)")
    "$REAL_GIT" ls-remote --exit-code "$hub_remote" "refs/tags/$reenroll_checkpoint_tag" >/dev/null ||
      fail "hub checkpoint tag was not published"
    "$REAL_GIT" ls-remote --exit-code "$hub_remote" "$reenroll_archive_ref" >/dev/null ||
      fail "hub checkpoint archive ref was not published"
    cat >"$node_home/.config/roundhouse/config.json" <<'JSON'
{"version":1,"machines":{"mac-studio":{"platform":"macos","transport":"local","groups":["durable"]}}}
JSON
    mkdir -p "$(dirname "$node_identity")"

    # First add proves the new bootstrap against a host with no identity and
    # no store. The remote probe is intentionally inconclusive;
    # fleet-add must record the posture warning rather than arm a surprise
    # first push.
    reenroll_first=$("$cli" fleet-add mac-studio 2>&1) || {
      printf '%s\n' "$reenroll_first" >&2
      [ ! -s "$reenroll_ssh_log" ] || {
        printf 'real-jj: remote SSH stderr follows\n' >&2
        sed -n '1,120p' "$reenroll_ssh_log" >&2
      }
      fail "initial live-shaped add failed"
    }
    [ -d "$node_store/.jj" ] || fail "initial add did not clone the hub store"
    [ -f "$hub_store/hosts/mac-studio.yaml" ] ||
      fail "initial add did not seed hosts/mac-studio.yaml"
    grep -Fqx 'domain: fleet.example.invalid' "$node_identity" ||
      fail "fresh bootstrap did not persist the pinned fleet domain"
    printf '%s\n' "$reenroll_first" | grep -Fq 'unverified over the SSH lane' ||
      fail "initial add did not guide the operator after an inconclusive posture probe"

    # Retire through the real verb, then wipe only the remote store. Identity
    # survives, matching the mac-studio failure; the next add is the sanctioned
    # re-enrollment rather than a hand-edited reviewed ref.
    "$cli" fleet-remove mac-studio >/dev/null
    [ ! -e "$hub_store/hosts/mac-studio.yaml" ] ||
      fail "retire left the durable host layer behind"
    mv "$node_store" "$node_store.wiped"
    [ -f "$node_identity" ] ||
      fail "the re-enrollment fixture lost identity.yaml while wiping the store"

    # A preserved store id is not enough: stale name/principal fields would
    # make the host sign under one identity while the sponsor records another.
    printf 'name: old-mac-studio\ndomain: fleet.example.invalid\nstore_id: %s\nprincipal: old-mac-studio@fleet.example.invalid\n' \
      "$reenroll_genesis" >"$node_identity"
    stale_identity_status=0
    stale_identity_out=$("$cli" fleet-add mac-studio 2>&1) ||
      stale_identity_status=$?
    [ "$stale_identity_status" -eq 69 ] ||
      fail "re-add accepted a preserved identity with stale name/principal"
    [ ! -d "$node_store/.jj" ] ||
      fail "identity mismatch cloned the store before refusing enrollment"
    printf 'name: mac-studio\ndomain: fleet.example.invalid\nstore_id: %s\nprincipal: mac-studio@fleet.example.invalid\n' \
      "$reenroll_genesis" >"$node_identity"

    # A preserved identity must also carry the same pinned domain. Missing or
    # stale domain data must refuse before the wiped store can be cloned.
    printf 'name: mac-studio\nstore_id: %s\nprincipal: mac-studio@fleet.example.invalid\n' \
      "$reenroll_genesis" >"$node_identity"
    domain_identity_status=0
    domain_identity_out=$("$cli" fleet-add mac-studio 2>&1) ||
      domain_identity_status=$?
    [ "$domain_identity_status" -eq 69 ] ||
      fail "re-add accepted a preserved identity with no pinned domain"
    [ ! -d "$node_store/.jj" ] ||
      fail "domain mismatch cloned the store before refusing enrollment"
    printf 'name: mac-studio\ndomain: fleet.example.invalid\nstore_id: %s\nprincipal: mac-studio@fleet.example.invalid\n' \
      "$reenroll_genesis" >"$node_identity"

    reenroll_second=$("$cli" fleet-add mac-studio 2>&1) || {
      printf '%s\n' "$reenroll_second" >&2
      fail "re-add did not bootstrap the wiped store from the hub"
    }
    [ -d "$node_store/.jj" ] || fail "re-add did not clone the published hub history"
    [ -f "$hub_store/hosts/mac-studio.yaml" ] ||
      fail "re-add did not seed hosts/mac-studio.yaml"
    grep -Fqx "store_id: $reenroll_genesis" \
      "$node_identity" ||
      fail "re-add overwrote the host identity with a foreign store id"
    reenroll_origin_head=$(jj -R "$node_store" log -r 'main@origin' \
      --no-graph -T 'commit_id')
    reenroll_seed_parent=$(jj -R "$node_store" log -r '@-' \
      --no-graph -T 'commit_id')
    [ "$reenroll_seed_parent" = "$reenroll_origin_head" ] ||
      fail "re-add seeded the working copy before the published enrollment head"

    # The host-side sequence is now exercised on the actual cloned store:
    # join is inert but must be accepted, and the verify/run path must remain
    # fail-closed until the remote is measured.
    node_join_status=0
    node_join_out=$(HOME="$node_home" XDG_CONFIG_HOME="$node_home/.config" \
      ROUNDHOUSE_CONFIG="$node_home/.config/roundhouse/config.json" \
      ROUNDHOUSE_FLEET_STORE="$node_store" \
      ROUNDHOUSE_FLEET_SIGNING_KEY="$node_home/.ssh/roundhouse_node_ed25519" \
      ROUNDHOUSE_TRUST_ROOT="$node_home/.config/roundhouse" \
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_FLEET_VISIBILITY_PROBE='exit 1' \
      "$cli" fleet-join "$reenroll_remote_url" 2>&1) || node_join_status=$?
    [ "$node_join_status" -eq 0 ] || {
      printf '%s\n' "$node_join_out" >&2
      fail "on-host fleet-join refused the cloned, checkpoint-anchored store"
    }
    node_verify_status=0
    node_verify_out=$(HOME="$node_home" XDG_CONFIG_HOME="$node_home/.config" \
      ROUNDHOUSE_CONFIG="$node_home/.config/roundhouse/config.json" \
      ROUNDHOUSE_FLEET_STORE="$node_store" \
      ROUNDHOUSE_FLEET_SIGNING_KEY="$node_home/.ssh/roundhouse_node_ed25519" \
      ROUNDHOUSE_TRUST_ROOT="$node_home/.config/roundhouse" \
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_FLEET_VISIBILITY_PROBE='exit 1' \
      "$cli" fleet-verify-remote 2>&1) || node_verify_status=$?
    [ "$node_verify_status" -ne 0 ] || fail "inconclusive remote posture unexpectedly opened the first-push gate"
    printf '%s\n' "$node_verify_out" | grep -Fq 'inconclusive' ||
      fail "verify-remote did not explain the no-answer posture"
    node_verify_ok=$(HOME="$node_home" XDG_CONFIG_HOME="$node_home/.config" \
      ROUNDHOUSE_CONFIG="$node_home/.config/roundhouse/config.json" \
      ROUNDHOUSE_FLEET_STORE="$node_store" \
      ROUNDHOUSE_FLEET_SIGNING_KEY="$node_home/.ssh/roundhouse_node_ed25519" \
      ROUNDHOUSE_TRUST_ROOT="$node_home/.config/roundhouse" \
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf Authentication >&2; exit 1' \
      "$cli" fleet-verify-remote 2>&1) || {
      printf '%s\n' "$node_verify_ok" >&2
      fail "a later successful remote posture verification could not open the gate"
    }
    node_run_status=0
    node_run_out=$(HOME="$node_home" XDG_CONFIG_HOME="$node_home/.config" \
      ROUNDHOUSE_CONFIG="$node_home/.config/roundhouse/config.json" \
      ROUNDHOUSE_FLEET_STORE="$node_store" \
      ROUNDHOUSE_FLEET_SIGNING_KEY="$node_home/.ssh/roundhouse_node_ed25519" \
      ROUNDHOUSE_TRUST_ROOT="$node_home/.config/roundhouse" \
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf Authentication >&2; exit 1' \
      "$cli" fleet-run 2>&1) || node_run_status=$?
    [ "$node_run_status" -eq 0 ] || {
      printf '%s\n' "$node_run_out" >&2
      fail "re-enrolled host could not complete fleet-run after the hub re-add"
    }
  )
fi
