# Running it

The practical surface: what runs on its own, what you reach for when
you're supervising, and where the evidence lives.

## Daily: nothing

The scheduler runs `roundhouse fleet-run` on its own cadence. Edits made
anywhere land everywhere, changes are reviewed on the machine where
they're about to run, evidence is written back, and held items wait for
someone. The verbs below are for the moments you want to look, decide, or
change the shape of the fleet.

## Supervising

```text
roundhouse fleet-explain [HOST] ITEM     # every layer's opinion, and which wins
roundhouse fleet-pending                 # every open alert, from every host
roundhouse fleet-review ITEM pass|hold REASON
roundhouse fleet-apply ITEM              # refuses without a passing review at the current digest
roundhouse fleet-hold ITEM REASON        # the fleet-visible refusal
roundhouse fleet-accept SLUG             # accept a promotion proposal
roundhouse fleet-finding SLUG SUMMARY [QUOTE]
roundhouse fleet-journal ENTRY.json|-
roundhouse fleet-rollback ITEM [--now]
roundhouse fleet-lock / fleet-unlock
```

**Every one of these writes into the working copy and stops.** No
describe, no bookmark move, no push. The next run publishes what they
wrote through the ordinary gates — which is what keeps the supervised
surface from becoming a second, unreviewed path onto `main`.

Two rules make it safe, and neither is a formality.

**A verdict binds to a digest.** `fleet-review ITEM hold REASON` stops
*this host* converging that exact value, and the run honours it ahead of
every other gate. Edit the item and the hold doesn't carry over — the new
value has never been reviewed by anyone. A stale `pass` fails exactly like
an absent one, so `fleet-apply` can't ride yesterday's approval.

**A hold and a review are different things.** `fleet-review ITEM hold` is
a local decision; `fleet-hold ITEM REASON` writes the alert every host
sees. Two verbs, so a local refusal doesn't shout at the fleet.

Verdicts live in `store.run/verdicts/` and are never replicated: a
fleet-writable verdict would put a consent-shaped artifact on a shared
surface. Alerts have no state machine — resolving one is `rm` on the file.
`fleet-finding` and `fleet-hold` pass every replicated field through the
redaction floor, and a field that trips it is **refused rather than
silently redacted**.

### Proposals

The full pass re-seeds — upsert, never remove — and looks for items whose
value is **identical in every enrolled host file**. Unanimity is the bar:
three-of-five is normal curation for a personal fleet, not drift, and
produces nothing. A unanimous item becomes a `proposals/<slug>.yaml`
suggesting the move up a layer. Ignoring one does nothing.

`fleet-accept SLUG` makes the two ordinary edits — write the value at the
target layer, drop it from each host file that carried it — and **the
digest is unchanged by construction**, so no host re-reviews anything.
Promotion moves *where* a value is written, never *what* it is.

## Membership

```text
roundhouse fleet-add HOST [--ephemeral] [--job JOB] [--ttl HOURS]
roundhouse fleet-join REMOTE            # run on the newcomer instead
roundhouse fleet-remove HOST [--burn]
roundhouse fleet-renew NAME [HOURS]     # same key, fresh window
roundhouse fleet-reparent               # adopt orphaned leaves
roundhouse fleet-reconstitute HOST      # new hardware, new key, one commit
```

All of them are one instruction on a machine you're already at, and none
of them runs anything on any other host. `--ttl` defaults to 24 hours.
[Trust](trust.md) covers what each one commits and why it verifies
everywhere.

## Standing up the store

```text
gh repo create <owner>/fleet-store --private   # the hub is transport, not authority
roundhouse fleet-init            # jj git init --colocate, repo config, scaffold
roundhouse fleet-enroll          # mint the node key, write [signing], self-signed roster
roundhouse fleet-set-remote <url>
roundhouse fleet-verify-remote   # required before the first push
roundhouse fleet-seed            # discovery -> hosts/<name>.yaml + applied/<name>.yaml
$EDITOR fleet.yaml               # lift the commonalities
roundhouse fleet-doctor          # every row before host 2
roundhouse fleet-run --fast      # the first convergence
```

