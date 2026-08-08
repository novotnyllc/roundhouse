# roundhouse — §8.2b: the agent resolution ladder.
#
# A conflict is a task for the agent driving the run, not a ticket for the
# operator. This unit is that decision and nothing else: it takes the evidence
# as DATA and returns a verdict with its rationale. There is no jj here, no
# store read, and no side effect — which is what makes the highest-risk logic
# in the design testable exhaustively, and what keeps the five defects that
# rev 5 introduced *by* fixing earlier defects from hiding behind a repository
# fixture. Every one of those five was a rule-ordering mistake.
#
# The caller gathers evidence (§8.2b's table) and writes the resolution; the
# record shape it produces is not defined here.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

# The evidence document, on stdin:
#
#   {
#     "item": "plugins.ponytail",
#     "fast_interval_seconds": 1500,
#     "mine":   { "grounded": {…}, "asserted": {…} },
#     "theirs": { "grounded": {…}, "asserted": {…} }
#   }
#
# THE SPLIT BETWEEN `grounded` AND `asserted` IS THE SAFETY PROPERTY, not
# documentation. §8.2b names three evidence classes:
#
#   signed history      file content at a commit, and what a named change
#                       replaced. A hostile enrolled host cannot fake it.
#   replicated journal  journal/<h>/ outcomes, §7.3-bound to <h>. It can lie
#                       only about itself.
#   self-asserted text  the §5 trailers. Free text in a description; anyone
#                       can write anything.
#
# The first two are `grounded`, the third is `asserted`, and **exactly one
# rule below reads `asserted` — rule 2, whose only possible outcome is
# escalation.** Rev 5's ladder violated that twice over: its revert rule fired
# on the unverified `roundhouse-reverts` trailer, so any enrolled host could
# write that trailer into a commit that was not a revert and beat a human's
# edit; and its human rule let a forged `interactive/human` *win*, which made
# forging strictly more powerful than omitting.
#
# grounded, per side:
#   value             the side's resolved value for the item
#   revert_replaced   what the change named by this side's roundhouse-reverts
#                     trailer REPLACED — read from history at <c>-, never from
#                     the trailer. Absent when the claim does not resolve.
#   revert_set_to     what that same change SET, read at <c>.
#   applied_elsewhere true when this side's value is recorded `outcome:
#                     applied` in some peer's journal and was not
#                     subsequently reverted or superseded there.
#   journal_at        this side's journal `at`, ISO8601 Z.
#
# asserted, per side:
#   session           the roundhouse-session trailer. Absent reads as
#                     interactive/human.
#   host, intent, reverts — provenance for the operator; no rule reads them.

