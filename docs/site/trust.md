# Trust

Every machine in the fleet can write to the store. What decides whether a
write counts is a single ordering rule, and everything else in this page
is detail on it.

## The ratchet, in one paragraph

The store carries `trust/signers.yaml`, a plain hand-editable list of
which machine key may write. **A change to that file counts only if it is
signed by a key the file already trusted one commit earlier** — so
membership can only ever be extended by a current member, and the chain
traces back to a genesis commit whose id every host pins. To add a
machine, you tell any machine you already have: "add wren." Its agent
reaches wren over the same SSH lane the fleet already uses to run commands
there, has wren mint a key, reads it back over that channel, and commits
it to the roster. Every other machine accepts wren within one fast
interval, because it can verify the whole story from the repository it
already fetches. To remove a machine, you say "remove wren": its block
moves to `retired:`, its old commits stay valid, and its new ones stop
verifying everywhere on the next fetch.

There is no CA, no certificate, no authority key, and nothing to keep safe
beyond the ordinary per-machine key each host already holds.

**Why the parent, and not the head.** Reading the roster at the current
head is circular: the file being verified supplies the keys that verify
it, so one commit replacing the whole roster with an attacker's key is
self-consistent and passes. Evaluating at the parent reads a strictly
earlier point in a history whose ordering is hash-secured. That single
rule is the load-bearing part of the whole model.

## The roster

```yaml
generation: 47

durable:                          # full authority; may sponsor either class
  vireo:
    principal: vireo@fleet.novotny.org
    key: "ssh-ed25519 AAAAC3Nza...OM3wmFt"
    enrolled_by: genesis
    channel_auth: genesis
  wren:
    principal: wren@fleet.novotny.org
    key: "ssh-ed25519 AAAAC3Nza...EW2hm/c"
    enrolled_by: vireo
    enrolled_at: "2026-08-07T09:00:00Z"
    channel_auth: known_hosts

ephemeral:                        # leaf. Own evidence paths only.
  build-x7f2:
    principal: build-x7f2@fleet.novotny.org
    key: "ssh-ed25519 AAAAC3Nza...9qT4vLm"
    sponsor: vireo
    job: railyard-deliver-01J9X2
    channel_auth: runtime
    valid_after:  "2026-08-07T09:00:00Z"
    valid_before: "2026-08-08T09:00:00Z"

retired:
  corvid:
    key: "ssh-ed25519 AAAAC3Nza...gJ07"
    revoked_at_commit: 8a1f2c9e   # commits BEFORE this stay good
```

One block per machine, listing its key by value. `generation:` is a
monotonic counter, and it's half the rollback defence.

## What a commit has to satisfy

A commit `C` signed by principal `P` is accepted when all of these hold:

1. The signature status is `good`. `unknown` is a failure, always — "not
   yet enrolled" is a newcomer's normal transient state and is
   deliberately indistinguishable from an attacker.
2. The principal the *signature* derives equals the commit's own committer
   identity. A valid roster key can still author a commit claiming another
   host's name; this is the check that catches it.
3. `P` is in the roster materialised from **every one of `C`'s parents**.
   Additions gate forward. "Every" rather than "the" is deliberate:
   merges are routine here, and reading one parent lets a removed member
   keep pushing forever by parenting their commits before their own
   removal.
4. `P` is in the roster at **this host's current reviewed head**. Removals
   bite backward.
5. `P` is not in this host's revocation list.
6. `P`'s class — read from the same rosters rule 3 used — permits the
   paths `C` touches. Reading class from the head instead would let a
   later promotion retroactively legalise a past commit.

Rules 3 and 4 are the two-sided check, and 3 alone or 4 alone each leaves
a hole the other closes.

**Additions need no propagation window**, because of one structural
property: the enrolling commit is authored by the *sponsor*, and the
newcomer clones after it lands. So every commit a newcomer ever authors
has its own enrollment as an ancestor, and **a host cannot possess a
newcomer's commit without possessing the commit that enrolled it.** A host
offline for six weeks fetches once and receives the enrollment and the
work it authorises in the same transfer, correctly ordered, with no
transient `unknown` state and no action taken anywhere. Enrollment is
complete only when the sponsor's commit is on the remote, and `fleet-add`
blocks on that push.

## Two classes, and the class is the boundary

| | `durable` | `ephemeral` (leaf) |
| --- | --- | --- |
| Fleet-shared layers, `definitions.yaml`, `lineage/`, `proposals/`, `checkpoints/` | write | **refused** |
| Own host-keyed paths (`journal/<self>/`, `applied/<self>.yaml`, `alerts/<self>/`, `findings/<self>/`) | write | write |
| Another member's host-keyed paths | refused | refused |
| `trust/signers.yaml` — that is, sponsoring | write | **refused** |

