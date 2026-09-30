# Automatic fleet sync for agent tooling

Status: **design proposal, rev 3.1** · 2026-09-30 · nothing implemented here.

## History

- **Rev 1** made adoption a manual, reviewed step. The owner rejected it: the point is that a
  change on any machine reaches every machine by itself.
- **Rev 2** kept everything automatic. An adversarial review found that its core mechanisms
  failed:
  - it ordered changes by timestamps hosts could forge;
  - its event store couldn't be verified;
  - its baseline was the wrong shape;
  - it let any session's plugin install run as code everywhere;
  - its native Windows port wasn't feasible.
- **Rev 3** replaced the mechanism with a three-way merge over git history. A Thermos review of rev
  3 found that:
  - a compromised host could bypass the owner confirmation;
  - the baseline could move past changes that were never published;
  - the conflict model contradicted the shipped one.
- **Rev 3.1** fixes those, reuses the existing trust gate and machinery wherever it can, and says
  where the code lives.

This reads on top of `2026-08-06-dsc-storage-design-v2.md` (V2). Everything V2 says holds unless a
section here says otherwise.

## 1. What the fleet does

The owner works on one machine at a time. What they do there becomes how every machine is:

- **Adds.** Install or enable a plugin from a known marketplace, or add a skill, on any host. It
  appears on every host on that host's next pass: within about a minute for hosts the nudge can
  reach, and otherwise at the next wake, login, session start or 20-minute timer.
- **Removals.** Uninstall or disable it anywhere, and it goes away everywhere.
- **Preferences** on the synced allowlist propagate the same way.
- **Upstream releases** arrive everywhere through the existing canary gate (§3.6).
- **Native Windows** takes part, with its harness commands running natively.
- **What needs the owner.** Only the *owner-controlled* settings (§4.1) need the owner:
  - a marketplace source the fleet has never seen;
  - a security-posture setting;
  - a new Codex hook;
  - the fleet's own policy.

  Nothing else needs approval.

## 2. Why it didn't happen before

Five writers edit the same agent state: dotfiles templates and the retired list, fleet-chezmoi
capture and `converge-plugins.sh`, Roundhouse seed and apply, the harnesses' own auto-update, and
Roundhouse `config.json` expectations. The reconciler stopped:

- **Canary lock.** The canary's `fleet-run` was stuck from about 2026-08-20 on a lock left by a
  dead process. It refuses such locks instead of recovering them (the age check runs before the
  dead-pid check).
- **Scheduler.** Its launch agents were disabled until 2026-09-29 or 2026-09-30; they are enabled
  again on macbook-pro now.
- **Publishing wedge.** Publishing was wedged by the trailer limit, fixed in #37.
- **Host layers.** The `hosts/*/99-canonical-agents.yaml` files are machine snapshots, 34–111
  plugins each. Host layers beat every other layer, so they override any change made anywhere, and
  they still enable `codex`, `superpowers` and `music-control`.

## 3. The model

### 3.1 One desired state, one writer

- **The fleet layer holds agent tooling.** Agent tooling lives in the fleet layer (`fleet.yaml`,
  `fleet/*.yaml`).
- **Each item is declared in exactly one layer.** The promote gate rejects an agent item that
  appears in more than one layer, so the layer that declares an item is always the layer that
  decides it. Platform-bound items, such as macOS-only bundled Codex plugins, live only in their
  `os/` layer, and local changes to them are written there.
- **No agent tooling in host layers.** Host-layer pins move to the owner-controlled files (§4.1).
- **Owner-controlled settings** live in `fleet/owner/*.yaml` (§4.1).
- **Changes are commits.** A change is a commit to the declaring layer, signed by the host that
  made it and checked by the existing trust ratchet and path-ownership table. There is no separate
  event store.
- **The loop is the only writer.**
  - dotfiles, fleet-chezmoi and `config.json` hand over each host through the marker (§6.2).
  - Re-seed and unanimity promotion lose their agent branches (§8, P2): the silent baseline (§3.3)
    replaces `fleet-seed` for agent state.
  - `fleet-accept` retires for agent items.

### 3.2 Item identity

Agent items move to **new category names**:

```yaml
agent_plugins:
  claude:impeccable@impeccable:               {state: enabled}
  codex:impeccable@openai-curated-remote:     {state: enabled}
  claude:superpowers@claude-plugins-official: {state: absent}   # tombstone (§3.4)
agent_skills:
  claude:ghidra-re: {state: enabled}
```

