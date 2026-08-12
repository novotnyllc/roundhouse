---
name: fleet-agents
description: Inventory and reconcile Codex and Claude runtimes, safe settings, plugins, standalone skills, skills-cli provenance, JSM-managed skills, and logical capabilities across machines. Use when agent tooling, Remote Control defaults, models, updates, or skills are missing, duplicated, stale, or inconsistent.
---

# Fleet Agents

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md` and
`CLI="$SKILL_DIR/../../scripts/roundhouse"`; the shell working directory
is not the skill directory. Collect `--section agents --section auth` when
evaluating capability readiness; provider-only inventory may collect just
`agents`. Windows tasks must pass `-AllowAuthVerify` for the combined readiness
check. Compare
runtime versions, plugin name/version/manager, standalone skill hashes and
origins, skills-cli lock metadata, JSM provenance, and configured logical
capabilities. Read `"$SKILL_DIR/../../references/agent-settings-and-auth.md"`
before auditing agent settings, runtime installation, model policy, or Remote
Control. Treat the same capability delivered as a plugin and a standalone
skill as equivalent only when the config says so; report duplicate providers.

Use manager-native ownership:

- Codex plugins: use Codex marketplace/plugin commands.
- Claude plugins: use Claude marketplace/plugin commands.
- skills-cli installs: use `npx skills check` or `npx skills update` and retain
  `.agents/.skill-lock.json` provenance.
- JSM installs: use JSM for inventory/update when its metadata proves ownership.
- local source skills: update their owning repository; do not overwrite them
  with a package manager.

## Desired-state sync

Fleet-wide desired state — plugins with enabled state, MCP servers, skills,
agents, hooks, packages, projects, and harness config keys — lives in the
**fleet store**, a jj repository whose design is
`docs/specs/2026-08-06-dsc-storage-design-v2.md`. The store is the source of
truth; every command below reads or writes it and nothing else.

Desired state lives here; root-touching authority lives with the privilege
broker per `docs/specs/2026-08-06-unattended-privileged-updates.md`. That
seam is unchanged by the storage design and must not change without
cross-checking the sibling spec.

### The store, and how an edit travels

The store is **four layers of plain YAML**, folded low to high, last wins:
`fleet.yaml` → `os/<platform>.yaml` → `groups/<group>.yaml` (in the host's
own `groups:` order) → `hosts/<name>.yaml`. Every tier also accepts a
directory (`hosts/vireo/skills.yaml`), merged in filename order after the
flat file. `definitions.yaml` maps an item to its per-manager package name and
is the only place an exception belongs. Everything else in the tree —
`applied/`, `journal/`, `alerts/`, `findings/`, `proposals/`, `upstreams/`,
`lineage/` — is **evidence a host publishes about itself**, never desired
state, and is never hand-edited to change what a machine wants.

**Editing is editing a file.** Open the layer file, change the value, save.
There is no commit step and no "forgot to push":

1. The next jj command snapshots the edit into `@` and signs it with this
   host's own node key — the one the roster lists by value. There is no CA and
   no certificate.
2. The run resolves from the **reconcile point** — normally `main`, never
   `@`. The working copy is a workbench, not the reviewed line.
3. The **promote gate** parses every changed layer file with `yq -e '.'`. If
   they parse, it describes `@` and moves `main` to it. If they do not, it
   refuses to promote, alerts with yq's own message and line, and converges
   from the last good `main`. A broken file never becomes the reviewed line.
4. Re-resolution finds the changed items. Apply-time review shows
   **provenance** — which layer won, the effective value, the digest, the
   principal the *signature* derives (never the one the commit claims) — not a
   file diff.
5. Verdict → apply → `applied/<host>.yaml` → `journal/<host>/<date>.yaml` →
   describe → move `main` → push → land `@` on the pushed commit.

A host with no override for that item is a **no-op** for it. That is the
layering working, not a propagation failure.

Report drift rather than reverting it: for a `config_files` key marked
`managed`, the run reports the value on disk and changes nothing. Keys
marked `unmanaged` are not compared, not reported, and not read.

### The two cadences

One scheduled entry per host runs both (see `roundhouse:fleet-update`):

| | Command | Default | Does |
| --- | --- | --- | --- |
| Fast | `roundhouse fleet-run --fast` | 20 min ± 5 jitter | poll floor, fetch, reconcile, promote gate, review → apply → journal, publish, peer nudge |
| Full | `roundhouse fleet-run --full` | 12 h ± 90 min jitter | everything fast does, plus marketplace refresh, re-seed, promotion proposals, unpinned package updates, and `fleet-doctor` |

The **poll floor** is a head check, not a fetch: a run with nothing to pull,
nothing to push and a clean `@` exits early. Jitter is seeded from the host
**name**, never the clock, so the offsets are stable and the fleet does not
re-synchronise on the same minute. The **push nudge** is an opportunistic
accelerator only — it carries no data, says "go look", and the peer then runs
its ordinary fast path with every gate. Turn it off with `push_nudge: false`
and the fleet still converges at poll speed; nothing depends on it.

An unpinned package is kept current by the full pass — that is what anyone
gets by doing nothing. A `version:` key in `definitions.yaml` opts one
package out, and the full pass skips it rather than quietly undoing the pin.

### Supervised review, item by item

The scheduled run reviews and applies on its own. These verbs are for a human
or an agent driving one item deliberately. **Every one of them writes into the
working copy and stops** — no describe, no bookmark move, no push. The next
run publishes what they wrote through the ordinary gates, which is what keeps
the supervised surface from being a second, unreviewed path onto `main`.

```text
roundhouse fleet-explain [HOST] ITEM     # provenance: every layer's opinion, and which wins
roundhouse fleet-review ITEM pass|hold REASON
roundhouse fleet-apply ITEM              # refuses without a passing review at the current digest
roundhouse fleet-pending                 # every open alert, from every host
roundhouse fleet-hold ITEM REASON        # the fleet-visible refusal
roundhouse fleet-accept SLUG             # accept a promotion proposal
roundhouse fleet-finding SLUG SUMMARY [QUOTE]
roundhouse fleet-journal ENTRY.json|-
roundhouse fleet-lock / fleet-unlock     # the run-lock, by hand
```

Two rules make this surface safe, and neither is a formality:

- **A verdict binds to a digest.** `fleet-review ITEM hold REASON` stops *this
  host* converging that exact value, and the scheduled run honours it ahead of
  every other gate. Edit the item and the hold does not carry over — the new
  value has never been reviewed by anyone. A stale `pass` fails exactly like an
  absent one, so `fleet-apply` cannot ride yesterday's approval.
- **A hold and a review are different things.** `fleet-review ITEM hold` is a
  local decision; `fleet-hold ITEM REASON` writes the alert every host sees.
  They are two verbs so that a local refusal does not shout at the fleet.

Verdicts are **host-local** (`store.run/verdicts/`) and never replicated: a
fleet-writable verdict would put a consent-shaped artifact on a shared surface.
Alerts have no state machine — resolving one is `rm` on the file.

`fleet-finding` and `fleet-hold` pass every replicated field through the
redaction floor, and a field that trips it is **refused rather than silently
redacted**: the remedy for a published secret cannot un-publish it.

### Proposals and promotion

The full pass re-seeds (upsert, never remove) and looks for items whose value
is **identical in every enrolled host file**. Unanimity is the bar: a 3-of-5
majority is normal curation for this fleet, not drift, and produces no proposal
and no alert. A unanimous item becomes a `proposals/<slug>.yaml` suggesting the
move up a layer. Ignoring a proposal does nothing. `fleet-accept SLUG` makes
the two ordinary edits for you — write the value at the target layer, drop it
from each host file that carried it — and **the item's digest is unchanged by
construction**, so no host re-reviews anything. Promotion moves *where* a value
is written, never *what* it is.

### Conflicts, and who resolves them

Two hosts editing different layer files is not a conflict; jj merges them.
A real conflict is two hosts changing the same value, and the posture is:

- **Publication-silent while a conflict is open.** The host converges locally
  and pushes nothing — the same state it is in when offline. It does not
  publish a conflicted commit, and it refuses to publish a tree carrying
  materialized conflict markers.
- **Items disagree, not stores.** Only the items the heads actually disagree
  about go into the hold set; everything else converges normally. An item
  missing from one head is a disagreement like any other and holds — that is
  what keeps a removal from converging while the heads disagree about whether
  the item exists.
- **An agent may resolve, under evidence rules.** The resolution ladder
  decides only what the record supports — one side is a revert of the other,
  one side is already applied elsewhere, one side is strictly newer by journal
  margin, and so on. Anything the ladder cannot decide on evidence **holds and
  is reported by name**. An agent resolution is signed, journaled with an
  `outcome: resolved` record, and re-reviewed by every host like any other
  change. Do not hand-resolve by picking a side in the file and pushing; edit
  the value you actually want and let it flow through the gates.

Held items are journaled as held. Nothing is ever applied because it was
confusing. An item this design has **no state-alignment verb** for — an
`agents`, `mcp_servers` or `projects` entry, a package desired `disabled` —
journals `satisfied` instead: it resolved, it was reviewed, and there was
nothing to do here or on any other host. That is a distinct record from `held`
so an audit can tell no-op-because-correct from no-op-because-blocked, and it is
the one non-`applied` outcome the canary gate accepts as evidence — gating peers
on an `applied` record that can never be written would hold the item forever and
buy nothing. An item a host **tried and could not apply**, or that a gate
refused, still journals `held` and still blocks downstream.

### Rollback

```text
roundhouse fleet-rollback ITEM [--now]
```

Rollback is **not a special path**. It creates a signed revert commit on
`main` that flows through the same review, canary and apply gates as any other
change — which is why it can be trusted: there is no privileged undo code path
that has never been exercised. The revert rolls back the **layers** only;
`journal/`, `applied/`, `alerts/` and the other evidence directories are
restored, because reversing them would delete evidence peers have already seen
and make the host disown what it installed.

`--now` is the only canary bypass in the design, and it is bound rather than
being a flag that turns a gate off: two independent checks about *history*
must both pass, both before the bookmark moves, and the override is signed,
journaled and alerted so `fleet-doctor` counts it. A bypass nobody counts is a
bypass that becomes routine.

Rollback is honest per category: reverting a `projects` entry stops managing
the project, it does not restore repository state; `mcp_servers` and `hooks`
are reversible for **configuration only** — removing one stops it firing, it
does not undo what it already did.

### The trust ratchet

The store carries `trust/signers.yaml`, a plain hand-editable list of which
machine key may write. **A change to that file counts only if it is signed by a
key the file already trusted one commit earlier**, so membership can only ever
be extended by a current member, and the chain traces back to a genesis commit
whose id every host pins. There is **no CA, no certificate, no authority key**,
and nothing anyone has to keep safe beyond the ordinary per-machine key each
host already holds.

Reading the roster at the current head would be circular — the file being
verified supplies the keys that verify it — so an attacker who lands one commit
replacing the whole roster with their own key would write something
self-consistent that passes. Evaluating at the **parents** is not circular. That
single ordering rule is the load-bearing part.

Two membership classes, and **the class is the security boundary, not the TTL**:

| | `durable` | `ephemeral` (leaf) |
| --- | --- | --- |
| Fleet-shared layers, `definitions.yaml`, `lineage/`, `proposals/`, `checkpoints/` | write | **refused** |
| Own host-keyed paths (`journal/<self>/`, `applied/<self>.yaml`, `alerts/<self>/`, `findings/<self>/`) | write | write |
| Another member's host-keyed paths | refused | refused |
| `trust/signers.yaml` — i.e. sponsoring | write | **refused** |

**Leaves may not sponsor**, and that is the whole anti-explosion rule: a
40-container burst produces 40 leaves, all one hop under one durable sponsor, so
every lineage question is a `yq` select and never a graph walk.

`sponsor:` and `enrolled_by:` are **cleanup metadata and nothing else**. No
verification path reads them, and **a sponsor's departure cannot invalidate its
leaves** — auto-invalidating them would turn one machine's removal into a
fleet-wide outage.

### Enrolling a host

`fleet-init` and `fleet-enroll` are two commands on purpose: init leaves the
repository with **no `[signing]` block at all**, and enroll adds it only once the
key that satisfies it exists. A repo configured to sign with a key that is not
there does not merely fail to sign — `jj git init --colocate` dies and the repo
is never created.

`fleet-enroll` is **keygen plus roster registration**: no certificate request, no
authority to contact, **no sudo**, no ceremony.

**Host 1** — the host that creates the store:

```text
gh repo create <owner>/fleet-store --private   # the hub is transport, not authority
roundhouse fleet-init          # jj git init --colocate, repo config, scaffold
                               # NO [signing] yet, and NO store id yet
