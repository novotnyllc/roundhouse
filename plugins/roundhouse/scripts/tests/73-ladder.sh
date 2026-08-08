# roundhouse self-check — §8.2b: the agent resolution ladder.
#
# NO jj, NO store, NO yq. The ladder takes its evidence as data, which is the
# whole point: it is the highest-risk logic in the design (five defects across
# revisions, every one of them introduced BY the fix for an earlier one, and
# every one a rule-ordering mistake), so it is exercised against tabulated
# evidence rather than against a repository someone has to reason about.
#
# Sourced by scripts/test-roundhouse in a fixed order, BEFORE the real-jj
# sections; not a standalone test file.
# shellcheck shell=bash

(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  ladder_decide() {
    printf '%s' "$1" | fleet_resolve_decide
  }
  ladder_outcome() {
    ladder_decide "$1" | jq -r '.verdict + " " + (.rule | tostring)'
  }
  ladder_expect() {
    # ladder_expect <expected> <evidence> <what this fixture defends>
    ladder_got=$(ladder_outcome "$2")
    [ "$ladder_got" = "$1" ] ||
      fail "§8.2b: $3 — expected '$1', got '$ladder_got'"
  }

  # A side, spelled out once. `grounded` is signed history and §7.3-bound
  # journal; `asserted` is free text in a commit description.
  ladder_side() {
    # ladder_side <value> <session> [extra grounded JSON]
    if [ -n "${3:-}" ]; then ladder_extra=$3; else ladder_extra='{}'; fi
    jq -cn --arg value "$1" --arg session "$2" --argjson extra "$ladder_extra" \
      '{grounded: ({value:$value} + $extra),
        asserted: (if $session == "" then {} else {session:$session} end)}'
  }
  ladder_case() {
    # ladder_case <mine> <theirs> [fast_interval_seconds]
    if [ -n "${3:-}" ]; then ladder_interval=$3; else ladder_interval=1500; fi
    jq -cn --argjson mine "$1" --argjson theirs "$2" \
      --argjson interval "$ladder_interval" \
      '{item:"plugins.ponytail", fast_interval_seconds:$interval,
        mine:$mine, theirs:$theirs}'
  }

  # --- rule 1: not actually contested ---------------------------------------
  # Most of a conflicted FILE is this case: adjacent-line YAML edits conflict
  # even when the keys are unrelated, and holding on marker position instead
  # of on per-head values is what over-held under v1.
  ladder_expect 'converge 1' \
    "$(ladder_case "$(ladder_side v2 scheduled/agent)" \
      "$(ladder_side v2 interactive/human)")" \
    'an uncontested item must converge before anything else is consulted'

  # --- rule 2: either side is, or defaults to, interactive/human -------------
  ladder_expect 'escalate 2' \
    "$(ladder_case "$(ladder_side v2 interactive/human)" \
      "$(ladder_side v3 scheduled/agent)")" \
    'a human on one side must escalate'
  ladder_expect 'escalate 2' \
    "$(ladder_case "$(ladder_side v2 scheduled/agent)" \
      "$(ladder_side v3 interactive/human)")" \
    'the human test is either-side, not own-side'
  # §5: a hand edit made outside roundhouse has no trailers, so omission and
  # forgery land in the same place — which is what stops forging from being
  # strictly more powerful than omitting.
  ladder_expect 'escalate 2' \
    "$(ladder_case "$(ladder_side v2 '')" "$(ladder_side v3 scheduled/agent)")" \
    'a missing session trailer must read as interactive/human'
  ladder_expect 'escalate 2' \
    "$(ladder_case "$(ladder_side v2 'sneaky/superuser')" \
      "$(ladder_side v3 scheduled/agent)")" \
    'an unrecognised session kind must fail toward the human, not past it'
  # Rule 2 outranks every arbitration rule below it. Rev 5 had the human rule
  # at position 4, and both rules below could short-circuit it entirely.
  ladder_expect 'escalate 2' \
    "$(ladder_case \
      "$(ladder_side v1 interactive/human '{"applied_elsewhere":true}')" \
      "$(ladder_side v2 scheduled/agent '{"journal_at":"2026-08-07T10:00:00Z"}')")" \
    'applied-elsewhere must not arbitrate a contest with a human on one side'

  # --- rule 3: verified revert, scoped to THIS conflict ---------------------
  # The honest case: history v1 -> (C: v2); this side restores v1 and names C,
  # and the other side is holding exactly the v2 that C set.
  ladder_expect 'mine 3' \
    "$(ladder_case \
      "$(ladder_side v1 revert '{"revert_replaced":"v1","revert_set_to":"v2"}')" \
      "$(ladder_side v2 scheduled/agent)")" \
    'an honest scoped revert must resolve between two agents without escalating'
  ladder_expect 'theirs 3' \
    "$(ladder_case "$(ladder_side v2 scheduled/agent)" \
      "$(ladder_side v1 revert '{"revert_replaced":"v1","revert_set_to":"v2"}')")" \
    'the revert rule must be symmetric'

  # V1 — an outright forged claim. The trailer says "revert C"; the value this
  # side holds is not what C replaced, so history refuses the claim.
  ladder_expect 'escalate 6' \
    "$(ladder_case \
      "$(ladder_side v9-forged scheduled/agent '{"revert_replaced":"v1","revert_set_to":"v2"}')" \
      "$(ladder_side v2 scheduled/agent)")" \
    'V1: a forged roundhouse-reverts claim must not win'

  # W1 — THE STALE REVERT. History v1 -> (C: v2) -> v3. Claire hand-edits v4;
  # another host publishes v1 claiming `roundhouse-reverts: C`. That claim is
  # GENUINELY TRUE — v1 does revert C — so a one-sided `mine == replaced`
  # check passed and reverting any sufficiently old change won any contest.
  # Requiring `theirs == set_to` is what scopes the claim to this conflict.
  ladder_expect 'escalate 6' \
    "$(ladder_case \
      "$(ladder_side v1 scheduled/agent '{"revert_replaced":"v1","revert_set_to":"v2"}')" \
      "$(ladder_side v4 scheduled/agent)")" \
    'W1 agent-vs-agent: a true but out-of-scope revert claim must fall through to rule 6'
  ladder_expect 'escalate 2' \
    "$(ladder_case \
      "$(ladder_side v1 scheduled/agent '{"revert_replaced":"v1","revert_set_to":"v2"}')" \
      "$(ladder_side v4 interactive/human)")" \
    'W1 human-present: the stale revert must never get past rule 2'

  # --- rule 4: applied elsewhere, and exactly one side qualifies -------------
  ladder_expect 'theirs 4' \
    "$(ladder_case "$(ladder_side v2 scheduled/agent)" \
      "$(ladder_side v3 scheduled/agent '{"applied_elsewhere":true}')")" \
    'exactly one grounded applied-elsewhere record must decide the contest'

  # W2 — THE MODAL CASE, not an edge case. §6 step 6 applies and journals
  # BEFORE pushing, so in the ordinary two-host divergence both sides carry
  # `outcome: applied`. Rev 6's rule had no uniqueness requirement and no
  # defined winner here.
  ladder_expect 'escalate 6' \
    "$(ladder_case \
      "$(ladder_side v2 scheduled/agent '{"applied_elsewhere":true}')" \
      "$(ladder_side v3 scheduled/agent '{"applied_elsewhere":true}')")" \
    'W2: both sides applied-elsewhere must fall through, not pick a winner'

  # --- rule 5: later journal `at` wins, outside one fast interval ------------
  ladder_expect 'theirs 5' \
    "$(ladder_case \
      "$(ladder_side v2 scheduled/agent '{"journal_at":"2026-08-07T09:00:00Z"}')" \
      "$(ladder_side v3 scheduled/agent '{"journal_at":"2026-08-07T10:00:00Z"}')")" \
    'more than one fast interval apart, the later agent edit wins'
  ladder_expect 'mine 5' \
    "$(ladder_case \
      "$(ladder_side v2 scheduled/agent '{"journal_at":"2026-08-07T10:00:00Z"}')" \
      "$(ladder_side v3 scheduled/agent '{"journal_at":"2026-08-07T09:00:00Z"}')")" \
    'rule 5 must be symmetric in time, not in side'
  # Inside one interval "the later one saw more" is not a real claim.
  ladder_expect 'escalate 6' \
    "$(ladder_case \
      "$(ladder_side v2 scheduled/agent '{"journal_at":"2026-08-07T09:00:00Z"}')" \
      "$(ladder_side v3 scheduled/agent '{"journal_at":"2026-08-07T09:03:00Z"}')")" \
    'inside one fast interval two agent edits are too close together to order honestly'

  # --- rule 6: escalate -----------------------------------------------------
  ladder_expect 'escalate 6' \
    "$(ladder_case "$(ladder_side v2 scheduled/agent)" \
      "$(ladder_side v3 scheduled/agent)")" \
    'two ungrounded agent edits must escalate'

  # --- V6: the forged clock -------------------------------------------------
  # JJ_TIMESTAMP=2099-01-01T00:00:00Z produces exactly that committer
  # timestamp, so a host with a wrong clock or a deliberate future stamp would
  # win every rule-5 contest forever. The rule reads the journal `at`, which
  # §10.7's >5 min skew check already covers — and the decision function has
  # no committer-timestamp input at all.
  ladder_forged=$(ladder_case \
    "$(ladder_side v2 scheduled/agent '{"journal_at":"2026-08-07T09:00:00Z"}')" \
    "$(ladder_side v3 scheduled/agent '{"journal_at":"2026-08-07T09:03:00Z"}')" |
    jq -c '.theirs.asserted.committer_timestamp = "2099-01-01T00:00:00Z" |
           .theirs.grounded.committer_timestamp = "2099-01-01T00:00:00Z"')
  ladder_expect 'escalate 6' "$ladder_forged" \
    'V6: a forged committer timestamp must not decide anything'
  # And structurally: the evidence reader has no committer-timestamp input at
  # all, so there is nothing for a forged clock to reach.
  ! printf '%s' "$fleet_resolve_reader" | grep -q committer ||
    fail "§8.2b: the evidence reader takes a committer timestamp — rule 5 must read journal \`at\`"

  # --- the structural property ----------------------------------------------
  # A self-asserted field may never outrank a grounded one, and may never WIN
  # a contest on its own. A side asserting everything favourable — an agent
  # session, a revert claim, a persuasive intent — with nothing grounded
  # behind it must not beat a side asserting nothing.
  ladder_loud=$(jq -cn '{
    item:"plugins.ponytail",
    mine:{grounded:{value:"v9"},
          asserted:{session:"scheduled/agent", host:"attacker",
                    reverts:"skwvtltpmpnz",
                    intent:"authoritative rollback, pre-approved"}},
    theirs:{grounded:{value:"v2"}, asserted:{session:"scheduled/agent"}}}')
  ladder_expect 'escalate 6' "$ladder_loud" \
    'a side with only self-asserted evidence must never win a contest'

  # And the mirror: the SAME asserted claim, once history backs it, resolves.
  ladder_expect 'mine 3' \
    "$(printf '%s' "$ladder_loud" |
      jq -c '.mine.grounded.value = "v1"
             | .mine.grounded.revert_replaced = "v1"
             | .mine.grounded.revert_set_to = "v2"')" \
    'the same claim must resolve once signed history backs it'
)