- **Why new names.** They carry the harness dimension that today's `plugins.<name>` lacks, and
  they keep the marketplace in the key. Names may contain dots, as today (`fleet_item_split` splits
  on the first dot on purpose).
- **Hosts on old code hold rather than mis-converge.** Old code sees unknown categories, holds the
  whole run and alerts (`fleet_unknown_categories`, `fleet-fold.sh:251`). A host still running old
  code therefore holds instead of converging wrongly.
- **Marketplaces are not an agent-plugins category.** They are owner-controlled
  (`fleet/owner/marketplaces.yaml`, §4.1).
- **Aliases.** `fleet/owner/aliases.yaml`, for example `openai-curated` ≡ `openai-curated-remote`,
  normalizes both observations and values. That stops two Codex versions flipping an item.
- **Values carry state only.**
  - No versions or SHAs; §3.6 covers versions.
  - The one exception is the `roundhouse` plugin itself. It keeps its existing self-update
    containment (`fleet-adopt-pin`) and its SHA.
  - Hook trust is not in the value either; it lives in `fleet/owner/hook-trust.yaml` (§3.5).
- **Migration** follows §8, P1.

### 3.3 One pass

Every host-local file below lives under `fleet_instance_path store.run/`, so the second
iris-windows instance (§7) gets its own copy through the existing `ROUNDHOUSE_FLEET_STORE` seam. The
files are:

- the **baseline** (`baseline.json`);
- the **pending-apply markers**;
- the **dirty stamp**;
- the **staged** set: local changes not yet in any pushed commit.

For each item, the baseline records the value this host last saw **agreed**. Agreed means observed
equal to the fleet value at a commit that was fetched and is on the remote.

1. **Observe.**
   - Read the harness records with `jq` and `yq`: `installed_plugins.json` and `settings.json` for
     Claude, and the `[plugins.*]` tables plus the synced keys of `config.toml` for Codex.
   - A harness CLI runs only when those records' hash changed since the last pass.
   - A non-authoritative collector result (for example `plugin list` failing mid-update) makes the
     item **unknown**.
   - Duplicate records for one key are refused, with an alert.
2. **Fetch and verify** with the trust ratchet.
3. **Three-way merge** each item, excluding unknowns. The logic is one pure function (§8.1). Base
   is the baseline value, ours is what was just observed, and theirs is the folded fleet value.

   | ours vs base | theirs vs base | Result |
   |---|---|---|
   | same | same | nothing |
   | same | changed | converge to theirs |
   | changed | same | **local change**: add to staged |
   | changed | changed, and ours = theirs | nothing; advance the baseline |
   | changed | changed, and ours ≠ theirs | **conflict**: theirs wins on this host; alert naming both hosts, with `fleet-adopt ITEM` to take ours |

   **A missing value** is its own state, *unmanaged*:
   - Base missing, theirs missing, ours present: a local add.
   - Base present, theirs missing: the item left desired state by an owner edit. Drop it from the
     baseline and take no action.
   - A tombstone (§3.4) is not missing. It is the value `absent`.

   There are no clocks in this ordering. A host whose loop was dead for a week still publishes what
   the owner changed there, unless someone changed the same item elsewhere meanwhile. State the
   host merely *has* loses, because for everything the owner didn't touch, base equals ours.
4. **Gate staged changes** (§4). Changes needing the owner, or tripping the breaker, become
   **pending-confirm**, a new state distinct from the existing verdict, hold-set and journal `held`
   states. They stay staged, and the host raises one alert listing them.
5. **Publish** the remaining staged changes as one signed commit.
   - It uses `fleet_vcs_publish … no-recover`.
   - On a stale-info rejection: abandon the staged commit, re-fetch and repeat from step 3.
   - Agent-layer heads therefore never diverge, and V2 §8.2b (the agent conflict resolver) and §8.3
     (the hold set) apply only to hand edits and non-agent categories.
   - A publish that fails for any other reason leaves the changes staged.
   - Git history is the only order.
6. **Converge** to the fleet state through each harness's own commands (§3.5), with sealed plans,
   the precondition recheck and backups exactly as today. Converge **skips every staged or
   pending-confirm item on this host**, so a local change is never reverted before it is
   published or confirmed.