The order carries weight. `fleet-init` leaves the repository with no
`[signing]` block, and `fleet-enroll` adds it once the key that satisfies
it exists — a repository configured to sign with a key that isn't there
fails at `jj git init` and the repository is never created. And the
store id is the genesis commit id, which is the roster commit
`fleet-enroll` makes, so `fleet-init` can't be the step that reports it.

`fleet-verify-remote` is a gate, not a formality: **the first push refuses
without it.** It probes the remote with every credential path closed and
takes a three-way verdict — only an *authentication refusal* proves the
remote is gated. A remote that answers unauthenticated reads is public and
is refused; an unreachable remote is inconclusive and never satisfies the
gate, because a failed probe is not evidence of privacy.

`fleet-set-remote URL` moves the store to a new remote. It writes the move
alert *before* the push, so a crash between the two still leaves the store
carrying the record of how it got where it went; rolls that alert back if
the push fails, so origin is never left claiming a move that didn't
happen; and invalidates the visibility posture afterward, so the next push
re-verifies.

`fleet-seed` writes this host's own `hosts/<name>.yaml` and
`applied/<name>.yaml` from discovery, which makes the **first convergence
after seeding a no-op by construction.**

## Maintenance

```text
roundhouse fleet-checkpoint      # signed roster+state snapshot, tagged
roundhouse fleet-reroot          # archive ref, then a new root
roundhouse fleet-adopt-pin PLUGIN PIN.json
roundhouse fleet-doctor
```

Checkpoint and re-root bound history; [Trust](trust.md) covers the archive
protocol that a re-root depends on. `fleet-adopt-pin` gates roundhouse
updating *itself* separately from ordinary convergence, because the code
that decides whether an update is safe is the code being updated. Every
other plugin rides the ordinary review, canary, and apply gates.

Two other things age on the 12-hour full pass with no command at all:
expired leaf entries are pruned from the roster, and evidence older than
`evidence_retention_days` (90 by default) is dropped.

## The scheduler

Auto-updating on a schedule uses the OS scheduler calling the CLI — no new
daemon, database, or engine. **There is exactly one owned scheduler entry
per host**, and it runs `roundhouse fleet-run`. Two local runners racing
one plugin cache is the failure that rule exists to prevent, so the
desired-state entry **absorbs** an older autoupdate entry rather than
sitting beside it. `railyard:setup` installs it on request.

```bash
roundhouse fleet-run --fast    # the fast slot; also the default with no flag
roundhouse fleet-run --full    # the heavy slot
```

| Platform | Shape |
| --- | --- |
| macOS | one per-user launchd agent, `~/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist` |
| Linux | a systemd **user** timer pair, `roundhouse-fleet-fast.timer` and `roundhouse-fleet-full.timer`, with `Persistent=true` so a sleeping laptop catches up once rather than storming |
| Windows | a per-user scheduled task; where the machine has a WSL sibling, registered there and driving the native side through the interop lane |

Both intervals are jittered from the host **name** rather than the clock,
so offsets are stable across restarts and the fleet doesn't re-synchronise
on one minute. The interval keys live in the store's policy block.

**The run is non-interactive by construction.** Every jj, git, and ssh
invocation it makes is closed to editors, pagers, and credential prompts,
so a scheduled run can never block on a human at a machine nobody is
sitting at.

**One runner at a time per host.** A second run finds the lock held and
exits 0 without acting — that's the ordinary overlap, not a failure. Exit
75 is the *stale*-lock refusal: a lock past two full cadences, or one
whose metadata is missing so its age can't be read. It names the recovery
rather than forcing. `fleet-unlock` releases a lock left behind by a
killed run; `fleet-lock` taken by hand exits 75 when the lock is already
held.

Privileged actions stay interactive by design. Failures land in the
store's own alert and journal records, surface in `fleet-pending`, and are
reported at the next `railyard:doctor` run.

## Policy keys

These live in the store's `fleet.yaml` under `policy:`, deliberately not
on the machine being governed — deleting `canary_group` or zeroing
`canary_wait_hours` in a file on the box being gated must not weaken the
gate.

