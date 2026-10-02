# roundhouse — re-anchoring a LEGACY reviewed-ref: the one-time migration off
# the old rule that recorded the materialized head itself.
#
# §7.12.3 of docs/specs/2026-08-06-dsc-storage-design-v2.md. Builds before the
# published-only mark wrote reviewed-ref = the head they had just materialized,
# which can be this host's own reconcile that never reached any remote. Such a
# mark is not on main@origin, and the descendant gate cannot tell it from an
# origin that dropped what it published. This file is the ONLY place that may
# tell them apart, and it does so only for a mark an older build wrote — the
# one-field materialized-at those builds left (fleet_trust_migrate_legacy_format).
# A mark this build wrote that is off the published line is never re-anchored:
# that is a rewound or divergent origin, and it is a plain refusal.
#
# "Its newest ancestor in the current main@origin" is NOT acceptable on its
# own: under a rewind that ancestor is wherever the attacker rewound TO.
# Two independent proofs are required, and either one failing holds:
#
#   1. fleet_trust_migrate_proof_own_gap — every commit between the mark and
#      its newest published ancestor verifies against a roster of ONE line:
#      this host's own key. A peer's commit there can only have arrived from
#      the remote, so its absence from origin is a rewind.
#   2. fleet_trust_migrate_proof_seen — every position the jj operation log
#      records for main@origin is still on the published line. This is the
#      proof against a hub-only attacker who drops this host's OWN published
#      commits; they cannot reach the op log.
#
# SAME-USER LANE ONLY. Both proofs read same-user state — the store, its op
# log, identity.yaml — so they say nothing to a root helper defending against
# a same-user process, which can rewrite all three. On the privileged lane
# (`fleet_trust_privileged_lane`, set by fleet_trust_materialize,
# fleet_trust_catch_up and roundhouse-trustd) a mark off the published line is
# never re-anchored: it is a plain refusal, and the operator re-points it with
# the `sudo tee` command the hold text names. On the same-user lane the proofs
# guard against a hub-only attacker; a same-user process there could rewrite
# reviewed-ref itself, so that lane promises nothing against one.
#
# REMOVE THIS FILE and its two call sites (fleet_trust_reviewed_next and
# fleet_trust_catch_up) once no host can still hold a one-field
# materialized-at: every same-user-lane host has materialized under a build
# with the published-only mark.
#
# Sourced by scripts/roundhouse after lib/fleet-trust.sh; definitions only.
# shellcheck shell=bash

fleet_trust_migrate_legacy_format() {
  # True when a migration may even be considered: the same-user lane, and trust
  # state last written by an OLDER build — a mark present and materialized-at
  # absent or carrying one field. Every writer in this build records
  # `<instant> <rendered-rev>`.
  [ "${fleet_trust_privileged_lane:-false}" != true ] || return 1
  [ -n "$(fleet_trust_reviewed_ref)" ] || return 1
  fleet_trust_lf=$(fleet_trust_root)/materialized-at
  [ -f "$fleet_trust_lf" ] || return 0
  [ "$(awk 'NR == 1 { print NF; exit }' "$fleet_trust_lf")" = 1 ]
}

fleet_trust_seen_published_parse() {
  # stdin: `jj op log --op-diff` output with templates.commit_summary pinned to
  # the bare commit id. stdout: every commit main@origin was ever moved to or
  # from, one per line, sorted. Lines under a `main@origin:` header that start
  # `+ ` or `- ` carry the ids; anything that is not a 40-hex token is skipped,
  # so a jj that renders differently yields NOTHING — which proof 2 refuses
  # rather than reading as "nothing was ever seen".
  awk '
    $0 == "main@origin:" { inb = 1; next }
    inb && /^[+-] / {
      for (i = 2; i <= NF; i++)
        if (length($i) == 40 && $i ~ /^[0-9a-f]+$/) print $i
      next
    }
    { inb = 0 }' | LC_ALL=C sort -u
}