7. **Re-baseline** by re-observing after the apply.
   - An item's baseline advances only where ours equals theirs at a commit on the remote.
   - Staged, pending-confirm, failed and unknown items keep their old baseline.
   - A pending-apply marker, written before each harness mutation and cleared after it, makes the
     next pass re-observe that item without publishing it.

**Silent first pass.** A new host, a migrated host, or a host with a lost baseline:

1. Converges.
2. Observes.
3. Writes the baseline only where ours equals theirs.
4. Publishes nothing.

Local extras not in the fleet are left alone and listed in one alert, with `fleet-adopt` to
publish them. That is what prevents the misfire where the MacBook's first pass would have
published 48 false removals and 51 Codex adds.

**Offline.** When Fetch fails, Converge skips staged items as above. The owner's offline changes
stay on the host and publish when it reconnects.

### 3.4 Removals and tombstones

- **Removal means the harness's own records drop the item.** For Claude that is
  `installed_plugins.json` and `enabledPlugins`; for Codex, the `[plugins."X@Y"]` table.
  - If the records are intact but files are missing or corrupt, that is *damage*: it is repaired
    locally and never staged.
- **Tombstones.** A removal publishes `state: absent`. On each host with that harness, apply
  uninstalls through the harness. Today `absent` only forgets the `applied/` record.
- **Compaction.** A tombstone is compacted only once every enrolled host's `applied/` record holds
  that tombstone's digest. A host that deferred the uninstall (§3.5) therefore holds the tombstone
  in place until it has actually uninstalled.
- **Undo** is the existing `fleet-rollback ITEM`.

### 3.5 Apply per harness

- **Claude.** The existing verbs (`marketplace add`, `install`, `enable`, `disable`), plus
  `uninstall` for tombstones, all at user scope.
- **Codex:**
  - `codex plugin add` and `codex plugin remove` are the only install verbs in codex-cli 0.158.
  - Enable and disable go through the app-server `config/batchWrite`, which
    `codex-plugin-hooks.mjs` already uses.
  - Updates go through the existing `update-codex-plugin`, which preserves hook trust.
  - `codex plugin marketplace add`, `upgrade` and `remove` handle marketplaces.
- **Codex hook trust.**
  - Trust is per hook key, meaning plugin plus hook name, in owner-controlled
    `fleet/owner/hook-trust.yaml`. The first trust of a hook key is an owner confirmation.
  - Later hash changes are accepted automatically when they arrive through a Roundhouse update
    from the same confirmed marketplace. That mirrors what `update-codex-plugin` already does
    locally.
  - A local `hooks.state` trust write on one host is never propagated.
- **Marketplaces** are registered from `fleet/owner/marketplaces.yaml`. The
  `extraKnownMarketplaces` fallback is deleted once every enrolled host renders the handover
  marker (§6.2).
- **Relative-source catalogs** (`./plugin`, as used by impeccable and last30days) take their
  identity from the marketplace checkout commit.
- **Held items.** A held "marketplace identity unavailable" item re-registers and refreshes its
  marketplace before it is held again.
- **Live sessions.** Uninstalls and version-replacing updates wait, for up to 24 h, while a
  `claude` or `codex` process is running on the host. Installs and enables don't wait.

### 3.6 Versions and the canary

**Origin-as-canary.** For state changes (enable, disable, add, remove), the origin host has
already applied the change, and its journal's `applied` record of that digest is the canary
evidence.
- The policy `agent_canary_wait_minutes` defaults to 0. The owner may raise it.
- Otherwise the existing `fleet_canary_gate` is unchanged, including V2's condition 3: a canary
  that went silent after applying an item *blocks* promotion rather than passing it on.
- There is no failover. `canary_group` names two or more live hosts instead.

**Upstream versions.**
- Roundhouse-initiated updates (`claude plugin update`, `update-codex-plugin`) wait until a
  `canary_group` host has recorded the target catalog revision in its existing
  `upstreams/<id>/<h>.yaml` record, and that record has aged `canary_wait_hours`.
- Harness auto-update outside Roundhouse bypasses that gate on every host where it is on. That is
  an owner decision (§10).

## 4. Safety

### 4.1 Owner-controlled settings

These live in `fleet/owner/`:

