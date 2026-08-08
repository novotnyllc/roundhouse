# roundhouse self-check — §5 and §10 record shapes: journal, ownership,
# alerts, proposals, lineage, upstreams, the canary gate and the removal caps.
#
# Every shape here is evidence, never authorization. The fixtures are pure
# file state, so the arithmetic that decides whether a machine uninstalls
# something is exercised without a repository anywhere near it.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'records: §5 shapes, §10 ownership, canary, caps\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    rec_store="$tmp/records/store"
    mkdir -p "$rec_store"

    # --- §5 journal/<host>/<date>.yaml ---
    rec_entry() { jq -cn --args '$ARGS.positional | {
      item: .[0], digest: .[1], outcome: .[2], at: .[3]}' "$@"; }

    fleet_journal_append "$rec_store" vireo \
      "$(jq -cn '{item: "plugins.railyard", digest: "4f1c9a02e8",
        outcome: "applied", change: "qpvuntsmwlqt", commit: "8a3f19c4bb21",
        at: "2026-08-07T09:14:02Z"}')" ||
      fail "a well-formed journal entry was refused"
    fleet_journal_append "$rec_store" vireo \
      "$(rec_entry skills.legal b71e held 2026-08-07T09:14:05Z)" ||
      fail "a held journal entry was refused"
    rec_journal="$rec_store/journal/vireo/2026-08-07.yaml"
    [ -f "$rec_journal" ] ||
      fail "the journal file was not named for the record's own date"
    [ "$(fleet_journal_entries "$rec_store" vireo | grep -c .)" -eq 2 ] ||
      fail "the journal did not append"

    # --- THE ONE-BYTE TRUNCATION, which was signed and pushed to every peer ---
    # Every caller composes its argument as `fleet_record_read … | jq …` inside
    # a command substitution, and this program sets no `pipefail`. When yq
    # fails on an unparsable or conflict-markered file, jq reads empty stdin,
    # prints nothing and exits 0 — and `printf '' | yq -P -p=json` SUCCEEDS
    # too, so the writer's own error branch never fired and safe_output
    # atomically installed a one-byte file over the record. Measured: a
    # 122-byte journal became 1 byte, rc 0.
    #
    # `ui.conflict-marker-style = snapshot` is pinned and `journal/` sits
    # outside fleet_run_layer_path, so nothing else validates these files —
    # and the conflicted path is exactly where the run writes `held` records.
    rec_conflicted="$rec_store/journal/wren/2026-08-07.yaml"
    mkdir -p "$(dirname "$rec_conflicted")"
    cat >"$rec_conflicted" <<'YAML'
<<<<<<< Conflict 1 of 1
- item: plugins.ponytail
  digest: aaaa
=======
- item: plugins.ponytail
  digest: bbbb
