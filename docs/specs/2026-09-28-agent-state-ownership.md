# Agent state: one owner per fact

Status: **design proposal, rev 1** · 2026-09-28 · nothing implemented here.

This reads on top of `2026-08-06-dsc-storage-design-v2.md` (V2: the store,
layers, trust, reconcile and canary rules) and `2026-08-10-dsc-scaling.md`.
It changes who owns agent-tooling state, and it adds the missing pieces
that let that owner actually keep hosts current. The storage model, the
trust ratchet, the reconcile point and the sealed-plan pipeline are not
changed.

## 1. What went wrong

One day of fleet work, 2026-09-28, surfaced a series of failures that
look unrelated but share one cause.

| Symptom | What caused it |
|---|---|
| iris-windows ran Claude Compound Engineering 3.28.0 and Railyard 0.10.0 when the rest of the fleet had 3.29.0 and 0.12.5. | Native Windows is not a fleet member, and nothing schedules convergence for it. |
| No host had converged Roundhouse desired state since 2026-09-22. | `fleet-run` is not scheduled anywhere. macbook-pro's LaunchAgent is installed but not loaded, and its last runs refused a 32-day-old lock with "remove it". mac-mini and mac-studio have no job loaded. iris-wsl has no timer. The repo has no scheduler installer: the scheduling contract exists only in `fleet-update` prose, checked by a doc-text test. Only Claude's own marketplace `autoUpdate` kept anything current. |
| Peers never apply plugin changes even when running. | They wait on canary evidence from macbook-pro. macbook-pro is dead (above) and holds its own plugin items: "installed marketplace identity unavailable". The identity gate never retries marketplace registration, and the full pass skips held items' marketplaces. |
| `music-control`, then `codex@openai-codex` and `superpowers`, spread to every host and had to be retired by hand the same day. | fleet-chezmoi captures every `enabledPlugins` and `extraKnownMarketplaces` entry. A plugin installed on one host becomes fleet-wide on the next capture. |
| The Roundhouse store still declares those three plugins `enabled`. | Retirement happened in dotfiles (a retired list). Nothing told the store. Re-seed "upserts, never removes". |
| Impeccable could not be declared correctly. | It comes from the pbakaus marketplace on Claude and the curated marketplace on Codex. The store keys a plugin by name with one marketplace. The apply path is Claude-only in code (`fleet-run.sh` seed comment: "the plugins apply surface is Claude-owned"). |
| last30days runs keyless on three hosts. | Its `~/.config/last30days/.env` exists only where someone created it. No system owns per-tool config or the secrets it needs. |
| Codex `model` flips between `gpt-6-sol` and `gpt-6-astra`. | Three writers: the dotfiles Codex modify script (sol/medium), Roundhouse `config.json` `agent_artifacts[codex-settings]` (astra/max, inventory only), and the Codex app (wrote astra at 18:02). |
| iris-wsl reported six "edited" marketplace entries. | Claude rewrote key order; fleet-chezmoi compared text. Fixed in agent-utilities 0.19.1, but it only mattered because fleet-chezmoi was capturing state it should not own. |

**Root cause.** The same agent-tooling facts have up to five writers:
- the dotfiles `settings.json` template and its retired list
- the Roundhouse store
- fleet-chezmoi capture, plus its `plugins` step
- the harnesses themselves (`claude plugin …`, `autoUpdate`, the Codex app)
- Roundhouse's `config.json` expectations

No document names one owner. V2's co-ownership rule covers `config_files` keys only. Where two writers disagree, the winner is whoever ran last. And the one writer designed to converge the fleet, `fleet-run`, has no owner for its own scheduling or liveness, so it stopped silently.

## 2. Principles

1. **One owner per fact.** Every piece of agent state has exactly one system that declares it and one that converges it. Every other system may observe it and report on it, and must not write it.
2. **Desired state is declared, never inferred from a host.** A change made on one host is evidence. It becomes desired state only through an explicit step: a reviewed adoption, not an automatic capture.
3. **Every declaration has a full lifecycle.** Add, change, retire and remove each have a defined path. Retirement propagates to every host and ends in an uninstall.
4. **Per-harness, not per-name.** Claude and Codex are separate surfaces. The same logical plugin may come from different marketplaces in each.
5. **Convergence is a liveness obligation.** A host that has not converged in 2× its cadence is an alert on every other host, not a silent gap. The scheduler and its lock belong to the system that needs them.
6. **Native Windows is a first-class target.** Its desired state and freshness are the same as any host's, reached through the lane that works: WSL interop, landed in Roundhouse 0.9.25.
7. **Secrets stay in the secret store.** Systems declare which secret a tool needs, render it where the tool reads it, and verify that it is present. No value is logged or captured.