fleet_resolve_reader='
  def grounded(side; key): (side.grounded[key] // null) | tojson;
  def flag(side; key): (side.grounded[key] // false) | tostring;
  def at(side):
    if (side.grounded.journal_at // null) == null then ""
    else (side.grounded.journal_at | fromdateiso8601 | tostring) end;
  (.item // ""),
  ((.fast_interval_seconds // 1500) | tostring),
  grounded(.mine; "value"),
  grounded(.theirs; "value"),
  ((.mine.asserted.session // "") | tostring),
  ((.theirs.asserted.session // "") | tostring),
  grounded(.mine; "revert_replaced"),
  grounded(.mine; "revert_set_to"),
  grounded(.theirs; "revert_replaced"),
  grounded(.theirs; "revert_set_to"),
  flag(.mine; "applied_elsewhere"),
  flag(.theirs; "applied_elsewhere"),
  at(.mine),
  at(.theirs)
'

fleet_resolve_is_human() {
  # §5: a hand edit made outside roundhouse has no trailers, and a missing
  # `roundhouse-session` reads as interactive/human — the most conservative
  # reading, which biases toward escalation rather than toward a confident
  # wrong merge. An UNRECOGNISED session reads the same way, so a typo or a
  # future session kind fails toward the human rather than past it.
  #
  # The trailer may carry a session token after the kind
  # (`scheduled/agent 01J9X2`); only the kind decides.
  case ${1%% *} in
    scheduled/agent | interactive/agent | seed | revert) return 1 ;;
  esac
  return 0
}

fleet_resolve_verdict() {
  # fleet_resolve_verdict <item> <verdict> <rule> <rationale> [winning-value]
  # `verdict` is one of converge | mine | theirs | escalate. The winning value
  # rides along as JSON so the caller can digest it (§7.2) without re-reading
  # the evidence; the record that carries it is the caller's to define.
  jq -cn --arg item "$1" --arg verdict "$2" --argjson rule "$3" \
    --arg rationale "$4" --argjson value "${5:-null}" \
    '{item:$item,verdict:$verdict,rule:$rule,rationale:$rationale,value:$value}'
}

fleet_resolve_decide() {
  # §8.2b's ladder. ONE ordered function, one `return` per rule, and no early
  # arbitration anywhere else in the codebase. Stop at the first rule that
  # fires.
  #
  # Rule 2 sits where it does on purpose: EVERY ARBITRATION RULE BELOW IT
  # DECIDES AGENT-VS-AGENT CONTESTS ONLY. Rev 5 had the human rule at position
  # 4, below both arbitration rules, and any rule above it short-circuits
  # human escalation entirely — rev 6's revert rule let a sufficiently old
  # true revert beat a hand edit, and the applied-elsewhere rule arbitrated
  # human-vs-agent without a human ever being consulted, which (because §6
  # step 6 applies and journals BEFORE pushing) is the modal two-host
  # divergence rather than an edge case.
  #
  # Values arrive as compact JSON, so equality is string equality and a
  # multi-line YAML value cannot break the line-oriented read below. The
  # session and timestamp fields legitimately come back empty, and command
  # substitution eats trailing newlines, so every field is cleared first
  # rather than left unset when the last one is absent.
  fleet_resolve_mine_session=
  fleet_resolve_theirs_session=
  fleet_resolve_mine_at=
  fleet_resolve_theirs_at=
  fleet_resolve_fields=$(jq -r "$fleet_resolve_reader")
  {
    read -r fleet_resolve_item
    read -r fleet_resolve_interval
    read -r fleet_resolve_mine
    read -r fleet_resolve_theirs
    read -r fleet_resolve_mine_session
    read -r fleet_resolve_theirs_session
    read -r fleet_resolve_mine_replaced
    read -r fleet_resolve_mine_set
    read -r fleet_resolve_theirs_replaced
    read -r fleet_resolve_theirs_set
    read -r fleet_resolve_mine_applied
    read -r fleet_resolve_theirs_applied
    read -r fleet_resolve_mine_at
    read -r fleet_resolve_theirs_at
  } <<EOF
$fleet_resolve_fields
EOF

  # 1. Not actually contested. [signed history] Most of a conflicted FILE is
  #    this case: adjacent-line YAML edits conflict even when the keys are
  #    unrelated.
  if [ "$fleet_resolve_mine" = "$fleet_resolve_theirs" ]; then
    fleet_resolve_verdict "$fleet_resolve_item" converge 1 \
      'both sides resolve the item to the same value' "$fleet_resolve_mine"
    return 0
  fi

  # 2. Either side is, or defaults to, interactive/human -> escalate.
  #    [self-asserted — so it can only escalate, never win] Deliberately an
  #    EITHER-SIDE test: forging `scheduled/agent` on your own side does not
  #    avoid escalation, because the other side still reads as human. Omission
  #    and forgery therefore land in the same place.
  #
  #    The cost is that a genuine hand edit conflicting with an agent edit
  #    escalates instead of silently winning. That is the right trade: it is
  #    precisely the moment a person's intent is at stake.
  if fleet_resolve_is_human "$fleet_resolve_mine_session" ||
    fleet_resolve_is_human "$fleet_resolve_theirs_session"; then
    fleet_resolve_verdict "$fleet_resolve_item" escalate 2 \
      'a human is on at least one side of this conflict, or a side carries no session trailer and reads as one'
    return 0
  fi

  # 3. Verified revert, SCOPED TO THIS CONFLICT. [signed history; the trailer
  #    is only a pointer to what to check] One side's value equals what the
  #    change it names replaced, AND the other side's value equals what that
  #    change set.
  #
  #    BOTH COMPARISONS ARE REQUIRED. Checking only `mine == replaced`
  #    verifies the claim is true about history, not that it is about THIS
  #    conflict: with history v1 -> (C: v2) -> v3, a hand edit of v4 loses to
  #    a peer publishing v1 and claiming to revert C — a claim that is
  #    genuinely true — so reverting any sufficiently old change won any
  #    contest. `theirs == set_to` says the other side is holding exactly what
  #    the named change introduced.
  if [ "$fleet_resolve_mine_replaced" != null ] &&
    [ "$fleet_resolve_mine" = "$fleet_resolve_mine_replaced" ] &&
    [ "$fleet_resolve_theirs" = "$fleet_resolve_mine_set" ]; then
    fleet_resolve_verdict "$fleet_resolve_item" mine 3 \
      'this side restores what the change it names replaced, and the other side holds exactly what that change set' \
      "$fleet_resolve_mine"
    return 0
  fi
  if [ "$fleet_resolve_theirs_replaced" != null ] &&
    [ "$fleet_resolve_theirs" = "$fleet_resolve_theirs_replaced" ] &&
    [ "$fleet_resolve_mine" = "$fleet_resolve_theirs_set" ]; then
    fleet_resolve_verdict "$fleet_resolve_item" theirs 3 \
      'the incoming side restores what the change it names replaced, and this side holds exactly what that change set' \
      "$fleet_resolve_theirs"
    return 0
  fi

  # 4. Verified applied-elsewhere, and EXACTLY ONE side qualifies.
  #    [replicated journal] "Exactly one" is load-bearing: §6 step 6 applies
  #    and journals BEFORE pushing, so in the ordinary two-host divergence
  #    both sides carry `outcome: applied` — each host applied its own edit
  #    locally before publishing. When both qualify, or neither does, the rule
  #    does not fire.
  #
  #    The wording matches §10.1: the journal attests that a run refused
  #    nothing, not that the item is healthy.
  if [ "$fleet_resolve_mine_applied" = true ] &&
    [ "$fleet_resolve_theirs_applied" != true ]; then
    fleet_resolve_verdict "$fleet_resolve_item" mine 4 \
      'a peer applied this value and has not since reverted or superseded it, and the other side has no such record' \
      "$fleet_resolve_mine"
    return 0
  fi
  if [ "$fleet_resolve_theirs_applied" = true ] &&
    [ "$fleet_resolve_mine_applied" != true ]; then
    fleet_resolve_verdict "$fleet_resolve_item" theirs 4 \
      'a peer applied the incoming value and has not since reverted or superseded it, and this side has no such record' \
      "$fleet_resolve_theirs"
    return 0
  fi

  # 5. Both sides agent-authored (guaranteed by rule 2 above), and their
  #    journal `at` times differ by MORE THAN ONE FAST INTERVAL — the later
  #    one wins, on the reasoning that it was derived from more recent
  #    upstream state. [replicated journal, skew-checked]
  #
  #    The clock read is the journal `at`, never `committer.timestamp()`:
  #    JJ_TIMESTAMP=2099-01-01T00:00:00Z produces exactly that committer
  #    timestamp, so one host with a wrong clock or a deliberate future stamp
  #    would win every rule-5 contest forever. Journal `at` is what §10.7's
  #    >5 min skew check already covers.
  #
  #    And the margin matters: at a 20-minute cadence "the later one saw more"
  #    is not a real claim three minutes apart, so inside one fast interval
  #    this rule does not fire and the ladder falls through to escalation.
  if [ -n "$fleet_resolve_mine_at" ] && [ -n "$fleet_resolve_theirs_at" ]; then
    fleet_resolve_gap=$((fleet_resolve_mine_at - fleet_resolve_theirs_at))
    [ "$fleet_resolve_gap" -ge 0 ] ||
      fleet_resolve_gap=$((-fleet_resolve_gap))
    if [ "$fleet_resolve_gap" -gt "$fleet_resolve_interval" ]; then
      if [ "$fleet_resolve_mine_at" -gt "$fleet_resolve_theirs_at" ]; then
        fleet_resolve_verdict "$fleet_resolve_item" mine 5 \
          'both sides are agent-authored and this side journaled more than one fast interval later' \
          "$fleet_resolve_mine"
      else
        fleet_resolve_verdict "$fleet_resolve_item" theirs 5 \
          'both sides are agent-authored and the incoming side journaled more than one fast interval later' \
          "$fleet_resolve_theirs"
      fi
      return 0
    fi
  fi

  # 6. Otherwise — escalate. Hold the item, alert, converge everything else.
  fleet_resolve_verdict "$fleet_resolve_item" escalate 6 \
    'neither side is grounded, both are equally grounded, or two agent edits are too close together to order honestly'
}