roundhouse fleet-enroll        # mint the node key, user.email = its principal,
                               # write [signing], then write trust/signers.yaml
                               # listing that key and commit it SELF-SIGNED.
                               # THAT COMMIT IS THE GENESIS, and it REPORTS the
                               # store id — which does not exist before it.
roundhouse fleet-set-remote <url>  # adds origin. fleet-init creates the store
                               # but no remote, so this is the step that gives
                               # the store one — it MOVES an existing remote and
                               # ADDS a missing one.
roundhouse fleet-verify-remote # REQUIRED before the first push
roundhouse fleet-seed          # discovery -> hosts/<name>.yaml + applied/<name>.yaml,
                               # including this machine's platform and groups
                               # from config.json — no hand-authored facts
$EDITOR fleet.yaml             # lift the commonalities
roundhouse fleet-doctor        # every check must pass before host 2
roundhouse fleet-run --fast    # the first convergence
```

The ordering is not stylistic: `[signing]` must follow key existence, and the
genesis commit id cannot be reported before the roster commit that *is* the
genesis. So `fleet-init` cannot be the step that names `store_id`.

**Hosts 2..N — one instruction, on a machine you already have:**

```text
roundhouse fleet-add wren
```

That is the whole bootstrap. `wren` is the **roster identity** — the config
machine name every host-keyed path and every signature is checked against — and
the **transport** is resolved separately from that machine's configured
`ssh_alias`, so a machine reachable as `claires-mac-mini` is still `mac-mini` in
the roster and needs no hand-added SSH `Host` block. The agent reaches it over
the **existing SSH lane the fleet already uses to run commands there**, resolves
roundhouse on the far side (a launcher on PATH if there is one, otherwise the
plugin cache under `~/.claude` or `~/.codex` — no shim to install), installs
prerequisites, runs `fleet-init`, has wren mint a key, reads the key and a
`roundhouse-enroll` possession proof back over the same channel, hands wren the
remote URL and `store_id` over that channel, commits the roster line, and pushes.
**Nothing is run on any other host, and no human touches any other host.**

Before it records anything, `fleet-add` settles §10.6 for the store remote: if
the remote answers unauthenticated reads it **refuses and records nothing** — no
roster edit, no alert, no identity written on the newcomer. Once the roster line
is published it has the newcomer run its own visibility probe over the same
channel. Posture is host-local and keyed on the URL that host resolves, so the
probe runs *there* rather than being copied from the sponsor.

**`fleet-add` does not clone the store for the newcomer.** `fleet-init` leaves a
store with no origin and §12's runbook has the newcomer clone, so on a genuinely
fresh host the probe has nothing to measure and `fleet-add` reports the two
commands that remain there — `jj git clone --colocate <remote>
~/.config/roundhouse/store`, then `roundhouse fleet-verify-remote`. For a host
that already carries the store — a re-add, or one that was cloned — the posture
lands automatically and its next `fleet-run` publishes.

Enrollment is **two-sided and needs no bearer credential**: an enrolled host
supplies authorization (its roster key makes the commit ratchet-valid) and the
channel supplies identity binding (the key was generated on, and read back from,
a machine that host could reach at the name the instruction gave). Neither side
alone enrols. The channel introduces no new trust assumption — the fleet already
grants SSH-to-a-named-host full code execution.

`roundhouse fleet-join REMOTE` is the fallback when the instruction lands on the
newcomer instead. It clones the private store with the owner's `gh` credential,
checks genesis == `store_id`, mints a key and writes `joins/<host>.yaml`. **That
commit signs as `unknown`, and that is correct** — the newcomer is not trusted
yet. An enrolled host then SSHes to the address, confirms the same pubkey is on
that machine, and commits the roster line. `joins/` is **inert by construction**:
never applied, only read as a hint. **The hub is the outer boundary and never the
authorization** — if hub-push alone could enrol, one stolen token would escalate
from noisy nuisance to total compromise.

`roundhouse fleet-add --ephemeral --job JOB --ttl HOURS NAME` enrols a leaf. A
sandbox is not *discovered* over a channel, it is *instantiated* by its sponsor,
which is why `channel_auth: runtime` is the **strongest binding in the system**:
there is no first-contact window to MITM.

**`store_id` is data, not a human step.** It is the **genesis commit id** —
unforgeable rather than merely secret, because knowing it does not let anyone
produce a store with that genesis. It is an *output* of setup, reported upward to
the orchestrator or into the session transcript, and from then on it travels down
the instruction chain or is read back over the enrollment channel. A human
pasting it is one of several ways that datum can travel, never a required one.

**Soak, by class.** A durable enrollment waits **24 h** before its fleet-layer
writes land — **72 h** when the channel was `tofu` (genuine first contact, where
the host key was unknown). A leaf waits **none**, because a class that cannot
write fleet layers has nothing to delay. Evidence paths are live immediately, so
a newcomer converges, applies and reports at once; it just cannot change fleet
policy on its first day. **Every roster change alerts on every host and leads the
recap**, and leaf enrollments are audit-only — paging on 40 a day trains you to
ignore the one that matters.

`fleet-verify-remote` is not optional and not a formality: **the first push
refuses without it**, by design. It probes the remote with every credential path
closed and takes a three-way verdict — only an *authentication refusal* proves
the remote is gated. A remote that answers unauthenticated reads is public and is
refused; an unreachable remote is **inconclusive and never
satisfies the gate**, because a failed probe is not evidence of privacy. Host 1
runs it by hand, in the runbook order above; hosts 2..N have `fleet-add` run it
for them over the enrollment channel.

`roundhouse fleet-set-remote URL` moves the store to a new remote. It writes the
move alert *before* the push so a crash between the two still leaves the store
carrying the record of how it got where it went, rolls that alert back if the
push fails so origin is never left claiming a move that did not happen, and
invalidates the visibility posture afterwards so the next push must re-verify.

### Removing a host, and the rest of the lifecycle

```text
roundhouse fleet-remove wren            # retire; --burn adds the KRL lever
roundhouse fleet-renew NAME [HOURS]     # same key, fresh window
roundhouse fleet-reparent               # adopt orphaned leaves
roundhouse fleet-reconstitute HOST      # new hardware, new key, one commit
```

**Revocation lives in the chain, and position in history decides validity.**
`fleet-remove wren` moves wren's block to `retired:` with `revoked_at_commit`,
retires the leaves wren sponsored in the same commit, deletes `hosts/wren.yaml`
and appends the `lineage/` record. It propagates through the ordinary store path
within one fast interval, on every host, **with no per-host step and no
checklist**. Then:

- wren's **future** commits verify against a roster-at-parent that no longer
  lists it → `unknown` → held.
- wren's **past** commits verify against rosters that *did* list it → still
  good. The fleet does not take an outage to cut off one machine.

Expiry, retirement and suspension are the same rule: **freeze at position in
history**. A stopped container is not a security event — its window lapses,
every commit it already made stays good, and restarting it is one field
(`fleet-renew`) or one block (`fleet-add --ephemeral` with the same key).
Identity continuity is free because the key never changed.

**The KRL is the emergency lever, not the default.** It is *retroactive and
total*: adding a key to it flips **every commit that key ever made** to `bad` and
holds every item resolved from every file those commits touched. On a fleet where
any durable host may edit any shared layer, revoking one machine that way is a
self-inflicted fleet outage that only a full re-commit of every layer file
clears. Use it only when the instruction is genuinely "burn its history too" —
`fleet-remove HOST --burn` prints the out-of-band procedure and does not run it.
**The in-band lever bites first and bites everywhere; the KRL is the deliberate
second one.**

### Checkpoints, re-root, and aging

```text
roundhouse fleet-checkpoint    # signed roster+state snapshot, tagged
roundhouse fleet-reroot        # MANDATORY archive ref, then a new root
```

A checkpoint is an **ordinary commit** containing one record, ratchet-valid like
anything else — signed by a durable member, verified against the roster at its
parent. No new trust rule, no new signature type, no quorum. It is **tagged**,
because jj's default immutable set is `trunk() | tags() | untracked_remote_bookmarks()`,
so a tag makes the commit *and all its ancestors* immutable for free. **A
bookmark does not do this.**

**The archive ref is part of the protocol, not hygiene.** A re-root is
byte-for-byte indistinguishable from a rollback attack except by the archive: a
host offline across one finds its monotonic `reviewed-ref` is not an ancestor of
the new root, which the rollback rule says to treat as an attack, hold and alert.
That behaviour is correct and is not softened. `fleet-reroot` refuses to proceed
if the archive ref does not publish.

Three things would grow forever and each gets its **own** lever: expired leaf
entries are pruned on the existing 12 h full pass; evidence (`journal/`,
`alerts/`, `findings/`) ages out on a retention window on the same pass; history
is bounded by checkpoint + re-root, which stays deliberate and instruction-driven
because it rewrites what every clone starts from. Evidence retention is
**deliberately decoupled** from trust checkpointing — a canary window is hours, a
trust checkpoint is months.

### What this model does not solve

Stated plainly, because a trust model that hides its floor is worse than one that
names it. **Authority reduces to two things: custody of the owner's GitHub
account, and the integrity of whatever session was told to do the work.**
Everything else is blast-radius engineering on top of those two.

- **Instruction-chain compromise has no technical mitigation.** A prompt-injected
  session can issue "add attacker-box" and the whole model executes it correctly.
  What applies is containment — the roster-change alert on every host within one
  fast interval, the soak, one-instruction revocation. What does *not* apply is
  detection. This is the largest residual and it is structural.
- **TOFU on genuine first contact is open**, closable only by a human check or a
  pre-shared secret, both of which zero-touch forbids. It is recorded in
  `channel_auth`, given the 72 h soak, and made loud.
- **A same-user-writable roster reduces this model to no model**, and root
  ownership does not prevent that attack — only *persistence past revocation*.
  Where the privileged lane is absent, or where passwordless sudo exists, doctor
  **reports** the degradation rather than failing on it.
- **Availability is out of scope.** Every control here fails to `hold`, and a
  held item is an unavailable item. A leaf's write to a fleet-shared layer is
  refused at verification on every host — but the refused commit still exists in
  the history every host fetches, so it degrades what it touched until a durable
  member supersedes the file. The hold is narrowed to **only the items whose
  values that commit actually changed**, so a leaf can no longer freeze a file by
  brushing against it. This design buys integrity and attribution, not
  availability.

### Self-update containment

`roundhouse fleet-adopt-pin PLUGIN PIN.json` gates roundhouse updating
*itself* separately from ordinary convergence, because the code that decides
whether an update is safe is the code being updated. Every other plugin rides
the ordinary review, canary and apply gates; a second gate in front of them
would be a second policy to keep in step with the first.

### Health

Before a fleet-wide operation, run `roundhouse fleet-readiness [HOST]...`; it reports per-host `jj`/`yq`, `roundhouse` PATH, SSH-name resolution, and verified-private remote rows. Chezmoi is not a prerequisite.

`roundhouse fleet-doctor` runs at the end of every full pass and on demand.
Its rows are advisory — a failing row reports, it does not abort a convergence
that already happened. One row compares the overlapping facts between
`config.json`'s machine entry and `hosts/<name>.yaml`: **platform and groups
only**. `config.json` stays hand-edited and host-local for the privilege lane;
`hosts/<name>.yaml` is the desired-state representation. Unifying them is a
separate project, not a doctor row.

The item-type reference below describes what the harnesses themselves can do,
not what any store commands.

### State-alignment capability per item type

Aligning enabled/disabled state uses manager-native commands where they
exist and reviewed config edits where they do not. The verbs below
are **verified against claude 2.1.222 / codex-cli 0.146.0** by reading each
harness's own `plugin --help`: Claude has `enable` and `disable`
subcommands, Codex's `plugin` command has only `add`, `list`, `marketplace`,
and `remove` — no state verbs at all, so Codex plugin state is a config
edit. Re-check `plugin --help` when a harness version moves; a verb that
disappeared must fall back to the config-edit path, never be guessed at.

| Item type | Claude | Codex |
| --- | --- | --- |
| Plugins | `claude plugin enable\|disable PLUGIN@MARKETPLACE --scope user` (verbs exist) | no enable/disable verb — state is the `[plugins."PLUGIN@MARKETPLACE"] enabled` key in `~/.codex/config.toml`, edited under review |
| Standalone skills | no enable/disable verb — presence only; state is a reviewed config edit | no enable/disable verb — presence only; state is a reviewed config edit |
| Hooks | no verb; enablement is a reviewed config edit | no verb; enablement is the `hooks.state."HOOK-KEY".enabled` config surface — the sibling `trusted_hash` leaf is host-local trust and is never synced |
| MCP servers | reviewed config edit | reviewed config edit |

Presence for manager-installed items is always the manager's own
install/remove command; only *state* falls back to config edits.

Codex-side freshness (verified against codex-rs commit 728e25cb, 2026-08-04):
Codex auto-upgrades `source_type = "git"` marketplaces at startup, but never
runs `git fetch`/`pull` against `source_type = "local"` marketplaces — for a
local-checkout marketplace, whoever refreshes it owns pulling that checkout
current; Codex will not. Once the on-disk marketplace content is current, Codex silently
advances installed plugin versions itself on the next `plugin/list` (which
every TUI session issues routinely) — nothing needs to force reinstalls
or invoke `codex plugin marketplace upgrade`, only to keep the checkout
current. The 3h remote-catalog TTL and the startup git auto-upgrade are
catalog-metadata-only and git-type-only respectively; neither gives local
marketplaces any freshness guarantee.

## Routine marketplace refresh

An explicit request to update or refresh one named marketplace plugin is
mutation authorization for that marketplace's already-installed plugins on the
requested hosts and applicable harnesses. A marketplace upgrade and its plugin
updates are one operation: after refreshing the catalog, update every installed
plugin owned by that marketplace, not only the plugin that prompted the refresh.
Do not install other catalog entries that were not already installed. Do not require a
fleet-wide inventory/readiness matrix or a sealed-plan round trip for this
routine path. Resolve every target
from `ROUNDHOUSE_CONFIG`, falling back to
`${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json`, and use each
target's configured `local`, `ssh`, or `codex-remote-control` transport. Never
guess an SSH alias or substitute WSL for native Windows.

Before changing a target, capture a bounded `agents` inventory and freeze a
de-duplicated set of every installed plugin owned by the marketplace. Treat the
two harnesses independently and refresh each available, applicable runtime.
For Claude, compare the marketplace entry's resolved source SHA with the
installed plugin's `gitCommitSha` as well as its version: the same version with
new bytes is stale and must reinstall, while matching version and SHA is a
no-op.
For local execution set `TARGET_CLI="$CLI"` and verify the loaded executor. For
SSH, use the configured alias and target login shell (`$SHELL -lc`), resolve the
target's installed Roundhouse version from its active Codex plugin
record, and set `TARGET_CLI` to that target cache's
`roundhouse/VERSION/scripts/roundhouse`; never send or interpolate
the controller's `SKILL_DIR` or `CLI`. Require `"$TARGET_CLI" verify-executor`
to pass before using it. Run only these target-native command sequences, in
order, substituting the authorized marketplace and each installed plugin ID:

```text
codex plugin list --json
codex plugin marketplace upgrade MARKETPLACE --json
"$TARGET_CLI" update-codex-plugin EACH_INSTALLED_PLUGIN@MARKETPLACE

claude plugin list --json
claude plugin marketplace update MARKETPLACE
claude plugin update EACH_INSTALLED_PLUGIN@MARKETPLACE --scope user
```

Require every frozen ID to end in the exact `@MARKETPLACE` suffix and attempt
every ID even if another update fails. Do not add IDs that appear only after the
catalog refresh. Update `roundhouse@novotnyllc` last when present, then
recapture inventory and re-resolve its installed executor. After every Codex plugin
install or update, run the hook-approval helper —
`node "$SKILL_DIR/../../scripts/codex-plugin-hooks.mjs" approve
PLUGIN@MARKETPLACE` — so ALL of the plugin's current hooks are trusted with
their fresh hashes: new hooks, changed hooks, hooks never before on this
machine. An installed plugin is a trusted plugin; a hook left silently
untrusted after an update is the failure mode this exists to prevent. The
helper discovers hooks against a fresh Codex app server, writes only
matching `trusted_hash` leaves, and preserves disabled and unrelated hook
state. Do not synchronize unrelated marketplaces, runtimes,
settings, skills, provenance, or configuration. Manager output is progress
evidence, not post-state. Recapture the bounded `agents` inventory after each
harness attempt. Require every frozen marketplace plugin record to remain
installed with its enabled state and Claude scope preserved; require every
outside-marketplace record to be unchanged. Report before/after versions per
plugin. A failure in one plugin or harness does not erase other evidence or stop
the remaining marketplace plugins from being attempted.

### Required plugin dependencies

A host that carries `railyard` REQUIRES two plugins, and railyard auto-installs
both: the `compound-engineering` plugin, version 3.20.0 or newer, from the
`EveryInc/compound-engineering-plugin` marketplace — railyard's delivery,
review, and orchestration skills invoke compound-engineering skills directly —
and the `ponytail` plugin from the `DietrichGebert/ponytail` marketplace, the
efficiency discipline railyard carries into the code and the process loop.
railyard without either is a broken install, not a lighter one. Converging
these dependencies is part of the routine refresh's existing mutation
authorization, not a separate consent: when the refresh finds `railyard`
installed on a harness and either required plugin missing there, add the
marketplace and install the plugin on that harness in the same pass. Do not ask
for a second approval, and do not install them on a harness that does not carry
railyard. Run only these target-native sequences:

```text
codex plugin marketplace add EveryInc/compound-engineering-plugin --json
codex plugin add compound-engineering@compound-engineering-plugin --json
codex plugin marketplace add DietrichGebert/ponytail --json
codex plugin add ponytail@ponytail --json

claude plugin marketplace add EveryInc/compound-engineering-plugin
claude plugin install compound-engineering@compound-engineering-plugin --scope user
claude plugin marketplace add DietrichGebert/ponytail
claude plugin install ponytail@ponytail --scope user
```

Each Codex install goes through the hook-approval helper like any other Codex
plugin install. An installed-but-older `compound-engineering` converges through
the normal marketplace-refresh path for its own marketplace; do not pin or
downgrade it — ponytail converges the same way. Report each dependency as a
converged item in the refresh result — per host and harness, with the before
state (absent, or the prior version) and the installed version — so a fleet
that was silently missing one shows up as converged evidence rather than as a
surprise.

The only pre-helper fallback is a separately approved self-update of
`roundhouse@novotnyllc` from an integrity-verified release that lacks
`update-codex-plugin`. After upgrading the `novotnyllc` marketplace, run exactly
`codex plugin add roundhouse@novotnyllc --json`, recapture inventory,
reload the new target-native plugin, and require its version `0.5.1` executor
and integrity verification before any other mutation. Never use that raw-add
fallback for another plugin or once the helper command is available.

For a native-Windows target with a configured `wsl_interop_via` sibling,
prefer the WSL interop lane for this whole routine: SSH to the sibling,
`cd /mnt/c` first — skipping it does NOT fail: cmd silently falls back to
`C:\Windows` with rc=0 and only a stderr warning, so relative paths target
the wrong directory invisibly — and run each Windows command through
`/mnt/c/Windows/System32/cmd.exe /c "..."` — cmd starts faster than
PowerShell, has fewer quoting layers through the ssh-to-interop chain, and
resolves the CLIs' native executables directly. When a command genuinely needs
PowerShell, never pass the script through the quoting chain — the double
bash parse eats `$env:` and quotes silently (observed: `$env:USERPROFILE`
resolving against the WSL-side cwd). Instead encode it on the WSL side and
pass one opaque token:
`PS_B64=$(printf %s '<script>' | iconv -t UTF-16LE | base64 -w0)` then
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile
-EncodedCommand "$PS_B64"` — still from a `/mnt/c` working directory.
The harness CLIs, plugin commands, and the hook-approval helper all execute
as native Windows processes, and their results are native evidence. WSL is
purely the launcher: the Windows process knows nothing about WSL, so never
hand it a WSL-side path — Windows commands operate on Windows files, with
Windows-side variables written cmd-style (`%USERPROFILE%`, which bash
passes through unexpanded). For the rare file that must cross the boundary,
stage it under `/mnt/c` or translate with `wslpath -w`.
Interop hygiene, each verified live: launch with stdin redirected
(`</dev/null` — cmd silently consumes inherited stdin, starving any
surrounding read loop); strip CRLF before comparing or parsing native
output (`| tr -d '\r'` — most Windows tools emit CRLF; the harness CLIs
emit clean LF); never nest quotes inside the `cmd /c` payload — cmd's own
quote-stripping mangles them regardless of escaping, so arguments with
spaces go through `%VAR%` expansion or the `-EncodedCommand` hatch; cmd
expands an undefined `%VAR%` to its literal self with rc=0, so echo-verify
a variable before anything destructive; and never run a bare CLI name in
the WSL shell expecting the Windows one — sshd sessions get no Windows
PATH entries, so `claude` resolves to the WSL-side install and yields WSL
evidence mislabeled as native. Only the full-path cmd.exe wrapper produces
native evidence. Fall back to `codex-remote-control` only when WSL is
absent or unreachable, or the work needs the Desktop app surface.

For a configured `codex-remote-control` target, follow the routine-refresh
path in `"$SKILL_DIR/../../references/codex-remote-control.md"`, using a visible
native task and native PowerShell. Before its task creation and every chunk or
other work-starting follow-up, invoke the reference's exact shared
`railyard/model-routing/v1` runtime-skill contract; no local model
policy is permitted. Every such dispatch prompt carries railyard's dispatch
banner instruction (`▸ <model>/<effort> · …` echoed first, non-blocking; see
railyard's harness-model-invocation reference). Lazy-discover the task-control
app tools before declaring them unavailable.

A harness that cannot drive the Codex task surface (Claude Code) is not
blocked from the declarative half: stage the marketplace desired-record and
profile bundles onto the Windows target through the enrolled `windows-sftp`
lane (`"$SKILL_DIR/../../references/windows-sftp.md"`), which any harness can
drive over SSH/SFTP. The broker's scheduled task picks up a committed slot
within one minute. Only the in-session convergence — installing plugin caches
and re-approving hook trust against the staged desired-record — still
requires the visible Codex task or an operator at the machine.

Use the sealed-plan reconciliation path below instead when the request includes
broad drift, runtime or settings changes, provenance repair, provider
conversion, ambiguous plugin/marketplace/host scope, or any mutation beyond
the explicit named-plugin refresh.

Default to a plan listing exact host, harness, manager, source, current version
or hash, and desired action. Seal it with
`"$CLI" seal-plan DRAFT SNAPSHOT PLAN`. Before apply, require exact scope,
recapture inventory, and require
`"$CLI" verify-preconditions PLAN CURRENT-SNAPSHOT` to succeed. Obtain
separate user approval and execute only the exact sealed argv. Do not silently
convert a standalone skill into a plugin or vice versa. For a local target use
`"$CLI" apply-plan PLAN PLAN-ID OUTPUT`; for SSH use
`"$CLI" apply-ssh-plan PLAN PLAN-ID OUTPUT`; Windows uses the native worker
contract in the remote-control reference. Apply recaptures trusted preflight
itself. Preserve its authoritative partial output when an operation or
postcondition fails.
The executor supports exact `codex update` and `claude update` runtime updates,
plus updates for skills-cli, JSM, and Claude plugins.
Codex replacement uses the native idempotent `codex plugin add
PLUGIN@MARKETPLACE --json` operation through the same hook-preserving wrapper.
An already-current runtime is a successful
no-op after it remains present in post-inventory. For a missing runtime, use the
official installer interactively or delegate a manager-owned install to
`fleet-update`; downloaded installer pipelines, removals, and provider
conversion are unsupported by sealed plans.

Configured `agent_artifacts` may declare an allowlisted `settings` object for a
JSON or TOML config file. Inventory emits one `agent_setting` record per key,
including observed value, desired value, presence, and `in_sync`; it never emits
unlisted config fields. Reconcile the owning file through
`agent-utilities:fleet-chezmoi` when chezmoi is present. Do not write Claude Desktop internal state or undocumented Codex
Desktop preferences. Claude's supported Remote Control default lives in the
shared Code settings file; the invoking agent must check Codex Desktop host
enablement manually.

Codex hook approval is target-local state, not a portable settings allowlist.
After the user explicitly approves the current hooks for one exact plugin and
host scope, local runs
`"$CLI" approve-codex-plugin-hooks PLUGIN@MARKETPLACE`; SSH runs the same command
through the previously resolved and verified `"$TARGET_CLI"` in the target login
shell. Native Windows uses the integrity-gated `-ApproveCodexPluginHooks` path
in `"$SKILL_DIR/../../references/codex-remote-control.md"`. Each path discovers
hooks with a fresh Codex app server, writes only matching `trusted_hash` leaves,
preserves disabled and unrelated hook state, and verifies every current matching
hook is trusted. Never copy the complete `[hooks.state]` table between hosts.
Later updates inherit approval only for the same stable hook keys; new hooks
require a new explicit approval.

Use local/SSH execution where configured. SSH uses bounded connection and
keepalive timeouts and must match the configured native hostname/user before
mutation. Run every SSH operation through the target user's configured login
shell (`$SHELL -lc`) so user-level paths such as `$HOME/.local/bin` are
available. Never use raw non-login SSH command execution or infer that tooling
is absent from its restricted `PATH`. For Windows Codex tasks read and follow
`"$SKILL_DIR/../../references/codex-remote-control.md"`; its explicit routine
named-plugin path may run the native Claude CLI in the visible native PowerShell
task only after the shared routing dispatch is admitted and claimed. Outside
that narrow path, Claude reports the transport control surface as unsupported
rather than using WSL. Re-inventory after changes and report
unresolved provenance as unknown, not guessed.

## Protected profile actions

Use `"$CLI" privilege-status HOST SNAPSHOT` before proposing protected profile
work. The only agent-content action is the readiness-advertised
`profile.apply-managed-bundle.v1` or read-only
`profile.inventory-managed-state.v1` in `windows-user-s4u-v1`. Build identical
Codex/Claude bytes with `"$CLI" profile-bundle SPEC SOURCE-ROOT OUTPUT`; include
only bounded config scalars, standalone-skill files, agent definitions, and
local marketplace desired records already authorized by the protected entry
map. Never copy credentials, secret-backed templates, installed plugin caches,
agent internal state, startup tasks, or arbitrary paths. A staged plugin
desired record is `manager_activation_pending` until the next ordinary user
session lets its manager activate it; logged-off S4U success is not plugin
activation evidence.

The shared protected lifecycle vocabulary is `prepare-privilege-identity`,
`prepare-privilege-enrollment`, `verify-privilege-plan`,
`submit-privilege-plan`, `lookup-privilege-result`,
`preview-privilege-upgrade`, and `preview-privilege-revocation`. Preserve every
readiness/result state without fallback, including
`unsupported_security_boundary`, `partial`, and `stale`.
Never ask for or relay a sudo or Administrator password; stop at the local human
password/UAC boundary.
