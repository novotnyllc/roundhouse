# Fleet Sync — Design

Status: draft for review · 2026-08-05
Owner: roundhouse (skills + store), with setup/doctor touchpoints in railyard

## Purpose

Keep the user-scope agent surface — plugins (with enabled/disabled state),
standalone skills, agents, hooks, MCP servers, and harness config files —
consistent across every machine and harness in the fleet, updated from their
upstream sources, with per-host history, rollback, and agent-ascertained
conflict resolution. **Opt-in**: never enabled by default; setup mentions it
once, docs cover it, and observed staleness/drift may hint at it later.
Enabling is always an explicit choice.

## Non-goals

- No dependency on any personal dotfiles tool. Other sync engines the user
  runs are treated as *upstreams* (below), never as infrastructure this
  system requires.
- No new package/skill installer, no daemon, no database. Third-party skill
  managers are never named in skill text; they are detected generically and
  their own mechanisms are used.
- Project-scope anything is out of scope; user scope only.
- No mechanical merge policy. Timestamps are evidence, not a decision rule.

## The store

`~/.config/roundhouse/` on every host is a **jj repository colocated with
git**: jj is the operating tool, git is the storage and wire format.

Why jj: conflicts are recorded as data in real commits instead of wedging the
working copy — an unattended run on a headless machine can merge, journal a
conflict, and continue; the conflicted commit replicates like any other, so
*any* host (or the user saying "go fix it" anywhere) can produce the
resolution, and descendants rebase automatically. The operation log makes
each sync run individually undoable. Escape hatch: the data is a plain git
repo at all times; bare git can read and recover everything.

Auto-snapshot guardrails: the scaffold sets `snapshot.max-new-file-size` (a
few MiB — deliberately above the default because pruned session logs are
carried), ships a curated `.gitignore` (caches, sockets, temp patterns), and
the run has a pre-push size guard that journals + alerts on unexpected large
additions instead of replicating them. Accidental tracking is reversed with
`jj file untrack` + abandon before push.

### Branches

- **`main`** — fleet truth: machine registry, groups, desired manifests,
  canonical config files and their group variants, upstream freshness
  records, update leases. File-per-item layout (one small file per plugin
  entry, group, config variant, machine) so concurrent edits rarely collide.
- **`host/<name>`** — single-writer (only that host commits): the host's
  materialized configs as they actually are, full inventory snapshot
  (plugins+state, skills, agents, hooks, MCP), manager lockfiles (as
  provenance evidence and restore fidelity — machine-specific, so they live
  here, never on main), the sync journal (each run: what, why, evidence),
  and rotated session logs (below). This is the redundancy layer: every
  host's complete agent surface, versioned, replicated everywhere — any
  surviving machine can restore any other.
- Conflicted merges live as jj conflict commits; the journal and alert point
  at them. No `conflict/*` branch machinery is needed — jj's model carries
  it.

### Transport

The store's remote is chosen at setup, with prompting:

1. **Private hosted repo (suggested)** — GitHub/GitLab/other; simplest,
   works off-tailnet, encrypted in transit.
2. **Bare relay on an always-on fleet host** over tailnet SSH.
3. **Peer-to-peer fallback** — always available: fetch directly from any
   reachable peer; used automatically when the primary remote is down.

Tailscale is recommended (setup suggests it; the registry prefers tailnet
addresses) but never required.

## Machine registry and groups

Registry entry per machine (file-per-machine on main): full hostname, SSH
alias, tailnet name (preferred when present), OS (`mac`/`linux`/`windows`;
WSL registers as `linux` with `wsl: true` — counts as Linux unless something
specifically cares), installed harnesses, per-upstream capability (which
managers/auth this host has), custom group names.

Groups:

- **Implicit, derived**: `all`, each OS, each harness (`claude`, `codex`,
  future ones). "Update all the Macs" works with zero configuration.
- **Custom, declared**: free names; a group may be defined as a union of
  other groups (hierarchy). Overlap is expected; a machine lists many.
- **Scopes** target desired entries: a group, `group+harness` (`mac+claude`),
  or a single machine. Effective desired set = union of matching scopes;
  install-wins across overlaps; only a single-machine scope can exclude
  (precedence stays trivial: machine > everything else).
- **Discovery**: a "what's where" tool renders the fleet × surface matrix
  with deltas — both the audit view and the way groups get discovered and
  named in the first place.

## Surface and provenance

Synced (user scope): plugins with enabled/disabled state, standalone skills,
agents, hooks, MCP servers (full definitions, no secrets — required env vars
checked for presence only), and harness config files
(`~/.claude/settings.json`, `~/.codex/config.toml`, agent definition files),
with group/per-machine variants supported.

Every item carries a provenance record: which upstream owns it. Upstreams
are uniform and generically detected:

- **Harness marketplaces** (Claude/Codex plugin managers).
- **Skill managers detected by heuristic** — a lockfile/marker (e.g., a
  `.skill-lock.json`-style file) reveals the manager, its source URLs, and
  hashes; provenance is imported from it. Never named in skill text.
