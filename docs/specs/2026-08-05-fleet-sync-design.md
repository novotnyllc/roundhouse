# Fleet Sync — Design

Status: draft v2 (post-adversarial-review) · 2026-08-05, revised 2026-08-06
Owner: roundhouse (skills + store), with setup/doctor touchpoints in railyard

## Purpose

Keep the user-scope agent surface — plugins (with enabled/disabled state),
standalone skills, agents, hooks, MCP servers, and harness config keys —
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
- Session logs and transcripts are **not** stored here (see Sensitive data).

## Threat model up front

The store is a **trusted-write surface on every fleet machine**: hooks and
skills it carries execute as the user on all hosts. Consequences the design
must carry, not footnote:

- **Apply-time review on every host** (below) — content is screened where
  it lands, not only where it was fetched.
- **Per-host store credentials are crown-jewel secrets**: provisioned at
  enrollment, revoked in the fleet-hosts removal flow, minimal scope
  (single private repo), never reused for anything else.
- Commits to `main` are signed by enrolled host keys (the fleet SSH CA
  already exists; jj/git signing rides on it), and hosts verify signatures
  before applying. The single-writer host-branch rule is enforced by
  verification, not convention.

## The store

`~/.config/roundhouse/store/` on every host is a **jj repository colocated
with git**: jj is the operating tool, git is the storage and wire format.
(Windows: `%USERPROFILE%\.config\roundhouse\store\` — the same relative
convention as the bash-side `${XDG_CONFIG_HOME:-$HOME/.config}`; the
existing AppData paths in config examples are per-artifact overrides and
keep working.) The store is a subdirectory precisely because the config
root is **not empty**: `config.json` and `identity.json` are live,
host-local files.

- **Registry authority**: the store's file-per-machine registry on `main`
  is authoritative once a host enrolls; `config.json`'s `machines` block is
  absorbed into it at enrollment, after which `config.json` is generated
  per-host from the store (host-local values like `transport: "local"`
  rendered for that host). `identity.json` and other host-identity files
  never enter the store.
- Why jj: conflicts are recorded as data in real commits instead of wedging
  the working copy; the operation log makes each sync run individually
  undoable; the data stays a plain git repo readable by bare git.
- **jj-immaturity fallback (Windows)**: a host where jj is not yet solid
  operates git-only against the same repo — full replication and
  materialization, conflict handling degraded to hold-and-alert. jj is
  preferred, never load-bearing for safety.
- Auto-snapshot guardrails: `snapshot.max-new-file-size` stays small and is
  a **tripwire for accidents only** — nothing in the normal pipeline may
  rely on large files; a curated `.gitignore` (caches, sockets, temp
  patterns, identity files); a pre-push size guard that journals + alerts
  on unexpected additions instead of replicating them.

### Branches

- **`main`** — fleet truth: machine registry, groups, desired manifests,
  canonical config *keys* and their group variants, upstream freshness
  records, update leases, alert/pending records, canary journals.
  File-per-item layout so concurrent edits rarely collide.
- **`host/<name>`** — single-writer (enforced by commit signatures): the
  host's materialized config state, full inventory snapshot (plugins+state,
  skills, agents, hooks, MCP), manager lockfiles (provenance evidence and
  restore fidelity), and the sync journal (each run: what, why, evidence).
  This is the redundancy layer: every host's agent surface, versioned,
  replicated — any surviving machine can drive another's restore.
- Conflicted merges live as jj conflict commits; the journal and alert
  point at them. **Convergence never materializes a conflicted item**: each
  item converges from its last conflict-free state; conflicted paths are
  held item-level (the rest of the run proceeds) and alerted.

### Transport

The store's remote is chosen at setup, with prompting:

1. **Private hosted repo (suggested)** — created *by the setup flow* (or
   verified if pre-existing), with an explicit privacy check (API-verified
   visibility, not assumed) before the first push.
2. **Bare relay on an always-on fleet host** over tailnet SSH.
3. **Peer-to-peer fallback** — always available: fetch directly from any
   reachable peer; used automatically when the primary remote is down.

Tailscale is recommended (setup suggests it; the registry prefers tailnet
addresses) but never required. Per-host credentials follow the threat-model
rules above.

## Machine registry and groups

Registry entry per machine (file-per-machine on main): full hostname, SSH
alias, tailnet name (preferred when present), OS (`mac`/`linux`/`windows`;
WSL registers as `linux` with `wsl: true`), installed harnesses,
per-upstream capability, custom group names, and hardware pairing:
entries on shared hardware carry the same `physical_host`, and a Windows
entry with a WSL sibling sets `wsl_interop_via` so maintenance runs
Windows-native CLIs from the WSL side (`cd /mnt/c` + full-path
`cmd.exe /c` — native processes, native evidence).

Groups:

- **Implicit, derived**: `all`, each OS, each harness. "Update all the
  Macs" works with zero configuration.
- **Custom, declared**: free names; a group may be a union of groups.
  Overlap is expected.
- **Scopes** target desired entries: a group, `group+harness`, or a single
  machine. Effective desired set = union of matching scopes; install-wins
  across overlaps for *presence*; **machine > group for both presence
  exclusions and state** — enabled in a group but disabled on one machine
  is expressible and the machine wins. Only a single-machine scope can
  exclude presence.
- **Discovery**: a "what's where" tool renders the fleet × surface matrix
  with deltas — the audit view and how groups get discovered and named.

## Surface and provenance

Synced (user scope): plugins, standalone skills, agents, hooks, and MCP
servers (full definitions, no secrets — required env vars checked for
presence only), plus harness config **at key level**: the store carries an
allowlisted key set per config file (the shape `agent_artifacts` already
uses), with group/per-machine variants. Whole files are never canonical:
host-local namespaces (trust tables, survey state, session-scoped values,
anything secret-bearing in `~/.codex/config.toml`) are excluded by
allowlist, which also prevents the sync writer and the manager CLIs from
fighting over one file.

**Enabled/disabled state is a first-class synced property of every item
type that carries it** — plugins, standalone skills, individual hooks
(enablement syncs; trust hashes stay host-local), and MCP servers.
Disabling a skill on one machine is a desired-state change like removing
it: it propagates per its scope, appears in the delta report by name, and
follows the intent-resolution evidence rules.

**Hook trust reconciliation** (the enablement/trust split, resolved): when
a store-delivered change alters a hook's content on a host, that host's
apply-time review screens the diff; passing review *is* the approval
evidence, and the host then runs its local hook-approval helper to
re-trust the new hash. A held (flagged) hook change is left **untrusted
and disabled** with an alert — never enabled-but-dead, never auto-trusted
around the review. Doctor checks for enabled-but-untrusted hooks.

Every item carries a provenance record: which upstream owns it. Upstreams
are uniform and generically detected:

- **Harness marketplaces** (Claude/Codex plugin managers).
- **Skill managers detected by heuristic** — a lockfile/marker reveals the
  manager, source URLs, hashes; provenance imported from it. Never named
  in skill text.
- **Other sync engines** (e.g., a personal dotfiles manager) — detected as
  a co-owner of a config file. Stance matches shipped doctrine: co-owned
  keys are **detected and surfaced, and the user chooses** which system
  owns each; automatic write-back through the other engine is not promised
  (the shipped dotfiles skill deliberately does not support source-side
  adds). A co-owned key the user assigns to the other engine is excluded
  from our allowlist; one assigned to sync is removed from the other
  engine by the user, with doctor watching for re-emerging co-ownership.
- **Local-source** — items whose truth is a local repo; updated only from
  that repo.

Desired **package** state (OS packages) also lives in the registry's
manifests as data, but authority to apply privileged package work belongs
exclusively to the privilege broker per the sibling spec
(2026-08-06-unattended-privileged-updates.md): sync proposes and records,
the broker's ceremonies govern what may touch root, and doctor reports
bindings orphaned by desired-state removals as stale authority.

## The scheduled run

**One scheduler entry per host, owned by this system.** Setup absorbs the
existing fleet-update autoupdate entry (migrating/removing its plist or
timer) so exactly one scheduled agent drives marketplace refresh, package
updates, and sync — no two local runners racing one plugin cache. A local
run-lock enforces one-runner-at-a-time; the scheduled prompt is fixed text
maintained with fleet-update's (they change in lockstep). Default twice
daily, jittered per host; configurable; plus on-demand ("sync now").

On iris-windows the entry runs **interactive-session-only**: logged-off
Windows is *expected* staleness, not failure — shipped doctrine already
establishes that logged-off S4U runs cannot produce activation evidence,
and logoff kills the WSL sibling too. Doctor carries a per-host
"last successful sync within 2× cadence" check so expected staleness is
visible and named, never silent.

Three phases:

### 1. Update — once per fleet, not per machine

Freshness per upstream is recorded on main. A host at its scheduled run:
fresh within cadence → skip, converge from the store. Stale and this host
is *capable* → take an opportunistic short-TTL lease (a marker committed
to main; a push race settles ownership; a double-update is idempotent
waste, not corruption), run the upstream's own update mechanism, commit
results + freshness. Leaderless: the first capable awake machine does each
upstream. Distribution splits by surface type:

- **File-carried** (skills, agents, hooks, config keys): updated content
  is committed to the store; every other host materializes from
  replication — no upstream contact, no auth needed.
- **Manager-installed** (plugins): the store carries the version pin; each
  host installs that pin from the marketplace locally.

**Self-update ordering**: the roundhouse plugin itself updates *last*, on
the updating host only; its new pin propagates to the rest of the fleet
only after that host's next scheduled run journals healthy — a bad release
of the sync machinery reaches one host, not five.

### 2. Apply-time safety review — on every host, every source

Before *materializing or installing* any changed item — whether the change
arrived from an upstream this host fetched or from store replication — the
applying host diffs current vs. incoming for readable surfaces (skills,
agents, hooks, config keys are text). Changes, including breaking changes,
are expected and fine. The review screens for destructive or suspicious
turns: new deletion behavior, credential/secret access, exfiltration
shapes, hook payload changes. A flagged item is held un-applied (and for
hooks, disabled+untrusted) and alerted; never silently applied, never
silently forgotten (doctor tracks held items). This is the supply-chain
gate, and it sits at the only edge that covers store compromise: apply
time, on the host where the content will run.

### 3. Sync

Converge this host to its effective desired set via manager-native
commands and allowlisted key materialization. Removals propagate by
default per scope rules: absent from desired ⇒ removed, every removal
reported by name. Commit the host snapshot to `host/<name>`; propose
outward changes (a local install/removal/config edit judged deliberate)
toward main — **at the narrowest scope**: a single-machine add or exclude.
Widening a proposal to a group is a separate intent-resolution outcome
requiring cross-host evidence, never the default. A phase-0 capability
check per item type confirms the state-alignment commands this host's
harnesses actually support (open item), falling back to allowlisted config
edits where commands don't exist.

## Sensitive data: session logs stay out

Session transcripts are the most sensitive data on these machines and do
not enter the store — not for redundancy, not for mining convenience.
Consequences:

- **Transcript mining runs locally on each host.** Each host contributes
  only **redacted findings** (item, verdict, minimal quoted evidence —
  bounded length, no secrets) as records on main. Resolution can then
  happen on any host from findings alone, and "findings stay local until
  redacted" is actually true.
- A long-offline host's evidence window is acknowledged: divergences that
  outlived the mining window default to **hold**, not confident
  resolution.
- If log redundancy is ever wanted, it is a separate opt-in system with
  its own encryption and retention story — explicitly out of scope here.

## Intent resolution

When states disagree (a conflict commit, or divergence between hosts),
evidence is weighed in order — timestamps inform but never decide:

1. **Store history** — who changed what, when, on which host, in which
   run.
2. **Provenance** — an upstream-driven change is not a human decision; a
   manual change is.
3. **Redacted transcript findings** contributed by each host's local
   mining (last ~48h; extensible), gathered on main.

Confident → apply at the evidenced scope (fleet-wide only when the
evidence is fleet-wide), journal the reasoning. Ambiguous → **hold the
divergence, alert, and wait**; never resolve destructively on a guess. The
alert names the item, the competing states, and the evidence found.

## Rollback and restore

- **Undo a specific run**: each run is journaled and, via the jj operation
  log, individually revertable without disturbing later unrelated changes.
- **Restore host X** is *configs plus a shopping list*, sequenced — and
  honestly scoped: the store cannot restore secrets, per-machine auth, or
  SSH identity. Order: fleet-hosts enrollment (SSH ceremony) → store
  credentials → materialize file-carried surfaces from `host/X` →
  replay manager installs from the inventory snapshot → per-artifact
  reauth from the auth shopping list. Read-first: show the full delta
  before touching anything.

## Alerting

An alert is three things at once: a record on `main` (replicated,
durable), a line in the host journal, and a native user notification where
a user is present to see one. **Any interactive session on any host
surfaces fleet-wide pending items** — held updates, conflicts, stale
hosts — not just its own. Doctor is the scheduled backstop; pending items
older than a threshold escalate in its report.

## Setup and doctor

Setup (railyard): mentions the feature once with a one-paragraph pitch; on
opt-in — installs jj (or flags the host git-only), scaffolds the store
under the config root's `store/` subdirectory, creates or verifies the
private remote (explicit privacy check) and provisions this host's
credential, absorbs `config.json`'s registry into main, migrates the
fleet-update autoupdate entry into the single owned scheduler entry,
bootstraps desired manifests from the current host, imports provenance
from detected managers/lockfiles, and runs the co-ownership ask for any
detected second sync engine. Host removal (fleet-hosts) revokes the store
credential alongside SSH trust.

Doctor: store reachable/replicating; commit signatures verifying; no
conflict commit older than 24 hours; no upstream stale beyond 2× cadence;
**no host's last successful sync older than 2× its cadence** (expected
staleness on iris-windows is reported as such, by name); no held flagged
update forgotten; no enabled-but-untrusted hook; scheduler entry singular
and alive; co-ownership sanity; store size within budget; stale broker
bindings (sibling spec seam) reported.

## Security and privacy

- The store carries no secrets: MCP definitions reference env vars checked
  for presence only; config sync is allowlisted keys, excluding
  secret-bearing namespaces; auth material never leaves its host; session
  transcripts never enter the store.
- The store is a trusted-write surface: private repo verified at setup,
  per-host minimal credentials with enrollment/revocation lifecycle,
  signed commits verified before apply, and the apply-time review on every
  host as the content gate.
- Version pins plus marketplace shas cover plugins; the apply-time review
  covers file-carried surfaces; the privilege broker (sibling spec) covers
  everything that touches root.

## Open research items (for the implementation plan)

1. Codex marketplace/plugin auto-update behavior — what runs on its own
   vs. needs driving.
2. Exact per-type state-alignment commands per harness (plugin
   enable/disable, skill enable/disable, per-hook enablement, MCP server
   state) and which exist only as config edits — the phase-0 capability
   check's ground truth.
3. jj packaging and maturity per fleet OS; criteria for flipping a
   git-only host to jj.
4. Commit-signing mechanics over the fleet SSH CA (jj/git signing config
   per host, verification tooling in the run).
5. Allowlist contents per config file: the synced key set, the excluded
   host-local namespaces, and where the allowlist itself lives (it is
   itself synced, file-carried, and reviewed).
6. Redaction rules for transcript findings (bounded quote length, secret
   patterns, what the finding record schema is).
7. Store size budget and the compaction story if history ever needs
   rewriting (fleet-coordinated, explicitly an incident-class operation).
8. Scheduler parameters: cadence, jitter, run-lock implementation, canary
   journal schema shared with the sibling spec.