## 3. Ownership map

| Fact | Declared by | Converged by | Everyone else |
|---|---|---|---|
| Which plugins each harness has installed and enabled (Claude and Codex) | **Roundhouse store**, `plugins` category, harness-qualified (§4.1) | **Roundhouse fleet-run** | dotfiles: never writes. fleet-chezmoi: observes and reports only. Harness autoUpdate: freshness only. |
| Which marketplaces each harness has registered, with source and ref | **Roundhouse store**, new `marketplaces` category (§4.2) | **Roundhouse fleet-run** | dotfiles stops shipping `extraKnownMarketplaces`. fleet-chezmoi stops capturing it. |
| Standalone skills | Roundhouse store `skills` (unchanged) | Roundhouse fleet-run | unchanged |
| Plugin and skill versions | Marketplace pins: novotnyllc/marketplace for ours, upstream catalogs for others | fleet-run: `update` to the pinned SHA | Harness autoUpdate may run ahead; the next run reconciles. |
| Per-tool config and secrets (for example last30days `.env`) | **Roundhouse store**, new `tool_config` category, names only (§4.4) | **dotfiles renders the file** from its secret data; Roundhouse **verifies presence** | fleet-chezmoi holds any secret-looking value back from capture, as it does today. |
| Harness preferences: Claude settings keys other than plugins and marketplaces; Codex `model` and effort | **dotfiles** (template or modify script) | chezmoi apply, driven by fleet-chezmoi | Roundhouse `config.json` stops declaring expected values; it only inventories. An app write is drift, sent to review (as fleet-chezmoi already does for modify sources). |
| Instructions files (`CLAUDE.md`, `AGENTS.md`), env, PATH, shells | dotfiles | chezmoi apply | unchanged |
| Hook trust (Codex `[hooks.state]`) | host-local, never synced | `codex-plugin-hooks.mjs` after each install or update | unchanged |
| fleet-run scheduling, lock and liveness | **Roundhouse**, new `scheduler` ownership (§4.5) | `roundhouse launcher-install` / `fleet-doctor` | dotfiles never ships a Roundhouse job. |
| Host identity names | Roundhouse `config.json` machine names | — | dotfiles roles map to them through one table (§4.7), not two naming schemes. |

## 4. Changes

### 4.1 Harness-qualified plugin records

A plugin item gains optional per-harness sub-records. The existing scalar and
`{state, marketplace}` forms keep working and mean "Claude", which is exactly
what the code does today.

```yaml
plugins:
  impeccable:
    claude: {marketplace: impeccable}          # state defaults to enabled
    codex:  {marketplace: openai-curated-remote}   # Codex's curated catalog
  last30days:
    claude: {marketplace: last30days-skill}
    codex:  {marketplace: last30days-skill}
  superpowers: absent                          # retired on every harness
  context7:
    claude: {marketplace: claude-plugins-official}
    codex: absent                              # a per-harness knockout
```

- **Identity** becomes `plugins.<name>.<harness>` for digests, verdicts, `applied/`, holds and journal lines. A bare `plugins.<name>` value folds into `.claude`. This is one normalization rule in `fleet_fold`, and existing digests are unchanged.
- **Codex apply path**, new. It uses the harness's own commands, as V2 already prescribes:
  - `codex plugin marketplace upgrade`
  - `codex plugin add NAME@MARKET` for an install
  - the existing `update-codex-plugin` helper for an update, which carries hook-trust snapshot and approval
  - enable and disable through the `[plugins."NAME@MARKET"] enabled` key, written under the same review
  - The install and update verifications mirror the Claude path: SHA and version.
- **Seeding** records what each harness actually has, under its harness key. This replaces the 2026-09-22 filter that dropped Codex rather than modelling it.

### 4.2 A `marketplaces` category

```yaml
marketplaces:
  impeccable:        {claude: {source: github, repo: pbakaus/impeccable}}
  openai-curated-remote: {codex: builtin}      # shipped with Codex; never registered
  novotnyllc:        {claude: {source: github, repo: novotnyllc/marketplace},
                      codex:  {source: git, url: https://github.com/novotnyllc/marketplace.git}}
  openai-codex: absent
```

