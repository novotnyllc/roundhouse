# Automatic fleet sync for agent tooling

Status: **design proposal, rev 3.3** · 2026-09-30 · nothing implemented here.

## History

- **Rev 1** made adoption a manual, reviewed step. The owner rejected that: the point is that a
  change on any machine reaches every machine by itself.
- **Rev 2** was automatic, but an adversarial review found problems in the places the design relied on:
  - forgeable timestamps;
  - an event store the trust gate can't verify;
  - a baseline that didn't reflect what was installed;
  - plugin installs from any session running as code everywhere;
  - an infeasible Windows port.
- **Rev 3** replaced the mechanism with a three-way merge over git history.
- **Revs 3.1–3.3** close three rounds of Thermos findings (§9). The main changes:
  - owner-controlled settings, including the owner keys themselves, are read only from an
    owner-verified pointer;
  - staged changes are derived, never stored;
  - held batches can be released or discarded.

Everything in `2026-08-06-dsc-storage-design-v2.md` (V2) holds unless a section here says otherwise.

## 1. What the fleet does

The owner works on one machine at a time. What they do there becomes how every machine is:

- **Adds.** Install or enable a plugin from a known marketplace, or add a skill, on any host. It
  appears on every host at that host's next pass. That's within about a minute for hosts the nudge
  can reach, and otherwise at the next wake, login, session start or 20-minute timer.
- **Removals.** Uninstall or disable it anywhere, and it goes away everywhere.
- **Model defaults and other allowlisted preferences** propagate the same way (§5.1). "Make model X
  the default everywhere" means changing it on the machine in use; no agent task and no dotfiles
  PR.
- **Upstream releases** arrive everywhere through the existing canary gate (§3.6).
- **Native Windows** takes part, with its harness commands running natively.
- **What needs the owner.** Only *owner-controlled* settings (§4.1):
  - a marketplace the fleet has never seen;
  - security posture;
  - a new Codex hook;
  - protected items;
  - fleet policy;
  - releasing an over-limit batch (§4.2).

  Nothing else needs approval.

## 2. Why it didn't happen before

Five writers edit the same agent state:
- dotfiles templates and the retired list;
- fleet-chezmoi capture and `converge-plugins.sh`;
- Roundhouse seed and apply;
- the harnesses' own auto-update;
- Roundhouse `config.json` expectations.

The reconciler stopped working:
- **Lock.** The canary's `fleet-run` was stuck from about 2026-08-20 on a lock left by a dead
  process. It refuses such locks instead of recovering them: the age check runs before the
  dead-pid check.
- **Scheduler.** Its launch agents were disabled until about 2026-09-29, and are enabled again on
  macbook-pro now.
