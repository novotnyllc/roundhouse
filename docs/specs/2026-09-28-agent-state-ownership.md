# Automatic fleet sync: one loop, one writer per fact

Status: **design proposal, rev 2** · 2026-09-28 · nothing implemented here.

Rev 1 made adoption a manual, reviewed step. That defeats the purpose of
the system, which is that a change made on any machine reaches every
machine without anyone doing anything. Rev 2 keeps everything automatic.
It fixes the actual defect instead: several automations compete, and none
of them owns the whole loop.

This reads on top of `2026-08-06-dsc-storage-design-v2.md` (V2), which
covers the store, layers, trust, reconcile and canary. It keeps V2's trust
ratchet, reconcile point and signed store. It deliberately changes one V2
non-goal, "timestamps are evidence, not a decision rule", for agent
tooling: see §3.3.

## 1. What the fleet should do

The owner works on one machine at a time. Whatever they do there becomes
how every machine is, on its own:

- **Adding.** Install or enable a plugin, add a marketplace, add a skill, or
  configure a tool on any host. Within one cycle, typically ≤ 25 minutes,
  every host has it, in every harness it applies to.
- **Removing.** Uninstall or disable it on any host, and it goes away everywhere.
- **Upstream releases.** A new version of anything installed arrives
  everywhere, first on a canary, then on the rest.
- **Native Windows.** It takes part like any other machine.
- **Settings.** A preference changed on one host propagates the same way.
  So does a tool key entered on one host, encrypted so it never appears in
  plain text.
- **When a person is involved.** Nothing needs approval. A person hears
  about it only when something is genuinely ambiguous or unsafe (§3.5),
  and even then as an alert with an undo, not a gate that stops the fleet.

## 2. Why it didn't do that on 2026-09-28

| Symptom | Cause |
|---|---|
| Nothing converged since 2026-09-22 | `fleet-run` is not scheduled on any host. The launch agents are unloaded, and the canary's last runs refused a 32-day-old lock with "remove it". The repo has no scheduler installer. |
| Peers never applied plugin changes | They wait on the dead canary. The canary's own plugin items are held on "installed marketplace identity unavailable", and nothing retries marketplace registration. |
| iris-windows stale | Native Windows isn't enrolled, and no run targets it. |
| A test plugin (`music-control`) spread fleet-wide, then `codex` and `superpowers` spread and were retired the same day | Two capture paths run independently. fleet-chezmoi captures `settings.json` entries, and Roundhouse re-seeds host inventory. Neither can tell a deliberate change from an echo of the other, and nothing marks a local directory marketplace as local. |
| The store still enables the retired plugins | Retirement went through dotfiles' retired list. Roundhouse re-seed "upserts, never removes", and `absent` never uninstalls. |
| Impeccable could not be declared per harness | Store records are keyed by name with one marketplace, and the apply path is Claude-only. |
| last30days keyless on most hosts | No system owns tool config or its secrets. |
| Codex `model` flip-flops | Three writers: the dotfiles modify script, Roundhouse `config.json` expectations, and the Codex app. |

Automation was not the problem. There were five automations — dotfiles templates, fleet-chezmoi capture, fleet-chezmoi plugin convergence, Roundhouse seed/apply, and harness auto-update — each writing overlapping state, each blind to the others. The one that could reconcile them had stopped, and nobody noticed.

## 3. The design

### 3.1 One loop per host

Every host runs one scheduled loop, `roundhouse fleet-run`, every 20 minutes. Each pass does four things in order:

1. **Observe.**
   - Read the host's actual agent state from each harness's own records: installed and enabled plugins per harness, registered marketplaces, standalone skills, tool config files, and the harness preference keys the fleet syncs.
   - Diff it against what this host last applied (`applied/<host>`).
   - Anything that differs is a **local change**.
2. **Publish.** Each local change becomes a signed **change event** in the store (§3.2), fleet-wide by default.
3. **Converge.**
   - Fold the store (events plus layers) into this host's desired state.
   - Apply it through each harness's own commands: install, update, enable, disable and uninstall, for Claude and for Codex.
   - Verify each result.
4. **Report.** Write a heartbeat, journal the outcomes, and raise any alert.

