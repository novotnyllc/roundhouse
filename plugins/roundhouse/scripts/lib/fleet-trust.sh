# roundhouse — the trust ratchet: roster derivation, per-commit verification,
# membership classes, materialization custody, checkpoints and aging.
#
# §7 of docs/specs/2026-08-06-dsc-storage-design-v2.md.
#
# ONE ordering rule carries the whole section: a change to `trust/signers.yaml`
# counts only if it is signed by a key the file already trusted ONE COMMIT
# EARLIER. Reading the roster at the current head is circular — the file being
# verified supplies the keys that verify it — so an attacker who lands one
# commit replacing the whole roster with their own key writes something
# self-consistent that passes. Evaluating at the parents is not circular: it
# reads a strictly earlier point in a history whose ordering is hash-secured.
#
# There is no CA, no certificate, no authority key, and nothing to keep safe
# beyond the ordinary per-machine key each host already holds.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_trust_roster_file='trust/signers.yaml'

fleet_trust_root() {
  # §7.9's ladder for $TRUST. The privileged lane's root-owned directory where
  # it is configured, this host's own instance root where it is not — and the
  # degraded case ALERTS rather than being the silent default (the caller
  # reports it; this resolver only answers where the files are).
  #
  # Test-gated like every other trust-root relocation: a stray environment
  # variable must never be able to move the file that decides who may sign.
  fleet_trust_dir=/usr/local/etc/roundhouse
  ! fleet_test_hook "${ROUNDHOUSE_TRUST_ROOT:-}" || fleet_trust_dir=$ROUNDHOUSE_TRUST_ROOT
  if [ -d "$fleet_trust_dir" ]; then
    printf '%s\n' "$fleet_trust_dir"
  else
    fleet_instance_root
  fi
}

fleet_trust_prefix=/usr/local/libexec/roundhouse-trustd

fleet_trust_privileged() {
  # True when the privileged materialization lane is configured: a root helper
  # whose entire job is to RE-DERIVE the roster from the store independently,
  # refuse a generation that went backward, refuse a head that is not a
  # descendant of `reviewed-ref`, then write atomically. The helper does not
  # trust the run's output; it recomputes it. That is what makes root ownership
  # mean something rather than being decoration.
  #
  # THE PREFIX IS A ROOT-OWNED DIRECTORY (§7.9's install lane), holding the
  # binary, the `roundhouse` library it sources, its `lib/` tree, and the
  # `toolchain` manifest — so trustd runs its OWN code and its OWN jj/yq/jq as
  # root, never a same-user copy. The binary lives inside that prefix.
  fleet_trust_helper=$fleet_trust_prefix/roundhouse-trustd
  ! fleet_test_hook "${ROUNDHOUSE_TRUSTD:-}" || fleet_trust_helper=$ROUNDHOUSE_TRUSTD
  [ -x "$fleet_trust_helper" ] || return 1
  # ARMED ONLY WITH ITS CO-LOCATED TREE. A bare binary with no library or
  # toolchain beside it would fail closed inside trustd, so treat it as "no
  # lane" and degrade seamlessly (the doctor still reports it) rather than
  # hard-fail the run. The self-check's env override points straight at the repo
  # binary, whose tree is always beside it, so the hook path skips this.
  if ! fleet_test_hook "${ROUNDHOUSE_TRUSTD:-}"; then
    fleet_trust_helper_dir=$(dirname "$fleet_trust_helper")
    [ -f "$fleet_trust_helper_dir/roundhouse" ] &&
      [ -f "$fleet_trust_helper_dir/toolchain" ] || return 1
  fi
  printf '%s\n' "$fleet_trust_helper"
}

# --- the roster, as data ------------------------------------------------------