- `fleet_run_ensure_marketplace` reads the source from the store, not from `~/.claude/settings.json`. The #32 fallback to `extraKnownMarketplaces` stays only for the migration window (§6, P1).
- **Identity-gate self-repair.** When a plugin's installed marketplace identity is unavailable, the run re-registers or refreshes the declared marketplace and retries once before holding. The full pass refreshes the marketplaces of held items too; today it skips them, which makes those holds permanent.
- **Relative-source catalogs.** Marketplaces whose manifest uses `./plugin` sources (impeccable, last30days) get their identity from the marketplace checkout's commit, not from a per-plugin SHA they do not have. Without this, those plugins can never pass the identity gate.

### 4.3 Retirement ends in an uninstall

- `absent` at the fleet, os, group or host layer already knocks an item out of the fold. What is new is that the apply side acts on it: for an item in `applied/<host>`, `absent` now runs the harness's uninstall (`claude plugin uninstall --scope user`, `codex plugin remove`) and verifies the result, instead of only forgetting the record.
  - V2's removal rules are unchanged: only what `applied/` owns, capped per run, and never on an unreadable source.
- **A local uninstall observed at seed time** becomes a named, reviewable proposal: `proposals/retire-<item>-on-<host>.yaml`. It is not silently re-upserted and not silently dropped, so the V2 §10.3 table gets the row it was missing.
- **The proposals path gets fixed before anyone relies on it:**
  - **Unanimity bug.** A host with no value drops out of the comparison because `jq --argjson value ""` exits 2, so "unanimous" proposals list only two of four hosts.
  - **Accept edits too little.** `fleet-accept` deletes from the flat host file but not from `hosts/<h>/*.yaml`. It must edit every tier it read.

### 4.4 `tool_config`: declared needs, rendered files, verified presence

```yaml
tool_config:
  last30days:
    requires: [plugins.last30days]
    file: {path: ~/.config/last30days/.env, mode: "0600"}
    keys: [SCRAPECREATORS_API_KEY]        # names only; values never enter the store
    settings: {INCLUDE_SOURCES: "..."}    # non-secret settings may be literal
```

- **The store declares what a tool needs**: names, the file, its mode, and non-secret settings.
- **dotfiles renders the file** from its existing secret data (`.chezmoidata.toml` env entries with `secret = true`, the pattern already used for API keys), because rendering user files is chezmoi's job. Values never pass through Roundhouse or its journals.
- **Roundhouse verifies presence.** The collector reports the file's mode and which declared keys are set. It never reports their values. A missing key is a `tool_config` finding. last30days's own `doctor` is the deeper check, run after apply.
- A secret held back by fleet-chezmoi's secret filter is not an error to route around. It is exactly the case this category exists for.

### 4.5 fleet-run owns its scheduler and its liveness

- **`roundhouse launcher-install` also installs the scheduler**:
  - a launchd agent on macOS
  - systemd user timers on Linux and WSL
  - a per-user scheduled task for a native Windows host with no WSL sibling
  - It is idempotent, and it absorbs any existing entry rather than adding a duplicate, as `fleet-update` already requires in prose.
  - `fleet-doctor` checks the job is loaded and its program path resolves.
- **Stale-lock recovery.** A lock whose holder PID is not alive, or is not a Roundhouse process, is taken over automatically, and the takeover is journaled. The "remove it" refusal survives only for a live holder.
- **Heartbeat and fleet liveness.** Every run journals a liveness record, as the canary already requires. `fleet-doctor` on every host alerts for any enrolled host whose last successful run is older than 2× its cadence. This restores the SYNC §8 requirement that V2's doctor table dropped. fleet-chezmoi's probe adds a `roundhouse-stale` finding for the same condition, so any sync session sees it.
- **Canary failover.** A canary silent for more than `canary_wait_hours × 2` raises a fleet alert. The next host in a declared `canaries:` list takes over. Waiting on a dead canary forever is the failure this prevents.

### 4.6 Native Windows through its WSL sibling

V2 §9.2 describes iris-windows as a second instance operated from iris-wsl. The 2026-08-10 scaling note superseded that with native membership, which needs jj, signing and a launcher on Windows. None of those exist. The interop lane (0.9.25) now gives native execution without any of them, so this proposal returns to the §9.2 shape:

- iris-windows gets a host file, `hosts/iris-windows.yaml`, and `os/windows.yaml`. It also gets its own key and principal (`iris-windows@<domain>`), held on the WSL side under `~/.config/roundhouse-iris-windows/`, as §9.2 describes.
- iris-wsl's scheduled `fleet-run` does a second pass for iris-windows. It resolves that host's fold and applies plugin, marketplace and skill items through the interop lane: native `claude` and `codex` commands, run in the logged-in session. It journals as iris-windows.
- **Logged off** means WSL is down, so no run happens. That is the existing SYNC §8 expectation, now visible through the liveness alert.
- The Codex remote-control lane remains the fallback when WSL is unreachable.

