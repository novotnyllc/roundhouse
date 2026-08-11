# How a change travels

One edit, followed from the keystroke to the machine at the far end of the
fleet. The path is the same whether an agent made the edit or you did, and
the same whether the other machine was awake at the time or three weeks
dark.

## 1. The edit

You open `hosts/vireo.yaml`, change `railyard: enabled` to
`railyard: {state: enabled, marketplace: claire-local}`, and save. An
agent doing the same thing writes the same bytes to the same file.

Nothing has moved yet. `main` is where it was, and `@` — the working-copy
commit — is the empty child the last run left behind.

## 2. Signing happens on snapshot

The next jj command in that repository, whether it's the scheduled run or
a bare `jj status`, snapshots the edit into `@` and **signs it** with this
host's own key. There is no commit step and nothing to forget: an edit
that exists on disk is already a signed commit.

The run then resolves the effective state from the **reconcile point** —
normally `main`, never `@`. The working copy is a workbench; the reviewed
line is a commit.

**The promote gate** decides whether the workbench becomes the reviewed
line. Every changed layer file is parsed with `yq -e '.'`. If they parse,
the run describes `@` and moves `main` to it. If one doesn't, the run
refuses to promote, alerts with yq's own message and line, and converges
from the last good `main`. A half-saved file never becomes the line every
host reads.

## 3. Propagation

**Steady state is minutes-fresh.** An edit published on one host is
applied on any awake host within `fast_interval_minutes +
fast_jitter_minutes` — 25 minutes at the defaults — or within seconds if
the publishing host can currently reach it.

| Path | Role |
| --- | --- |
| **Hub** (the git remote) | the universal path — everything converges through it eventually, including a laptop on hotel wifi with a route to GitHub and to nothing else |
| **Peer** (`rh-<name>` over SSH) | an opportunistic accelerator, never assumed and never required |

**The poll floor** is what makes a short interval cheap. The fast run
first asks whether the remote head moved, whether anything committed here
is unpushed, whether `@` is dirty, and whether this host has already
completed a run against the state it's holding. The first is one
`git ls-remote` round trip with no object negotiation and no transfer, and
all four quiet means exit. A full fetch runs only when something differs.

That last condition is what makes the check about *propagation* rather
than about the remote: a host that just cloned has nothing to pull and
nothing to push and has applied nothing, and without it would sit idle
until the remote happened to move.

**The push nudge** is six lines and nothing depends on it. After a
successful push, the pushing host tells whichever peers it can reach,
outbound only, best effort, with a bounded timeout. The nudge carries no
data — it says "go look," and the peer then runs its ordinary fast path
with every gate intact. An unreachable peer is skipped without a retry
queue and converges on its next poll instead. Policy key `push_nudge:
false` turns it off and the fleet still converges at poll speed.

**Two cadences, one scheduler entry per host:**

| Cadence | Command | Default | Does |
| --- | --- | --- | --- |
| Fast | `roundhouse fleet-run --fast` | 20 min ± 5 | poll floor, fetch, reconcile, promote gate, review, apply, journal, publish, nudge |
| Full | `roundhouse fleet-run --full` | 12 h ± 90 min | everything fast does, plus marketplace refresh, unpinned package updates, re-seed, promotion proposals, evidence retention, expired-leaf pruning, and `fleet-doctor` |

Both intervals are jittered from the host **name**, so the offsets are
stable across restarts and the fleet doesn't re-synchronise on one minute.

## 4. The gates, on the host where it lands

Every changed item passes the same ladder on the receiving machine, in
this order. The first thing that fires wins, and the item is journaled
either way.

1. **Divergence.** If the heads disagree about this item's value, it
   holds. Everything they agree on converges.
2. **Integrity.** The commit that introduced the value must be signed, its
   signature principal must equal its committer identity, and the signer
   must be in the roster at every one of that commit's parents *and* at
   this host's current reviewed head. A failure holds **only the items
   resolved from files that commit touched** — everything else converges.
   See [Trust](trust.md).
3. **A refusal you already recorded.** `roundhouse fleet-review ITEM hold
   REASON` refuses this exact value on this machine, and it outranks every
   gate below it. There's no point waiting for canary evidence about a
   digest someone already looked at and refused.