>>>>>>> side #2
YAML
    rec_size=$(wc -c <"$rec_conflicted" | tr -d ' ')
    rec_rc=0
    fleet_journal_append "$rec_store" wren \
      "$(rec_entry plugins.ponytail cccc applied 2026-08-07T10:00:00Z)" \
      2>/dev/null || rec_rc=$?
    [ "$rec_rc" -ne 0 ] ||
      fail "appending to an unparsable journal reported success"
    [ "$(wc -c <"$rec_conflicted" | tr -d ' ')" -eq "$rec_size" ] ||
      fail "an unparsable journal was TRUNCATED by the writer rather than refused"

    # …and READING that conflicted day-file is signalled, not silently skipped.
    # §10.1 canary condition 2 ("nothing withdrew it") is a claim about the WHOLE
    # journal, and a `held`/`reverted` record lands in exactly the conflicted
    # file; skipping it read clean off the files that parse. A parseable applied
    # record for the same host would otherwise satisfy the gate on its own.
    printf '%s\n' '- {item: plugins.ponytail, digest: cccc, outcome: applied, at: 2020-01-01T00:00:00Z}' \
      >"$rec_store/journal/wren/2020-01-01.yaml"
    rec_rc=0
    fleet_journal_entries "$rec_store" wren >/dev/null 2>&1 || rec_rc=$?
    [ "$rec_rc" -ne 0 ] ||
      fail "the journal reader silently skipped an unparsable day-file"
    # the canary gate over wren FAILS CLOSED: partial evidence cannot promote.
    ! fleet_canary_gate "$rec_store" plugins.ponytail cccc 0 \
      2026-08-07T10:00:00Z wren 2>/dev/null ||
      fail "the canary gate promoted on a host with an unreadable day-file"

    # Losing applied/<h>.yaml makes the host disown everything roundhouse
    # installed — §5 calls that record "the ONLY thing that makes a removal
    # legal" — so the same guard is asserted on the ownership record.
    rec_applied=$(fleet_applied_path "$rec_store" corvid)
    mkdir -p "$(dirname "$rec_applied")"
    printf 'items: {a: {digest: x}}\n:::not yaml\n' >"$rec_applied"
    rec_size=$(wc -c <"$rec_applied" | tr -d ' ')
    rec_rc=0
    fleet_applied_record "$rec_store" corvid plugins.b bbbb 2026-08-07T10:00:00Z \
      2>/dev/null || rec_rc=$?
    [ "$rec_rc" -ne 0 ] ||
      fail "recording into an unparsable applied/<h>.yaml reported success"
    [ "$(wc -c <"$rec_applied" | tr -d ' ')" -eq "$rec_size" ] ||
      fail "an unparsable applied/<h>.yaml was truncated rather than refused"
    rm -f "$rec_applied" "$rec_conflicted"

    # The writer refuses an EMPTY value outright, which is the shape every one
    # of the above collapses to.
    rec_rc=0
    fleet_record_write "$rec_store/empty-probe.yaml" '' 2>/dev/null || rec_rc=$?
    [ "$rec_rc" -ne 0 ] ||
      fail "the record writer accepted an empty document"
    [ ! -f "$rec_store/empty-probe.yaml" ] ||
      fail "the record writer created a file for an empty document"
    # It is a human-first YAML document, not a JSON blob in a .yaml file.
    grep -Fq -- '- item: plugins.railyard' "$rec_journal" ||
      fail "the journal was not written as a YAML sequence"

    # `alive` is a run-level heartbeat with NO item, written once per
    # completed run. §10.1's liveness term needs it.
    fleet_journal_append "$rec_store" vireo \
      "$(jq -cn '{outcome: "alive", at: "2026-08-07T09:20:00Z"}')" ||
      fail "an alive heartbeat was refused"
    ! fleet_journal_append "$rec_store" vireo \
      "$(jq -cn '{outcome: "alive", item: "plugins.railyard", at: "2026-08-07T09:21:00Z"}')" \
      2>/dev/null || fail "an alive heartbeat carrying an item was accepted"

    # `outcome: unreachable` with `source: none` is §6/convergence.md's
    # dark-run record: the remote could not be reached, the host converged from
    # last known and fetched nothing. Run-level like the heartbeat — no item.
    fleet_journal_append "$rec_store" vireo \
      "$(jq -cn '{outcome: "unreachable", source: "none", at: "2026-08-07T09:22:00Z"}')" ||
      fail "a source: none dark-run record was refused"
    ! fleet_journal_append "$rec_store" vireo \
      "$(jq -cn '{outcome: "unreachable", at: "2026-08-07T09:23:00Z"}')" 2>/dev/null ||
      fail "an unreachable record with no source was accepted"
    ! fleet_journal_append "$rec_store" vireo \
      "$(jq -cn '{outcome: "unreachable", source: "none", item: "plugins.x", at: "2026-08-07T09:24:00Z"}')" \
      2>/dev/null || fail "an unreachable record carrying an item was accepted"

    # `outcome: resolved` names BOTH parents by change id, plus the resolution
    # commit whose description carries the rationale.
    rec_resolved=$(jq -cn '{item: "plugins.railyard", digest: "9c14ab77e2",
      outcome: "resolved",
      sides: [{change: "knzkquxztzss", host: "vireo", session: "scheduled/agent",
               at: "2026-08-07T08:02:11Z"},
              {change: "nzqoyoprnokz", host: "wren", session: "scheduled/agent",
               at: "2026-08-07T08:14:47Z"}],
      resolution: "qpvuntsmwlqt", at: "2026-08-07T09:14:09Z"}')
    fleet_journal_append "$rec_store" vireo "$rec_resolved" ||
      fail "a resolution record was refused"
    ! fleet_journal_append "$rec_store" vireo \
      "$(printf '%s\n' "$rec_resolved" | jq -c 'del(.sides[1])')" 2>/dev/null ||
      fail "a resolution record naming only one side was accepted"
    ! fleet_journal_append "$rec_store" vireo \
      "$(printf '%s\n' "$rec_resolved" | jq -c 'del(.resolution)')" 2>/dev/null ||
      fail "a resolution record with no resolution commit was accepted"

    # The three fields rev 1 published and this design moved to store.run/.
    for rec_banned in signer layers held_reason schema schema_version; do
      ! fleet_journal_append "$rec_store" vireo \
        "$(rec_entry plugins.x d1 applied 2026-08-07T09:30:00Z |
          jq -c --arg k "$rec_banned" '.[$k] = "x"')" 2>/dev/null ||
        fail "a journal entry carrying $rec_banned was accepted"
    done
    ! fleet_journal_append "$rec_store" vireo \
      "$(rec_entry plugins.x d1 wibble 2026-08-07T09:30:00Z)" 2>/dev/null ||
      fail "a journal entry with an unknown outcome was accepted"

    # NO schema keys anywhere, in the records or in the code that writes them.
    ! grep -rqE '^\s*schema(_version)?:' "$rec_store" ||
      fail "a replicated record carries a schema key"
    ! grep -vE '^ *#' "$(dirname -- "$cli")/lib/fleet-records.sh" |
      grep -qE '(^|[^a-z_])schema(_version)?:' ||
      fail "the records unit emits a schema key"

    # --- §10.3 applied/<host>.yaml and the five ownership rows ---
    fleet_applied_record "$rec_store" vireo plugins.ponytail 91ac33 \
      2026-08-06T09:14:12Z
    fleet_applied_record "$rec_store" vireo plugins.railyard 4f1c9a02e8 \
      2026-08-07T09:14:12Z
    [ "$(fleet_applied_digest "$rec_store" vireo plugins.ponytail)" = 91ac33 ] ||
      fail "the ownership record did not read back"
    [ "$(fleet_applied_count "$rec_store" vireo)" -eq 2 ] ||
      fail "the ownership record miscounted the applied set"
    grep -Fq 'plugins.ponytail:' "$(fleet_applied_path "$rec_store" vireo)" ||
      fail "the ownership record is not a hand-editable YAML map"
    fleet_applied_forget "$rec_store" vireo plugins.ponytail
    [ -z "$(fleet_applied_digest "$rec_store" vireo plugins.ponytail)" ] ||
      fail "forgetting an item left it in the ownership record"

    [ "$(fleet_ownership_action yes no no na)" = adopt ] ||
      fail "row 1 (in layers, unowned, absent) is not adopt"
    # Row 2, the one rev 1 omitted: the state a HOST REINSTALL produces.
    [ "$(fleet_ownership_action yes no yes yes)" = adopt-in-place ] ||
      fail "row 2 with a matching digest is not a silent adopt in place"
    [ "$(fleet_ownership_action yes no yes no)" = adopt-in-place-review ] ||
      fail "row 2 with a mismatching digest does not go to review"
    [ "$(fleet_ownership_action yes yes yes yes)" = nothing ] ||
      fail "an item already applied at the desired digest is not left alone"
    [ "$(fleet_ownership_action yes yes yes no)" = changed ] ||
      fail "a changed digest does not go to review"
    [ "$(fleet_ownership_action no yes yes na)" = prune ] ||
      fail "an item that left the layers is not a prune candidate"
    # The row with a body count attached: never touch what was never ours.
    [ "$(fleet_ownership_action no no yes na)" = untouched ] ||
      fail "software roundhouse never installed was not left alone"

    # --- §10.3 the removal caps, whichever is smaller ---
    # 20 applied, fraction 0.25 -> 5, per-run 5: the two agree.
    fleet_removal_cap 5 20 5 0.25 >/dev/null ||
      fail "a removal set exactly at the cap was held"
    ! fleet_removal_cap 6 20 5 0.25 >/dev/null 2>&1 ||
      fail "a removal set over the count cap was allowed"
    # 8 applied, fraction 0.25 -> 2: the FRACTION binds, not the count.
    [ "$(fleet_removal_cap 2 8 5 0.25)" = 2 ] ||
      fail "the smaller of the two caps did not bind"
    ! fleet_removal_cap 3 8 5 0.25 >/dev/null 2>&1 ||
      fail "a removal set over the fraction cap was allowed"
    # 100 applied, fraction 0.25 -> 25: the COUNT binds.
    [ "$(fleet_removal_cap 5 100 5 0.25)" = 5 ] ||
      fail "the count cap did not bind on a large applied set"
    # Neither catches a one-line deletion, and nothing should: that is a
    # legitimate edit and its defence is apply-time review naming the item.
    fleet_removal_cap 1 100 5 0.25 >/dev/null ||
      fail "a one-line deletion was held by a blast-radius cap"

    # --- §5 alerts, §10.4 findings, and the redaction floor ---
    fleet_alert_write "$rec_store" vireo unsigned-edit unsigned-hand-edit \
      'Commit 6705e1a3 carries no SSH signature.' plugins.impeccable ||
      fail "a clean alert was refused"
    rec_alert=$(find "$rec_store/alerts/vireo" -name '*-unsigned-hand-edit.yaml' | head -1)
    [ -n "$rec_alert" ] ||
      fail "the alert was not written under alerts/<host>/<stamp>-<slug>.yaml"
    [ "$(yq -r '.kind' "$rec_alert")" = unsigned-edit ] &&
      [ "$(yq -r '.items[0]' "$rec_alert")" = plugins.impeccable ] ||
      fail "the alert did not carry its kind and the items it holds"

    # A quote that trips the floor is REFUSED, not silently redacted: §10.4's
    # own remedy explicitly cannot un-publish.
    for rec_secret in 'token ghp_abcdefghijklmnopqrstuvwxyz0123' \
      'key -----BEGIN OPENSSH PRIVATE KEY-----'; do
      ! fleet_alert_write "$rec_store" vireo leak leaky "$rec_secret" 2>/dev/null ||
        fail "a secret class reached a replicated record: $rec_secret"
    done
    ! fleet_finding_write "$rec_store" vireo leaky 'summary' \
      'export KEY=sk-abcdefghijklmnop0123' 2>/dev/null ||
      fail "a secret class reached a replicated finding quote"
    # ...and the 400-byte cap on every replicated free-text field.
    rec_long=$(printf 'a%.0s' $(seq 1 401))
    ! fleet_alert_write "$rec_store" vireo verbose wordy "$rec_long" 2>/dev/null ||
      fail "a replicated field over 400 bytes was accepted"
    fleet_alert_write "$rec_store" vireo terse fits "$(printf 'a%.0s' $(seq 1 400))" ||
      fail "a replicated field exactly at the 400-byte cap was refused"
    fleet_finding_write "$rec_store" vireo clean 'the plugin update landed cleanly' ||
      fail "a clean finding was refused"

    # --- §10.2 proposals and unanimity ---
    fleet_proposal_unanimous '[{"host":"vireo","value":"enabled"},
      {"host":"wren","value":"enabled"},{"host":"iris-wsl","value":"enabled"}]' ||
      fail "an item with an identical value on every enrolled host was not unanimous"
    ! fleet_proposal_unanimous '[{"host":"vireo","value":"enabled"},
      {"host":"wren","value":"enabled"},{"host":"iris-wsl","value":"disabled"}]' ||
      fail "a disagreement was promoted"
    # A host that does not carry the item at all is not agreement.
    ! fleet_proposal_unanimous '[{"host":"vireo","value":"enabled"},
      {"host":"wren","value":"enabled"},{"host":"iris-wsl","value":null}]' ||
      fail "a host with no opinion counted toward unanimity"
    ! fleet_proposal_unanimous '[{"host":"vireo","value":"enabled"}]' ||
      fail "a one-host fleet produced a promotion proposal"

    fleet_proposal_write "$rec_store" promote-ponytail-to-fleet plugins.ponytail \
      '"enabled"' fleet.yaml vireo 'identical value on all 3 enrolled hosts since 2026-07-14' \
      hosts/vireo.yaml hosts/iris-wsl.yaml hosts/wren.yaml ||
      fail "a proposal was refused"
    rec_proposal="$rec_store/proposals/promote-ponytail-to-fleet.yaml"
    [ "$(yq -r '.item' "$rec_proposal")" = plugins.ponytail ] &&
      [ "$(yq -r '.from | length' "$rec_proposal")" -eq 3 ] &&
      [ "$(yq -r '.to' "$rec_proposal")" = fleet.yaml ] ||
      fail "the proposal did not name the item, its sources and its destination"
    # Re-seeding UPSERTS and never removes.
    fleet_proposal_write "$rec_store" promote-ponytail-to-fleet plugins.ponytail \
      '"enabled"' fleet.yaml wren 'identical value on all 4 enrolled hosts' \
      hosts/vireo.yaml hosts/iris-wsl.yaml hosts/wren.yaml hosts/mac-mini.yaml
    [ "$(yq -r '.from | length' "$rec_proposal")" -eq 4 ] ||
      fail "re-seeding did not upsert the proposal in place"
    [ "$(find "$rec_store/proposals" -name '*.yaml' | grep -c .)" -eq 1 ] ||
      fail "re-seeding wrote a second proposal for the same content"

    # --- §9.1 lineage: rename AND retirement, transitively ---
    fleet_lineage_write "$rec_store" renamed macbook-pro vireo vireo \
      'Read this file before reusing a name.' ||
      fail "a rename record was refused"
    [ "$(fleet_lineage_current "$rec_store" macbook-pro)" = vireo ] ||
      fail "a rename did not resolve to the current name"
    fleet_lineage_write "$rec_store" renamed vireo kestrel kestrel
    [ "$(fleet_lineage_current "$rec_store" macbook-pro)" = kestrel ] ||
      fail "a transitive rename chain did not resolve"
    fleet_lineage_write "$rec_store" retired kestrel kestrel ||
      fail "a retirement record was refused"
    [ "$(fleet_lineage_current "$rec_store" macbook-pro)" = retired ] ||
      fail "a retirement at the end of a rename chain was not reported"
    [ "$(fleet_lineage_current "$rec_store" wren)" = wren ] ||
      fail "a host that was never renamed did not resolve to itself"
    # A rename with nothing to rename TO is not a rename.
    ! fleet_lineage_write "$rec_store" renamed orphan orphan 2>/dev/null ||
      fail "a rename record with no destination was accepted"
    ! fleet_lineage_write "$rec_store" vanished orphan orphan 2>/dev/null ||
      fail "an unknown lineage event was accepted"

    # --- §10.5 upstream freshness ---
    [ -z "$(fleet_upstream_freshness "$rec_store" claude-marketplace)" ] ||
      fail "an upstream nobody has checked reported a freshness"
    fleet_upstream_write "$rec_store" claude-marketplace vireo sha256:3b1f9c
    fleet_upstream_write "$rec_store" claude-marketplace wren sha256:99aa11
    [ "$(find "$rec_store/upstreams/claude-marketplace" -name '*.yaml' | grep -c .)" -eq 2 ] ||
      fail "upstream freshness is not one file per host per upstream"
    rec_fresh=$(fleet_upstream_freshness "$rec_store" claude-marketplace)
    printf '%s\n' "$rec_fresh" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' ||
      fail "upstream freshness is not max(updated_at) across the directory"
    # Hand-written older stamps: the maximum wins, and nothing takes a turn.
    fleet_record_write "$rec_store/upstreams/claude-marketplace/wren.yaml" \
      '{"updated_at":"2020-01-01T00:00:00Z","result":"sha256:old"}'
    [ "$(fleet_upstream_freshness "$rec_store" claude-marketplace)" = "$rec_fresh" ] ||
      fail "an older per-host record moved the fleet's freshness backwards"

    # --- §5 policy, read from the store rather than from the box ---
    rec_fold=$(printf '%s' '{"policy":{"canary_wait_hours":48,"cadence_hours":6}}')
    [ "$(fleet_policy_get "$rec_fold" canary_wait_hours)" = 48 ] ||
      fail "the folded policy did not win over the default"
    [ "$(fleet_policy_get "$rec_fold" canary_group)" = canary ] ||
      fail "a policy key the store does not state did not fall back to the default"
    [ "$(fleet_policy_get '{}' max_removals_per_run)" = 5 ] &&
      [ "$(fleet_policy_get '{}' max_removal_fraction)" = 0.25 ] ||
      fail "the removal caps have no default"
    ! fleet_policy_get '{}' no_such_policy_key >/dev/null 2>&1 ||
      fail "an unknown policy key answered instead of failing"
    # Canary policy tampering: the reviewed source is the folded fleet.yaml at
    # R, so a local config that deletes the group or zeroes the wait cannot
    # weaken the gate on the box being gated.
    printf '%s\n' '{"version":1,"machines":{},"sync":{"canary_wait_hours":0}}' \
      >"$tmp/records/tamper.json"
    [ "$(ROUNDHOUSE_CONFIG="$tmp/records/tamper.json" \
      fleet_policy_get '{}' canary_wait_hours)" = 24 ] ||
      fail "a host-local config changed the canary policy"

    # --- §10.1 the canary gate and its liveness term ---
    rec_canary_store="$tmp/records/canary"
    rec_canary_reset() {
      rm -rf "$rec_canary_store"
      mkdir -p "$rec_canary_store"
      fleet_journal_append "$rec_canary_store" canary-1 \
        "$(rec_entry plugins.ponytail 91ac33 applied 2026-08-06T09:00:00Z)"
    }
    # 1 + 2 + 3: applied long enough ago, never withdrawn, still publishing.
    rec_canary_reset
    fleet_journal_append "$rec_canary_store" canary-1 \
      "$(jq -cn '{outcome: "alive", at: "2026-08-07T10:00:00Z"}')"
    fleet_canary_gate "$rec_canary_store" plugins.ponytail 91ac33 24 \
      2026-08-07T12:00:00Z canary-1 ||
      fail "a healthy canary did not release the item"
    # (1) not long enough ago yet.
    ! fleet_canary_gate "$rec_canary_store" plugins.ponytail 91ac33 24 \
      2026-08-06T18:00:00Z canary-1 ||
      fail "the canary wait was not enforced"
    # A different digest is a different thing.
    ! fleet_canary_gate "$rec_canary_store" plugins.ponytail deadbeef 24 \
      2026-08-07T12:00:00Z canary-1 ||
      fail "the canary gate released an item at a digest no canary applied"
    # (2) a later hold or revert withdraws it.
    for rec_withdrawal in held reverted; do
      rec_canary_reset
      fleet_journal_append "$rec_canary_store" canary-1 \
        "$(rec_entry plugins.ponytail 91ac33 "$rec_withdrawal" 2026-08-06T20:00:00Z)"
      fleet_journal_append "$rec_canary_store" canary-1 \
        "$(jq -cn '{outcome: "alive", at: "2026-08-07T10:00:00Z"}')"
      ! fleet_canary_gate "$rec_canary_store" plugins.ponytail 91ac33 24 \
        2026-08-07T12:00:00Z canary-1 ||
        fail "a canary that later $rec_withdrawal the item still released it"
    done
    # (3) the two silences condition 3 exists for. A canary that applied the
    # item and was WRECKED by it satisfies (1) and (2) and must still block.
    rec_canary_reset
    ! fleet_canary_gate "$rec_canary_store" plugins.ponytail 91ac33 24 \
      2026-08-07T12:00:00Z canary-1 ||
      fail "a canary that applied an item and stopped journaling released it"
    # ...and so does one that went publication-silent from an unrelated
    # conflict, which is precisely the state §8.4 mandates: its last record
    # predates the wait elapsing.
    rec_canary_reset
    fleet_journal_append "$rec_canary_store" canary-1 \
      "$(rec_entry skills.tdd aa11 applied 2026-08-06T10:00:00Z)"
    ! fleet_canary_gate "$rec_canary_store" plugins.ponytail 91ac33 24 \
      2026-08-07T12:00:00Z canary-1 ||
      fail "a publication-silent canary released the item on stale evidence"
    # Any record at all after the wait is liveness — it need not be the item.
    fleet_journal_append "$rec_canary_store" canary-1 \
      "$(rec_entry skills.tdd bb22 applied 2026-08-07T11:00:00Z)"
    fleet_canary_gate "$rec_canary_store" plugins.ponytail 91ac33 24 \
      2026-08-07T12:00:00Z canary-1 ||
      fail "an unrelated later record did not satisfy the liveness term"
    # One healthy canary is enough, and a silent one does not veto it.
    fleet_journal_append "$rec_canary_store" canary-2 \
      "$(rec_entry plugins.ponytail 91ac33 applied 2026-08-06T09:00:00Z)"
    fleet_canary_gate "$rec_canary_store" plugins.ponytail 91ac33 24 \
      2026-08-07T12:00:00Z canary-2 canary-1 ||
      fail "a healthy canary did not release the item alongside a silent one"
    # No canary has ever seen it: nothing to promote on.
    ! fleet_canary_gate "$rec_canary_store" plugins.brand-new ff00 24 \
      2026-08-07T12:00:00Z canary-1 canary-2 ||
      fail "an item no canary ever applied was released"
  )
fi
