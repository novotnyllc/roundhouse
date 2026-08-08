# roundhouse — fleet store bootstrap: the fleet-init / fleet-enroll split.
#
# The split is not stylistic. With `signing.behavior = "own"` and a
# `signing.key` naming a file that does not exist, jj 0.44 does not merely
# fail to sign: `jj git init --colocate` dies with "Internal error: Failed to
# check out the initial commit / … Signing error" and THE REPO IS NEVER
# CREATED (§3.3, reproduced in tests/90-jj-bootstrap.sh). So fleet-init writes
# every pin EXCEPT `[signing]`, leaving a fully operable unsigned store, and
# fleet-enroll writes `[signing]` only after it has MINTED the key. Merging
# them back together, or writing `[signing]` from a helper either one calls,
# destroys the store on first run.
#
# This unit also carries the lifecycle verbs (§7.3a, §7.8, §7.11), because they
# are all the same operation seen from different angles: one ratchet-valid edit
# to `trust/signers.yaml`, signed by a key the file already trusted one commit
# earlier. There is no CA, no certificate and no authority to contact.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_jj_pins() {
  # §3.1, minus `[signing]` — see the file header. Every line is a decision
  # traceable to an observed failure; the spec carries the reasoning and this
  # table is its single machine-readable form, written by fleet-init and read
  # back by doctor. `user.email` is absent on purpose: it must equal this
  # host's roster principal, and at fleet-init time no key exists yet.
  #
  # `snapshot.auto-track` and `snapshot.max-new-file-size` are deliberately
  # NOT here: on jj 0.44 the default `auto-track = all()` tracked neither
  # .DS_Store nor *.swp nor *~, so the v1 pins bought nothing.
  #
  # Values are TOML expressions, because that is what `jj config set` takes.
  # `ui.editor` is a COMMAND and must be a TOML string: the bare token `true`
  # types as a boolean and every later jj command in the repo then dies with
  # "Invalid type or value for ui.editor" — which is a bricked store reached
  # by a different road. The three genuine booleans below stay bare.
  cat <<'EOF'
user.name roundhouse-sync
ui.paginate never
ui.editor "true"
ui.conflict-marker-style snapshot
ui.show-cryptographic-signatures true
git.abandon-unreachable-commits false
git.write-change-id-header true
EOF
}

fleet_git_pins() {
  # §3.2 point 3: the colocated .git is pinned hermetic. The owner's global
  # git config signs commits through 1Password's op-ssh-sign, so ANY agent
  # running `git commit` inside the store pops an approval dialog — and §8.4's
  # own premise is that agents shell out to git. These repo-local values win
  # over the global ones. `core.symlinks false` rides along: store content is
  # data, so a symlink in the store materializes as a plain file rather than a
  # link out of it.
  cat <<'EOF'
commit.gpgsign false
tag.gpgsign false
gpg.ssh.program ssh-keygen
core.pager cat
core.editor true
core.symlinks false
EOF
}

fleet_apply_jj_pins() {
  while read -r pin_key pin_value; do
    [ -n "$pin_key" ] || continue
    jj -R "$1" config set --repo "$pin_key" "$pin_value" >/dev/null
  done <<EOF
$(fleet_jj_pins)
EOF
}

fleet_apply_git_pins() {
  while read -r pin_key pin_value; do
    [ -n "$pin_key" ] || continue
    git -C "$1" config "$pin_key" "$pin_value"
  done <<EOF
$(fleet_git_pins)
EOF
}