fleet_trust_entries() {
  # fleet_trust_entries <roster-yaml> -> one line per live member:
  #   <name> <class> <principal> <valid_after|-> <valid_before|->
  #   <enrolled_at|-> <channel_auth|-> <keytype> <b64>
  #
  # `retired:` is absent by construction — a retired block is not a member.
  # Its past commits stay good anyway, because each verifies against the roster
  # at ITS OWN parents, where the entry still existed (§7.1b).
  #
  # Fields are space-joined rather than @tsv'd because the key is itself two
  # space-separated tokens and lands last, so awk reads $6 $7 and nothing has
  # to survive a quoting round trip.
  # One read per class rather than one `map(.class = …)` over the union:
  # measured on yq v4.53, an assignment inside `map()` is evaluated in a
  # detached context and the field comes back EMPTY, which silently shifts
  # every column after it. Two reads, no assignment, no shift.
  [ -f "$1" ] || return 0
  for fleet_trust_class in durable ephemeral; do
    # `map(tostring) | join(" ")`, never `+` between the fields: an unquoted
    # `2026-08-07T09:00:00Z` is a TIMESTAMP to yq, and `+` on a timestamp is
    # duration arithmetic — measured, the whole read dies with "unable to parse
    # duration" and every roster comes back EMPTY, which renders as "nobody is
    # trusted". A hand-editable file cannot be relied on to quote its dates.
    FLEET_TRUST_CLASS=$fleet_trust_class yq -r '
      (.[strenv(FLEET_TRUST_CLASS)] // {}) | to_entries | .[] |
      [ .key, strenv(FLEET_TRUST_CLASS), (.value.principal // "-"),
        (.value.valid_after // "-"), (.value.valid_before // "-"),
        (.value.enrolled_at // .value.valid_after // "-"),
        (.value.channel_auth // "-"), (.value.key // "-") ]
      | map(tostring) | join(" ")
    ' "$1" 2>/dev/null | grep . || true
  done
}

fleet_trust_render() {
  # fleet_trust_render <roster-yaml> <at-iso8601> -> allowed_signers lines.
  #
  # TTL IS IMPLEMENTED HERE AND ONLY HERE, filtered against the verifying
  # commit's own timestamp — never as native OpenSSH `valid-before`/
  # `valid-after` in any file jj or ssh-keygen reads. Measured: native expiry
  # is evaluated at WALL CLOCK, so an expired line retroactively invalidates
  # the node's entire signed history, and jj has no verify-time control to pin
  # the evaluation instant. jj renders an expired line as `unknown` with an
  # empty display — identical to "not in the roster" — so the failure is silent
  # as to cause. Hence: ordinary human-readable YAML here, and the emitted
  # lines carry NO time options at all.
  #
  # `namespaces="git"` on every line is what keeps commit signatures and
  # `roundhouse-enroll` possession proofs apart: a proof offered as a commit
  # signature is refused with `namespace does not match`, and vice versa.
  #
  # ISO8601 Z sorts chronologically, so the window test is a string compare and
  # needs no date arithmetic on a platform whose `date` flags differ.
  # `NF == 9`, never `NF >= 9`: the fields are space-joined and the key is
  # itself two tokens, so a hand-edited `principal: "vireo fleet"` shifts every
  # column right and $8/$9 stop being the key. Ten fields is a malformed row,
  # not a longer one, and emitting it would write a garbage allowed_signers
  # line. Dropping it fails closed — that member is simply not derived.
  fleet_trust_entries "$1" | awk -v now="$2" '
    NF == 9 && $3 != "-" && $8 != "-" {
      if ($4 != "-" && now < $4) next
      if ($5 != "-" && now >= $5) next
      printf "%s namespaces=\"git\" %s %s\n", $3, $8, $9
    }
  ' | LC_ALL=C sort -u
}

fleet_trust_class_map() {
  # fleet_trust_class_map <roster-yaml> <at-iso8601> ->
  #   `<principal> <class> <enrolled_at|-> <channel_auth|->`
  #
  # Same window filter as the roster itself, so a principal that is not a member
  # at this instant has no class either. The enrollment stamp rides along
  # because the soak is evaluated from the same roster the class comes from —
  # reading it at the current head instead would let an attacker's own later
  # commit shorten their own soak.
  # Same `NF == 9` rule as the render, for the same reason: a shifted row would
  # read someone else's field as this principal's class.
  fleet_trust_entries "$1" | awk -v now="$2" '
    NF == 9 && $3 != "-" {
      if ($4 != "-" && now < $4) next
      if ($5 != "-" && now >= $5) next
      print $3, $2, $6, $7
    }
  ' | LC_ALL=C sort -u
}

fleet_trust_generation() {
  # The monotonic roster counter, §7.11/§7.12.3's rollback defence. Absent
  # reads as 0 so a roster that predates the field cannot look like a rollback.
  # ALWAYS A NUMBER. The roster is hand-editable, so `.generation` can be any
  # scalar — and every reader feeds it straight to `[ -lt ]`/`[ -ge ]`, where a
  # non-numeric value makes the test ERROR OUT rather than compare. Under
  # `set -e` that takes the caller down; without it the `if` reads false and
  # `fleet_trust_materialize` walks past its own rollback check. Coerced at the
  # source, once, instead of at three call sites.
  # Coerced in SHELL, not in yq: mikefarah's yq has no `tonumber?`, and jq's
  # spelling is a lexer error there rather than a fallback — which would make
  # every generation read as empty.
  [ -f "$1" ] || {
    printf '0\n'
    return
  }
  fleet_trust_gen_read=$(yq -r '.generation // 0' "$1" 2>/dev/null) ||
    fleet_trust_gen_read=0
  # A non-numeric generation reads as 0, which is BELOW every high-water mark —
  # so `fleet_trust_materialize` refuses it as a rollback instead of erroring
  # out of an arithmetic test and walking past its own check.
  case $fleet_trust_gen_read in
    '' | *[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$fleet_trust_gen_read" ;;
  esac
}

# --- derivation from history: the ratchet loop --------------------------------

fleet_trust_commit_time() {
  jj -R "$1" log -r "$2" --no-graph \
    -T 'committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null
}

fleet_trust_parents() {
  # Real parents only. jj's virtual root commit is a parent of the genesis
  # commit and carries no tree, so it is excluded here rather than in five
  # callers.
  jj -R "$1" log -r "parents($2) ~ root()" --no-graph \
    -T 'commit_id ++ "\n"' 2>/dev/null | grep . || true
}

fleet_trust_roster_show() {
  # fleet_trust_roster_show <store> <rev> <dest> — the roster file as it stood
  # at one revision. Confirmed readable at an arbitrary ancestor, including
  # while a merge is conflicted. An absent file yields an empty roster, which
  # renders as "nobody is trusted" and holds — the safe direction.
  jj -R "$1" file show -r "$2" "root:$fleet_trust_roster_file" >"$3" 2>/dev/null ||
    : >"$3"
}

fleet_trust_roster_derive() {
  # fleet_trust_roster_derive <store> <commit> <workdir> — writes
  # <workdir>/roster (allowed_signers) and <workdir>/classes.
  #
  # THE EVERY-PARENT RULE, AS A PER-PARENT LOOP. `jj file show -r <C>-` is the
  # copy-paste trap: for a merge it silently picks ONE parent, and the singular
  # reading is exploitable — two branches off one base, the left still listing
  # mallory and the right having removed her, with a merge authored by mallory.
  # Under any-parent that merge is ACCEPTED and a removed member keeps pushing
  # forever; under every-parent it HOLDS. §8.2 manufactures merges as its
  # normal path, so this is not a corner.
  #
  # The intersection costs legitimate authors nothing: the ancestry property
  # guarantees a newcomer clones AFTER its enrollment is on `main@origin`, so
  # every head it can merge already descends from that enrollment.
  #
  # The window is evaluated at the VERIFYING COMMIT's timestamp, not at each
  # parent's and not at wall clock — freeze-at-expiry, freeze-at-revocation and
  # freeze-at-suspension are one rule: position in history.
  fleet_trust_store=$1
  fleet_trust_commit=$2
  fleet_trust_work=$3
  mkdir -p "$fleet_trust_work"
  fleet_trust_at=$(fleet_trust_commit_time "$fleet_trust_store" "$fleet_trust_commit")
  [ -n "$fleet_trust_at" ] || return 1
  # Cached for the monotonicity assert, which walks the same parents at the
  # same instant: deriving a roster is already several jj invocations per
  # commit, and asking twice doubled the doctor's replay for nothing.
  printf '%s\n' "$fleet_trust_at" >"$fleet_trust_work/at"
  fleet_trust_parents "$fleet_trust_store" "$fleet_trust_commit" \
    >"$fleet_trust_work/parents"
  fleet_trust_n=0
  : >"$fleet_trust_work/all"
  : >"$fleet_trust_work/allclasses"
  for fleet_trust_parent in $(cat "$fleet_trust_work/parents"); do
    fleet_trust_n=$((fleet_trust_n + 1))
    fleet_trust_roster_show "$fleet_trust_store" "$fleet_trust_parent" \
      "$fleet_trust_work/signers.$fleet_trust_n"
    fleet_trust_render "$fleet_trust_work/signers.$fleet_trust_n" "$fleet_trust_at" \
      >>"$fleet_trust_work/all"
    fleet_trust_class_map "$fleet_trust_work/signers.$fleet_trust_n" "$fleet_trust_at" \
      >>"$fleet_trust_work/allclasses"
  done
  if [ "$fleet_trust_n" -eq 0 ]; then
    # THE GENESIS BRANCH IS GATED ON THE PIN, and this is the one guard that
    # keeps the circular read from being an authorization bypass.
    #
    # Reading a commit's roster from the commit itself is only safe where there
    # is no earlier point to read and no counterparty to fool — the store's OWN
    # genesis. Any OTHER parentless commit is a history someone just minted:
    # `jj new root()` with a self-signed roster listing only the attacker
    # verifies perfectly against itself, which is exactly the read §7.1 opens by
    # calling broken. It is also the failure mode of `fleet_trust_parents`,
    # which cannot tell "no parents" from "the jj query failed" — so an errored
    # query would otherwise fall INTO the self-verifying branch.
    #
    # An empty roster renders as "nobody is trusted", so the commit comes back
    # `unknown` and holds. That is the safe direction and it is the same
    # direction every other error path in this file takes.
    fleet_trust_pin=$(fleet_identity_get store_id)
    if [ -n "$fleet_trust_pin" ] && [ "$fleet_trust_pin" != "$fleet_trust_commit" ]; then
      : >"$fleet_trust_work/roster"
      : >"$fleet_trust_work/classes"
      chmod 600 "$fleet_trust_work/roster" "$fleet_trust_work/classes" 2>/dev/null || :
      return 0
    fi
    # Genesis proper. The one check that makes the self-read safe — the genesis
    # roster must list the key that signed it — is asserted by the caller
    # (§7.3a), not smuggled in here.
    fleet_trust_roster_show "$fleet_trust_store" "$fleet_trust_commit" \
      "$fleet_trust_work/signers.0"
    fleet_trust_render "$fleet_trust_work/signers.0" "$fleet_trust_at" \
      >"$fleet_trust_work/roster"
    fleet_trust_class_map "$fleet_trust_work/signers.0" "$fleet_trust_at" \
      >"$fleet_trust_work/classes"
    # `classes` is mode-restricted too: it is what the class and the soak
    # decisions read, and the run passes a STABLE workdir under
    # fleet_run_state_dir rather than a mktemp -d.
    chmod 600 "$fleet_trust_work/roster" "$fleet_trust_work/classes" 2>/dev/null || :
    return 0
  fi
  # In EVERY parent, not in any: each per-parent file is already `sort -u`, so
  # a line seen $fleet_trust_n times is a line every parent carried.
  LC_ALL=C sort "$fleet_trust_work/all" | uniq -c |
    awk -v n="$fleet_trust_n" '$1 == n { $1 = ""; sub(/^ /, ""); print }' \
      >"$fleet_trust_work/roster"
  # Class the same way, and for the same reason: reading class from the current
  # head instead would let a later promotion retroactively legalise a past
  # commit, and a later demotion retroactively void one. A principal whose
  # class disagrees across parents appears under neither, so it is refused.
  LC_ALL=C sort "$fleet_trust_work/allclasses" | uniq -c |
    awk -v n="$fleet_trust_n" '$1 == n { print $2, $3, $4, $5 }' \
      >"$fleet_trust_work/classes"
  chmod 600 "$fleet_trust_work/roster" "$fleet_trust_work/classes" 2>/dev/null || :
}

fleet_trust_roster_at_head() {
  # fleet_trust_roster_at_head <store> <rev> <dest> — the roster as this host's
  # CURRENT REVIEWED HEAD states it, for rule 4. Rules 3 and 4 are the two-sided
  # check: 3 alone lets a removed host keep pushing forever by parenting its
  # commits before its own removal; 4 alone would reject a legitimate newcomer
  # on a host that had not yet fetched the roster change — except that it
  # cannot, because of the ancestry property.
  #
  # Filtered at WALL CLOCK here on purpose: rule 4 asks "is this principal a
  # member as far as I know right now", which is a question about now.
  #
  # …EXCEPT where the caller names the instant. Materialization and its drift
  # compare must render at ONE instant or the compare is meaningless (§7.9): the
  # only variable between the two renders would otherwise be the clock, and
  # every ephemeral TTL boundary that falls between two runs would read as
  # tamper.
  fleet_trust_head_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-roster.XXXXXX")
  fleet_trust_roster_show "$1" "$2" "$fleet_trust_head_tmp"
  fleet_trust_render "$fleet_trust_head_tmp" "${4:-$(fleet_now)}" >"$3"
  rm -f "$fleet_trust_head_tmp"
}

# --- the verification rule ----------------------------------------------------

fleet_trust_krl() {
  # A missing or typo'd KRL path returns `bad` for EVERYTHING, indistinguishable
  # from mass revocation — so an unresolvable path is refused loudly here
  # instead of being rendered as a fleet-wide hold.
  fleet_trust_krl_path=$(fleet_trust_root)/krl
  [ -f "$fleet_trust_krl_path" ] || fleet_trust_krl_path=$(fleet_instance_path krl)
  [ -f "$fleet_trust_krl_path" ] || {
    printf 'roundhouse: no revocation list at %s; an unresolved KRL path reports every signature bad\n' \
      "$fleet_trust_krl_path" >&2
    return 78
  }
  printf '%s\n' "$fleet_trust_krl_path"
}

fleet_trust_signature_read() {
  # fleet_trust_signature_read <store> <commit> <roster-file>
  #   -> "<status> <display> <email>"
  #
  # ONE template read answering §7.1's "is this from an enrolled machine" and
  # §7.3's "which machine" together, because asking twice is how the two answers
  # drift apart. `unsigned` is a status value rather than a missing line.
  #
  # EVERY TRUST DECISION PASSES THE PER-COMMIT ROSTER. The repo-config values
  # fleet-enroll wrote serve signing (which needs a roster at *now*) and any
  # ad-hoc `jj log` a human runs; using them here would build head-roster
  # verification, which §7.1 opens by calling broken.
  #
  # The signing PROGRAM is pinned on every verification: the owner's user-level
  # config points it at 1Password's op-ssh-sign, a shim that rejects the
  # revocation argument and takes the whole gate down.
  fleet_trust_krl_file=$(fleet_trust_krl) || return
  jj -R "$1" \
    --config signing.backends.ssh.program="$(fleet_vcs_toml_string "$(system_ssh_keygen_path)")" \
    --config signing.backends.ssh.allowed-signers="$(fleet_vcs_toml_string "$3")" \
    --config signing.backends.ssh.revocation-list="$(fleet_vcs_toml_string "$fleet_trust_krl_file")" \
    log -r "$2" --no-graph -T \
    'if(signature, signature.status() ++ " " ++ signature.display(), "unsigned -") ++ " " ++ committer.email() ++ "\n"'
}

fleet_trust_principal() {
  # fleet_trust_principal <store> <commit> <roster-file> — the principal the
  # SIGNATURE derives, never the one the commit claims.
  fleet_trust_signature_read "$1" "$2" "$3" | awk '{ print $2 }'
}

fleet_trust_monotonic() {
  # fleet_trust_monotonic <store> <commit> [derive-workdir] — `timestamp >=
  # every parent's`.
  #
  # Backdating is the honest residual: a commit's timestamp is inside the signed
  # object, so it is tamper-evident but self-asserted, and a node whose window
  # closed could sign a commit backdated into it. The loop already walks commits
  # in order, so this assert is free and bounds backdating to "no earlier than
  # the parent", whose position is set by other members.
  if [ -n "${3:-}" ] && [ -f "$3/at" ]; then
    fleet_trust_mt=$(cat "$3/at")
    fleet_trust_mparents=$(cat "$3/parents")
  else
    fleet_trust_mt=$(fleet_trust_commit_time "$1" "$2")
    fleet_trust_mparents=$(fleet_trust_parents "$1" "$2")
  fi
  for fleet_trust_mp in $fleet_trust_mparents; do
    fleet_trust_mpt=$(fleet_trust_commit_time "$1" "$fleet_trust_mp")
    [ -n "$fleet_trust_mpt" ] || continue
    # ISO8601 Z, so the string compare IS the chronological one.
    if [ "$fleet_trust_mt" \< "$fleet_trust_mpt" ]; then
      printf 'timestamp %s predates its parent %s (%s)\n' \
        "$fleet_trust_mt" "$fleet_trust_mp" "$fleet_trust_mpt"
      return 1
    fi
  done
}

fleet_trust_commit_hold() {
  # fleet_trust_commit_hold <store> <commit> <workdir> [reviewed-roster]
  #
  # Silent and 0 when the commit passes rules 1-5. Otherwise prints the hold
  # reason and returns 1. Rule 6 (class) is DELIBERATELY NOT HERE: §7.7 gives a
  # class refusal a narrower hold set than every other failure, so it is a
  # separate predicate with a separate caller.
  #
  # THE BRANCH ORDER IS THE POINT. Four distinct messages, and only one names
  # two principals: a KRL revocation produces `bad` with matching principals, so
  # rendering that through a combined template says "bad: vireo@… != vireo@…"
  # and points the operator at an identity mismatch that does not exist. And
  # "not in the roster at this commit's parents" is its OWN message rather than
  # an identity mismatch, because that is the newcomer/attacker case.
  fleet_trust_roster_derive "$1" "$2" "$3" || {
    printf 'unreadable commit\n'
    return 1
  }
  # A 78 from the KRL pre-check travels out with its own reason: `return` on its
  # own would carry the status and print NOTHING, which breaks this function's
  # "prints the hold reason" contract and hands the caller an empty string.
  fleet_trust_line=$(fleet_trust_signature_read "$1" "$2" "$3/roster") || {
    fleet_trust_read_rc=$?
    printf 'no usable revocation list, so nothing can be verified\n'
    return "$fleet_trust_read_rc"
  }
  # Parameter expansion, not `read a b c`: an empty roster yields an EMPTY
  # display field, and `read` collapses the run of spaces and shifts the
  # committer email into the display variable.
  fleet_trust_status=${fleet_trust_line%% *}
  fleet_trust_rest=${fleet_trust_line#* }
  fleet_trust_display=${fleet_trust_rest%% *}
  fleet_trust_committer=${fleet_trust_rest#* }
  if [ "$fleet_trust_status" = unsigned ]; then
    printf 'unsigned\n'
    return 1
  fi
  # `unknown` is a failure, never "probably fine" — and this rule is MORE
  # load-bearing under the ratchet than under any authority model, because "not
  # yet enrolled" is a newcomer's normal transient state and is deliberately
  # indistinguishable from an attacker. No provisional acceptance, no grace.
  if [ "$fleet_trust_status" = unknown ]; then
    printf 'not in the roster at this commit'"'"'s parents\n'
    return 1
  fi
  if [ "$fleet_trust_status" != good ]; then
    printf 'signature %s\n' "$fleet_trust_status"
    return 1
  fi
  [ "$fleet_trust_display" = "$fleet_trust_committer" ] || {
    printf 'identity mismatch: signature says %s, commit says %s\n' \
      "$fleet_trust_display" "$fleet_trust_committer"
    return 1
  }
  # Rule 4 — removals bite backward. Deliberately fetch-state-dependent: during
  # divergence a host that has fetched a removal holds a commit that a host that
  # has not will accept. That asymmetry IS the design, and it converges within
  # one fast interval.
  if [ -n "${4:-}" ] && [ -f "$4" ]; then
    awk -v p="$fleet_trust_display" '$1 == p { found = 1 } END { exit(found ? 0 : 1) }' \
      "$4" || {
      printf 'no longer in the roster at this host'"'"'s reviewed head\n'
      return 1
    }
  fi
  fleet_trust_mono=$(fleet_trust_monotonic "$1" "$2" "$3") || {
    printf '%s\n' "$fleet_trust_mono"
    return 1
  }
}

fleet_trust_class_of() {
  # fleet_trust_class_of <classes-file> <principal> — the class the ratchet
  # derived, or nothing.
  awk -v p="$2" '$1 == p { print $2; exit }' "$1" 2>/dev/null
}

fleet_trust_soak_open() {
  # fleet_trust_soak_open <classes-file> <principal> <commit-time>
  #   [genesis-roster]
  # — true when the key was enrolled less than its soak window before this
  # commit.
  #
  # <genesis-roster> is the rendered roster AT THIS STORE'S GENESIS COMMIT, and
  # it is what makes `channel_auth: genesis` honest. The field lives in a
  # hand-editable block, so an attacker enrolling themselves later writes
  # `genesis` and switches their own soak off — §7.12.1's control 5 bypassed by
  # typing a word. But the founding host's `genesis` is REAL and must stay
  # free: it has no counterparty, and delaying it would mean host 1 cannot
  # write the layers it was just told to seed. The discriminator is therefore
  # membership in the genesis roster, not the identity of the commit being
  # judged — host 1's ordinary convergence commits are not the genesis commit.
  #
  # §7.12.1's containment for the enroll-then-write race, and the point is that
  # it makes the race STRICTLY WORSE FOR AN ATTACKER THAN NOT ENROLLING AT ALL:
  # writing as the compromised host lands in 20 minutes, writing as a freshly
  # enrolled key lands in 24 h. It costs a real new machine nothing, because a
  # real new machine is not editing fleet policy on its first day — and its
  # evidence paths are live immediately, so it converges, applies and reports at
  # once.
  fleet_trust_soak_line=$(awk -v p="$2" '$1 == p { print; exit }' "$1" 2>/dev/null)
  [ -n "$fleet_trust_soak_line" ] || return 1
  fleet_trust_soak_class=$(printf '%s' "$fleet_trust_soak_line" | awk '{ print $2 }')
  fleet_trust_soak_at=$(printf '%s' "$fleet_trust_soak_line" | awk '{ print $3 }')
  fleet_trust_soak_ch=$(printf '%s' "$fleet_trust_soak_line" | awk '{ print $4 }')
  fleet_trust_soak_ctx=
  if [ -n "${4:-}" ] && [ -f "$4" ] &&
    awk -v p="$2" '$1 == p { found = 1 } END { exit(found ? 0 : 1) }' "$4"; then
    fleet_trust_soak_ctx=genesis
  fi
  fleet_trust_soak_h=$(fleet_trust_soak_hours "$fleet_trust_soak_class" \
    "$fleet_trust_soak_ch" "$fleet_trust_soak_ctx")
  [ "$fleet_trust_soak_h" -gt 0 ] || return 1
  # AN ABSENT `enrolled_at` MEANS MAXIMUM CAUTION, NOT NONE. It is a
  # self-asserted field in a hand-editable file, so "no stamp" is precisely what
  # an attacker writes to switch its own soak off — reading it as "no soak"
  # inverts §7.12.1's whole point, which is that enrolling has to be WORSE for
  # an attacker than not enrolling. With no stamp there is no evidence this key
  # has been here longer than this commit, so the window is treated as open.
  [ "$fleet_trust_soak_at" != - ] || return 0
  fleet_trust_soak_until=$(fleet_trust_iso_plus_hours "$fleet_trust_soak_at" \
    "$fleet_trust_soak_h") || return 0
  [ "$3" \< "$fleet_trust_soak_until" ]
}

fleet_trust_iso_plus_hours() {
  # ISO8601 Z + N hours. BSD and GNU date disagree about both the parse flag and
  # the arithmetic flag, so both spellings are tried rather than one assumed —
  # and when NEITHER parses, this REFUSES. The old fallback printed the input
  # back unchanged, which made the window close instantly: a non-numeric
  # `--ttl 8h` or an unparsable stamp read as "no soak", the one direction a
  # date helper must never fail in.
  case ${2:-} in
    '' | *[!0-9]*) return 1 ;;
  esac
  date -u -j -v+"$2"H -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "$1 + $2 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    return 1
}

fleet_trust_class_allows() {
  # fleet_trust_class_allows <class> <store-relative-path>
  #
  # Rule 6's table, and it is the whole anti-explosion rule. A leaf may write
  # its own host-keyed evidence paths and nothing else; it MAY NOT SPONSOR. A
  # 40-container burst therefore produces 40 leaves, all at depth 1 under one
  # durable sponsor, so chain of custody is one hop always — no transitive
  # closure to compute and no cycle to detect. It costs one refusal.
  #
  # Which host-keyed path a principal may write is §7.3's equality check and is
  # enforced separately; this predicate answers only the class question, so the
  # two never drift into one combined condition nobody can read.
  #
  # DEFAULT-DENY, and the default is LEAF rather than durable. `[ "$1" =
  # ephemeral ] || return 0` granted full durable authority to the EMPTY class —
  # which is what fleet_trust_class_of returns both for a principal absent from
  # `classes` and for one whose class DISAGREED ACROSS PARENTS and was therefore
  # dropped by the every-parent intersection. The intersection's own comment says
  # such a principal "is refused"; under the old test it was promoted. A class
  # this reader cannot name is not authority it may grant.
  case ${1:-} in
    durable) return 0 ;;
  esac
  case $(fleet_vcs_path_owner "$2" 2>/dev/null || printf '?') in
    '*') return 1 ;;
  esac
}

# --- §7.9 materialization and the detection compare ---------------------------

fleet_trust_materialized_path() {
  fleet_allowed_signers_path
}

fleet_trust_materialize() {
  # fleet_trust_materialize <store> <reviewed-rev> — derive the steady-state
  # roster from verified history and install it, with the generation and
  # reviewed-ref high-water marks beside it.
  #
  # THE POSITION, ARGUED HONESTLY. A same-user-writable roster makes every trust
  # model equivalent to no model. But that same attacker already holds
  # ~/.ssh/roundhouse_node_ed25519, because the signing key must be readable by
  # the process that signs — they do not need to self-enrol, they ARE this
  # machine. Root ownership does not prevent the attack. It prevents something
  # narrower and genuinely valuable: persistence past revocation of the
  # compromised host. Where the privileged lane is absent, degrade to same-user
  # and ALERT — a seamless setup with a named weakness beats a hard stop.
  fleet_trust_ms=$1
  fleet_trust_mrev=$2
  fleet_trust_mtmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-trustd.XXXXXX")
  # ONE INSTANT, recorded beside the file. The drift compare re-renders the same
  # revision later and byte-compares; rendering the two at different clocks
  # makes every `valid_after`/`valid_before` boundary that falls between them a
  # difference, and §7.3a D mints ephemeral leaves at ~40/day. The row's real
  # question — has anything edited this file since trustd wrote it — is
  # instant-independent, so the instant is pinned rather than re-read.
  fleet_trust_mat=$(fleet_now)
  fleet_trust_roster_at_head "$fleet_trust_ms" "$fleet_trust_mrev" \
    "$fleet_trust_mtmp/roster" "$fleet_trust_mat"
  fleet_trust_roster_show "$fleet_trust_ms" "$fleet_trust_mrev" \
    "$fleet_trust_mtmp/signers.yaml"
  fleet_trust_mgen=$(fleet_trust_generation "$fleet_trust_mtmp/signers.yaml")
  fleet_trust_mgen_was=$(fleet_trust_seen_generation)
  if [ "$fleet_trust_mgen" -lt "$fleet_trust_mgen_was" ]; then
    printf 'roundhouse: roster generation went backward (%s < %s); refusing to materialize (§7.12.3)\n' \
      "$fleet_trust_mgen" "$fleet_trust_mgen_was" >&2
    rm -rf "$fleet_trust_mtmp"
    return 65
  fi
  # §7.12.3's OTHER half, and §7.9's `trustd` contract says the helper refuses
  # it too: the new head must be a DESCENDANT of `reviewed-ref`. Generation
  # alone does not catch a same-genesis truncation, because the attacker writes
  # the generation as well. Lifted out of the unshipped helper so both lanes
  # enforce it — the helper recomputing it independently stays the point of the
  # helper. A re-root legitimately breaks this ancestry, and §7.11.2's catch-up
  # is what re-points `reviewed-ref` before this runs again.
  #
  # LOCAL UNPUBLISHED WORK IS NOT A ROLLBACK. A run that reconciles then REFUSES
  # to publish (the §10.4 sweep, an open conflict) still materialized the head it
  # reviewed, so reviewed-ref advances to a commit that never reached the fleet.
  # The §10.4 recovery — `jj abandon` / `op restore` that drops that head and
  # resets to main@origin — then leaves the next head a SIBLING of reviewed-ref,
  # not a descendant, and this would brick every future materialize. That is a
  # LOCAL rewrite, "this host's own doing" (§7.11.2), not the §7.12.3 attack: the
  # attack is a DIVERGENT origin that does not descend from reviewed-ref. So
  # refuse ONLY when reviewed-ref does not descend from the current published
  # head either — when reviewed-ref IS local work built atop main@origin, allow,
  # and let reviewed-ref re-point below. A rewound/divergent origin still fails
  # closed, because there reviewed-ref descends from neither the new head nor
  # main@origin.
  fleet_trust_mref=$(fleet_trust_reviewed_ref)
  if [ -n "$fleet_trust_mref" ] &&
    jj -R "$fleet_trust_ms" log -r "$fleet_trust_mref" --no-graph -T '""' \
      >/dev/null 2>&1 &&
    [ -z "$(jj -R "$fleet_trust_ms" log \
      -r "$fleet_trust_mref & ::$fleet_trust_mrev" --no-graph -T 'commit_id' \
      2>/dev/null)" ] &&
    [ -z "$(jj -R "$fleet_trust_ms" log \
      -r "present(main@origin) & ::$fleet_trust_mref" --no-graph -T 'commit_id' \
      2>/dev/null)" ]; then
    printf 'roundhouse: %s is not a descendant of reviewed-ref %s; refusing to materialize (§7.12.3)\n' \
      "$fleet_trust_mrev" "$fleet_trust_mref" >&2
    rm -rf "$fleet_trust_mtmp"
    return 65
  fi
  if fleet_trust_mhelper=$(fleet_trust_privileged); then
    # The privileged lane. trustd re-derives the roster from verified history
    # and writes roster / reviewed-ref / generation / materialized-at / KRL
    # ROOT-OWNED — including materialized-at, at the instant IT rendered at,
    # because $TRUST is root-owned and this same-user run cannot write into it.
    # The helper does not trust this run's output; it recomputes it (§7.9).
    #
    # THE HERMETIC ROOT INVOCATION (§7.9, P0). trustd runs as root, so it must
    # inherit NONE of this same-user run's environment — the P0 root-RCE is a
    # ROUNDHOUSE_TRUSTD_HOME / PATH / ROUNDHOUSE_TRUST_ROOT the caller set
    # reaching the root process. It is invoked through `env -i` with an explicit
    # minimal environment and `sudo -n` (mirroring invoke_fixed_posix_broker),
    # the sudoers entry is NOSETENV, and the store and rev travel as the only
    # arguments. trustd re-derives $TRUST, the genesis pin (from the store arg)
    # and the toolchain itself and refuses a non-root-owned library or tool.
    if fleet_test_hook "${ROUNDHOUSE_TRUSTD:-}"; then
      # The self-check runs unprivileged with no sudoers lane, so it exercises
      # the same hermetic shape MINUS the sudo hop: `env -i` carrying only the
      # explicit test hooks the fixture set (never the ambient environment), so
      # what materialize passes to the helper is an allowlist here too.
      env -i \
        PATH="$PATH" HOME="${HOME:-}" LC_ALL=C LANG=C TZ=UTC \
        JJ_CONFIG="${JJ_CONFIG:-}" XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}" \
        ROUNDHOUSE_SELFTEST="${ROUNDHOUSE_SELFTEST:-}" \
        ROUNDHOUSE_TRUST_ROOT="${ROUNDHOUSE_TRUST_ROOT:-}" \
        ROUNDHOUSE_TRUSTD_FIXTURE="${ROUNDHOUSE_TRUSTD_FIXTURE:-}" \
        ROUNDHOUSE_TRUSTD_HOME="${ROUNDHOUSE_TRUSTD_HOME:-}" \
        "$fleet_trust_mhelper" apply "$fleet_trust_ms" "$fleet_trust_mrev" || {
        rm -rf "$fleet_trust_mtmp"
        return 65
      }
    else
      env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C TZ=UTC SSH_AUTH_SOCK= \
        /usr/bin/sudo -n "$fleet_trust_mhelper" apply \
        "$fleet_trust_ms" "$fleet_trust_mrev" || {
        rm -rf "$fleet_trust_mtmp"
        return 65
      }
    fi
  else
    # The degraded rung: same-user custody, reported by the doctor's
    # privileged-lane finding rather than silently accepted. This branch is
    # UNCHANGED — regressing it would drop the seamless-setup fallback §7.9
    # mandates. It records materialized-at here, at the instant this run
    # rendered at, since no helper does it for this lane.
    mkdir -p "$(dirname "$(fleet_trust_materialized_path)")"
    safe_output "$fleet_trust_mtmp/roster" "$(fleet_trust_materialized_path)"
    printf '%s\n' "$fleet_trust_mrev" >"$fleet_trust_mtmp/reviewed-ref"
    printf '%s\n' "$fleet_trust_mgen" >"$fleet_trust_mtmp/generation"
    safe_output "$fleet_trust_mtmp/reviewed-ref" "$(fleet_trust_root)/reviewed-ref"
    safe_output "$fleet_trust_mtmp/generation" "$(fleet_trust_root)/generation"
    mkdir -p "$(fleet_trust_root)"
    printf '%s\n' "$fleet_trust_mat" >"$fleet_trust_mtmp/materialized-at"
    safe_output "$fleet_trust_mtmp/materialized-at" \
      "$(fleet_trust_root)/materialized-at"
  fi
  rm -rf "$fleet_trust_mtmp"
}

fleet_trust_materialized_at() {
  # The instant the materialized roster was RENDERED at, which is the only
  # instant its drift compare may use.
  fleet_trust_at_file=$(fleet_trust_root)/materialized-at
  [ -f "$fleet_trust_at_file" ] || return 0
  awk 'NR == 1 { print $1; exit }' "$fleet_trust_at_file"
}

fleet_trust_seen_generation() {
  fleet_trust_gen_file=$(fleet_trust_root)/generation
  [ -f "$fleet_trust_gen_file" ] || {
    printf '0\n'
    return
  }
  awk 'NR == 1 { print $1 + 0; exit }' "$fleet_trust_gen_file"
}

fleet_trust_reviewed_ref() {
  fleet_trust_ref_file=$(fleet_trust_root)/reviewed-ref
  [ -f "$fleet_trust_ref_file" ] || return 0
  awk 'NR == 1 { print $1; exit }' "$fleet_trust_ref_file"
}

fleet_trust_materialization_drift() {
  # fleet_trust_materialization_drift <store> — silent when the materialized
  # roster is byte-identical to the one the ratchet derives AT THE REF IT WAS
  # MATERIALIZED FROM.
  #
  # The comparison point is `reviewed-ref`, never the head this run is about to
  # adopt: every legitimate roster change moves the head, so comparing against
  # the new head would report drift on exactly the commits the ratchet just
  # accepted. What this row asks is narrower and is the only question worth
  # asking — has anything edited the materialized file since trustd wrote it.
  #
  # Detection, taken as well as ownership, because it is nearly free and fails
  # in a DIFFERENT direction: it catches the case ownership misses entirely, an
  # attacker who does get root. A mismatch is a loud alert and a full hold,
  # never a repair.
  # An ABSENT materialized roster is the pre-enrollment state, not drift: this
  # host has nothing to compare and fleet-enroll writes it. Silence here, and a
  # doctor row for the case where it never appears.
  fleet_trust_dfile=$(fleet_trust_materialized_path)
  [ -f "$fleet_trust_dfile" ] || return 0
  fleet_trust_dref=$(fleet_trust_reviewed_ref)
  [ -n "$fleet_trust_dref" ] || return 0
  jj -R "$1" log -r "$fleet_trust_dref" --no-graph -T '""' >/dev/null 2>&1 ||
    return 0
  # AT THE INSTANT IT WAS MATERIALIZED AT, never at wall clock. Both sides are
  # renders of the same revision, so the only variable a wall-clock read
  # introduces is TIME — and `fleet_trust_render` filters on
  # `valid_after`/`valid_before` against that instant, so any leaf whose window
  # boundary fell between the two runs produces a byte difference that this row
  # reports as tamper and the run turns into a fleet-wide `exit 65`. At ~40
  # leaves a day and a 20-minute cadence that is essentially every run.
  #
  # No recorded instant is the pre-upgrade state, not drift: the very next
  # materialize (which every clean run performs, immediately after this call)
  # writes one.
  fleet_trust_dat=$(fleet_trust_materialized_at)
  [ -n "$fleet_trust_dat" ] || return 0
  fleet_trust_dtmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-drift.XXXXXX")
  fleet_trust_roster_at_head "$1" "$fleet_trust_dref" "$fleet_trust_dtmp" \
    "$fleet_trust_dat"
  cmp -s "$fleet_trust_dtmp" "$fleet_trust_dfile" ||
    printf 'materialized roster differs from the roster derived at %s\n' \
      "$fleet_trust_dref"
  rm -f "$fleet_trust_dtmp"
}

# --- §7.3a possession proof ---------------------------------------------------

fleet_trust_enroll_namespace=roundhouse-enroll

fleet_trust_proof_verify() {
  # fleet_trust_proof_verify <principal> <pubkey-file> <signature-file>
  #
  # The sponsor watches the key being generated over the channel, which already
  # proves possession — this additionally stops a sponsor enrolling a key nobody
  # controls (a typo, or an attacker-supplied blob).
  #
  # The NAMESPACE is the separation: a `roundhouse-enroll` proof offered as a
  # commit signature is refused with `namespace does not match`, and vice versa.
  # That is why every roster line carries `namespaces="git"` and one option only.
  fleet_trust_pk=$(mktemp "${TMPDIR:-/tmp}/roundhouse-proof.XXXXXX")
  printf '%s namespaces="%s" %s\n' "$1" "$fleet_trust_enroll_namespace" \
    "$(fleet_signer_entry "$2")" >"$fleet_trust_pk"
  printf '%s' "$1" | "$(system_ssh_keygen_path)" -Y verify \
    -f "$fleet_trust_pk" -I "$1" -n "$fleet_trust_enroll_namespace" \
    -s "$3" >/dev/null 2>&1
  fleet_trust_proof_rc=$?
  rm -f "$fleet_trust_pk"
  return $fleet_trust_proof_rc
}

# --- §7.3a soak ---------------------------------------------------------------

fleet_trust_soak_hours() {
  # fleet_trust_soak_hours <class> <channel_auth> [context]. The policy falls
  # out of the class rather than being a knob: a class that cannot write fleet
  # layers has nothing to delay, and paging on 40 enrollments a day trains the
  # owner to ignore the one that matters. `tofu` is the weakest path and is
  # visibly the slowest.
  #
  # <context> is `genesis` ONLY when the commit being judged is this store's own
  # genesis commit.
  case $1 in
    ephemeral)
      printf '0\n'
      return
      ;;
  esac
  case $2 in
    genesis)
      # Genesis has no soak because it has no counterparty: there is no fleet to
      # protect from the first key, and delaying it would mean host 1 could not
      # write the layers it was just told to seed.
      #
      # THAT IS A PROPERTY OF THE COMMIT, NOT OF THE FIELD. `channel_auth` lives
      # in a hand-editable roster block written by whoever authors the enrolling
      # commit, so `channel_auth: genesis` anywhere else is simply an attacker
      # switching their own soak off — §7.12.1's control 5 bypassed by typing a
      # word. Outside the genesis context it falls to the ordinary 24 h.
      if [ "${3:-}" = genesis ]; then
        printf '0\n'
      else
        printf '24\n'
      fi
      ;;
    tofu) printf '72\n' ;;
    *) printf '24\n' ;;
  esac
}

