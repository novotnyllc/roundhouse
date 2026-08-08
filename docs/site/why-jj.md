# Why jj

The fleet store is a [jj](https://jj-vcs.github.io/jj/) repository,
colocated with git. Six properties of jj do real work here, and each one
maps to a behaviour you'd otherwise have to build.

## A conflict is a commit, and it never blocks

In jj a conflict is recorded state, not a stuck working copy. A merge that
conflicts still commits, still has parents you can read, and still lets
every command that isn't about the conflicted path proceed.

That is what makes item-level convergence possible. While a conflict is
open, the run reads **each head's own copy of each layer file** — clean,
parseable YAML, at a real signed commit — folds each side, and compares
the resolved values item by item. One contested key holds that key. Every
other item in the same file, in the same group, on every host in that
group, converges normally.

It's also what lets the resolver work at all. The run's agent reads both
sides' values, both sides' commit descriptions, and both sides' journal
history *while the merge is still conflicted*, and decides from that
evidence. A tool that wedged the working copy would have nothing to read.

With `ui.conflict-marker-style = "snapshot"`, the markers a human sees are
each side of the file at correct YAML indentation, labelled with change
id, commit id, and description. You delete the lines you don't want and
save. There is no resolve subcommand to learn, no continue, no abort.

And because a conflict is ordinary state rather than a broken repository,
the store can be **publication-silent** while one is open — converging
locally, publishing nothing — and then push one clean fast-forward once
the resolution is folded back into the commit that carried it. No host
ever fetches a conflicted tree.

## Auto-snapshot means an edit is already durable, and already signed

The next jj command in the repository snapshots whatever is on disk into
the working-copy commit. With `signing.behavior = "own"`, that snapshot is
signed with this host's key — one signature per command, no watcher
process, no daemon.

So "editing is editing a file" is literally true. Save `hosts/vireo.yaml`
and the edit is a signed commit before anything else happens. There is no
commit step to forget, no staging area to get wrong, and no window where
a hand edit exists as untracked bytes that a run might discard.

It also means the *human* and *agent* paths through this system are one
path. Both produce a signed snapshot; both go through the promote gate;
both are reviewed on every host that receives them. Nothing had to be
built to make hand edits first-class, because there was never a second
mechanism for them to be excluded from.

Signing is per-host: each machine's committer identity is its own roster
principal. That's what gives the identity gate something to compare, and
it's why a rewrite of another host's commit **strips** the signature
rather than silently re-attributing it — which fails loud, in the safe
direction, and recovers when the authoring host re-signs.

## Change identity survives rewrites

A jj change keeps its identity across amend, rebase, squash, and re-sign,
while its commit id changes.

Re-signing an unsigned commit is therefore free: the content is identical,
the value digest is unchanged, the recorded verdict still binds, and the
item applies **without re-review**. Fixing a signing mistake isn't a
security event, and making it cost a review prompt is how you train
someone to click through prompts.

The stable identity is also what makes evidence readable. A journal record
names the change that last touched a contributing layer alongside the
commit id whose signature was verified, so a conflict resolution can name
both parent changes and the resolution change, and those names still refer
to the same edits after any of them is rewritten. When two hosts
independently re-sign the same commit, jj calls the change **divergent** —
one change, two commits — and that's treated exactly like a conflict: hold
the contributing items, alert with both commit ids, converge everything
else.

## The operation log is a real undo

jj records every operation on the repository, and `jj op restore <op>`
puts the whole repository back to a prior operation.

The run records its starting operation id in `store.run/` and prints it,
along with whether it pushed. So "this run did something wrong on this
box" has a precise, immediate, host-local answer that touches nothing else
and reverts nothing anyone else did.

The op log is deliberately **not** the journal. It's host-local, never
pushed, erasable, and it records jj operations rather than roundhouse
decisions — which is exactly why the fleet-wide mechanism is a signed
revert commit flowing through the ordinary gates instead. Two levers, two
scopes, no overlap.

## Immutability comes from tags, for free

jj's default immutable set is `trunk() | tags() | untracked_remote_bookmarks()`.

Two things fall out. Everything reachable from the remote's `main` is
already immutable, which in steady state is the whole of enrollment
history — a stray rewrite of a trust commit fails with an error rather
than succeeding quietly. And a checkpoint gets its protection by being
**tagged**: the tag makes that commit and all its ancestors immutable with
zero configuration, which is what lets verification replay from the last
checkpoint instead of from genesis.

Revsets answer the audit questions on the same graph:
`descendants(<enrollment commit>)` is everything a member ever wrote,
`<checkpoint>..head` is the range to replay.

## Colocated git hosts it anywhere

The store is a jj repository with a real `.git` beside it, so the remote
is an ordinary private git repository — GitHub, or anything else that
speaks git. No server component, no custom protocol, nothing to run.

That buys three concrete things. The **poll floor** is one
`git ls-remote` round trip: the entire "is there anything new" check, with
no object negotiation and no transfer, which is what makes a 20-minute
interval a bandwidth decision rather than a load decision. **Peer fetch**
is a second git remote per peer, and jj namespaces remote-tracking
bookmarks per remote — `main@origin` and `main@peer-wren` are different
refs, so one stale peer cannot roll back anyone's view of `main`. And
`git verify-commit` serves as an independent cross-check on a doctor
fixture, so the signature gate is confirmed by something other than the
thing implementing it.

The git side is pinned hermetic per repository — no signing, no pager, no
editor — so an agent that shells out to git inside the store gets the same
non-interactive behaviour everything else has.

`git.abandon-unreachable-commits = false` is set for a specific failure:
with the default, a force-pushed remote makes a fetch abandon local
commits that became unreachable, which is silent deletion of an offline
host's unpushed work. Pinning it costs nothing and the alternative costs
data.

## Nothing this system runs can wait for a human

That's a hard requirement, not a preference: a run that can block on a
prompt hangs a machine nobody is sitting at.

jj makes it enforceable. `ui.paginate = never` and `ui.editor = "true"` mean
a rewrite command that would otherwise open an editor completes silently
instead. Every rewrite the runbook issues carries an explicit message
flag. The environment closes stdin and refuses SSH prompts outright. And
`fleet-doctor` asserts the effective configuration values rather than the
file contents — because the repository config is host-local and jj
migrates it out of the tree.

## Go deeper

- **[The fleet store](store.md)** — the layers and the fold.
- **[How a change travels](convergence.md)** — where each of these shows up in a run.
- **[Trust](trust.md)** — signing, the roster, checkpoints.
- **[Credits](credits.md)** — jj and the rest of the tools this is built on.