**Decision needed.** This reverses a recorded user decision (native membership, 2026-08-10). The recommendation is the WSL-operated instance, because it works with what exists today and adds no Windows-side trust roots. Native membership stays possible later without redoing this.

### 4.7 dotfiles and fleet-chezmoi step back from plugin state

- **dotfiles** drops `enabledPlugins` and `extraKnownMarketplaces` from `.chezmoitemplates/claude-code-settings.json`, and the matching sections of the retired list. The modify script keeps the other keys it owns.
- **fleet-chezmoi**:
  - removes those two keys from `.fleet-chezmoi.json` `managed_json`, so it can no longer promote a host's plugin into fleet state;
  - replaces its `plugins` step (`converge-plugins.sh`) with "run `roundhouse fleet-run --fast` on that host";
  - keeps reporting plugin drift from Roundhouse's own view, not from the union of whatever hosts happen to have.
- **One host-name map.** dotfiles roles (`claires-macbook-pro`, `claires-mini`, `primary-mac`, `iris-wsl`, `windows-side`) map to Roundhouse machine names in one table, owned by dotfiles and read by fleet-chezmoi. Two unrelated naming schemes invite exactly the mistakes seen here.

## 5. What this fixes

| Symptom | Fixed by |
|---|---|
| iris-windows plugins stale | §4.6: iris-wsl's run converges it; §4.5: liveness makes it visible |
| Fleet-wide convergence dead since 2026-09-22 | §4.5: scheduler owned and installed, stale lock recovered, liveness alerted |
| Peers stuck behind a dead canary | §4.5 failover; §4.2 identity self-repair |
| Plugins spreading from one host | §4.7: capture no longer owns plugin state; §2: adoption is explicit |
| Store still enabling retired plugins | §3: the store is the only declaration; §4.3: `absent` uninstalls |
| Impeccable per harness | §4.1 harness-qualified records and the Codex apply path |
| last30days unconfigured | §4.4 `tool_config` |
| Codex model flip-flop | §3: dotfiles owns preferences; Roundhouse stops declaring them |

## 6. Migration

Each phase ships alone and leaves the fleet better than it found it.

- **P0: stop the bleeding.** Data plus operations, no new code.
  1. Store edits, signed through the normal promote gate:
     - `superpowers`, `codex` and `music-control` become `absent` at the fleet layer;
     - impeccable and last30days get correct marketplaces;
     - the stale seeded mixed-harness entries are removed.
  2. Only after that, reload `fleet-run` on every POSIX host and clear the dead lock. Reloading first would converge the stale declarations.
  3. Remove the duplicate Codex `impeccable@impeccable` on iris-wsl and iris-windows.
  4. Render last30days `.env` on every host (the §4.4 file, done by hand once).
  5. Update iris-windows's Claude plugins once through the interop lane.
- **P1: ownership.** dotfiles and fleet-chezmoi step back (§4.7). Roundhouse keeps the `extraKnownMarketplaces` fallback for one release so nothing is left without a marketplace source.
- **P2: Roundhouse model.** Harness-qualified plugins, the Codex apply path, the `marketplaces` category, uninstall on `absent`, the identity-gate and relative-source fixes, and the proposals fixes (§4.1–4.3). This is one PR series with tests in the existing fixture style.
- **P3: liveness.** Scheduler install, stale-lock recovery, heartbeat alerts, canary failover, and the fleet-chezmoi finding (§4.5).
- **P4: Windows.** The iris-windows operated instance (§4.6).
- **P5: tool config.** The `tool_config` category, the collector presence check, and the dotfiles renderer (§4.4).

## 7. Non-goals

- No change to trust, signing, the reconcile point, or the sealed-plan pipeline.
- No syncing of whole harness state directories, `[hooks.state]`, auth files or MCP secrets. V2 and `agent-settings-and-auth.md` already forbid this.
- No automatic promotion of host-local changes. Adoption stays an explicit, reviewed step.
- No replacement for harness `autoUpdate`. It stays as a freshness accelerator that the next run reconciles.

## 8. Open decisions

1. **Windows shape** (§4.6): the WSL-operated instance (recommended) or native membership.
2. **Canary list** (§4.5): which hosts may take over as canary, and in what order.
3. **Codex preference owner** (§3): confirm dotfiles owns `model`/`model_reasoning_effort`. If Astra should be the default, change it there, once.
4. **Where secrets live** (§4.4): stay with the existing `.chezmoidata.toml` pattern, or move tool secrets to 1Password references rendered at apply time.
