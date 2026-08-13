# roundhouse — the run driver: two cadences, one convergence.
#
# §6, §6.1, §8 and §10 of docs/specs/2026-08-06-dsc-storage-design-v2.md. This
# unit is the integration point and owns no new doctrine of its own: the fold,
# the records, the signature gate, the reconcile runbook and the resolution
# ladder each already decided their own question, and what is left is the ORDER
# they are asked in. That order is the design:
#
#   poll floor -> fetch -> step 0 -> promote gate -> fold at R per head ->
#   hold set -> review -> verdict -> apply -> applied/ -> journal -> publish
#
# Two rules bind every line below and neither is stylistic:
#
#   The bare token `main` never appears in a revset (§8.1). Every read goes
#   through lib/fleet-vcs.sh, which is where that rule is enforced once.
#
#   NEVER `jj new -m ''` after a push. An undescribed commit that becomes an
#   ancestor of the bookmark refuses to push forever; `fleet_vcs_publish`'s
#   `jj new <target>` is the only post-push working-copy move in the system.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

# --- §7.6 the verdict, host-local and never replicated ------------------------

fleet_run_state_dir() {
  # store.run/ — verdicts, the nudge memo, the starting operation id. The
  # judges named a fleet-writable verdict as the one thing that must not
  # survive: it puts a consent-shaped artifact on a shared surface and then
  # needs prose to say it is not one. The canary gate reads journal/ instead.
  fleet_instance_path store.run
}

fleet_run_verdict_path() {
  printf '%s/verdicts/%s.yaml\n' "$(fleet_run_state_dir)" "$1"
}

fleet_run_verdict_write() {
  # fleet_run_verdict_write ITEM DIGEST REASON [REVIEWER] [VERDICT]
  #
  # ONE writer for both verdicts. The run writes `pass` as it applies; a human
  # writes either through `fleet-review`. Keeping them one record shape is what
  # lets the run's hold guard below read a human's decision without a second
  # vocabulary — and a `hold` the run could not see would be decoration.
  fleet_record_write "$(fleet_run_verdict_path "$1")" \
    "$(jq -cn --arg item "$1" --arg digest "$2" --arg reason "$3" \
      --arg reviewer "${4:-agent}" --arg verdict "${5:-pass}" \
      --arg at "$(fleet_now)" \
      '{item:$item,verdict:$verdict,reason:$reason,digest:$digest,
        reviewer:$reviewer,decided_at:$at}')"
}

fleet_run_verdict_digest() {
  fleet_record_read "$(fleet_run_verdict_path "$1")" '{}' |
    jq -r 'select(.verdict == "pass") | .digest // empty'
}

fleet_run_verdict_held() {
  # fleet_run_verdict_held ITEM DIGEST — a hold BOUND TO THIS DIGEST. Keying on
  # the digest is the whole point: a hold is a judgement about a value, so the
  # next edit to that item is a new value that has never been reviewed and must
  # not inherit the refusal. An unkeyed hold is a permanent one nobody
  # remembers setting.
  [ "$(fleet_record_read "$(fleet_run_verdict_path "$1")" '{}' |
    jq -r 'select(.verdict == "hold") | .digest // empty')" = "$2" ]
}

# --- §6.1 the two cadences, and the jitter that keeps them from synchronising -

fleet_run_jitter() {
  # fleet_run_jitter SEED SPAN -> a stable offset in [0, SPAN). Seeded from the
  # host NAME, never from the clock or a random draw: a fleet whose hosts
  # re-roll their offset every run converges on the same minute as often as it
  # spreads out, and jitter is this design's only coordination primitive
  # (§10.5 — there are no leases to fall back on).
  [ "${2:-0}" -gt 0 ] 2>/dev/null || {
    printf '0\n'
    return
  }
  fleet_run_seed=$(printf '%s' "$1" | sha256_stream | cut -c1-8)
  printf '%s\n' "$((0x$fleet_run_seed % $2))"
}

fleet_run_interval_seconds() {
  # fleet_run_interval_seconds FOLD HOST fast|full -> seconds until the next
  # run of that cadence, jittered symmetrically about the configured base.
  #
  # Policy comes from the FOLD — desired state like everything else, which is
  # what makes it reviewable, signed and fleet-wide (§5). Never from a file on
  # the box being governed: zeroing a knob locally must not weaken a gate.
  # `fleet_policy_int` FLOORS the value and falls back to the built-in default
  # on a non-number: a signed `cadence_hours: 12.0` (a realistic
  # digest-perturbing edit) reached bare `$(( ))` and crashed bash with an
  # undocumented exit, no alert, on every host at the next scheduling read.
  case $3 in
    fast)
      fleet_run_base=$(fleet_policy_int "$1" fast_interval_minutes)
      fleet_run_span=$(fleet_policy_int "$1" fast_jitter_minutes)
      ;;
    *)
      fleet_run_base=$(($(fleet_policy_int "$1" cadence_hours) * 60))
      fleet_run_span=$(fleet_policy_int "$1" jitter_minutes)
      ;;
  esac
  fleet_run_offset=$(fleet_run_jitter "$2" $((fleet_run_span * 2 + 1)))
  printf '%s\n' $(((fleet_run_base - fleet_run_span + fleet_run_offset) * 60))
}

fleet_run_stale_after() {
  # fleet_run_stale_after STORE HOST -> the run-lock staleness threshold, in
  # seconds: TWO FULL CADENCES, and never anything derived from the fast
  # interval.
  #
  # §10.6 is explicit about this and the reason is arithmetic: §6.1 introduced
  # a second, much shorter cadence, and `fast_interval_minutes` (20) through
  # the same expression gives a ~40-minute threshold — long enough to look
  # plausible and short enough to declare a LIVE full run's lock stale on the
  # very next fast run, which is how every later run gets stuck.
  #
  # The fold is read from the working copy rather than from the reviewed ref:
  # the lock is taken before anything resolves R, and a threshold that needed R
  # could not be computed at the moment it is needed. Absent policy falls
  # through to fleet_policy_defaults' 12 hours like every other reader.
  stale_fold=$(fleet_fold "$1" "$2" 2>/dev/null) || stale_fold=
  [ -n "$stale_fold" ] || stale_fold='{}'
  printf '%s\n' "$(($(fleet_policy_int "$stale_fold" cadence_hours) * 7200))"
}

# --- §6.1(a) the poll floor ---------------------------------------------------

fleet_run_poll_floor() {
  # Exit 0 when there is genuinely nothing to do. ALL THREE CONDITIONS are
  # needed: rev 5 checked only the remote head, so a host with a
  # committed-but-unpushed edit and an unchanged remote exited immediately and
  # its own edit sat unpublished — which breaks §6.1's freshness target at the
  # PUBLISHING end.
  #
  # `git ls-remote` joins `git verify-commit` as the second and last read-only
  # git invocation this system makes (§8.4's ban is on `git push`/`git
  # commit`). It moves no local ref and transfers no objects.
  fleet_run_remote=$(git -C "$1" ls-remote origin refs/heads/main 2>/dev/null |
    awk 'NR == 1 { print $1; exit }')
  fleet_run_local=$(fleet_vcs_head_origin "$1")
  # `present()` so a never-fetched store answers empty instead of erroring —
  # host 1's very first run, and any host whose remote was just re-pointed.
  fleet_run_pending=$(jj -R "$1" log \
    -r 'present(main@origin)..heads(bookmarks(exact:"main"))' \
    --no-graph -T 'commit_id ++ "\n"')
  fleet_run_dirty=$(jj -R "$1" log -r @ --no-graph -T 'if(empty,"","x")')
  # A fourth condition, host-local, and it is what makes the other three a
  # PROPAGATION check rather than a convergence one: a host that just cloned
  # has nothing to pull and nothing to push and has applied nothing, so on the
  # three conditions alone it would sit idle until the remote happened to
  # move. The marker is the reference this host last completed a run against.
  [ "$fleet_run_remote" = "$fleet_run_local" ] &&
    [ -z "$fleet_run_pending" ] && [ -z "$fleet_run_dirty" ] &&
    [ "$(cat "$(fleet_run_state_dir)/converged" 2>/dev/null)" = \
      "$(fleet_vcs_heads_local "$1")" ]
}

fleet_run_prune_empty() {
  # §8.1's invariant, repaired rather than asserted: @ must be a child of a
  # main target, and after `fleet-enroll` it is not.
  #
  # MEASURED on jj 0.44: `fleet-init` leaves an empty undescribed @, then
  # `fleet-enroll` runs `jj new -m ''` on top of it to get a post-enrollment
  # author — and jj does NOT abandon the first one, because a working-copy
  # commit is only abandoned when nothing is left standing on it. So the first
  # real convergence merges an EMPTY UNDESCRIBED COMMIT into main's ancestry
  # and every push from then on dies with "Won't push commit … since it has no
  # description". The store is bricked by its own bootstrap.
  #
  # Abandoning is lossless by construction — these commits are empty — and it
  # is the same operation jj performs itself in the case it does handle.
  jj -R "$1" log \
    -r '::@ ~ @ ~ ::(heads(bookmarks(exact:"main")) | present(main@origin))' \
    --no-graph -T 'commit_id ++ "\n"' 2>/dev/null |
    while IFS= read -r fleet_run_stale; do
      [ -n "$fleet_run_stale" ] || continue
      [ "$(jj -R "$1" log -r "$fleet_run_stale" --no-graph \
        -T 'if(empty, if(description, "n", "y"), "n")')" = y ] || continue
      jj -R "$1" abandon -r "$fleet_run_stale" >/dev/null 2>&1 || :
    done
}

# --- reviewed content: the layers at a real commit ----------------------------