| File | Controls |
|---|---|
| `marketplaces.yaml` | Every marketplace name → source, plus `review: per-plugin` |
| `posture.yaml` | Security-posture keys: `skipDangerousModePermissionPrompt`, `remoteControlAtStartup`, permission rules, hooks, the Roundhouse SessionStart hook (§6.1) |
| `synced-preferences.yaml` | The allowlist of synced preference keys |
| `aliases.yaml` | Marketplace aliases |
| `tool-schemas.yaml` | Per-tool config schemas (§5.2) |
| `hook-trust.yaml` | Trusted Codex hook keys |
| `pins.yaml` | `pin: local` exceptions, per host |
| `policy.yaml` | Breaker thresholds, `agent_canary_wait_minutes`, `canary_group`, and the removal-cap knobs. Moved out of the general fold, so no host can raise them. |

**Enforcement.** Enforcement uses the existing path-ownership gate:
- `fleet_vcs_path_owner` gains a row making `fleet/owner/**` writable only by an **owner**
  principal.
- The trust roster gains an `owner` class with its own ratchet. Owner entries change only in a
  commit signed by an owner key trusted at the parents, and the genesis owner is pinned in
  `identity.yaml`.
- A node key can't sign owner paths, and can't add or replace an owner key: `trust/` owner rows
  are owner-only. That closes the gap where any enrolled host can rewrite `trust/` today
  (`fleet-vcs.sh:49`).

**The owner key.**
- It is never the passphrase-less node key.
- It is either an SSH key in the 1Password SSH agent, set to ask for approval on every use (Touch
  ID), or a passphrase-protected key used from a TTY.
- `roundhouse fleet-confirm ID` presents the pending-confirm item or batch and signs the owner
  file edit. `ID` is an item key or a batch ID from the alert. This is the owner-signed,
  replicated counterpart of the host-local `fleet-review`.

**On receiving hosts:**
- A fleet-layer plugin whose marketplace is not in `marketplaces.yaml` is held.
- A plugin from a `review: per-plugin` marketplace is held until confirmed.
- A posture key or preference not on the allowlist is never applied.

**The threat this covers.** A prompt-injected session, or a malicious plugin, has the node key and
can write the store working copy directly. It still can't do any of the following, because each is
an owner path:
- add or repoint a marketplace;
- loosen posture;
- trust a hook;
- change pins;
- raise the breaker;
- edit the roster.

**Accepted residual risk.** Such a session *can* enable a plugin from an already-confirmed
marketplace, and that propagates. The marketplaces the owner confirmed bound this risk, and it can
be narrowed per marketplace with `review: per-plugin`.

### 4.2 Breaker

The existing `fleet_removal_cap` (`max_removals_per_run` 5, `max_removal_fraction` 0.25) becomes
one pure **change cap**: `fleet_change_cap`, counting adds, removals and state changes, with its
thresholds in `policy.yaml`. It is applied per pass, with no clock:

- **At the publisher,** over the staged set. Over the cap, the whole batch becomes one
  pending-confirm batch, which is what a wiped or restored home directory looks like.
- **At the receiver,** over the incoming changes from each source host in this pass. Over the cap,
  that source's changes are held with one alert.

### 4.3 Never staged

These are never staged:

- items from directory or local-path marketplaces (`music-control` was one);
- non-user plugin scopes;
- items under a pin;
- preference keys not on the allowlist;
- any path on V2's `never:` list, auth files, SSH keys and MCP credentials.

## 5. Preferences and tool config

### 5.1 Preferences

- **Only allowlisted keys sync**, per `synced-preferences.yaml`. Examples are Codex `model` and
  `model_reasoning_effort`, and Claude `theme`.
- **Nothing else crosses hosts.** The rest of `settings.json` and `config.toml` stays host-local
  and is never copied wholesale.
- **Change detection** hashes only the allowlisted keys, because Codex rewrites `config.toml`
  constantly.
- **Posture keys are owner-controlled values** (§4.1). Changing one is a `fleet-confirm`. A local
  change to one is reported and not staged.

### 5.2 Tool config and secrets

- **The file.** A tool config file (`~/.config/last30days/.env`) is an item with a schema in
  `tool-schemas.yaml`.
- **Default deny.** Every key is secret unless the schema lists it under `plain:`, such as
  `INCLUDE_SOURCES`.
  - Plain keys sync like preferences.
  - A key not in the schema is reported and never staged. A secret the patterns fail to recognise
    therefore can't publish in plaintext.
- **Secrets are 1Password references.** The store holds only an `op://…` reference for each secret
  key.
- **Rendering.** Each host renders the file at mode 0600 through a sealed per-target plan with its
  own signed-in `op`.
  - A host without `op` access alerts and leaves the file alone.
  - Values are never logged, journaled or printed.
