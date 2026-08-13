# roundhouse self-check — §7 integrity: the signature gate, the principal
# equality check, the path->identity table, and §10.8's revert-signature
# predicate.
#
# Sourced by scripts/test-roundhouse in a fixed order, after
# tests/90-jj-bootstrap.sh, whose key/roster/KRL fixture generator and real-jj
# gate this section reuses; not a standalone test file.
# shellcheck shell=bash

integrity_root="$tmp/fleet-integrity"
mkdir -p "$integrity_root"

# --- the path->identity table and the revert predicate: no jj, no yq ---
# §7.3's table and §10.8's predicate are the two pieces of §7 that decide
# things without touching a repository, so they are tested without one. Both
# are also the pieces most likely to be quietly wrong.
(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # Row 1 — the shared layers, in both §2 path kinds, plus the three
  # non-layer paths any enrolled host may author. definitions.yaml is here on
  # purpose: the reserved `definitions.` prefix is about item identity, not
  # about who may write the file.
  for integrity_shared in fleet.yaml definitions.yaml definitions/10-overrides.yaml os/macos.yaml \
    groups/development.yaml hosts/vireo.yaml hosts/wren/base.yaml \
    fleet/policy.yaml lineage/1785024000-macbook-pro.yaml \
    proposals/promote-ponytail-to-fleet.yaml; do
    [ "$(fleet_vcs_path_owner "$integrity_shared")" = '*' ] ||
      fail "§7.3 row 1 did not accept any enrolled host for $integrity_shared"
  done

  # Row 2 — host-keyed evidence, which has NO exception for any host.
  for integrity_owned in journal/vireo/2026-08-07.yaml applied/vireo.yaml \
    alerts/vireo/20260807T0914-unsigned-hand-edit.yaml \
    findings/vireo/disk.yaml upstreams/claude-marketplace/vireo.yaml; do
    [ "$(fleet_vcs_path_owner "$integrity_owned")" = vireo ] ||
      fail "§7.3 row 2 did not key $integrity_owned to its own host"
  done

  # Neither row. No item resolves from these, so they need no identity — and
  # a deeper path must not be able to slide a host name into the leaf
  # position of a row 2 pattern.
  for integrity_unowned in README.md .gitignore .roundhouse-sync-store \
    applied/vireo/extra.yaml upstreams/claude-marketplace/deep/vireo.yaml \
    definitions/nested/file.yaml hosts journal/vireo; do
    ! fleet_vcs_path_owner "$integrity_unowned" >/dev/null ||
      fail "§7.3 claimed an identity for an unrecognised path: $integrity_unowned"
  done

  printf '%s\n' vireo wren corvid >"$integrity_root/hosts"

  # The whole point of §7.3: a commit dropped into journal/wren/ by vireo
  # signs as vireo, and the canary gate does not count it.
  ! fleet_vcs_path_identity_ok journal/wren/2026-08-07.yaml \
    vireo@fleet.example.invalid "$integrity_root/hosts" ||
    fail "a peer forged host-keyed evidence under another host's journal"
  fleet_vcs_path_identity_ok journal/wren/2026-08-07.yaml \
    wren@fleet.example.invalid "$integrity_root/hosts" ||
    fail "a host was refused its own journal path"
  fleet_vcs_path_identity_ok fleet.yaml corvid@fleet.example.invalid \
    "$integrity_root/hosts" ||
    fail "an enrolled host was refused a shared layer (the Q4 authorization model)"
  ! fleet_vcs_path_identity_ok fleet.yaml stranger@fleet.example.invalid \
    "$integrity_root/hosts" ||
    fail "a host with no hosts/ entry edited a shared layer"
  # A principal is `<h>@<domain>`. Anything else is not an identity this
  # table can reason about, so it is refused rather than guessed at.
  for integrity_bogus in vireo 'vireo@' '@fleet.example.invalid' \
    'vireo@a@b' ''; do
    ! fleet_vcs_path_identity_ok fleet.yaml "$integrity_bogus" \
      "$integrity_root/hosts" ||
      fail "§7.3 accepted a malformed principal: '$integrity_bogus'"
  done

  # §10.8 — the predicate is the only thing between a rollback and a silent
  # auto-apply, because the reverted digest is one this host already passed.
  integrity_fires() {
    printf '%s\n' "$2" | fleet_vcs_revert_signature "$1"
  }
  integrity_fires D_prior 'applied D_prior
applied D_bad' ||
    fail "§10.8 missed a revert: D_prior was applied, then superseded, and is incoming again"
  integrity_fires D_prior 'applied D_prior
reverted D_prior' ||
    fail "§10.8 missed a revert of an item that was rolled back outright"
  ! integrity_fires D_now 'applied D_now' ||
    fail "§10.8 fired on a PROMOTION — the digest never stopped being applied (§7.2)"
  ! integrity_fires D_now 'applied D_now
held D_other' ||
    fail "§10.8 fired on a held record: a hold changes nothing, so it withdraws nothing"
  ! integrity_fires D_new 'applied D_old' ||
    fail "§10.8 fired on a digest this host has never applied"
  ! integrity_fires D_any '' ||
    fail "§10.8 fired on an empty journal"
  # Re-applied after the withdrawal: the review already happened and the
  # digest is current again, so the next arrival is a promotion, not a revert.
  ! integrity_fires D_prior 'applied D_prior
applied D_bad
applied D_prior' ||
    fail "§10.8 re-fired on a digest this host had already re-reviewed and re-applied"

)

# --- real jj: the signature gate against real keys and a real roster ---
# Every claim below is about what jj 0.44 and ssh-keygen actually do with a
# KRL-revoked key, an empty signers file, and a commit whose committer
# says one host while its signature says another. A comment cannot verify any
# of them, and v1 tested this surface only under an env-var bypass.
if [ "$real_jj_ok" != true ]; then
  printf '\n'
  printf '========================================================================\n'
  printf 'NOTICE: real-jj integrity block skipped\n'
  printf '  required: jj >= 0.43 and yq   found: jj %s, yq %s\n' \
    "${real_jj_version:-none}" "${real_yq:-none}"
  printf '  §7.1/§7.3 signature and principal gates are UNVERIFIED in this run.\n'
  printf '========================================================================\n'
  printf '\n'