fleet_pins_drift() {
  # Doctor's rows for §3.1/§3.2 (phase 10): one line per pin whose EFFECTIVE
  # value disagrees with the table, as `<key> <expected> <actual>`. Effective
  # values only — never file contents, because jj 0.44 migrates a written
  # `.jj/repo/config.toml` into ~/.config/jj/repos/<hash>/ and replaces the
  # original with a symlink into $HOME inside the store tree.
  while read -r pin_key pin_value; do
    [ -n "$pin_key" ] || continue
    # `jj config get` answers with the VALUE, so the table's TOML quoting is
    # not part of what comes back.
    pin_expect=${pin_value#\"}
    pin_expect=${pin_expect%\"}
    pin_actual=$(jj -R "$1" config get "$pin_key" 2>/dev/null || true)
    [ "$pin_actual" = "$pin_expect" ] ||
      printf '%s %s %s\n' "$pin_key" "$pin_expect" "${pin_actual:-<unset>}"
  done <<EOF
$(fleet_jj_pins)
EOF
  while read -r pin_key pin_value; do
    [ -n "$pin_key" ] || continue
    pin_actual=$(git -C "$1" config --get "$pin_key" 2>/dev/null || true)
    [ "$pin_actual" = "$pin_value" ] ||
      printf '%s %s %s\n' "$pin_key" "$pin_value" "${pin_actual:-<unset>}"
  done <<EOF
$(fleet_git_pins)
EOF
}

fleet_signing_ready() {
  # Doctor's R4 row (phase 10): `[signing]` present implies the key file it
  # names exists. The moment that stops holding, the next command that has to
  # create a working-copy commit bricks the store — which is the whole reason
  # fleet-init and fleet-enroll are two commands.
  ready_key=$(jj -R "$1" config get signing.key 2>/dev/null || true)
  [ -n "$ready_key" ] || return 0
  [ -f "$ready_key" ] || {
    printf 'roundhouse: signing.key names a file that does not exist: %s\n' \
      "$ready_key" >&2
    return 1
  }
}

# --- the roster, as an editable file ------------------------------------------

fleet_enroll_roster_path() {
  printf '%s/%s\n' "$1" "$fleet_trust_roster_file"
}

fleet_enroll_roster_touch() {
  # An absent roster is not an error at genesis; every other caller has already
  # asserted the store is enrolled.
  mkdir -p "$(dirname "$1")"
  [ -f "$1" ] || printf 'generation: 0\n' >"$1"
}

fleet_enroll_bump() {
  # `generation:` is monotonic, and its whole value is custody (§7.9): in the
  # store it is attacker-controlled by construction — the attacker force-pushing
  # history writes the generation too — so the defence is the host-local
  # high-water mark, not this number. Bumping it is still what makes the
  # high-water mark able to say "backward".
  yq -i -P '.generation = ((.generation // 0) + 1)' "$1"
}

fleet_enroll_block() {
  # fleet_enroll_block <roster> <class> <name> <json-object>
  #
  # One block per machine. `enrolled_by` / `sponsor` are CLEANUP METADATA AND
  # NOTHING ELSE: no verification path ever reads them, and a sponsor's
  # departure cannot invalidate its leaves. Auto-invalidating on sponsor
  # departure would be the retroactive-revocation mistake a third time — one
  # machine's removal cascading into a fleet-wide outage — and in an agent fleet
  # sponsors are rebuilt routinely.
  # Direct path assignment, never `(.x // {} | .y = z)`: measured on yq v4.53,
  # the piped form evaluates the assignment in a detached context and writes
  # back an EMPTY map — so the roster silently loses the block it just added.
  FLEET_ENROLL_CLASS=$2 FLEET_ENROLL_NAME=$3 FLEET_ENROLL_BLOCK=$4 yq -i -P '
    .[strenv(FLEET_ENROLL_CLASS)][strenv(FLEET_ENROLL_NAME)] =
      (strenv(FLEET_ENROLL_BLOCK) | from_json)
  ' "$1"
}

fleet_enroll_retire() {
  # fleet_enroll_retire <roster> <name> <at-commit>
  #
  # Revocation lives IN THE CHAIN, and position in history decides validity: the
  # block moves to `retired:` and the key's PAST commits stay good, because the
  # roster at their own parents still listed it. The KRL is not used here — it
  # is retroactive and total, so revoking a machine that way flips every commit
  # it ever made to `bad` and holds every item resolved from every file those
  # commits touched. On a fleet where any durable host may edit any shared
  # layer, that is a self-inflicted outage only a full re-commit clears.
  # `as $block` binds before the deletes, so the retired entry keeps the key
  # it is retiring. Direct paths for the same reason as fleet_enroll_block.
  FLEET_ENROLL_NAME=$2 FLEET_ENROLL_AT=$3 yq -i -P '
    ((.durable[strenv(FLEET_ENROLL_NAME)] //
      .ephemeral[strenv(FLEET_ENROLL_NAME)]) // {}) as $block |
    .retired[strenv(FLEET_ENROLL_NAME)].key = ($block.key // "") |
    .retired[strenv(FLEET_ENROLL_NAME)].revoked_at_commit = strenv(FLEET_ENROLL_AT) |
    del(.durable[strenv(FLEET_ENROLL_NAME)]) |
    del(.ephemeral[strenv(FLEET_ENROLL_NAME)])
  ' "$1"
}

fleet_enroll_cascade() {
  # fleet_enroll_cascade <roster> <departing> <at-commit>
  #
  # Cascade survives as a default ACTION, not a rule: told "remove vireo", the
  # revocation commit also retires vireo's unexpired ephemera in the SAME
  # commit, by default — one explicit, reviewable edit visible in the diff. So
  # "remove vireo but keep its sandboxes running" is different commit content
  # rather than an impossible request.
  #
  # ONE `yq` SELECT, NEVER A GRAPH WALK: leaves cannot sponsor, so the sponsor
  # graph is exactly one hop deep. Revsets answer the commit DAG; this question
  # is not in the DAG and does not need to be.
  FLEET_ENROLL_NAME=$2 yq -r '
    (.ephemeral // {}) | to_entries | .[] |
    select(.value.sponsor == strenv(FLEET_ENROLL_NAME)) | .key
  ' "$1" 2>/dev/null | while IFS= read -r fleet_enroll_leaf; do
    [ -n "$fleet_enroll_leaf" ] || continue
    fleet_enroll_retire "$1" "$fleet_enroll_leaf" "$3"
  done
}

fleet_enroll_orphans() {
  # An ORPHAN is an `ephemeral:` entry whose `sponsor:` no longer appears in
  # `durable:`. Adoption is safe to be unilateral precisely because it is
  # cosmetic to the security model: it keeps the cleanup queries answerable and
  # nothing else depends on it.
  yq -r '
    (.durable // {} | keys) as $live |
    (.ephemeral // {}) | to_entries | .[] |
    select((.value.sponsor // "") as $s | ($live | contains([$s])) | not) | .key
  ' "$1" 2>/dev/null || true
}

# --- key material -------------------------------------------------------------

fleet_enroll_keygen() {
  # §3.3, and it is the whole of what enrollment does locally: no certificate
  # request, no authority to contact, NO SUDO, no ceremony.
  [ ! -f "$1" ] || return 0
  mkdir -p "$(dirname "$1")"
  chmod 700 "$(dirname "$1")" 2>/dev/null || :
  "$(system_ssh_keygen_path)" -q -t ed25519 -f "$1" -N '' -C '' </dev/null
}

fleet_enroll_proof_write() {
  # fleet_enroll_proof_write <principal> <key> <dest>. Signing the principal in
  # a DEDICATED namespace is what stops a sponsor enrolling a key nobody
  # controls (a typo, or an attacker-supplied blob), and the namespace is what
  # stops the proof being replayed as a commit signature.
  #
  # `ssh-keygen -Y sign` prompts `overwrite (y/n)?` when the .sig already
  # exists — it hung a lab for 120 s — so the destination is removed first and
  # stdin is closed by fleet_run_env.
  rm -f "$3"
  printf '%s' "$1" | "$(system_ssh_keygen_path)" -Y sign \
    -n "$fleet_trust_enroll_namespace" -f "$2" >"$3" 2>/dev/null
}

fleet_enroll_signing_config() {
  # fleet_enroll_signing_config <store> <principal> <key>
  #
  # §3.1's `[signing]` block, written by fleet-enroll and never by fleet-init:
  # with `behavior = "own"` and a `signing.key` naming a file that does not
  # exist, `jj git init --colocate` itself dies and THE REPO IS NEVER CREATED.
  #
  # `allowed-signers` here is the STEADY-STATE default only — it serves signing,
  # which needs a roster at *now*, and any ad-hoc `jj log` a human runs. Every
  # trust decision overrides it per commit (§7.1a). Wiring verification to this
  # value instead would build head-roster verification, which §7.1 opens by
  # calling broken.
  jj -R "$1" config set --repo user.email "$2"
  jj -R "$1" config set --repo signing.backend ssh
  jj -R "$1" config set --repo signing.behavior own
  jj -R "$1" config set --repo signing.key "$3"
  jj -R "$1" config set --repo signing.backends.ssh.program \
    "$(system_ssh_keygen_path)"
  jj -R "$1" config set --repo signing.backends.ssh.allowed-signers \
    "$(fleet_allowed_signers_path)"
  jj -R "$1" config set --repo signing.backends.ssh.revocation-list \
    "$(fleet_trust_root)/krl"
}

fleet_enroll_krl_seed() {
  # A revocation-list path that does not RESOLVE makes ssh-keygen report EVERY
  # signature `bad` — indistinguishable from mass revocation, and it is a typo.
  # So an empty KRL is always a real file.
  fleet_enroll_krl=$(fleet_trust_root)/krl
  [ ! -f "$fleet_enroll_krl" ] || return 0
  mkdir -p "$(dirname "$fleet_enroll_krl")"
  fleet_enroll_ktmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-krl.XXXXXX")
  "$(system_ssh_keygen_path)" -k -f "$fleet_enroll_ktmp/krl" >/dev/null 2>&1 ||
    : >"$fleet_enroll_ktmp/krl"
  safe_output "$fleet_enroll_ktmp/krl" "$fleet_enroll_krl"
  rm -rf "$fleet_enroll_ktmp"
}

fleet_enroll_commit() {
  # fleet_enroll_commit <store> <host> <message> — describe @, move the
  # bookmark, land @ back on it. Used by the roster verbs that must publish;
  # the ordinary supervised verbs write into the working copy and stop.
  # A DIVERGED BOOKMARK IS NOT THIS VERB'S TO RESOLVE. `bookmark set main -r @`
  # on a conflicted bookmark picks @ and drops the other head locally; the push
  # then fails non-fast-forward (fails safe) but local `main` is left mangled
  # and the dropped head's content is excluded from every later reconcile.
  [ "$(fleet_vcs_heads_local "$1" | grep -c .)" -le 1 ] || {
    printf 'roundhouse: main is diverged; run `roundhouse fleet-run` to reconcile before a roster edit (§8.2)\n' >&2
    return 65
  }
  jj -R "$1" describe -r @ -m "$3

$(fleet_vcs_trailers "$2" "${ROUNDHOUSE_SESSION:-agent}" 'roster edit, §7.3a' -)" \
    >/dev/null
  fleet_enroll_at=$(jj -R "$1" log -r @ --no-graph -T 'commit_id')
  jj -R "$1" bookmark set main -r "$fleet_enroll_at" >/dev/null
  printf '%s\n' "$fleet_enroll_at"
}

fleet_host_name_ok() {
  # A host name reaches `rm -rf`, `mkdir -p`, a store-relative path and an SSH
  # destination. ONE predicate for every verb that takes one, because the
  # verb that only ADDS carried this guard while the verb that DELETES did not.
  # `.` and `..` pass the character class and are the two names that matter
  # most: `rm -rf "$store/hosts/."` is the whole directory and `hosts/..` is
  # the store root. They are refused by name, not by pattern.
  #
  # A LEADING `-` is refused for the same class of reason `.`/`..` are: the
  # character class permits `-` (it is legal inside a host name), but a name
  # that STARTS with one reaches `ssh`/`ssh-keygen` as an OPTION rather than a
  # destination — `-oProxyCommand=…` is the near-miss, and even an
  # option-shaped name with no `=` (`-oProxyCommand`) is an argv the fixed
  # trailing slot must never be handed. No real host or IP starts with `-`.
  case ${1:-} in
    '' | . | .. | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fleet_enroll_hours_ok() {
  # Whole hours, or nothing. `fleet_enroll_deadline` used to fall through both
  # `date` spellings to `fleet_now`, so `--ttl 8h` printed "renewed for 8hh",
  # exited 0 and set `valid_before` to NOW — a leaf enrolled already expired,
  # reported as success.
  case ${1:-} in
    '' | *[!0-9]*) return 1 ;;
  esac
}

fleet_enroll_require_enrolled() {
  # Every roster verb below is authorized by THIS host's roster key making the
  # commit ratchet-valid. A host with no key cannot sponsor anything.
  [ -f "$(fleet_signing_key_path)" ] || {
    printf 'roundhouse: this host has no node key; run `roundhouse fleet-enroll` first\n' >&2
    return 69
  }
}

# --- §12 host 1: fleet-init, then fleet-enroll --------------------------------

fleet_init_command() (
  fleet_run_env
  require_yq
  command -v jj >/dev/null 2>&1 || {
    printf 'roundhouse: jj is required for the fleet store (install jj >= 0.43)\n' >&2
    exit 69
  }
  store=$(fleet_store_path)
  if [ ! -d "$store/.jj" ]; then
    # A .git with no .jj is either a foreign clone or a half-move. Both are
    # recoverable by hand and neither is safe to guess at.
    [ ! -e "$store/.git" ] || {
      printf 'roundhouse: %s carries a git repository but no jj repository; clone with `jj git clone --colocate` or move it aside\n' \
        "$store" >&2
      exit 65
    }
    mkdir -p "$store"
    jj git init --colocate "$store" >/dev/null
  fi
  # The repo config is host-local and outside the store, so a clone does not
  # inherit it: fleet-init runs on EVERY host, not just the first (§12).
  fleet_apply_jj_pins "$store"
  fleet_apply_git_pins "$store"

  if [ -n "$(fleet_store_id "$store")" ]; then
    fleet_store_id_assert "$store" || exit 65
  else
    # Rooting a new fleet. The scaffold is WRITTEN, not committed: the roster
    # commit fleet-enroll makes IS the genesis, and a scaffold commit here would
    # become the genesis instead — so `store_id` would name a commit that
    # carries no roster and was signed by nobody.
    fleet_write_store_scaffold "$store"
  fi
  printf 'roundhouse: fleet store initialized at %s\n' "$store"
  printf 'roundhouse: unsigned and store-id-less until `roundhouse fleet-enroll` writes the roster; the roster commit IS the genesis (§12)\n'
)

fleet_enroll_command() (
  # §3.3 step 2 — mint this machine's own keypair and register it. At genesis
  # there is no sponsor and the host writes its own SELF-SIGNED roster; on every
  # other host the roster line is committed BY THE SPONSOR (§7.3a), because a
  # machine cannot enrol itself and that is the ratchet.
  fleet_run_env
  require_jq
  require_yq
  store=$(fleet_store_path)
  [ -d "$store/.jj" ] || {
    printf 'roundhouse: no fleet store at %s; run `roundhouse fleet-init` first\n' \
      "$store" >&2
    exit 69
  }
  host=$(fleet_host_name)
  principal=$(fleet_principal)
  key=$(fleet_signing_key_path)
  fleet_enroll_keygen "$key"
  fleet_enroll_krl_seed
  fleet_enroll_signing_config "$store" "$principal" "$key"
  fleet_signing_ready "$store" || exit 65

  genesis=$(fleet_store_id "$store")
  if [ -n "$genesis" ]; then
    # Already a store with history. Enrollment is idempotent and is also the
    # heal path, the rename path (§9.1), the reconstitution path (§7.8 C) and
    # the second-identity path for an operated host (§9.2). The roster line
    # itself is the sponsor's to write.
    jj -R "$store" new -m '' >/dev/null
    fleet_trust_materialize "$store" \
      "$(fleet_vcs_heads_local "$store" | head -1)" || :
    printf 'roundhouse: %s signs as %s; a durable member must commit its roster line (`roundhouse fleet-add %s` on an enrolled host)\n' \
      "$store" "$principal" "$host"
    printf 'roundhouse: store id %s\n' "$genesis"
    exit 0
  fi

  # Genesis. The self-signed roster is fine because there is no counterparty at
  # genesis to fool. ONE check makes it safe: the genesis roster must list the
  # key that signed it, and a genesis listing anyone else is refused.
  [ -z "$(fleet_identity_get store_id)" ] || {
    printf 'roundhouse: identity.yaml names a store id but %s has no history; clone the fleet store first (§12)\n' \
      "$store" >&2
    exit 65
  }
  # The scaffold in @ was authored before this identity existed, and
  # `behavior = "own"` keys on the commit's AUTHOR — so without re-authoring it
  # the genesis commit lands unsigned and every peer holds it forever.
  jj -R "$store" metaedit --update-author -r @ >/dev/null 2>&1 || :
  roster=$(fleet_enroll_roster_path "$store")
  fleet_enroll_roster_touch "$roster"
  fleet_enroll_block "$roster" durable "$host" "$(jq -cn \
    --arg principal "$principal" \
    --arg key "$(fleet_signer_entry "$key.pub")" --arg at "$(fleet_now)" \
    '{principal:$principal, key:$key, enrolled_by:"genesis",
      channel_auth:"genesis", enrolled_at:$at}')"
  fleet_enroll_bump "$roster"
  genesis=$(fleet_enroll_commit "$store" "$host" \
    "genesis: roster with $principal")
  jj -R "$store" new "$genesis" >/dev/null

  # The genesis roster must list the key that signed it — asserted rather than
  # assumed, because this is the one commit the ratchet cannot check against an
  # earlier point.
  gtmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-genesis.XXXXXX")
  gbad=$(fleet_trust_commit_hold "$store" "$genesis" "$gtmp") || {
    printf 'roundhouse: the genesis commit does not verify against its own roster: %s\n' \
      "$gbad" >&2
    rm -rf "$gtmp"
    exit 65
  }
  rm -rf "$gtmp"
  fleet_trust_materialize "$store" "$genesis" || :
  # §7.5: PIN THE FOUNDER TO ITS OWN GENESIS. Every other host is pinned by its
  # sponsor (fleet-add writes store_id into the sponsored host's identity.yaml);
  # the founder had nobody to pin it, so its `store_id` stayed empty forever —
  # `fleet_store_id_assert` passed vacuously and any parentless commit reached
  # roster_derive's genesis self-verify branch (the earlier P0-2 fix gated only
  # the present-and-different case). Back-fill it now that the genesis commit
  # exists, so host 1 ends pinned exactly like every sponsored host.
  fleet_identity_set store_id "$genesis"
  printf 'roundhouse: enrolled %s as %s\n' "$store" "$principal"
  # store_id is an OUTPUT, reported upward to the orchestrator or into the
  # session transcript — never an input a human pastes, and it cannot be
  # reported until the roster commit exists.
  printf 'roundhouse: store id %s\n' "$genesis"
)

# --- §7.3a A/D: sponsorship, over a channel the fleet already trusts ----------

fleet_enroll_channel_auth() {
  # §7.3a A step 2. The channel is one the fleet ALREADY grants full code
  # execution over — §6.1's push-nudge runs `roundhouse fleet-sync` on peers,
  # `fleet-inventory` and `fleet-update` run commands on every host — so
  # enrollment over it introduces no new trust assumption. Shrinking the TOFU
  # window is opportunistic and never required.
  if "$(system_ssh_keygen_path)" -F "$1" \
    -f "$(fleet_identity_get known_hosts)" >/dev/null 2>&1; then
    printf 'known_hosts\n'
  elif "$(system_ssh_keygen_path)" -F "$1" -f "$HOME/.ssh/known_hosts" \
    >/dev/null 2>&1; then
    printf 'known_hosts\n'
  elif tailscale status --json 2>/dev/null | jq -e --arg h "$1" \
    '[.Peer // {} | .[] | .HostName, .DNSName] | any(. // "" | startswith($h))' \
    >/dev/null 2>&1; then
    printf 'tailscale\n'
  else
    # FIRST CONTACT. It proceeds — the zero-touch requirement forbids a human
    # check and there is no pre-shared secret — but it takes the 72 h soak and a
    # distinct alert class naming tofu on every host. And decisively: the real
    # machine never joins, and a human just asked for it to. This is the
    # most-noticed attack in the design.
    printf 'tofu\n'
  fi
}

fleet_add_command() (
  # `roundhouse fleet-add HOST [--ephemeral --job J --ttl HOURS]` — §7.3a A and
  # D. Nothing is run on any other host; no human touches any other host.
  #
  # Enrollment is TWO-SIDED and needs no bearer credential: an enrolled host
  # supplies authorization (its roster key makes the commit ratchet-valid) and
  # the channel supplies identity binding (the key was generated on, and read
  # back from, a machine this host could reach at the name the instruction
  # gave). Neither side alone enrols.
  fleet_run_env
  require_jq
  require_yq
  add_class=durable
  add_job=
  add_ttl=24
  add_target=
  while [ $# -gt 0 ]; do
    case $1 in
      --ephemeral) add_class=ephemeral ;;
      --job)
        shift
        add_job=${1:-}
        ;;
      --ttl)
        shift
        add_ttl=${1:-24}
        ;;
      -*)
        printf 'roundhouse: unknown fleet-add option: %s\n' "$1" >&2
        exit 64
        ;;
      *) add_target=$1 ;;
    esac
    shift
  done
  fleet_host_name_ok "$add_target" || {
    printf 'roundhouse: fleet-add needs a host name: %s\n' "${add_target:-<empty>}" >&2
    exit 64
  }
  fleet_enroll_hours_ok "$add_ttl" || {
    printf 'roundhouse: --ttl takes whole hours: %s\n' "${add_ttl:-<empty>}" >&2
    exit 64
  }
  fleet_enroll_require_enrolled || exit $?
  add_store=$(fleet_store_path)
  fleet_vcs_store_ready "$add_store" || exit $?
  add_host=$(fleet_host_name)
  add_domain=$(fleet_fleet_domain)
  add_principal="$add_target@$add_domain"
  # The principal is interpolated into a remote `sh -c` string below. The host
  # half is validated above; the DOMAIN half comes from identity.yaml, a git
  # config value or `gh api`, none of which this code wrote — so the composed
  # principal is checked before it can reach a shell.
  case $add_principal in
    *[!A-Za-z0-9._@-]*)
      printf 'roundhouse: refusing an unusable principal: %s\n' "$add_principal" >&2
      exit 64
      ;;
  esac
  add_genesis=$(fleet_store_id "$add_store")
  add_remote=$(jj -R "$add_store" git remote list 2>/dev/null |
    awk '$1 == "origin" { print $2; exit }')
  add_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-fleet-add.XXXXXX")
  trap 'rm -rf "$add_tmp"' EXIT HUP INT TERM

  if [ "$add_class" = ephemeral ]; then
    # §7.3a D. A sandbox is not DISCOVERED over a channel, it is INSTANTIATED
    # by its sponsor — which is why `channel_auth: runtime` is the strongest
    # binding in the system, stronger than known_hosts or tailscale: there is no
    # first-contact window to MITM.
    add_channel=runtime
    fleet_enroll_keygen "$add_tmp/leaf"
    add_pub=$add_tmp/leaf.pub
    fleet_enroll_proof_write "$add_principal" "$add_tmp/leaf" "$add_tmp/proof.sig"
  else
    add_channel=$(fleet_enroll_channel_auth "$add_target")
    # Step 3-4: over that channel, bootstrap and read the key back. The
    # newcomer's own agent mints; this host only reads.
    ssh_run "$add_target" \
      'roundhouse fleet-init >/dev/null && roundhouse fleet-enroll >/dev/null 2>&1; :' \
      >/dev/null 2>&1 || :
    ssh_run "$add_target" 'cat "$HOME/.ssh/roundhouse_node_ed25519.pub"' \
      >"$add_tmp/leaf.pub" 2>/dev/null || :
    add_pub=$add_tmp/leaf.pub
    [ -s "$add_pub" ] || {
      printf 'roundhouse: could not read a node key back from %s over the SSH lane; the newcomer holds a keypair and nothing else\n' \
        "$add_target" >&2
      exit 69
    }
    ssh_run "$add_target" \
      "printf '%s' '$add_principal' | ssh-keygen -Y sign -n $fleet_trust_enroll_namespace -f \"\$HOME/.ssh/roundhouse_node_ed25519\" 2>/dev/null" \
      >"$add_tmp/proof.sig" 2>/dev/null || :
  fi

  # The possession proof, verified against the namespace that is NOT `git`. A
  # sponsor watching the key being generated already proves possession; this
  # stops a sponsor enrolling a key nobody controls.
  [ -s "$add_tmp/proof.sig" ] &&
    fleet_trust_proof_verify "$add_principal" "$add_pub" "$add_tmp/proof.sig" || {
    printf 'roundhouse: %s did not produce a valid %s possession proof for %s\n' \
      "$add_target" "$fleet_trust_enroll_namespace" "$add_principal" >&2
    exit 65
  }

  add_roster=$(fleet_enroll_roster_path "$add_store")
  fleet_enroll_roster_touch "$add_roster"
  add_now=$(fleet_now)
  if [ "$add_class" = ephemeral ]; then
    fleet_enroll_block "$add_roster" ephemeral "$add_target" "$(jq -cn \
      --arg principal "$add_principal" \
      --arg key "$(fleet_signer_entry "$add_pub")" --arg sponsor "$add_host" \
      --arg job "$add_job" --arg channel "$add_channel" --arg after "$add_now" \
      --arg before "$(fleet_enroll_deadline "$add_ttl")" \
      '{principal:$principal, key:$key, sponsor:$sponsor, job:$job,
        channel_auth:$channel, valid_after:$after, valid_before:$before}')"
  else
    fleet_enroll_block "$add_roster" durable "$add_target" "$(jq -cn \
      --arg principal "$add_principal" \
      --arg key "$(fleet_signer_entry "$add_pub")" --arg by "$add_host" \
      --arg channel "$add_channel" --arg at "$add_now" \
      '{principal:$principal, key:$key, enrolled_by:$by,
        channel_auth:$channel, enrolled_at:$at}')"
  fi
  fleet_enroll_bump "$add_roster"

  # EVERY roster change alerts on every host, always, and leads the recap. On a
  # five-host fleet this is a two-to-three-times-a-year event: if it fires and
  # the human did not just ask for a machine to be added, THAT is the compromise
  # notification, and it fires within one fast interval. `tofu` gets its own
  # class so the weakest path is the loudest.
  if [ "$add_class" = ephemeral ]; then
    fleet_journal_append "$add_store" "$add_host" \
      "$(jq -cn --arg item "trust.$add_target" --arg at "$add_now" \
        --arg d "$add_channel" \
        '{item:$item, digest:$d, outcome:"enrolled", at:$at}')" || :
  else
    fleet_alert_write "$add_store" "$add_host" \
      "roster-change${add_channel:+-$add_channel}" "roster-$add_target" \
      "$add_target enrolled as $add_principal over a $add_channel channel; soak $(fleet_trust_soak_hours "$add_class" "$add_channel")h before its fleet-layer writes land" ||
      :
  fi

  add_commit=$(fleet_enroll_commit "$add_store" "$add_host" \
    "enrol $add_target as $add_principal ($add_class, channel_auth $add_channel)")
  # ENROLLMENT IS NOT COMPLETE UNTIL THE SPONSOR'S COMMIT IS ON `main@origin`.
  # That is what makes the ancestry property true — a host cannot possess a
  # newcomer's commit without possessing the commit that enrolled it — so
  # additions have no propagation window and no host ever observes `unknown`
  # for a legitimate newcomer. It blocks here and fails loudly.
  fleet_vcs_publish "$add_store" "$add_commit" || {
    printf 'roundhouse: the enrolling commit did not reach main@origin; %s holds a keypair and nothing else\n' \
      "$add_target" >&2
    exit 65
  }

  if [ "$add_class" = ephemeral ]; then
    # Step 2 of D: hand it, over the runtime boundary just created, the remote
    # URL, the store_id and the key. Data, not paste.
    printf '%s\n' "$add_remote" >"$add_tmp/handoff.remote"
    printf 'roundhouse: leaf %s enrolled; hand it over the runtime boundary — remote %s, store_id %s, key %s\n' \
      "$add_target" "${add_remote:-<none>}" "$add_genesis" "$add_tmp/leaf"
    printf 'roundhouse: private key path %s (copy it into the sandbox; it is not stored here)\n' \
      "$add_tmp/leaf"
    trap - EXIT HUP INT TERM
    exit 0
  fi
  # Step 5-7: hand wren the remote URL and store_id over the SAME channel —
  # data, not a paste — and let it clone, check genesis == store_id and ratchet
  # to head on its own.
  ssh_run "$add_target" \
    "printf 'store_id: %s\nprincipal: %s\nname: %s\n' '$add_genesis' '$add_principal' '$add_target' > \"\$HOME/.config/roundhouse/identity.yaml\"" \
    >/dev/null 2>&1 || :
  printf 'roundhouse: enrolled %s as %s (channel_auth %s, store id %s)\n' \
    "$add_target" "$add_principal" "$add_channel" "$add_genesis"
)

fleet_enroll_deadline() {
  # now + N hours, ISO8601 Z. BSD and GNU date disagree about the flag — and
  # when NEITHER parses this REFUSES rather than falling through to `fleet_now`,
  # which minted an already-expired window and called it success.
  fleet_enroll_hours_ok "${1:-}" || return 1
  date -u -v+"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "$1 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    return 1
}

# --- §7.3a B: told on the newcomer -------------------------------------------

fleet_join_command() (
  # `roundhouse fleet-join REMOTE` — the FALLBACK, and B reduces to A: the hub
  # proves credential possession and carries notification; SSH proves the key
  # belongs to a reachable machine actually running roundhouse.
  #
  # `joins/` is INERT BY CONSTRUCTION — never applied, only read as a hint — so
  # the `unknown`-signed commit this writes is harmless. THE HUB IS THE OUTER
  # BOUNDARY AND NEVER THE AUTHORIZATION: if hub-push alone could enrol, a
  # stolen token would escalate from noisy nuisance to total compromise.
  fleet_run_env
  require_jq
  require_yq
  join_remote=$1
  fleet_validate_fetch_url "$join_remote" || {
    printf 'roundhouse: refusing an unusable store remote: %s\n' "$join_remote" >&2
    exit 64
  }
  join_store=$(fleet_store_path)
  [ -d "$join_store/.jj" ] || {
    printf 'roundhouse: no fleet store at %s; clone it first (`jj git clone --colocate`), then run `roundhouse fleet-init`\n' \
      "$join_store" >&2
    exit 69
  }
  # Step 2: verify genesis == store_id. `jj git clone` performs no check
  # whatsoever on remote content, so this comparison is the only thing standing
  # between this host and a foreign store.
  fleet_store_id_assert "$join_store" || exit 65
  join_host=$(fleet_host_name)
  join_principal=$(fleet_principal)
  join_key=$(fleet_signing_key_path)
  fleet_enroll_keygen "$join_key"
  join_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-fleet-join.XXXXXX")
  trap 'rm -rf "$join_tmp"' EXIT HUP INT TERM
  fleet_enroll_proof_write "$join_principal" "$join_key" "$join_tmp/proof.sig"
  mkdir -p "$join_store/joins"
  join_record=$(jq -cn --arg host "$join_host" --arg principal "$join_principal" \
    --arg key "$(fleet_signer_entry "$join_key.pub")" \
    --arg proof "$(tr -d '\n' <"$join_tmp/proof.sig")" \
    --arg address "$(fleet_identity_get address)" --arg at "$(fleet_now)" \
    '{host:$host, principal:$principal, key:$key, proof:$proof,
      address:(if $address == "" then $host else $address end), at:$at}')
  fleet_record_write "$join_store/joins/$join_host.yaml" "$join_record"
  printf 'roundhouse: wrote joins/%s.yaml — it is INERT and never applied; an enrolled host verifies the key over SSH and commits the roster line (§7.3a B)\n' \
    "$join_host"
  printf 'roundhouse: this commit will sign as `unknown`, and that is correct: %s is not trusted yet\n' \
    "$join_host"
)

fleet_enroll_process_joins() {
  # fleet_enroll_process_joins <store> <host> — the enrolled side of B, run by
  # the full pass. IT DOES NOT TRUST joins/<h>.yaml: it SSHes to the address and
  # confirms the same pubkey is present on that machine. Unreachable holds the
  # request, alerts, and retries next run.
  [ -d "$1/joins" ] || return 0
  for fleet_enroll_join in "$1"/joins/*.yaml; do
    [ -f "$fleet_enroll_join" ] || continue
    # EVERY FIELD OF joins/<h>.yaml IS HOSTILE. §7.3a B: the file is written by
    # a NON-MEMBER over a channel the fleet does not yet trust and signs as
    # `unknown`; the whole point of the record being inert is that nothing acts
    # on it un-validated. Both the file name (→ the `who` fallback destination
    # and `fleet-add` argv) and `.address` (→ the ssh destination) reach an argv
    # here, so each is refused against the same strict host/IP allowlist every
    # other ssh destination in this file passes — a leading `-`, a metacharacter
    # or an option-shaped value is refused and ALERTED, never executed. This is
    # the sink §7.12.5 assumed unreachable ("a hub credential yields no code
    # execution"); it was reachable because nothing validated the address.
    fleet_enroll_who=$(basename "$fleet_enroll_join" .yaml)
    fleet_host_name_ok "$fleet_enroll_who" || {
      fleet_alert_write "$1" "$2" join-unverified join-invalid-name \
        "a joins/ file name is not a valid host and was refused, not executed" || :
      continue
    }
    fleet_enroll_want=$(yq -r '.key // ""' "$fleet_enroll_join" 2>/dev/null)
    [ -n "$fleet_enroll_want" ] || continue
    fleet_enroll_addr=$(yq -r '.address // ""' "$fleet_enroll_join" 2>/dev/null)
    fleet_enroll_dest=${fleet_enroll_addr:-$fleet_enroll_who}
    fleet_host_name_ok "$fleet_enroll_dest" || {
      fleet_alert_write "$1" "$2" join-unverified "join-$fleet_enroll_who" \
        "joins/$fleet_enroll_who.yaml carries an unusable address and was refused, not executed" || :
      continue
    }
    fleet_enroll_saw=$(ssh_run "$fleet_enroll_dest" \
      'cat "$HOME/.ssh/roundhouse_node_ed25519.pub"' 2>/dev/null |
      fleet_signer_entry /dev/stdin 2>/dev/null) || fleet_enroll_saw=
    if [ "$fleet_enroll_saw" != "$fleet_enroll_want" ]; then
      fleet_alert_write "$1" "$2" join-unverified "join-$fleet_enroll_who" \
        "joins/$fleet_enroll_who.yaml is unverified: the address did not answer with the same key; retrying next run" ||
        :
      continue
    fi
    fleet_add_command "$fleet_enroll_who" >/dev/null 2>&1 || :
  done
}

# --- §7.3a C / §7.8: removal, renewal, reparenting, reconstitution ------------

fleet_remove_command() (
  # `roundhouse fleet-remove HOST [--burn]` — one instruction, no fan-out.
  # Every host, next fetch: the removed host's FUTURE commits verify against a
  # roster-at-parent that no longer lists it and are held; its PAST commits
  # verify against rosters that did list it and stay good. That is why the fleet
  # does not take an outage to cut off one machine.
  fleet_run_env
  require_jq
  require_yq
  remove_target=$1
  remove_burn=${2:-}
  # THE SAME GUARD `fleet_add_command` HAS, on the verb that DELETES. Two `rm`s
  # below build their paths straight from this argument, and dispatch accepts
  # one argument including the empty string: `fleet-remove ''` resolved to
  # `rm -rf "$store/hosts/"` and took every host file in the store, and
  # `fleet-remove ../../SECRET` deleted a sibling directory outside the store
  # entirely. With enough `../` that reaches ~/.ssh and this host's node
  # signing key.
  fleet_host_name_ok "$remove_target" || {
    printf 'roundhouse: fleet-remove needs a host name: %s\n' \
      "${remove_target:-<empty>}" >&2
    exit 64
  }
  fleet_enroll_require_enrolled || exit $?
  remove_store=$(fleet_store_path)
  fleet_vcs_store_ready "$remove_store" || exit $?
  remove_host=$(fleet_host_name)
  remove_roster=$(fleet_enroll_roster_path "$remove_store")
  [ -f "$remove_roster" ] || {
    printf 'roundhouse: no roster at %s\n' "$remove_roster" >&2
    exit 65
  }
  remove_head=$(fleet_vcs_heads_local "$remove_store" | head -1)
  fleet_enroll_cascade "$remove_roster" "$remove_target" "$remove_head"
  fleet_enroll_retire "$remove_roster" "$remove_target" "$remove_head"
  fleet_enroll_bump "$remove_roster"
  rm -f "$remove_store/hosts/$remove_target.yaml"
  rm -rf "$remove_store/hosts/$remove_target"
  fleet_record_write "$remove_store/lineage/$(date -u +%s)-$remove_target.yaml" \
    "$(jq -cn --arg host "$remove_target" --arg by "$remove_host" \
      --arg at "$(fleet_now)" --arg commit "$remove_head" \
      '{host:$host, event:"retired", by:$by, at:$at,
        revoked_at_commit:$commit}')"
  fleet_alert_write "$remove_store" "$remove_host" roster-change \
    "roster-remove-$remove_target" \
    "$remove_target retired at $remove_head; its past commits stay valid and its future ones stop verifying everywhere on the next fetch" ||
    :
  printf 'roundhouse: retired %s at %s (working copy — the next run publishes it)\n' \
    "$remove_target" "$remove_head"
  case $remove_burn in
    --burn)
      # The KRL survives SOLELY as the emergency lever for "this key's history
      # is itself suspect", and its totality is a feature once it is not the
      # only lever. It is host-local, so this is out-of-band by construction.
      printf 'roundhouse: --burn is the deliberate second lever and is retroactive AND TOTAL — every commit %s ever made flips to `bad`\n' \
        "$remove_target" >&2
      printf 'roundhouse: run `ssh-keygen -k -u -f %s/krl <key.pub>` on every host, then `roundhouse fleet-doctor` on each (§12)\n' \
        "$(fleet_trust_root)" >&2
      ;;
  esac
)

fleet_renew_command() (
  # `roundhouse fleet-renew NAME [HOURS]` — §7.8 B. A stopped container is not a
  # security event and must not become one: the window lapses, every commit it
  # already made stays `good`, and restarting is one field (entry survived
  # pruning) or one block (entry was pruned). Identity continuity is FREE
  # because the key never changed — same principal, same key, same historical
  # commits still verifying — which is why no tombstone mechanism exists.
  fleet_run_env
  require_jq
  require_yq
  renew_name=$1
  renew_hours=${2:-24}
  fleet_host_name_ok "$renew_name" || {
    printf 'roundhouse: fleet-renew needs a member name: %s\n' \
      "${renew_name:-<empty>}" >&2
    exit 64
  }
  fleet_enroll_hours_ok "$renew_hours" || {
    printf 'roundhouse: fleet-renew takes whole hours: %s\n' "$renew_hours" >&2
    exit 64
  }
  fleet_enroll_require_enrolled || exit $?
  renew_store=$(fleet_store_path)
  fleet_vcs_store_ready "$renew_store" || exit $?
  renew_roster=$(fleet_enroll_roster_path "$renew_store")
  FLEET_ENROLL_NAME=$renew_name yq -e \
    '(.ephemeral // {}) | has(strenv(FLEET_ENROLL_NAME))' "$renew_roster" \
    >/dev/null 2>&1 || {
    printf 'roundhouse: %s is not a live ephemeral entry; it was pruned, so re-add the SAME key with `roundhouse fleet-add --ephemeral %s`\n' \
      "$renew_name" "$renew_name" >&2
    exit 65
  }
  FLEET_ENROLL_NAME=$renew_name FLEET_ENROLL_UNTIL=$(fleet_enroll_deadline "$renew_hours") \
    yq -i -P '.ephemeral[strenv(FLEET_ENROLL_NAME)].valid_before = strenv(FLEET_ENROLL_UNTIL)' \
    "$renew_roster"
  fleet_enroll_bump "$renew_roster"
  printf 'roundhouse: renewed %s for %sh (working copy — the next run publishes it)\n' \
    "$renew_name" "$renew_hours"
)

fleet_reparent_command() (
  # `roundhouse fleet-reparent` — §7.8 A. Any durable member may adopt orphans.
  # No coordination, no election, no race that matters: two hosts adopting the
  # same orphans produce a value-level conflict in one YAML field, which §8.3
  # already holds and §8.2b's agent resolves from the commit descriptions.
  fleet_run_env
  require_jq
  require_yq
  fleet_enroll_require_enrolled || exit $?
  reparent_store=$(fleet_store_path)
  fleet_vcs_store_ready "$reparent_store" || exit $?
  reparent_host=$(fleet_host_name)
  reparent_roster=$(fleet_enroll_roster_path "$reparent_store")
  reparent_any=0
  for reparent_leaf in $(fleet_enroll_orphans "$reparent_roster"); do
    FLEET_ENROLL_NAME=$reparent_leaf FLEET_ENROLL_TO=$reparent_host \
      yq -i -P '.ephemeral[strenv(FLEET_ENROLL_NAME)].sponsor = strenv(FLEET_ENROLL_TO)' \
      "$reparent_roster"
    reparent_any=1
    printf 'roundhouse: adopted %s\n' "$reparent_leaf"
  done
  [ "$reparent_any" -eq 1 ] || {
    printf 'roundhouse: no orphans\n'
    exit 0
  }
  fleet_enroll_bump "$reparent_roster"
)

fleet_reconstitute_command() (
  # `roundhouse fleet-reconstitute HOST` — §7.8 C. New hardware means a new key,
  # correctly, and it is ONE COMMIT: the lineage record, the new key, the old
  # entry retired, and the old entry's orphans reparented onto the new one.
  #
  # The old key's history stays valid, the new key starts clean, and THE ORPHANS
  # NEVER LAPSED AT ANY POINT DURING THE REBUILD — the payoff of "sponsorship is
  # not validity". `lineage/` is reused, not invented: a rebuild is a rename
  # with a key change.
  fleet_run_env
  require_jq
  require_yq
  recon_target=$1
  fleet_host_name_ok "$recon_target" || {
    printf 'roundhouse: fleet-reconstitute needs a host name: %s\n' \
      "${recon_target:-<empty>}" >&2
    exit 64
  }
  fleet_enroll_require_enrolled || exit $?
  recon_store=$(fleet_store_path)
  fleet_vcs_store_ready "$recon_store" || exit $?
  recon_host=$(fleet_host_name)
  recon_roster=$(fleet_enroll_roster_path "$recon_store")
  recon_head=$(fleet_vcs_heads_local "$recon_store" | head -1)
  recon_channel=$(fleet_enroll_channel_auth "$recon_target")
  recon_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-recon.XXXXXX")
  trap 'rm -rf "$recon_tmp"' EXIT HUP INT TERM
  ssh_run "$recon_target" \
    'roundhouse fleet-init >/dev/null && roundhouse fleet-enroll >/dev/null 2>&1; cat "$HOME/.ssh/roundhouse_node_ed25519.pub"' \
    >"$recon_tmp/new.pub" 2>/dev/null || :
  [ -s "$recon_tmp/new.pub" ] || {
    printf 'roundhouse: could not read a new node key back from %s\n' "$recon_target" >&2
    exit 69
  }
  recon_principal="$recon_target@$(fleet_fleet_domain)"
  fleet_record_write \
    "$recon_store/lineage/$(date -u +%s)-$recon_target-rebuild.yaml" \
    "$(jq -cn --arg host "$recon_target" --arg by "$recon_host" \
      --arg at "$(fleet_now)" --arg commit "$recon_head" \
      '{host:$host, event:"rebuilt", by:$by, at:$at,
        old_key_revoked_at_commit:$commit}')"
  # Retire FIRST, so the old block's key lands in `retired:` before the new one
  # takes its name, then re-add under the same name and reparent its orphans.
  fleet_enroll_retire "$recon_roster" "$recon_target" "$recon_head"
  fleet_enroll_block "$recon_roster" durable "$recon_target" "$(jq -cn \
    --arg principal "$recon_principal" \
    --arg key "$(fleet_signer_entry "$recon_tmp/new.pub")" \
    --arg by "$recon_host" --arg channel "$recon_channel" \
    --arg at "$(fleet_now)" \
    '{principal:$principal, key:$key, enrolled_by:$by, channel_auth:$channel,
      enrolled_at:$at}')"
  for recon_leaf in $(fleet_enroll_orphans "$recon_roster"); do
    FLEET_ENROLL_NAME=$recon_leaf FLEET_ENROLL_TO=$recon_target \
      yq -i -P '.ephemeral[strenv(FLEET_ENROLL_NAME)].sponsor = strenv(FLEET_ENROLL_TO)' \
      "$recon_roster"
  done
  fleet_enroll_bump "$recon_roster"
  fleet_alert_write "$recon_store" "$recon_host" roster-change \
    "roster-rebuild-$recon_target" \
    "$recon_target rebuilt with a new key over a $recon_channel channel; its old key's history stays valid" ||
    :
  printf 'roundhouse: reconstituted %s as %s (working copy — the next run publishes it)\n' \
    "$recon_target" "$recon_principal"
)

# --- §7.11 checkpoints, re-root, and the aging that rides the full pass -------

fleet_checkpoint_command() (
  # `roundhouse fleet-checkpoint` — an ordinary commit containing one file,
  # RATCHET-VALID LIKE ANYTHING ELSE: signed by a durable member, verified
  # against the roster at its parent. No new trust rule, no new signature type,
  # no quorum. Only durable members may checkpoint and that needs no new
  # enforcement — a checkpoint is a fleet-shared path, which leaves are already
  # refused.
  fleet_run_env
  require_jq
  require_yq
  fleet_enroll_require_enrolled || exit $?
  ckpt_store=$(fleet_store_path)
  fleet_vcs_store_ready "$ckpt_store" || exit $?
  ckpt_host=$(fleet_host_name)
  ckpt_head=$(fleet_vcs_heads_local "$ckpt_store" | head -1)
  ckpt_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-checkpoint.XXXXXX")
  trap 'rm -rf "$ckpt_tmp"' EXIT HUP INT TERM
  fleet_trust_roster_at_head "$ckpt_store" "$ckpt_head" "$ckpt_tmp/roster"
  fleet_run_export "$ckpt_store" "$ckpt_head" "$ckpt_tmp/layers"
  fleet_trust_roster_show "$ckpt_store" "$ckpt_head" "$ckpt_tmp/signers.yaml"
  # `prior_checkpoint` chains the records so a reader can walk backwards
  # without the tags; it is provenance, never a gate.
  ckpt_prior=$(ls "$ckpt_store/checkpoints" 2>/dev/null | LC_ALL=C sort | tail -1)
  ckpt_prior=${ckpt_prior%.yaml}
  [ -z "$ckpt_prior" ] ||
    ckpt_prior=$(yq -r '.covers_through // ""' \
      "$ckpt_store/checkpoints/$ckpt_prior.yaml" 2>/dev/null || printf '')
  ckpt_epoch=$(date -u +%s)
  mkdir -p "$ckpt_store/checkpoints"
  fleet_record_write "$ckpt_store/checkpoints/$ckpt_epoch.yaml" \
    "$(fleet_trust_checkpoint_record \
      "$(fleet_trust_generation "$ckpt_tmp/signers.yaml")" "$ckpt_head" \
      "$ckpt_prior" \
      "sha256:$(sha256_file "$ckpt_tmp/roster")" \
      "sha256:$(fleet_fold "$ckpt_tmp/layers" "$ckpt_host" | sha256_stream)")"
  ckpt_commit=$(fleet_enroll_commit "$ckpt_store" "$ckpt_host" \
    "checkpoint $ckpt_epoch through $ckpt_head")
  fleet_vcs_publish "$ckpt_store" "$ckpt_commit" || exit $?
  # CHECKPOINTS ARE TAGS. A bookmark confers no immutability — measured on
  # properly isolated sibling commits, the same rewrite succeeded through a
  # bookmark and was refused through a tag.
  fleet_trust_checkpoint_tag "$ckpt_store" "$ckpt_commit" "$ckpt_epoch" || {
    printf 'roundhouse: the checkpoint commit landed but could not be tagged; it is NOT immutable\n' >&2
    exit 65
  }
  printf 'roundhouse: checkpoint %s at %s, tagged rh-checkpoint-%s\n' \
    "$ckpt_epoch" "$ckpt_commit" "$ckpt_epoch"
)

fleet_reroot_command() (
  # `roundhouse fleet-reroot` — deliberate and instruction-driven, because it
  # rewrites what every clone starts from.
  #
  # THE ARCHIVE REF IS MANDATORY. A re-root is byte-for-byte indistinguishable
  # from the §7.12.3 rollback attack except by the archive: a host offline
  # across one finds its monotonic reviewed-ref is not an ancestor of the new
  # root, which the rollback rule says to treat as an attack. That behaviour is
  # correct and must not be softened — so the archive is part of the protocol,
  # not hygiene, and this refuses to re-root without publishing one.
  fleet_run_env
  require_jq
  require_yq
  fleet_enroll_require_enrolled || exit $?
  reroot_store=$(fleet_store_path)
  fleet_vcs_store_ready "$reroot_store" || exit $?
  reroot_head=$(fleet_vcs_heads_local "$reroot_store" | head -1)
  reroot_ckpt=$(jj -R "$reroot_store" log -r "$reroot_head" --no-graph \
    -T 'if(tags, "yes", "no")' 2>/dev/null)
  [ "$reroot_ckpt" = yes ] || {
    printf 'roundhouse: re-root starts from a tagged checkpoint; run `roundhouse fleet-checkpoint` first (§7.11.2 step 1)\n' >&2
    exit 65
  }
  reroot_ref=$(fleet_trust_archive_ref "$(date -u +%Y%m%d)")
  git -C "$reroot_store" update-ref "$reroot_ref" "$reroot_head" || exit 65
  git -C "$reroot_store" push origin "$reroot_ref:$reroot_ref" >/dev/null 2>&1 || {
    printf 'roundhouse: the archive ref did not publish; REFUSING to re-root — without it every offline host reads this as a rollback attack and holds\n' >&2
    git -C "$reroot_store" update-ref -d "$reroot_ref" 2>/dev/null || :
    exit 65
  }
  printf 'roundhouse: archived history at %s; new clones start from %s\n' \
    "$reroot_ref" "$reroot_head"
  printf 'roundhouse: store_id for new hosts is now %s (the checkpoint id, §7.11.1)\n' \
    "$reroot_head"
)