The class is the section of the file the entry sits in, and putting it
there was itself a ratchet-valid act by a durable member. It is never
self-asserted.

**Leaves may not sponsor**, and that's the whole anti-explosion rule. A
forty-container burst produces forty leaves, all at depth one under one
durable sponsor, so chain of custody is one hop always — no transitive
closure to compute, no cycle to detect, and every lineage question is one
`yq` select rather than a graph walk. It costs exactly one refusal.

Host-keyed evidence takes a pure equality check with no exceptions: a
record under `journal/wren/` must be signed as `wren@<domain>`. That's
what gives the canary gate its integrity, makes forged peer evidence
inert, and lets a leaf slot into the journal machinery with no special
casing — a leaf cannot forge anyone else's evidence.

## Adding a machine

```text
roundhouse fleet-add wren
```

That is the whole bootstrap for a new host. `wren` is the **roster
identity** — the name every host-keyed path and every signature is checked
against — and the **transport** comes from that machine's configured
`ssh_alias`, so a machine you reach as `claires-wren` is still `wren` in
the roster. On the machine you're already on, the agent reaches it over the
existing SSH lane, resolves roundhouse on the far side (a launcher on PATH
if there is one, otherwise the plugin cache), installs the prerequisites,
runs `fleet-init`, has wren mint its own key, reads the public key and a
possession proof back over the same channel, hands wren the remote URL and
store id over that channel, commits the roster line, pushes, and has wren
prove the remote is gated for itself. **Nothing runs on any other host, and
no human touches any other host.**

Enrollment is two-sided and needs no bearer credential. An enrolled host
supplies **authorisation** — its roster key makes the commit
ratchet-valid. The channel supplies **identity binding** — the key was
generated on, and read back from, a machine that host could reach at the
name the instruction gave. Neither side alone enrols. The channel
introduces no new assumption either: the fleet already grants
SSH-to-a-named-host full code execution for every other fleet operation.

The newcomer additionally signs its own principal in a dedicated
`roundhouse-enroll` namespace, so a sponsor can't enrol a key nobody
controls — a typo, or an attacker-supplied blob. The namespace is what
keeps that proof from being replayable as a commit signature.

**How the channel was authenticated is recorded**, because it decides the
soak:

| `channel_auth` | Means | Soak before fleet-layer writes land |
| --- | --- | --- |
| `genesis` | the first host, which *is* the fleet at that moment | none |
| `known_hosts` | you had SSH'd there before | 24 h |
| `tailscale` | reached over the tunnel, which authenticates the node | 24 h |
| `runtime` | the sponsor instantiated the process namespace itself | 24 h (durable), none for a leaf |
| `tofu` | genuine first contact, host key unknown | **72 h**, plus a distinct alert class naming it |

The soak delays a newly-enrolled key's writes to *fleet-shared* layers.
Evidence paths are live immediately, so a new machine converges, applies,
and reports at once — it just can't change fleet policy on its first day.
A leaf takes no soak because a class that can't write fleet layers has
nothing to delay. The soak window is measured from the `enrolled_at` in
the roster **at the verifying commit's parents**, against that commit's
own timestamp — so a member cannot shorten their own soak, for the same
structural reason they cannot promote their own class.

**Every roster change alerts on every host and leads the recap.** On a
five-host fleet that's a two-or-three-times-a-year event. If it fires and
you didn't just ask for a machine to be added, that *is* the compromise
notification, and it arrives within one fast interval.

### The two other ways in

`roundhouse fleet-join REMOTE` runs on the newcomer instead. It clones the
private store with your `gh` credential, checks the genesis against the
store id, mints a key, and writes `joins/<host>.yaml`. That commit signs
as `unknown`, which is correct — the newcomer isn't trusted yet, and
`joins/` is inert by construction: never applied, only read as a hint. An
enrolled host then SSHes to the address, confirms the same public key is
on that machine, and commits the roster line. The hub proves credential
possession and carries the notification; SSH proves the key belongs to a
reachable machine actually running roundhouse. **The hub is the outer
boundary and never the authorisation** — if a push alone could enrol, one
stolen token would escalate from noisy nuisance to total compromise.

```text
roundhouse fleet-add build-x7f2 --ephemeral --job deliver-01J9X2 --ttl 24
```

enrols a leaf. A sandbox isn't *discovered* over a channel — it's
*instantiated* by its sponsor, which is why `channel_auth: runtime` is the
strongest binding in the system: there's no first-contact window to sit in
the middle of. The container takes a full clone, verifies the genesis,
ratchets to head, and operates offline for the whole job, because **a
complete clone is a complete peer.** Its entry ages out and the next full
pass prunes the line.

## Store identity