This one loop replaces fleet-chezmoi's plugin capture and convergence, dotfiles' plugin keys, and Roundhouse's upsert-only re-seed. Those were several writers; now there is one. Harness auto-update may still run between passes. The next Observe step sees its result as an ordinary version change and reconciles it.

### 3.2 Change events, not snapshots

A host's inventory is not written wholesale into the store as desired state; that is what re-seed does today, and it is why removals never happen. Instead, each observed difference is one event:

```yaml
# store/events/<item>/<utc-ts>-<host>.yaml  (host-keyed, one writer)
item: plugins.impeccable.codex        # category.name.harness
value: {state: enabled, marketplace: openai-curated-remote}
observed_at: 2026-09-28T18:24:47Z     # when this host first saw the change
host: mac-studio
cause: local                          # local | upstream | applied-from:<event>
```

- **Fold rule.** For each item, the event with the latest `observed_at` wins. It becomes the effective fleet value, and hand-written layer values still override it (§3.4).
- **Echo filter.** A host applying another host's change records `cause: applied-from`, which never generates a new event. Only genuine local changes do. This is what stops a change bouncing around the fleet.
- **Compaction.** The full pass compacts old events per item to the latest one, with a floor so undo still works (§3.5). This keeps the evidence bounded, per the scaling spec.

### 3.3 Last change wins, and why that is correct here

V2 made timestamps evidence rather than a decision rule, because it assumed concurrent editors. This fleet has one operator working on one machine at a time, so the most recent deliberate change is the intent. For agent-tooling items, the rules are:

- **Latest `observed_at` wins**, per item and per harness.
- **Timestamps come from the host that made the change**, read from harness records such as install times, or from the host's first observation of the change. The host clock is checked against the store commit time, and a host whose skew exceeds 5 minutes raises an alert. Its events are ordered by commit time instead.
- **Genuinely concurrent changes** (two hosts changed the same item within one cycle) resolve to the later one, raise an alert that names both, and offer the undo. The fleet doesn't stop.

Items outside agent tooling keep V2's conflict ladder unchanged: packages, privileged operations and projects.

### 3.4 Scope: fleet by default, with local and layered exceptions

- **Default.** A change is fleet-wide, applying to every host where that harness exists.
- **Local by nature.** Some changes never propagate:
  - a directory or local-path marketplace, and every plugin from it (`music-control` was one);
  - a plugin that exists in only one harness, which applies to hosts that have that harness;
  - platform-bound items, via `os/<platform>.yaml`. `tart-xcode-runner`, for example, is macOS-only.
- **Local by choice.** A host-layer entry `pin: local` makes an item stay host-local, and the loop never publishes events for it. This is the one thing written by hand, and only for exceptions.
- **Hand-written layers still work.** `fleet.yaml`, `os/`, `groups/` and `hosts/` values beat events. They're the way to force a value regardless of what hosts do: a lock, not a workflow.

### 3.5 Intent, safety, and undo, all automatic

- **Uninstall versus damage.**
  - **Deliberate removal** means the plugin is gone from the harness's own records (`installed_plugins.json`, `enabledPlugins`, or Codex's `[plugins.*]`). That publishes a removal.
  - **Damage** means the records are intact but files are missing or corrupt. That is repaired locally and never published.
- **Mass-change breaker.** A host whose single pass would publish more than 5 removals, or more than 25% of its items, publishes them as `held`. It keeps converging everything else and raises an alert: this is what a wiped or restored home directory looks like. The first host to observe it again after an operator's `fleet-release` sends them on.
- **Undo.** Every applied change is journaled with the event that caused it. `roundhouse fleet-undo ITEM` publishes a reversing event, restoring the previous value everywhere. So "latest wins" is always one command from being reversed.
- **Secrets are never plain.** Tool secret values are captured only in encrypted form (§3.7).
- **Sensitive files are never touched.** SSH keys, auth files and MCP secrets are never observed or published. V2's `never:` list and `agent-settings-and-auth.md` rules stay.

### 3.6 Per-harness items and a real Codex path