fleet_run_layer_path() {
  # Store-relative paths the fold reads. Everything else in the tree is a
  # record: evidence a host publishes about itself, never desired state.
  #
  # A case glob's `*` matches `/`, so `hosts/*.yaml` already covers §2's
  # directory form (`hosts/wren/skills.yaml`) — spelling both is a pattern that
  # can never match.
  case $1 in
    fleet.yaml | definitions.yaml | fleet/*.yaml | os/*.yaml | groups/*.yaml | \
      hosts/*.yaml) ;;
    definitions/*.yaml) fleet_definitions_file_path "$1" || return 1 ;;
    *) return 1 ;;
  esac
}

fleet_run_export() {
  # fleet_run_export STORE REV DEST — the layers at REV as plain files, so the
  # fold runs over a real commit without a checkout and without touching the
  # working copy. This is how §8.3 reads each head while the merge is
  # conflicted: `jj file show -r <head>` returns clean per-side YAML that yq
  # parses, and the conflicted commit's own content does not.
  #
  # `-T 'path'` is not decoration: a bare `jj file list` prints paths relative
  # to the CALLER's working directory, so from anywhere else every line comes
  # back as `../../../store/hosts/vireo.yaml`. Measured on jj 0.44.
  mkdir -p "$3"
  jj -R "$1" file list -r "$2" -T 'path ++ "\n"' 2>/dev/null |
    while IFS= read -r fleet_run_path; do
      fleet_run_layer_path "$fleet_run_path" || continue
      mkdir -p "$3/$(dirname "$fleet_run_path")"
      # `root:` makes the argument repo-root-relative regardless of cwd.
      jj -R "$1" file show -r "$2" "root:$fleet_run_path" \
        >"$3/$fleet_run_path" 2>/dev/null || :
    done
}

fleet_run_item_digests() {
  # fleet_run_item_digests FOLD [LAYERDIR] -> `<item> <digest>` lines, which is
  # exactly what §8.3's hold set reads.
  #
  # LAYERDIR brings the definitions file/directory INTO THE ITEM UNIVERSE. It is correctly
  # outside the fold (§5.1 — a mapping is a lookup, not a want), and nothing
  # else enumerated it either, so `definitions.*` had no digest, no verdict, no
  # §8.3 hold entry and no §7.7 narrow-hold entry. That made rule 6's
  # deliberately-narrow hold set EMPTY for a definitions-only commit: an
  # `ephemeral` leaf — 40/day by construction — could commit nothing but
  # definitions content, be correctly refused by the class rule, produce zero
  # holds, and have the run clone its skill source and install its package
  # anyway. §5.1's "the `definitions.` prefix is load-bearing" is what keeps
  # `definitions.packages.jj` and `packages.jj` from sharing one verdict key.
  fleet_items "$1" | while IFS= read -r fleet_run_item; do
    [ -n "$fleet_run_item" ] || continue
    fleet_run_digest=$(fleet_item_digest "$1" "$fleet_run_item") || continue
    printf '%s %s\n' "$fleet_run_item" "$fleet_run_digest"
  done
  [ -n "${2:-}" ] || return 0
  fleet_run_defs=$(fleet_definitions_load "$2")
  fleet_definition_items "$fleet_run_defs" | while IFS= read -r fleet_run_item; do
    [ -n "$fleet_run_item" ] || continue
    fleet_run_dcat=${fleet_run_item#definitions.}
    fleet_run_dcat=${fleet_run_dcat%%.*}
    fleet_run_dvalue=$(fleet_definition_entry "$fleet_run_defs" \
      "$fleet_run_dcat" "${fleet_run_item#"definitions.$fleet_run_dcat."}")
    [ -n "$fleet_run_dvalue" ] || continue
    fleet_run_digest=$(printf '%s\n' "$fleet_run_dvalue" |
      fleet_value_digest "$fleet_run_item") || continue
    printf '%s %s\n' "$fleet_run_item" "$fleet_run_digest"
  done
}

fleet_run_item_layer() {
  # fleet_run_item_layer LAYERDIR HOST ITEM -> the store-relative layer file
  # whose opinion wins. Provenance is FILE, never file:line: yq's `line`
  # operator does not count comment-only lines, and every layer file is
  # commented by design, so a confidently wrong number is worse than none.
  fleet_run_split=$(fleet_item_split "$3") || return 1
  fleet_run_category=$(printf '%s\n' "$fleet_run_split" | sed -n 1p)
  fleet_run_name=$(printf '%s\n' "$fleet_run_split" | sed -n 2p)
  fleet_run_winner=
  while IFS= read -r fleet_run_file; do
    [ -n "$fleet_run_file" ] || continue
    [ "$(fleet_explain_layer_value "$fleet_run_file" "$fleet_run_category" \
      "$fleet_run_name")" = '""' ] || fleet_run_winner=$fleet_run_file
  done <<EOF
$(fleet_layer_files "$1" "$2")
EOF
  [ -n "$fleet_run_winner" ] || return 1
  printf '%s\n' "${fleet_run_winner#"$1/"}"
}

# --- §6 step 4: the promote gate, and §8.2's precedence over it ---------------

fleet_run_promote_gate() {
  # Every changed layer file in @ must parse. If they do, the run describes @
  # and moves the bookmark to it (which is what the §8.2 runbook's steps 1-2
  # do). If they don't, it REFUSES to promote and converges from the last good
  # `main` — a broken file never becomes the reviewed line.
  #
  # Prints `<file>: <yq's own message>` per failure; silence is clean.
  #
  # THE §8.2 PRECEDENCE IS THE CALLER'S, and it is skipped here for the one
  # state that would otherwise fire it spuriously: a layer file carrying
  # snapshot markers fails `yq -e '.'`, so on the conflicted path this gate
  # would alert every run pointing at a line number INSIDE a conflict marker,
  # and pick a different reconcile point than §8.2/§8.3. One state, one
  # answer: §8.2 wins.
  [ -z "$(fleet_vcs_conflicted "$1" @)" ] || return 0
  fleet_run_broken=0
  while IFS= read -r fleet_run_changed; do
    [ -n "$fleet_run_changed" ] || continue
    fleet_run_layer_path "$fleet_run_changed" || continue
    [ -f "$1/$fleet_run_changed" ] || continue
    fleet_run_parse=$(yq -e '.' "$1/$fleet_run_changed" 2>&1 >/dev/null) || {
      printf '%s: %s\n' "$fleet_run_changed" \
        "$(printf '%s' "$fleet_run_parse" | tr '\n' ' ')"
      fleet_run_broken=1
    }
  done <<EOF
$(cd "$1" && jj diff -r @ --name-only 2>/dev/null)
EOF
  # `jj diff --name-only` refuses -T, so it runs with cwd INSIDE the store or
  # every name comes back absolute.
  [ "$fleet_run_broken" -eq 0 ]
}

# --- §7.1/§7.3/§7.7: hold only what an unverifiable commit touched ------------

fleet_run_file_items() {
  # fleet_run_file_items <file-on-disk> [store-relative-path] — every item a
  # layer file contributes, `<category>.<name>`.
  #
  # A definitions file contributes DEFINITIONS items, under the reserved prefix.
  # Without it this function emitted `packages.jj` for the definitions file, so
  # a file-scoped refusal of a definitions edit held the coincidentally
  # same-named DESIRED items and never the mapping — §5.1's "the `definitions.`
  # prefix is load-bearing, not decoration", read backwards.
  # yq does the YAML->JSON step and jq does the rest, because yq's `as` binding
  # EVALUATES ITS BODY ONCE ON AN EMPTY STREAM: measured on yq v4.53,
  # `to_entries[] | select(…) | .key as $c | … "\($c).\(.)"` over a file with no
  # map-valued top-level key (every host facts file: `platform: macos`) emits a
  # bare `.` — a bogus item id that entered every file-scoped hold set. jq's
  # empty stream stays empty.
  #
  # The parse status is captured rather than piped: jq exits 0 on empty stdin,
  # so an unparsable file would otherwise read as "this file contributes no
  # items" and hold nothing.
  fleet_run_file_path=${2:-$1}
  case $fleet_run_file_path in
    definitions.yaml | definitions/*.yaml)
      case $fleet_run_file_path in
        definitions/*.yaml)
          fleet_definitions_file_path "$fleet_run_file_path" || return 1
          ;;
      esac
      fleet_run_ns=definitions. ;;
    *) fleet_run_ns= ;;
  esac
  fleet_run_fi_json=$(yq -o=json -I=0 '. // {}' "$1" 2>/dev/null) || return 1
  [ -n "$fleet_run_fi_json" ] || return 1
  printf '%s\n' "$fleet_run_fi_json" |
    jq -r --arg ns "$fleet_run_ns" '
      to_entries[] | select(.value | type == "object") |
      .key as $c | .value | keys[] | "\($ns)\($c).\(.)"'
}

fleet_run_file_items_at_change() {
  # fleet_run_file_items_at_change STORE COMMIT LAYERDIR PATH WORKDIR — the
  # union of the items this changed path contributes before and after the
  # commit. A deleted file (or a deleted key inside a surviving file) has no
  # post-change file to inspect, so using only the reviewed export silently
  # drops the item that must be held.
  fleet_run_file_item_list=$5/file-items
  fleet_run_file_parent_dir=$5/file-parent
  rm -rf "$fleet_run_file_parent_dir"
  : >"$fleet_run_file_item_list"
  if [ -f "$3/$4" ]; then
    fleet_run_file_items "$3/$4" "$4" >>"$fleet_run_file_item_list" || :
  fi
  for fleet_run_file_parent in $(fleet_trust_parents "$1" "$2"); do
    rm -rf "$fleet_run_file_parent_dir"
    fleet_run_export "$1" "$fleet_run_file_parent" \
      "$fleet_run_file_parent_dir" 2>/dev/null || continue
    [ -f "$fleet_run_file_parent_dir/$4" ] || continue
    fleet_run_file_items "$fleet_run_file_parent_dir/$4" "$4" \
      >>"$fleet_run_file_item_list" || :
  done
  LC_ALL=C sort -u "$fleet_run_file_item_list"
}

fleet_run_changed_items() {
  # fleet_run_changed_items STORE COMMIT HOST WORKDIR -> the items whose
  # VALUE this commit actually changed, by §8.3's per-parent comparison reused
  # verbatim: fold the layers at each real parent and at the commit, and take
  # the items whose digest differs (an item that appears or disappears differs
  # like any other).
  #
  # This is the narrower hold set §7.7 gives a CLASS refusal specifically —
  # where the content parses and the signature is good and only the author's
  # authority is wrong. Verified on a leaf touching one key of a three-key
  # layer file: file-scoped hold = a,b,c; item-scoped hold = b. A leaf can still
  # degrade what it touched; it can no longer freeze a file by brushing
  # against it.
  rm -rf "$4/at" "$4/before"
  fleet_run_export "$1" "$2" "$4/at" 2>/dev/null || return 0
  fleet_run_item_digests "$(fleet_fold "$4/at" "$3" 2>/dev/null || printf '{}')" \
    "$4/at" >"$4/digests.at"
  : >"$4/digests.before"
  for fleet_run_cparent in $(fleet_trust_parents "$1" "$2"); do
    rm -rf "$4/before"
    fleet_run_export "$1" "$fleet_run_cparent" "$4/before" 2>/dev/null || continue
    fleet_run_item_digests \
      "$(fleet_fold "$4/before" "$3" 2>/dev/null || printf '{}')" "$4/before" \
      >>"$4/digests.before"
  done
  LC_ALL=C sort -u "$4/digests.before" >"$4/digests.before.u"
  LC_ALL=C sort -u "$4/digests.at" >"$4/digests.at.u"
  # BOTH directions. An item this commit REMOVED changed just as much as one it
  # rewrote, and taking only the additions would let a refused author delete an
  # item from a shared layer without that item being held.
  comm -3 "$4/digests.at.u" "$4/digests.before.u" | awk '{ print $1 }' |
    LC_ALL=C sort -u
}

fleet_run_signature_holds() {
  # fleet_run_signature_holds STORE RANGE HOSTS_FILE LAYERDIR HOST
  #   [REVIEWED-ROSTER] [WORKDIR]
  #
  # §7.7's unifying rule: a bad edit NARROWS what is applicable; it never
  # breaks the store and never blocks unrelated items. Every failure is
  # item-scoped, and a class refusal is scoped narrower still.
  #
  # THE RATCHET LOOP. Each commit is verified against the roster materialized
  # from EVERY ONE OF ITS PARENTS — never `jj file show -r <C>-`, which for a
  # merge silently picks one and lets a removed member keep pushing forever by
  # parenting its commits before its own removal (§7.1). §8.2 manufactures
  # merges as its normal path, so the singular reading is not a corner case.
  #
  # Prints `<item> <reason>` lines, plus the reserved marker `!hold <reason>`
  # for a condition whose scope is the WHOLE run. `!hold` can never collide
  # with an item id, which is always `<category>.<name>` and always carries a
  # dot; the caller escalates it to a fleet alert and `exit 65`.
  #
  # A MISSING KRL IS NOT "NO HOLDS". `fleet_trust_krl >/dev/null 2>&1 ||
  # return 0` discarded the warning and returned the same empty output a fully
  # verified range produces, so deleting one user-writable file turned every
  # gate in §7 off silently — unsigned commits, foreign principals and retired
  # members all applied, and §7.1a says the opposite ("returns `bad` for
  # everything … refused loudly"). The bootstrap carve-out survives, narrowed
  # to the state that actually needs it: a store between fleet-init and
  # fleet-enroll, which has no genesis yet and so has nothing to verify against.
  fleet_run_krlerr=$(fleet_trust_krl 2>&1 >/dev/null) || {
    [ -n "$(fleet_store_id "$1")" ] || return 0
    printf '!hold %s\n' \
      "${fleet_run_krlerr:-no usable revocation list}; every signature would report bad, so nothing can be verified (§7.1a)"
    return 0
  }
  fleet_run_sigwork=${7:-$(fleet_run_state_dir)}
  mkdir -p "$fleet_run_sigwork"
  # The roster AS THE GENESIS COMMIT STATED IT, rendered once: it is what tells
  # a real `channel_auth: genesis` from one an attacker typed into their own
  # block later. Absent (a store with no genesis yet) means no principal is a
  # genesis member, which is the safe direction.
  fleet_run_store_genesis=$(fleet_store_id "$1")
  fleet_run_genesis_roster=
  [ -z "$fleet_run_store_genesis" ] || {
    fleet_run_genesis_roster=$fleet_run_sigwork/genesis-roster
    fleet_trust_roster_at_head "$1" "$fleet_run_store_genesis" \
      "$fleet_run_genesis_roster"
  }
  jj -R "$1" log -r "$2" --no-graph -T 'commit_id ++ "\n"' 2>/dev/null |
    while IFS= read -r fleet_run_commit; do
      [ -n "$fleet_run_commit" ] || continue
      fleet_run_roster="$fleet_run_sigwork/roster.$fleet_run_commit"
      fleet_run_reason=$(fleet_trust_commit_hold "$1" "$fleet_run_commit" \
        "$fleet_run_roster" "${6:-}") || fleet_run_reason=${fleet_run_reason:-unverifiable}
      # A REJECTED ROSTER COMMIT ESCALATES OUT OF THE ITEM-SCOPED PATH.
      # `trust/signers.yaml` is not a layer path, so a commit that fails
      # verification while rewriting the roster held NOTHING — every hold below
      # is scoped to layer files that exist in the exported tree — while still
      # supplying the roster its children are verified against. That is the
      # §7.12.5 bypass in two commits: C1 adds the attacker's own key and is
      # correctly refused; C2, its child, is then verified against C1's bytes,
      # comes back `good`, and writes desired state. The ratchet checks each
      # commit against whatever sits at its parent; nothing required the commit
      # that PUT those bytes there to have verified. Until derivation carries
      # only verified roster state forward, a failed roster commit is a
      # store-wide refusal.
      if [ -n "$fleet_run_reason" ] &&
        (cd "$1" && jj diff -r "$fleet_run_commit" --name-only 2>/dev/null) |
        grep -Fqx "$fleet_trust_roster_file"; then
        printf '!hold %s\n' \
          "commit $fleet_run_commit rewrites $fleet_trust_roster_file and does not verify: $fleet_run_reason"
      fi
      fleet_run_principal=$(fleet_trust_principal "$1" "$fleet_run_commit" \
        "$fleet_run_roster/roster")
      fleet_run_class=$(fleet_trust_class_of "$fleet_run_roster/classes" \
        "$fleet_run_principal")
      fleet_run_narrow=
      (cd "$1" && jj diff -r "$fleet_run_commit" --name-only 2>/dev/null) |
        while IFS= read -r fleet_run_touched; do
          [ -n "$fleet_run_touched" ] || continue
          fleet_run_bad=$fleet_run_reason
          fleet_run_scope=file
          if [ -z "$fleet_run_bad" ] &&
            ! fleet_vcs_path_identity_ok "$fleet_run_touched" \
              "$fleet_run_principal" "$3"; then
            fleet_run_bad="path $fleet_run_touched may not be authored by $fleet_run_principal"
          fi
          # Rule 6, and its hold set is DELIBERATELY narrower than every other
          # failure's: the content parses and the signature is good, so there is
          # no reason to distrust the untouched items.
          if [ -z "$fleet_run_bad" ] &&
            ! fleet_trust_class_allows "$fleet_run_class" "$fleet_run_touched"; then
            fleet_run_bad="class $fleet_run_class may not write $fleet_run_touched"
            fleet_run_scope=item
          fi
          # §7.12.1's soak, evaluated from the SAME derived roster the class
          # came from — reading it at the current head would let an attacker's
          # own later commit shorten their own soak.
          if [ -z "$fleet_run_bad" ] &&
            [ "$(fleet_vcs_path_owner "$fleet_run_touched" 2>/dev/null)" = '*' ] &&
            fleet_trust_soak_open "$fleet_run_roster/classes" \
              "$fleet_run_principal" \
              "$(fleet_trust_commit_time "$1" "$fleet_run_commit")" \
              "$fleet_run_genesis_roster"; then
            fleet_run_bad="$fleet_run_principal is inside its enrollment soak window and may not write fleet layers yet"
          fi
          [ -n "$fleet_run_bad" ] || continue
          # A FAILURE THAT TOUCHES A §7-VERIFICATION PATH ESCALATES TO A
          # STORE-WIDE HOLD, never a dropped item hold. trust/, checkpoints/,
          # lineage/ and proposals/ are not layer paths, so the item-scoped
          # `fleet_run_layer_path || continue` below discarded their computed
          # `fleet_run_bad` entirely — a leaf holding a real key with a good
          # signature could author a `trust/signers.yaml` edit adding a durable
          # key, be refused by the class rule, produce NO hold, and have it
          # materialized fleet-wide. This is the §7.12.5 boundary; treat it
          # exactly like the unverifiable-roster-commit escalation above.
          case $fleet_run_touched in
            trust/* | checkpoints/* | lineage/* | proposals/*)
              printf '!hold %s\n' \
                "commit $fleet_run_commit writes $fleet_run_touched and does not satisfy §7 verification: $fleet_run_bad"
              continue
              ;;
          esac
          fleet_run_layer_path "$fleet_run_touched" || continue
          fleet_run_changed_file_items=$(fleet_run_file_items_at_change \
            "$1" "$fleet_run_commit" "$4" "$fleet_run_touched" \
            "$fleet_run_roster")
          [ -n "$fleet_run_changed_file_items" ] || continue
          if [ "$fleet_run_scope" = item ]; then
            [ -n "$fleet_run_narrow" ] || {
              fleet_run_changed_items "$1" "$fleet_run_commit" "$5" \
                "$fleet_run_roster" >"$fleet_run_roster/narrow"
              fleet_run_narrow=$fleet_run_roster/narrow
            }
            printf '%s\n' "$fleet_run_changed_file_items" |
              comm -12 - "$fleet_run_narrow" |
              while IFS= read -r fleet_run_held_item; do
                [ -n "$fleet_run_held_item" ] || continue
                printf '%s %s\n' "$fleet_run_held_item" "$fleet_run_bad"
              done
            continue
          fi
          printf '%s\n' "$fleet_run_changed_file_items" |
            while IFS= read -r fleet_run_held_item; do
              [ -n "$fleet_run_held_item" ] || continue
              printf '%s %s\n' "$fleet_run_held_item" "$fleet_run_bad"
            done
        done
    done
}

# --- §8.2b: the evidence the ladder decides on --------------------------------

fleet_run_trailer() {
  # fleet_run_trailer STORE REV NAME — one §5 trailer off a commit
  # description. SELF-ASSERTED free text: exactly one rule in the ladder reads
  # it (rule 2), and that rule's only possible outcome is escalation.
  jj -R "$1" log -r "$2" --no-graph -T 'description' 2>/dev/null |
    sed -n "s/^$3: //p" | tail -1
}

fleet_run_side_session() {
  # fleet_run_side_session STORE SIDE OTHER — §8.2b rule 2's input, read over
  # the side's UNIQUE RANGE and not at its tip.
  #
  # RULE 2 COULD NOT FIRE ON A REAL HAND EDIT. Roundhouse stamps every head it
  # publishes `scheduled/agent` (fleet_run_publish, fleet_vcs_reconcile), and
  # §8.2 step 1 folds the operator's edit in as a PARENT of the merge — so the
  # operator's `interactive/human` trailer is never on a head, and reading one
  # commit found `scheduled/agent` on both sides every time. The ladder then
  # arbitrated with rule 4 or 5 and the hand edit SILENTLY LOST, with a
  # `resolved` journal record asserting it was decided on grounded evidence.
  # §8.2b pays for the opposite explicitly: "a genuine hand edit conflicting
  # with an agent edit escalates instead of silently winning."
  #
  # The question the rule asks is "is a human on this side", which is a question
  # about the range, not about one commit. `fleet_resolve_is_human` is already
  # the right predicate — only the input revset was wrong — and it fails an
  # unrecognised or absent session kind TOWARD the human, which is why a
  # trailerless commit anywhere in the range escalates.
  fleet_run_sess_range=$2
  [ -z "${3:-}" ] || fleet_run_sess_range="$3..$2"
  fleet_run_sess_found=
  while IFS= read -r fleet_run_sess_commit; do
    [ -n "$fleet_run_sess_commit" ] || continue
    ! fleet_resolve_is_human \
      "$(fleet_run_trailer "$1" "$fleet_run_sess_commit" roundhouse-session)" ||
      fleet_run_sess_found=interactive/human
  done <<EOF
$(jj -R "$1" log -r "$fleet_run_sess_range" --no-graph -T 'commit_id ++ "\n"' \
  2>/dev/null)
EOF
  printf '%s\n' \
    "${fleet_run_sess_found:-$(fleet_run_trailer "$1" "$2" roundhouse-session)}"
}

fleet_run_applied_elsewhere() {
  # fleet_run_applied_elsewhere STORE SELF ITEM DIGEST HOSTS_FILE
  #
  # §8.2b's replicated-journal class, read off `applied/<h>.yaml` because that
  # file answers the question the rule actually asks — is a PEER carrying this
  # value RIGHT NOW — in one read. A value that was applied and later reverted
  # or superseded is no longer the peer's applied digest, so "and has not since
  # reverted or superseded it" falls out of the record shape rather than out of
  # a journal replay. Attribution is §7.3's: only `<h>` may write `applied/<h>`.
  while IFS= read -r fleet_run_peer; do
    [ -n "$fleet_run_peer" ] || continue
    [ "$fleet_run_peer" != "$2" ] || continue
    [ "$(fleet_applied_digest "$1" "$fleet_run_peer" "$3")" != "$4" ] ||
      return 0
  done <"$5"
  return 1
}

fleet_run_journal_at() {
  # fleet_run_journal_at STORE ITEM DIGEST HOSTS_FILE -> the newest `at` any
  # host recorded applying this value, ISO8601 Z, or nothing.
  #
  # The journal `at`, NEVER `committer.timestamp()`: JJ_TIMESTAMP produces
  # exactly that committer timestamp, so one host with a deliberate future
  # stamp would win every rule-5 contest forever. Journal `at` is what §10.7's
  # 5-minute skew check already covers.
  while IFS= read -r fleet_run_peer; do
    [ -n "$fleet_run_peer" ] || continue
    fleet_journal_entries "$1" "$fleet_run_peer" |
      jq -r --arg item "$2" --arg digest "$3" \
        'select(.item == $item and .digest == $digest and .outcome == "applied") | .at'
  done <"$4" | LC_ALL=C sort | tail -1
}

fleet_run_revert_evidence() {
  # fleet_run_revert_evidence STORE REV ITEM HOST WORKDIR -> two JSON lines:
  # what the change this side NAMES replaced, and what that same change set.
  #
  # Read from HISTORY at <c>- and <c>, never from the trailer. The trailer is
  # only a pointer to what to check: a hostile enrolled host can write
  # `roundhouse-reverts` into a commit that is not a revert, and §8.2b rule 3
  # is what stops that claim winning anything.
  fleet_run_claim=$(fleet_run_trailer "$1" "$2" roundhouse-reverts)
  [ -n "$fleet_run_claim" ] || {
    printf 'null\nnull\n'
    return
  }
  fleet_run_named=$(jj -R "$1" log -r "$fleet_run_claim" --no-graph \
    -T 'commit_id' 2>/dev/null) || fleet_run_named=
  [ -n "$fleet_run_named" ] || {
    printf 'null\nnull\n'
    return
  }
  for fleet_run_side in "$fleet_run_named-" "$fleet_run_named"; do
    rm -rf "$5/claim"
    fleet_run_export "$1" "$fleet_run_side" "$5/claim" 2>/dev/null || :
    fleet_run_claim_fold=$(fleet_fold "$5/claim" "$4" 2>/dev/null) ||
      fleet_run_claim_fold='{}'
    fleet_run_claim_value=$(fleet_item_value "$fleet_run_claim_fold" "$3")
    printf '%s\n' "${fleet_run_claim_value:-null}"
  done
}

fleet_run_evidence() {
  # fleet_run_evidence ITEM INTERVAL MINE_JSON THEIRS_JSON -> §8.2b's evidence
  # document. The split between `grounded` and `asserted` is the safety
  # property, not documentation: signed history and replicated journals are
  # grounded, the §5 trailers are self-asserted, and only rule 2 reads the
  # third class.
  jq -cn --arg item "$1" --argjson interval "$2" \
    --argjson mine "$3" --argjson theirs "$4" \
    '{item:$item,fast_interval_seconds:$interval,mine:$mine,theirs:$theirs}'
}

fleet_run_side() {
  # fleet_run_side STORE REV ITEM HOST HOSTS_FILE WORKDIR LAYERDIR [OTHER-REV]
  # -> one side's `{grounded, asserted}`. OTHER-REV bounds the range the
  # session trailer is read over; see fleet_run_side_session.
  fleet_run_fold=$(fleet_fold "$7" "$4" 2>/dev/null) || fleet_run_fold='{}'
  fleet_run_value=$(fleet_item_value "$fleet_run_fold" "$3")
  fleet_run_value=${fleet_run_value:-null}
  fleet_run_digest=
  [ "$fleet_run_value" = null ] ||
    fleet_run_digest=$(printf '%s\n' "$fleet_run_value" |
      fleet_value_digest "$3" 2>/dev/null) || fleet_run_digest=
  fleet_run_claims=$(fleet_run_revert_evidence "$1" "$2" "$3" "$4" "$6")
  fleet_run_applied=false
  [ -z "$fleet_run_digest" ] ||
    ! fleet_run_applied_elsewhere "$1" "$4" "$3" "$fleet_run_digest" "$5" ||
    fleet_run_applied=true
  fleet_run_at=
  [ -z "$fleet_run_digest" ] ||
    fleet_run_at=$(fleet_run_journal_at "$1" "$3" "$fleet_run_digest" "$5")
  jq -cn --argjson value "$fleet_run_value" \
    --argjson replaced "$(printf '%s\n' "$fleet_run_claims" | sed -n 1p)" \
    --argjson set_to "$(printf '%s\n' "$fleet_run_claims" | sed -n 2p)" \
    --argjson applied "$fleet_run_applied" \
    --arg at "${fleet_run_at:-}" \
    --arg session "$(fleet_run_side_session "$1" "$2" "${8:-}")" \
    --arg host "$(fleet_run_trailer "$1" "$2" roundhouse-host)" \
    --arg intent "$(fleet_run_trailer "$1" "$2" roundhouse-intent)" \
    --arg reverts "$(fleet_run_trailer "$1" "$2" roundhouse-reverts)" \
    '{grounded: {value: $value, revert_replaced: $replaced,
                 revert_set_to: $set_to, applied_elsewhere: $applied,
                 journal_at: (if $at == "" then null else $at end)},
      asserted: {session: $session, host: $host, intent: $intent,
                 reverts: $reverts}}'
}

# --- §10.1/§10.3/§10.8: the gates between a verdict and an apply --------------

fleet_run_canary_hosts() {
  # fleet_run_canary_hosts LAYERDIR GROUP HOSTS_FILE — membership is a grep
  # across the host files (§10.1's own stated ceiling: at ~30 hosts it moves
  # into groups/canary.yaml).
  # An `if`, not an `&&` chain: a `while` loop's status is that of the last
  # command its body ran, so a final non-canary host would fail the whole
  # function under `set -e`.
  while IFS= read -r fleet_run_host; do
    [ -n "$fleet_run_host" ] || continue
    if fleet_host_facts "$1" "$fleet_run_host" 2>/dev/null |
      jq -e --arg g "$2" '(.groups // []) | index($g) != null' >/dev/null 2>&1; then
      printf '%s\n' "$fleet_run_host"
    fi
  done <"$3"
}

fleet_run_is_revert() {
  # fleet_run_is_revert STORE HOST ITEM DIGEST — §10.8's revert-signature
  # predicate, wired to this host's OWN journal. A stored verdict does not
  # satisfy the apply gate when the incoming digest is one this host previously
  # applied and later stopped applying: applied, then withdrawn, now back IS
  # the signature of a revert, and without this a verdict keyed on (item,
  # digest) matches a stale pass and auto-applies the rollback with no review.
  fleet_vcs_journal_outcomes "$1/journal/$2" "$3" |
    fleet_vcs_revert_signature "$4"
}

# --- the apply layer ----------------------------------------------------------

fleet_run_ssh_include() {
  # §5's rendered aliases reach ssh only if ~/.ssh/config includes them. One
  # line, idempotent, FIRST in the file because ssh_config takes the first
  # value it sees for every keyword and a later Include cannot win.
  #
  # This is the one host mutation the fold deliberately left out: rendering is
  # pure (lib/fleet-fold.sh), wiring the render into the host is a run step.
  fleet_run_ssh_dir=$HOME/.ssh
  fleet_run_ssh_config=$fleet_run_ssh_dir/config
  fleet_run_include="Include $fleet_run_ssh_dir/config.d/roundhouse"
  mkdir -p "$fleet_run_ssh_dir/config.d"
  chmod 700 "$fleet_run_ssh_dir" 2>/dev/null || :
  [ -f "$fleet_run_ssh_config" ] || : >"$fleet_run_ssh_config"
  grep -Fqx "$fleet_run_include" "$fleet_run_ssh_config" && return 0
  fleet_run_ssh_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-ssh-include.XXXXXX") ||
    return 1
  printf '%s\n' "$fleet_run_include" >"$fleet_run_ssh_tmp"
  cat "$fleet_run_ssh_config" >>"$fleet_run_ssh_tmp"
  safe_output "$fleet_run_ssh_tmp" "$fleet_run_ssh_config"
  rm -f "$fleet_run_ssh_tmp"
}

fleet_run_state_of() {
  # §4's reader's choice: a scalar IS the state, a map carries it under
  # `state:`, and a map that states none at all defaults to enabled.
  #
  # `has("state")` rather than `.state // "enabled"`: jq's alternative operator
  # treats FALSE and NULL alike, so `state: false` — a plausible hand-edit —
  # read as ABSENT and therefore as `enabled`, quietly turning a stop into a
  # start. lib/fleet-run.sh's own seeder carries this same warning about
  # `.enabled // true`. Returning the value verbatim lets the apply layer's
  # guard hold anything that is not `enabled`/`disabled`.
  printf '%s\n' "$1" |
    jq -r 'if type == "object" then (if has("state") then .state else "enabled" end)
      else . end'
}

fleet_config_drift() {
  # fleet_config_drift HOST FILE VALUE — §6/convergence.md's read-only
  # managed-key drift report. For each key this fleet declares `managed` in the
  # config file, read its CURRENT on-disk value and print it. Changes nothing:
  # `config_files` owns keys, not values (§5 defers value convergence), so there
  # is no stored desired value to compare against or restore — the report exists
  # so a hand-edit to a managed key is SEEN, never silently reverted.
  fleet_run_cf_file=$2
  fleet_run_cf_path=$(expand_user_path "$fleet_run_cf_file")
  printf '%s\n' "$3" |
    jq -r '(.keys // {}) | to_entries[] | select(.value == "managed") | .key' \
      2>/dev/null |
    while IFS= read -r fleet_run_cf_key; do
      [ -n "$fleet_run_cf_key" ] || continue
      if [ ! -f "$fleet_run_cf_path" ]; then
        printf '  drift  config_files.%s %s  on-disk=<file absent>\n' \
          "$fleet_run_cf_file" "$fleet_run_cf_key"
        continue
      fi
      # `getpath(split("."))` reads the dotted managed key; an absent key reads
      # as `null`, a file that does not parse as `<unreadable>` — both reported,
      # neither changed.
      fleet_run_cf_on=$(FLEET_CF_KEY=$fleet_run_cf_key jq -c \
        'getpath(env.FLEET_CF_KEY | split("."))' "$fleet_run_cf_path" 2>/dev/null) ||
        fleet_run_cf_on='<unreadable>'
      [ -n "$fleet_run_cf_on" ] || fleet_run_cf_on='<unreadable>'
      printf '  drift  config_files.%s %s  on-disk=%s\n' \
        "$fleet_run_cf_file" "$fleet_run_cf_key" "$fleet_run_cf_on"
    done
}

fleet_run_plugin_catalog() {
  # The source SHA is the byte identity; the catalog version remains useful
  # for the ordinary release advance but is never sufficient by itself.
  # Claude 2.1.229's `--available` view omits plugins already installed on the
  # host, so use it when it has a SHA and fall back to the installed
  # marketplace manifest when it does not. Older managers that fail the
  # `--available` command still reach the manifest path.
  fleet_run_catalog_id=$1
  fleet_run_catalog_name=${fleet_run_catalog_id%@*}
  fleet_run_catalog_market=${fleet_run_catalog_id##*@}
  fleet_run_catalog_json=$(claude plugin list --available --json 2>/dev/null) ||
    fleet_run_catalog_json=
  fleet_run_catalog_entry=$(printf '%s\n' "$fleet_run_catalog_json" |
    jq -e -c --arg id "$fleet_run_catalog_id" '
      (if type == "array" then .[] else (.available // [])[] end) |
      select((.pluginId // .id) == $id and (.source.sha // "") != "")' \
      2>/dev/null) || fleet_run_catalog_entry=
  [ -n "$fleet_run_catalog_entry" ] && {
    printf '%s\n' "$fleet_run_catalog_entry"
    return 0
  }

  fleet_run_marketplaces=$(claude plugin marketplace list --json 2>/dev/null) ||
    return 75
  fleet_run_catalog_locations=$(printf '%s\n' "$fleet_run_marketplaces" |
    jq -r --arg market "$fleet_run_catalog_market" '
      (if type == "array" then .[] else (.marketplaces // [])[] end) |
      select(.name == $market) | .installLocation // empty' 2>/dev/null) ||
    return 75
  while IFS= read -r fleet_run_catalog_location; do
    [ -n "$fleet_run_catalog_location" ] || continue
    fleet_run_catalog_manifest="$fleet_run_catalog_location/.claude-plugin/marketplace.json"
    [ -f "$fleet_run_catalog_manifest" ] || continue
    fleet_run_catalog_entry=$(jq -e -c \
      --arg name "$fleet_run_catalog_name" --arg market "$fleet_run_catalog_market" \
      '.plugins[]? | select(.name == $name) |
       . + {pluginId: ($name + "@" + $market), marketplaceName: $market}' \
      "$fleet_run_catalog_manifest" 2>/dev/null) || continue
    [ -n "$fleet_run_catalog_entry" ] || continue
    printf '%s\n' "$fleet_run_catalog_entry"
    return 0
  done <<EOF
$fleet_run_catalog_locations
EOF
  return 75
}

fleet_run_installed_plugin() {
  # No installed-plugins file, or the plugin absent from it, means "not
  # installed yet" — an empty identity that must proceed to install, not a
  # hold. Only a file that fails to parse as JSON is genuinely malformed and
  # still holds: we cannot trust its absence of the plugin in that case.
  fleet_run_installed_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  [ -f "$fleet_run_installed_file" ] || { printf '{}\n'; return 0; }
  jq -c --arg id "$1" \
    '(.plugins[$id] // []) | map(select(.scope == "user")) | (.[0] // {})' \
    "$fleet_run_installed_file" 2>/dev/null && return 0
  return 75
}

fleet_run_plugin_enabled() {
  # State verbs reject no-ops; verify one strict user-scoped manager row.
  # A bare id can resolve to more than one marketplace, which is not proof.
  fleet_run_plugin_list=$(claude plugin list --json 2>/dev/null) || return 75
  fleet_run_plugin_state=$(printf '%s\n' "$fleet_run_plugin_list" |
    jq -e -r --arg id "$1" '
      def records:
        if type == "array" then .
        elif type == "object" and (.installed | type == "array") then .installed
        else error("invalid plugin list")
        end;
      [ records[]
        | select(.scope == "user")
        | (.id // .pluginId) as $record_id
        | select(($record_id | type) == "string")
        | select(if ($id | contains("@")) then $record_id == $id
                 else ($record_id | split("@")[0]) == $id
                 end) ] as $matches
      | if ($matches | length) == 1 and ($matches[0].enabled | type == "boolean")
        then ($matches[0].enabled | tostring)
        else empty
        end' 2>/dev/null) || return 75
  printf '%s\n' "$fleet_run_plugin_state"
}

fleet_run_approve_plugin_hooks() {
  # The DSC plugin item is a Claude manager operation, but the hook trust state
  # is Codex-local. Qualified marketplace IDs are the shared seam accepted by
  # codex-plugin-hooks.mjs; an unqualified Claude-only name has no Codex
  # identity to approve and remains on the native manager path.
  case ${1:-} in
    *@*) ;;
    *) return 0 ;;
  esac
  fleet_run_hooks_node=$(fleet_node_path) || {
    printf 'roundhouse: Node.js is required to approve hooks for %s\n' "$1" >&2
    return 75
  }
  "$fleet_run_hooks_node" "$script_dir/codex-plugin-hooks.mjs" approve "$1" \
    >/dev/null || return 75
}

fleet_run_plugin_identity_matches() {
  # fleet_run_plugin_identity_matches DEFS NAME VALUE — compare a resolved
  # marketplace plugin with the user-scoped installed record before ownership
  # can turn an already-applied item into `nothing`. Return 0 for matching
  # bytes/version, 1 for a reinstall, and 75 when the manager cannot prove the
  # identity.
  fleet_run_identity_surface=$(fleet_resolve_surface "$1" plugins "$2") || return 75
  fleet_run_identity_market=$(printf '%s\n' "$3" | jq -r \
    'if type == "object" then (.marketplace // "") else "" end')
  [ -n "$fleet_run_identity_market" ] || fleet_run_identity_market=$(printf '%s\n' \
    "$fleet_run_identity_surface" | jq -r '.marketplace // ""')
  # An unqualified plugin is resolved by the native harness, so there is no
  # marketplace SHA to compare here; the existing manager presence path stays
  # authoritative for that zero-config form.
  [ -n "$fleet_run_identity_market" ] || return 0
  command -v claude >/dev/null 2>&1 || return 75
  fleet_run_identity_id="$2@$fleet_run_identity_market"
  fleet_run_identity_catalog=$(fleet_run_plugin_catalog "$fleet_run_identity_id") || return 75
  fleet_run_identity_installed=$(fleet_run_installed_plugin "$fleet_run_identity_id") || return 75
  fleet_run_identity_sha=$(printf '%s\n' "$fleet_run_identity_catalog" |
    jq -r '.source.sha // empty')
  fleet_run_identity_version=$(printf '%s\n' "$fleet_run_identity_catalog" |
    jq -r '.version // empty')
  fleet_run_identity_installed_sha=$(printf '%s\n' "$fleet_run_identity_installed" |
    jq -r '.gitCommitSha // empty')
  fleet_run_identity_installed_version=$(printf '%s\n' "$fleet_run_identity_installed" |
    jq -r '.version // empty')
  printf '%s\n' "$fleet_run_identity_sha" |
    grep -Eq '^[0-9a-fA-F]{40}$' || return 75
  [ "$fleet_run_identity_sha" = "$fleet_run_identity_installed_sha" ] &&
    [ "$fleet_run_identity_version" = "$fleet_run_identity_installed_version" ]
}

fleet_run_apply_item() {
  # fleet_run_apply_item STORE HOST DEFS ITEM VALUE MANAGERS
  #
  # Exit 0 applied, 70 SATISFIED, 75 held. Presence for manager-installed items
  # is always the manager's own command; only STATE falls back to a config
  # edit, and where a harness has no state verb this design does not invent
  # one.
  #
  # 70 vs 75 is load-bearing and is read by the canary gate, so the split has
  # to mean something a gate can act on:
  #
  #   70 SATISFIED  this design has no state-alignment verb for the item, so
  #                 there is nothing to do — here or on any other host. A no-op
  #                 BECAUSE CORRECT. It journals `satisfied` and counts as
  #                 canary evidence, because gating peers on an `applied`
  #                 record that can never exist deadlocks the item forever and
  #                 buys nothing: the peer would no-op identically.
  #   75 HELD       this host tried and could not, or a gate refused. A no-op
  #                 BECAUSE BLOCKED. It journals `held` and blocks downstream,
  #                 which is the property a genuine apply failure must keep.
  #
  # A miss that is about THIS HOST's capability (no `claude` on the box, no
  # skill root configured, no resolvable source) is 75 and not 70: another host
  # may well be able to apply it, so this host's inability is not evidence
  # about the item.
  fleet_run_split=$(fleet_item_split "$4") || return 70
  fleet_run_category=$(printf '%s\n' "$fleet_run_split" | sed -n 1p)
  fleet_run_name=$(printf '%s\n' "$fleet_run_split" | sed -n 2p)
  # A category the design holds outright refuses here rather than being
  # advised against. The set is currently empty — `hooks` graduated to the
  # per-item trust gate below — and the predicate stays because "held" is a
  # position a category can be put back into in one line.
  ! fleet_category_held "$fleet_run_category" || return 75
  # POLICY AND DEFINITIONS DISPATCH FIRST, ahead of the state guard below.
  # Their values are not states at all — `policy.cadence_hours: 12`,
  # `policy.canary_group: canary`, a definitions map — so subjecting them to an
  # enabled/disabled check holds every policy item on every host forever, and
  # downstream hosts could never obtain the canary evidence a policy change
  # needs. Policy is read, not installed; a definition is a lookup, not a want.
  case $fleet_run_category in
    policy | definitions.*) return 0 ;;
  esac
  # AN UNRECOGNISED STATE IS HELD, checked ONCE for every remaining category
  # rather than per arm. §4's reader's choice makes a bare scalar the state and a map's
  # `state:` key the state, and every arm below then asks `= enabled`, so a
  # typo (`enable`) or a wrong type (`state: false`) fell into whatever the arm
  # does with "not enabled": packages returned SATISFIED — positive canary
  # evidence that malformed desired state had converged fleet-wide — and
  # plugins silently DISABLED the plugin. Neither is a decision anybody made.
  # A value carrying no state at all still reads `enabled` (§4), so
  # config_files and definitions maps are unaffected.
  case $(fleet_run_state_of "$5") in
    enabled | disabled) ;;
    *) return 75 ;;
  esac
  case $fleet_run_category in
    packages)
      # SATISFIED, and asked BEFORE the resolver: a desired state of `disabled`
      # has no removal verb by design (§10.3 makes removal a separate, capped
      # decision driven by applied/), so there is nothing to do here or on any
      # other host — and that is true whether or not this host has a manager
      # that could have provided the package. Asking the resolver first made an
      # unprovidable disabled package journal `held` and block every downstream
      # host forever on evidence nobody could ever produce.
      [ "$(fleet_run_state_of "$5")" = enabled ] || return 70
      # shellcheck disable=SC2086 # the host's package_managers list, in order
      fleet_run_resolved=$(fleet_resolve_package "$3" "$fleet_run_name" $6) || :
      [ "$(printf '%s\n' "$fleet_run_resolved" | jq -r '.resolved')" = true ] ||
        return 75
      # THE VERSION RIDES ALONG. The resolver reports `pin: flag` plus the
      # version and `fleet_package_pinned` then makes the update pass skip the
      # package forever — so dropping the version here meant the store asserted
      # a pin, the installer never received it, and nothing ever revisited it.
      # §5.1.1 calls that exact shape "worse than no pin".
      fleet_install_package \
        "$(printf '%s\n' "$fleet_run_resolved" | jq -r '.manager')" \
        "$(printf '%s\n' "$fleet_run_resolved" | jq -r '.name')" \
        "$(printf '%s\n' "$fleet_run_resolved" | jq -r '.attributes.cask // false')" \
        "$(printf '%s\n' "$fleet_run_resolved" |
          jq -r 'if .pin == "flag" then (.version // "") else "" end')"
      ;;
    plugins)
      fleet_run_surface=$(fleet_resolve_surface "$3" plugins "$fleet_run_name")
      fleet_run_market=$(printf '%s\n' "$5" | jq -r '
        if type == "object" then (.marketplace // "") else "" end')
      [ -n "$fleet_run_market" ] || fleet_run_market=$(printf '%s\n' \
        "$fleet_run_surface" | jq -r '.marketplace // ""')
      # HELD, not satisfied: a host with no `claude` cannot speak to the item
      # at all, and a peer that has one still must not converge on this host's
      # inability. See the exit-code contract above.
      command -v claude >/dev/null 2>&1 || return 75
      # A NULL MARKETPLACE IS THE ZERO-CONFIG CASE, not a missing one.
      # `fleet_resolve_surface`'s own contract is "a null marketplace means
      # 'wherever this harness looks'", and §5's worked example — `plugins:
      # {ponytail: enabled}` with no marketplace anywhere — is the documented
      # default. Refusing it journaled `held` on every host forever, which in
      # turn made `fleet_hook_trust` report every hook that plugin delivers
      # `enabled_but_untrusted` permanently, because the approval it looks for
      # can only arrive through applied/. Unqualified, and the harness resolves
      # its own default.
      fleet_run_id=$fleet_run_name
      [ -z "$fleet_run_market" ] ||
        fleet_run_id="$fleet_run_name@$fleet_run_market"
      if [ -n "$fleet_run_market" ]; then
        fleet_run_catalog=$(fleet_run_plugin_catalog "$fleet_run_id") || return 75
        fleet_run_resolved_sha=$(printf '%s\n' "$fleet_run_catalog" |
          jq -r '.source.sha // empty')
        fleet_run_resolved_version=$(printf '%s\n' "$fleet_run_catalog" |
          jq -r '.version // empty')
        fleet_run_installed=$(fleet_run_installed_plugin "$fleet_run_id") || return 75
        fleet_run_installed_sha=$(printf '%s\n' "$fleet_run_installed" |
          jq -r '.gitCommitSha // empty')
        fleet_run_installed_version=$(printf '%s\n' "$fleet_run_installed" |
          jq -r '.version // empty')
        # A marketplace entry without a resolved SHA cannot prove installed
        # bytes. Hold it instead of silently trusting a version string.
        printf '%s\n' "$fleet_run_resolved_sha" |
          grep -Eq '^[0-9a-fA-F]{40}$' || return 75
        if [ "$fleet_run_resolved_sha" != "$fleet_run_installed_sha" ] ||
          [ "$fleet_run_resolved_version" != "$fleet_run_installed_version" ]; then
          # install is for the absent-record case; an existing user-scoped
          # record with stale bytes goes through the manager's own update
          # verb (the target-native refresh sequence in
          # fleet-agents/SKILL.md), which installing an already-installed
          # plugin can reject or no-op instead of actually refreshing it.
          if [ -n "$fleet_run_installed_sha" ]; then
            claude plugin update "$fleet_run_id" --scope user >/dev/null 2>&1 || return 75
          else
            claude plugin install "$fleet_run_id" --scope user >/dev/null 2>&1 || return 75
          fi
          fleet_run_approve_plugin_hooks "$fleet_run_id" || return 75
          # Trust the manager's exit status for nothing beyond "it ran": a
          # success exit with the catalog identity still unmatched (a no-op
          # install, a race against a catalog refresh) must not journal as
          # applied on stale bytes.
          fleet_run_reverified=$(fleet_run_installed_plugin "$fleet_run_id") || return 75
          [ "$(printf '%s\n' "$fleet_run_reverified" | jq -r '.gitCommitSha // empty')" \
            = "$fleet_run_resolved_sha" ] &&
            [ "$(printf '%s\n' "$fleet_run_reverified" | jq -r '.version // empty')" \
              = "$fleet_run_resolved_version" ] || return 75
        fi
      else
        claude plugin install "$fleet_run_id" --scope user >/dev/null 2>&1 || return 75
        fleet_run_approve_plugin_hooks "$fleet_run_id" || return 75
      fi
      # State-verb status is not convergence: re-read the manager afterward.
      if [ "$(fleet_run_state_of "$5")" = enabled ]; then
        fleet_run_want_enabled=true
        claude plugin enable "$fleet_run_id" --scope user >/dev/null 2>&1 || :
        fleet_run_approve_plugin_hooks "$fleet_run_id" || return 75
      else
        fleet_run_want_enabled=false
        claude plugin disable "$fleet_run_id" --scope user >/dev/null 2>&1 || :
      fi
      fleet_run_actual_enabled=$(fleet_run_plugin_enabled "$fleet_run_id") || return 75
      [ "$fleet_run_actual_enabled" = "$fleet_run_want_enabled" ] || return 75
      ;;
    skills)
      # Presence only: neither harness carries a skill enable/disable verb
      # (verified against claude 2.1.222 / codex-cli 0.146.0), so state is a
      # reviewed config edit and this path never pretends otherwise. A
      # plugin-qualified name rides its plugin and needs nothing here.
      fleet_run_surface=$(fleet_resolve_surface "$3" skills "$fleet_run_name")
      [ "$(printf '%s\n' "$fleet_run_surface" | jq -r '.delivery')" = standalone ] ||
        return 0
      # Both misses are HELD, not satisfied: an unresolvable source is a
      # definitions gap someone has to close, and a missing skill root is this
      # host's own configuration. Neither is evidence the item needs no work.
      fleet_run_source=$(printf '%s\n' "$fleet_run_surface" | jq -r '.source // ""')
      [ -n "$fleet_run_source" ] || return 75
      fleet_run_root=$(jq -r '(.skill_roots // [])[0].path // empty' \
        "$(config_path)" 2>/dev/null) || fleet_run_root=
      [ -n "$fleet_run_root" ] || return 75
      fleet_run_root=$(expand_user_path "$fleet_run_root")
      [ ! -d "$fleet_run_root/$fleet_run_name" ] || return 0
      fleet_validate_fetch_url "$fleet_run_source" || return 75
      mkdir -p "$fleet_run_root"
      git clone --depth 1 -- "$fleet_run_source" \
        "$fleet_run_root/$fleet_run_name" >/dev/null 2>&1
      ;;
    hooks)
      # §5.1.3's trust gate, and it is the ONLY thing standing between a
      # `hooks:` entry and arbitrary code on every session start.
      #
      # A trusted hook is plugin-delivered and rides its plugin's install
      # (approving the plugin approves its hooks), so there is nothing to do
      # here beyond letting the item journal as applied. A standalone hook is
      # never trusted and, deliberately, HAS NO INSTALL PATH IN THIS FUNCTION
      # AT ALL — not a guarded one. That is what makes "never installable
      # ungated, not even transiently" a property of the code's shape rather
      # than of the order of two lines.
      fleet_hook_trust "$1" "$2" "$3" "$fleet_run_name" >/dev/null || return 75
      return 0
      ;;
    config_files)
      # §6: the run REPORTS the drift and changes nothing. A twice-daily job
      # that silently reverts what someone typed four hours ago is the exact
      # surprise this system exists not to deliver. `config_files` declares
      # OWNERSHIP, not values — the only writer of a managed key is §10.8's
      # rollback, restoring what applied/<host>.yaml records this host wrote.
      #
      # The report reads each MANAGED key's current on-disk value and prints it,
      # changing nothing (convergence.md §6). Full value convergence — the store
      # carrying desired VALUES to enforce against — stays deferred per §5, so
      # there is nothing here to compare to and nothing to stomp; this is the
      # surface that lets a human SEE a hand-edit, not one that reverts it.
      fleet_config_drift "$2" "$fleet_run_name" "$5"
      return 0
      ;;
    agents | mcp_servers | projects)
      # The B-3 categories, NAMED rather than caught by a wildcard: no
      # state-alignment verb and no observed state either. They resolve, review
      # and journal; they do not apply.
      return 70
      ;;
    *)
      # AN UNKNOWN CATEGORY IS HELD, never satisfied. §7.7 holds the whole store
      # on a top-level key that is neither a category nor a host fact, and the
      # run never reaches this function for one — but `fleet-apply ITEM` is
      # invoked directly and does. Returning 70 here would journal `satisfied`
      # for state this build cannot interpret, which is positive canary evidence
      # that peers act on. The closed set (§4/fleet_categories) is the point:
      # anything outside it is exactly what nobody has decided about yet.
      return 75
      ;;
  esac
}

# --- §5/§10.4 the alert surface -----------------------------------------------

fleet_run_alerts() {
  # fleet_run_alerts STORE HOST FOLD LAYERDIR — every detection predicate lane
  # A landed, wired to the one writer. Each of these is a condition that would
  # otherwise converge something this reader does not understand.
  #
  # AND EACH ONE IS A HOLD, not only an alert. §7.7 rows 3 and 4 specify a hold
  # and these predicates' own comments claim one ("the run holds EVERYTHING and
  # alerts naming it. Never silent"), but nothing read their output — every call
  # was suffixed `|| :` and the run converged anyway. So this function now
  # PRINTS the holds it detected and the caller acts on them: `!hold <reason>`
  # for the two §7.7 store-wide rows, `<item> <reason>` for a collision, which
  # is a refusal of that config file's widening and not of the store.
  fleet_run_unknown=$(fleet_unknown_categories "$3" | tr '\n' ' ')
  [ -z "${fleet_run_unknown% }" ] || {
    fleet_alert_write "$1" "$2" unknown-category unknown-category \
      "top-level keys that are neither a category nor a host fact: ${fleet_run_unknown% }" ||
      :
    printf '!hold %s\n' \
      "top-level keys that are neither a category nor a host fact: ${fleet_run_unknown% }"
  }
  # The real tree, not the exported layers: an unrecognised directory is one
  # nothing folded, so a dir-filtered export can never see it.
  fleet_run_unknown=$(fleet_unknown_layer_dirs "$1" | tr '\n' ' ')
  [ -z "${fleet_run_unknown% }" ] || {
    fleet_alert_write "$1" "$2" unknown-store-dir unknown-store-dir \
      "unrecognised store directories: ${fleet_run_unknown% }" || :
    printf '!hold %s\n' \
      "unrecognised store directories: ${fleet_run_unknown% }"
  }
  fleet_config_key_collisions "$3" |
    while IFS=$(printf '\t') read -r fleet_run_file fleet_run_key; do
      [ -n "$fleet_run_file" ] || continue
      fleet_alert_write "$1" "$2" config-key-collision config-key-collision \
        "$fleet_run_file: managed key $fleet_run_key collides with a never namespace" \
        "config_files.$fleet_run_file" || :
      printf 'config_files.%s managed key %s collides with a never namespace\n' \
        "$fleet_run_file" "$fleet_run_key"
    done
  fleet_config_coowned "$3" |
    while IFS=$(printf '\t') read -r fleet_run_file fleet_run_key; do
      [ -n "$fleet_run_file" ] || continue
      fleet_alert_write "$1" "$2" chezmoi-coownership chezmoi-coownership \
        "$fleet_run_file: managed key $fleet_run_key is also written by chezmoi" \
        "config_files.$fleet_run_file" || :
    done
}

# --- §6 step 6 and §6.1(b): publication and the nudge -------------------------

fleet_run_publish() {
  # fleet_run_publish STORE HOST SESSION INTENT ITEMS — describe, move the
  # bookmark, push, and land @ on the published commit.
  #
  # NEVER a bare `jj new -m ''` here. `jj git push` leaves an empty UNDESCRIBED
  # working-copy commit of its own; naming the target is what makes @ a child
  # of the bookmark instead of a child of that leftover, and it is the line
  # that keeps §8.1's invariant true between runs.
  if [ "$(jj -R "$1" log -r @ --no-graph -T 'if(empty,"y","n")')" = n ]; then
    jj -R "$1" describe -r @ -m "converge on $2

$(fleet_vcs_trailers "$2" "$3" "$4" "$5")" >/dev/null
    jj -R "$1" bookmark set main \
      -r "$(jj -R "$1" log -r @ --no-graph -T 'commit_id')" >/dev/null
  fi
  fleet_run_target=$(fleet_vcs_heads_local "$1" | head -1)
  [ -n "$fleet_run_target" ] || return 65
  fleet_vcs_publish "$1" "$fleet_run_target"
}

fleet_run_nudge() {
  # fleet_run_nudge STORE HOST LAYERDIR INTERVAL — §6.1(b). Outbound only, no
  # listener, no daemon, no inbound port. It carries NO DATA: the nudge says
  # "go look", and the peer then runs its ordinary fast path with full gates,
  # so a nudge from a compromised host can cause exactly one thing — an early
  # fetch of content that is signature-gated anyway.
  #
  # GENUINELY DELETABLE, and that is the test an accelerator has to pass:
  # remove this loop and the system still converges at poll speed. Nothing
  # depends on it, and a policy `push_nudge: false` or a missing peer degrades
  # to the poll floor without an error, a retry queue or a record.
  #
  # The ten-second bound is on the REMOTE COMMAND, not just the connect:
  # ConnectTimeout alone leaves a peer that connects and then hangs holding the
  # pushing host's wait indefinitely. It is a watchdog rather than `timeout(1)`
  # because ssh_run is a shell function — and because macOS ships no `timeout`,
  # so depending on one would silently delete the accelerator on half the
  # fleet.
  fleet_run_memo=$(fleet_run_state_dir)/nudge-unreachable
  # Remembered for ONE interval only, so a peer that comes back is retried.
  fleet_run_skip=$fleet_run_memo
  if [ ! -f "$fleet_run_memo" ] ||
    [ "$(($(date +%s) - $(fleet_run_mtime "$fleet_run_memo")))" -gt "$4" ]; then
    fleet_run_skip=/dev/null
  fi
  mkdir -p "$(dirname "$fleet_run_memo")"
  : >"$fleet_run_memo.next"
  for fleet_run_peer in $(fleet_ssh_render_hosts "$3"); do
    [ "$fleet_run_peer" != "$2" ] || continue
    ! grep -Fqx "$fleet_run_peer" "$fleet_run_skip" 2>/dev/null || continue
    fleet_run_nudge_peer "$fleet_run_peer" ||
      printf '%s\n' "$fleet_run_peer" >>"$fleet_run_memo.next"
  done
  mv -f "$fleet_run_memo.next" "$fleet_run_memo"
}

fleet_run_nudge_peer() {
  # One bounded, best-effort nudge. It CARRIES NO DATA: "go look", nothing
  # more. The peer then runs its ordinary fast path — fetch from the hub, full
  # review gates, canary, the lot — so a nudge from a compromised host can
  # cause exactly one thing: an early fetch of content that is signature-gated
  # anyway.
  ssh_run "rh-$1" 'roundhouse fleet-run --fast' >/dev/null 2>&1 &
  fleet_run_nudge_pid=$!
  (
    sleep 10
    kill -TERM "$fleet_run_nudge_pid" 2>/dev/null || :
  ) >/dev/null 2>&1 &
  fleet_run_nudge_watch=$!
  fleet_run_nudge_status=0
  wait "$fleet_run_nudge_pid" || fleet_run_nudge_status=$?
  kill -TERM "$fleet_run_nudge_watch" 2>/dev/null || :
  wait "$fleet_run_nudge_watch" 2>/dev/null || :
  [ "$fleet_run_nudge_status" -eq 0 ]
}

fleet_run_mtime() {
  # stat -c first: on Linux `stat -f` is filesystem stat and dumps a report to
  # stdout, so the -f-first form leaks that into the value; on macOS `stat -c`
  # is an illegal option and cleanly falls through to `stat -f`.
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'
}

# --- the commands -------------------------------------------------------------

fleet_run_command() (
  # `roundhouse fleet-run [--fast|--full]` — §6.1's two cadences. Fast is the
  # propagation path; full is maintenance. Splitting them is what lets the
  # propagation interval be short without running discovery, doctoring and
  # upstream fetches 72 times a day.
  fleet_run_env
  require_jq
  require_yq
  run_mode=fast
  while [ $# -gt 0 ]; do
    case $1 in
      --fast) run_mode=fast ;;
      --full) run_mode=full ;;
      *)
        printf 'roundhouse: unknown fleet-run option: %s\n' "$1" >&2
        exit 64
        ;;
    esac
    shift
  done

  run_store=$(fleet_store_path)
  run_host=$(fleet_host_name)
  fleet_vcs_store_ready "$run_store" || exit $?

  # §10.6: one run per host. The stale threshold keys on the FULL cadence and
  # never on the fast interval — a 40-minute threshold would declare a live
  # run's lock stale on the very next fast run.
  run_lock=$(fleet_lock_path)
  if ! fleet_lock_acquire "$run_lock"; then
    run_age=$(fleet_lock_age_seconds "$run_lock" || printf '')
    run_stale=$(fleet_run_stale_after "$run_store" "$run_host")
    # AN UNKNOWN AGE IS STALE, NOT FRESH. `fleet_lock_age_seconds` answers empty
    # when meta.json is missing or unparsable, and reading that as "under the
    # threshold" wedged every future run on this host silently, forever, at
    # exit 0. It is reachable through the recovery fleet-update/SKILL.md
    # prescribes: `fleet-unlock` removes meta.json BEFORE an rmdir that can
    # fail. A lock directory with no evidence of a live runner is exactly the
    # case the stale branch exists for.
    if [ -z "$run_age" ] || [ "$run_age" -gt "$run_stale" ]; then
      printf 'roundhouse: a run lock at %s is %s old; confirm no live runner on this host, then remove it\n' \
        "$run_lock" "${run_age:+${run_age}s}${run_age:-of unknown age (no readable meta.json)}" >&2
      exit 75
    fi
    # …and the pid the lock has always recorded, finally read: a crashed run is
    # otherwise indistinguishable from a slow one for two full cadences.
    if fleet_lock_holder_gone "$run_lock"; then
      printf 'roundhouse: the run lock at %s names a pid on this host that no longer exists; release it with `roundhouse fleet-unlock`\n' \
        "$run_lock" >&2
      exit 75
    fi
    printf 'roundhouse: another run holds %s; exiting without acting\n' \
      "$run_lock" >&2
    exit 0
  fi
  trap 'rm -rf "$run_lock"' EXIT HUP INT TERM
  run_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-fleet-run.XXXXXX")
  trap 'rm -rf "$run_lock" "$run_tmp"' EXIT HUP INT TERM

  # §8.6: the abort button for a bad local apply, captured deliberately
  # WITHOUT --ignore-working-copy (that flag suppresses the colocated
  # auto-import, so restoring to the newest operation exports an empty view and
  # deletes the bookmarks outright).
  run_op=$(fleet_vcs_op_id "$run_store")
  mkdir -p "$(fleet_run_state_dir)"
  printf '%s\n' "$run_op" >"$(fleet_run_state_dir)/starting-operation"

  # §6.1(a). One HTTPS round trip, one string compare, exit — no snapshot, no
  # object transfer, no commit, no push. The full fetch runs only when the ids
  # differ.
  if [ "$run_mode" = fast ] && fleet_run_poll_floor "$run_store"; then
    printf 'roundhouse: nothing to pull, nothing to push, clean working copy — one ls-remote round trip, no fetch (§6.1a)\n'
    printf 'roundhouse: starting operation %s\n' "$run_op"
    exit 0
  fi

  # Captured BEFORE the fetch: what arrives is what §7.7 has to gate, and after
  # the fetch there is no other way to tell new from known.
  run_pre_origin=$(fleet_vcs_head_origin "$run_store")
  run_fetched=true
  fleet_vcs_fetch "$run_store" origin 2>/dev/null || run_fetched=false
  [ "$run_fetched" = true ] ||
    printf 'roundhouse: could not reach the store remote; converging from last known (§10.3, never prune)\n' >&2

  # §7.11.2: a re-root and the §7.12.3 rollback attack are byte-for-byte
  # indistinguishable EXCEPT BY THE ARCHIVE, so the archive protocol runs
  # before anything adopts the fetched head. Its failure branch IS the rollback
  # protection: an attacker who re-roots without publishing an archive
  # containing this host's reviewed-ref cannot get it to adopt.
  run_fetched_head=$(fleet_vcs_head_origin "$run_store")
  if [ -n "$run_fetched_head" ]; then
    if run_catchup=$(fleet_trust_catch_up "$run_store" "$run_fetched_head") &&
      [ -z "$run_catchup" ]; then
      :
    else
      fleet_alert_write "$run_store" "$run_host" rollback rollback \
        "refusing the fetched head: $(printf '%s' "${run_catchup:-reviewed-ref is not an ancestor of the fetched head}" | head -c 300)" ||
        :
      printf 'roundhouse: %s; holding everything and alerting (§7.11.2/§7.12.3)\n' \
        "${run_catchup:-the fetched head is not a descendant of reviewed-ref}" >&2
      exit 65
    fi
  fi

  # §8.1's invariant, repaired before anything reads the graph: the bootstrap
  # leaves an empty undescribed commit under @ that would otherwise become a
  # permanent ancestor of main and refuse every future push.
  fleet_run_prune_empty "$run_store"

  # --- step 0: is this the second half of an earlier reconcile? (§8.1) ---
  run_state=clean
  run_workbench=$(fleet_vcs_resolution_workbench "$run_store")
  if [ -n "$run_workbench" ]; then
    # A human may have resolved it since; if not, the fold refuses and the
    # items stay held. Readable from repo state alone, because $M, $WC and
    # $LOCAL do not survive between runs.
    run_state=conflicted
    run_reference=$run_workbench
    if run_folded=$(fleet_vcs_fold_resolution "$run_store" 2>/dev/null); then
      run_state=clean
      run_reference=$run_folded
    fi
  else
    # §6 step 4 and its §8.2 precedence: the gate runs only off the conflicted
    # path, and a failure refuses to PROMOTE rather than refusing to converge.
    run_broken=$(fleet_run_promote_gate "$run_store") || run_broken=${run_broken:-x}
    if [ -n "${run_broken:-}" ]; then
      fleet_alert_write "$run_store" "$run_host" layer-parse layer-parse \
        "refusing to promote; converging from the last good main: $(printf '%s' "$run_broken" | head -c 300)" ||
        :
      run_reference=$(fleet_vcs_head_origin "$run_store")
      [ -n "$run_reference" ] || run_reference=$(fleet_vcs_heads_local "$run_store" | head -1)
      [ "$(fleet_vcs_heads_local "$run_store" | grep -c .)" -le 1 ] || {
        printf 'roundhouse: a layer file does not parse and main is diverged; holding everything\n' >&2
        exit 65
      }
    else
      run_out=$(fleet_vcs_reconcile "$run_store" "$run_host" "scheduled/agent" \
        "$run_mode convergence") || exit $?
      run_state=${run_out%% *}
      run_reference=${run_out#* }
    fi
  fi

  # --- §8.3: the hold set, from per-head folds over real commits ---
  # THE HEADS ARE THE BOOKMARK HEADS, recomputed — never parents($M), which is
  # the heads PLUS the operator's in-flight edit.
  if [ "$run_state" = conflicted ]; then
    run_heads=$( (fleet_vcs_heads_local "$run_store"
      fleet_vcs_head_origin "$run_store") | grep . | LC_ALL=C sort -u)
  else
    run_heads=$run_reference
  fi
  run_head_count=$(printf '%s\n' "$run_heads" | grep -c .)
  run_index=0
  : >"$run_tmp/values"
  for run_head in $run_heads; do
    run_index=$((run_index + 1))
    fleet_run_export "$run_store" "$run_head" "$run_tmp/head-$run_index"
    fleet_run_item_digests "$(fleet_fold "$run_tmp/head-$run_index" "$run_host")" \
      "$run_tmp/head-$run_index" >>"$run_tmp/values"
  done
  # The reviewed tree R. On the clean path that is the merge, and there is one
  # head. On the conflicted path it is the first head — legitimate because
  # §8.3 only converges items whose value is IDENTICAL at every head, so any
  # head answers for them, and the rest are held.
  run_layers=$run_tmp/head-1
  run_fold=$(fleet_fold "$run_layers" "$run_host")
  run_defs=$(fleet_definitions_load "$run_layers")
  fleet_vcs_enrolled_hosts "$run_store" "$run_reference" >"$run_tmp/hosts"
  grep -Fqx "$run_host" "$run_tmp/hosts" || printf '%s\n' "$run_host" >>"$run_tmp/hosts"

  fleet_vcs_hold_set "$run_head_count" <"$run_tmp/values" >"$run_tmp/verdicts"

  # §7.7: an unverifiable commit holds exactly the items resolved from the
  # files it touched. Everything else converges.
  # What ARRIVED, which is what §7.7 has to gate: the pre-fetch origin head is
  # the only stateless way to tell new from known, and on a never-fetched store
  # the whole (tiny) history is new by definition.
  run_range="::$run_reference"
  [ -z "$run_pre_origin" ] || run_range="$run_pre_origin..$run_reference"
  # Rule 4's roster — this host's CURRENT reviewed head, which is what makes
  # removals bite backward. Rules 3 and 4 are the two-sided check: 3 alone lets
  # a removed host keep pushing forever, 4 alone would reject a legitimate
  # newcomer except that the ancestry property means it cannot.
  fleet_trust_roster_at_head "$run_store" "$run_reference" "$run_tmp/reviewed-roster"
  fleet_run_signature_holds "$run_store" "$run_range" "$run_tmp/hosts" \
    "$run_layers" "$run_host" "$run_tmp/reviewed-roster" "$run_tmp/rosters" \
    >"$run_tmp/sigholds" 2>/dev/null || :

  # `!hold` is the marker for a refusal whose scope is the WHOLE run rather
  # than an item: a rejected `trust/signers.yaml` commit (whose consequences
  # are otherwise scoped to layer files it did not touch) and an unusable
  # revocation list. Both are conditions under which nothing in the range can
  # be trusted, so they take the same branch materialization drift takes.
  run_full_hold=$(awk '$1 == "!hold" { $1 = ""; sub(/^ /, ""); print; exit }' \
    "$run_tmp/sigholds")
  if [ -n "$run_full_hold" ]; then
    fleet_alert_write "$run_store" "$run_host" integrity integrity-store-wide \
      "$(printf '%s' "$run_full_hold" | head -c 300)" || :
    printf 'roundhouse: %s; holding everything (§7.7/§7.12.5)\n' "$run_full_hold" >&2
    exit 65
  fi

  # §7.9: install the roster the ratchet derived, and compare what is already
  # installed against it. The compare is nearly free and fails in a DIFFERENT
  # direction from ownership — it catches an attacker who does get root. A
  # mismatch is a loud alert and a full hold, never a repair.
  #
  # SKIPPED ON THE CONFLICTED PATH, and not as tidiness: `run_reference` is the
  # conflicted merge there, so `trust/signers.yaml` read at it comes back with
  # snapshot markers, parses to nothing, and renders as "nobody is trusted" —
  # which would read as total roster drift and hold the whole store on the one
  # path §8.2b exists to resolve. There is no single reviewed ref during a
  # divergence, so there is nothing to compare against yet.
  if [ "$run_state" = clean ]; then
    run_drift=$(fleet_trust_materialization_drift "$run_store")
    # A REFUSED MATERIALIZATION IS A HOLD, not a swallowed `|| :`. §7.12.3's
    # generation-rollback and non-descendant-of-reviewed-ref refusals (and a
    # privileged helper that refuses) all come back non-zero here, and every
    # sibling hold in this function exits 65 and alerts — this one silently
    # converged on. Take the same branch the drift compare below takes.
    if ! fleet_trust_materialize "$run_store" "$run_reference"; then
      run_reference_short=${run_reference:0:12}
      fleet_alert_write "$run_store" "$run_host" materialization \
        materialization-refused \
        "materialization refused for commit[$run_reference_short] (abbreviated commit id): a roster generation rollback or a non-descendant head (§7.12.3); holding everything" ||
        :
      printf 'roundhouse: materialization refused (§7.12.3); holding everything (§7.9)\n' >&2
      exit 65
    fi
    fleet_trust_privileged >/dev/null 2>&1 ||
      printf 'roundhouse: no privileged materialization lane; the roster is same-user writable, which buys no persistence protection past revocation (§7.9)\n' >&2
    [ -z "$run_drift" ] || {
      fleet_alert_write "$run_store" "$run_host" materialization materialization \
        "$(printf '%s' "$run_drift" | head -c 300)" || :
      printf 'roundhouse: %s; holding everything (§7.9)\n' "$run_drift" >&2
      exit 65
    }
  fi

  fleet_run_alerts "$run_store" "$run_host" "$run_fold" "$run_layers" \
    >"$run_tmp/detections"
  run_full_hold=$(awk '$1 == "!hold" { $1 = ""; sub(/^ /, ""); print; exit }' \
    "$run_tmp/detections")
  if [ -n "$run_full_hold" ]; then
    printf 'roundhouse: %s; holding everything (§4/§7.7)\n' "$run_full_hold" >&2
    exit 65
  fi
  # The item-scoped detections join the same hold file the signature gate
  # writes, so the apply loop below reads one surface and not two.
  grep -v '^!hold ' "$run_tmp/detections" >>"$run_tmp/sigholds" || :
  fleet_run_definition_hold_consumers "$run_tmp/sigholds" \
    "$run_tmp/verdicts" "$run_tmp/values" "$run_tmp" \
    || exit 65
  fleet_run_hold_items_into_verdicts "$run_tmp/sigholds" \
    "$run_tmp/verdicts" "$run_tmp"

  # §5's rendered aliases, and the include line that makes them reachable. The
  # destination directory is this run's to create: the render is pure and
  # writes through safe_output, which refuses a destination whose directory
  # does not exist.
  mkdir -p "$HOME/.ssh/config.d"
  chmod 700 "$HOME/.ssh" 2>/dev/null || :
  if fleet_ssh_config_render "$run_layers" "$HOME/.ssh/config.d/roundhouse" \
    2>/dev/null; then
    fleet_run_ssh_include || :
  else
    fleet_alert_write "$run_store" "$run_host" ssh-render ssh-render \
      'a host field failed validation; no ssh config was rendered (§5)' || :
  fi

  # --- §8.2b: the run's own agent resolves, in the same run ---
  run_resolved_items=
  if [ "$run_state" = conflicted ]; then
    fleet_run_resolve_conflict "$run_store" "$run_host" "$run_tmp" \
      "$run_fold" "$run_heads" || :
    if [ -f "$run_tmp/resolved" ]; then
      run_resolved_items=$(tr '\n' ' ' <"$run_tmp/resolved")
      run_folded=$(fleet_vcs_fold_resolution "$run_store" \
        "resolve $run_resolved_items on $run_host

$(fleet_vcs_trailers "$run_host" scheduled/agent \
          'agent resolution, §8.2b' "$run_resolved_items")") && {
        run_state=clean
        run_reference=$run_folded
        # Only now is the resolution real; peers may not read `outcome:
        # resolved` for an item whose fold refused.
        fleet_run_resolution_journal "$run_store" "$run_host" "$run_tmp"
      } || :
    fi
  fi

  # --- §6 step 6: review -> verdict -> apply -> applied/ -> journal ---
  run_canary_group=$(fleet_policy_get "$run_fold" canary_group)
  run_wait=$(fleet_policy_get "$run_fold" canary_wait_hours)
  fleet_run_canary_hosts "$run_layers" "$run_canary_group" "$run_tmp/hosts" \
    >"$run_tmp/canaries"
  run_self_canary=false
  ! grep -Fqx "$run_host" "$run_tmp/canaries" || run_self_canary=true
  run_now=$(fleet_now)
  run_applied_items=

  # §10.3's removal set, capped BEFORE any removal applies. Over the cap the
  # ENTIRE set holds — neither term catches a one-line deletion, and nothing
  # should: that is a legitimate edit, and its defence is apply-time review
  # naming the item.
  : >"$run_tmp/removals"
  fleet_record_read "$(fleet_applied_path "$run_store" "$run_host")" '{}' |
    jq -r '(.items // {}) | keys[]' |
    while IFS= read -r run_owned; do
      [ -n "$run_owned" ] || continue
      # An item held by §8.3 is not gone; the heads merely disagree about
      # whether it exists. Pruning it would uninstall software on the strength
      # of an open conflict.
      ! grep -Fqx "held $run_owned" "$run_tmp/verdicts" || continue
      # Presence is asked of the ITEM UNIVERSE this run computed, not of the
      # fold alone: `definitions.*` items are real items with digests and
      # verdicts (§5.1) and they are deliberately outside the fold, so asking
      # the fold would read every one of them as "gone from the layers" and
      # prune it with a false `outcome: reverted` record.
      ! awk -v i="$run_owned" '$1 == i { found = 1 } END { exit(found ? 0 : 1) }' \
        "$run_tmp/values" || continue
      printf '%s\n' "$run_owned"
    done >"$run_tmp/removals"
  run_removals=$(grep -c . <"$run_tmp/removals" || true)
  run_removals_ok=true
  fleet_removal_cap "$run_removals" "$(fleet_applied_count "$run_store" "$run_host")" \
    "$(fleet_policy_get "$run_fold" max_removals_per_run)" \
    "$(fleet_policy_get "$run_fold" max_removal_fraction)" >/dev/null ||
    run_removals_ok=false
  if [ "$run_removals_ok" != true ]; then
    fleet_alert_write "$run_store" "$run_host" removal-cap removal-cap \
      "$run_removals removals exceed the cap; the entire removal set is held" || :
    : >"$run_tmp/removals"
  fi
  while IFS= read -r run_owned; do
    [ -n "$run_owned" ] || continue
    printf '  prune %s (in applied/, gone from the layers)\n' "$run_owned"
    fleet_applied_forget "$run_store" "$run_host" "$run_owned"
    fleet_journal_append "$run_store" "$run_host" \
      "$(jq -cn --arg item "$run_owned" --arg at "$run_now" \
        '{item:$item,digest:"absent",outcome:"reverted",at:$at}')" || :
  done <"$run_tmp/removals"

  # THE VERDICT LIST IS READ ON FD 9, not on stdin. This loop's body runs
  # `brew`, `claude` and `git clone`; measured, one greedy child consumed the
  # rest of the list and silently cut a four-item run to one.
  while read -r run_verdict run_item run_digest <&9; do
    [ -n "${run_item:-}" ] || continue
    if [ "$run_verdict" = held ]; then
      fleet_run_runtime_hold "$run_item" 'verdict held' "$run_tmp/sigholds" ||
        exit 65
      fleet_journal_append "$run_store" "$run_host" \
        "$(jq -cn --arg item "$run_item" --arg at "$run_now" \
          '{item:$item,digest:"held",outcome:"held",at:$at}')" || :
      continue
    fi
    run_hold=$(awk -v item="$run_item" '$1 == item { $1 = ""; print; exit }' \
      "$run_tmp/sigholds")
    if [ -n "$run_hold" ]; then
      printf '  hold  %s —%s\n' "$run_item" "$run_hold"
      fleet_alert_write "$run_store" "$run_host" integrity \
        "integrity-$(printf '%s' "$run_item" | tr './' '--')" \
        "$run_item held:$run_hold" "$run_item" || :
      fleet_journal_append "$run_store" "$run_host" \
        "$(jq -cn --arg item "$run_item" --arg d "$run_digest" --arg at "$run_now" \
          '{item:$item,digest:$d,outcome:"held",at:$at}')" || :
      continue
    fi
    # §7.6's supervised half: a human `fleet-review ITEM hold` refuses THIS
    # value, and it outranks every gate below it — there is no point waiting for
    # canary evidence about a digest someone has already looked at and refused.
    # Host-local, like every verdict: the refusal governs this machine and is
    # never a vote cast on anyone else's behalf.
    if fleet_run_verdict_held "$run_item" "$run_digest"; then
      printf '  hold  %s — held by review at %s\n' "$run_item" "$run_digest"
      fleet_run_runtime_hold "$run_item" 'held by review' "$run_tmp/sigholds" ||
        exit 65
      fleet_journal_append "$run_store" "$run_host" \
        "$(jq -cn --arg item "$run_item" --arg d "$run_digest" --arg at "$run_now" \
          '{item:$item,digest:$d,outcome:"held",at:$at}')" || :
      continue
    fi

    run_split=$(fleet_item_split "$run_item") || continue
    run_category=$(printf '%s\n' "$run_split" | sed -n 1p)
    run_value=$(fleet_item_value "$run_fold" "$run_item")

    # §10.3's ownership table, as one function with one answer per row.
    run_in_applied=no
    [ "$(fleet_applied_digest "$run_store" "$run_host" "$run_item")" = "" ] ||
      run_in_applied=yes
    run_match=no
    [ "$(fleet_applied_digest "$run_store" "$run_host" "$run_item")" != "$run_digest" ] ||
      run_match=yes
    if [ "$run_category" = plugins ] && [ "$run_in_applied" = yes ] &&
      [ "$run_match" = yes ]; then
      run_plugin_identity_status=0
      fleet_run_plugin_identity_matches "$run_defs" "${run_item#plugins.}" \
        "$run_value" || run_plugin_identity_status=$?
      case $run_plugin_identity_status in
        1) run_match=no ;;
        75)
          printf '  hold  %s — installed marketplace identity unavailable\n' "$run_item"
          fleet_run_runtime_hold "$run_item" \
            'installed marketplace identity unavailable' "$run_tmp/sigholds" ||
            exit 65
          fleet_journal_append "$run_store" "$run_host" \
            "$(jq -cn --arg item "$run_item" --arg d "$run_digest" --arg at "$run_now" \
              '{item:$item,digest:$d,outcome:"held",at:$at}')" || :
          continue
          ;;
      esac
    fi
    # ponytail: on-host observation exists for no category yet (declared
    # boundary B-3), so row 2 reads as row 1 — adopt, which reviews before it
    # applies. Wrong in the safe direction; the dangerous row (not ours, never
    # touch it) is driven by applied/ and is exact.
    run_action=$(fleet_ownership_action yes "$run_in_applied" no "$run_match")
    [ "$run_action" != nothing ] || continue

    # §10.8: a revert restores a value this host already passed before, so a
    # verdict keyed on (item, digest) alone matches a stale pass. Re-review is
    # the point, and it must be visible.
    run_reason="$run_action at $run_digest"
    if fleet_run_is_revert "$run_store" "$run_host" "$run_item" "$run_digest"; then
      run_reason="revert re-reviewed: this host applied $run_digest before and withdrew it"
      printf '  revert %s — re-reviewing, not matching the stored verdict\n' "$run_item"
    fi

    # §10.1's gate, with the liveness term. Canary hosts are not gated by
    # themselves.
    if [ "$run_self_canary" != true ] && [ -s "$run_tmp/canaries" ]; then
      # shellcheck disable=SC2046 # the canary set, one host per argument
      fleet_canary_gate "$run_store" "$run_item" "$run_digest" "$run_wait" \
        "$run_now" $(cat "$run_tmp/canaries") || {
        printf '  wait  %s — no canary evidence at %s yet\n' "$run_item" "$run_digest"
        fleet_run_runtime_hold "$run_item" 'canary evidence unavailable' \
          "$run_tmp/sigholds" || exit 65
        fleet_journal_append "$run_store" "$run_host" \
          "$(jq -cn --arg item "$run_item" --arg d "$run_digest" --arg at "$run_now" \
            '{item:$item,digest:$d,outcome:"held",at:$at}')" || :
        continue
      }
    fi

    # §6 step 5: the review is provenance, not a file diff — and it prints
    # BEFORE the apply, so a crash mid-apply still leaves the operator the
    # value and digest that were about to be written.
    printf '  review %s  %s  %s\n' "$run_item" "${run_value:-<none>}" "$run_digest"
    fleet_run_verdict_write "$run_item" "$run_digest" "$run_reason"
    run_status=0
    fleet_run_apply_item "$run_store" "$run_host" "$run_defs" "$run_item" \
      "$run_value" "$(printf '%s\n' "$run_fold" |
        jq -r '(.package_managers // []) | join(" ")')" || run_status=$?
    case $run_status in
      0)
        # An unwritable applied/<h>.yaml is loud and narrow, never fatal: the
        # record refuses rather than truncating (fleet_record_write), and a
        # bare call under `set -e` would abort the run mid-apply instead of
        # narrowing what is applicable.
        fleet_applied_record "$run_store" "$run_host" "$run_item" "$run_digest" \
          "$run_now" || {
          printf 'roundhouse: could not record %s in applied/%s.yaml; the item is applied but unowned\n' \
            "$run_item" "$run_host" >&2
          fleet_alert_write "$run_store" "$run_host" record-write \
            "record-write-$(printf '%s' "$run_item" | tr './' '--')" \
            "applied/$run_host.yaml could not be updated for $run_item" \
            "$run_item" || :
        }
        fleet_journal_append "$run_store" "$run_host" \
          "$(jq -cn --arg item "$run_item" --arg d "$run_digest" --arg at "$run_now" \
            '{item:$item,digest:$d,outcome:"applied",at:$at}')" || :
        run_applied_items="$run_applied_items$run_item "
        printf '  applied %s\n' "$run_item"
        ;;
      70)
        # No-op BECAUSE CORRECT: the item resolved and reviewed, and this
        # design has no state-alignment verb to run for it (B-3). A DISTINCT
        # outcome from `held` so an audit can tell the two apart, and the one
        # non-`applied` outcome the canary gate accepts as evidence —
        # otherwise every such item deadlocks the whole fleet behind a record
        # that can never be written. applied/ stays untouched: nothing was
        # installed, so nothing is owned, and §10.3's removal legality is
        # unchanged.
        fleet_journal_append "$run_store" "$run_host" \
          "$(jq -cn --arg item "$run_item" --arg d "$run_digest" --arg at "$run_now" \
            '{item:$item,digest:$d,outcome:"satisfied",at:$at}')" || :
        printf '  satisfied %s (no state-alignment verb for this category)\n' \
          "$run_item"
        ;;
      *)
        fleet_run_runtime_hold "$run_item" "apply status $run_status" \
          "$run_tmp/sigholds" || exit 65
        [ "$run_status" -ne 75 ] || [ "$run_category" != packages ] ||
          fleet_alert_write "$run_store" "$run_host" package-hold \
            "package-hold-$(printf '%s' "$run_item" | tr './' '--')" \
            "no package manager on this host can provide $run_item" "$run_item" ||
          :
        # §5.1.3's one carried-over behaviour: an enabled hook this host does
        # not trust is REPORTED by name, not silently skipped. The gate is
        # re-read for its reason rather than the apply path returning one,
        # because an exit status that carries prose is an exit status nobody
        # can test.
        [ "$run_status" -ne 75 ] || [ "$run_category" != hooks ] ||
          fleet_alert_write "$run_store" "$run_host" enabled-but-untrusted \
            "enabled-but-untrusted-$(printf '%s' "$run_item" | tr './' '--')" \
            "$(fleet_hook_trust "$run_store" "$run_host" "$run_defs" \
              "${run_item#hooks.}" || :)" "$run_item" ||
          :
        fleet_journal_append "$run_store" "$run_host" \
          "$(jq -cn --arg item "$run_item" --arg d "$run_digest" --arg at "$run_now" \
            '{item:$item,digest:$d,outcome:"held",at:$at}')" || :
        printf '  held    %s (this host could not apply it, or a gate refused)\n' \
          "$run_item"
        ;;
    esac
  done 9<"$run_tmp/verdicts"

  # --- the full cadence's maintenance half ---
  if [ "$run_mode" = full ]; then
    fleet_run_full_pass "$run_store" "$run_host" "$run_fold" "$run_defs" \
      "$run_layers" "$run_tmp"
  fi

  # §10.1 condition 3's heartbeat: a canary that applies an item, is wrecked by
  # it and stops journaling otherwise satisfies conditions 1 and 2. One record
  # per completed run is what makes silence visible.
  fleet_journal_append "$run_store" "$run_host" \
    "$(jq -cn --arg at "$(fleet_now)" '{outcome:"alive",at:$at}')" || :

  # §8.4: while a conflict is open the host is locally converging and
  # PUBLICATION-SILENT — the same state it is in when offline.
  if [ "$run_state" = conflicted ]; then
    printf 'roundhouse: converged locally; publication held while the conflict is open (§8.4)\n'
    printf 'roundhouse: starting operation %s (not pushed)\n' "$run_op"
    exit 0
  fi
  if [ "$run_fetched" != true ]; then
    # §6/convergence.md: an unreachable remote is JOURNALED as `source: none`,
    # not only printed to stderr. The record is the durable, replicated evidence
    # that this host converged from last known on this run — a peer reading the
    # journal can tell "was dark, converged locally" from "never ran". It rides
    # the next successful publish, exactly like every other local commit.
    fleet_journal_append "$run_store" "$run_host" \
      "$(jq -cn --arg at "$(fleet_now)" \
        '{outcome:"unreachable",source:"none",at:$at}')" || :
    printf 'roundhouse: converged from last known; nothing published (the remote was unreachable, journaled source: none)\n'
    exit 0
  fi
  fleet_run_publish "$run_store" "$run_host" scheduled/agent \
    "$run_mode convergence" "${run_applied_items:--}" || exit $?
  # The poll floor's fourth condition: this host has converged at this
  # reference, so the next run may honestly short-circuit.
  fleet_vcs_heads_local "$run_store" >"$(fleet_run_state_dir)/converged"
  printf 'roundhouse: published; starting operation %s\n' "$run_op"
  # The off-switch is a policy key like any other, and its absence reads as
  # "on" — an accelerator you cannot turn off is a dependency.
  [ "$(fleet_policy_get "$run_fold" push_nudge 2>/dev/null || printf true)" = false ] ||
    fleet_run_nudge "$run_store" "$run_host" "$run_layers" \
      "$(fleet_run_interval_seconds "$run_fold" "$run_host" fast)" || :
)

fleet_run_resolve_conflict() (
  # fleet_run_resolve_conflict STORE HOST TMP FOLD HEADS
  #
  # §8.2b step 3b: gather the evidence, decide, write the resolution into @ (a
  # child of M). The ladder itself lives in lib/fleet-resolve.sh and takes its
  # evidence as DATA; this function's whole job is assembling that data
  # honestly and turning a verdict into bytes.
  #
  # ponytail: the resolution is written at FILE granularity — a conflicted
  # layer file is taken whole from the winning side. Adjacent-line collisions
  # (the common case) all decide rule 1 and agree, so this costs nothing; a
  # file whose items split across sides escalates instead of being merged
  # key-by-key. Upgrade to a per-key rewrite if a real fleet ever hits it.
  resolve_store=$1
  resolve_host=$2
  resolve_tmp=$3
  resolve_fold=$4
  # shellcheck disable=SC2086 # deliberate word splitting over the head list
  set -- $5
  [ $# -eq 2 ] || {
    printf 'roundhouse: %s heads on a conflicted bookmark; escalating rather than arbitrating\n' "$#" >&2
    # On the REPLICATED alert surface too, like every other escalation: a
    # three-way bookmark conflict that only reaches stderr is invisible to
    # `fleet-pending` and to every peer.
    fleet_alert_write "$resolve_store" "$resolve_host" conflict \
      conflict-multiple-heads \
      "$# heads on the main bookmark; escalating rather than arbitrating (§8.2b)" ||
      :
    return 1
  }
  resolve_origin=$(fleet_vcs_head_origin "$resolve_store")
  if [ "$1" = "$resolve_origin" ]; then
    resolve_theirs=$1
    resolve_mine=$2
    resolve_theirs_dir=$resolve_tmp/head-1
    resolve_mine_dir=$resolve_tmp/head-2
  else
    resolve_mine=$1
    resolve_theirs=$2
    resolve_mine_dir=$resolve_tmp/head-1
    resolve_theirs_dir=$resolve_tmp/head-2
  fi
  resolve_interval=$(fleet_run_interval_seconds "$resolve_fold" "$resolve_host" fast)
  : >"$resolve_tmp/sides"
  : >"$resolve_tmp/escalated"
  grep '^held ' "$resolve_tmp/verdicts" | while read -r _ resolve_item; do
    [ -n "$resolve_item" ] || continue
    resolve_evidence=$(fleet_run_evidence "$resolve_item" "$resolve_interval" \
      "$(fleet_run_side "$resolve_store" "$resolve_mine" "$resolve_item" \
        "$resolve_host" "$resolve_tmp/hosts" "$resolve_tmp" "$resolve_mine_dir" \
        "$resolve_theirs")" \
      "$(fleet_run_side "$resolve_store" "$resolve_theirs" "$resolve_item" \
        "$resolve_host" "$resolve_tmp/hosts" "$resolve_tmp" "$resolve_theirs_dir" \
        "$resolve_mine")")
    resolve_decision=$(printf '%s\n' "$resolve_evidence" | fleet_resolve_decide)
    resolve_verdict=$(printf '%s\n' "$resolve_decision" | jq -r '.verdict')
    resolve_rule=$(printf '%s\n' "$resolve_decision" | jq -r '.rule')
    resolve_why=$(printf '%s\n' "$resolve_decision" | jq -r '.rationale')
    if [ "$resolve_verdict" = escalate ]; then
      printf '  hold  %s — rule %s: %s\n' "$resolve_item" "$resolve_rule" "$resolve_why"
      fleet_alert_write "$resolve_store" "$resolve_host" conflict \
        "conflict-$(printf '%s' "$resolve_item" | tr './' '--')" \
        "rule $resolve_rule: $resolve_why" "$resolve_item" || :
      printf '%s\n' "$resolve_item" >>"$resolve_tmp/escalated"
      continue
    fi
    resolve_side=mine
    [ "$resolve_verdict" != theirs ] || resolve_side=theirs
    resolve_path=$(fleet_run_item_layer "$resolve_mine_dir" "$resolve_host" \
      "$resolve_item" 2>/dev/null) ||
      resolve_path=$(fleet_run_item_layer "$resolve_theirs_dir" "$resolve_host" \
        "$resolve_item" 2>/dev/null) || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$resolve_path" "$resolve_side" \
      "$resolve_item" "$resolve_rule" "$resolve_why" >>"$resolve_tmp/sides"
  done

  [ ! -s "$resolve_tmp/escalated" ] || return 1
  [ -s "$resolve_tmp/sides" ] || return 1
  : >"$resolve_tmp/resolved"
  rm -f "$resolve_tmp/split"
  # A `return` inside a pipeline's `while` leaves the pipeline's subshell, not
  # this function, so the split-file refusal travels as a file.
  cut -f1 "$resolve_tmp/sides" | LC_ALL=C sort -u |
    while IFS= read -r resolve_path; do
      [ -n "$resolve_path" ] || continue
      resolve_choice=$(awk -F'\t' -v p="$resolve_path" \
        '$1 == p { print $2 }' "$resolve_tmp/sides" | LC_ALL=C sort -u)
      [ "$(printf '%s\n' "$resolve_choice" | grep -c .)" -eq 1 ] || {
        printf 'roundhouse: %s carries items resolving to both sides; escalating\n' \
          "$resolve_path" >&2
        : >"$resolve_tmp/split"
        continue
      }
      resolve_head=$resolve_mine
      [ "$resolve_choice" != theirs ] || resolve_head=$resolve_theirs
      mkdir -p "$resolve_store/$(dirname "$resolve_path")"
      jj -R "$resolve_store" file show -r "$resolve_head" "root:$resolve_path" \
        >"$resolve_store/$resolve_path"
      awk -F'\t' -v p="$resolve_path" '$1 == p { print $3 }' "$resolve_tmp/sides" \
        >>"$resolve_tmp/resolved"
    done
  [ ! -f "$resolve_tmp/split" ] || return 1
  [ -s "$resolve_tmp/resolved" ] || return 1

  # §5's one replicated record that carries a rationale, and the exception that
  # proves the rule: a hold reason is duplicated in store.run/, but a
  # resolution is a fleet-affecting decision no other artifact records. Peers
  # must be able to see why.
  #
  # STAGED, NOT APPENDED. The fold that makes the resolution real
  # (fleet_vcs_fold_resolution) runs in the CALLER and can still refuse — the
  # merge may come back conflicted — so writing `outcome: resolved` here
  # published a record, to every peer, for an item that was still held. The
  # caller appends these once the fold has succeeded.
  : >"$resolve_tmp/resolution-journal"
  while IFS= read -r resolve_item; do
    [ -n "$resolve_item" ] || continue
    resolve_row=$(awk -F'\t' -v i="$resolve_item" '$3 == i { print; exit }' \
      "$resolve_tmp/sides")
    printf '%s\n' \
      "$(jq -cn --arg item "$resolve_item" \
        --arg digest "$(fleet_item_digest "$resolve_fold" "$resolve_item" 2>/dev/null || printf unknown)" \
        --arg mine "$(jj -R "$resolve_store" log -r "$resolve_mine" --no-graph -T 'change_id')" \
        --arg theirs "$(jj -R "$resolve_store" log -r "$resolve_theirs" --no-graph -T 'change_id')" \
        --arg host "$resolve_host" \
        --arg resolution "rule $(printf '%s' "$resolve_row" | cut -f4): $(printf '%s' "$resolve_row" | cut -f5)" \
        --arg at "$(fleet_now)" \
        '{item:$item,digest:$digest,outcome:"resolved",
          sides:[{change:$mine,host:$host},{change:$theirs,host:"peer"}],
          resolution:$resolution,at:$at}')" >>"$resolve_tmp/resolution-journal"
  done <"$resolve_tmp/resolved"
)

fleet_run_resolution_journal() {
  # fleet_run_resolution_journal STORE HOST TMP — append the resolution records
  # fleet_run_resolve_conflict staged, once the fold that made them true has
  # succeeded.
  [ -f "$3/resolution-journal" ] || return 0
  while IFS= read -r fleet_run_res_entry; do
    [ -n "$fleet_run_res_entry" ] || continue
    fleet_journal_append "$1" "$2" "$fleet_run_res_entry" || :
  done <"$3/resolution-journal"
  rm -f "$3/resolution-journal"
}

fleet_run_item_is_held() {
  # fleet_run_item_is_held ITEM DIGEST SIGNATURE_HOLDS VERDICTS. The full
  # cadence runs after the apply loop, so it must not consume a definition or
  # desired plugin that this run already held. Otherwise maintenance could
  # act on content the item gate deliberately refused.
  [ -f "$3" ] && awk -v item="$1" '$1 == item { found = 1 } END { exit !found }' \
    "$3" && return 0
  [ -f "$4" ] && awk -v item="$1" \
    '$1 == "held" && $2 == item { found = 1 } END { exit !found }' \
    "$4" && return 0
  [ -n "$2" ] && fleet_run_verdict_held "$1" "$2" && return 0
  return 1
}

fleet_run_definition_hold_consumers() {
  # fleet_run_definition_hold_consumers HOLDS VERDICTS VALUES TMP — a definitions
  # refusal also holds the desired item that would resolve through it. The
  # mapping is one-to-one by design: definitions.packages.foo governs
  # packages.foo, and the same shape applies to agent-surface categories.
  # This protects both a changed mapping and a deleted mapping, whose current
  # tree no longer has an entry from which a resolver could detect the hold.
  fleet_run_definition_hold_items=$4/definition-hold-items
  awk '$1 != "" && $1 != "!hold" { print $1 }' "$1" \
    >"$fleet_run_definition_hold_items"
  awk '$1 == "held" { print $2 }' "$2" \
    >>"$fleet_run_definition_hold_items"
  fleet_run_definition_consumer_holds=$4/definition-consumer-holds
  : >"$fleet_run_definition_consumer_holds"
  while IFS= read -r fleet_run_definition_hold; do
    fleet_run_definition_item=${fleet_run_definition_hold%% *}
    case $fleet_run_definition_item in
      definitions.*.*)
        fleet_run_definition_rest=${fleet_run_definition_item#definitions.}
        fleet_run_definition_category=${fleet_run_definition_rest%%.*}
        fleet_run_definition_name=${fleet_run_definition_rest#*.}
        [ -n "$fleet_run_definition_category" ] || continue
        [ -n "$fleet_run_definition_name" ] || continue
        fleet_run_definition_consumer=$fleet_run_definition_category.$fleet_run_definition_name
        awk -v item="$fleet_run_definition_consumer" \
          '$1 == item { found = 1 } END { exit !found }' "$3" || continue
        printf '%s held by %s\n' "$fleet_run_definition_consumer" \
          "$fleet_run_definition_item" >>"$fleet_run_definition_consumer_holds"
        ;;
    esac
  done < <(LC_ALL=C sort -u "$fleet_run_definition_hold_items")
  [ ! -s "$fleet_run_definition_consumer_holds" ] || {
    LC_ALL=C sort -u "$fleet_run_definition_consumer_holds" \
      >>"$1"
  }
}

fleet_run_hold_items_into_verdicts() {
  # fleet_run_hold_items_into_verdicts HOLDS VERDICTS TMP — a held item that
  # vanished from every reviewed head still needs a verdict entry. Otherwise
  # the removal pass and the apply loop never see the hold: an existing host
  # can forget the item, while a new host can resolve a deleted definition by
  # its default. Preserve existing converge/held verdicts and add only the
  # missing held entries. A `converge` verdict for a held item is replaced, so
  # the removal and apply loops consume the same effective decision.
  fleet_run_hold_item_list=$3/held-items
  awk '$1 != "" && $1 != "!hold" { print $1 }' "$1" |
    LC_ALL=C sort -u >"$fleet_run_hold_item_list"
  fleet_run_held_verdicts=$3/held-verdicts
  awk '
    FILENAME == ARGV[1] { held[$1] = 1; next }
    {
      if ($2 in held) {
        print "held", $2
        emitted[$2] = 1
      } else {
        print
      }
    }
    END {
      for (item in held)
        if (!(item in emitted)) print "held", item
    }
  ' "$fleet_run_hold_item_list" "$2" |
    LC_ALL=C sort >"$fleet_run_held_verdicts"
  mv -f "$fleet_run_held_verdicts" "$2"
}

fleet_run_runtime_hold() {
  # fleet_run_runtime_hold ITEM REASON HOLDS_FILE — carry an apply-time
  # refusal into the same temporary hold surface the full cadence consumes.
  # This file is run-local and never replicated; the journal remains the audit
  # record, while this marker prevents maintenance in this same run from acting
  # on content the apply gate just refused.
  printf '%s %s\n' "$1" "$2" >>"$3"
  case $1 in
    definitions.*.*)
      fleet_run_runtime_definition_rest=${1#definitions.}
      fleet_run_runtime_definition_category=${fleet_run_runtime_definition_rest%%.*}
      fleet_run_runtime_definition_name=${fleet_run_runtime_definition_rest#*.}
      printf '%s held by %s: %s\n' \
        "$fleet_run_runtime_definition_category.$fleet_run_runtime_definition_name" \
        "$1" "$2" >>"$3"
      ;;
  esac
}

fleet_run_plugin_marketplaces() (
  # Resolve desired plugin marketplaces from the same surface resolver the
  # apply path uses. A marketplace may live in the definitions tier when the
  # desired value is the documented scalar `enabled`; refreshing only inline
  # values leaves that manifest stale forever.
  fleet_run_market_fold=$1
  fleet_run_market_defs=$2
  fleet_run_market_holds=${3:-}
  fleet_run_market_verdicts=${4:-}
  printf '%s\n' "$fleet_run_market_fold" |
    jq -r '(.plugins // {}) | to_entries[] |
      [.key, (.value | if type == "object" then (.marketplace // "") else "" end)] |
      @tsv' |
    while IFS='	' read -r fleet_run_market_plugin fleet_run_inline_market; do
      [ -n "$fleet_run_market_plugin" ] || continue
      fleet_run_market_item="plugins.$fleet_run_market_plugin"
      fleet_run_market_digest=$(fleet_item_digest "$fleet_run_market_fold" \
        "$fleet_run_market_item" 2>/dev/null || true)
      fleet_run_item_is_held "$fleet_run_market_item" "$fleet_run_market_digest" \
        "$fleet_run_market_holds" "$fleet_run_market_verdicts" && continue
      fleet_run_market=$fleet_run_inline_market
      if [ -z "$fleet_run_market" ]; then
        fleet_run_market_definition_item="definitions.plugins.$fleet_run_market_plugin"
        fleet_run_market_definition=$(fleet_definition_entry "$fleet_run_market_defs" \
          plugins "$fleet_run_market_plugin")
        [ -n "$fleet_run_market_definition" ] || continue
        fleet_run_market_definition_digest=$(printf '%s\n' \
          "$fleet_run_market_definition" |
          fleet_value_digest "$fleet_run_market_definition_item")
        fleet_run_item_is_held "$fleet_run_market_definition_item" \
          "$fleet_run_market_definition_digest" "$fleet_run_market_holds" \
          "$fleet_run_market_verdicts" && continue
        fleet_run_market=$(fleet_resolve_surface "$fleet_run_market_defs" plugins \
          "$fleet_run_market_plugin" 2>/dev/null | jq -r '.marketplace // empty')
      fi
      [ -n "$fleet_run_market" ] || continue
      fleet_upstream_id_valid "$fleet_run_market" || continue
      printf '%s\n' "$fleet_run_market"
    done |
    LC_ALL=C sort -u
)

fleet_run_full_pass() (
  # fleet_run_full_pass STORE HOST FOLD DEFS LAYERDIR TMP — everything the fast
  # run does NOT do, and the reason the fast interval can be 20 minutes:
  # discovery, upstreams, proposals, doctor and package updates run twice a
  # day, not 72 times.
  full_store=$1
  full_host=$2
  full_fold=$3
  full_defs=$4
  full_layers=$5
  full_hold_dir=${6:-}

  # §10.5: one file per host per upstream. No leases, no CAS, no TTLs, no
  # takeover — jitter is the coordination primitive.
  fleet_run_plugin_marketplaces "$full_fold" "$full_defs" \
    "${6:-}/sigholds" "${6:-}/verdicts" |
    while IFS= read -r full_upstream; do
    [ -n "$full_upstream" ] || continue
    full_result=unavailable
    if command -v claude >/dev/null 2>&1; then
      full_result=failed
      ! claude plugin marketplace update "$full_upstream" >/dev/null 2>&1 ||
        full_result=ok
    fi
    fleet_upstream_write "$full_store" "$full_upstream" "$full_host" "$full_result" || :
  done

  # §7.11.3's three aging policies, DELIBERATELY SEPARATE because they answer
  # different questions and have different natural periods. Both of the two that
  # ride a cadence ride THIS one; the third (history) stays instruction-driven,
  # because a re-root rewrites what every clone starts from.
  #
  # Pruning expired leaves is safe here and would not be in a snapshot model:
  # an old commit is verified against the roster at ITS parents, where the entry
  # still exists. Evidence retention carries no trust reasoning at all, because
  # evidence paths are never inputs to verification.
  fleet_trust_prune_expired "$full_store/$fleet_trust_roster_file" || :
  # THE RETENTION WINDOW HAS A FLOOR. It is read from store content, it is not
  # an item (no digest, no verdict, no canary gate, outside fleet_removal_cap),
  # and its consequence is `rm -f` across journal/, alerts/ and findings/ on
  # every host on the 12 h cadence — so `evidence_retention_days: 0` wipes the
  # fleet's entire replicated evidence surface from one unreviewable scalar. A
  # non-numeric value falls back to the default rather than to the floor: a
  # typo should keep more evidence, not less.
  fleet_trust_age_evidence "$full_store" \
    "$(printf '%s\n' "$full_fold" | jq -r '
      (.evidence_retention_days // 90) as $d |
      if ($d | type) == "number" then ([$d, 7] | max | floor) else 90 end')" || :

  # §7.3a B's enrolled side: joins/ is read as a hint and NEVER trusted — the
  # address is SSH'd and the same pubkey confirmed on that machine before any
  # roster line is written.
  fleet_enroll_process_joins "$full_store" "$full_host" || :

  # §10.2: re-seed (upsert, never remove) and then look for unanimity. Seeding
  # writes into the WORKING COPY, never into the exported reviewed tree — the
  # export is a read of a commit and nothing may write back through it.
  fleet_seed_command || :
  fleet_run_proposals "$full_store" "$full_host" "$full_layers" "$6" || :

  # The fleet-update contract, as a predicate: an unpinned package is kept
  # current by this pass — that is what anyone gets by doing nothing — and a
  # `version:` key opts one package out. Skipping the pinned ones is not an
  # optimisation; running them would quietly undo the pin.
  printf '%s\n' "$full_fold" | jq -r '(.packages // {}) | keys[]' |
    while IFS= read -r full_package; do
      [ -n "$full_package" ] || continue
      if [ -n "$full_hold_dir" ] &&
        fleet_run_item_is_held "packages.$full_package" "" \
          "$full_hold_dir/sigholds" "$full_hold_dir/verdicts"; then
        continue
      fi
      if [ -n "$full_hold_dir" ] &&
        fleet_run_item_is_held "definitions.packages.$full_package" "" \
          "$full_hold_dir/sigholds" "$full_hold_dir/verdicts"; then
        continue
      fi
      ! fleet_package_pinned "$full_defs" "$full_package" || continue
      # shellcheck disable=SC2046,SC2086 # the host's package_managers, in order
      full_resolved=$(fleet_resolve_package "$full_defs" "$full_package" \
        $(printf '%s\n' "$full_fold" | jq -r '(.package_managers // []) | join(" ")')) || :
      [ "$(printf '%s\n' "$full_resolved" | jq -r '.resolved')" = true ] || continue
      # `</dev/null` on each: this loop is fed by a pipeline, so its stdin is
      # the package list and a greedy manager would eat the rest of it.
      case $(printf '%s\n' "$full_resolved" | jq -r '.manager') in
        homebrew) brew upgrade "$(printf '%s\n' "$full_resolved" | jq -r '.name')" >/dev/null 2>&1 </dev/null || : ;;
        winget) winget upgrade --id "$(printf '%s\n' "$full_resolved" | jq -r '.name')" \
          --silent --accept-package-agreements --accept-source-agreements >/dev/null 2>&1 </dev/null || : ;;
        scoop) scoop update "$(printf '%s\n' "$full_resolved" | jq -r '.name')" >/dev/null 2>&1 </dev/null || : ;;
      esac
    done

  # §10.7: the full cadence ends on the doctor's rows. Advisory by design — a
  # failing row reports, it does not abort a convergence that already happened.
  fleet_doctor_command || :
)

fleet_run_proposals() (
  # §10.2: where an item has an identical value in EVERY enrolled host file,
  # seeding proposes moving it up a layer. Unanimity is the bar — 3-of-5 is
  # normal curation for this fleet (141 vs 58 standalone skills is intent, not
  # drift) and produces no proposal and no alert.
  proposal_store=$1
  proposal_host=$2
  proposal_layers=$3
  proposal_tmp=$4
  : >"$proposal_tmp/items"
  while IFS= read -r proposal_peer; do
    [ -n "$proposal_peer" ] || continue
    fleet_items "$(fleet_host_facts "$proposal_layers" "$proposal_peer")" \
      >>"$proposal_tmp/items"
  done <"$proposal_tmp/hosts"
  LC_ALL=C sort -u "$proposal_tmp/items" | while IFS= read -r proposal_item; do
    [ -n "$proposal_item" ] || continue
    proposal_values=$(while IFS= read -r proposal_peer; do
      [ -n "$proposal_peer" ] || continue
      jq -cn --arg host "$proposal_peer" --argjson value \
        "$(fleet_item_value "$(fleet_host_facts "$proposal_layers" "$proposal_peer")" \
          "$proposal_item" 2>/dev/null || printf null)" \
        '{host:$host,value:$value}'
    done <"$proposal_tmp/hosts" | jq -sc '.')
    fleet_proposal_unanimous "$proposal_values" || continue
    # shellcheck disable=SC2046 # one --args positional per contributing host
    fleet_proposal_write "$proposal_store" \
      "promote-$(printf '%s' "$proposal_item" | tr './' '--')-to-fleet" \
      "$proposal_item" \
      "$(printf '%s\n' "$proposal_values" | jq -c '.[0].value')" \
      fleet.yaml "$proposal_host" \
      'identical in every enrolled host file' \
      $(jq -r '.[].host' <<EOF
$proposal_values
EOF
      ) || :
  done
)

fleet_seed_command() (
  # `roundhouse fleet-seed` — §10.2/§12. Discovery writes this host's OWN
  # `hosts/<name>.yaml` and `applied/<host>.yaml` to match what is installed,
  # so the first convergence after seeding is a no-op BY CONSTRUCTION. That is
  # the safety property worth paying for: a seeding pass that treated the
  # larger host as truth would install 83 skills someone deliberately kept off
  # a machine, and the reverse mistake deletes 83.
  #
  # It writes into the WORKING COPY and stops — no describe, no bookmark move,
  # no push. The next run's promote gate parses what it wrote and publishes it
  # through the ordinary gates (§6 step 4), which is what keeps seeding from
  # being a second, unreviewed path onto `main`. §12's sequence is exactly
  # this: fleet-init, fleet-enroll, fleet-seed, hand-edit fleet.yaml,
  # fleet-doctor.
  #
  # Re-seeding UPSERTS and never removes: a skill uninstalled between seeds is
  # a convergence decision for the run to report by name, not something seeding
  # silently drops.
  fleet_run_env
  require_jq
  require_yq
  seed_store=$(fleet_store_path)
  seed_host=$(fleet_host_name)
  seed_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-seed.XXXXXX")
  trap 'rm -rf "$seed_tmp"' EXIT HUP INT TERM

  # A TEST hook may substitute the snapshot. It decides what gets DESCRIBED,
  # never what is trusted, and a fixture that shells out to the real collector
  # is a fixture that passes for the wrong reason on the next runner image.
  if fleet_test_hook "${ROUNDHOUSE_SEED_SNAPSHOT:-}"; then
    cat "$ROUNDHOUSE_SEED_SNAPSHOT" >"$seed_tmp/snapshot.jsonl"
  else
    collect_command --section agents --section packages \
      --output "$seed_tmp/snapshot.jsonl" >/dev/null
  fi

  # ponytail: plugins, standalone skills and packages — the three surfaces the
  # shipped collector observes. `agents`, `mcp_servers` and `hooks` have no
  # observed-state side at all (declared boundary B-3), so seeding them would
  # be inventing state rather than reading it.
  seed_desired=$(jq -sc '
    # `.enabled // true` would read FALSE as absent — jq'\''s alternative operator
    # treats false and null alike, and a disabled plugin would seed as enabled.
    def state($e): if $e.data.enabled == false then "disabled" else "enabled" end;
    reduce (.[] | select(.status == "present")) as $r ({};
      if $r.kind == "plugin" then
        .plugins[$r.data.name] = (if ($r.data.marketplace // "") == "" then state($r)
          else {state: state($r), marketplace: $r.data.marketplace} end)
      elif $r.kind == "skill" then .skills[$r.data.name] = "enabled"
      elif $r.kind == "package" then .packages[$r.data.name] = "enabled"
      else . end)' "$seed_tmp/snapshot.jsonl")

  # MACHINE TRUTH, seeded from the one file that already states it. `platform`
  # and `groups` are host FACTS rather than desired items — the fold reads them
  # to pick the `os/` and `groups/` layers, and `machine-truth` reports a host
  # file without them as incomplete. Seeding captured the three observed
  # surfaces and not these, so every enrolled host needed a hand-authored
  # hosts/<name>.yaml before its own layers resolved. config.json already
  # carries both, validated (platform is one of macos/linux/wsl/windows and
  # every group matches the name charset), so there is nothing to infer.
  #
  # PRESENCE, not truthiness: a machine legitimately in no groups carries
  # `groups: []`, and dropping an empty list is not the same as having no
  # opinion. The `machine-truth` doctor row compares `.groups // null` on both
  # sides, and jq's `//` passes `[]` through — so an omitted field reads as
  # `null` against the config's `[]` and the row fires forever on a host that
  # is correctly configured.
  seed_facts=$(jq -c --arg host "$seed_host" '
    (.machines[$host] // {}) |
    {} + (if has("platform") then {platform: .platform} else {} end)
       + (if has("groups") then {groups: .groups} else {} end)
    ' "$(config_path)" 2>/dev/null) || seed_facts='{}'
  [ -n "$seed_facts" ] || seed_facts='{}'

  seed_file="$seed_store/hosts/$seed_host.yaml"
  mkdir -p "$(dirname "$seed_file")"
  seed_existing=$(fleet_record_read "$seed_file" '{}')
  # Facts are the BASE, not an override: a value already in the host file wins,
  # because someone wrote it deliberately and seeding is not a place to
  # relitigate it. Observed surfaces still win over both, unchanged.
  fleet_record_write "$seed_file" \
    "$(printf '%s\n' "$seed_existing" | jq -c --argjson seeded "$seed_desired" \
      --argjson facts "$seed_facts" '$facts * . * $seeded')"

  seed_fold=$(fleet_fold "$seed_store" "$seed_host")
  fleet_items "$seed_desired" | while IFS= read -r seed_item; do
    [ -n "$seed_item" ] || continue
    seed_digest=$(fleet_item_digest "$seed_fold" "$seed_item") || continue
    fleet_applied_record "$seed_store" "$seed_host" "$seed_item" "$seed_digest"
  done

  printf 'roundhouse: seeded %s items into %s and applied/%s.yaml (working copy only — the next run publishes them)\n' \
    "$(fleet_items "$seed_desired" | grep -c . || printf 0)" \
    "${seed_file#"$seed_store/"}" "$seed_host"
)

fleet_adopt_pin_command() (
  # `roundhouse fleet-adopt-pin PLUGIN PIN.json` — §10.6's self-update
  # containment. The CONTAINMENT carries verbatim: roundhouse updating itself
  # is gated separately from ordinary convergence, because the code that
  # decides whether an update is safe is the code being updated.
  #
  # The RECORD is re-implemented. v1 emitted `schema:"roundhouse.sync-adopt-pin",
  # schema_version:1` and §14 bans both keys; the decision is now an ordinary
  # item under the closed category set — `plugins.<name>`, the same id, digest
  # and shape every other item carries, so nothing has to learn a second
  # vocabulary to read it.
  fleet_run_env
  require_jq
  adopt_plugin=$1
  adopt_file=$2
  [ -f "$adopt_file" ] || {
    printf 'roundhouse: no pin file at %s\n' "$adopt_file" >&2
    exit 66
  }
  adopt_store=$(fleet_store_path)
  adopt_sha=$(jq -r '.sha // empty' "$adopt_file")
  adopt_version=$(jq -r '.version // empty' "$adopt_file")
  adopt_by=$(jq -r '.updated_by // empty' "$adopt_file")
  adopt=false
  adopt_reason="no host has published an applied record for plugins.$adopt_plugin at this pin"
  if [ "$adopt_plugin" != roundhouse ]; then
    # Only roundhouse is contained: every other plugin rides the ordinary
    # review, canary and apply gates, and a second gate in front of them would
    # be a second policy to keep in step with the first.
    adopt=true
    adopt_reason='an ordinary plugin adopts through the ordinary gates'
  elif [ "$adopt_version" = "$(jq -r '.version' \
    "$plugin_root/.codex-plugin/plugin.json" 2>/dev/null)" ]; then
    adopt=true
    adopt_reason='the pin names the version already running here'
  elif [ -n "$adopt_by" ] &&
    [ "$(fleet_applied_digest "$adopt_store" "$adopt_by" "plugins.$adopt_plugin")" = \
      "$adopt_sha" ]; then
    # The containment condition, read off the ONE record that answers it:
    # applied/<updating-host>.yaml says that host is carrying this pin RIGHT
    # NOW, and §7.3 says only that host could have written it. A journal replay
    # would answer the same question more slowly and with more ways to be wrong.
    adopt=true
    adopt_reason="$adopt_by has this pin applied"
  fi
  jq -n --arg item "plugins.$adopt_plugin" --arg digest "$adopt_sha" \
    --arg version "$adopt_version" --arg by "$adopt_by" \
    --argjson adopted "$adopt" --arg reason "$adopt_reason" \
    --arg at "$(fleet_now)" \
    '{item:$item, digest:(if $digest == "" then null else $digest end),
      version:(if $version == "" then null else $version end),
      updated_by:(if $by == "" then null else $by end),
      adopted:$adopted, reason:$reason, at:$at}'
  [ "$adopt" = true ] || exit 65
)

fleet_rollback_command() (
  # `roundhouse fleet-rollback ITEM [--now]` — §10.8. Rollback is NOT a special
  # path: a fleet-wide rollback is a signed revert commit on `main` that flows
  # through the exact same review, canary and apply gates as any other change.
  # That is why it can be trusted — there is no privileged "undo" code path
  # that has never been exercised.
  fleet_run_env
  require_jq
  require_yq
  rollback_now=false
  rollback_item=
  while [ $# -gt 0 ]; do
    case $1 in
      --now) rollback_now=true ;;
      -*)
        printf 'roundhouse: unknown fleet-rollback option: %s\n' "$1" >&2
        exit 64
        ;;
      *) rollback_item=$1 ;;
    esac
    shift
  done
  [ -n "$rollback_item" ] || {
    printf 'roundhouse: fleet-rollback needs an item id\n' >&2
    exit 64
  }
  rollback_store=$(fleet_store_path)
  rollback_host=$(fleet_host_name)
  fleet_vcs_store_ready "$rollback_store" || exit $?
  [ "$(fleet_vcs_heads_local "$rollback_store" | grep -c .)" -eq 1 ] || {
    printf 'roundhouse: main is diverged; reconcile before rolling back (§8.2)\n' >&2
    exit 65
  }
  rollback_ref=$(fleet_vcs_heads_local "$rollback_store" | head -1)
  rollback_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-rollback.XXXXXX")
  trap 'rm -rf "$rollback_tmp"' EXIT HUP INT TERM
  fleet_run_export "$rollback_store" "$rollback_ref" "$rollback_tmp/now"
  rollback_path=$(fleet_run_item_layer "$rollback_tmp/now" "$rollback_host" \
    "$rollback_item") || {
    printf 'roundhouse: no layer carries %s at the reviewed ref\n' "$rollback_item" >&2
    exit 65
  }

  # The change that last touched the layer file this item resolves from. A
  # `files()` revset, never a description grep: the trailer is self-asserted
  # and a commit that merely claims to have set an item is not evidence.
  rollback_bad=$(jj -R "$rollback_store" log \
    -r "::$rollback_ref & files(root:\"$rollback_path\")" \
    --no-graph -T 'commit_id ++ "\n"' | head -1)
  [ -n "$rollback_bad" ] || {
    printf 'roundhouse: nothing in history touched %s\n' "$rollback_path" >&2
    exit 65
  }
  rollback_change=$(jj -R "$rollback_store" log -r "$rollback_bad" --no-graph \
    -T 'change_id')

  rollback_before=$(jj -R "$rollback_store" log -r "children($rollback_ref)" \
    --no-graph -T 'commit_id ++ "\n"')
  jj -R "$rollback_store" revert -r "$rollback_bad" -d "$rollback_ref" >/dev/null
  rollback_revert=$(jj -R "$rollback_store" log -r "children($rollback_ref)" \
    --no-graph -T 'commit_id ++ "\n"' |
    grep -vxF "$(printf '%s\n' "$rollback_before")" | head -1)
  [ -n "$rollback_revert" ] || {
    printf 'roundhouse: jj revert produced no new commit\n' >&2
    exit 65
  }
  # `jj revert` reverses the WHOLE commit, and a run commit bundles the layer
  # edit with that run's journal, applied/ and alert records (§6 step 6 writes
  # them into the same @). Reversing those would delete evidence peers have
  # already seen and make this host disown what it installed — §10.3's "never
  # prune" and §10.1's canary attribution both rest on those files. So the
  # records are restored to their pre-revert content and only the LAYERS roll
  # back, which is what §10.8 means by a revert of the change.
  rollback_revert_change=$(jj -R "$rollback_store" log -r "$rollback_revert" \
    --no-graph -T 'change_id')
  jj -R "$rollback_store" restore --from "$rollback_ref" --into "$rollback_revert" \
    'root:journal' 'root:applied' 'root:alerts' 'root:findings' \
    'root:upstreams' 'root:proposals' 'root:lineage' >/dev/null 2>&1 || :
  # `jj restore --into` rewrites the commit, so its commit id moved. The CHANGE
  # id did not — which is the property §7.4 records and the one thing that
  # makes a rewritten commit findable again.
  rollback_revert=$(jj -R "$rollback_store" log -r "$rollback_revert_change" \
    --no-graph -T 'commit_id')
  jj -R "$rollback_store" describe -r "$rollback_revert" \
    -m "revert $rollback_item

$(fleet_vcs_trailers "$rollback_host" revert \
      "rollback; $rollback_item reverted on $rollback_host" \
      "$rollback_item" "$rollback_change")" >/dev/null
  # Every rewrite moves the commit id and preserves the change id, so the
  # bookmark is set from the change and not from a stale id — pointing `main`
  # at the pre-describe commit would publish a revert with no trailers at all.
  rollback_revert=$(jj -R "$rollback_store" log -r "$rollback_revert_change" \
    --no-graph -T 'commit_id')

  # The reverted value, read from the revert commit itself.
  fleet_run_export "$rollback_store" "$rollback_revert" "$rollback_tmp/after"
  rollback_digest=$(fleet_item_digest \
    "$(fleet_fold "$rollback_tmp/after" "$rollback_host")" "$rollback_item") ||
    rollback_digest=absent

  if [ "$rollback_now" = true ]; then
    # THE ONLY CANARY BYPASS IN THE DESIGN, and it is bound rather than being a
    # flag that turns a gate off. Two independent checks, both of them about
    # HISTORY and neither about the trailer's claim, and BOTH BEFORE the
    # bookmark moves — a refusal that had already advanced `main` would publish
    # the very revert it refused to accelerate on the next ordinary run.
    #
    #   §8.2b rule 3's scoped check — the reverted value must equal what the
    #   named change replaced, and the value it displaces must equal what that
    #   change set. Checking only the first verifies the claim is true about
    #   history, not that it is about THIS item.
    #
    #   §10.8's revert-signature predicate — this host applied that digest
    #   before and later stopped. A forward change cannot satisfy it.
    fleet_run_export "$rollback_store" "$rollback_bad-" "$rollback_tmp/replaced"
    fleet_run_export "$rollback_store" "$rollback_bad" "$rollback_tmp/set"
    rollback_replaced=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/replaced" "$rollback_host")" "$rollback_item")
    rollback_set=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/set" "$rollback_host")" "$rollback_item")
    rollback_after=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/after" "$rollback_host")" "$rollback_item")
    rollback_before_value=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/now" "$rollback_host")" "$rollback_item")
    rollback_bound=true
    { [ -n "$rollback_replaced" ] && [ "$rollback_after" = "$rollback_replaced" ] &&
      [ "$rollback_before_value" = "$rollback_set" ]; } || {
      printf 'roundhouse: --now refused: %s is not a verified revert of %s (§8.2b rule 3)\n' \
        "$rollback_item" "$rollback_change" >&2
      rollback_bound=false
    }
    [ "$rollback_bound" != true ] ||
      fleet_run_is_revert "$rollback_store" "$rollback_host" "$rollback_item" \
        "$rollback_digest" || {
      printf 'roundhouse: --now refused: this host has no applied-then-withdrawn record for %s at %s (§10.8)\n' \
        "$rollback_item" "$rollback_digest" >&2
      rollback_bound=false
    }
    [ "$rollback_bound" = true ] || {
      jj -R "$rollback_store" abandon -r "$rollback_revert" >/dev/null 2>&1 || :
      exit 65
    }
  fi

  # §6 step 6's order, unchanged: the bookmark moves, the working copy lands on
  # the revert, the evidence is written INTO that working copy, and only then
  # does anything push. Journaling before `jj new` would write the record into
  # a commit the publish then walks away from.
  jj -R "$rollback_store" bookmark set main -r "$rollback_revert" >/dev/null
  jj -R "$rollback_store" new "$rollback_revert" >/dev/null

  if [ "$rollback_now" = true ]; then
    # Signed and journaled like everything else, so §7.3 attributes it to a
    # host and every peer sees it; doctor reports every override in the last 30
    # days. A bypass nobody counts is a bypass that becomes routine.
    fleet_journal_append "$rollback_store" "$rollback_host" \
      "$(jq -cn --arg item "$rollback_item" --arg d "$rollback_digest" \
        --arg at "$(fleet_now)" \
        '{item:$item,digest:$d,outcome:"applied",override:"canary",at:$at}')" || :
    fleet_alert_write "$rollback_store" "$rollback_host" canary-override \
      "canary-override-$(printf '%s' "$rollback_item" | tr './' '--')" \
      "canary wait bypassed for $rollback_item by an explicit --now" \
      "$rollback_item" || :
  else
    fleet_journal_append "$rollback_store" "$rollback_host" \
      "$(jq -cn --arg item "$rollback_item" --arg d "$rollback_digest" \
        --arg at "$(fleet_now)" \
        '{item:$item,digest:$d,outcome:"reverted",at:$at}')" || :
  fi

  fleet_run_publish "$rollback_store" "$rollback_host" revert \
    "rollback $rollback_item" "$rollback_item" || exit $?
  printf 'roundhouse: reverted %s (change %s); every host re-reviews it as the new change it is\n' \
    "$rollback_item" "$rollback_change"
  # §10.8's per-category honesty: a rollback that silently cannot roll
  # something back is worse than no rollback.
  case ${rollback_item%%.*} in
    projects)
      printf 'roundhouse: projects are NOT reversible by this system — reverting the entry stops managing the project, it does not restore repository state\n'
      ;;
    mcp_servers | hooks)
      printf 'roundhouse: %s is reversible for CONFIGURATION only — removing it stops it firing, it does not undo what it already did\n' \
        "${rollback_item%%.*}"
      ;;
  esac
)

# --- §7.6/§10.2/§10.4 the supervised verbs ------------------------------------
#
# Every command below writes into the WORKING COPY and stops. None of them
# describes, moves a bookmark or pushes: the next `fleet-run` parses what they
# wrote and publishes it through the ordinary gates (§6 step 4). That is what
# keeps the supervised surface from being a second, unreviewed path onto `main`
# — the same rule `fleet-seed` follows, for the same reason.

fleet_review_command() (
  # `roundhouse fleet-review ITEM pass|hold REASON` — §7.6. The verdict binds
  # to the digest the item resolves to RIGHT NOW; it is host-local and never
  # replicated, so it can never read as consent given on another host's behalf.
  fleet_run_env
  require_jq
  require_yq
  review_item=$1
  review_verdict=$2
  review_reason=$3
  # The item id names a FILE under store.run/verdicts/. The digest lookup below
  # already refuses anything that does not resolve in the fold, so this is the
  # second lock on the same door — but it is the one that is about the path.
  case $review_item in
    '' | */* | .*)
      printf 'roundhouse: %s is not an item id (<category>.<name>)\n' \
        "${review_item:-<empty>}" >&2
      exit 64
      ;;
  esac
  case $review_verdict in
    pass | hold) ;;
    *)
      printf 'roundhouse: fleet-review verdict must be pass or hold\n' >&2
      exit 64
      ;;
  esac
  [ -n "$review_reason" ] || {
    printf 'roundhouse: fleet-review requires a reason\n' >&2
    exit 64
  }
  review_store=$(fleet_store_path)
  review_host=$(fleet_host_name)
  review_digest=$(fleet_item_digest \
    "$(fleet_fold "$review_store" "$review_host")" "$review_item") || {
    printf 'roundhouse: no layer carries %s for %s\n' "$review_item" "$review_host" >&2
    exit 65
  }
  fleet_run_verdict_write "$review_item" "$review_digest" "$review_reason" \
    human "$review_verdict"
  printf 'roundhouse: %s %s at %s\n' "$review_item" "$review_verdict" "$review_digest"
)