| Key | Default | What it sets |
| --- | --- | --- |
| `fast_interval_minutes` | `20` | the propagation cadence |
| `fast_jitter_minutes` | `5` | per-host spread, seeded from the name |
| `cadence_hours` | `12` | the maintenance cadence |
| `jitter_minutes` | `90` | spread on the maintenance run |
| `canary_group` | `canary` | which group adopts first |
| `canary_wait_hours` | `24` | how long a canary's clean record must stand |
| `max_removals_per_run` | `5` | over it, the whole removal set holds |
| `max_removal_fraction` | `0.25` | …or this share of the applied set, whichever is smaller |
| `push_nudge` | `true` | the opportunistic peer accelerator |
| `evidence_retention_days` | `90` | how long journals, alerts, and findings are kept |

## Doctor is the health surface

```text
roundhouse fleet-doctor
```

It runs at the end of every full pass and on demand. **Rows are
advisory** — a failing row reports, it doesn't abort a convergence that
already happened. Every row exists because something was observed to fail
silently.

| Group | Rows |
| --- | --- |
| Prerequisites and hygiene | `tools`, `store`, `config-pins`, `rewrite-messages`, `raw-git-push`, `banned-keys`, `undescribed`, `host-local-leak`, `store-symlinks` |
| Trust | `genesis-pin`, `signing-key`, `trust-roots`, `krl`, `signature-skip`, `privileged-lane`, `head-signature`, `ratchet-replay`, `monotonicity`, `generation`, `roster-coherence`, `roster-lines`, `soak`, `class-enforcement`, `path-identity`, `materialization-digest`, `checkpoint-tags`, `archive-present`, `git-cross-check` |
| Store state | `conflicts`, `conflict-paths`, `revsets`, `working-copy`, `trailers`, `description-sweep`, `findings-sweep` |
| Convergence | `digest`, `revert-signature`, `canary-overrides`, `hooks`, `chezmoi`, `machine-truth`, `ssh-fields`, `clock`, `poll-floor`, `remote-posture`, `run-lock` |

A few worth knowing by name. **`ratchet-replay`** re-verifies every commit
between the reviewed ref and the head against its own roster-at-parent —
the trust gate asserted rather than assumed. **`materialization-digest`**
compares the roster jj actually reads against the one the ratchet derives
from the reviewed ref; a mismatch is a full hold, never a repair.
**`class-enforcement`** and **`soak`** generate fixtures on demand and
require the refusal to happen. **`canary-overrides`** reports every
`fleet-rollback --now` in the last 30 days, because a bypass nobody counts
becomes routine. **`digest`** recomputes a checked-in fixture on this host,
which catches a yq or jq behaviour change locally rather than as a
fleet-wide re-review. And **`poll-floor`** confirms the cheap head check
still works — if it fails quietly the fleet degrades to the 12-hour
cadence without saying so.

## The audit trail

Every host publishes what it did, under paths only it can write:

```text
journal/<host>/<date>.yaml     applied | held | reverted | resolved | alive
applied/<host>.yaml            what this host owns, at what digest
alerts/<host>/<stamp>-<slug>.yaml
findings/<host>/<stamp>-<slug>.yaml
upstreams/<id>/<host>.yaml
```

A journal record carries the item, the digest, the outcome, the change and
commit the signature was verified against, and the time. `outcome:
resolved` additionally names both contested sides and the resolution
commit, whose description carries the rationale — that's the one
replicated record that carries prose, and it exists so a peer can
reconstruct what was contested and why.

The `alive` record is a per-run heartbeat with no item, and it's what makes
a canary's silence visible to the gate rather than reading as a pass.

`roundhouse fleet-pending` is the fleet-wide view of everything open, from
every host. Commit descriptions carry the host, session kind, one line of
intent, and the items touched — replicated, signed, and greppable, which
is what a peer's resolver reads when it has to decide without asking
anyone.

## Go deeper

- **[The fleet store](store.md)** — the layers, the fold, the categories.
- **[How a change travels](convergence.md)** — the gates, in order.
- **[Trust](trust.md)** — the ratchet and the membership lifecycle.
- **[Why jj](why-jj.md)** — what the version control buys.