4. **Ownership.** An item in the layers and absent from
   `applied/<host>.yaml` is adopted after review. An item in
   `applied/<host>.yaml` at the same digest is already done. An item that
   left the layers is a prune candidate. Software that never appears in
   `applied/<host>.yaml` is never touched.
5. **Revert re-review.** A digest this host applied before and later
   stopped applying is the signature of a revert, so the stored verdict no
   longer satisfies the apply gate and the item is reviewed again as the
   new decision it is. A **promotion** — the same value moving from three
   host files up to `fleet.yaml` — keeps its digest and passes silently,
   because the value never changed.
6. **Canary.** A non-canary host applies item X at digest D only when some
   canary host has journaled `outcome: applied` — or `outcome: satisfied`
   — for that exact pair at least `canary_wait_hours` ago, has no later
   `held` or `reverted` record for it, **and** has published something —
   any item, or its `alive` heartbeat — dated at or after the wait
   elapsed. That third condition is what stops a canary that applied an
   item, was wrecked by it, and went quiet from reading as a pass.

   `satisfied` is the record a host writes for an item it resolved and had
   nothing to do about — an `agents`, `mcp_servers` or `projects` entry, a
   package desired `disabled` — because this design carries no
   state-alignment verb for those. It counts as canary evidence and `held`
   does not, and that asymmetry is what lets the gate terminate: an item
   that can never produce an `applied` record anywhere would otherwise wait
   on one forever, and the peer waiting would no-op identically once
   released. An item a host **tried and could not apply** journals `held`
   and keeps blocking.
7. **Review, then apply.** The review is provenance rather than a file
   diff — which layer won, the effective value, the digest — and it prints
   *before* the apply, so a crash mid-apply still leaves you the value
   that was about to be written.

Then: verdict to `store.run/verdicts/`, apply, `applied/<host>.yaml`,
`journal/<host>/<date>.yaml`, describe, move `main`, push, land `@` on the
pushed commit.

**Removals are capped before any of them run.** A run whose effective set
removes more than `max_removals_per_run` (5) or `max_removal_fraction`
(0.25 of the applied set), whichever is smaller, **holds the entire
removal set** and alerts. Neither term catches a one-line deletion, and
neither should — that's a legitimate edit, and its defence is the review
naming the item.

**Drift is reported, never stomped.** For every `managed` key in a harness
config file, the run prints the current on-disk value — so a hand-edit to a
key roundhouse owns is something you *see*, not something a twice-daily job
silently reverts four hours later. `config_files` declares ownership of
keys, and the run reports and changes nothing. Keys marked `unmanaged` are
not compared, not reported, and not read.

## 5. What the far host sees

On a host with no override for that item, the group layer's `enabled` is
still the winner and the change is a **no-op**. That's the layering
working, not a propagation failure.

## 6. Coming back from offline

A host that was dark converges the same way a host that was gone for
twenty minutes does. It fetches (or journals `source: none` and skips
that), reviews against what it has, converges, applies, journals, and
lands `@` back on `main`. jj commits without a network, so nothing was
degraded except freshness — there is no lease to reclaim and no state that
went stale.

Two rules keep a returning host safe. **Cannot reach the source** —
converge from last known, never prune. **Cannot read the source** — parse
failure, open conflict, bad signature — hold the affected items at their
last applied value, never prune. A file that doesn't parse is not an empty
file.

## 7. When two hosts disagree

Two hosts editing different layer files is not a conflict; jj merges them.
A real conflict is two hosts changing the same value.

**The host stays publication-silent while a conflict is open** — the same
state it's in when offline. It converges locally, and it publishes nothing
until the conflict is resolved and folded back into the commit that
carried it, so no conflicted commit ever reaches the remote and no host
clones into a broken tree.

**Items disagree, stores don't.** The hold set comes from comparing each
head's *resolved value* for each item, so one contested key in
`groups/development.yaml` holds that key and nothing else — every other
item that layer contributes still converges, on every host in the group.
An item present at one head and missing at the other is a disagreement
like any other and holds, which is what keeps a removal from landing while
the heads disagree about whether the item exists.

