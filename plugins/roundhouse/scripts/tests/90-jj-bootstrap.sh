# roundhouse self-check — fleet store bootstrap: paths, the run environment,
# store identity, and the fleet-init / fleet-enroll ordering against real jj.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

# --- host-local path resolution, the run environment, store identity ---
# No jj and no yq: pure path and file logic, so it runs everywhere.

bootstrap_root="$tmp/fleet-bootstrap"
mkdir -p "$bootstrap_root"

(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # R5: two roundhouse instances live on one machine (the Windows host and its
  # WSL sibling), each with its own certificate, store clone and repo config.
  # Nothing in CI can exercise that, so what CI CAN prove is that "run it
  # twice" is genuinely the same code: every host-local file resolves off the
  # one store resolver, so two store paths give two disjoint instance roots.
  for bootstrap_instance in alpha beta; do
    ROUNDHOUSE_FLEET_STORE="$bootstrap_root/$bootstrap_instance/store"
    export ROUNDHOUSE_FLEET_STORE
    for bootstrap_file in local.yaml krl store.run store.local; do
      fleet_instance_path "$bootstrap_file"
    done
    fleet_identity_path
    fleet_allowed_signers_path
  done >"$bootstrap_root/instance-paths"
  unset ROUNDHOUSE_FLEET_STORE
  [ "$(sort -u "$bootstrap_root/instance-paths" | grep -c .)" -eq 12 ] ||
    fail "two fleet instance roots did not resolve to disjoint host-local paths"
  grep -Fqx "$bootstrap_root/alpha/allowed_signers" "$bootstrap_root/instance-paths" ||
    fail "fleet_allowed_signers_path ignored the instance root"

  # The default instance root is the store's parent, so an unset override
  # still lands on ~/.config/roundhouse.
  [ "$(XDG_CONFIG_HOME="$bootstrap_root/xdg" fleet_instance_root)" = \
    "$bootstrap_root/xdg/roundhouse" ] ||
    fail "the default fleet instance root is not the store's parent"

  # §3.2: the run environment is one function, and it closes stdin. A run that
  # can block on a human hangs a machine nobody is sitting at.
  printf 'STDIN-LEAKED\n' >"$bootstrap_root/stdin-probe"
  bootstrap_env=$(
    fleet_run_env
    printf '%s|%s|%s|%s|%s|' "$JJ_EDITOR" "$GIT_EDITOR" "$PAGER" \
      "$GIT_TERMINAL_PROMPT" "$GIT_SSH_COMMAND"
    cat
  ) <"$bootstrap_root/stdin-probe"
  [ "$bootstrap_env" = 'true|true|cat|0|ssh -o BatchMode=yes|' ] ||
    fail "fleet_run_env did not pin the non-interactive environment and close stdin: $bootstrap_env"

  # The store scaffold carries NO identity marker file: §7.5's discriminator is
  # the genesis commit id, because a marker file could be copied into a hostile
  # store and a genesis commit cannot be produced without producing that commit.
  mkdir -p "$bootstrap_root/identity/store"
  fleet_write_store_scaffold "$bootstrap_root/identity/store"
  grep -Fqx '*  -text' "$bootstrap_root/identity/store/.gitattributes" ||
    fail "the store scaffold wrote no -text attribute"
  [ ! -e "$bootstrap_root/identity/store/.roundhouse-sync-store" ] ||
    fail "the store scaffold still writes an identity marker file (§7.5)"
)

