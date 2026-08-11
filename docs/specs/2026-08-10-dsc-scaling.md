# Roundhouse DSC — scaling design

Status: **design deliverable, rev 1** · 2026-08-10 · no implementation in this
document.
Reads on top of `docs/specs/2026-08-06-dsc-storage-design-v2.md` (the storage
core: four layers, host-keyed appends, one `main` bookmark, the §7 trust
ratchet) and `docs/specs/2026-08-06-unattended-privileged-updates.md` (the
broker and the unattended cadence that decides how often each host writes).

**Design target: ~30 nodes.** Every mitigation below is sized against that
number and stated so the next tier is a build, never a rewrite. Nothing here
is a reason to defer growth: the breakpoints are named precisely so the fleet
can pass one without discovering it in production.

One sentence: **the desired-state path already scales and needs no rework; what
does not scale is the evidence path, because a single repository holds every
host's convergence record forever and every node clones all of it.**

## What scales as it stands

- **The fold is O(1) per host.** `fleet_fold` resolves one host's desired state
  from the four layers (`fleet.yaml`, `os/`, `groups/`, `hosts/<name>`). Adding
  a node adds one host file and changes no other host's resolution cost. This
  is the single most important scaling property in the design and it is already
  right.
- **Convergence is pull-based and per-host.** Each node runs its own
  `fleet-run` on its own jittered cadence (`fleet_run_interval_seconds`, seeded
  from the host name so the fleet spreads rather than synchronising). There is
  no scheduler, no controller, no lease, and therefore no central component
  whose capacity has to grow with the fleet.
- **Host-keyed evidence paths cannot conflict.** `journal/<host>/`,
  `alerts/<host>/`, `findings/<host>/`, `applied/<host>.yaml` and
  `upstreams/<id>/<host>.yaml` have exactly one writer each (§7.3's path→identity
  table enforces it cryptographically). N hosts appending concurrently produce
  no merge work at all — the reconcile runbook (§8.2) only ever arbitrates
  *hand-edited shared layers*, and those are edited by people at human rates.
- **Canary blast radius is constant.** `fleet_canary_gate` holds every
  non-canary host behind evidence from the canary group, so a bad desired-state
  edit reaches `canary_wait_hours` worth of machines regardless of fleet size.
  A 300-node fleet is no more exposed than a 5-node one.
- **Push contention is absorbed, not queued.** `fleet_vcs_publish` recovers a
  concurrent remote move by fetching, reconciling through §8.2 and re-pushing
  once. Contention grows with fleet size but the recovery is O(1) per push and
  needs no coordination.

## What breaks, and roughly where