fleet_apply_command() (
  # `roundhouse fleet-apply ITEM` — §6. THE VERDICT GATE IS THE POINT: an apply
  # with no recorded pass at this exact digest is refused, so this verb can
  # never become an unreviewed write path that happens to be shorter to type
  # than the reviewed one. A stale pass fails the same way an absent one does.
  fleet_run_env
  require_jq
  require_yq
  apply_item=$1
  apply_store=$(fleet_store_path)
  apply_host=$(fleet_host_name)
  apply_fold=$(fleet_fold "$apply_store" "$apply_host")
  apply_digest=$(fleet_item_digest "$apply_fold" "$apply_item") || {
    printf 'roundhouse: no layer carries %s for %s\n' "$apply_item" "$apply_host" >&2
    exit 65
  }
  [ "$(fleet_run_verdict_digest "$apply_item")" = "$apply_digest" ] || {
    printf 'roundhouse: no passing review of %s at %s; run `roundhouse fleet-review %s pass REASON` first\n' \
      "$apply_item" "$apply_digest" "$apply_item" >&2
    exit 65
  }
  apply_status=0
  fleet_run_apply_item "$apply_store" "$apply_host" \
    "$(fleet_definitions_load "$apply_store")" "$apply_item" \
    "$(fleet_item_value "$apply_fold" "$apply_item")" \
    "$(printf '%s\n' "$apply_fold" |
      jq -r '(.package_managers // []) | join(" ")')" || apply_status=$?
  apply_now=$(fleet_now)
  case $apply_status in
    0)
      fleet_applied_record "$apply_store" "$apply_host" "$apply_item" \
        "$apply_digest" "$apply_now"
      fleet_journal_append "$apply_store" "$apply_host" \
        "$(jq -cn --arg item "$apply_item" --arg d "$apply_digest" \
          --arg at "$apply_now" \
          '{item:$item,digest:$d,outcome:"applied",at:$at}')" || :
      printf 'roundhouse: applied %s at %s (working copy only — the next run publishes it)\n' \
        "$apply_item" "$apply_digest"
      ;;
    70)
      # The same split the run makes, for the same reason — and here it also
      # stops the manual verb from WITHDRAWING evidence: a `held` record dated
      # after an earlier `applied`/`satisfied` fails canary condition 2 and
      # would silently re-block every downstream host.
      fleet_journal_append "$apply_store" "$apply_host" \
        "$(jq -cn --arg item "$apply_item" --arg d "$apply_digest" \
          --arg at "$apply_now" \
          '{item:$item,digest:$d,outcome:"satisfied",at:$at}')" || :
      printf 'roundhouse: %s is satisfied at %s — this design has no state-alignment verb for its category (working copy only)\n' \
        "$apply_item" "$apply_digest"
      ;;
    *)
      fleet_journal_append "$apply_store" "$apply_host" \
        "$(jq -cn --arg item "$apply_item" --arg d "$apply_digest" \
          --arg at "$apply_now" \
          '{item:$item,digest:$d,outcome:"held",at:$at}')" || :
      printf 'roundhouse: this host could not apply %s, or a gate refused it\n' \
        "$apply_item" >&2
      exit "$apply_status"
      ;;
  esac
)