- **Item identity** becomes `plugins.<name>.<harness>`, and likewise `marketplaces.<name>.<harness>` and `skills.<name>.<harness>`. Impeccable is simply two items:
  - `plugins.impeccable.claude`, from the pbakaus marketplace
  - `plugins.impeccable.codex`, from `openai-curated-remote`

  Each is observed, published and applied on its own. An existing bare `plugins.<name>` value folds into `.claude`, which is what the code does today, so existing digests don't change.
- **Codex apply** uses the harness's own verbs:
  - `codex plugin marketplace add`, `upgrade` and `remove`
  - `codex plugin add NAME@MARKET` and `codex plugin remove`
  - updates through the existing hook-trust-preserving `update-codex-plugin` helper
  - enable and disable through the `[plugins."NAME@MARKET"] enabled` key

  Results are verified by SHA and version, as the Claude path already does.
- **Marketplace sources** are items too, recorded with their source and ref. They are registered from the store, not from `settings.json`. A held plugin's marketplace is re-registered and refreshed before the item is held again, so today's permanent holds can't recur.
- **Relative-source catalogs** (`./plugin`, as used by impeccable and last30days) take their identity from the marketplace checkout's commit, so they can pass the identity gate.

### 3.7 Tool config and secrets, synced automatically

- A tool's config file is an item: `tool_config.last30days`, path `~/.config/last30days/.env`. The loop observes it like any other item.
- **Settings** (for example `INCLUDE_SOURCES`) are published as ordinary values.
- **Secret values** are detected by the existing secret patterns plus declared key names. They are encrypted before they leave the host, using **age**, with every enrolled host's Roundhouse node key as a recipient. Node keys are already ed25519 SSH keys and age accepts them directly, so no new key management is needed.
  - Only ciphertext is in the store.
  - Each host decrypts with its own node key when rendering the file (mode 0600).
  - Values are never logged, journaled or printed.
- Configuring last30days once, on any host, configures it everywhere. Rotating a key is the same: change it on one host.
- Existing plaintext secrets in `.chezmoidata.toml` can migrate to this, a later cleanup and not a prerequisite.

### 3.8 Harness preferences have one owner: the loop

Harness preference keys the fleet syncs are items in the same loop, not a second system. They include:

- Claude `settings.json` keys such as `remoteControlAtStartup` and `theme`
- Codex `config.toml` `model` and `model_reasoning_effort`

Observed on any host and published as events, they converge everywhere. The rest of each file stays host-local, and nothing is ever copied wholesale. Where they come from today:

- **dotfiles** stops templating those keys (and the plugin and marketplace keys), keeping everything else it owns: instruction files, env, PATH, shells.
- **Roundhouse `config.json`** stops declaring expected values.
- **The Codex app** writing `model` counts as a local change, like any other. If the owner picks Astra in the app on one machine, every machine gets Astra.

### 3.9 The loop keeps itself alive

- **Self-installed scheduler.** `roundhouse launcher-install` installs and loads the per-host job:
  - launchd on macOS
  - systemd user timers on Linux and WSL
  - for native Windows, iris-wsl's job covers it (§3.10)

  Every pass re-asserts that the job is loaded, so a job that falls out repairs itself on the next manual or scheduled run.
- **Stale locks self-recover.** A lock whose holder PID is dead, or isn't a Roundhouse process, is taken over and journaled. A live holder is the only thing that still blocks.
- **Liveness is visible everywhere.** Each pass writes a heartbeat. Every host's pass alerts when any enrolled host hasn't completed a pass in 2× its cadence, and fleet-chezmoi's probe shows the same finding. A silent fleet can't stay silent.
- **Canary failover.** Upstream updates still go to a canary first. A canary silent for more than twice the canary wait hands over to the next host on the canary list. User-originated changes don't wait on a canary: the originating host already has the change, so it is its own canary.

### 3.10 Native Windows, operated from its WSL sibling

- iris-windows becomes an enrolled host: `hosts/iris-windows.yaml` and `os/windows.yaml`. It gets its own key and principal, `iris-windows@<domain>`, held on the WSL side under `~/.config/roundhouse-iris-windows/`, as V2 §9.2 describes.
- iris-wsl's scheduled pass runs a second pass for iris-windows. Observe, Converge and Report all go through the 0.9.25 interop lane, so native `claude` and `codex` run in the logged-in session. Its events are signed as iris-windows.
- **Logged off** means WSL is down and the pass doesn't run. The liveness alert makes that visible, and the next logged-in pass catches up.
- **The alternative** is native membership (the 2026-08-10 decision). That needs jj, signing and a launcher on Windows, none of which exist. The operated instance delivers the same automation now. Native membership remains possible later without redoing any of this.