`store_id` is the **genesis commit id** — or, after a re-root, the id of
the checkpoint a host started from. It's compared at clone, at
`fleet-init` against an existing remote, and whenever the remote URL
changes.

It is **unforgeable rather than merely secret**: an attacker who knows
your store id still cannot produce a store with that genesis. It's also
data, not a human step — genesis produces it as an *output*, reported
upward to the orchestrator or into the session transcript, and from then
on it travels down the instruction chain or is read back over the
enrollment channel. One further genesis check: the genesis roster must
list the key that signed it.

## Removing a machine

```text
roundhouse fleet-remove wren            # --burn adds the emergency lever
```

**Revocation lives in the chain, and position in history decides
validity.** The command moves wren's block to `retired:` with
`revoked_at_commit`, retires in the same commit the leaves wren sponsored,
deletes `hosts/wren.yaml`, appends the `lineage/` record, and pushes. It
propagates on the ordinary store path within one fast interval, on every
host, with no per-host step and no checklist. Then:

- wren's **future** commits verify against a roster-at-parent that no
  longer lists it — `unknown`, held everywhere.
- wren's **past** commits verify against rosters that did list it — still
  good. The fleet doesn't take an outage to cut off one machine.

Expiry, retirement, and suspension are one rule: **freeze at position in
history.** A stopped container is not a security event — its window
lapses, every commit it already made stays good, and restarting it is one
field (`fleet-renew`) or one block (`fleet-add --ephemeral` with the same
key). Identity continuity is free because the key never changed.

New hardware means a new key, correctly: `fleet-reconstitute HOST` writes
one commit that records the rebuild in `lineage/`, installs the new key,
retires the old entry, and reparents the old host's leaves onto the new
one — so nothing that host sponsored lapses at any point during the
rebuild.

Lineage is **cleanup metadata and nothing else.** No verification path
reads `sponsor:` or `enrolled_by:`. A member's validity is decided by
three things: is its key in the roster at the verifying commit's parents,
does its class permit this path, is the commit's timestamp inside its
window. **A sponsor's departure cannot invalidate its leaves** — in an
agent fleet, sponsors are rebuilt routinely, and a rebuild that silently
killed forty running sandboxes would be a failure mode manufactured for
its own sake.

**The revocation list is the emergency lever.** It is retroactive and
total: adding a key to it flips *every commit that key ever made* to bad,
and holds every item resolved from every file those commits touched. On a
fleet where any durable host may edit any shared layer, that's a
self-inflicted outage only a full re-commit of every layer file clears.
`fleet-remove HOST --burn` prints the out-of-band procedure rather than
running it. The in-band lever bites first and bites everywhere; this one
is the deliberate second.

## Keeping history bounded

Three things would grow forever, and each gets its own lever.

**Expired leaf entries** are pruned on the existing 12-hour full pass.
Pruning is safe because an old commit is verified against the roster at
*its* parent, where the entry still exists. At 40 joins a day with a
24-hour TTL, the file holds around 60 leaf lines and the `durable:`
section — the part a human reads — stays five.

**Evidence** ages out on a retention window (`evidence_retention_days`,
90 by default) on the same pass. Evidence paths are never inputs to
verification, so aging them is a pure `rm` with no trust reasoning
attached — which is exactly why it's decoupled from the trust checkpoint
below. A canary window is hours; a trust checkpoint is months.

**History** is bounded by checkpoint and re-root.

```text
roundhouse fleet-checkpoint    # signed roster+state snapshot, tagged
roundhouse fleet-reroot        # archive ref, then a new root
```

A checkpoint is an ordinary commit carrying one record, ratchet-valid like
anything else — signed by a durable member, verified against the roster at
its parent. It's **tagged**, and jj's default immutable set includes
`tags()`, so a tag makes the commit and all its ancestors immutable with
no configuration. Verification then replays from the last checkpoint
rather than from genesis, which is the difference between a bounded
startup cost and one that grows forever.

**The archive ref is part of the protocol, not hygiene.** A re-root is
byte-for-byte indistinguishable from a rollback attack except by the
archive: a host offline across one finds that its monotonic reviewed ref
isn't an ancestor of the new root, which the rollback rule says to treat
as an attack, hold, and alert. That behaviour is correct and stays. The
catching-up host fetches the archive, finds its reviewed ref there,
verifies the chain forward to the checkpoint by the ordinary ratchet rule,
checks the checkpoint's signature and that `generation` didn't go
backwards, and only then adopts. `fleet-reroot` refuses to proceed when
the archive ref doesn't publish — and if the archive doesn't contain the
victim's reviewed ref, the victim never adopts. That branch *is* the
rollback protection.

## What jj and ssh-keygen actually read