else
  printf 'real-jj: §7 signature, principal and revert gates (jj %s)\n' "$real_jj_version"
  (
    set -eu
    fail() {
      printf 'FAIL: real-jj: %s\n' "$*" >&2
      exit 1
    }
    PATH="$(dirname "$real_jj"):$(dirname "$real_yq"):$PATH"
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    rjj="$integrity_root/real"
    mkdir -p "$rjj"
    cat >"$rjj/jj-config.toml" <<'TOML'
[user]
name = "roundhouse selfcheck"
email = "roundhouse-selfcheck@example.invalid"
[ui]
paginate = "never"
editor = "true"
TOML
    export JJ_CONFIG="$rjj/jj-config.toml"
    # jj 0.44 migrates `--repo` config out of the store into
    # $XDG_CONFIG_HOME/jj/repos/<hash>/, so every effective-value read has to
    # run in the SAME XDG root as the write that produced it.
    export XDG_CONFIG_HOME="$rjj/xdg"

    rjj_key vireo
    rjj_key corvid
    rjj_key mallory
    rjj_key leaf
    rjj_krl seed.krl

    # One instance: the store path is the only thing that places it, and the
    # trust roots the gate reads are the instance-local ones — read FRESH per
    # invocation, never from repo config.
    export ROUNDHOUSE_FLEET_STORE="$rjj/vireo/store"
    export ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/vireo-key"
    export ROUNDHOUSE_SELFTEST=1
    export ROUNDHOUSE_TRUST_ROOT="$rjj/vireo"
    store="$rjj/vireo/store"
    mkdir -p "$rjj/vireo"
    printf 'name: vireo\ndomain: fleet.example.invalid\n' >"$rjj/vireo/identity.yaml"

    # --- the roster, as pure data: derivation, classes, TTL, lifecycle ---
    # No repository is touched below — only yq over a file — but it lives in
    # this block because the suite sanitizes PATH and yq is only on it here.
    # No jj and no repository: roster derivation and the class rules decide
    # things from a file, and they are the pieces most likely to be quietly
    # wrong. The history-shaped half is the real-jj block below.
    integrity_roster=$integrity_root/signers.yaml
    cat >"$integrity_roster" <<'YAML'
generation: 47
durable:
  vireo:
    principal: vireo@fleet.example.invalid
    key: "ssh-ed25519 AAAAvireo"
    enrolled_by: genesis
    channel_auth: genesis
    enrolled_at: 2020-01-01T00:00:00Z
  wren:
    principal: wren@fleet.example.invalid
    key: "ssh-ed25519 AAAAwren"
    enrolled_by: vireo
    channel_auth: tofu
    enrolled_at: 2020-01-01T00:00:00Z
ephemeral:
  build-x7f2:
    principal: build-x7f2@fleet.example.invalid
    key: "ssh-ed25519 AAAAbuild"
    sponsor: vireo
    job: railyard-deliver-01J9X2
    channel_auth: runtime
    valid_after: 2026-08-07T09:00:00Z
    valid_before: 2026-08-08T09:00:00Z
retired:
  corvid:
    key: "ssh-ed25519 AAAAcorvid"
    revoked_at_commit: 8a1f2c9e
YAML
    [ "$(fleet_trust_generation "$integrity_roster")" = 47 ] ||
      fail "the roster generation was not read"
    # `retired:` is not a member — but this is a FREEZE, not a burn: the entry is
    # gone from the derivation while its past commits still verify against the
    # rosters that listed it.
    ! fleet_trust_render "$integrity_roster" 2026-08-07T12:00:00Z |
      grep -q '^corvid@' ||
      fail "a retired member was still derived into the roster"
    # The window is enforced HERE and only here, and the emitted lines carry no
    # time options: native expiry is evaluated at wall clock and is retroactive.
    fleet_trust_render "$integrity_roster" 2026-08-07T12:00:00Z |
      grep -q '^build-x7f2@fleet.example.invalid namespaces="git" ssh-ed25519 AAAAbuild$' ||
      fail "a leaf inside its window was not derived, or the line is not <principal> namespaces=\"git\" <key>"
    ! fleet_trust_render "$integrity_roster" 2026-08-06T12:00:00Z |
      grep -q '^build-x7f2@' ||
      fail "a leaf was derived BEFORE its valid_after"
    ! fleet_trust_render "$integrity_roster" 2026-08-09T12:00:00Z |
      grep -q '^build-x7f2@' ||
      fail "a lapsed leaf survived the derivation"
    ! fleet_trust_render "$integrity_roster" 2026-08-07T12:00:00Z |
      grep -qE 'valid-before=|valid-after=' ||
      fail "the derived roster emitted a native time option (§7.1b)"
    [ "$(fleet_trust_render "$integrity_roster" 2026-08-07T12:00:00Z | grep -c .)" -eq 3 ] ||
      fail "the derived roster is not exactly the live members"

    # The class, from the same roster the keys came from — never from the head,
    # which would let a later promotion retroactively legalise a past commit.
    fleet_trust_class_map "$integrity_roster" 2026-08-07T12:00:00Z \
      >"$integrity_root/classes"
    [ "$(fleet_trust_class_of "$integrity_root/classes" \
      build-x7f2@fleet.example.invalid)" = ephemeral ] ||
      fail "a leaf's class was not derived"
    [ "$(fleet_trust_class_of "$integrity_root/classes" \
      vireo@fleet.example.invalid)" = durable ] ||
      fail "a durable member's class was not derived"

    # Rule 6, the whole security boundary: a leaf writes its own evidence and
    # nothing else, and it MAY NOT SPONSOR.
    for integrity_refused in fleet.yaml os/macos.yaml groups/development.yaml \
      hosts/vireo.yaml definitions.yaml definitions/10-overrides.yaml trust/signers.yaml \
      checkpoints/1785024000.yaml lineage/x.yaml proposals/x.yaml; do
      ! fleet_trust_class_allows ephemeral "$integrity_refused" ||
        fail "rule 6 let a leaf write $integrity_refused"
      fleet_trust_class_allows durable "$integrity_refused" ||
        fail "rule 6 refused a durable member $integrity_refused"
    done
    for integrity_own in journal/build-x7f2/2026-08-07.yaml \
      applied/build-x7f2.yaml alerts/build-x7f2/x.yaml findings/build-x7f2/x.yaml; do
      fleet_trust_class_allows ephemeral "$integrity_own" ||
        fail "rule 6 refused a leaf its own evidence path: $integrity_own"
    done
    # `joins/` takes ANY signer, including `unknown`: it is inert by
    # construction, so there is nothing for a forged one to authorize.
    [ "$(fleet_vcs_path_owner joins/wren.yaml)" = '+' ] ||
      fail "joins/ did not get its own row"
    fleet_vcs_path_identity_ok joins/wren.yaml '' "$integrity_root/hosts" ||
      fail "joins/ refused an unknown signer, which is the only signer it ever gets"

    # The soak falls out of the class, and `tofu` is visibly the slowest path.
    [ "$(fleet_trust_soak_hours durable tofu)" = 72 ] ||
      fail "tofu did not select the 72h soak"
    [ "$(fleet_trust_soak_hours durable known_hosts)" = 24 ] ||
      fail "known_hosts did not select the 24h soak"
    # `channel_auth: genesis` is a field in a hand-editable roster block, so it
    # is honoured ONLY in the genesis commit's own context. Outside it, it was
    # §7.12.1's control 5 switched off by typing a word.
    [ "$(fleet_trust_soak_hours durable genesis genesis)" = 0 ] ||
      fail "the genesis commit took a soak, and it has no counterparty to protect"
    [ "$(fleet_trust_soak_hours durable genesis)" = 24 ] ||
      fail "channel_auth genesis switched the soak off outside the genesis commit"
    # An absent `enrolled_at` means MAXIMUM caution, not none: it is exactly
    # what an attacker omits, and reading it as "no soak" inverted the control.
    printf 'nostamp@fleet.example.invalid durable - known_hosts\n' \
      >"$integrity_root/nostamp.classes"
    fleet_trust_soak_open "$integrity_root/nostamp.classes" \
      nostamp@fleet.example.invalid 2026-08-07T12:00:00Z ||
      fail "a member carrying no enrolled_at was not held by the soak"
    # An unnamed or unrecognised class gets the LEAF rules, never durable's:
    # the empty class is what the every-parent intersection produces for a
    # principal whose class disagreed across parents, and the intersection's
    # own contract says such a principal is refused.
    ! fleet_trust_class_allows '' fleet.yaml ||
      fail "the empty class was granted a fleet-shared layer"
    ! fleet_trust_class_allows '' trust/signers.yaml ||
      fail "the empty class was permitted to sponsor"
    ! fleet_trust_class_allows future-class fleet.yaml ||
      fail "an unrecognised class was granted a fleet-shared layer"
    fleet_trust_class_allows '' journal/leaf/2026-08-07.yaml ||
      fail "the empty class was refused a host-keyed evidence path"
    # A whitespace-bearing principal shifts every space-joined column, so the
    # row is DROPPED rather than emitted as a malformed allowed_signers line.
    printf 'generation: 1\ndurable:\n  vireo:\n    principal: "vireo fleet"\n    key: "ssh-ed25519 AAAAvireo"\n    enrolled_at: 2020-01-01T00:00:00Z\n    channel_auth: known_hosts\n' \
      >"$integrity_root/shifted.yaml"
    [ -z "$(fleet_trust_render "$integrity_root/shifted.yaml" 2026-08-07T12:00:00Z)" ] ||
      fail "a shifted roster row was rendered into allowed_signers"
    # …and a well-formed one still is, so the NF test is not simply refusing
    # everything.
    [ -n "$(fleet_trust_render "$integrity_roster" 2026-08-07T12:00:00Z)" ] ||
      fail "the NF guard dropped every well-formed roster row"
    [ "$(fleet_trust_soak_hours ephemeral runtime)" = 0 ] ||
      fail "a leaf took a soak, and it has nothing to delay"

    # --- §7.3a C / §7.8: the lifecycle edits, as file operations ---
    cp "$integrity_roster" "$integrity_root/lifecycle.yaml"
    integrity_life=$integrity_root/lifecycle.yaml
    # Removal moves the block and KEEPS THE KEY, so `revoked_at_commit` names the
    # position past which its commits stop verifying — and its earlier ones do not.
    fleet_enroll_cascade "$integrity_life" vireo deadbeef
    fleet_enroll_retire "$integrity_life" vireo deadbeef
    [ "$(yq -r '.retired.vireo.key' "$integrity_life")" = 'ssh-ed25519 AAAAvireo' ] ||
      fail "retiring a member dropped the key its history is verified against"
    [ "$(yq -r '.retired.vireo.revoked_at_commit' "$integrity_life")" = deadbeef ] ||
      fail "the retirement recorded no position in history"
    [ "$(yq -r '.durable | has("vireo")' "$integrity_life")" = false ] ||
      fail "a retired member is still durable"
    # The cascade is a default ACTION, not a rule: vireo's unexpired leaves are
    # retired in the SAME edit, visible in the diff.
    [ "$(yq -r '.retired | has("build-x7f2")' "$integrity_life")" = true ] ||
      fail "the lineage cascade left a departed sponsor's leaf live"

    # Reparenting: an orphan is a leaf whose sponsor left `durable:`. Adoption is
    # cosmetic to the security model, which is why it is safe to be unilateral.
    cp "$integrity_roster" "$integrity_life"
    fleet_enroll_retire "$integrity_life" vireo deadbeef
    [ "$(fleet_enroll_orphans "$integrity_life")" = build-x7f2 ] ||
      fail "an orphaned leaf was not found by the one-hop select"
    fleet_enroll_block "$integrity_life" durable wren "$(jq -cn \
      '{principal:"wren@fleet.example.invalid",key:"ssh-ed25519 AAAAwren"}')"
    [ "$(yq -r '.durable.wren.principal' "$integrity_life")" = \
      wren@fleet.example.invalid ] ||
      fail "a roster block was written as an empty map"
    fleet_enroll_bump "$integrity_life"
    [ "$(fleet_trust_generation "$integrity_life")" = 48 ] ||
      fail "generation did not advance"

    # Pruning is safe here and would not be in a snapshot model: an old commit is
    # verified against the roster at ITS parents, where the entry still exists.
    cp "$integrity_roster" "$integrity_life"
    yq -i -P '.ephemeral.lapsed = .ephemeral.build-x7f2 |
      .ephemeral.lapsed.valid_before = "2020-01-02T00:00:00Z" |
      .ephemeral.build-x7f2.valid_before = "2099-01-01T00:00:00Z"' \
      "$integrity_life"
    fleet_trust_prune_expired "$integrity_life"
    [ "$(yq -r '.ephemeral | has("lapsed")' "$integrity_life")" = false ] ||
      fail "a lapsed leaf survived the 12h prune"
    [ "$(yq -r '.ephemeral | has("build-x7f2")' "$integrity_life")" = true ] ||
      fail "the prune took a leaf that was still inside its window"

    "$cli" fleet-init >/dev/null || fail "fleet-init failed"
    "$cli" fleet-enroll >/dev/null || fail "fleet-enroll failed"
    integrity_genesis=$(fleet_store_id "$store")

    # The ratchet, as one call: derive the roster from EVERY parent, verify.
    integrity_hold_of() {
      fleet_trust_commit_hold "$store" "$1" "$rjj/work.$1" "${2:-}"
    }
    # Become another host for the commits that follow. `behavior = "own"` keys
    # on the commit's AUTHOR, so the `jj new` is what makes the next commit
    # this identity's to sign.
    integrity_as() {
      jj -R "$store" new -m '' >/dev/null
      jj -R "$store" config set --repo user.email "$1@fleet.example.invalid"
      jj -R "$store" config set --repo signing.key "$rjj/$1-key"
      jj -R "$store" new -m '' >/dev/null
    }
    integrity_commit() {
      jj -R "$store" describe -r @ -m "$1" >/dev/null
      jj -R "$store" log -r @ --no-graph -T 'commit_id'
    }

    printf 'probe: enrolled\n' >"$store/fleet.yaml"
    mkdir -p "$store/hosts/wren"
    printf 'platform: macos\n' >"$store/hosts/vireo.yaml"
    printf 'platform: macos\n' >"$store/hosts/wren/base.yaml"
    printf 'platform: macos\n' >"$store/hosts/corvid.yaml"
    integrity_good=$(integrity_commit 'enrolled layers')

    # 1. The pass. Silent, exit 0, both bindings satisfied in ONE read.
    integrity_hold=$(integrity_hold_of "$integrity_good") ||
      fail "a correctly signed commit was held: $integrity_hold"
    [ -z "$integrity_hold" ] ||
      fail "the signature gate printed a hold reason for a good commit: $integrity_hold"
    [ "$(fleet_trust_signature_read "$store" "$integrity_good" \
      "$rjj/work.$integrity_good/roster")" = \
      'good vireo@fleet.example.invalid vireo@fleet.example.invalid' ] ||
      fail "the one-template read did not answer status, principal and committer together"

    # 2. Unsigned — its own message, and it names no principal. `drop` is how a
    #    hand edit made outside roundhouse reaches the store.
    jj -R "$store" new -m '' >/dev/null
    printf 'probe: hand edit\n' >"$store/fleet.yaml"
    jj -R "$store" --config signing.behavior=drop describe -r @ \
      -m 'unsigned hand edit' >/dev/null
    integrity_unsigned=$(jj -R "$store" log -r @ --no-graph -T 'commit_id')
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_unsigned") ||
      integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "an unsigned commit was not held (got $integrity_status)"
    [ "$integrity_hold" = unsigned ] ||
      fail "the unsigned hold message is not §7.3's unsigned message: $integrity_hold"

    # 3. RATCHET DISCRIMINATION — the primitive the whole rule rests on. A
    #    commit by a key the roster at its PARENTS did not list is `unknown`,
    #    and `unknown` is a failure, never "probably fine": under the ratchet
    #    "not yet enrolled" is a newcomer's normal transient state and is
    #    DELIBERATELY indistinguishable from an attacker.
    integrity_as corvid
    printf 'probe: unenrolled\n' >"$store/fleet.yaml"
    integrity_unenrolled=$(integrity_commit 'commit by an unenrolled key')
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_unenrolled") ||
      integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "a commit by a key no parent roster listed was accepted"
    [ "$integrity_hold" = "not in the roster at this commit's parents" ] ||
      fail "the unenrolled hold message points at the wrong thing: $integrity_hold"

    #    …and the SAME key, once a durable member has sponsored it one commit
    #    earlier, verifies. Additions gate forward.
    integrity_as vireo
    rjj_roster "$store/trust/signers.yaml" 2 vireo:durable corvid:durable
    integrity_enrol=$(integrity_commit 'enrol corvid')
    integrity_as corvid
    printf 'probe: enrolled corvid\n' >"$store/fleet.yaml"
    integrity_corvid=$(integrity_commit 'commit by a sponsored key')
    integrity_hold=$(integrity_hold_of "$integrity_corvid") ||
      fail "a sponsored key was still held one commit after its enrollment: $integrity_hold"

    #    …and removal FREEZES rather than burning: corvid's past commit stays
    #    good against the roster at ITS parents, while rule 4 holds anything
    #    corvid signs once this host's reviewed head no longer lists it.
    integrity_as vireo
    rjj_roster "$store/trust/signers.yaml" 3 vireo:durable
    integrity_removed=$(integrity_commit 'retire corvid')
    fleet_trust_roster_at_head "$store" "$integrity_removed" "$rjj/reviewed"
    integrity_hold=$(integrity_hold_of "$integrity_corvid") ||
      fail "retiring corvid retroactively invalidated its past commit: $integrity_hold"
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_corvid" "$rjj/reviewed") ||
      integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "rule 4 did not bite backward on a retired member"
    [ "$integrity_hold" = "no longer in the roster at this host's reviewed head" ] ||
      fail "rule 4's hold message is not its own: $integrity_hold"

    # 4. THE EVERY-PARENT RULE. Two branches off one base, the left still
    #    listing mallory and the right having removed her, with a merge
    #    authored by MALLORY. Under the singular reading — `jj file show -r
    #    <C>-`, which for a merge silently picks one — that merge is ACCEPTED
    #    and a removed member keeps pushing forever. §8.2 manufactures merges
    #    as its normal path, so this is not a corner case.
    integrity_as vireo
    rjj_roster "$store/trust/signers.yaml" 4 vireo:durable mallory:durable
    integrity_base=$(integrity_commit 'base: mallory is a member')
    jj -R "$store" new "$integrity_base" -m '' >/dev/null
    printf 'probe: left\n' >"$store/fleet.yaml"
    integrity_left=$(integrity_commit 'left: no roster change')
    jj -R "$store" new "$integrity_base" -m '' >/dev/null
    rjj_roster "$store/trust/signers.yaml" 5 vireo:durable
    integrity_right=$(integrity_commit 'right: mallory removed')

    integrity_as mallory
    jj -R "$store" new "$integrity_left" "$integrity_right" -m '' >/dev/null
    printf 'probe: exploit\n' >"$store/fleet.yaml"
    integrity_exploit=$(integrity_commit 'merge authored by a removed member')
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_exploit") ||
      integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "EVERY-PARENT: a merge by a member removed on ONE side was accepted — the roster read picked a single parent"
    [ "$integrity_hold" = "not in the roster at this commit's parents" ] ||
      fail "the every-parent refusal did not name the roster: $integrity_hold"
    #    …and it costs a legitimate author nothing: vireo is in BOTH parents'
    #    rosters, so the intersection still lists it.
    integrity_as vireo
    jj -R "$store" new "$integrity_left" "$integrity_right" -m '' >/dev/null
    printf 'probe: legitimate\n' >"$store/fleet.yaml"
    integrity_legit=$(integrity_commit 'merge authored by an enrolled member')
    integrity_hold=$(integrity_hold_of "$integrity_legit") ||
      fail "EVERY-PARENT: a legitimate merge by a member in both parents was held: $integrity_hold"

    # 5. Principal mismatch — the hole §7.3 exists to close. A valid roster key
    #    can still author a commit claiming another host's identity, because
    #    the claimed identity is not an input to verification.
    #    The identity moves but the KEY does not: `behavior = "own"` keys on the
    #    commit's AUTHOR, so the second `jj new` is what makes the commit
    #    corvid's to claim while vireo's key is still the one that signs it.
    jj -R "$store" new -m '' >/dev/null
    jj -R "$store" config set --repo user.email corvid@fleet.example.invalid
    jj -R "$store" new -m '' >/dev/null
    printf 'probe: impersonated\n' >"$store/fleet.yaml"
    integrity_mismatch=$(integrity_commit 'commit claiming another host')
    jj -R "$store" config set --repo user.email vireo@fleet.example.invalid
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_mismatch") ||
      integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "a commit signed by one host and claiming another was accepted"
    [ "$integrity_hold" = \
      'identity mismatch: signature says vireo@fleet.example.invalid, commit says corvid@fleet.example.invalid' ] ||
      fail "the mismatch hold message is not §7.3's identity message: $integrity_hold"

    # 6. MONOTONICITY. A commit's timestamp is inside the signed object, so it
    #    is tamper-evident but self-asserted: a node whose window closed could
    #    sign a commit backdated into it. The assert is free and bounds
    #    backdating to "no earlier than the parent".
    jj -R "$store" new -m '' >/dev/null
    printf 'probe: backdated\n' >"$store/fleet.yaml"
    JJ_TIMESTAMP='2020-01-01T00:00:00Z' jj -R "$store" describe -r @ \
      -m 'a commit backdated past its parent' >/dev/null
    integrity_backdated=$(jj -R "$store" log -r @ --no-graph -T 'commit_id')
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_backdated") ||
      integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "a JJ_TIMESTAMP-backdated commit passed the monotonicity assert"
    case $integrity_hold in
      'timestamp 2020-01-01'*) ;;
      *) fail "the monotonicity hold did not name the timestamps: $integrity_hold" ;;
    esac
    jj -R "$store" new -m '' >/dev/null

    # 7. POSSESSION PROOF, and the namespace separation that keeps the two
    #    worlds apart. A `roundhouse-enroll` proof offered as a commit
    #    signature is refused with `namespace does not match`, and vice versa —
    #    which is why every roster line carries exactly one namespace option.
    fleet_enroll_proof_write leaf@fleet.example.invalid "$rjj/leaf-key" \
      "$rjj/leaf.proof"
    fleet_trust_proof_verify leaf@fleet.example.invalid "$rjj/leaf-key.pub" \
      "$rjj/leaf.proof" ||
      fail "a genuine roundhouse-enroll possession proof did not verify"
    ! fleet_trust_proof_verify leaf@fleet.example.invalid \
      "$rjj/corvid-key.pub" "$rjj/leaf.proof" ||
      fail "a possession proof verified against the WRONG key"
    printf 'leaf@fleet.example.invalid namespaces="git" %s\n' \
      "$(rjj_signer leaf)" >"$rjj/git-namespace-signers"
    ! printf '%s' leaf@fleet.example.invalid |
      /usr/bin/ssh-keygen -Y verify -f "$rjj/git-namespace-signers" \
        -I leaf@fleet.example.invalid -n roundhouse-enroll \
        -s "$rjj/leaf.proof" >/dev/null 2>&1 ||
      fail "an enrollment proof verified against a namespaces=\"git\" roster line — the namespace separation is gone"

    # 8. THE CLASS BOUNDARY, and its ITEM-SCOPED hold. Rule 6 refuses a leaf's
    #    write to a fleet-shared layer at verification, on every host — and
    #    because the content parses and the signature is good and only the
    #    authority is wrong, §7.7 holds only the items whose values that commit
    #    ACTUALLY CHANGED, not every item the file contributes.
    integrity_as vireo
    rjj_roster "$store/trust/signers.yaml" 6 vireo:durable leaf:ephemeral
    printf 'packages:\n  a: latest\n  b: latest\n  c: latest\n' \
      >"$store/fleet.yaml"
    integrity_three=$(integrity_commit 'three-key layer file')
    integrity_as leaf
    printf 'packages:\n  a: latest\n  b: pinned\n  c: latest\n' \
      >"$store/fleet.yaml"
    integrity_leafwrite=$(integrity_commit 'a leaf touches one key of three')
    integrity_hold=$(integrity_hold_of "$integrity_leafwrite") ||
      fail "the leaf's commit failed the signature gate rather than the class rule: $integrity_hold"
    ! fleet_trust_class_allows ephemeral fleet.yaml ||
      fail "rule 6 permitted a leaf to write a fleet-shared layer"
    ! fleet_trust_class_allows ephemeral trust/signers.yaml ||
      fail "rule 6 permitted a leaf to SPONSOR"
    fleet_trust_class_allows ephemeral journal/leaf/2026-08-07.yaml ||
      fail "rule 6 refused a leaf its own evidence path"
    fleet_run_export "$store" "$integrity_leafwrite" "$rjj/leaf-layers"
    printf 'vireo\nleaf\n' >"$rjj/leaf-hosts"
    fleet_run_signature_holds "$store" "$integrity_leafwrite" "$rjj/leaf-hosts" \
      "$rjj/leaf-layers" leaf '' "$rjj/leaf-work" >"$rjj/leaf-holds" 2>/dev/null || :
    [ "$(awk '{ print $1 }' "$rjj/leaf-holds" | LC_ALL=C sort -u | tr '\n' ' ')" = \
      'packages.b ' ] ||
      fail "the class refusal was file-scoped, not item-scoped: $(tr '\n' ';' <"$rjj/leaf-holds")"
    integrity_as vireo

    # 8b. THE ROSTER-BEARING PATH ESCALATES TO A STORE-WIDE HOLD — the trust
    #     boundary. A leaf holding a real key signs a genuinely-GOOD commit that
    #     edits trust/signers.yaml, adding a durable key. trust/ is not a layer
    #     path, so the item-scoped hold path discarded the class refusal entirely
    #     and the roster edit materialized fleet-wide; §7 verification demands a
    #     store-wide `!hold` instead. The signature is good and only the
    #     authority is wrong, which is exactly why the item-scoped drop was the
    #     wrong answer. The leaf commit takes its verifying roster from its PARENT
    #     (the vireo-authored `integrity_rbase`) by ancestry, so main need not
    #     move — nothing here disturbs the sections that follow.
    rjj_roster "$store/trust/signers.yaml" 6 vireo:durable leaf:ephemeral
    integrity_rbase=$(integrity_commit 'roster establishing the leaf')
    integrity_as leaf
    rjj_roster "$store/trust/signers.yaml" 7 \
      vireo:durable leaf:ephemeral mallory:durable
    integrity_leafroster=$(integrity_commit 'a leaf adds a durable key to the roster')
    printf 'vireo\nleaf\n' >"$rjj/lr-hosts"
    fleet_run_export "$store" "$integrity_leafroster" "$rjj/lr-layers"
    fleet_run_signature_holds "$store" "$integrity_leafroster" "$rjj/lr-hosts" \
      "$rjj/lr-layers" leaf '' "$rjj/lr-work" >"$rjj/lr-holds" 2>/dev/null || :
    grep -q '^!hold ' "$rjj/lr-holds" ||
      fail "a leaf's durable-key roster edit was not escalated to a store-wide hold: $(tr '\n' ';' <"$rjj/lr-holds")"
    grep -q '^!hold .*trust/signers.yaml' "$rjj/lr-holds" ||
      fail "the store-wide hold did not name the roster path: $(tr '\n' ';' <"$rjj/lr-holds")"
    integrity_as vireo
    rjj_roster "$store/trust/signers.yaml" 6 vireo:durable

    # 9. SOAK, by class. The policy falls out of the class rather than being a
    #    knob, and `tofu` — the weakest channel — is visibly the slowest.
    [ "$(fleet_trust_soak_hours durable tofu)" = 72 ] ||
      fail "a tofu enrollment does not take the 72h soak"
    [ "$(fleet_trust_soak_hours durable known_hosts)" = 24 ] ||
      fail "a known_hosts enrollment does not take the 24h soak"
    [ "$(fleet_trust_soak_hours ephemeral runtime)" = 0 ] ||
      fail "a leaf takes a soak, and it has nothing to delay"
    printf 'fresh@fleet.example.invalid durable %s tofu\n' "$(fleet_now)" \
      >"$rjj/soak.classes"
    printf 'old@fleet.example.invalid durable 2020-01-01T00:00:00Z known_hosts\n' \
      >>"$rjj/soak.classes"
    fleet_trust_soak_open "$rjj/soak.classes" fresh@fleet.example.invalid \
      "$(fleet_now)" ||
      fail "a key enrolled just now was not inside its soak window"
    ! fleet_trust_soak_open "$rjj/soak.classes" old@fleet.example.invalid \
      "$(fleet_now)" ||
      fail "a key enrolled in 2020 was reported inside its soak window"

    # 10. TTL is enforced in the DERIVATION ONLY, and freezes rather than
    #     burning: a lapsed leaf's own past commits still verify, because each
    #     is evaluated against the roster at its own parents.
    rjj_roster "$rjj/ttl.yaml" 1 vireo:durable leaf:ephemeral:2026-01-01T00:00:00Z
    fleet_trust_render "$rjj/ttl.yaml" 2025-06-01T00:00:00Z |
      grep -q '^leaf@' ||
      fail "a leaf inside its window was filtered out of the roster"
    ! fleet_trust_render "$rjj/ttl.yaml" 2026-06-01T00:00:00Z |
      grep -q '^leaf@' ||
      fail "a lapsed leaf survived the roster derivation"
    ! fleet_trust_render "$rjj/ttl.yaml" 2025-06-01T00:00:00Z |
      grep -qE 'valid-before=|valid-after=' ||
      fail "the derived roster emitted a native time option, which is evaluated at WALL CLOCK and is therefore retroactive"

    # 11. CHECKPOINTS ARE TAGS. jj 0.44's default immutable set is
    #     `trunk() | tags() | untracked_remote_bookmarks()`, so a tag makes the
    #     commit AND ALL ITS ANCESTORS immutable for free. A BOOKMARK DOES NOT.
    integrity_tagtarget=$(integrity_commit 'checkpoint target')
    jj -R "$store" bookmark set rh-not-a-tag -r "$integrity_tagtarget" >/dev/null
    jj -R "$store" describe -r "$integrity_tagtarget" -m 'bookmarked, still mutable' \
      >/dev/null 2>&1 ||
      fail "a bookmark unexpectedly conferred immutability — re-derive §7.10.1"
    integrity_tagtarget=$(jj -R "$store" log -r 'bookmarks(exact:"rh-not-a-tag")' \
      --no-graph -T 'commit_id')
    fleet_trust_checkpoint_tag "$store" "$integrity_tagtarget" 1 ||
      fail "could not tag the checkpoint commit"
    [ "$(jj -R "$store" log -r "$integrity_tagtarget" --no-graph -T 'immutable')" = \
      true ] ||
      fail "a tagged checkpoint is not immutable"
    ! jj -R "$store" describe -r "$integrity_tagtarget" -m tamper >/dev/null 2>&1 ||
      fail "a tagged checkpoint commit was rewritten"

    # 12. THE ARCHIVE IS MANDATORY, and its ABSENCE is the rollback protection:
    #     a host whose reviewed-ref is not an ancestor of the fetched head, with
    #     no archive containing it, must HOLD rather than adopt.
    #     The trigger is a CHANGED ROOT: pin this host to a store_id the fetched
    #     head does not root at, which is exactly what a re-root looks like from
    #     a host that was offline across it.
    printf 'name: vireo\ndomain: fleet.example.invalid\nstore_id: %s\n' \
      "$integrity_unenrolled" >"$rjj/vireo/identity.yaml"
    printf '%s\n' "$integrity_unenrolled" >"$rjj/vireo/reviewed-ref"
    integrity_catch=$(fleet_trust_catch_up "$store" "$integrity_genesis") ||
      integrity_status=$?
    case $integrity_catch in
      *'absent from the archive'*) ;;
      *) fail "a head that does not descend from reviewed-ref was adopted without an archive: '$integrity_catch'" ;;
    esac
    printf 'name: vireo\ndomain: fleet.example.invalid\nstore_id: %s\n' \
      "$integrity_genesis" >"$rjj/vireo/identity.yaml"
    printf '%s\n' "$integrity_genesis" >"$rjj/vireo/reviewed-ref"
    [ -z "$(fleet_trust_catch_up "$store" "$integrity_legit")" ] ||
      fail "an ordinary head rooted at the pinned genesis was refused by the archive protocol"
    printf 'name: vireo\ndomain: fleet.example.invalid\n' \
      >"$rjj/vireo/identity.yaml"

    # 12a. §7.12.5 — THE HUB-ONLY ATTACKER, in two commits. An attacker holding
    #     only the hub credential and NO roster key anywhere pushes C1 (adds
    #     their own key to trust/signers.yaml, self-signed) and C2, its child
    #     (desired state, same key). C1 is correctly refused. C2 then verifies
    #     GOOD, because rule 3 materializes its roster from its only parent —
    #     C1 — whose bytes list the attacker. The ratchet checks each commit
    #     against whatever sits at its parent; nothing required the commit that
    #     PUT those bytes there to have verified.
    #
    #     C1's rejection bought nothing on its own: `trust/signers.yaml` is not
    #     a layer path, so a rejected roster commit produced ZERO held items
    #     while still supplying the roster that legitimised every descendant.
    #     The refusal is therefore store-wide, and the run escalates it exactly
    #     as it escalates materialization drift.
    integrity_as vireo
    rjj_roster "$store/trust/signers.yaml" 10 vireo:durable
    printf 'probe: before the attack\n' >"$store/fleet.yaml"
    integrity_pre=$(integrity_commit 'baseline before the self-enrolment')
    integrity_as mallory
    rjj_roster "$store/trust/signers.yaml" 11 vireo:durable mallory:durable
    printf 'platform: macos\n' >"$store/hosts/mallory.yaml"
    integrity_c1=$(integrity_commit 'C1: mallory enrols herself, signed by herself')
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_c1") || integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "SELF-ENROL: a roster commit signed by a key no parent roster listed was accepted"
    jj -R "$store" new -m '' >/dev/null
    printf 'probe: OWNED BY MALLORY\n' >"$store/fleet.yaml"
    integrity_c2=$(integrity_commit 'C2: mallory writes desired state')
    # The ratchet still accepts C2 in isolation — that is the honest shape of
    # roster-at-parent — so the control is at the RUN, where a rejected roster
    # commit becomes a store-wide refusal instead of an empty item hold set.
    fleet_run_export "$store" "$integrity_c2" "$rjj/selfenrol-layers"
    printf 'vireo\nmallory\n' >"$rjj/selfenrol-hosts"
    fleet_run_signature_holds "$store" "$integrity_pre..$integrity_c2" \
      "$rjj/selfenrol-hosts" "$rjj/selfenrol-layers" vireo '' \
      "$rjj/selfenrol-work" >"$rjj/selfenrol-holds" 2>/dev/null || :
    grep -q '^!hold ' "$rjj/selfenrol-holds" ||
      fail "SELF-ENROL: a rejected trust/signers.yaml commit produced no store-wide hold, so its child's desired state applied: $(tr '\n' ';' <"$rjj/selfenrol-holds")"
    grep -q "$integrity_c1" "$rjj/selfenrol-holds" ||
      fail "the store-wide hold does not name the roster commit that caused it"

    # 12b. §7.1a — A MISSING KRL IS NOT "NO HOLDS". An unresolvable revocation
    #     list makes ssh-keygen report every signature `bad`, so returning the
    #     same empty output a fully verified range produces turned every gate
    #     in §7 off silently.
    mv "$rjj/vireo/krl" "$rjj/krl.hidden"
    fleet_run_signature_holds "$store" "$integrity_pre..$integrity_c2" \
      "$rjj/selfenrol-hosts" "$rjj/selfenrol-layers" vireo '' \
      "$rjj/selfenrol-work2" >"$rjj/krl-holds" 2>/dev/null || :
    grep -q '^!hold ' "$rjj/krl-holds" ||
      fail "a missing KRL silently disabled the whole signature gate (§7.1a)"
    mv "$rjj/krl.hidden" "$rjj/vireo/krl"

    # …and the bootstrap carve-out survives, narrowed to the state that
    # actually needs it: a store BETWEEN fleet-init and fleet-enroll has no
    # genesis, so it can verify nothing and holding everything would brick
    # §12's own sequence. `fleet-init` deliberately creates no history, which
    # is exactly that state — and this instance root has no KRL either.
    mkdir -p "$rjj/pregenesis"
    printf 'name: pregenesis\ndomain: fleet.example.invalid\n' \
      >"$rjj/pregenesis/identity.yaml"
    env ROUNDHOUSE_FLEET_STORE="$rjj/pregenesis/store" \
      ROUNDHOUSE_TRUST_ROOT="$rjj/pregenesis" ROUNDHOUSE_SELFTEST=1 \
      "$cli" fleet-init >/dev/null ||
      fail "could not stage a pre-enrollment store"
    [ -z "$(fleet_store_id "$rjj/pregenesis/store")" ] ||
      fail "the pre-enrollment fixture already has a genesis"
    [ ! -f "$rjj/pregenesis/krl" ] ||
      fail "the pre-enrollment fixture already has a KRL"
    [ -z "$(ROUNDHOUSE_TRUST_ROOT=$rjj/pregenesis fleet_run_signature_holds \
      "$rjj/pregenesis/store" 'all()' "$rjj/selfenrol-hosts" \
      "$rjj/selfenrol-layers" pregenesis '' "$rjj/selfenrol-work3" 2>/dev/null)" ] ||
      fail "the pre-enrollment carve-out is gone; §12's bootstrap would brick"

    integrity_as vireo
    rjj_roster "$store/trust/signers.yaml" 12 vireo:durable
    rm -f "$store/hosts/mallory.yaml"
    printf 'probe: recovered\n' >"$store/fleet.yaml"
    integrity_recovered=$(integrity_commit 'retire the self-enrolled key')

    # 12c. §7.11.2 — THE SEVEN-STEP CATCH-UP, all three outcomes. The archive
    #     is what distinguishes a legitimate re-root from the §7.12.3 rollback
    #     attack, and steps 4-5 are what make the archive mean something: an
    #     archive nobody verified is a bag of commits an attacker chose to keep.
    integrity_archive_ref=$(fleet_trust_archive_ref 20260807)
    "$REAL_GIT" -C "$store" update-ref "$integrity_archive_ref" \
      "$integrity_recovered"
    printf '%s\n' "$integrity_recovered" >"$rjj/vireo/reviewed-ref"
    printf 'name: vireo\ndomain: fleet.example.invalid\nstore_id: %s\n' \
      "$integrity_genesis" >"$rjj/vireo/identity.yaml"

    #     The ATTACK: a brand-new parentless root, self-signed, listing only
    #     the attacker, published alongside the GENUINE old history as the
    #     archive (the attacker has it — it is what they just replaced). Steps
    #     1-3 all pass. The implementation then ran the ordinary ratchet on the
    #     NEW ROOT, which has no parents, so roster derivation took the genesis
    #     branch and verified it AGAINST ITS OWN ROSTER — the circular read §7.1
    #     opens by calling broken. Self-signed R passed and the run adopted it.
    jj -R "$store" new 'root()' -m '' >/dev/null
    jj -R "$store" config set --repo user.email mallory@fleet.example.invalid
    jj -R "$store" config set --repo signing.key "$rjj/mallory-key"
    jj -R "$store" new 'root()' -m '' >/dev/null
    mkdir -p "$store/trust"
    rjj_roster "$store/trust/signers.yaml" 99999 mallory:durable
    printf 'probe: OWNED\n' >"$store/fleet.yaml"
    integrity_evilroot=$(integrity_commit 'attacker root')
    integrity_status=0
    integrity_catch=$(fleet_trust_catch_up "$store" "$integrity_evilroot") ||
      integrity_status=$?
    [ "$integrity_status" -ne 0 ] ||
      fail "RE-ROOT: the seven-step catch-up ADOPTED an attacker-authored root"
    case $integrity_catch in
      *'not signed by a key the checkpoint trusts'*) ;;
      *) fail "the re-root refusal does not name the checkpoint's roster as the authority: '$integrity_catch'" ;;
    esac
    #     …and the same parentless commit cannot self-verify through the
    #     ordinary gate either, which is the guard that makes this independent
    #     of the catch-up path: `fleet_trust_parents` cannot tell "no parents"
    #     from "the query failed", and both used to land in the genesis branch.
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_evilroot") || integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "a NEW parentless commit verified against its own roster (§7.1's circular read)"

    #     The LEGITIMATE re-root: the same shape, signed by a key the archived
    #     checkpoint's roster lists. It is adopted, and reviewed-ref advances —
    #     step 7 — so materialization's descendant gate does not then refuse
    #     the head forever.
    jj -R "$store" new 'root()' -m '' >/dev/null
    jj -R "$store" config set --repo user.email vireo@fleet.example.invalid
    jj -R "$store" config set --repo signing.key "$rjj/vireo-key"
    jj -R "$store" new 'root()' -m '' >/dev/null
    mkdir -p "$store/trust"
    rjj_roster "$store/trust/signers.yaml" 12 vireo:durable
    printf 'probe: re-rooted\n' >"$store/fleet.yaml"
    integrity_newroot=$(integrity_commit 're-root on the checkpointed state')
    integrity_catch=$(fleet_trust_catch_up "$store" "$integrity_newroot") ||
      fail "a legitimate re-root signed by a key the checkpoint trusts was refused: $integrity_catch"
    [ -z "$integrity_catch" ] ||
      fail "the legitimate re-root printed a hold reason: $integrity_catch"
    [ "$(fleet_trust_reviewed_ref)" = "$integrity_newroot" ] ||
      fail "step 7 did not advance reviewed-ref past the re-root"

    #     And the MISSING ARCHIVE is still the rollback protection.
    printf '%s\n' "$integrity_recovered" >"$rjj/vireo/reviewed-ref"
    "$REAL_GIT" -C "$store" update-ref -d "$integrity_archive_ref"
    integrity_status=0
    integrity_catch=$(fleet_trust_catch_up "$store" "$integrity_evilroot") ||
      integrity_status=$?
    [ "$integrity_status" -ne 0 ] ||
      fail "a re-root with no archive at all was adopted"
    case $integrity_catch in
      *'absent from the archive'*) ;;
      *) fail "the no-archive refusal is not the rollback message: '$integrity_catch'" ;;
    esac
    printf 'name: vireo\ndomain: fleet.example.invalid\n' \
      >"$rjj/vireo/identity.yaml"
    rm -f "$rjj/vireo/reviewed-ref"
    integrity_as vireo

    # 12d. §7.9's DETECTION COMPARE, at one instant. Both sides are renders of
    #     the SAME revision, so the only variable is the clock — and
    #     `fleet_trust_render` filters valid_after/valid_before against it. The
    #     compare re-rendered at wall clock while the materialized file had been
    #     rendered earlier, so ANY ephemeral leaf whose window boundary fell
    #     between two runs produced a byte difference. §7.3a D mints those at a
    #     design rate of ~40/day and the fast cadence is 20 minutes, so this
    #     fired fleet-wide on essentially every run — and its consequence is a
    #     loud alert plus `exit 65`, "holding everything", named as the tamper
    #     signature. The instants are pinned here rather than waited for.
    rjj_roster "$rjj/drift.yaml" 1 vireo:durable \
      leaf:ephemeral:2020-01-01T00:00:00Z
    integrity_drift_at=2019-01-01T00:00:00Z
    integrity_drift_rev=$(fleet_vcs_heads_local "$store" | head -1)
    jj -R "$store" file show -r "$integrity_drift_rev" \
      "root:$fleet_trust_roster_file" >"$rjj/drift.reviewed" 2>/dev/null || :
    cp "$rjj/drift.yaml" "$store/$fleet_trust_roster_file"
    integrity_drift_rev=$(integrity_commit 'a roster carrying a leaf that lapses in 2020')
    #     Materialize the way trustd does: render at ONE instant, at which the
    #     leaf is live, and record that instant beside the file.
    fleet_trust_roster_at_head "$store" "$integrity_drift_rev" \
      "$rjj/vireo/allowed_signers" "$integrity_drift_at"
    printf '%s\n' "$integrity_drift_at" >"$rjj/vireo/materialized-at"
    printf '%s\n' "$integrity_drift_rev" >"$rjj/vireo/reviewed-ref"
    grep -q '^leaf@' "$rjj/vireo/allowed_signers" ||
      fail "the drift fixture did not materialize the leaf that is live at its instant"
    #     Wall clock is years past that leaf's window. The file is untouched.
    [ -z "$(fleet_trust_materialization_drift "$store")" ] ||
      fail "an ephemeral TTL boundary between the materialize and the compare read as roster tamper (§7.9)"
    #     …and the row still SEES a real edit, which is the whole point of it.
    printf 'attacker@fleet.example.invalid namespaces="git" %s\n' \
      "$(rjj_signer mallory)" >>"$rjj/vireo/allowed_signers"
    [ -n "$(fleet_trust_materialization_drift "$store")" ] ||
      fail "a key appended to the materialized roster was not detected (§7.9)"
    #     A compare with no recorded instant has nothing to ask about and is
    #     silent rather than guessing at wall clock; the next materialize
    #     writes one.
    rm -f "$rjj/vireo/materialized-at"
    [ -z "$(fleet_trust_materialization_drift "$store")" ] ||
      fail "the compare fell back to wall clock when no instant was recorded"
    cp "$rjj/drift.reviewed" "$store/$fleet_trust_roster_file"
    integrity_drift_rev=$(integrity_commit 'restore the roster after the drift fixture')
    rm -f "$rjj/vireo/reviewed-ref"
    fleet_trust_materialize "$store" "$integrity_drift_rev" ||
      fail "could not re-materialize after the drift fixture"

    integrity_signers="$rjj/vireo/allowed_signers"
    integrity_krl="$rjj/vireo/krl"
    cp "$integrity_krl" "$rjj/krl.good"

    # 13. Revocation. `bad` with MATCHING principals is the case a single
    #     message template renders as "bad: vireo@… != vireo@…", pointing the
    #     operator at an identity mismatch that does not exist. Branching on
    #     status first is what fixes it, so assert the message names exactly
    #     one principal — and note this is the EMERGENCY lever, not removal.
    rjj_krl revoked.krl "$rjj/vireo-key.pub"
    cp "$rjj/revoked.krl" "$integrity_krl"
    integrity_status=0
    integrity_hold=$(integrity_hold_of "$integrity_good") ||
      integrity_status=$?
    [ "$integrity_status" -eq 1 ] ||
      fail "a KRL-revoked key still verified"
    [ "$integrity_hold" = 'signature bad' ] ||
      fail "the revoked hold message is not §7.3's status message: $integrity_hold"
    [ "$(printf '%s' "$integrity_hold" | grep -c '@' || true)" -eq 0 ] ||
      fail "the revocation hold named a principal, so it reads as an identity mismatch"
    cp "$rjj/krl.good" "$integrity_krl"

    # 14. A KRL path that does not resolve reports `bad` for EVERYTHING —
    #    indistinguishable from mass revocation, and in practice a typo. Prove
    #    the hazard is real against raw jj, then require the gate to refuse
    #    the configuration loudly instead of rendering it as a fleet-wide
    #    hold.
    integrity_raw=$(jj -R "$store" \
      --config signing.backends.ssh.program='"/usr/bin/ssh-keygen"' \
      --config signing.backends.ssh.allowed-signers="\"$integrity_signers\"" \
      --config signing.backends.ssh.revocation-list="\"$rjj/no-such.krl\"" \
      log -r "$integrity_good" --no-graph -T 'signature.status()')
    [ "$integrity_raw" = bad ] ||
      fail "an unresolved KRL path no longer reports every signature bad (got '$integrity_raw') — re-derive the §7.1 pre-check"
    mv "$integrity_krl" "$rjj/krl.parked"
    integrity_status=0
    integrity_hold_of "$integrity_good" >/dev/null 2>&1 ||
      integrity_status=$?
    [ "$integrity_status" -eq 78 ] ||
      fail "a missing revocation list was rendered as a signature verdict instead of refused (got $integrity_status)"
    mv "$rjj/krl.parked" "$integrity_krl"

    # 15. Row 1's membership set, over both §2 path kinds, at a real revision.
    integrity_hosts=$(fleet_vcs_enrolled_hosts "$store" "$integrity_good")
    [ "$(printf '%s\n' "$integrity_hosts" | tr '\n' ' ')" = 'corvid vireo wren ' ] ||
      fail "the enrolled host set did not cover hosts/<h>.yaml and hosts/<h>/: $integrity_hosts"
    printf '%s\n' "$integrity_hosts" >"$rjj/hosts"
    ! fleet_vcs_path_identity_ok journal/wren/2026-08-07.yaml \
      vireo@fleet.example.invalid "$rjj/hosts" ||
      fail "row 2 accepted forged peer evidence against a real host list"

    # 16. §7.5, wired: the comparison guards every operation that changes which
    #    repository this host talks to, and only a HOST-LOCAL expected value
    #    tells two fleets on one remote apart.
    fleet_vcs_store_ready "$store" ||
      fail "the store-identity guard refused this host's own store"
    printf 'name: vireo\ndomain: fleet.example.invalid\nstore_id: %s\n' \
      0000000000000000 >"$rjj/vireo/identity.yaml"
    integrity_status=0
    fleet_vcs_store_ready "$store" >/dev/null 2>&1 || integrity_status=$?
    [ "$integrity_status" -eq 65 ] ||
      fail "the store-identity guard accepted a store belonging to another fleet (got $integrity_status)"
    printf 'name: vireo\ndomain: fleet.example.invalid\n' \
      >"$rjj/vireo/identity.yaml"
    integrity_status=0
    fleet_vcs_store_ready "$rjj/nowhere" >/dev/null 2>&1 || integrity_status=$?
    [ "$integrity_status" -eq 69 ] ||
      fail "the store-identity guard accepted a path with no store (got $integrity_status)"

    # 17. The predicate against a real journal directory, in the shape §5
    #    publishes: date-named files, oldest first, this host's own only.
    mkdir -p "$store/journal/vireo"
    cat >"$store/journal/vireo/2026-08-06.yaml" <<'YAML'