- **New secrets.** A new secret typed on one host produces an alert asking the owner to store it in
  1Password. The loop never writes the value anywhere.

## 6. Triggers, handover, liveness

### 6.1 Triggers

- **Scheduled passes.** The existing launchd agents and systemd user timers run: fast every 20
  minutes, full as today. `roundhouse fleet-schedule install` installs and loads them; it is a new
  verb, because `launcher-install` is the PATH shim. A pass never re-enables a job an operator
  disabled; it alerts instead.
- **Wake-ups.** Wake-ups start the scheduled job instead of running a pass inline:
  - macOS: `launchctl kickstart gui/$UID/com.novotnyllc.roundhouse.fleet-fast`
  - Linux: `systemctl --user start roundhouse-fleet-fast.service`

  That makes them detached by construction.
- **Push nudge.** The existing push nudge does this over SSH after a publish that changes desired
  state, and returns immediately.
- **Session start.** A Claude `SessionStart` hook does the same thing locally, printing nothing and
  never blocking. `fleet-schedule install` writes it, and its content is an owner-controlled
  posture entry, so there is no chezmoi-shipped hook and no sixth writer. The Codex equivalent
  follows once its hook key is owner-trusted.
- **No file watches.**
- **The dirty stamp.** A trigger that finds the lock held writes a dirty stamp. The holder
  re-checks the stamp *after* releasing the lock, and starts the job again if it moved.

### 6.2 The handover marker

On each host, the loop owns an agent category or preference key only once that host's applied
dotfiles render `~/.config/roundhouse/released-agent-keys`, which lists what dotfiles no longer
writes.

The marker also retires these, per host:

- fleet-chezmoi's plugin capture;
- `converge-plugins.sh`;
- the dotfiles retired list (`claude-code-settings.retired.json`), which is itself a removal
  writer;
- `config.json` agent expectations.

Controller-run writers check the **target's** marker in their sealed plan's precondition recheck.
Those writers are `config.json` apply and fleet-chezmoi capture and converge.

The P2 and P5 deletion steps (§8) run once every enrolled host renders the marker.

### 6.3 Lock and liveness

- **Taking a lock.** A lock carries a nonce, the holder's pid, and the process start time.
- **Recovering a dead lock.**
  1. Check that the holder is dead: its pid is gone, or its start time or command doesn't match.
  2. Rename the lock to a unique name.
  3. Verify that the renamed lock still carries the nonce judged dead.
  4. Only then create a new lock.
- **Releasing.** A release removes only a lock carrying this run's nonce. The EXIT trap no longer
  deletes by path.
- **Heartbeats** stay host-local and publish at most every 6 h. Every host alerts when another
  enrolled host hasn't published one within 12 h, and fleet-chezmoi's probe reports the same.

### 6.4 Record hygiene and the no-op pass

- **Alerts** are keyed by kind and item, and written only when their content changes. A one-time
  compaction runs in P0; the store holds 47,568 alert files today.
- **The poll floor.**
  1. Fetch, a cheap incremental fetch.
  2. Compare the tree hashes of the desired-state paths (`fleet*`, `os/`, `groups/`, `hosts/`,
     `fleet/owner/`) with the last converged ones.
  3. Compare the Observe input hash.

  If all match, exit. No `claude` or `codex` process starts. Record-only commits from peers don't
  cause work.

## 7. Native Windows: the operated instance

iris-windows is the second instance on iris-wsl, using the existing `ROUNDHOUSE_FLEET_STORE` seam
(V2 §9.2), with its own principal, key and `store.run/`.

- **The Windows task.** One Task Scheduler task runs *as the user, only when logged on*
  (InteractiveToken), at logon, on unlock and every 20 minutes. It runs
  `wsl.exe -d <distro> --exec roundhouse fleet-run --fast --with-windows`.
  - The iris-windows pass runs **only** under that flag. Timer and nudge passes on iris-wsl skip
    it, so every Windows pass descends from the logged-in session's token.
  - Windows has no nudge; it catches up at the next task tick or unlock.
- **Interop-routed code (P4).** Its collectors and verbs route over the 0.9.25 interop lane, so
  native `claude` and `codex` run in that session. `apply-windows.ps1` today only updates, so P4
  adds to the interop executor:
  - marketplace add;
  - install, enable, disable and uninstall;
  - Codex `batchWrite`;
  - the tool-config render.