fleet_accept_command() (
  # `roundhouse fleet-accept SLUG` — §10.2. A proposal is a suggestion with no
  # authority; accepting it is TWO ORDINARY EDITS this verb makes for you —
  # write the value at the proposed layer, drop it from each host file that
  # carried it — and nothing else. The item's digest is unchanged by
  # construction, so no host re-reviews anything: promotion moves WHERE a value
  # is written, never WHAT it is.
  fleet_run_env
  require_jq
  require_yq
  accept_slug=$1
  case $accept_slug in
    '' | */* | .*)
      printf 'roundhouse: invalid proposal slug: %s\n' "${accept_slug:-<empty>}" >&2
      exit 64
      ;;
  esac
  accept_store=$(fleet_store_path)
  accept_file="$accept_store/proposals/$accept_slug.yaml"
  [ -f "$accept_file" ] || {
    printf 'roundhouse: no proposal at proposals/%s.yaml\n' "$accept_slug" >&2
    exit 66
  }
  accept=$(fleet_record_read "$accept_file" '{}')
  accept_item=$(printf '%s\n' "$accept" | jq -r '.item // empty')
  accept_to=$(printf '%s\n' "$accept" | jq -r '.to // empty')
  accept_value=$(printf '%s\n' "$accept" | jq -c '.value')
  [ -n "$accept_item" ] && [ -n "$accept_to" ] || {
    printf 'roundhouse: proposal %s names no item or no target layer\n' "$accept_slug" >&2
    exit 65
  }
  # The target is store content, and it reaches a file path. It passes the same
  # layer-path predicate the fold uses, so a proposal cannot name `../../.ssh`
  # or a records directory and have this verb write there.
  fleet_run_layer_path "$accept_to" || {
    printf 'roundhouse: proposal %s targets %s, which is not a layer file\n' \
      "$accept_slug" "$accept_to" >&2
    exit 65
  }
  accept_split=$(fleet_item_split "$accept_item") || {
    printf 'roundhouse: proposal %s names an unsplittable item: %s\n' \
      "$accept_slug" "$accept_item" >&2
    exit 65
  }
  accept_category=$(printf '%s\n' "$accept_split" | sed -n 1p)
  accept_name=$(printf '%s\n' "$accept_split" | sed -n 2p)
  fleet_record_write "$accept_store/$accept_to" \
    "$(fleet_record_read "$accept_store/$accept_to" '{}' |
      jq -c --arg c "$accept_category" --arg n "$accept_name" \
        --argjson v "$accept_value" 'setpath([$c, $n]; $v)')"
  printf '%s\n' "$accept" | jq -r '(.from // [])[]' |
    while IFS= read -r accept_from; do
      [ -n "$accept_from" ] || continue
      # `from[]` is store content reaching a WRITE path, exactly as `to` is —
      # and only `to` was validated. `from: ["../../../.ssh/config"]` resolves
      # outside the store, and the `-f` test below only limits it to
      # overwriting an existing file with YAML.
      fleet_host_name_ok "$accept_from" || {
        printf 'roundhouse: proposal %s names an unusable host in from[]: %s\n' \
          "$accept_slug" "$accept_from" >&2
        continue
      }
      accept_host_file="$accept_store/hosts/$accept_from.yaml"
      [ -f "$accept_host_file" ] || continue
      fleet_record_write "$accept_host_file" \
        "$(fleet_record_read "$accept_host_file" '{}' |
          jq -c --arg c "$accept_category" --arg n "$accept_name" \
            'delpaths([[$c, $n]])')"
    done
  # Acted on, so it goes. Leaving it would re-offer a promotion that has
  # already happened, and the next full pass re-proposes on its own if the
  # unanimity that produced it is somehow still true.
  rm -f "$accept_file"
  printf 'roundhouse: %s now lives in %s (working copy only — the next run publishes it)\n' \
    "$accept_item" "$accept_to"
)

fleet_lock_command() (
  # The run-lock, taken by hand: one runner per host per store. A second run
  # exits 75 and STOPS rather than forcing — two convergences racing one plugin
  # cache is the failure this prevents.
  require_jq
  lock=$(fleet_lock_path)
  fleet_lock_acquire "$lock" || {
    printf 'roundhouse: the fleet run-lock is held: %s\n' "$lock" >&2
    exit 75
  }
  printf 'roundhouse: fleet run-lock acquired: %s\n' "$lock"
)

fleet_unlock_command() (
  unlock=$(fleet_lock_path)
  rm -f "$unlock/meta.json"
  [ ! -d "$unlock" ] || rmdir "$unlock"
  printf 'roundhouse: fleet run-lock released\n'
)

fleet_journal_command() (
  # `roundhouse fleet-journal ENTRY.json|-` — §7.3's evidence surface, by hand.
  # The entry passes the SAME shape gate the run's own writes pass; there is no
  # looser hand-written path, because the canary gate on every other host reads
  # what this writes and cannot tell who typed it.
  fleet_run_env
  require_jq
  require_yq
  journal_source=$1
  journal_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-journal.XXXXXX")
  trap 'rm -rf "$journal_tmp"' EXIT HUP INT TERM
  if [ "$journal_source" = - ]; then
    cat >"$journal_tmp/entry.json"
  else
    cat "$journal_source" >"$journal_tmp/entry.json"
  fi
  journal_entry=$(jq -c --arg at "$(fleet_now)" '.at //= $at' \
    "$journal_tmp/entry.json") || {
    printf 'roundhouse: fleet-journal input is not JSON\n' >&2
    exit 65
  }
  fleet_journal_append "$(fleet_store_path)" "$(fleet_host_name)" \
    "$journal_entry" || exit 65
  printf '%s\n' "$journal_entry"
)

fleet_finding_command() (
  # `roundhouse fleet-finding SLUG SUMMARY [QUOTE]` — §10.4. A finding is the
  # ONLY mining output that replicates, so every field it carries goes through
  # the redaction floor, and a trip REFUSES rather than silently redacting: the
  # remedy for a published secret cannot un-publish it.
  fleet_run_env
  require_jq
  require_yq
  finding_slug=$1
  case $finding_slug in
    '' | *[!A-Za-z0-9._-]*)
      printf 'roundhouse: invalid finding slug: %s\n' "${finding_slug:-<empty>}" >&2
      exit 64
      ;;
  esac
  [ -n "$2" ] || {
    printf 'roundhouse: fleet-finding requires a summary\n' >&2
    exit 64
  }
  fleet_finding_write "$(fleet_store_path)" "$(fleet_host_name)" \
    "$finding_slug" "$2" ${3+"$3"} || {
    printf 'roundhouse: refusing the finding: a field trips the redaction floor (§10.4)\n' >&2
    exit 65
  }
  printf 'roundhouse: recorded finding %s (working copy only — the next run publishes it)\n' \
    "$finding_slug"
)

fleet_hold_command() (
  # `roundhouse fleet-hold ITEM REASON` — the fleet-visible half of a refusal.
  # `fleet-review ITEM hold` stops THIS host converging; this writes the alert
  # every host sees. They are deliberately two verbs: one is a local decision,
  # the other is a message, and collapsing them would make every local hold
  # shout at the fleet.
  fleet_run_env
  require_jq
  require_yq
  hold_item=$1
  [ -n "$2" ] || {
    printf 'roundhouse: fleet-hold requires a reason\n' >&2
    exit 64
  }
  fleet_item_split "$hold_item" >/dev/null || {
    printf 'roundhouse: fleet-hold needs a <category>.<name> item id\n' >&2
    exit 64
  }
  fleet_alert_write "$(fleet_store_path)" "$(fleet_host_name)" hold \
    "hold-$(printf '%s' "$hold_item" | tr './' '--')" "$2" "$hold_item" || {
    printf 'roundhouse: refusing the hold: the reason trips the redaction floor (§10.4)\n' >&2
    exit 65
  }
  printf 'roundhouse: held %s for the fleet (working copy only — the next run publishes it)\n' \
    "$hold_item"
)

fleet_pending_command() (
  # `roundhouse fleet-pending` — every open alert in the store, from every
  # host, as JSON lines. Resolution is `rm` on the file (§5): there is no state
  # machine, so "pending" is exactly "the file is still there".
  require_jq
  require_yq
  pending_store=$(fleet_store_path)
  [ -d "$pending_store/alerts" ] || return 0
  find "$pending_store/alerts" -type f -name '*.yaml' 2>/dev/null |
    LC_ALL=C sort | while IFS= read -r pending_file; do
    [ -n "$pending_file" ] || continue
    fleet_record_read "$pending_file" '{}' |
      jq -c --arg path "${pending_file#"$pending_store/"}" '. + {alert: $path}'
  done
)