### 3.11 fleet-chezmoi's place

fleet-chezmoi keeps doing what only it can: the dotfiles files chezmoi owns, meaning the instruction files, shell env, PATH, templates and scripts. For those files it becomes automatic too:

- The Roundhouse loop runs fleet-chezmoi's fast path on each pass, as sealed plans applied under policy instead of per-stage approval:
  - pull when the source is clean and behind
  - apply source-driven changes
  - capture uncontested plain-file edits
- Conflicts, secret-looking values and sensitive paths still go to an alert with evidence, because a text merge can't be resolved safely by timestamp alone.
- It no longer touches plugins, marketplaces or harness preferences. The loop owns those.

## 4. How the same day plays out under this design

| Event | What happens |
|---|---|
| `music-control` installed on one Mac from a local directory marketplace | Local by nature (§3.4). It stays on that Mac. |
| `superpowers` and `codex` installed on mac-studio | Published as events. Every host has them within a cycle. |
| The owner uninstalls them on one host | That host's records show a deliberate removal (§3.5). A removal event is published, and every host uninstalls them next pass. One event, not a dotfiles edit plus a store edit. |
| Impeccable moved to the curated catalog on Codex | The Codex item on the host where it was moved changes marketplace. Every host's Codex follows. Claude's item is untouched. |
| last30days configured on the MacBook | The settings are published and the key is encrypted to every node. Every host renders `~/.config/last30days/.env`. |
| Codex app switches to Astra | That is a local change to `model`. Every host follows, and `fleet-undo` restores Sol. |
| A new Compound Engineering release | The canary updates, then the peers. iris-windows follows through iris-wsl's pass. |
| The canary's scheduler dies | The next pass anywhere reports the canary silent. Failover to the next canary. The dead job is re-asserted on its host's next run. |

## 5. Guarantees kept from the original work

- Every mutation still runs as a sealed plan with a precondition recheck immediately before it. Identity is verified before mutation, and a backup is taken before an apply. Policy replaces per-set human approval; the plans are unchanged.
- No secret value is printed, logged, journaled or stored in plain text.
- Native Windows work runs only as native processes: interop or Codex remote control, never WSL-side execution.
- No sudo or Administrator password is ever requested or relayed.
- Every change is attributable (host, time, cause) and reversible (`fleet-undo`).

## 6. Migration

Each phase ships alone.

- **P0: restart and clean.**
  1. Repair the store data: retire `codex`, `superpowers` and `music-control`; correct impeccable and last30days.
  2. Only then reload the loop on every POSIX host and clear the dead lock. Doing it first would converge the stale entries.
  3. Remove the duplicate Codex impeccable.
  4. Configure last30days everywhere once.
  5. Update iris-windows's Claude plugins through the interop lane.
- **P1: liveness.** Self-installed scheduler, stale-lock recovery, heartbeat alerts, canary failover. This alone would have prevented the six-day stall.
- **P2: per-harness items.** Harness-qualified identity, the Codex apply path, marketplace items, uninstall on removal, and the identity-gate and relative-source fixes.
- **P3: the event loop.**
  - Observe, publish, fold and converge with events, the echo filter, scope rules, the breaker and `fleet-undo`.
  - Re-seed is retired in favor of Observe.
  - dotfiles drops the plugin, marketplace and preference keys, and fleet-chezmoi drops plugin capture, in the same release, so there's never a moment with two writers.
- **P4: native Windows.** The operated instance.
- **P5: tool config and preferences.** Encrypted tool secrets, and harness preference keys as items.
- **P6: automate fleet-chezmoi's fast path** under the loop (§3.11).

## 7. Decisions for the owner

1. **Windows:** the operated instance from iris-wsl (recommended), or native membership.
2. **Canary order:** which hosts may act as canary, and in what order.
3. **Breaker thresholds:** 5 removals or 25% per pass (proposed).
4. **Secrets:** age-encrypted in the store to node keys (proposed), or 1Password references resolved at render time.