fleet_trust_seen_published() {
  # fleet_trust_seen_published <store> -> every commit main@origin has EVER
  # pointed at in this host's op log. One `--op-diff` walk rather than one
  # `--at-op` read per operation (measured ~2 s for 1,500 operations).
  fleet_trust_sp_out=$(jj -R "$1" --ignore-working-copy op log --no-graph \
    --op-diff --config 'templates.commit_summary="commit_id"' -T '""' \
    2>/dev/null) || return 1
  printf '%s\n' "$fleet_trust_sp_out" | fleet_trust_seen_published_parse
}

fleet_trust_migrate_proof_own_gap() {
  # fleet_trust_migrate_proof_own_gap <store> <mark> <published-revset> —
  # silent and 0 when every commit in `::mark ~ ::(published)` is signed by
  # this host's own key alone; otherwise prints the reason and returns 1.
  # Bounded: a wedge is a few reconcile and evidence commits, and a gap of
  # hundreds is not something to prove one signature at a time.
  fleet_trust_pg_gap="::$2 ~ ::($3) ~ root()"
  fleet_trust_pg_rest=$(jj -R "$1" log -r "$fleet_trust_pg_gap" --no-graph \
    --limit 201 -T 'commit_id ++ "\n"' 2>/dev/null) || {
    printf 'its history is unreadable\n'
    return 1
  }
  fleet_trust_pg_n=$(printf '%s\n' "$fleet_trust_pg_rest" | grep -c . || true)
  [ "$fleet_trust_pg_n" -le 200 ] || {
    printf 'over 200 unpublished commits\n'
    return 1
  }
  [ "$fleet_trust_pg_n" -gt 0 ] || return 0
  fleet_trust_pg_me=$(fleet_principal)
  fleet_trust_pg_own=$(mktemp "${TMPDIR:-/tmp}/roundhouse-own.XXXXXX")
  awk -v p="$fleet_trust_pg_me" '$1 == p' \
    "$(fleet_trust_materialized_path)" >"$fleet_trust_pg_own" 2>/dev/null || :
  if [ ! -s "$fleet_trust_pg_own" ]; then
    rm -f "$fleet_trust_pg_own"
    printf 'own key absent from the materialized roster\n'
    return 1
  fi
  fleet_trust_pg_sigs=$(fleet_trust_signature_read "$1" "$fleet_trust_pg_gap" \
    "$fleet_trust_pg_own") || {
    rm -f "$fleet_trust_pg_own"
    printf 'no usable revocation list\n'
    return 1
  }
  rm -f "$fleet_trust_pg_own"
  # One line per commit, each `good <me> <me>`; a count that disagrees with the
  # gap is a read that went wrong, and it holds like any other.
  if [ "$(printf '%s\n' "$fleet_trust_pg_sigs" | grep -c . || true)" -ne "$fleet_trust_pg_n" ] ||
    ! printf '%s\n' "$fleet_trust_pg_sigs" | awk -v p="$fleet_trust_pg_me" '
      NF && !($1 == "good" && $2 == p && $3 == p) { bad = 1 }
      END { exit(bad ? 1 : 0) }'; then
    printf 'a commit not signed by this host is missing from origin\n'
    return 1
  fi
}