- **Fail closed.** When interop is unavailable, every Windows observation is **unknown**, and
  falling back to the WSL `$HOME` or `CLAUDE_CONFIG_DIR` is forbidden. So no WSL-side state is ever
  observed or applied as iris-windows.
- **What this keeps.** No inbound connection is made to Windows. There is no WSL fallback for
  Windows work: WSL only carries commands that run natively.
- **Native membership** (the loop itself under Git for Windows) is not planned: Roundhouse's
  signing and stat helpers are Darwin/Linux-only, and about 19k lines would need porting.

## 8. Implementation

### 8.1 Code layout and tests

`lib/fleet-run.sh` is 3,149 lines, and `fleet_run_command` alone is about 560. New code goes in
modules, and `fleet_run_command` only calls them:

| Module | Contents | Test |
|---|---|---|
| `lib/fleet-merge.sh` | `fleet_merge3 BASE OURS THEIRS`: pure, modelled on `fleet_vcs_hold_set` | `tests/NN-merge.sh`, table-driven over §3.3's rows |
| `lib/fleet-observe.sh` | Harness readers, record hashing, aliases, unknown handling | `tests/NN-observe.sh`, with fixture records including duplicates and non-authoritative results |
| `lib/fleet-baseline.sh` | Baseline, staged, pending-apply, dirty stamp (instance paths) | `tests/NN-baseline.sh`, covering offline, rejected push and failed apply |
| `lib/fleet-agent-keys.sh` | `agent_*` key parsing and migration map (moved out of `fleet-fold.sh`) | extends `tests/70-fold.sh` |
| `lib/fleet-confirm.sh` | Owner paths, owner roster class, `fleet-confirm` | extends the trust and jj-run tests (`tests/93-jj-run.sh`) |
| `lib/apply-claude.sh`, `lib/apply-codex.sh` | Per-harness verbs that `fleet_run_apply_item` dispatches to | extends `tests/74-run.sh` |
| `lib/fleet-schedule.sh` | Install, trigger, lock nonce | `tests/NN-schedule.sh` |

`fleet_change_cap` replaces `fleet_removal_cap` in place (`tests/72-records.sh`).

### 8.2 Phases

Each phase ships alone and leaves the fleet no worse off.

- **P0: stop the bleeding.**
  - **Already landed:** #35 (package managers), #37 (trailers).
  - **Code:**
    - the lock nonce and takeover (§6.3);
    - alert keying and compaction;
    - heartbeat throttle;
    - the fetch-based floor;
    - kickstart-style nudge;
    - `fleet-schedule install`;
    - identity-gate self-repair and relative-source identity;
    - Claude uninstall for `absent`;
    - `canary_group` with two live hosts.
  - **Data, one owner-reviewed store commit:**
    - Delete `hosts/*/99-canonical-agents.yaml` and the agent `proposals/promote-*`.
    - Keep `fleet/99-canonical-agents.yaml` as the fleet baseline, minus tombstones for `codex`,
      `superpowers` and `music-control`, with the impeccable and last30days entries corrected.
    - Host-layer entries not in the fleet layer become unmanaged, neither removed nor spread. One
      report lists them for adoption. This avoids both a mass add and mass removals.
  - **Compatibility:** dotfiles already retires those three (`claude-code-settings.retired.json`),
    so fleet-chezmoi's convergence agrees with the tombstones.
  - **Also:** fix the local 0644 mode of `.chezmoidata.toml`.
  - **Result:** Claude plugins converge fleet-wide again, and the retired plugins are uninstalled.
    Capture still runs through today's paths.
- **P1: identity.**
  - **P1a** ships readers for the `agent_*` categories and `fleet/owner/`, the owner roster class,
    and the Codex apply path. Nothing writes them yet.
  - **P1b** starts after every enrolled host reports P1a:
    - One owner-signed commit moves shared-layer entries to `agent_*` keys, moves marketplaces and
      policy into `fleet/owner/`, and commits a migration map from old ids to new ids.
    - On each host's first P1b run, it re-keys its own `applied/` and journal references.
    - The canary gate accepts a mapped old-id `applied` digest with an identical normalized value
      as evidence for the new id, so the rename triggers no wait.
