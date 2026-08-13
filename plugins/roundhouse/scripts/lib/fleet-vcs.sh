# roundhouse — fleet store integrity: the signature gate, the principal
# equality check, the path->identity table, and the revert-signature predicate.
#
# §7 of docs/specs/2026-08-06-dsc-storage-design-v2.md. Four independent
# bindings, kept separate on purpose: a hand edit that breaks one of them
# narrows what is applicable and never breaks the store.
#
# jj is the gate. `git verify-commit` survives only as a doctor cross-check
# (§7.1) and is not in this unit — nothing here is in the apply path twice.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_vcs_toml_string() {
  # `jj --config` parses its value as TOML. jj 0.44 accepts a bare path (even
  # one carrying spaces, measured), but a signers file that happens to be
  # named `true` or `12` would type as a boolean or an integer and the pin
  # would silently not be a path. Quote, and escape what TOML strings escape.
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

fleet_vcs_path_owner() {
  # §7.3's path->identity table, as one function over a store-relative path.
  #
  #   `*`      row 1 — any `<h>@<domain>` where `<h>` has a hosts/ entry:
  #            the shared layers, definitions.yaml, lineage/, proposals/.
  #            definitions.yaml belongs HERE and not in row 2: it is a
  #            fleet-shared layer like any other, and the reserved
  #            `definitions.` item prefix is about item identity (§5.1), not
  #            about who may author the file.
  #   `<h>`    row 2 — host-keyed evidence, which must verify as EXACTLY
  #            `<h>@<domain>`, with no exception for any host. That is what
  #            makes forged peer evidence inert and gives the canary gate its
  #            integrity: a commit dropped into journal/wren/ by vireo signs
  #            as vireo and is not counted.
  #   `+`      row 4 — `joins/<h>.yaml`: ANY signer, including `unknown`.
  #            Inert by construction, never applied, only read as a hint, which
  #            is why an unknown-signed commit landing there is harmless and
  #            why it gets its own row rather than an exception in row 1.
  #   (1)      an unrecognised path. No item resolves from it, so it needs no
  #            identity; §7.7 holds anything under an unknown category by a
  #            different rule than this one.
  #
  # `trust/signers.yaml` and `checkpoints/` are row 1: sponsoring and
  # checkpointing are fleet-shared writes, which is exactly why a leaf is
  # already refused both with no separate enforcement.
  case $1 in
    fleet.yaml | definitions.yaml | fleet/?* | os/?* | groups/?* | hosts/?* | \
      lineage/?* | proposals/?* | trust/?* | checkpoints/?*)
      printf '*\n'
      ;;
    definitions/?*)
      fleet_definitions_file_path "$1" || return 1
      printf '*\n'
      ;;
    joins/?*.yaml)
      printf '+\n'
      ;;
    journal/?*/?* | alerts/?*/?* | findings/?*/?*)
      fleet_vcs_owner=${1#*/}
      printf '%s\n' "${fleet_vcs_owner%%/*}"
      ;;
    applied/?*.yaml)
      fleet_vcs_owner=${1#applied/}
      case $fleet_vcs_owner in */*) return 1 ;; esac
      printf '%s\n' "${fleet_vcs_owner%.yaml}"
      ;;
    upstreams/?*/?*.yaml)
      # upstreams/<id>/<h>.yaml — exactly three components, so a deeper path
      # cannot smuggle a host name into the leaf position.
      fleet_vcs_owner=${1#upstreams/*/}
      case $fleet_vcs_owner in */*) return 1 ;; esac
      printf '%s\n' "${fleet_vcs_owner%.yaml}"
      ;;
    *) return 1 ;;
  esac
}

fleet_vcs_path_identity_ok() {
  # fleet_vcs_path_identity_ok <store-relative-path> <principal> <hosts-file>
  #
  # The equality check §7.3 exists for. Verification DERIVES the principal
  # from the signature and never compares it to the identity the commit
  # claims, so host B's key verifies clean on a commit claiming host A's
  # identity. The comparison is here.
  #
  # <hosts-file> is one enrolled host name per line (fleet_vcs_enrolled_hosts),
  # passed in rather than read here so the predicate is pure and testable with
  # no store.
  fleet_vcs_required=$(fleet_vcs_path_owner "$1") || return 1
  # `joins/` takes any signer, including `unknown`: it is never applied, so
  # there is nothing for a forged one to authorize.
  [ "$fleet_vcs_required" != '+' ] || return 0
  case $2 in
    *@*) ;;
    *) return 1 ;;
  esac
  fleet_vcs_who=${2%%@*}
  fleet_vcs_domain=${2#*@}
  [ -n "$fleet_vcs_who" ] || return 1
  # One `@`, and a domain: `vireo@` and `a@b@c` are not principals.
  case $fleet_vcs_domain in
    '' | *@*) return 1 ;;
  esac
  if [ "$fleet_vcs_required" = '*' ]; then
    grep -Fqx "$fleet_vcs_who" "$3"
  else
    [ "$fleet_vcs_who" = "$fleet_vcs_required" ]
  fi
}

fleet_vcs_enrolled_hosts() {
  # fleet_vcs_enrolled_hosts <store> <revision> — the row 1 membership set:
  # every `<h>` that has a hosts/ entry at that revision. Both §2 path kinds
  # count, because a host file that grew long and became a directory is the
  # same host.
  #
  # `-T 'path'` is not decoration: a bare `jj file list` prints paths relative
  # to the CALLER's working directory, so under `-R` from anywhere else every
  # line comes back as `../../..//store/hosts/vireo.yaml` and the table below
  # matches nothing. Measured on jj 0.44.
  jj -R "$1" file list -r "$2" -T 'path ++ "\n"' 2>/dev/null | awk -F/ '
    $1 == "hosts" && NF == 2 && $2 ~ /\.yaml$/ {
      name = $2
      sub(/\.yaml$/, "", name)
      print name
      next
    }
    $1 == "hosts" && NF >= 3 { print $2 }
  ' | LC_ALL=C sort -u
}

fleet_vcs_journal_outcomes() {
  # fleet_vcs_journal_outcomes <journal-dir> <item> -> "<outcome> <digest>"
  # lines, oldest first. THIS HOST's own journal directory only: the predicate
  # below asks what this machine did, and a peer's record is evidence about a
  # peer. Date-named files sort chronologically, and records inside one file
  # are already appended in order.
  [ -d "$1" ] || return 0
  find "$1" -type f -name '*.yaml' | LC_ALL=C sort | while IFS= read -r fleet_vcs_day; do
    FLEET_VCS_ITEM=$2 yq -r '
      [.[] | select(.item == strenv(FLEET_VCS_ITEM))]
      | .[] | ((.outcome // "-") + " " + (.digest // "-"))
    ' "$fleet_vcs_day" 2>/dev/null || true
  done
}

fleet_vcs_revert_signature() {
  # fleet_vcs_revert_signature <incoming-digest> < <outcome> <digest> lines
  #
  # §10.8. A stored verdict does not satisfy the apply gate when the incoming
  # digest is one this host previously applied and later stopped applying.
  # That pattern — applied, then withdrawn, now back — IS the signature of a
  # revert, and without it a verdict keyed on (item, digest) matches a stale
  # pass and auto-applies the rollback with no review at all.
  #
  # Pure over journal data: no jj, no change id, no history walk. Fires when
  # the digest was applied at some point AND is not what this host is applying
  # now. That gives all three properties §10.8 needs, from one comparison:
  #
  #   revert     applied D, then applied D_bad  -> current != D  -> fires
  #   promotion  applied D, still applied D     -> current == D  -> silent
  #   re-signing applied D, nothing withdrawn   -> current == D  -> silent
  #
  # `held` records leave the currently-applied value alone: a hold is a
  # refusal to change anything, not a withdrawal. `reverted` clears it.
  awk -v want="$1" '
    $1 == "applied" { current = $2; if (current == want) seen = 1; next }
    $1 == "reverted" { current = ""; next }
    END { exit(seen && current != want ? 0 : 1) }
  '
}

fleet_vcs_store_ready() {
  # The §7.5 comparison, at every point that changes which repository this
  # host talks to. A token that lives only in the store proves "this is some
  # roundhouse store"; the threat is two fleets pointed at one remote, and
  # only the host-local expected value in identity.yaml tells them apart.
  # `jj git clone` performs no check whatsoever on the remote's content.
  [ -d "$1/.jj" ] || {
    printf 'roundhouse: no fleet store at %s; run `roundhouse fleet-init` first\n' \
      "$1" >&2
    return 69
  }
  fleet_store_id_assert "$1" || return 65
}

# --- §8: the reconcile point, the conflicted-bookmark runbook, publication ---
#
# One rule governs every revset below: THE BARE TOKEN `main` NEVER APPEARS IN
# A REVSET ARGUMENT. When two hosts have both moved the bookmark it goes
# conflicted and every bare read exits 1 with "Name `main` is conflicted";
# `present()` does not help, because it guards absence and not ambiguity.
# `--bookmark main` on a push is a bookmark NAME and not a revset, which is
# why it is the one place the token survives.

fleet_vcs_heads_local() {
  # ONE OR MORE commit ids. Two lines is not an error: it is the conflicted
  # bookmark, and §8.3's hold set is computed per head precisely because of
  # it.
  jj -R "$1" log -r 'heads(bookmarks(exact:"main"))' --no-graph -T 'commit_id ++ "\n"'
}

fleet_vcs_head_origin() {
  # Empty on a store that has never fetched — host 1's very first push, and
  # any host whose remote was just re-pointed. `present()` is what makes that
  # exit 0 instead of "Revision `main@origin` doesn't exist".
  jj -R "$1" log -r 'present(main@origin)' --no-graph -T 'commit_id ++ "\n"'
}

fleet_vcs_conflicted() {
  # Non-empty output when the named revision carries a conflict.
  jj -R "$1" log -r "conflicts() & $2" --no-graph -T 'commit_id ++ "\n"'
}

fleet_vcs_resolution_workbench() {
  # §8.1's ONE exemption to the "@ is a fresh child of a main target"
  # invariant, and without it the invariant's own remedy (`jj new <target>`)
  # moves the workbench off an open resolution and discards it. Readable from
  # repo state alone, because $M, $WC and $LOCAL do not survive between runs.
  #
  # "Created locally" is REACHABILITY, never the committer field. The
  # committer test this replaced was spoofable and leaked: a peer sets
  # JJ_EMAIL to the victim's principal, publishes a conflicted merge with
  # --allow-conflicts, the victim fetches, §8.1's own remedy parents @ onto
  # the fetched head, and the clause fires on a commit the victim never made.
  # An inbound conflict is by construction reachable from a remote bookmark;
  # a locally created merge by construction is not.
  jj -R "$1" log -r '(conflicts() & @-) ~ ::remote_bookmarks()' --no-graph \
    -T 'commit_id ++ "\n"'
}

fleet_vcs_trailers() {
  # §5's trailer block: fleet_vcs_trailers <host> <session> <intent> <items>
  # [reverts]. Four trailers, each something the resolver cannot get anywhere
  # else — and every one of them SELF-ASSERTED free text, which is why §8.2b
  # lets them escalate a contest and never win one.
  #
  # Newlines are collapsed: a newline inside `intent` would end the trailer
  # and let the rest of that string pose as further trailers. The claims are
  # unverifiable either way, but a block that stays well-formed is what lets
  # a resolver parse the two it actually reads.
  printf 'roundhouse-host: %s\n' "$(printf '%s' "$1" | tr '\n\r' '  ')"
  printf 'roundhouse-session: %s\n' "$(printf '%s' "$2" | tr '\n\r' '  ')"
  printf 'roundhouse-intent: %s\n' "$(printf '%s' "$3" | tr '\n\r' '  ')"
  [ -z "${5:-}" ] ||
    printf 'roundhouse-reverts: %s\n' "$(printf '%s' "$5" | tr '\n\r' '  ')"
  printf 'roundhouse-items: %s\n' "$(printf '%s' "$4" | tr '\n\r' '  ')"
}

fleet_vcs_working_copy_files() {
  # Names for step 1's description, repo-relative. `jj diff --name-only`
  # prints paths relative to the CALLER's working directory and refuses
  # `-T`, so from anywhere else every name comes back absolute and lands in
  # a replicated commit message that way. Measured on jj 0.44.
  (cd "$1" && jj diff -r @ --name-only) | tr '\n' ' '
}

fleet_vcs_reconcile() {
  # §8.2 steps 1-3: fleet_vcs_reconcile <store> <host> <session> <intent>
  # Prints `clean <M>` or `conflicted <M>`. On the clean path the bookmark
  # has already moved; on the conflicted path it deliberately has NOT, and
  # R = M until §8.2b's resolution is folded in.
  fleet_vcs_repo=$1
  fleet_vcs_host=$2
  fleet_vcs_session=$3
  fleet_vcs_intent=$4

  # §8.1's invariant, checked FIRST because the window it covers is a crashed
  # previous run. A hand edit made while @ sits ON a main target rewrites the
  # commit the bookmark names and drags the bookmark with it; re-parenting
  # first keeps that head's own description and content intact instead of
  # letting step 1 relabel it as a hand edit.
  fleet_vcs_on_target=$(jj -R "$fleet_vcs_repo" log \
    -r '@ & (heads(bookmarks(exact:"main")) | present(main@origin))' \
    --no-graph -T 'commit_id')
  [ -z "$fleet_vcs_on_target" ] ||
    jj -R "$fleet_vcs_repo" new "$fleet_vcs_on_target" >/dev/null

  set --
  for fleet_vcs_head in $(fleet_vcs_heads_local "$fleet_vcs_repo") \
    $(fleet_vcs_head_origin "$fleet_vcs_repo"); do
    set -- "$@" "$fleet_vcs_head"
  done
  [ $# -gt 0 ] || {
    printf 'roundhouse: %s has no main bookmark and no main@origin; run `roundhouse fleet-init`\n' \
      "$fleet_vcs_repo" >&2
    return 65
  }

  # Step 1. The operator may have left an edit in @. It must not be discarded
  # — without it `jj new … $LOCAL $ORIGIN` reports "removed 1 files" and the
  # just-saved layer leaves the working copy — and it must have a description
  # or the push refuses forever.
  #
  # AN EMPTY @ IS NEVER A PARENT. It has nothing to preserve and no
  # description, and step 5's `jj new` leaves exactly that state behind, so
  # passing it unconditionally makes an empty undescribed commit a permanent
  # ancestor of main and every future push dies with "Won't push commit …
  # since it has no description".
  if [ "$(jj -R "$fleet_vcs_repo" log -r @ --no-graph -T 'if(empty,"y","n")')" = n ]; then
    jj -R "$fleet_vcs_repo" describe -r @ -m "hand edit on $fleet_vcs_host: $(fleet_vcs_working_copy_files "$fleet_vcs_repo")

$(fleet_vcs_trailers "$fleet_vcs_host" interactive/human \
      'edit found in the working copy at run start' \
      "$(fleet_vcs_working_copy_files "$fleet_vcs_repo")")" >/dev/null
    set -- "$@" "$(jj -R "$fleet_vcs_repo" log -r @ --no-graph -T 'commit_id')"
  fi

  # Step 2. Merge every head, BY COMMIT ID. jj dedupes the duplicate that
  # appears when local and origin name the same commit.
  jj -R "$fleet_vcs_repo" new -m "reconcile $fleet_vcs_host

$(fleet_vcs_trailers "$fleet_vcs_host" "$fleet_vcs_session" "$fleet_vcs_intent" -)" \
    "$@" >/dev/null
  fleet_vcs_merge=$(jj -R "$fleet_vcs_repo" log -r @ --no-graph -T 'commit_id')

  # Step 3. Workbench off the merge either way.
  jj -R "$fleet_vcs_repo" new "$fleet_vcs_merge" >/dev/null
  if [ -z "$(fleet_vcs_conflicted "$fleet_vcs_repo" "$fleet_vcs_merge")" ]; then
    # A merge commit dominates every head and discards nothing.
    jj -R "$fleet_vcs_repo" bookmark set main -r "$fleet_vcs_merge" >/dev/null
    printf 'clean %s\n' "$fleet_vcs_merge"
  else
    printf 'conflicted %s\n' "$fleet_vcs_merge"
  fi
}

fleet_vcs_fold_resolution() {
  # §8.2 step 4: fleet_vcs_fold_resolution <store> [rationale-message]
  # Prints the published-ready merge. Same run when §8.2b resolved; a later
  # run when a human resolved after an escalation, which is why $M is
  # recovered from repo state rather than carried in a variable.
  #
  # RESOLVING IN A CHILD IS NOT ENOUGH. It leaves M permanently conflicted
  # and permanently an ancestor of every future main, so one conflict would
  # brick publication for the whole fleet. Squashing INTO M is what leaves
  # the push range conflict-free, and --use-destination-message is what keeps
  # it non-interactive.
  #
  # Because --use-destination-message keeps the DESTINATION's description,
  # the rationale §8.2b requires has to land on M before the squash, not on
  # the resolution child — the child's message is discarded.
  fleet_vcs_merge=$(jj -R "$1" log -r '@-' --no-graph -T 'commit_id')
  if [ -n "${2:-}" ]; then
    jj -R "$1" describe -r "$fleet_vcs_merge" -m "$2" >/dev/null
    fleet_vcs_merge=$(jj -R "$1" log -r '@-' --no-graph -T 'commit_id')
  fi
  jj -R "$1" squash --into "$fleet_vcs_merge" --use-destination-message >/dev/null
  fleet_vcs_merge=$(jj -R "$1" log -r '@-' --no-graph -T 'commit_id')
  # An empty workbench squashes to "Nothing changed" and leaves the merge
  # conflicted. The push guard would still catch it, but by then the bookmark
  # names a conflicted commit locally and the next run folds it in as a head —
  # so the refusal belongs BEFORE the bookmark moves, not after.
  [ -z "$(fleet_vcs_conflicted "$1" "$fleet_vcs_merge")" ] || {
    printf 'roundhouse: the merge is still conflicted after folding; the item stays held (§8.2b escalation)\n' >&2
    return 65
  }
  # AND IT MUST DOMINATE EVERY MAIN TARGET. `$M` is recovered as `@-` from repo
  # state, and `conflicts()` is not the only way that can be the wrong commit:
  # any conflicted non-merge under @ — an aborted `jj rebase`, a hand
  # `jj new A B` — satisfies step 0's revset, so the bookmark could be set to a
  # commit that never merged `main@origin` and the dropped head's unpushed
  # content would be excluded from every later reconcile. Publication would
  # then fail non-fast-forward AFTER the run had already applied and journaled.
  [ -z "$(jj -R "$1" log \
    -r "(heads(bookmarks(exact:\"main\")) | present(main@origin)) ~ ::$fleet_vcs_merge" \
    --no-graph -T 'commit_id ++ "\n"' 2>/dev/null)" ] || {
    printf 'roundhouse: the folded merge does not dominate every main target; refusing to move the bookmark (§8.2)\n' >&2
    return 65
  }
  jj -R "$1" bookmark set main -r "$fleet_vcs_merge" >/dev/null
  printf '%s\n' "$fleet_vcs_merge"
}

fleet_vcs_git_conflict_paths() {
  # The one sanctioned git read of store content, and it exists because jj's
  # own refusal is not self-enforcing: a raw `git push` from the colocated
  # repo bypasses it. `--allow-conflicts` publishes .jjconflict-base-0/,
  # .jjconflict-side-0/, .jjconflict-side-1/ and JJ-CONFLICT-README — the
  # whole tree three times over — and jj reconstitutes the native conflict so
  # `jj file list` never shows them. Verified: the git side carries all four.
  #
  # "NO CONFLICT PATHS" AND "git ERRORED" ARE DIFFERENT ANSWERS. The trailing
  # `|| true` collapsed them: a failed `git ls-tree` (unreadable ref, corrupt
  # object) read exactly like a clean tree, silently disarming the ONE guard
  # that catches a peer's raw `git push --allow-conflicts` (jj#9571) — the range
  # check cannot see that one, because there the conflicted commit IS
  # main@origin and the range is empty. Capture the tree, FAIL CLOSED (return 2)
  # on a git error, and only then grep.
  conflict_tree=$(git -C "$1" ls-tree -r --name-only "$2" 2>/dev/null) || return 2
  printf '%s\n' "$conflict_tree" |
    grep -E '^(\.jjconflict-|JJ-CONFLICT-README)' || true
}

fleet_vcs_publish() {
  # §8.2 step 5: fleet_vcs_publish <store> <target>. No conflicted commit is
  # ever pushed; history MAY contain a commit that was conflicted and was
  # resolved in place, which is exactly what step 4 produces.
  #
  # FOUR guards, and they live here rather than in the run because this is the
  # only line in the system that pushes. A guard in the callers is a guard the
  # next caller forgets.
  #
  # §10.6's private-remote gate first: it is about the remote, so it is cheaper
  # than the sweep and it is the one that must refuse before any content is
  # examined at all.
  fleet_first_push_gate "$1" || return $?
  # §10.4's redaction sweep over the range about to leave this machine.
  fleet_sweep_gate "$1" "$2" || return $?
  # Two more, because they see different things:
  fleet_vcs_range=$(jj -R "$1" log \
    -r "conflicts() & present(main@origin)..$2" --no-graph -T 'commit_id ++ "\n"')
  [ -z "$fleet_vcs_range" ] || {
    printf 'roundhouse: refusing to publish a conflicted commit: %s\n' \
      "$(printf '%s' "$fleet_vcs_range" | tr '\n' ' ')" >&2
    return 65
  }
  # …and the git tree, which is what catches an INBOUND published conflict:
  # the range revset cannot see that one, because there the conflicted commit
  # IS main@origin and the range is empty.
  fleet_vcs_leak=$(fleet_vcs_git_conflict_paths "$1" "$2") || {
    printf 'roundhouse: refusing to publish; the conflict-path check could not read the git tree at %s (§8.4)\n' \
      "$2" >&2
    return 65
  }
  [ -z "$fleet_vcs_leak" ] || {
    printf 'roundhouse: refusing to publish a tree carrying materialized conflict paths: %s\n' \
      "$(printf '%s' "$fleet_vcs_leak" | tr '\n' ' ')" >&2
    return 65
  }
  # …and the brick that recurs, diagnosed HERE rather than left to jj's own
  # refusal: an undescribed non-empty ancestor of the bookmark refuses to push
  # forever, and `fleet_run_prune_empty` abandons only commits that are empty
  # AND undescribed. Doctor has the row; the guard belongs on the one line that
  # pushes, so the operator learns which commit rather than that "something"
  # has no description.
  # `~ root()`: on a never-fetched store `present(main@origin)` is empty, so the
  # range degenerates to `::target` — which includes jj's VIRTUAL root commit.
  # It carries no tree and no description by construction and is never pushed,
  # so counting it would refuse every first push.
  fleet_vcs_undescribed=$(jj -R "$1" log -r "(present(main@origin)..$2) ~ root()" \
    --no-graph -T 'if(description, "", commit_id ++ "\n")' 2>/dev/null | grep . ||
    true)
  [ -z "$fleet_vcs_undescribed" ] || {
    printf 'roundhouse: refusing to publish; these commits carry no description and would refuse to push forever: %s\n' \
      "$(printf '%s' "$fleet_vcs_undescribed" | tr '\n' ' ')" >&2
    return 65
  }
  # THE ONE LINE THAT PUSHES. A failed push is never dressed as success — but a
  # CONCURRENT REMOTE MOVE is not a failure, it is the routine case the §6.1
  # cycle absorbs: another host pushed since this host last fetched, so
  # main@origin is stale and jj refuses the non-fast-forward (jj 0.44:
  # "references unexpectedly moved on the remote … (reason: stale info)").
  # `fleet-run` is immune because it fetches FIRST; a bare publisher
  # (fleet-rollback, fleet-add, fleet-checkpoint) never fetched. So recover HERE,
  # uniformly for every publisher: fetch, reconcile this host's work onto the
  # moved head through the SAME §8.2 path the run uses, and re-publish ONCE.
  # Never a force — that would stamp over the other host's push — and ONLY for
  # this class: auth, network, a no-description refusal and every other rejection
  # stay fail-closed exactly as the guards above intend. `$3 == no-recover` is
  # the internal one-shot guard so the retry cannot itself re-enter the recovery.
  fleet_vcs_pusherr=$(jj -R "$1" git push --bookmark main 2>&1 >/dev/null) || {
    fleet_vcs_pushrc=$?
    case $fleet_vcs_pusherr in
      *'stale info'* | *'unexpectedly moved'*)
        [ "${3:-}" != no-recover ] || {
          printf '%s\n' "$fleet_vcs_pusherr" >&2
          return "$fleet_vcs_pushrc"
        }
        fleet_vcs_fetch "$1" origin >/dev/null 2>&1 || {
          printf 'roundhouse: the remote moved and could not be re-fetched; nothing published\n' >&2
          return "$fleet_vcs_pushrc"
        }
        fleet_vcs_recout=$(fleet_vcs_reconcile "$1" "$(fleet_host_name)" \
          scheduled/agent 'republish after a concurrent remote move') || {
          printf 'roundhouse: could not reconcile after the remote moved; nothing published\n' >&2
          return 65
        }
        case $fleet_vcs_recout in
          conflicted\ *)
            # The moved head and this host's change contest the same value.
            # That is §8.2b's job, not a force here: hold publication and let the
            # next `fleet-run` resolve it (§8.1 step 0 adopts the merge).
            printf 'roundhouse: the remote moved and this change conflicts with it; run `roundhouse fleet-run` to reconcile (§8.2)\n' >&2
            return 65
            ;;
          clean\ *)
            fleet_vcs_publish "$1" "${fleet_vcs_recout#clean }" no-recover
            return $?
            ;;
          *)
            printf 'roundhouse: unexpected reconcile result after the remote moved: %s\n' \
              "$fleet_vcs_recout" >&2
            return 65
            ;;
        esac
        ;;
      *)
        # Genuine failure — auth, network, backwards move, hook refusal. Fail
        # closed, loud, non-zero: it must NOT be dressed as success.
        printf '%s\n' "$fleet_vcs_pusherr" >&2
        return "$fleet_vcs_pushrc"
        ;;
    esac
  }
  # Explicit target, not a bare `jj new`: `jj git push` leaves an empty
  # UNDESCRIBED working-copy commit of its own, and naming the target makes @
  # a child of the bookmark instead of a child of that leftover. This is the
  # line that keeps the §8.1 invariant true between runs, and it is what
  # preserves fleet-enroll's post-enrollment authorship: @ ends every run
  # empty, described by nothing, and parented on main.
  jj -R "$1" new "$2" >/dev/null
}

fleet_vcs_hold_set() {
  # §8.3, and it is a PURE function on purpose: fleet_vcs_hold_set
  # <head-count> reading "<item> <value-digest>" lines, one per head per item.
  # Prints `held <item>` or `converge <item> <digest>`.
  #
  # THE HEADS ARE THE BOOKMARK HEADS, recomputed — never parents($M). Step 1
  # may add the workbench as a third parent, so parents($M) is the heads PLUS
  # the operator's in-flight edit, and folding that in as an equal voice makes
  # an item she is halfway through editing read as a two-host disagreement and
  # get held.
  #
  # An item missing from one head is a difference like any other: it holds.
  # That is what keeps a removal from converging while the heads disagree
  # about whether the item exists at all.
  awk -v heads="$1" '
    {
      seen[$1]++
      if (!($1 in value)) value[$1] = $2
      else if (value[$1] != $2) differs[$1] = 1
    }
    END {
      for (item in seen) {
        if (differs[item] || seen[item] != heads) print "held " item
        else print "converge " item " " value[item]
      }
    }
  ' | LC_ALL=C sort
}

fleet_vcs_peer_remote_add() {
  # §8.5: fleet_vcs_peer_remote_add <store> <peer-host> <url>. Each peer is
  # its own jj remote, so main@origin and main@peer-wren are different refs
  # and the shipped `+refs/heads/*:refs/remotes/origin/*` peer refspec — the
  # thing that let one stale peer roll back everyone's view of main — is not
  # expressible here. That fix is deleting code.
  #
  # The URL comes out of store content and reaches jj as an argument, so it
  # is validated BEFORE any transport helper could be chosen by it.
  fleet_validate_fetch_url "$3" || {
    printf 'roundhouse: refusing an unusable peer URL for %s\n' "$2" >&2
    return 69
  }
  if jj -R "$1" git remote list 2>/dev/null | awk '{ print $1 }' |
    grep -Fqx "peer-$2"; then
    jj -R "$1" git remote set-url "peer-$2" "$3" >/dev/null
  else
    jj -R "$1" git remote add "peer-$2" "$3" >/dev/null
  fi
}

fleet_vcs_fetch() {
  jj -R "$1" git fetch --remote "$2" >/dev/null
}

fleet_vcs_op_id() {
  # §8.6: the run records its starting operation id so a bad local apply has
  # an abort button. Deliberately WITHOUT --ignore-working-copy: that flag
  # suppresses the colocated auto-import, so the newest operation predates jj
  # seeing the store's refs and restoring to it exports an empty view,
  # deleting the bookmarks outright.
  jj -R "$1" op log --no-graph --limit 1 -T 'id ++ "\n"'
}

fleet_vcs_op_restore() {
  # Local abort only. The op log is host-local, never pushed and erasable, so
  # it can never be the fleet mechanism — a fleet rollback is a signed revert
  # through the normal gates (§10.8).
  jj -R "$1" op restore "$2" >/dev/null
}