# --- real jj: bootstrap ordering, the pins, and enrollment ---
# Everything below can only be falsified by real tools: §3.3's brick case is a
# claim about what jj 0.44 does when signing config precedes the certificate,
# and a comment cannot verify it. The suite sanitizes PATH early, so probe the
# standard install locations in addition to whatever survives on PATH.
bootstrap_tool_path() {
  bootstrap_found=$(command -v "$1" 2>/dev/null || true)
  if [ -z "$bootstrap_found" ]; then
    for candidate in "/opt/homebrew/bin/$1" "/usr/local/bin/$1" \
      "$HOME/.local/bin/$1" "$HOME/.cargo/bin/$1"; do
      [ ! -x "$candidate" ] || {
        bootstrap_found=$candidate
        break
      }
    done
  fi
  printf '%s\n' "$bootstrap_found"
}
real_jj=$(bootstrap_tool_path jj)
real_yq=$(bootstrap_tool_path yq)
real_jj_version=
real_jj_ok=false
if [ -n "$real_jj" ] && [ -n "$real_yq" ]; then
  real_jj_version=$("$real_jj" --version 2>/dev/null |
    sed -n 's/^jj \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  real_jj_major=${real_jj_version%%.*}
  real_jj_minor=${real_jj_version#*.}
  if [ -n "$real_jj_version" ] &&
    { [ "$real_jj_major" -gt 0 ] || [ "$real_jj_minor" -ge 43 ]; } 2>/dev/null; then
    real_jj_ok=true
  fi
fi
# CI installs jj and sets this, so the five real-jj sections RUN there rather
# than printing a NOTICE nobody reads. One guard, here, where the gate is
# decided: a per-section check is five places for the skip to survive in.
if [ "${ROUNDHOUSE_REQUIRE_REAL_JJ:-false}" = true ] && [ "$real_jj_ok" != true ]; then
  fail "ROUNDHOUSE_REQUIRE_REAL_JJ is set but jj >= 0.43 and yq are not both usable (jj ${real_jj_version:-none}, yq ${real_yq:-none})"
fi

# --- the key/roster/KRL fixture generator, shared by every real-jj section ---
# Real ed25519 node keys, a real hand-editable roster listing them by value,
# and a real KRL. THERE IS NO CA AND NO CERTIFICATE. Nothing expires on an
# unwritten date and nothing is stubbed: the signature gate this material feeds
# is the one thing v1 tested only under an env-var bypass, which is why the
# bypass is deleted. Defined at section scope rather than inside the block below
# so sections 91 and 92 mint their own material with the same three lines; each
# sets `$rjj` to its own directory first.
rjj_key() {
  # rjj_key <node-id> — one plain ed25519 node key. THERE IS NO CA AND NO
  # CERTIFICATE: the roster lists this key by value, which is what binds the
  # principal natively rather than through a wildcard authority line.
  /usr/bin/ssh-keygen -q -t ed25519 -N '' -C '' -f "$rjj/$1-key"
}
rjj_signer() {
  # keytype + base64 only, the way the roster carries it.
  awk '{ printf "%s %s", $1, $2 }' "$rjj/$1-key.pub"
}
rjj_roster() {
  # rjj_roster <dest> <generation> <name>:<class>[:<valid_before>]...
  # The roster as a real host would hand-edit it, one block per machine.
  rjj_roster_dest=$1
  rjj_roster_gen=$2
  shift 2
  printf 'generation: %s\n' "$rjj_roster_gen" >"$rjj_roster_dest"
  for rjj_roster_class in durable ephemeral; do
    rjj_roster_any=false
    for rjj_roster_spec in "$@"; do
      rjj_roster_name=${rjj_roster_spec%%:*}
      rjj_roster_rest=${rjj_roster_spec#*:}
      rjj_roster_kind=${rjj_roster_rest%%:*}
      [ "$rjj_roster_kind" = "$rjj_roster_class" ] || continue
      if [ "$rjj_roster_any" = false ]; then
        printf '%s:\n' "$rjj_roster_class" >>"$rjj_roster_dest"
        rjj_roster_any=true
      fi
      printf '  %s:\n    principal: %s@fleet.example.invalid\n    key: "%s"\n' \
        "$rjj_roster_name" "$rjj_roster_name" "$(rjj_signer "$rjj_roster_name")" \
        >>"$rjj_roster_dest"
      printf '    enrolled_at: 2020-01-01T00:00:00Z\n    channel_auth: known_hosts\n' \
        >>"$rjj_roster_dest"
      [ "$rjj_roster_class" != ephemeral ] ||
        printf '    sponsor: vireo\n' >>"$rjj_roster_dest"
      # DELIBERATELY UNQUOTED: yq types a bare ISO8601 stamp as a timestamp,
      # and a hand-editable roster cannot be relied on to quote its dates, so
      # the fixture is the unfriendly case.
      case $rjj_roster_rest in
        *:*) printf '    valid_before: %s\n' "${rjj_roster_rest#*:}" \
          >>"$rjj_roster_dest" ;;
      esac
    done
  done
}
rjj_krl() {
  # rjj_krl <name> [revoked-key.pub]... — no keys mints an empty KRL, which is
  # the honest "no revocations known yet" state and is the normal steady state:
  # the KRL is the emergency lever, never the removal path.
  rjj_krl_name=$1
  shift
  /usr/bin/ssh-keygen -q -k -f "$rjj/$rjj_krl_name" "$@"
}

if [ "$real_jj_ok" != true ]; then
  printf '\n'
  printf '========================================================================\n'
  printf 'NOTICE: real-jj bootstrap block skipped\n'
  printf '  required: jj >= 0.43 and yq   found: jj %s, yq %s\n' \
    "${real_jj_version:-none}" "${real_yq:-none}"
  printf '  §3.3 bootstrap ordering is UNVERIFIED in this run.\n'
  printf '  Run this suite once on a jj-equipped host before merge.\n'
  printf '========================================================================\n'
  printf '\n'
else
  printf 'real-jj: fleet bootstrap ordering and enrollment (jj %s)\n' "$real_jj_version"
  (
    set -eu
    # Distinct failure voice: anything below is a real-jj finding, not a
    # fixture regression.
    fail() {
      printf 'FAIL: real-jj: %s\n' "$*" >&2
      exit 1
    }
    PATH="$(dirname "$real_jj"):$(dirname "$real_yq"):$PATH"
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    rjj="$bootstrap_root/real"
    mkdir -p "$rjj"
    # Ambient jj identity, standing in for the operator's own ~/.config/jj.
    # fleet-init's repo-local pins must win over it.
    cat >"$rjj/jj-config.toml" <<'TOML'
[user]
name = "roundhouse selfcheck"
email = "roundhouse-selfcheck@example.invalid"
[ui]
paginate = "never"
TOML
    export JJ_CONFIG="$rjj/jj-config.toml"
    # jj 0.44 does not keep `--repo` config in the store: it migrates
    # .jj/repo/config.toml to $XDG_CONFIG_HOME/jj/repos/<opaque-hash>/ and
    # leaves a symlink behind (the [rev2] observation §2 records). So the XDG
    # root is machine-wide and shared by every instance — one root here, with
    # instances told apart by store path, which is what a real machine looks
    # like. Reading a pin back from a different XDG root silently answers with
    # the operator's own jj config instead.
    export XDG_CONFIG_HOME="$rjj/xdg"

    # The key/roster/KRL fixture generator is defined at section scope above.
    rjj_key corvid
    rjj_krl empty.krl
    [ -s "$rjj/empty.krl" ] ||
      fail "the key/roster/KRL fixture generator produced nothing"

    rjj_run() {
      # One roundhouse invocation against one instance root. The store path is
      # the ONLY thing that distinguishes two instances: every host-local file
      # follows it, and no host-local file follows XDG.
      rjj_instance=$1
      shift
      mkdir -p "$rjj/$rjj_instance"
      # §7.1's principal is `<node_id>@<domain>`, and identity.yaml is the only
      # source that survives a rename. Written here so the fixture host names
      # are the ones the assertions below use, rather than this machine's.
      [ -f "$rjj/$rjj_instance/identity.yaml" ] ||
        printf 'name: %s\ndomain: fleet.example.invalid\n' "$rjj_instance" \
          >"$rjj/$rjj_instance/identity.yaml"
      env ROUNDHOUSE_FLEET_STORE="$rjj/$rjj_instance/store" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/$rjj_instance-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/$rjj_instance" \
        "$@"
    }

    # 1. §3.3, the brick case — the reason fleet-init and fleet-enroll are two
    #    commands. With signing.behavior=own and signing.key naming a file
    #    that does not exist, `jj git init --colocate` does not merely fail to
    #    sign: it dies and the repo is NEVER CREATED.
    cat >"$rjj/bricked-config.toml" <<TOML
[user]
name = "roundhouse selfcheck"
email = "vireo@fleet.example.invalid"
[ui]
paginate = "never"
editor = "true"
[signing]
backend = "ssh"
behavior = "own"
key = "$rjj/no-such-key"
[signing.backends.ssh]
program = "/usr/bin/ssh-keygen"
TOML
    mkdir -p "$rjj/bricked"
    rjj_brick_status=0
    JJ_CONFIG="$rjj/bricked-config.toml" jj git init --colocate "$rjj/bricked" \
      >/dev/null 2>"$rjj/bricked.err" || rjj_brick_status=$?
    [ "$rjj_brick_status" -ne 0 ] ||
      fail "[signing] before the certificate no longer bricks jj git init — re-derive §3.3 before merging enroll back into init"
    grep -qi 'signing error\|sign failed' "$rjj/bricked.err" ||
      fail "jj git init failed for a reason other than signing: $(cat "$rjj/bricked.err")"
    [ ! -d "$rjj/bricked/.jj" ] ||
      fail "the bricked init left a jj repository behind (the failure mode changed)"

    # 2. The split order succeeds, and fleet-init writes NO signing config.
    rjj_init=$(rjj_run vireo "$cli" fleet-init) ||
      fail "fleet-init failed on a host with no certificate"
    [ -d "$rjj/vireo/store/.jj" ] ||
      fail "fleet-init created no colocated jj repository"
    [ -d "$rjj/vireo/store/.git" ] ||
      fail "the fleet store carries no git backing"
    # fleet-init CANNOT report a store id: the roster commit fleet-enroll makes
    # IS the genesis, and a scaffold commit here would become the genesis
    # instead — so store_id would name a commit carrying no roster, signed by
    # nobody.
    ! printf '%s\n' "$rjj_init" | grep -q 'store id [0-9a-f]' ||
      fail "fleet-init reported a store id before the roster commit existed (§12)"
    [ -z "$(fleet_store_id "$rjj/vireo/store")" ] ||
      fail "fleet-init created history; the roster commit must BE the genesis"
    # Repo scope, not effective value: jj answers `none`/`keep` for unset
    # signing keys, so the question is whether fleet-init wrote any of them
    # HERE — which is the thing that bricks the next init.
    rjj_repo_signing() {
      jj -R "$1" config list --repo signing 2>/dev/null | grep -c '^signing' ||
        true
    }
    [ "$(rjj_repo_signing "$rjj/vireo/store")" -eq 0 ] ||
      fail "fleet-init wrote repo-local [signing] before a key existed (§3.3)"
    # §3.1 and §3.2 by EFFECTIVE value, which is also doctor's row.
    rjj_drift=$(fleet_pins_drift "$rjj/vireo/store" || true)
    [ -z "$rjj_drift" ] ||
      fail "fleet-init left config pins unset or wrong: $rjj_drift"
    grep -Fqx '*  -text' "$rjj/vireo/store/.gitattributes" ||
      fail "fleet-init wrote no store scaffold"

    # 3. The 1Password inheritance trap, in its own store so the probe cannot
    #    disturb a jj working copy. The owner's global git config signs every
    #    commit through op-ssh-sign, so any agent shelling out to git inside
    #    the store pops an approval dialog — and §8.4's own premise is that
    #    agents shell out to git. The stand-in fails loudly and records that
    #    it ran, so a leak is a failure and never a hang.
    cat >"$rjj/op-ssh-sign" <<'SH'
#!/usr/bin/env bash
printf 'leaked\n' >>"$OP_SSH_SIGN_MARKER"
printf 'op-ssh-sign: interactive approval required\n' >&2
exit 1
SH
    chmod +x "$rjj/op-ssh-sign"
    cat >"$rjj/ambient-gitconfig" <<TOML
[user]
	name = ambient
	email = ambient@example.invalid
[commit]
	gpgsign = true
[tag]
	gpgsign = true
[gpg]
	format = ssh
[gpg "ssh"]
	program = $rjj/op-ssh-sign
[core]
	pager = less
	editor = false
TOML
    OP_SSH_SIGN_MARKER="$rjj/op-ssh-sign-ran"
    export OP_SSH_SIGN_MARKER
    GIT_CONFIG_GLOBAL="$rjj/ambient-gitconfig"
    export GIT_CONFIG_GLOBAL
    rjj_run ambient "$cli" fleet-init >/dev/null ||
      fail "fleet-init failed under an ambient signing git config"
    [ "$(git -C "$rjj/ambient/store" config --get gpg.ssh.program)" = ssh-keygen ] ||
      fail "the ambient gpg.ssh.program was not overridden repo-locally"
    [ "$(git -C "$rjj/ambient/store" config --get core.pager)" = cat ] ||
      fail "the ambient pager was not overridden repo-locally"
    printf 'ambient probe\n' >"$rjj/ambient/store/.git-probe"
    git -C "$rjj/ambient/store" add -f .git-probe
    git -C "$rjj/ambient/store" commit -q -m 'ambient probe' ||
      fail "a plain git commit inside the store fell through to the ambient signer"
    [ ! -f "$OP_SSH_SIGN_MARKER" ] ||
      fail "op-ssh-sign leaked into the store repo (§3.2 point 3)"
    unset GIT_CONFIG_GLOBAL

    # 4. fleet-enroll, in §3.3's order: keygen -> user.email -> [signing] ->
    #    the SELF-SIGNED roster commit, which IS the genesis.
    rjj_no_store_status=0
    rjj_run corvid "$cli" fleet-enroll >/dev/null 2>&1 || rjj_no_store_status=$?
    [ "$rjj_no_store_status" -eq 69 ] ||
      fail "fleet-enroll did not refuse a host with no store (got $rjj_no_store_status)"
    rjj_enroll=$(rjj_run vireo "$cli" fleet-enroll) ||
      fail "fleet-enroll failed on a host with no key (it is supposed to mint one)"
    assert_contains "$rjj_enroll" 'vireo@'
    [ -f "$rjj/vireo-key" ] ||
      fail "fleet-enroll minted no node key — there is no CA to ask for one"
    [ "$(fleet_signer_entry "$rjj/vireo-key.pub")" = \
      "$(awk '{ printf "%s %s", $1, $2 }' "$rjj/vireo-key.pub")" ] ||
      fail "the minted key is not a usable signer entry"
    rjj_signers="$rjj/vireo/allowed_signers"
    [ -f "$rjj_signers" ] ||
      fail "fleet-enroll materialized no allowed_signers under \$TRUST"
    # PER-KEY LINES, never a wildcard authority: the principal is bound
    # natively, and `namespaces="git"` is what keeps a roundhouse-enroll
    # possession proof from being replayed as a commit signature.
    ! grep -q 'cert-authority' "$rjj_signers" ||
      fail "the materialized roster carries a cert-authority line (there is no CA)"
    grep -q '^[^ ]*@[^ ]* namespaces="git" ssh-ed25519 ' "$rjj_signers" ||
      fail "the materialized roster line is not <principal> namespaces=\"git\" <key>"
    ! grep -qE 'valid-before=|valid-after=' "$rjj_signers" ||
      fail "the materialized roster carries a TIME OPTION, which is evaluated at wall clock and is therefore retroactive (§7.1b)"
    [ -f "$rjj/vireo/krl" ] ||
      fail "fleet-enroll installed no host-local KRL"
    rjj_store_id=$(printf '%s\n' "$rjj_enroll" |
      sed -n 's/^.*store id \([0-9a-f][0-9a-f]*\).*$/\1/p')
    [ -n "$rjj_store_id" ] ||
      fail "fleet-enroll reported no store id UPWARD (§12: it is an output)"
    [ "$(fleet_store_id "$rjj/vireo/store")" = "$rjj_store_id" ] ||
      fail "the reported store id is not this store's genesis commit id"
    # §7.5: the FOUNDER MUST END PINNED, like every sponsored host. store_id is
    # an output, but it is also written back into the founder's own
    # identity.yaml — without it host 1 stays pinless forever and any parentless
    # commit reaches roster_derive's genesis self-verify branch.
    [ "$(FLEET_IDENTITY_KEY=store_id yq -r '.[strenv(FLEET_IDENTITY_KEY)] // ""' \
      "$rjj/vireo/identity.yaml")" = "$rjj_store_id" ] ||
      fail "the founder did not back-fill its own store_id — it ends unpinned (§7.5)"
    # The genesis roster must list the key that signed it.
    jj -R "$rjj/vireo/store" file show -r "$rjj_store_id" \
      "root:$fleet_trust_roster_file" | grep -Fq "$(rjj_signer vireo)" ||
      fail "the genesis roster does not list the key that signed the genesis commit"
    case $(jj -R "$rjj/vireo/store" config get user.email) in
      *@*) ;;
      *) fail "user.email is not a roster principal (§7.3's equality gate)" ;;
    esac
    [ "$(jj -R "$rjj/vireo/store" config get signing.behavior)" = own ] ||
      fail "fleet-enroll did not write signing.behavior own"
    [ "$(jj -R "$rjj/vireo/store" config get signing.key)" = "$rjj/vireo-key" ] ||
      fail "signing points at something other than the minted node key"
    fleet_signing_ready "$rjj/vireo/store" ||
      fail "fleet_signing_ready refused a correctly enrolled store"

    # The library assertions below call the ratchet directly rather than
    # through the CLI, so they need the same $TRUST this instance was enrolled
    # against — the trust roots are read FRESH per invocation and never from
    # repo config, which is the point.
    export ROUNDHOUSE_SELFTEST=1
    export ROUNDHOUSE_TRUST_ROOT="$rjj/vireo"
    export ROUNDHOUSE_FLEET_STORE="$rjj/vireo/store"

    # 5. The gate this whole ordering exists to make possible: the genesis
    #    commit verifies good against its OWN roster, and its signature
    #    principal equals its committer email (§7.3).
    rjj_signature=$(fleet_trust_signature_read "$rjj/vireo/store" \
      "$rjj_store_id" "$rjj_signers")
    case $rjj_signature in
      'good '*) ;;
      *) fail "the genesis commit did not verify good: $rjj_signature" ;;
    esac
    [ "$(printf '%s' "$rjj_signature" | awk '{ print $2 }')" = \
      "$(printf '%s' "$rjj_signature" | awk '{ print $3 }')" ] ||
      fail "the genesis signature principal does not equal its committer: $rjj_signature"

    # 6. Enrollment is IDEMPOTENT, and it is also the heal path, the rename
    #    path and the reconstitution path. A second run must not mint a second
    #    genesis or a second key.
    rjj_run vireo "$cli" fleet-enroll >/dev/null ||
      fail "fleet-enroll is not idempotent"
    [ "$(fleet_store_id "$rjj/vireo/store")" = "$rjj_store_id" ] ||
      fail "re-running fleet-enroll moved the genesis"

    # 7. §7.9's detection compare: a hand-edited materialized roster is
    #    precisely the self-enrollment signature, and the mismatch is a hold
    #    rather than a repair.
    [ -z "$(fleet_trust_materialization_drift "$rjj/vireo/store")" ] ||
      fail "a freshly materialized roster already disagrees with the ratchet"
    printf 'attacker@fleet.example.invalid namespaces="git" %s\n' \
      "$(rjj_signer corvid)" >>"$rjj_signers"
    [ -n "$(fleet_trust_materialization_drift "$rjj/vireo/store")" ] ||
      fail "a key appended to the materialized roster was not detected (§7.9)"
    rjj_run vireo "$cli" fleet-enroll >/dev/null

    # 8. §7.5 at init, against a real clone. `jj git clone` performs no check
    #    whatsoever on the remote's content, so this comparison is the only
    #    thing standing between this fleet and a foreign store — and the
    #    genesis commit id is UNFORGEABLE where a marker file was merely
    #    copyable.
    "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"
    "$REAL_GIT" -C "$rjj/vireo/store" push -q "$rjj/remote.git" main ||
      fail "could not publish the fleet store to the fixture remote"
    # The three commands that run OUTSIDE the store's repo config carry the
    # pins explicitly (§3.2): a clone happens before fleet-init writes any.
    jj git clone --colocate --config ui.editor='"true"' \
      --config ui.paginate=never "$rjj/remote.git" "$rjj/corvid/store" \
      >/dev/null 2>&1 ||
      fail "could not clone the fleet store for the second host"
    [ -f "$rjj/corvid/store/$fleet_trust_roster_file" ] ||
      fail "the clone checked out no roster"
    printf 'name: corvid\nstore_id: %s\n' "$rjj_store_id" \
      >"$rjj/corvid/identity.yaml"
    rjj_run corvid "$cli" fleet-init >/dev/null ||
      fail "fleet-init refused a clone whose genesis matches identity.yaml"
    [ -z "$(fleet_pins_drift "$rjj/corvid/store" || true)" ] ||
      fail "fleet-init did not pin a cloned store (the repo config is host-local)"
    printf 'name: corvid\nstore_id: %s\n' 0000000000000000 \
      >"$rjj/corvid/identity.yaml"
    rjj_foreign_status=0
    rjj_run corvid "$cli" fleet-init >/dev/null 2>&1 || rjj_foreign_status=$?
    [ "$rjj_foreign_status" -eq 65 ] ||
      fail "fleet-init accepted a store belonging to another fleet (got $rjj_foreign_status)"
    # And the reverse: a host that already knows the fleet's store id must not
    # be able to root a SECOND store claiming that identity.
    mkdir -p "$rjj/wren"
    printf 'name: wren\nstore_id: %s\n' "$rjj_store_id" >"$rjj/wren/identity.yaml"
    rjj_run wren "$cli" fleet-init >/dev/null 2>&1 || :
    rjj_reroot_status=0
    rjj_run wren "$cli" fleet-enroll >/dev/null 2>&1 || rjj_reroot_status=$?
    [ "$rjj_reroot_status" -eq 65 ] ||
      fail "a host named the fleet's store id and minted a second genesis anyway"

    # 9. A store with HISTORY but no roster behind it: refuse, never heal.
    #    Both verbs keyed their "already set up, just heal" path on the store id
    #    alone — and §7.5/§12 make the store id and the roster the same fact
    #    seen twice, so a store id with no `trust/signers.yaml` is a DIFFERENT
    #    store's remains. A leftover v0.5 store looked exactly like this, and
    #    healing it produced something that looked enrolled and verified
    #    nothing; every later verb then failed somewhere further downstream.
    rjj_legacy="$rjj/legacy/store"
    mkdir -p "$rjj/legacy"
    jj git clone --colocate --config ui.editor='"true"' \
      --config ui.paginate=never "$rjj/remote.git" "$rjj_legacy" >/dev/null 2>&1 ||
      fail "could not clone the fleet store for the legacy-remnant fixture"
    printf 'name: legacy\nstore_id: %s\n' "$rjj_store_id" \
      >"$rjj/legacy/identity.yaml"
    # Same lineage, same store id — only the roster is gone, which is the whole
    # point: the store id check passes and this one has to be what refuses.
    rm -f "$rjj_legacy/$fleet_trust_roster_file"
    jj -R "$rjj_legacy" describe -m 'drop the roster' >/dev/null
    jj -R "$rjj_legacy" bookmark set main \
      -r "$(jj -R "$rjj_legacy" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$rjj_legacy" new "$(jj -R "$rjj_legacy" log \
      -r 'heads(bookmarks(exact:"main"))' --no-graph -T 'commit_id')" >/dev/null
    # THE REFUSAL LEAVES NOTHING BEHIND. A preflight that fires after minting the
    # node key and pointing the repo's [signing] block at it hands back a store
    # this build just called unusable AND reconfigured — half-enrolled state is
    # worse than no refusal. So the key must not exist and the config must not
    # be rewritten when the verb refuses.
    # Pins are read as EFFECTIVE values through fleet_pins_drift, never as file
    # contents: jj 0.44 migrates a written `.jj/repo/config.toml` out to
    # $XDG_CONFIG_HOME/jj/repos/<hash>/, so a path-based check here would
    # compare two absent files and pass vacuously. A fresh clone carries no
    # pins, so drift is non-empty now and must STAY non-empty across a refusal
    # — the corvid case above is the positive control where a successful
    # fleet-init drives it to empty.
    rm -f "$rjj/legacy-key" "$rjj/legacy-key.pub"
    [ -n "$(fleet_pins_drift "$rjj_legacy" || true)" ] ||
      fail "the legacy fixture was already pinned; the no-write assertion below would be vacuous"
    for rjj_legacy_verb in fleet-init fleet-enroll; do
      rjj_legacy_status=0
      rjj_legacy_out=$(rjj_run legacy "$cli" "$rjj_legacy_verb" 2>&1) ||
        rjj_legacy_status=$?
      [ "$rjj_legacy_status" -eq 65 ] ||
        fail "$rjj_legacy_verb healed a store with history and no roster (got $rjj_legacy_status)"
      case $rjj_legacy_out in
        *'re-init'* | *'move it aside'*) ;;
        *) fail "$rjj_legacy_verb refused without naming the remedy: $rjj_legacy_out" ;;
      esac
      [ ! -f "$rjj/legacy-key" ] ||
        fail "$rjj_legacy_verb minted a node key before refusing the store"
      [ -n "$(fleet_pins_drift "$rjj_legacy" || true)" ] ||
        fail "$rjj_legacy_verb pinned the repository config before refusing the store"
    done
    # A preflight that CANNOT RUN must refuse, never authorize: "I could not
    # check" is not "the check passed", and reading it as one would let
    # fleet-init/fleet-enroll mutate exactly the history this exists to reject.
    rjj_legacy_status=0
    rjj_legacy_out=$(TMPDIR="$rjj/no-such-tmpdir" rjj_run legacy "$cli" fleet-init 2>&1) ||
      rjj_legacy_status=$?
    [ "$rjj_legacy_status" -eq 65 ] ||
      fail "fleet-init proceeded when the lineage preflight could not allocate a tempfile (got $rjj_legacy_status)"
    case $rjj_legacy_out in
      *'could not be checked'*) ;;
      *) fail "the unrunnable preflight did not say it could not check: $rjj_legacy_out" ;;
    esac

    # …and the ordinary clone, which has a roster, is unaffected. (corvid's
    # identity was rewritten by the foreign-store fixture above; restore it.)
    printf 'name: corvid\nstore_id: %s\n' "$rjj_store_id" \
      >"$rjj/corvid/identity.yaml"
    rjj_run corvid "$cli" fleet-init >/dev/null ||
      fail "the lineage check refused a healthy cloned store"

    printf 'real-jj: OK (brick order, config pins, op-ssh-sign containment, keygen enrollment, genesis-as-store-id, legacy-remnant refusal, materialization drift)\n'
  ) || fail "real-jj bootstrap block failed (see the FAIL: real-jj: line above)"
fi