Never the working copy. Reading `trust/signers.yaml` straight from the
checkout would be the circular version of this model.

| Artifact | Path | Written by |
| --- | --- | --- |
| Steady-state roster | `/usr/local/etc/roundhouse/allowed_signers` | the privileged lane |
| Per-commit roster | a per-run temp dir (`$TMPDIR/roundhouse-fleet-run.XXXXXX/rosters/`) | the run, for the ratchet only, removed at run end |
| Reviewed-ref high-water mark | `/usr/local/etc/roundhouse/reviewed-ref` | the privileged lane |
| Generation high-water mark | `/usr/local/etc/roundhouse/generation` | the privileged lane |
| Revocation list | `/usr/local/etc/roundhouse/krl` | the privileged lane |

Every trust decision passes the roster derived from *that commit's*
parents, per invocation. The steady-state file serves signing and any
ad-hoc `jj log` you run.

Root ownership buys one specific thing, and it's worth naming precisely.
An attacker with your shell already holds the signing key — they are
already this machine, and they don't need to self-enrol. What root
ownership prevents is **persistence past revocation**: revoke that host
and, with a root-owned roster, the locally appended key never existed
anywhere else and the host's own copy is corrected on the next update.
With a user-owned roster, the revoked machine keeps trusting the attacker
— and that's exactly the machine you were cutting off.

Where the privileged lane isn't configured, this degrades to same-user
custody **and says so**, every run and every doctor pass. Passwordless
sudo collapses root ownership to same-user, and doctor reports that rather
than failing on it. (On Windows, this POSIX roster ratchet doesn't run at
all — the privileged SSH broker carries its own trust store under
`%ProgramData%\Roundhouse\trust\` with an ACL denying the interactive user
write, a separate CA/KRL mechanism, `fleet-ca.pub` and `revoked.krl`, not
this page's per-commit roster.)

Alongside ownership there's detection, which fails in a different
direction and is nearly free: every run compares the materialised roster
against the roster the ratchet derives **from the reviewed ref** — the
state this host has actually verified, rather than the head it's about to
adopt. A mismatch is a loud alert and a full hold, never a repair. One
`sha256` compare, no privileges, and it catches the case ownership misses
entirely: an attacker who *does* get root.

## What this rests on

Stated plainly, because a trust model that hides its floor is worse than
one that names it.

> **Authority is custody of your GitHub account, times the integrity of
> whatever session was told to do the work.**

The store is a private repository; only your credential can create, find,
clone, or push to it — that's the outer boundary on who participates at
all. And whichever session was told "set up the fleet" or "add wren"
carries the authority, whether the instruction came from you typing it or
an orchestrator relaying it.

Everything else on this page bounds what a compromise of those two can do
and how fast it's noticed. An agent that is prompt-injected into running
"add attacker-box" enrols an attacker, and no cryptography here detects
that, because from the store's point of view it is indistinguishable from
you asking. **The model secures the wire, not the intent.**

What still applies, in that case, is containment:

- **The alert.** Every roster change fires on every host within one fast
  interval and leads the recap.
- **The soak.** During the window the new key can write nothing but its
  own inert evidence — which makes enrolling *worse* for an attacker than
  not enrolling. Writing as the compromised host lands in 20 minutes;
  writing as the new key lands in 24 hours.
- **The downstream gates.** Apply-time review on the receiving host,
  canary evidence a forged key can't produce, and the removal caps.
- **Revocation.** One instruction, in-band, every host, no checklist.

Four more residuals, named rather than papered over. **Trust on first
contact** is open where the host key is genuinely unknown — closable only
by a human check or a pre-shared secret — so it's recorded in
`channel_auth`, given the 72-hour soak, and made loud. **A rollback
against a host that's been offline since before a revocation, or restored
from an old backup, succeeds**; it buys an attacker persistence, never
entry, and the generation check fires the moment that host talks to any
current host. **A same-user-writable roster reduces this model to no
model**, per the paragraphs above. And **availability is out of scope**:
every control here fails to `hold`, and a held item is an unavailable
item. A leaf's write to a fleet-shared layer is refused at verification on
every host, but the refused commit still exists in the history every host
fetches — so it degrades what it touched until a durable member supersedes
the file. The hold is narrowed to only the items whose values that commit
actually changed, which bounds a leaf to degrading what it wrote rather
than freezing a whole file by brushing against it. This design buys
integrity and attribution.

## Go deeper

- **[Threat model](security/threat-model.md)** — the same model at audit
  altitude: the four boundaries, the actor-capability matrix, and every
  residual stated unhedged. Written for external review.
- **[The fleet store](store.md)** — what's in the repository.
- **[How a change travels](convergence.md)** — where these gates sit in a run.
- **[Running it](operating.md)** — the membership verbs, and doctor.