**The run's agent resolves it, on an evidence ladder.** It has both sides,
it can read them while the merge is still conflicted, and it's already
reviewing this run's diffs. The ladder, in order:

1. **Not actually contested** — the resolved value is identical on both
   sides. Converge.
2. **A human is on either side → escalate.** A commit with no roundhouse
   trailers reads as a human edit, so omitting the marker and forging it
   land in the same place. This is checked *before* any arbitration,
   because that is exactly the moment a person's intent is at stake.
3. **Verified revert** — one side's value equals what the change it names
   replaced, *and* the other side's value equals what that change set.
   Both halves are required: the first says the claim is true about
   history, the second says it's about *this* conflict. That side wins.
4. **Verified applied-elsewhere, and exactly one side qualifies** — one
   side's value is recorded `applied` in some peer's journal and not
   subsequently reverted there, and the other side's isn't. Uniqueness is
   load-bearing: each host applies and journals before it pushes, so in
   the ordinary two-host divergence *both* sides carry an `applied`
   record, and the rule stays silent.
5. **Both sides agent-authored and more than one fast interval apart** —
   the later one wins, on the reasoning that it saw more recent upstream
   state. Inside one interval, "later" isn't a real claim and the rule
   doesn't fire.
6. **Otherwise, escalate.** Hold the item, alert, converge everything else.

The ordering follows from what grounds each rule. Signed file content is
the strongest evidence, a peer's journal is next — bound to that peer by
signature, so it can only ever lie about itself — and free text in a
commit description is self-asserted. **A self-asserted field may point at
evidence to check or trigger an escalation; it can never win a contest on
its own.**

A resolution is an ordinary commit: signed at creation, subject to the
identity gate on every peer, digest-bound and re-reviewed by every
receiving host, gated by canary, capped by the removal guards, and
revertable like anything else. It's also journaled with an
`outcome: resolved` record naming both parent changes, the winning digest,
and the resolution commit — so a peer, human or agent, can reconstruct
what was contested, what won, and why, from replicated signed content.

## 8. Rollback

```text
roundhouse fleet-rollback ITEM [--now]
```

Rollback is an ordinary change. It creates a signed revert commit on
`main` that flows through the same review, canary, and apply gates as
everything else — which is exactly why it can be trusted: the undo path is
the path that runs a hundred times a day. The revert covers the layers;
the evidence directories are left intact, because reversing them would
delete records peers have already seen and make the host disown what it
installed.

**Canary caught it.** The item never satisfied `canary_wait_hours`, so no
non-canary host ever applied it. The canary publishes the revert, and the
later `held`/`reverted` record also stops the original from promoting if
someone re-pushes it. Blast radius: one machine, one fast interval.

**Canary missed it.** Any host publishes the revert — there's no owner of
a change — and every host picks it up on its next fast run, reviews it as
the new change it is, and applies the prior value. Non-canary hosts wait
behind the canary for the revert too, which is deliberate: a panicked bad
revert is a real failure mode. `--now` is the one canary bypass in the
design, and it is bound rather than being a flag that turns a gate off. It
is honoured only for an item whose introducing commit carries a revert
claim that verifies against history, it is scoped to the named item, it is
signed and journaled with `override: canary`, and `fleet-doctor` counts
every override in the last 30 days. A bypass nobody counts becomes routine.

Rollback is honest per category. Plugins, skills, agents, and config file
keys restore fully. Packages restore where the manager can install the
older version, and hold with an alert where it can't. `mcp_servers` and
`hooks` are reversible for configuration only — removing a hook stops it
firing, it does not undo what it already did. Reverting a `projects` entry
stops managing the project; repository state is its own business. Anything
that can't fully roll back says so in the review output, before you pass
it.

For one bad *local* run there's a second, narrower lever:
`jj op restore <op>`, host-local and immediate. The run records its
starting operation id in `store.run/`, and prints it along with whether it
pushed.

## Go deeper

- **[The fleet store](store.md)** — the layers, the fold, what converges.
- **[Trust](trust.md)** — who may write what, and how a machine joins.
- **[Why jj](why-jj.md)** — the version control this leans on.
- **[Running it](operating.md)** — the verbs and the schedule.