- **Publishing.** The trailer limit wedged publishing (fixed in #37).
- **Host layers.** The `hosts/*/99-canonical-agents.yaml` files are machine snapshots of 34–111
  plugins each, and they override every change made anywhere. They still enable `codex`,
  `superpowers` and `music-control`.

## 3. The model

### 3.1 One desired state, one writer

- **Where agent tooling lives.** Only dedicated files hold it, and those files hold nothing else:
  - `fleet/agent-plugins.yaml` and `fleet/agent-skills.yaml`;
  - `os/<platform>/agent-*.yaml` for items that exist only on one platform.

  A hand edit to packages can therefore never share a file, or a jj conflict, with an agent
  change.
- **Owner-controlled settings** live in `fleet/owner/*.yaml` (§4.1).
- **One declaring layer.** Each agent item is declared in exactly one layer, and that layer is the
  one a local change edits. The **receiving host's fold** enforces this: an agent item found in two
  layers, or in a host layer, is an item-scoped detection in `fleet_run_alerts`, held through the
  existing single hold surface.
- **A change is a commit** to the declaring file, signed by the host that made it. There is no
  event store.
- **The loop is the only writer.**
  - dotfiles, fleet-chezmoi and `config.json` hand over per host through the marker (§6.2).
  - Re-seed and unanimity promotion stop writing agent categories in P0, so nothing re-adds a
    retired plugin to a layer. Their agent branches are deleted in P2, where the silent first pass
    (§3.3) replaces `fleet-seed` for agent state.
  - `fleet-accept` retires for agent items.

### 3.2 Item identity

Agent items use **new categories**:

```yaml
# fleet/agent-plugins.yaml
agent_plugins:
  claude:impeccable@impeccable:               {state: enabled}
  codex:impeccable@openai-curated-remote:     {state: enabled}
  claude:superpowers@claude-plugins-official: {state: absent}   # tombstone (§3.4)
```

- **The key.** It carries the harness and keeps the marketplace in the name. Names may contain
  dots, as today: `fleet_item_split` splits on the first dot.
- **Old code holds, it doesn't mis-converge.** Old code sees unknown categories, holds the whole
  run and alerts (`fleet_unknown_categories`, `fleet-fold.sh:251`).
- **Aliases.** `fleet/owner/aliases.yaml` (for example `openai-curated` ≡ `openai-curated-remote`)
  normalizes both observations and values.
- **Values carry state only.** No version, no SHA, and no hook trust (§3.5).
- **Protected items.** Protected items are **declared in** `fleet/owner/protected.yaml`, and their
  values live there, read at the owner pointer (§4.1).
  - It starts with the `roundhouse` plugin and its marketplace.
  - Because the value is in an owner file, owner-path enforcement covers it on every receiving
    host. No node key can tombstone the loop fleet-wide.
  - Protected items are never staged.
  - The owner-file value always wins. A fold declaration of a protected key is an item-scoped
    detection in `fleet_run_alerts`, and it is held.
  - The `roundhouse` plugin also keeps its existing `fleet-adopt-pin` SHA containment.

### 3.3 One pass

All host-local state lives under `fleet_instance_path store.run/` (the existing
`ROUNDHOUSE_FLEET_STORE` seam):
- the **baseline** (`agent-baseline.json`);
- **pending-apply markers**;
- the **dirty stamp**;
- the **owner pointer** (§4.1);
- **pending-confirm decisions**;
- the per-item **refused-publish counter** (§3.3 step 6);
- **conflict records**: the local value a conflict displaced (§3.3 step 3).

For each item, the baseline is the value this host last saw **agreed**: observed equal to the
fleet value, at a commit that was fetched and is on the remote.

1. **Observe.**
   - Read the harness records with `jq` and `yq`:
     - Claude: `installed_plugins.json` and `settings.json`;
     - Codex: `[plugins.*]` and the allowlisted root keys of `config.toml`;
     - OpenCodex: `ocx config export` (§5.1).
   - A harness CLI runs only when the record hash has changed since the last pass.
   - A non-authoritative collector result makes an item **unknown**.
   - Two records for the same key are refused, with an alert.
2. **Fetch and verify** with the trust ratchet, and advance the owner pointer (§4.1).
3. **Three-way merge** each item with the pure `fleet_merge3 BASE OURS THEIRS`. Unknowns are
   skipped.

   | ours vs base | theirs vs base | Result |
   |---|---|---|
   | same | same | nothing |
   | same | changed | converge to theirs |
   | changed | same | **local change** |
   | changed | changed, and ours = theirs | nothing; advance the baseline |
   | changed | changed, and ours ≠ theirs | **conflict**: record ours, then theirs wins; alert naming both hosts; `fleet-take-local ITEM` publishes the recorded value |

   - **Conflict records.** Before a conflict converges to theirs, the host writes a conflict
     record holding the displaced local value. So `fleet-take-local ITEM` can still publish ours
     after converge has overwritten it.
     - Records are written only for items §4.3 allows to be staged. For tool config, a record
       holds only the schema's `plain:` keys, so it never holds a secret or an owner-controlled
       value.
     - `fleet-take-local` publishes the recorded value as an ordinary local change, through the §4
       gate and the change cap.
     - It is cleared by `fleet-take-local`, by `fleet-discard`, or when theirs changes again.
       Theirs changing again raises a new alert.
   - **Unmanaged** is its own state.
     - A local add: base and theirs missing, ours present.
     - **Ignored** is an explicit baseline marker, `{ignored: true, value}`. Such an item never
       publishes while ours equals the recorded value.
       - If ours changes to another present value (for example, the owner disables the extra),
         the marker's value is updated and the item stays ignored. The marker is dropped, silently,
         only when ours goes missing.
       - **If the fleet later adds the same item** (theirs present), the ignored value serves as
         base. If ours matches it, the item converges to theirs; otherwise it is a conflict, with a
         conflict record. Once ours and theirs agree, an ordinary baseline replaces the marker.
       - Only `fleet-take-local` clears the marker and publishes the item.
     - Base present and theirs missing means an owner edit dropped the item. The baseline entry
       becomes ignored with the observed value, and no action is taken. It is not dropped, which
       would make the next pass read it as a local add.
     - A tombstone is the value `absent`, not a missing value.
   - **Local changes are derived every pass, never stored.** Because base doesn't advance until
     agreement, an unpublished local change is re-derived on every pass. Once theirs changes that
     same item, the row becomes a conflict and the local change is gone.
   - **No clocks.** A host whose loop was dead for a week publishes what the owner changed there,
     unless the same item changed elsewhere meanwhile. The stale state it merely *has* loses,
     because base = ours.
4. **Gate** the local changes (§4).
   - A change needing the owner, or a batch over the cap, becomes **pending-confirm**. This is a
     new state, separate from verdict holds, the §8.3 hold set and journal `held`.
   - The host raises one alert with an ID, which is an item key or a batch ID.
5. **Publish** the remaining local changes as one signed commit, with
   `fleet_vcs_publish … no-recover`.
   - **Stale-info rejection:** abandon the commit, re-fetch, and go back to step 3.
   - **Any other failure:** publish nothing. The changes are re-derived next pass.
   - Agent files never diverge across heads, so V2 §8.2b (the conflict resolver) and §8.3 (the
     hold set) apply only to non-agent files.
   - Git history is the only order.
6. **Converge** through each harness's own commands (§3.5), with sealed plans, the precondition
   recheck and backups as today.
   - Converge skips only **publishable** local changes (those §4.3 allows) and pending-confirm
     items, so the owner's change isn't reverted before it publishes.
   - A never-staged row still converges to the owner or fleet value. For example, a posture key
     loosened locally is reported and put back; pinned items stay local.
   - A publishable change that is refused for three passes in a row (for example by the redaction
     sweep) raises an alert rather than diverging silently.
   - `fleet-discard ID` drops a pending-confirm item or batch; its items then converge to theirs.
     That is how a wiped home directory is repaired.
7. **Re-baseline** by re-observing after the apply.
   - A baseline advances only where ours = theirs at a commit on the remote.
   - A pending-apply marker is written before each harness mutation and cleared after it. When one
     is left behind, the next pass re-observes that item without publishing it.

**Silent first pass.** A new host, a migrated host, or a host that lost its baseline:
1. converges;
2. observes;
3. writes the baseline where ours = theirs, and writes an **ignored** entry for every local extra
   not in the fleet;
4. publishes nothing.

Local extras are therefore left alone on every later pass too, and are listed in one alert, with
`fleet-take-local` to publish them.

**Offline.** When fetch fails, local changes aren't agreed. Converge skips them, and they publish
once the host reconnects.

### 3.4 Removals and tombstones

- **What counts as a removal.** The harness's own records drop the item: `installed_plugins.json`
  and `enabledPlugins` for Claude, the `[plugins."X@Y"]` table for Codex.
- **Damage isn't removal.** Records intact but files missing or corrupt is *damage*: it's repaired
  locally and never staged.
- **Tombstones.** A removal publishes `state: absent`, and apply uninstalls it through the harness.
  Today `absent` only forgets the record.
- **Compaction.** A tombstone is compacted once every enrolled host **with that harness** has
  journaled `applied` or `satisfied` for the tombstone's digest. Compaction mutates no harness, so
  it doesn't count toward the change cap (§4.2).
- **Undo** is the existing `fleet-rollback ITEM`.

### 3.5 Apply per harness

- **Claude.** The existing verbs (`marketplace add`, `install`, `enable`, `disable`), plus
  `uninstall` for tombstones, all at user scope.
- **Codex.**
  - `codex plugin add` and `codex plugin remove` (the only install verbs in codex-cli 0.158).
  - Enable and disable through app-server `config/batchWrite`, which `codex-plugin-hooks.mjs`
    already uses.
  - Updates through the existing `update-codex-plugin`.
  - `codex plugin marketplace add`, `upgrade` and `remove`.
- **OpenCodex.** Preferences only (§5.1), through `ocx config export`, `validate`, `import`, then
  `ocx sync`. The file is never edited directly.
- **Codex hook trust.**
  - Trust is per hook key (plugin plus hook name), stored in `fleet/owner/hook-trust.yaml`, and the
    first trust of a hook key is an owner edit.
  - A later hash change is accepted automatically when it arrives through a Roundhouse update from
    the same owner-confirmed marketplace source.
  - A host's local `hooks.state` trust is never propagated.
- **Marketplaces are checked by source, not name.**
  - A marketplace is registered only from `fleet/owner/marketplaces.yaml`.
  - Before converging a plugin, the loop compares the marketplace's registered source with the
    owner file. A mismatch, such as a same-name repoint, is held.
  - The `extraKnownMarketplaces` fallback registers only when its source matches the owner file,
    and it is deleted in P2 (§8.2).
- **Relative-source catalogs** (`./plugin`) take their identity from the marketplace checkout
  commit.
- **Held items.** A held "marketplace identity unavailable" item re-registers and refreshes before
  holding again.
- **Live sessions.** Uninstalls and version-replacing updates wait, for up to 24 h, while a
  `claude` or `codex` process is running.

### 3.6 Versions and the canary

- **State changes: the origin is the canary.** For a state change, the origin host's journaled
  `applied` for that digest is the canary evidence. `agent_canary_wait_minutes` defaults to 0.
  `fleet_canary_gate` is otherwise unchanged, including V2 condition 3: a canary that goes silent
  after applying blocks promotion. There is no failover.
- **Upstream releases use the same gate.**
  - A canary that updates a marketplace catalog journals `applied` for a synthetic item
    `upstream.<marketplace-id>`, whose digest is the catalog revision.
  - Non-canary hosts update to a revision only after `fleet_canary_gate` passes for that digest.
  - One gate, and no new record shape.
- **Harness auto-update outside Roundhouse** bypasses the gate wherever it's on. That's an owner
  decision (§10).

## 4. Safety

### 4.1 Owner-controlled settings

| File in `fleet/owner/` | Controls |
|---|---|
| `marketplaces.yaml` | Marketplace name → source, plus `review: per-plugin` |
| `protected.yaml` | Protected items and their values (§3.2) |
| `posture.yaml` | Posture keys: `skipDangerousModePermissionPrompt`, `remoteControlAtStartup`, permission rules, hooks, the Roundhouse SessionStart hook (§6.1) |
| `synced-preferences.yaml` | `config_files` managed-key declarations for agent config files (§5.1) |
| `aliases.yaml`, `tool-schemas.yaml`, `hook-trust.yaml` | As named |
| `pins.yaml` | `pin: local` exceptions per host |
| `policy.yaml` | The **whole** policy category, including the canary member list |
| `confirmations.yaml` | Releases of pending-confirm batches and receiver holds (§4.2), by source commit ID or item keys |

**Owner class.** `owner` is a third class in the existing roster and ratchet, alongside `durable`
and `ephemeral`.
- **Keys.** At least two owner keys: one in the 1Password SSH agent, set to approve every use, and
  an offline recovery key.
- **The one new ratchet rule.** Owner rows change only in a commit signed by an owner at the
  parents.
- **What an owner key may sign.** `fleet/owner/**`, `trust/` owner rows, and row-1 layer paths,
  which P1b needs (§8.2).
- **What it isn't.** It is never the passphrase-less node key.

**The owner pointer.** This is what makes owner files trustworthy with the gate as built. The gate
checks only newly fetched commits, and a refused non-fold file has no item to hold.
- **What it is.** Each host keeps a host-local pointer to the last commit whose owner tree was
  owner-verified. The owner tree is `fleet/owner/**` plus the owner rows in `trust/`.
- **Where owner files are read from.** Always at the pointer, never at head. That includes the
  owner key set itself: owner keys come **only from the owner rows at the pointer**, never from a
  commit's parents, whose roster bytes may be unverified.
- **How it advances.** The pointer moves to a newly fetched commit C only when C's owner tree
  equals the pointer's owner tree with changes applied that are each signed by an owner key the
  pointer already trusts.
  - A commit that touches no owner path passes trivially.
  - The pointer only ever moves to a descendant of itself.
  - A merge passes only when its owner tree equals the owner tree at the current pointer, or at a
    passed parent that descends from the pointer, plus changes signed by owner keys the pointer
    trusts.
  - Routine reconcile and records merges pass, because both sides carry the pointer's owner tree.
  - A merge that takes owner files from an older commit is a rollback, and never passes.
  - **Re-root (V2 §7.11.2).** A re-root's new root descends from nothing, so the pointer joins the
    §7.11.2 catch-up:
    1. Find the pointer in the archive.
    2. Advance it along the archived chain by this rule, up to the checkpoint.
    3. Adopt the new root's owner tree only if it equals that verified owner tree, or if the
       checkpoint is signed by an owner key that the advanced pointer trusts.

    Otherwise the pointer stays pinned, and the host raises a persistent alert.
- **A non-owner write** to an owner path stops the pointer and raises a persistent alert. It
  doesn't wedge the host: non-owner paths keep flowing, and owner settings freeze at the pointer.
- **Restoring.** Only `roundhouse fleet-owner restore` resumes the pointer. It builds an owner tree
  from the pointer's tree and commits it under an owner signature. A later commit signed by some
  key that a node-written roster row names never counts as a restore.
- **Every owner write starts from the pointer's owner tree, never from head.** That covers
  `fleet-confirm`, `fleet-owner restore`, and owner edits. Confirming something therefore can't
  re-sign an attacker's pending owner-path bytes.
- **Owner-path edits in the store working copy are never auto-published.** The reconcile step
  refuses to describe them as a hand edit, and points the owner to the owner-signing command. A
  node-signed publish of the owner's own edit would otherwise stop the pointer fleet-wide.
- **Old copies of owner settings.** A `policy:` key anywhere in the general fold is ignored and
  alerted, and `fleet_policy_get` reads only the owner file at the pointer.

**Pinning and recovery.**
- The genesis owner keys are pinned on each host with `roundhouse fleet-owner pin`. It runs
  interactively in a TTY and requires a signature over a fresh challenge from an owner key, so a
  node key or an unattended agent can't pin an owner.
- Enrolling a new host (V2 enrollment) includes the same pin step.
- Losing one owner key: the other one rotates it.
- Losing both: re-run `fleet-owner pin` on every host with new keys. This is documented as the
  recovery procedure.

**Receiving hosts** hold:
- any fleet plugin whose marketplace isn't in `marketplaces.yaml`, or whose source doesn't match it;
- any plugin from a `review: per-plugin` marketplace that isn't confirmed.

**What this defends against.** A prompt-injected session or a malicious plugin holds the node key
and can write the store directly. It still can't do any of these:
- add or repoint a marketplace;
- change posture, pins, policy, protection or hook trust;
- release a batch;
- touch the roster.

**Accepted residual risk.** Such a session *can* enable, disable or remove plugins from confirmed
marketplaces. Those changes propagate, bounded by the change cap. Protected items are exempt,
`fleet-rollback` undoes it, and `review: per-plugin` narrows it per marketplace.

### 4.2 The change cap

The existing `fleet_removal_cap` becomes one pure `fleet_change_cap`:
- **What it counts.** Harness-mutating adds, removals and state changes. The knobs are
  `max_changes_per_run` and `max_change_fraction` in `policy.yaml`. The old names are still read as
  a fallback, and the defaults stay 5 and 0.25.
- **Owner-signed commits are exempt.**
- **At the publisher,** over this pass's local changes. Over the cap, the whole set becomes one
  pending-confirm batch, released by `fleet-confirm` or dropped by `fleet-discard`.
- **At the receiver,** per source host, over that source's node-signed changes **not yet
  converged on this host**.
  - Splitting 100 removals into 100 one-item commits doesn't evade the cap.
  - Six small changes that pile up while a host sleeps count together, but they don't stay stuck:
    - Over the cap, that source's pending changes become a receiver-side pending-confirm.
    - The same `fleet-confirm` releases it, and writes `confirmations.yaml` so every receiver sees
      the release.
  - A release is keyed by **source host plus commit range**, or by **item key plus digest**; never
    by bare item keys, so no release becomes a standing exemption.
  - A batch confirmed at the publisher writes the same entry, so receivers don't trip on it again.

### 4.3 Never staged

- items from directory or local-path marketplaces (`music-control` was one);
- non-user plugin scopes;
- pinned and protected items;
- preference keys not on the allowlist;
- posture keys, where a local change is reported, not staged;
- V2's `never:` list, auth files, SSH keys and MCP credentials;
- OpenCodex accounts, account pins, pools, credentials and ports.

## 5. Preferences and tool config

### 5.1 Preferences: model defaults first

- **How it's declared.** Preferences reuse V2's `config_files` managed-key mechanism rather than
  adding a second one:
  - `fleet/owner/synced-preferences.yaml` holds the `config_files` declarations for the agent
    config files. Each file is listed with its keys marked `managed`; everything else is
    `unmanaged`. Being an owner file, a node can't add a key; a key that holds a token, for
    example, can never be made to publish.
  - A fold `config_files` entry for any file listed in `synced-preferences.yaml` is ignored and
    alerted, just as `policy:` is. The existing `fleet_config_key_collisions` check runs over the
    owner declarations read at the pointer.
  - The existing co-ownership check (`fleet_config_coowned`) also applies, running over the same
    owner declarations at the pointer. The handover marker
    (§6.2) is its per-key exception: chezmoi still owns the file but has released those keys.
- **Where values live.** Values are items in a new `agent_preferences` category, in
  `fleet/agent-preferences.yaml`. That is the declaring file a local change edits (§3.1).
- **Order.** Model defaults come first and ship before the other preferences (P2b, §8.2).
- **Writing values is new.** Today `config_files` only reports drift, so converging preference
  values adds a writer. Each harness's own writer does it:
  - Codex through app-server `config/batchWrite`, so Codex's concurrent writes to `config.toml`
    (project trust, `hooks.state`) are never lost;
  - OpenCodex through `ocx config import`;
  - Claude through a key-scoped `settings.json` merge under the existing sealed plan.

  None of them rewrites a whole file.

**Codex: `~/.codex/config.toml`, root keys only.**
- Synced: `model`, `model_reasoning_effort`, and `review_model` where present.
- Host-local: `[profiles.*]` and everything else.

**OpenCodex: `~/.opencodex/config.json`, or `%USERPROFILE%\.opencodex\config.json` on Windows.**
The file changes only through `ocx config export`, `validate`, `import`, then `ocx sync`. Synced
keys:
- `settings.injectionModel`, `settings.injectionEffort`;
- `settings.subagentModels` (ordered; the first entry is the default subagent);
- `settings.syncCodexSubagentDefaults`;
- `settings.agentTaskRecovery.model`;
- `settings.visionSidecar.model`, `settings.visionSidecar.reasoning`;
- `settings.webSearchSidecar.model`, `settings.webSearchSidecar.reasoning`;
- `settings.disabledModels`;
- `providers.openai.defaultModel`;
- the `providers.openai` model metadata maps: `modelContextWindows`, `modelMaxOutputTokens`,
  `modelInputModalities`, `modelReasoningEfforts`, `modelDefaultReasoningEfforts`,
  `modelDisplayNames`.

**Claude:** `theme`, and other keys as the owner adds them.

**Rules:**
- Nothing outside the allowlist crosses hosts, and no file is copied wholesale.
- The Observe hash covers only allowlisted keys, because Codex rewrites `config.toml` constantly.
- A multi-key setting such as `subagentModels` is one item, so its order is preserved.

### 5.2 Tool config and secrets

- **The file.** `~/.config/last30days/.env` is an item with a schema in `tool-schemas.yaml`.
- **Keys are secret by default.** A key is plain only if the schema lists it under `plain:`, such
  as `INCLUDE_SOURCES`, and plain keys sync as preferences. Keys not in the schema are reported and
  never staged.
- **What the store holds.** Only an `op://…` reference for each secret.
- **Rendering.** Each host renders the file at mode 0600 through a sealed per-target plan with its
  own `op`, or alerts if `op` is unavailable.
- **Values are never logged or printed.** A new secret typed on one host produces an alert asking
  the owner to store it in 1Password.

## 6. Triggers, handover, liveness

### 6.1 Triggers

- **Scheduled passes.** The existing launchd agents and systemd user timers run fast every 20
  minutes, and full as today.
  - `roundhouse fleet-schedule install` installs and loads them (`launcher-install` remains the
    PATH shim).
  - A pass never re-enables a job an operator disabled; it alerts instead.
- **Every trigger** first touches the dirty stamp, then starts the scheduled job:
  - macOS: `launchctl kickstart gui/$UID/com.novotnyllc.roundhouse.fleet-fast`;
  - Linux: `systemctl --user start roundhouse-fleet-fast.service`.
- **When no GUI domain exists** (a Mac with no console login, reached over SSH), it falls back to
  `nohup roundhouse fleet-run --fast </dev/null >/dev/null 2>&1 &`.
- **The running pass loops in-process** while the stamp has moved since the pass began, so a
  trigger that arrives mid-pass is never lost. A kickstart for a job already running is harmless.
- **Push nudge.** After a publish that changes desired state, the existing push nudge sends this
  trigger over SSH and returns immediately.
- **SessionStart.** A Claude `SessionStart` hook sends the same trigger locally, printing nothing.
  `fleet-schedule install` writes it until P5; from P5 on, it's a `posture.yaml` entry that the
  loop converges, and `fleet-schedule` stops writing it.
- **No file watches.**

### 6.2 The handover marker

- **The marker.** On each host, the loop owns an agent category or preference key only once that
  host's applied dotfiles render `~/.config/roundhouse/released-agent-keys`, listing what dotfiles
  no longer writes.
- **What the marker switches off, per host:**
  - fleet-chezmoi plugin capture;
  - `converge-plugins.sh`;
  - the dotfiles retired list;
  - `config.json` agent expectations.
- **Controller-run writers** check the **target's** marker in their sealed-plan precondition
  recheck.
- **Deletions** in §8.2 run once every enrolled host renders the marker.

### 6.3 Lock and liveness

- **Lock contents.** A lock carries a nonce, a pid, and the process start time. The primitives stay
  in `lib/fleet-store.sh`.
- **Dead-holder takeover:**
  1. Confirm the holder is dead: its pid is gone, or its start time or command doesn't match.
  2. Rename the lock to a unique name.
  3. Verify the renamed lock carries the nonce that was judged dead.
  4. Create the new lock.
- **Release** removes only this run's nonce.
- **Heartbeats** stay host-local and publish at most every 6 h. Every host alerts when another host
  has gone 12 h without one, and fleet-chezmoi's probe reports the same.

### 6.4 Record hygiene and the no-op pass

- **Alerts** are keyed by kind and item, and written only when their content changes. A one-time
  compaction in P0 clears the 47,568 alert files.
- **The poll floor:**
  1. an incremental fetch;
  2. a comparison of the tree hashes of the desired-state paths against the last converged ones;
  3. the Observe input hash.

  The desired-state paths are derived from `fleet_vcs_path_owner`'s row-1 paths minus `lineage/`,
  `proposals/` and `checkpoints/`, so `trust/` and `definitions` are included. If everything
  matches, the pass exits without starting `claude` or `codex`.

## 7. Native Windows: the operated instance

**Roles, not names.** The operated Windows instance is any `platform: windows` machine in
`ROUNDHOUSE_CONFIG` (or the standard config path) whose `wsl_interop_via` names a configured WSL
machine, the *operator host*. That is the same resolution `lib/interop.sh` already uses. Its
instance name, store and principal derive from that config entry, and nothing in the
implementation names a concrete host. In this fleet today, the operated instance is
`iris-windows` and the operator host is `iris-wsl`. Those names are examples, not part of the
contract.

The operated instance is the second instance on its operator host (V2 §9.2). It has its own
principal, key and `store.run/`.

- **The Windows task.** One Task Scheduler task runs *as the user, only when logged on*
  (InteractiveToken), at logon, on unlock, and every 20 minutes. It runs
  `wsl.exe -d <distro> --exec /home/<user>/.local/bin/roundhouse fleet-run --fast --with-windows`,
  using an absolute path because `--exec` gives no login shell.
- **The operator host's pass comes first.** `--with-windows` then **re-executes** `roundhouse`
  with `ROUNDHOUSE_FLEET_STORE` set to the operated instance's store, one process at a time as the
  seam requires. Timer and nudge passes on the operator host never run the Windows instance. Windows has no
  nudge; it catches up at the next task tick or unlock.
- **Windows commands run from this pass's own process tree.** The Windows instance launches
  `pwsh.exe` directly over WSL interop, never over the SSH interop lane.
  - Before observing, it checks that its Windows token belongs to the interactive logon session,
    and refuses otherwise.
  - P4 adds the executor verbs `apply-windows.ps1` lacks today: marketplace add, install, enable,
    disable, uninstall, Codex `batchWrite`, `ocx config import`, and the tool-config render.
- **Fail closed.** Interop unavailable, or a token check that fails, makes every Windows
  observation **unknown**. Falling back to the WSL `$HOME` or `CLAUDE_CONFIG_DIR` is forbidden.
- **Guarantees.** No inbound connection to Windows is ever made, and there is no WSL fallback:
  WSL only carries native commands.
- **Native membership isn't planned.** The signing and stat helpers are Darwin/Linux-only, and
  about 19k lines would need porting.

## 8. Implementation

### 8.1 Code layout and tests

`lib/fleet-run.sh` is 3,149 lines, and `fleet_run_command` alone is about 560. New code goes in
modules, and `fleet_run_command` only calls them:

| Module | Contents | Test |
|---|---|---|
| `lib/fleet-merge.sh` | `fleet_merge3`, pure, modelled on `fleet_vcs_hold_set` | `tests/77-merge.sh`, table-driven over §3.3 |
| `lib/fleet-observe.sh` | Harness readers, record hashing, aliases, unknowns | `tests/79-observe.sh`, fixture records |
| `lib/fleet-baseline.sh` | Baseline, pending-apply, dirty stamp, pending-confirm | `tests/80-baseline.sh`: offline, stale push, failed apply, wiped home |
| `lib/fleet-agent-keys.sh` | `agent_*` keys, migration map (out of `fleet-fold.sh`) | `tests/81-agent-keys.sh` |
| `lib/fleet-owner.sh` | Owner pointer, `fleet-owner pin`, `fleet-confirm`, `fleet-discard`, `fleet-take-local` | `tests/82-owner.sh`, plus `tests/93-jj-run.sh` |
| `lib/apply-claude.sh`, `lib/apply-codex.sh`, `lib/apply-ocx.sh` | Per-harness verbs, dispatched from `fleet_run_apply_item` | `tests/83-apply-harness.sh` |
| `lib/fleet-schedule.sh` | Install, triggers | `tests/84-schedule.sh` |

`fleet_change_cap` replaces `fleet_removal_cap` in place (`tests/72-records.sh`). The lock nonce
goes into `lib/fleet-store.sh` (`tests/90-jj-bootstrap.sh`).

### 8.2 Phases

Each phase ships alone, and none leaves the fleet worse off.

**P0: stop the bleeding.**
- **Already landed:** #35 and #37.
- **Code:**
  - lock nonce;
  - alert keying and compaction;
  - heartbeat throttle;
  - fetch-based floor;
  - stamp-and-kick triggers;
  - `fleet-schedule install`;
  - identity-gate self-repair and relative-source identity;
  - Claude uninstall for `absent`;
  - re-seed and unanimity promotion skip the agent keys (`plugins` and `skills` inside
    `seed_desired`). Seed still writes packages, `platform` and `groups`;
  - a canary member list with two live hosts.
- **Data:** one reviewed store commit.
  - Delete `hosts/*/99-canonical-agents.yaml` and the agent `proposals/promote-*`.
  - Keep `fleet/99-canonical-agents.yaml` as the fleet's agent set, minus tombstones for `codex`,
    `superpowers` and `music-control`, with the impeccable and last30days entries corrected.
  - Host-only items are **disowned** in the same run by a one-shot `fleet_applied_forget`. That
    sits outside the cap and writes no `reverted` journal, so they become unmanaged: neither
    removed nor spread. One report lists them for adoption.
- **Compatibility:** dotfiles already retires those three (`claude-code-settings.retired.json`),
  so fleet-chezmoi agrees.
- **Also:** fix the 0644 mode of `.chezmoidata.toml`.

**P1: identity and owner.**
- **P1a** ships readers for `agent_*`, the owner class and pointer, `fleet-owner pin` and the Codex
  apply path; nothing writes the new categories yet. The owner pins each host.
- **P1b** follows once every host reports P1a and is owner-pinned. One owner-signed commit:
  - moves agent entries into the dedicated `agent_*` files;
  - moves marketplaces and the whole policy category into `fleet/owner/`;
  - commits a migration map from old ids to new ids.

  Each host's first P1b run re-keys its own `applied/` **before** computing removals, so old ids
  never read as removals. The canary gate accepts a mapped old-id `applied` with an identical
  normalized value as evidence for the new id. Journals are not rewritten.

**P2: automatic capture.**
- **P2a** adds baselines, merge, publish, tombstones everywhere, pending-confirm,
  `fleet-confirm`/`fleet-discard`/`fleet-take-local`, the change cap, scope rules, source-checked
  marketplaces and the handover marker. dotfiles drops plugin and marketplace keys and the retired
  list per host.
- **P2b** adds model defaults as the first preference items (§5.1) and the OpenCodex apply path.
  dotfiles releases those keys through the marker.
- **Deletions, once every host renders the marker:**
  - the agent branches of `seed_desired`;
  - agent unanimity promotion;
  - `fleet-accept` for agent items;
  - `converge-plugins.sh` and fleet-chezmoi plugin capture;
  - the `extraKnownMarketplaces` fallback.

**P3: triggers.** The SessionStart hook.

**P4: Windows.** Enrol the operated instance (including the owner pin), add the interop executor
verbs, the token check and the task.

**P5: the remaining preferences, posture values and tool config.**
- Posture values move under `fleet/owner/`.
- The SessionStart hook becomes a posture entry.
- dotfiles releases each key through the marker.
- **Deletion:** dotfiles preference templating and `config.json` agent expectations.

## 9. Review findings and where they're handled

| Round | Finding | Where |
|---|---|---|
| Rev 2 | Snapshot host layers override everything | §3.1; P0 data |
| Rev 2 | Automatic spread runs code everywhere | §4.1 |
| Rev 2 | Forgeable timestamps; stale host wins | §3.3; no clocks |
| Rev 2 | Wrong baseline; first-pass misfire | §3.3 silent first pass |
| Rev 2 | Trailer wedge; record churn | #37; §6.4 |
| Rev 2 | Native Windows port | §7 |
| Rev 2 | Normalization oscillation; auto-update bypasses canary | §3.2 aliases; §3.6 |
| Rev 2 | `events/` unverifiable; dropped triggers; resurrections | no event store; §6.1; §3.3 |
| Rev 2 | Scope, Codex verbs, secrets | §4.3; §3.5; §5.2 |
| Rev 3 | Owner confirmation bypassable | §4.1 owner class and pointer |
| Rev 3 | Baseline passes unpublished changes | §3.3 agreed baseline |
| Rev 3 | Canary latency and failover | §3.6 |
| Rev 3 | Rejected push semantics; two conflict models | §3.3 step 5 |
| Rev 3 | Edit loses to a higher layer | §3.1 one declaring layer, enforced at the receiver |
| Rev 3 | Windows WSL-home fallback; shared baseline | §7; instance paths |
| Rev 3 | Hook trust; migration; lock; `setsid`; layout; "held"; versions; P0 fold; deletions; clocks | §3.5; §8.2; §6.3; §6.1; §8.1; §3.3; §3.6; §8.2; §8.2; §4.2 |
| Rev 3.1 | Owner paths enforced only on arrival | §4.1 owner pointer |
| Rev 3.1 | Stuck staged and held changes; no discard | §3.3 derived changes; `fleet-discard`; §4.2 per-commit cap and `confirmations.yaml` |
| Rev 3.1 | Owner key pinning, loss, row-1 authority | §4.1 pinning and recovery |
| Rev 3.1 | Staged set contradicts "theirs wins" | §3.3 changes derived each pass |
| Rev 3.1 | Roundhouse plugin can be tombstoned fleet-wide | §3.2 `protected.yaml` |
| Rev 3.1 | Windows token lineage; PATH under `--exec` | §7 direct interop, token check, absolute path |
| Rev 3.1 | Kickstart drops wake-ups; no GUI domain over SSH | §6.1 stamp-and-kick, in-process loop, `nohup` fallback |
| Rev 3.1 | Marketplace checked by name only | §3.5 source check |
| Rev 3.1 | Receiver cap re-trips; no release | §4.2 |
| Rev 3.1 | Canary membership writable by any host; layer rules only at the publisher | §4.1 policy; §3.1 receiver detection |
| Rev 3.1 | Split policy source | §4.1 whole policy category |
| Rev 3.1 | Parallel upstream gate | §3.6 synthetic `upstream.<id>` items |
| Rev 3.1 | Per-file jj conflicts | §3.1 dedicated agent files |
| Rev 3.1 | P0 prunes trip the cap | §8.2 P0 disown |
| Rev 3.1 | Tombstone compaction stalls; floor path list; owner-class duplication; naming; hook writers; `--with-windows` | §3.4; §6.4; §4.1; §8.1; §6.1; §7 |
| Rev 3.2 | Owner keys read from unverified parent roster; undefined restore; confirm could re-sign attacker bytes | §4.1 keys only from the pointer; `fleet-owner restore`; owner writes start from the pointer tree |
| Rev 3.2 | Merge commits stall the pointer | §4.1 merge rule |
| Rev 3.2 | Per-commit receiver cap can be split around; bare-key releases become exemptions | §4.2 per-source pending set; keyed releases |
| Rev 3.2 | Converge skip lets never-staged drift (posture) persist | §3.3 step 6 |
| Rev 3.2 | Protected items enforced only at the publisher | §3.2 values live in the owner file |
| Rev 3.2 | Preference items have no category, and duplicate `config_files` | §5.1 `agent_preferences`; `config_files` managed keys |
| Rev 3.2 | Owner working-copy edits auto-published; SSH stdin; silent refused publishes | §4.1; §6.1; §3.3 step 6 |
| Rev 3.3 | Merge rule allowed an owner-state rollback | §4.1 descendant-only pointer |
| Rev 3.3 | `config_files` had two sources; protected key also declared in the fold | §5.1; §3.2 |
| Rev 3.3 | Preference value writes could clobber Codex's concurrent writes | §5.1 per-harness writers |
| Rev 3.3 | Descendant-only pointer freezes after a V2 re-root | §4.1 re-root catch-up |
| PR review (CodeRabbit) | Re-seed can re-add retired plugins between P0 and P2 | §3.1; §8.2 P0 |
| PR review (CodeRabbit) | A conflict overwrote ours, so `fleet-take-local` had nothing to publish | §3.3 conflict records |
| PR review (Codex) | Silent-pass extras and owner-dropped items would publish on the next pass | §3.3 ignored marker |
| PR review (Codex) | Windows design bound to concrete host names | §7 roles resolved from config |

## 10. Open decisions for the owner

1. **Harness auto-update.**
   - Leave it on: fast, but plugin updates bypass the canary.
   - Or turn it off on non-canary hosts: updates are then canary-gated, a `canary_wait_hours`
     behind.
2. **Canary members:** which two or more hosts.
3. **Change cap:** 5 changes or 25% per pass or commit (the existing numbers), or higher.
4. **Owner keys:** a 1Password SSH agent key with per-use approval, plus an offline recovery key
   (proposed).