| # | Limit | Mechanism | Rough breakpoint |
|---|---|---|---|
| 1 | Unbounded evidence in a fully-cloned repo | every node's `journal/<host>/<date>.yaml` accumulates per host per day, forever, in the one repository every node clones in full | **~30 nodes** |
| 2 | Roster and trust ratchet are O(members) | `trust/signers.yaml` is one file re-derived and re-verified per commit; the soak/ratchet walk reads it per verification | ~75 members |
| 3 | Central "installed where" view is O(nodes) | answering "which hosts carry item X" means reading every `applied/<host>.yaml` (and, for history, every host's journal) | ~75 nodes |
| 4 | Enrollment is sequential | `fleet_add_command` is one host per invocation: SSH bootstrap, key read-back, possession proof, roster commit, **and a blocking publish to `main@origin`** each time | ~50 nodes onboarded at once |
| 5 | `main` is a single write hotspot | every host's every run pushes to the one bookmark; each collision costs a fetch + reconcile + re-push | ~100 nodes at the shipped 12h/20m cadences |

Limit 1 is the one that arrives first and it is the one that compounds: it is
simultaneously a clone-size problem, a fetch-bandwidth problem, and a
`fleet_journal_entries` read-cost problem (the canary gate parses a canary's
whole journal on every gated item on every run). At ~30 nodes on the shipped
cadence the journal is the dominant object in the repository.

Limits 2 and 3 are read-side and degrade gracefully — slower, not wrong.
Limit 4 is a one-time cost paid at onboarding. Limit 5 is last because jitter
spreads the writes and the recovery path is already correct.

## Mitigations

### Recommended as the next build — journal compaction / TTL (limit 1)

Bound evidence retention. The journal's consumers all read a *recent* window:
the canary gate reads back to `applied_at + canary_wait_hours`;
`fleet_vcs_revert_signature` reads this host's own outcome sequence for one
item; `fleet-pending` and the doctor read the current state. None of them needs
a year of day-files.

The shape: a retention policy key (desired state like every other policy, so it
is signed and reviewable), a compaction pass in the full cadence that folds
day-files older than the window into a per-host summary record, and a hard
floor at `canary_wait_hours` so compaction can never remove evidence a gate is
still entitled to read. Compaction is a host writing *its own* host-keyed path,
so it stays inside §7.3 and needs no new authority.

This is the only mitigation recommended for the ~30-node target. Everything
below is named, sized and deferred.

### Named and deferred — per-group store sharding (limits 1, 2, 5)

At ~75+ nodes, split the store per group: each group gets its own repository
with its own `main`, and the fleet-wide layers replicate into each shard. Cost:
a cross-shard read is no longer one clone, and the trust roster has to be
either shared or per-shard with a bridging rule. Benefit: clone size, roster
size and push contention all become per-group rather than per-fleet.

**Constraint this places on the evidence topology today:** whatever holds a
host's convergence evidence must be splittable per group **without rewriting
history**. Host-keyed paths under one bookmark satisfy this — a shard is a
filtered subset of paths, and each host's evidence is already an independent
path prefix signed by exactly that host, so a shard's history is a valid
projection rather than a rewrite. Any future evidence topology (see the open
decision below) has to keep that property.

### Named and deferred — a materialized aggregate index (limit 3)

A single generated `materialized/index.yaml` answering "item → hosts carrying
it at digest D", rebuilt by whichever host runs the full pass, so the central
view is one read rather than N. It is derived state and therefore discardable:
it must never be an input to an apply decision, only to a human's question.
Deferred until the O(nodes) scan is actually slow (~75 nodes).

### Named and deferred — batched enrollment (limit 4)

`fleet-add` publishes to `main@origin` before returning, by design (a host
cannot possess a newcomer's commit without possessing the commit that enrolled
it). Batching means one roster commit carrying N newcomers with N possession
proofs, published once. The ancestry property is preserved because the batch
commit is still an ancestor of everything the newcomers write. Deferred until
someone is onboarding tens of hosts in one sitting.

## Commercial / multi-tenant operation

Possible later commercial or multi-tenant operation is a **consideration for
the sharding design, not current architecture.** The single relevant
implication: a shard boundary that can also be a *tenant* boundary is strictly
more useful than one that cannot, so per-group sharding should key on an opaque
shard identity rather than on the group name, and the fleet-wide layers should
replicate *into* shards rather than being read *across* them. Nothing else in
this document changes for a multi-tenant future, and nothing should be built
for it now.

## Recorded decisions

### iris-windows becomes a native roster member (user decision, 2026-08-10)

iris-windows joins the roster as a full member in its own right, not as state
covered by its WSL sibling.

**Rationale.** Coverage-by-sibling makes iris-wsl's roster identity sign for a
machine it is not — which is exactly the equality §7.3 exists to enforce, and
the one place the design refuses an exception ("host-keyed evidence must verify
as EXACTLY `<h>@<domain>`, with no exception for any host"). A Windows machine
whose desired state is real but whose evidence is signed by a Linux machine
would be permanently outside the trust model, and every audit of it would have
to carry a footnote. Native membership costs a toolchain; the alternative costs
the property the whole store is built on.

**What native membership requires** (a follow-up plan, not this one):

- **jj on Windows** — the store is a jj repository and every read in
  `lib/fleet-vcs.sh` is a jj call. jj ships Windows binaries; the store's pinned
  config (`fleet_apply_jj_pins`) has to be verified against them.
- **A Windows `roundhouse` launcher** — the same gap G1 closes on POSIX, in its
  Windows form. The launcher work in this build is deliberately structured
  POSIX-first and cross-platform-ready so the Windows shim is an addition, not
  a redesign.
- **SSH-reachable enrollment** — `fleet_add_command` bootstraps the newcomer
  over `ssh_run`, which is POSIX-shell-shaped (`exec "$SHELL" -lc …`).
  iris-windows currently uses the `codex-remote-control` transport with
  `wsl_interop_via: iris-wsl`; enrollment needs either an OpenSSH server path or
  a transport-specific bootstrap.
- **Signing** — `ssh-keygen -Y sign` against a Windows-resident node key, and
  `system_ssh_keygen_path` has no Windows arm (it refuses on anything that is
  not Darwin or Linux).

## Open decision — the evidence topology (blocks U1 of the 2026-08-10 plan)

Recorded here because U5 was written to constrain U1 and the constraint turned
out to be a contradiction that only the owner can resolve.

**What the plan assumed.** That host convergence evidence already lands on
`host/<name>` branches for remote hosts, and that the hub leaks its own
evidence onto `main` through `fleet_run_publish` — a hub-only bug at the
publish seam.

**What the code and the spec actually do.** There are no `host/<name>` branches
anywhere in the implementation. `fleet_vcs_publish` pushes `--bookmark main`
and nothing else; every host, hub and remote alike, writes its evidence to
host-keyed *paths* on that one bookmark. This is not drift — the v2 storage
design deleted host branches deliberately and says so
(`2026-08-06-dsc-storage-design-v2.md` §2: "**No `host/<name>` branches**",
with the rationale that the branch-checkout sandwich can strand the store on
the wrong branch, and that "evidence a human cannot `ls` is evidence they will
not read"). Host-keyed paths were adopted as giving the same single-writer
guarantee at lower cost.

**Why this is not a publish-seam edit.** Every reader of evidence resolves it
from the one working copy: `fleet_canary_gate` parses `journal/<canary>/` for
each canary on every gated item; `fleet_applied_digest`,
`fleet_run_is_revert`, the trust soak reads, `fleet-pending` and the doctor all
do the same. Moving evidence to per-host branches means every host fetching and
reading N branches to answer questions it answers today from one tree, and
`fleet_vcs_path_owner`'s §7.3 identity table would need a second addressing
mode. That is a re-architecture of the evidence read path on a signed store
every machine reads.

**The decision needed.** Either (a) R1 is satisfied by bounding evidence rather
than relocating it — journal compaction/TTL above, which addresses the
scaling concern R1 was reaching for while keeping the shipped topology — or
(b) the v2 decision to delete host branches is deliberately reversed, which is
its own plan with its own review, not a unit inside this one.

Recommendation: **(a)**. It is the smaller change, it is the mitigation this
document already recommends on independent grounds, and it preserves the
per-group-splittability property sharding will need. A characterization test
pinning today's placement (evidence on `main`) ships with this build so that
whichever way the decision goes, the current behaviour is asserted rather than
assumed.