- **P2: automatic capture.**
  - **Adds:** baselines, the merge, staging, publishing, tombstones everywhere, `fleet-confirm`,
    `fleet_change_cap`, and the scope rules.
  - **Handover:** dotfiles renders the marker, and drops plugin and marketplace keys and the
    retired list, per host.
  - **Deletions, once every host renders the marker:**
    - the agent branches of `seed_desired`;
    - agent unanimity promotion;
    - `fleet-accept` for agent items;
    - fleet-chezmoi `converge-plugins.sh` and plugin capture;
    - the `extraKnownMarketplaces` fallback.
- **P3: triggers.** The SessionStart hook and the dirty stamp.
- **P4: Windows.** Enrol the operated instance, add the interop verbs, and register the task.
- **P5: preferences and tool config.**
  - The allowlist, tool schemas, 1Password-referenced secrets, and posture values under
    `fleet/owner/`.
  - dotfiles releases each key through the marker only once the loop owns it.
  - **Deletion:** the dotfiles preference templating and `config.json` agent expectations.

## 9. Review findings and where they're handled

| Finding | Where |
|---|---|
| Rev 2: snapshot host layers override everything | §3.1 one declaring layer; P0 data |
| Rev 2: automatic spread runs code everywhere | §4.1 |
| Rev 2: forgeable timestamps; a stale host wins | §3.3; no clocks |
| Rev 2: wrong baseline; first-pass misfire | §3.3 silent first pass |
| Rev 2: trailer wedge | #37 |
| Rev 2: record churn; wake storms | §6.4 |
| Rev 2: native Windows port | §7 |
| Rev 2: harness normalization oscillation | §3.2 aliases; §3.3 step 7 |
| Rev 2: auto-update bypasses the canary | §3.6; §10 |
| Rev 2: `events/` unverifiable | no event store |
| Rev 2: dropped triggers; the nudge kills peer runs | §6.1 |
| Rev 2: failure windows resurrect removals | §3.3 steps 6–7 |
| Rev 2: lost plugin scope | §4.3 |
| Rev 2: Codex verbs; hook trust | §3.5 |
| Rev 2: secrets | §5.2 |
| Rev 3: owner confirmation bypassable; `trust/` writable by any host | §4.1 owner paths and owner roster class |
| Rev 3: baseline passes unpublished changes; owner changes reversed | §3.3 "agreed" baseline; converge skips staged |
| Rev 3: the latency claim conflicts with the canary; failover defeats condition 3 | §3.6 origin-as-canary; no failover |
| Rev 3: rejected-push semantics conflict with `fleet_vcs_publish` | §3.3 step 5 `no-recover` |
| Rev 3: an edit written to fleet.yaml loses to `os/` | §3.1 one declaring layer |
| Rev 3: the Windows instance falls back to the WSL home and shares a baseline | §7; instance paths |
| Rev 3: hook auto-trust contradicts posture | §3.5 owner-trusted hook keys |
| Rev 3: per-host migration impossible under path ownership | §8.2 P1a/P1b |
| Rev 3: non-atomic lock takeover | §6.3 nonce |
| Rev 3: `setsid` missing on macOS; chezmoi hook as a sixth writer | §6.1 kickstart; owner posture entry |
| Rev 3: no code layout or tests | §8.1 |
| Rev 3: two conflict models | §3.3 step 5 |
| Rev 3: "held" overloaded; `fleet-confirm` ID undefined | §3.3 step 4 pending-confirm; §4.1 |
| Rev 3: version gating undefined | §3.6 `upstreams/` records |
| Rev 3: P0 fights fleet-chezmoi | §8.2 P0 compatibility |
| Rev 3: retirements gated, never deleted | §8.2 deletion lines |
| Rev 3: breaker numbers disagree; clock window | §4.2 one pure per-pass cap |
| Rev 3: the no-op floor needs a fetch; Observe spawns CLIs | §6.4; §3.3 step 1 |
| Rev 3: tombstone compaction by time | §3.4 per-item `applied` |
| Rev 3: P0 fold union vs intersection | §8.2 P0: fleet layer as-is; extras unmanaged |

## 10. Open decisions for the owner

1. **Harness auto-update.**
   - **Leave it on** (today's behaviour). It's fast, but plugin updates bypass the canary.
   - **Turn it off on non-canary hosts.** Updates then arrive through Roundhouse and are
     canary-gated, a `canary_wait_hours` behind.
2. **`canary_group`:** which two or more hosts.
3. **Breaker:** 5 changes or 25% per pass (the existing numbers), or higher.
4. **Owner key:** a 1Password SSH agent key with per-use approval (proposed), or a
   passphrase-protected key.