# --- §7.11 checkpoints and aging ---------------------------------------------

fleet_trust_checkpoint_record() {
  # fleet_trust_checkpoint_record <generation> <covers_through> <prior>
  #   <roster-digest> <state-digest>
  jq -n --argjson generation "$1" --arg covers "$2" --arg prior "$3" \
    --arg roster "$4" --arg state "$5" \
    '{generation:$generation, covers_through:$covers,
      prior_checkpoint:(if $prior == "" then null else $prior end),
      roster_digest:$roster, state_digest:$state}'
}

fleet_trust_checkpoint_tag() {
  # fleet_trust_checkpoint_tag <store> <commit> <n> — CHECKPOINTS ARE TAGS.
  # jj 0.44's default `builtin_immutable_heads()` is
  # `trunk() | tags() | untracked_remote_bookmarks()`, so a git tag on a
  # checkpoint makes it AND ALL ITS ANCESTORS immutable with zero configuration.
  # A BOOKMARK DOES NOT DO THIS — measured on properly isolated sibling commits,
  # the same rewrite succeeded.
  #
  # No revset alias is set. If one ever is, the key must be QUOTED —
  # `revset-aliases.immutable_heads()` is an invalid unquoted TOML key and
  # `jj config set` rejects it; `'revset-aliases."immutable_heads()"'` works.
  # It fails loudly there only because parens are invalid TOML; a subtly wrong
  # revset would not.
  git -C "$1" tag "rh-checkpoint-$3" "$2" >/dev/null 2>&1 || return 1
  jj -R "$1" git import >/dev/null 2>&1 || return 1
}