fleet_trust_migrate_proof_seen() {
  # fleet_trust_migrate_proof_seen <store> <published-revset> — silent and 0
  # when nothing the op log records for main@origin has left `::(published)`;
  # otherwise prints the reason and returns 1.
  fleet_trust_ps_seen=$(fleet_trust_seen_published "$1") || {
    printf 'the operation log is unreadable\n'
    return 1
  }
  fleet_trust_ps_tip=$(jj -R "$1" log -r 'present(main@origin)' --no-graph \
    -T 'commit_id' 2>/dev/null) || fleet_trust_ps_tip=
  if [ -z "$fleet_trust_ps_seen" ]; then
    # Nothing ever seen published is believable only where nothing is
    # published now; with a main@origin present it is an op-diff this parser
    # could not read.
    [ -z "$fleet_trust_ps_tip" ] || {
      printf 'the operation log records no main@origin\n'
      return 1
    }
    return 0
  fi
  [ -z "$fleet_trust_ps_tip" ] ||
    printf '%s\n' "$fleet_trust_ps_seen" | grep -Fqx "$fleet_trust_ps_tip" || {
    printf 'the operation log lacks the current main@origin\n'
    return 1
  }
  # Revsets of 400 ids: one jj call per batch, under Linux's 128 KiB argument
  # ceiling. NO `present()` around the ids: a recorded position this store
  # cannot resolve is an error, and an error holds.
  fleet_trust_ps_batch=
  fleet_trust_ps_count=0
  for fleet_trust_ps_id in $fleet_trust_ps_seen ''; do
    if [ -n "$fleet_trust_ps_id" ]; then
      fleet_trust_ps_batch="$fleet_trust_ps_batch${fleet_trust_ps_batch:+ | }$fleet_trust_ps_id"
      fleet_trust_ps_count=$((fleet_trust_ps_count + 1))
      [ "$fleet_trust_ps_count" -ge 400 ] || continue
    fi
    [ -n "$fleet_trust_ps_batch" ] || continue
    fleet_trust_ps_miss=$(jj -R "$1" log -r "($fleet_trust_ps_batch) ~ ::($2)" \
      --no-graph -T 'commit_id ++ "\n"' 2>/dev/null) || {
      printf 'the operation log names a commit this store cannot read\n'
      return 1
    }
    [ -z "$fleet_trust_ps_miss" ] || {
      printf 'main@origin once held %s, which origin no longer has\n' \
        "$(printf '%s\n' "$fleet_trust_ps_miss" | head -1)"
      return 1
    }
    fleet_trust_ps_batch=
    fleet_trust_ps_count=0
  done
}

fleet_trust_migrate_proof() {
  # fleet_trust_migrate_proof <store> <mark> <published-revset> -> prints the
  # mark's newest ancestor in `::(published)` (or nothing, see below) and
  # returns 0 when both proofs hold; otherwise prints the reason, returns 1.
  #
  # NO published ancestor is acceptable in exactly one state: nothing is
  # published now and (proof 2) the op log never saw anything published —
  # host 1 between fleet-enroll and its first push, its genesis as the mark.
  # There is nothing origin could have rolled back, so the mark becomes "none
  # yet". Anywhere else no ancestor means a different root, which is
  # §7.11.2's business and holds.
  fleet_trust_mp_anchor=$(jj -R "$1" log \
    -r "heads(::$2 & ::($3) ~ root())" --no-graph -T 'commit_id ++ "\n"' \
    2>/dev/null | grep . || true)
  case $(printf '%s\n' "$fleet_trust_mp_anchor" | grep -c . || true) in
    1) ;;
    0)
      [ -z "$(jj -R "$1" log -r 'present(main@origin)' --no-graph \
        -T 'commit_id' 2>/dev/null)" ] || {
        printf 'no published ancestor\n'
        return 1
      }
      ;;
    *)
      printf 'no single newest published ancestor\n'
      return 1
      ;;
  esac
  fleet_trust_mp_why=$(fleet_trust_migrate_proof_own_gap "$1" "$2" "$3") || {
    printf '%s\n' "$fleet_trust_mp_why"
    return 1
  }
  fleet_trust_mp_why=$(fleet_trust_migrate_proof_seen "$1" "$3") || {
    printf '%s\n' "$fleet_trust_mp_why"
    return 1
  }
  printf '%s\n' "$fleet_trust_mp_anchor"
}

fleet_trust_migrate_legacy_mark() {
  # fleet_trust_migrate_legacy_mark <store> <mark> — the materialize gate's
  # hook: prints the mark to stand in for <mark>, or returns 1 (the reason on
  # stderr). Only a legacy-format mark is ever considered.
  fleet_trust_migrate_legacy_format || return 1
  fleet_trust_ml=$(fleet_trust_migrate_proof "$1" "$2" 'present(main@origin)') || {
    printf 'roundhouse: legacy reviewed-ref %s is not provably local-only work (%s)\n' \
      "$2" "$fleet_trust_ml" >&2
    return 1
  }
  printf '%s\n' "$fleet_trust_ml"
}

fleet_trust_migrate_catchup_mark() {
  # fleet_trust_migrate_catchup_mark <store> <mark> <archive-tip> — the §7.11.2
  # catch-up's hook, with the archive counted as published (it is the old
  # line, by the protocol's own definition). Prints the re-anchored mark, or
  # the reason and returns 1.
  fleet_trust_migrate_proof "$1" "$2" "present(main@origin) | $3"
}
