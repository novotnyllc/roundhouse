# roundhouse self-check — §8: the reconcile point, the no-bare-`main` rule,
# the conflicted-bookmark runbook, the per-head hold set, and publication.
#
# Sourced by scripts/test-roundhouse in a fixed order, after
# tests/90-jj-bootstrap.sh whose real-jj gate this section reuses; not a
# standalone test file.
# shellcheck shell=bash

reconcile_root="$tmp/fleet-reconcile"
mkdir -p "$reconcile_root"

# --- §8.3's hold set and §5's trailer block: no jj ---
# The hold set decides what converges while a conflict is open, which is the
# part of §8 that is wrong most expensively, and it is a pure function on
# per-head values so it is tested as one.
(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # §8.3's worked run: one contested key and two uncontested ones in the same
  # conflicted file. The group-layer amplification is what this fixes — one
  # contested key must not hold every item the layer contributes.
  reconcile_verdicts=$(printf '%s\n' \
    'plugins.ponytail "1.6.0-a"' 'plugins.railyard "enabled"' 'plugins.legal "enabled"' \
    'plugins.ponytail "1.6.0-b"' 'plugins.railyard "enabled"' 'plugins.legal "absent"' |
    fleet_vcs_hold_set 2)
  [ "$(printf '%s\n' "$reconcile_verdicts" | tr '\n' '|')" = \
    'converge plugins.railyard "enabled"|held plugins.legal|held plugins.ponytail|' ] ||
    fail "§8.3 did not hold exactly the items that differ across heads: $reconcile_verdicts"

  # An item present at one head and missing at the other is a difference, not
  # a convergence: the heads disagree about whether it exists at all.
  reconcile_verdicts=$(printf '%s\n' 'plugins.new "enabled"' | fleet_vcs_hold_set 2)
  [ "$reconcile_verdicts" = 'held plugins.new' ] ||
    fail "§8.3 converged an item that only one head carries: $reconcile_verdicts"
  reconcile_verdicts=$(printf '%s\n' 'plugins.new "enabled"' | fleet_vcs_hold_set 1)
  [ "$reconcile_verdicts" = 'converge plugins.new "enabled"' ] ||
    fail "§8.3 held an item on a single head: $reconcile_verdicts"

  # §5's trailer block. Four trailers in a fixed order, and `roundhouse-items`
  # last so §10.8's `roundhouse-reverts` sits beside it.
  reconcile_trailers=$(fleet_vcs_trailers vireo scheduled/agent \
    'adopt upstream release' plugins.ponytail)
  [ "$(printf '%s\n' "$reconcile_trailers" | tr '\n' '|')" = \
    'roundhouse-host: vireo|roundhouse-session: scheduled/agent|roundhouse-intent: adopt upstream release|roundhouse-items: plugins.ponytail|' ] ||
    fail "the §5 trailer block is not the four trailers in order: $reconcile_trailers"
  fleet_vcs_trailers wren revert 'rollback' plugins.ponytail skwvtltpmpnz |
    grep -Fqx 'roundhouse-reverts: skwvtltpmpnz' ||
    fail "the revert trailer did not reach the block"
  # A newline inside the free-text trailer would end it and let the rest pose
  # as further trailers. The claims are unverifiable either way (§8.2b), but a
  # well-formed block is what lets a resolver parse the two it reads.
  [ "$(fleet_vcs_trailers vireo scheduled/agent 'one
roundhouse-session: interactive/human' plugins.x | grep -c '^roundhouse-session:')" -eq 1 ] ||
    fail "a newline in roundhouse-intent injected a second trailer"
)

# --- real jj: the runbook against two real diverged stores ---
if [ "$real_jj_ok" != true ]; then
  printf '\n'
  printf '========================================================================\n'
  printf 'NOTICE: real-jj reconcile block skipped\n'
  printf '  required: jj >= 0.43 and yq   found: jj %s, yq %s\n' \
    "${real_jj_version:-none}" "${real_yq:-none}"
  printf '  §8.1/§8.2 revsets and the conflicted-bookmark runbook are UNVERIFIED.\n'
  printf '========================================================================\n'
  printf '\n'
else
  printf 'real-jj: §8 revsets, runbook and publication guards (jj %s)\n' "$real_jj_version"
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

    rjj="$reconcile_root/real"
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
    export XDG_CONFIG_HOME="$rjj/xdg"

    # The fleet remote, standing in for the store's origin. Wiring a remote is
    # a later phase's verb; here it is fixture.
    "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"
    # §10.6's first-push gate sits in fleet_vcs_publish, so a fixture that
    # publishes has to have answered it. The gate itself — and the three-way
    # verdict behind this flag — is tested in tests/94-jj-doctor.sh; here the
    # posture is fixture, written at the ambient instance root because this
    # section drives two stores from one process.
    mkdir -p "$rjj/xdg/roundhouse/store.local"
    printf 'remote_visibility_verified: true\nremote_visibility_reason: auth-required\n' \
      >"$rjj/xdg/roundhouse/store.local/posture.yaml"

    reconcile_init() {
      # reconcile_init <name> — one host with its own instance root.
      env ROUNDHOUSE_FLEET_STORE="$rjj/$1/store" "$cli" fleet-init >/dev/null
      jj -R "$rjj/$1/store" git remote add origin "$rjj/remote.git" >/dev/null
    }
    reconcile_heads() { fleet_vcs_heads_local "$rjj/$1/store"; }
    reconcile_edit() {
      # reconcile_edit <host> <yaml> <summary> — a described commit on top of
      # whatever @ is, bookmarked but NOT published.
      printf '%s' "$2" >"$rjj/$1/store/groups.yaml"
      jj -R "$rjj/$1/store" describe -m "$3" >/dev/null
      jj -R "$rjj/$1/store" bookmark set main \
        -r "$(jj -R "$rjj/$1/store" log -r @ --no-graph -T 'commit_id')" >/dev/null
    }

    reconcile_init vireo
    vireo="$rjj/vireo/store"
    # §10.6 [rev]: the gate now binds posture to the remote URL it verified, so a
    # re-point can't reuse stale posture. Record the URL jj actually stores for
    # origin — derive it (mktemp paths are symlink-normalized by jj on macOS),
    # never hardcode. All hosts share this remote, so one write covers them.
    printf 'remote_visibility_verified: true\nremote_visibility_reason: auth-required\nremote_visibility_url: %s\n' \
      "$(fleet_remote_url "$vireo")" >"$rjj/xdg/roundhouse/store.local/posture.yaml"
    reconcile_edit vireo 'plugins:
  ponytail: v1
  railyard: enabled
' 'seed layers'
    fleet_vcs_publish "$vireo" "$(reconcile_heads vireo)" ||
      fail "the first push to a never-fetched remote failed"

    # The §8.1 invariant, and the state every run must end in: @ is an EMPTY
    # child of main, described by nothing, authored by this host now.
    reconcile_shape=$(jj -R "$vireo" log -r @ --no-graph \
      -T 'if(empty,"empty","dirty") ++ " " ++ if(description,"described","undescribed") ++ " " ++ parents.map(|p| p.commit_id()).join(",") ++ " " ++ author.email()')
    [ "$reconcile_shape" = \
      "empty undescribed $(reconcile_heads vireo) $(jj -R "$vireo" config get user.email)" ] ||
      fail "a completed run did not leave @ an empty child of main with this host's authorship: $reconcile_shape"

    # Host 2 clones what host 1 published.
    jj git clone --colocate --config ui.editor='"true"' \
      --config ui.paginate=never "$rjj/remote.git" "$rjj/wren/store" >/dev/null 2>&1 ||
      fail "could not clone the fleet store for the second host"
    env ROUNDHOUSE_FLEET_STORE="$rjj/wren/store" "$cli" fleet-init >/dev/null
    wren="$rjj/wren/store"

    # 1. Both hosts move main. vireo publishes; wren does not fetch first.
    reconcile_edit vireo 'plugins:
  ponytail: v2-vireo
  railyard: enabled
  legal: enabled
' 'vireo edit'
    fleet_vcs_publish "$vireo" "$(reconcile_heads vireo)" ||
      fail "vireo could not publish its edit"
    reconcile_edit wren 'plugins:
  ponytail: v2-wren
  railyard: enabled
' 'wren edit'
    jj -R "$wren" new "$(reconcile_heads wren)" >/dev/null
    fleet_vcs_fetch "$wren" origin

    # 2. THE NO-BARE-`main` RULE, executed rather than grepped. Every revset
    #    the run uses must exit 0 against a conflicted bookmark, and the bare
    #    read must fail — that is the check §8.1 says is the real one.
    reconcile_status=0
    jj -R "$wren" log -r main --no-graph -T 'commit_id' >/dev/null 2>&1 ||
      reconcile_status=$?
    [ "$reconcile_status" -ne 0 ] ||
      fail "a bare \`main\` revset read succeeded against a conflicted bookmark — §8.1's rule no longer has a reason"
    [ "$(reconcile_heads wren | grep -c .)" -eq 2 ] ||
      fail "heads(bookmarks(exact:\"main\")) did not return both heads of a conflicted bookmark"
    [ -n "$(fleet_vcs_head_origin "$wren")" ] ||
      fail "present(main@origin) came back empty on a fetched store"
    [ -z "$(fleet_vcs_resolution_workbench "$wren")" ] ||
      fail "the §8.1 exemption fired before any resolution workbench existed"

    # 3. A pending hand edit in @ must survive the merge, and must be
    #    described or the push refuses forever.
    printf 'x: 1\n' >"$wren/testing.yaml"
    reconcile_out=$(fleet_vcs_reconcile "$wren" wren scheduled/agent \
      'reconcile diverged main') ||
      fail "the reconcile runbook failed on a conflicted bookmark"
    reconcile_merge=${reconcile_out#* }
    [ "${reconcile_out%% *}" = conflicted ] ||
      fail "the runbook did not report the contested merge as conflicted: $reconcile_out"
    [ -f "$wren/testing.yaml" ] ||
      fail "the operator's pending hand edit left the working copy (§8.2 step 1)"
    jj -R "$wren" log -r "$reconcile_merge" --no-graph -T 'parents.len()' |
      grep -qx 3 ||
      fail "the merge did not take both heads plus the non-empty working copy as parents"

    # 4. The §8.1 exemption now fires, from repo state alone — $M, $WC and
    #    $LOCAL do not survive between runs, and step 0 has to resume anyway.
    [ "$(fleet_vcs_resolution_workbench "$wren")" = "$reconcile_merge" ] ||
      fail "the resolution workbench is not readable from repo state after the merge"

    # 5. §8.3: per-head reads are clean YAML while the merge is conflicted,
    #    and the conflicted commit's own content is not.
    reconcile_values=""
    for reconcile_head in $(reconcile_heads wren); do
      reconcile_side=$(jj -R "$wren" file show -r "$reconcile_head" \
        'root:groups.yaml' | yq -o=json -I=0 '.plugins' 2>/dev/null) ||
        fail "a per-head read of a conflicted file did not parse as YAML"
      reconcile_values="$reconcile_values$(printf '%s\n' "$reconcile_side" |
        jq -r 'to_entries[] | "plugins." + .key + " " + (.value | tostring)')
"
    done
    ! jj -R "$wren" file show -r "$reconcile_merge" 'root:groups.yaml' |
      yq -e '.' >/dev/null 2>&1 ||
      fail "the conflicted commit's own content parsed as YAML — the markers are gone"
    reconcile_held=$(printf '%s' "$reconcile_values" | fleet_vcs_hold_set 2)
    printf '%s\n' "$reconcile_held" | grep -qx 'held plugins.ponytail' ||
      fail "the contested key did not land in the hold set: $reconcile_held"
    printf '%s\n' "$reconcile_held" | grep -qx 'converge plugins.railyard enabled' ||
      fail "an uncontested key in the same conflicted file was held: $reconcile_held"

    # 6. Publication is refused while the conflict is open, by BOTH guards.
    reconcile_status=0
    fleet_vcs_publish "$wren" "$reconcile_merge" >/dev/null 2>&1 ||
      reconcile_status=$?
    [ "$reconcile_status" -eq 65 ] ||
      fail "a conflicted commit was publishable (got $reconcile_status)"
    reconcile_leak=$(fleet_vcs_git_conflict_paths "$wren" "$reconcile_merge")
    printf '%s\n' "$reconcile_leak" | grep -q '^\.jjconflict-side-0/' ||
      fail "the git tree of a conflicted commit no longer carries .jjconflict-* — re-derive the §8.4 doctor check"
    ! jj -R "$wren" file list -r "$reconcile_merge" -T 'path ++ "\n"' |
      grep -q jjconflict ||
      fail "jj started showing the materialized conflict paths, so `jj file list` would now be a usable check"

    # 7a. Folding an EMPTY workbench must refuse before the bookmark moves.
    #     "Nothing changed" leaves the merge conflicted, and a local `main`
    #     naming a conflicted commit becomes a head of the next run.
    reconcile_status=0
    fleet_vcs_fold_resolution "$wren" >/dev/null 2>&1 || reconcile_status=$?
    [ "$reconcile_status" -eq 65 ] ||
      fail "folding an unresolved conflict was accepted (got $reconcile_status)"
    [ "$(fleet_vcs_heads_local "$wren" | grep -c .)" -eq 2 ] ||
      fail "the refused fold still moved the bookmark onto a conflicted commit"

    # 7. §8.2 step 4: resolve in @, fold INTO the merge, publish. Resolving in
    #    a CHILD leaves M permanently conflicted and permanently an ancestor
    #    of every future main — one conflict would brick the whole fleet.
    printf 'plugins:\n  ponytail: v2-vireo\n  railyard: enabled\n  legal: enabled\n' \
      >"$wren/groups.yaml"
    reconcile_final=$(fleet_vcs_fold_resolution "$wren" "resolve plugins.ponytail at v2-vireo

$(fleet_vcs_trailers wren scheduled/agent 'rule 4: applied elsewhere and not withdrawn' plugins.ponytail)")
    [ -z "$(fleet_vcs_conflicted "$wren" "$reconcile_final")" ] ||
      fail "the folded merge is still conflicted"
    # --use-destination-message keeps the DESTINATION's description, so the
    # rationale has to be on the merge itself and not on the resolution child.
    jj -R "$wren" log -r "$reconcile_final" --no-graph -T 'description' |
      grep -q 'rule 4: applied elsewhere' ||
      fail "the resolution rationale did not survive the squash"
    [ -z "$(jj -R "$wren" log -r "conflicts() & present(main@origin)..$reconcile_final" \
      --no-graph -T 'commit_id')" ] ||
      fail "the push range still carries a conflicted commit after the fold"
    fleet_vcs_publish "$wren" "$reconcile_final" ||
      fail "the resolved merge could not be published"
    [ "$(jj -R "$wren" log -r @ --no-graph \
      -T 'if(empty,"empty","dirty") ++ " " ++ parents.map(|p| p.commit_id()).join(",")')" = \
      "empty $reconcile_final" ] ||
      fail "the run did not end with @ an empty child of the published main"
    # The operator's pending file rode the merge all the way to origin.
    jj -R "$wren" file list -r "$reconcile_final" -T 'path ++ "\n"' |
      grep -qx testing.yaml ||
      fail "the operator's hand edit did not reach the published commit"

    # 8. §8.6: the abort button for a bad local apply. Host-local, never the
    #    fleet mechanism.
    reconcile_op=$(fleet_vcs_op_id "$wren")
    [ -n "$reconcile_op" ] || fail "no starting operation id was recorded"
    printf 'oops: 1\n' >"$wren/groups.yaml"
    jj -R "$wren" describe -m 'bad local apply' >/dev/null
    fleet_vcs_op_restore "$wren" "$reconcile_op"
    grep -q ponytail "$wren/groups.yaml" ||
      fail "jj op restore did not undo the bad local apply"
    [ -n "$(fleet_vcs_heads_local "$wren")" ] ||
      fail "jj op restore deleted the bookmarks (the --ignore-working-copy trap)"

    # 9. §8.5: peers are namespaced remotes, and the URL is validated before
    #    anything can choose a transport helper from it.
    fleet_vcs_peer_remote_add "$wren" vireo "$rjj/vireo/store" ||
      fail "a valid peer remote was refused"
    fleet_vcs_fetch "$wren" peer-vireo
    [ -n "$(jj -R "$wren" log -r 'present(main@peer-vireo)' --no-graph -T 'commit_id')" ] ||
      fail "the peer's main is not reachable as main@peer-vireo"
    reconcile_status=0
    fleet_vcs_peer_remote_add "$wren" evil 'ext::sh -c touch% /tmp/pwn' \
      >/dev/null 2>&1 || reconcile_status=$?
    [ "$reconcile_status" -eq 69 ] ||
      fail "a hostile peer URL was not refused with 69 (got $reconcile_status)"
    ! jj -R "$wren" git remote list | grep -q '^peer-evil' ||
      fail "a hostile peer URL still created a remote"

    # 10. The R4 leak state: an INBOUND published conflict. The exemption
    #     revset must go empty, so the run falls through to hold-and-alert
    #     rather than squash-resolving and republishing a conflict its
    #     operator never saw. Reachability is what makes that true —
    #     the committer field this replaced was self-asserted and spoofable.
    jj git clone --colocate --config ui.editor='"true"' \
      --config ui.paginate=never "$rjj/remote.git" "$rjj/leak/store" >/dev/null 2>&1
    leak="$rjj/leak/store"
    printf 'plugins:\n  ponytail: v3-leak\n  railyard: enabled\n' >"$leak/groups.yaml"
    jj -R "$leak" describe -m 'leak edit' >/dev/null
    jj -R "$leak" bookmark set main -r @ >/dev/null
    jj -R "$leak" new "$(jj -R "$leak" log -r @ --no-graph -T 'commit_id')" >/dev/null
    # vireo catches up first, which is also the CLEAN path of the runbook: a
    # merge commit dominates every head and discards nothing, so the bookmark
    # moves in the same call.
    fleet_vcs_fetch "$vireo" origin
    reconcile_out=$(fleet_vcs_reconcile "$vireo" vireo scheduled/agent 'catch up')
    [ "${reconcile_out%% *}" = clean ] ||
      fail "an uncontested reconcile did not come back clean: $reconcile_out"
    [ "$(reconcile_heads vireo)" = "${reconcile_out#* }" ] ||
      fail "the clean path did not move the bookmark to the merge"
    fleet_vcs_publish "$vireo" "${reconcile_out#* }" ||
      fail "vireo could not publish its catch-up merge"
    reconcile_edit vireo 'plugins:
  ponytail: v3-vireo
  railyard: enabled
  legal: enabled
' 'vireo third edit'
    fleet_vcs_publish "$vireo" "$(reconcile_heads vireo)" ||
      fail "vireo could not publish its third edit"
    fleet_vcs_fetch "$leak" origin
    reconcile_out=$(fleet_vcs_reconcile "$leak" leak scheduled/agent 'leak probe')
    reconcile_leak_merge=${reconcile_out#* }
    [ "$(fleet_vcs_resolution_workbench "$leak")" = "$reconcile_leak_merge" ] ||
      fail "a locally created conflicted merge was not recognised as this host's workbench"
    jj -R "$leak" bookmark set published-conflict -r "$reconcile_leak_merge" >/dev/null
    jj -R "$leak" git push --allow-conflicts --bookmark published-conflict >/dev/null 2>&1 ||
      fail "could not stage the published-conflict fixture"
    fleet_vcs_fetch "$leak" origin
    [ -z "$(fleet_vcs_resolution_workbench "$leak")" ] ||
      fail "the §8.1 exemption fired on a conflicted merge reachable from a remote bookmark (the R4 leak)"

    # 11. §8.2b RULE 2, AGAINST A REAL REPOSITORY. `73-ladder.sh` feeds the
    #     ladder session strings directly, so nothing asserted that
    #     `fleet_run_side` can ever PRODUCE `interactive/human` from history —
    #     and it could not. Roundhouse stamps every head it publishes
    #     `scheduled/agent`, and §8.2 step 1 folds the operator's hand edit in
    #     as a PARENT of the merge, so reading the trailer at the tip found
    #     `scheduled/agent` on both sides every time. Rule 2 never fired, the
    #     ladder arbitrated, and the hand edit SILENTLY LOST — the exact
    #     inverse of the trade §8.2b names ("a genuine hand edit conflicting
    #     with an agent edit escalates instead of silently winning").
    reconcile_side="$rjj/side"
    mkdir -p "$reconcile_side"
    env ROUNDHOUSE_FLEET_STORE="$reconcile_side/store" "$cli" fleet-init >/dev/null
    side="$reconcile_side/store"
    # REAL LAYER PATHS: `fleet_run_side` folds the exported tree, and
    # `fleet_run_export` keeps only what `fleet_run_layer_path` admits — a
    # `groups.yaml` at the store root is not one, and both sides would fold to
    # null and agree at rule 1.
    mkdir -p "$side/hosts"
    printf 'platform: macos\ngroups: []\n' >"$side/hosts/vireo.yaml"
    printf 'plugins:\n  ponytail: base\n' >"$side/fleet.yaml"
    jj -R "$side" describe -m "base

$(fleet_vcs_trailers vireo scheduled/agent 'base' -)" >/dev/null
    reconcile_base=$(jj -R "$side" log -r @ --no-graph -T 'commit_id')
    # The operator's hand edit, described exactly as §8.2 step 1 describes it…
    jj -R "$side" new "$reconcile_base" >/dev/null
    printf 'plugins:\n  ponytail: claire\n' >"$side/fleet.yaml"
    jj -R "$side" describe -m "hand edit on vireo

$(fleet_vcs_trailers vireo interactive/human 'edit found in the working copy at run start' fleet.yaml)" \
      >/dev/null
    reconcile_hand=$(jj -R "$side" log -r @ --no-graph -T 'commit_id')
    # …and then the run publishes on top of it, stamped scheduled/agent, which
    # is what makes the head agent-sessioned and the human marker a parent.
    jj -R "$side" new "$reconcile_hand" >/dev/null
    printf 'plugins:\n  ponytail: claire\n  railyard: enabled\n' >"$side/fleet.yaml"
    jj -R "$side" describe -m "converge on vireo

$(fleet_vcs_trailers vireo scheduled/agent 'fast convergence' -)" >/dev/null
    reconcile_mine=$(jj -R "$side" log -r @ --no-graph -T 'commit_id')
    # The peer's side: agent all the way down.
    jj -R "$side" new "$reconcile_base" >/dev/null
    printf 'plugins:\n  ponytail: wren\n' >"$side/fleet.yaml"
    jj -R "$side" describe -m "converge on wren

$(fleet_vcs_trailers wren scheduled/agent 'fast convergence' -)" >/dev/null
    reconcile_theirs=$(jj -R "$side" log -r @ --no-graph -T 'commit_id')

    # Reading the TIP is what was wrong, and it is asserted here so a
    # regression cannot hide behind the range read below.
    [ "$(fleet_run_trailer "$side" "$reconcile_mine" roundhouse-session)" = \
      scheduled/agent ] ||
      fail "the fixture's own head is not agent-sessioned; the case has changed shape"
    # Reading the side's UNIQUE RANGE finds the human two commits down.
    [ "$(fleet_run_side_session "$side" "$reconcile_mine" "$reconcile_theirs")" = \
      interactive/human ] ||
      fail "§8.2b rule 2 cannot see a hand edit folded in as a parent of the head"
    [ "$(fleet_run_side_session "$side" "$reconcile_theirs" "$reconcile_mine")" = \
      scheduled/agent ] ||
      fail "an all-agent side was reported as human, so rule 2 would escalate everything"

    # …and end to end through the ladder: EITHER side reading human escalates.
    printf 'vireo\nwren\n' >"$reconcile_side/hosts"
    mkdir -p "$reconcile_side/work"
    fleet_run_export "$side" "$reconcile_mine" "$reconcile_side/mine"
    fleet_run_export "$side" "$reconcile_theirs" "$reconcile_side/theirs"
    reconcile_verdict=$(fleet_run_evidence plugins.ponytail 1500 \
      "$(fleet_run_side "$side" "$reconcile_mine" plugins.ponytail vireo \
        "$reconcile_side/hosts" "$reconcile_side/work" "$reconcile_side/mine" \
        "$reconcile_theirs")" \
      "$(fleet_run_side "$side" "$reconcile_theirs" plugins.ponytail vireo \
        "$reconcile_side/hosts" "$reconcile_side/work" "$reconcile_side/theirs" \
        "$reconcile_mine")" | fleet_resolve_decide)
    [ "$(printf '%s\n' "$reconcile_verdict" | jq -r '.verdict')" = escalate ] &&
      [ "$(printf '%s\n' "$reconcile_verdict" | jq -r '.rule')" = 2 ] ||
      fail "a real hand edit against an agent edit did not escalate at rule 2: $reconcile_verdict"

    printf 'real-jj: OK (no bare main, conflicted-bookmark revsets, runbook steps 0-5, hold set, both push guards, op restore, peer remotes, R4 leak, rule 2 over a side range)\n'
  ) || fail "real-jj reconcile block failed (see the FAIL: real-jj: line above)"
fi