fleet_trust_archive_ref() {
  printf 'refs/roundhouse/archive/%s\n' "$1"
}

fleet_trust_catch_up() {
  # fleet_trust_catch_up <store> <fetched-head> — §7.11.2's seven steps, for a
  # host offline across a re-root.
  #
  # A RE-ROOT IS BYTE-FOR-BYTE INDISTINGUISHABLE FROM THE §7.12.3 ROLLBACK
  # ATTACK, EXCEPT BY THE ARCHIVE. A host finds its monotonic `reviewed-ref` is
  # not an ancestor of the new root — which the rollback rule says to treat as
  # an attack, hold, and alert. That behaviour is correct and is not softened
  # here; the archive ref is what distinguishes the two, so it is part of the
  # protocol and not hygiene.
  #
  # Prints nothing and returns 0 when the new head may be adopted.
  fleet_trust_cs=$1
  fleet_trust_chead=$2
  # THE TRIGGER IS A CHANGED ROOT, not a moved head. §7.11.2 is about a NEW
  # ROOT that is not a descendant of this host's reviewed-ref; an ordinary
  # rewind, abandon or squash moves the head and leaves the root alone, and
  # firing on those would turn every local history edit into a fleet-wide hold.
  # A truncation attack that keeps the genesis is a different rule (monotonic
  # reviewed-ref and generation, §7.12.3) and has its own doctor rows.
  fleet_trust_cpin=$(fleet_identity_get store_id)
  [ -n "$fleet_trust_cpin" ] || return 0
  [ "$(fleet_store_id_at "$fleet_trust_cs" "$fleet_trust_chead")" != \
    "$fleet_trust_cpin" ] || return 0
  fleet_trust_cref=$(fleet_trust_reviewed_ref)
  # A host that has never seen the store is unaffected: it has no reviewed-ref
  # and starts from the checkpoint.
  [ -n "$fleet_trust_cref" ] || return 0
  # …and so is a host whose reviewed-ref no longer RESOLVES here: that is a
  # local rewrite (abandon, squash, restore), which is this host's own doing and
  # says nothing about the remote. The attack case leaves it resolvable, because
  # `git.abandon-unreachable-commits = false` is pinned exactly so a
  # force-pushed origin cannot delete local commits — so refusing here would
  # only ever fire on a host that rewrote its own history.
  jj -R "$fleet_trust_cs" log -r "$fleet_trust_cref" --no-graph -T '""' \
    >/dev/null 2>&1 || return 0
  # 1. fetch main -> is the new root a descendant of my reviewed-ref?
  if [ -n "$(jj -R "$fleet_trust_cs" log \
    -r "$fleet_trust_cref & ::$fleet_trust_chead" --no-graph -T 'commit_id' 2>/dev/null)" ]; then
    return 0
  fi
  # 2-3. the archive, and its ABSENCE is the rollback protection.
  jj -R "$fleet_trust_cs" git fetch --remote origin >/dev/null 2>&1 || :
  fleet_trust_carchive=$(git -C "$fleet_trust_cs" for-each-ref --count=1 \
    --sort=-refname --format='%(objectname)' 'refs/roundhouse/archive/*' \
    2>/dev/null)
  if [ -z "$fleet_trust_carchive" ] ||
    ! git -C "$fleet_trust_cs" merge-base --is-ancestor "$fleet_trust_cref" \
      "$fleet_trust_carchive" 2>/dev/null; then
    printf 'reviewed-ref %s is absent from the archive; this is a rollback until an archive says otherwise\n' \
      "$fleet_trust_cref"
    return 1
  fi
  fleet_trust_cgen=$(fleet_trust_seen_generation)
  fleet_trust_ctmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-catchup.XXXXXX")
  fleet_trust_croot=$(jj -R "$fleet_trust_cs" log \
    -r "roots(::$fleet_trust_chead ~ root())" --no-graph -T 'commit_id ++ "\n"' \
    2>/dev/null | head -1)

  # 4. VERIFY THE ARCHIVED CHAIN FORWARD, from reviewed-ref to the checkpoint,
  #    by the ordinary ratchet rule. This is the step that makes the archive
  #    mean something: without it the archive is a bag of commits nobody
  #    checked, and "reviewed-ref is somewhere in there" is satisfied by any
  #    history an attacker chose to keep. The archive tip IS the checkpoint —
  #    fleet-reroot publishes the tagged checkpoint commit as the archive ref —
  #    so step 5 ("the checkpoint is signed by a key trusted at its parent") is
  #    the same rule applied to the last commit of this range, which `x..y`
  #    includes.
  #
  #    RULE 4 ("removals bite backward") NEEDS ITS REVIEWED ROSTER HERE TOO. The
  #    live run threads `run_reference`'s roster as `commit_hold`'s 4th arg
  #    (fleet-run.sh); this replay called `commit_hold` with only THREE args, so
  #    the archived chain ran rules 1/2/3/5 and skipped rule 4 — the archive is
  #    exactly the fabricated `refs/roundhouse/archive/*` a malicious origin
  #    publishes, and a removed member's commit forked off a pre-removal parent
  #    passed. Render the roster at the archive tip (the checkpoint, this host's
  #    adoption target) once and pass it as the 4th arg to every commit_hold.
  fleet_trust_roster_at_head "$fleet_trust_cs" "$fleet_trust_carchive" \
    "$fleet_trust_ctmp/reviewed-for-replay"
  fleet_trust_cfail=
  while IFS= read -r fleet_trust_cc; do
    [ -n "$fleet_trust_cc" ] || continue
    [ -z "$fleet_trust_cfail" ] || continue
    fleet_trust_cbad=$(fleet_trust_commit_hold "$fleet_trust_cs" \
      "$fleet_trust_cc" "$fleet_trust_ctmp/a.$fleet_trust_cc" \
      "$fleet_trust_ctmp/reviewed-for-replay") ||
      fleet_trust_cfail="the archived chain does not verify at $fleet_trust_cc: ${fleet_trust_cbad:-unverifiable}"
  done <<EOF
$(jj -R "$fleet_trust_cs" log -r "$fleet_trust_cref..$fleet_trust_carchive" \
  --no-graph -T 'commit_id ++ "\n"' 2>/dev/null)
EOF
  [ -z "$fleet_trust_cfail" ] || {
    printf '%s\n' "$fleet_trust_cfail"
    rm -rf "$fleet_trust_ctmp"
    return 1
  }

  # 6. checkpoint.generation >= my last-seen. Read at the CHECKPOINT, never at
  #    the fetched head: the head is the attacker's to write in this scenario,
  #    and reading it there lets a re-root launder a generation rollback.
  fleet_trust_roster_show "$fleet_trust_cs" "$fleet_trust_carchive" \
    "$fleet_trust_ctmp/signers.yaml"
  fleet_trust_cnew=$(fleet_trust_generation "$fleet_trust_ctmp/signers.yaml")
  [ "$fleet_trust_cnew" -ge "$fleet_trust_cgen" ] || {
    printf 'checkpoint generation %s is below this host'"'"'s last-seen %s\n' \
      "$fleet_trust_cnew" "$fleet_trust_cgen"
    rm -rf "$fleet_trust_ctmp"
    return 1
  }

  # 7. ONLY NOW the new root, and it is verified AGAINST THE CHECKPOINT'S
  #    ROSTER — never against its own. A parentless commit has no earlier point
  #    for the ratchet to read, so `fleet_trust_commit_hold` on it would take
  #    the genesis branch and check it against the roster it itself carries:
  #    self-signed, self-listed, and accepted. The checkpoint is the last state
  #    this host has actually verified, so it is the state that says who may
  #    re-root.
  fleet_trust_render "$fleet_trust_ctmp/signers.yaml" \
    "$(fleet_trust_commit_time "$fleet_trust_cs" "$fleet_trust_croot")" \
    >"$fleet_trust_ctmp/roster"
  fleet_trust_cline=$(fleet_trust_signature_read "$fleet_trust_cs" \
    "$fleet_trust_croot" "$fleet_trust_ctmp/roster") || fleet_trust_cline=
  fleet_trust_cstatus=${fleet_trust_cline%% *}
  fleet_trust_crest=${fleet_trust_cline#* }
  fleet_trust_cdisplay=${fleet_trust_crest%% *}
  fleet_trust_ccommitter=${fleet_trust_crest#* }
  if [ "$fleet_trust_cstatus" != good ] ||
    [ "$fleet_trust_cdisplay" != "$fleet_trust_ccommitter" ]; then
    printf 'the new root %s is not signed by a key the checkpoint trusts (%s)\n' \
      "$fleet_trust_croot" "${fleet_trust_cline:-unreadable}"
    rm -rf "$fleet_trust_ctmp"
    return 1
  fi

  # …and advance reviewed-ref, which is step 7's other half. Without it the
  # host's high-water mark still names a commit in the archived history, and
  # `fleet_trust_materialize`'s descendant gate would refuse the adopted head
  # forever.
  printf '%s\n' "$fleet_trust_croot" >"$fleet_trust_ctmp/reviewed-ref"
  safe_output "$fleet_trust_ctmp/reviewed-ref" \
    "$(fleet_trust_root)/reviewed-ref"
  rm -rf "$fleet_trust_ctmp"
}

fleet_trust_prune_expired() {
  # fleet_trust_prune_expired <roster-yaml> — drop `ephemeral:` entries whose
  # window has passed. §7.11.3's first aging policy, riding the existing 12 h
  # full cadence.
  #
  # PRUNING IS SAFE HERE AND WOULD NOT BE IN A SNAPSHOT MODEL: an old commit is
  # verified against the roster at ITS parents, where the entry still exists.
  # At 40 joins/day with a 24 h TTL pruned every 12 h the file holds ~60 leaf
  # lines and `durable:` — the part a human reads — stays five.
  [ -f "$1" ] || return 0
  FLEET_TRUST_NOW=$(fleet_now) yq -i '
    .ephemeral = ((.ephemeral // {}) | with_entries(
      select(((.value.valid_before // "") | tostring) == "" or
             (((.value.valid_before | tostring)) > strenv(FLEET_TRUST_NOW)))))
  ' "$1"
}

fleet_trust_age_evidence() {
  # fleet_trust_age_evidence <store> <retention-days> — §7.11.3's second policy,
  # DELIBERATELY DECOUPLED from trust checkpointing. They have different natural
  # periods (a canary window is hours, a trust checkpoint is months) and coupling
  # them would mean keeping evidence far too long or re-rooting far too often.
  # Because evidence paths are never inputs to verification, aging them out is a
  # pure `rm` with no trust reasoning attached.
  fleet_trust_cutoff=$(fleet_doctor_days_ago "$2")
  for fleet_trust_edir in journal alerts findings; do
    [ -d "$1/$fleet_trust_edir" ] || continue
    # A here-doc rather than `find | while`: the pipeline form runs the body in
    # a subshell, so nothing it decides can leave the loop. Nothing escapes
    # today, but the next counter someone adds here would read zero forever.
    while IFS= read -r fleet_trust_ef; do
      [ -n "$fleet_trust_ef" ] || continue
      fleet_trust_estamp=$(yq -r '(.at // .[0].at // "") | sub("[Tt].*$"; "")' \
        "$fleet_trust_ef" 2>/dev/null || true)
      [ -n "$fleet_trust_estamp" ] || continue
      [ "$fleet_trust_estamp" \< "${fleet_trust_cutoff%%T*}" ] || continue
      rm -f "$fleet_trust_ef"
    done <<EOF
$(find "$1/$fleet_trust_edir" -type f -name '*.yaml' 2>/dev/null)
EOF
  done
}