- **Other sync engines** (e.g., a personal dotfiles manager) — detected as a
  co-owner of a config file; treated bidirectionally: their change is
  accepted and propagated; our change is written back through them so it
  does not revert. Setup/doctor surface the co-ownership and ask once.
- **Local-source** — items whose truth is a local repo; updated only from
  that repo.

## The scheduled run

OS scheduler (launchd / systemd user timer / scheduled task; installed by
setup on opt-in) calls the harness with a fixed prompt. Default twice daily,
jittered per host; configurable; plus on-demand ("sync now"). Three phases:

### 1. Update — once per fleet, not per machine

Freshness per upstream is recorded on main. A host at its scheduled run:
fresh within cadence → skip, converge from the store. Stale and this host is
*capable* (has the manager/auth) → take an opportunistic short-TTL lease (a
marker committed to main; a push race settles ownership; a double-update is
idempotent waste, not corruption), run the upstream's own update mechanism,
commit results + freshness. Leaderless: the first capable awake machine does
each upstream. Distribution splits by surface type:

- **File-carried** (skills, agents, hooks, configs): updated content is
  committed to the store; every other host materializes from replication —
  no upstream contact, no auth needed.
- **Manager-installed** (plugins): the store carries the version pin; each
  host installs that pin from the marketplace locally.

Harness-native auto-update is used where it exists (Claude marketplaces);
what Codex does on its own is an **open research item** for the plan.

### 2. Update safety review

Before applying an update, the agent diffs current vs. incoming for readable
surfaces (skills, agents, hooks are text). Changes — including breaking
changes — are expected and fine. The review screens specifically for
destructive or suspicious turns: new deletion behavior, credential/secret
access, exfiltration shapes, hook payload changes. A flagged item is held
un-applied and alerted; never silently applied, never silently forgotten
(doctor tracks held items).

### 3. Sync

Converge this host to its effective desired set via manager-native commands
(install/remove/enable/disable; `claude mcp add|remove`; materialize config
files). Removals propagate by default: absent from desired ⇒ removed, with
every removal reported by name. Commit the host snapshot to `host/<name>`;
propose outward changes (a local install/removal/config edit judged
deliberate) toward main. Session logs for the window are rotated onto the
host branch (size-capped, 14-day retention by default, prunable later).

## Intent resolution

When states disagree (a conflict commit, or divergence between hosts),
evidence is weighed in order — timestamps inform but never decide:

1. **Store history** — who changed what, when, on which host, in which run.
2. **Provenance** — an upstream-driven change is not a human decision; a
   manual change is.
3. **Session-transcript mining** — grep the last ~48h of agent sessions
   (Claude and Codex session files; extensible to other harnesses) across
   all hosts for mentions of the contested item. "Get rid of X" in
   yesterday's conversation usually settles intent. Findings stay local and
   are quoted minimally in the journal.

Confident → apply fleet-wide, journal the reasoning. Ambiguous → **hold the
divergence, alert, and wait**; never resolve destructively on a guess. The
alert names the item, the competing states, and the evidence found.

## Rollback

- **Restore host X to <date>**: check out `host/X` at the date, materialize
  configs, replay the inventory snapshot through the managers. Read-first:
  show the full delta before touching anything.
- **Undo a specific run**: each run is journaled and, via the jj operation
  log, individually revertable without disturbing later unrelated changes.

## Setup and doctor

Setup (railyard): mentions the feature once with a one-paragraph pitch;
on opt-in — installs jj (single binary via the OS package manager), scaffolds
the store (repo, ignore file, snapshot limits), prompts for the transport
remote (private hosted repo suggested; tailnet relay; peer-only), suggests
Tailscale where absent, bootstraps registry + desired manifests from the
current host, installs the scheduler entry, and imports provenance from any
detected managers/lockfiles. Detected co-owning sync engines and manager
auto-updaters are surfaced with an ask — respected by default, never fought.

Doctor: store reachable/replicating; no conflict commit older than 24 hours;
no upstream stale beyond 2× cadence; no held flagged update forgotten;
scheduler alive with a healthy log; co-ownership sanity (bidirectional
write-back configured where a second engine owns a file).

## Security and privacy

- The store carries no secrets: MCP definitions reference env vars checked
  for presence only; auth material never leaves its host.
- Session logs are sensitive; the store must be a private repo, and the
  transport prompt says so explicitly.
- The update safety review is the supply-chain gate for file-carried
  surfaces; version pins plus marketplace shas cover plugins.
- Alerts use the host's native user notification plus a pending item the
  doctor and any interactive session surface.

## Open research items (for the implementation plan)

1. Codex marketplace/plugin auto-update behavior — what runs on its own vs.
   needs driving.
2. Exact session-file locations/formats per harness for transcript mining
   (Claude `~/.claude/projects/*/*.jsonl`; Codex sessions; others later).
3. jj packaging on every fleet OS (brew/winget/apt/cargo) and its Windows
   maturity for the store operations used here.
4. `claude plugin enable|disable` / Codex equivalents — exact commands for
   state alignment.
5. Migration for detected manager auto-updaters (respect vs. absorb) — the
   generic flow, validated against the managers actually present.