- item: plugins.ponytail
  digest: 0ada03724bef
  outcome: applied
  at: 2026-08-06T09:14:02Z
- item: skills.legal
  digest: b71ec0de
  outcome: held
  at: 2026-08-06T09:14:05Z
YAML
    cat >"$store/journal/vireo/2026-08-07.yaml" <<'YAML'
- item: plugins.ponytail
  digest: 91ac33bad000
  outcome: applied
  at: 2026-08-07T09:14:02Z
YAML
    integrity_outcomes=$(fleet_vcs_journal_outcomes "$store/journal/vireo" \
      plugins.ponytail)
    [ "$(printf '%s\n' "$integrity_outcomes" | tr '\n' '|')" = \
      'applied 0ada03724bef|applied 91ac33bad000|' ] ||
      fail "the journal reader did not return this item's outcomes oldest-first: $integrity_outcomes"
    printf '%s\n' "$integrity_outcomes" |
      fleet_vcs_revert_signature 0ada03724bef ||
      fail "§10.8 did not fire on a real journal recording apply-then-supersede"
    ! printf '%s\n' "$integrity_outcomes" |
      fleet_vcs_revert_signature 91ac33bad000 ||
      fail "§10.8 fired on the currently applied digest (a promotion re-reviews nothing)"

    printf 'real-jj: OK (ratchet discrimination, every-parent merge, monotonicity, possession proof, item-scoped class hold, soak, TTL freeze, checkpoint tag, missing archive, KRL, row 1/row 2, genesis pin, revert predicate)\n'
  ) || fail "real-jj integrity block failed (see the FAIL: real-jj: line above)"
fi
