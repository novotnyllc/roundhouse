# Desired-State Store — Storage and Configuration Model (v2)

Status: **SUPERSEDED** · 2026-08-06 — replaced in full by
`2026-08-06-dsc-storage-design-v2.md` after owner review rejected this
draft's storage core (YAML-authoring/canonical-JSON split, absorb/render
pipeline, schema versions). The replacement was produced by a four-design
competition with scored judging and a seven-round adversarial review
(`2026-08-06-dsc-storage-design-v2-review.md`). Kept for the feature
inventory and the record.

Original status line: draft for review · 2026-08-07
Supersedes the storage sections of `2026-08-05-fleet-sync-design.md`; the
threat model, three-phase run, intent resolution, and alerting sections of that
spec stand unchanged.

## Purpose

The store shipped and is live on one host. Browsing it surfaced four structural
problems that get expensive once a second and third host enroll: a singleton
`meta/host.json` that implies a primary machine, a `registry/config-base.json`
built by denylist from whichever host ran absorb, a `transport: "local"` field
whose meaning depends on who is reading it, and a lease primitive that guards
against a failure the spec itself calls harmless. Two further dependencies were borrowed rather than owned: fleet transport
rides the operator's personal `~/.ssh/config` aliases, and the harness-config
surfaces have no stated owner independent of chezmoi. And the desired catalog
has no seeding story, which matters now that a real inventory shows machines
differing by 83 standalone skills on purpose.

This document settles the storage and configuration model: identity, layout,
formats, schema evolution, the config↔store direction, offline behaviour, host
symmetry, ownership of every file we depend on, and catalog seeding.

The store can be recreated freely. Nothing here is constrained by migration.

---

## Research findings

Patterns extracted from established desired-state systems. One paragraph each;
sources are the projects' own docs unless noted.

**Ansible** ([inventory guide], [variable precedence], [sample layout]) —
`inventory_hostname` is the identity key and is deliberately decoupled from
`ansible_host`, the connection address: renaming the box's DNS entry is an
`ansible_host` edit, not an identity change. Layering is a 22-level precedence
list, last-wins per key, no deep merge by default. Layout is scope-first at the
top (`inventory/production`, `inventory/staging`) then type-first inside
(`group_vars/`, `host_vars/`, `roles/`). Growth is unscaffolded: a new group is
one new file. Everything is hand-authored YAML; nothing is generated and there
is no per-file schema version — compatibility rides the ansible-core version.
**Take:** identity separate from address; groups as files, not as registry.

**GitOps (Flux, Argo CD)** ([Flux repository structure], [Argo best
practices]) — path *is* identity, with no rename lineage: a renamed directory
is a delete plus a create. Layering is Kustomize `base/` + `overlays/<env>/`
with ordered patches — override semantics, not variable precedence. Layout is
environment-first for cluster state, type-first for apps; a new environment is
a new overlay, never a pre-created directory. Versioning is per-object
`apiVersion`, never per-repo, and both ecosystems insist on a **separate config
repo** from application source. **Take:** overlays over duplication;
per-record versioning, not per-repo.

**Nix / home-manager** — the flake attribute name
(`nixosConfigurations.<host>`) is the identity; renaming is a manual breaking
edit with no tracked lineage. Layering is module composition with deep merge
and explicit `mkForce`/`mkDefault` priorities rather than an ordered list;
layout is type-first (`hosts/<name>/` composed from `modules/<feature>/`). The
human/machine split is by file: `.nix` authored, `flake.lock` generated.
`stateVersion` is not a schema version — it pins *default behaviour* at first
install and is deliberately never bumped. **Take:** the human/machine split
belongs at file granularity, and a "version" field can legitimately mean
compatibility rather than shape.

**Terraform** ([workspaces], [refactoring/moved]) — the resource *address* is
identity and is symbolic, not filename-derived, so `.tf` files can be
reorganised freely without touching state. The rename story is the most
explicit of the seven: a `moved { from = ..., to = ... }` block renames the
state entry in place instead of destroy-and-recreate, and moved blocks are
**retained permanently** — deleting one is a breaking change for anyone still
on the old address. HashiCorp explicitly discourages workspaces for environment
separation in favour of directory-per-environment when blast radius or
credentials differ. State carries two orthogonal counters: `version` (format
shape) and `serial` (monotonic, for optimistic concurrency). **Take:** rename
records must outlive the rename, and shape-version is not the same axis as
write-ordering.

**PowerShell DSC** ([DSC v3 config document], [DSC v1.1 configurations]) —
classic DSC compiles a hand-authored `.ps1` `Configuration` into one
machine-generated `<NodeName>.mof` per node: filename-as-identity for the
artifact, with `ConfigurationID` as a separate opaque pull-mode identifier for
when node name is not reliable. DSC v3 drops MOF for JSON/YAML documents with a
mandatory `$schema` pointing at a semver-pinned URI. **Take:** the compiled
artifact is not the source; Microsoft's own v3 move was toward *declared*
schema versioning.

**chezmoi** ([source state attributes], [templating], [externals]) — filename
*is* identity, heavily encoded: `private_dot_ssh/private_config.tmpl` decodes
to `~/.ssh/config`. Per-machine variation lives inside templates keyed on
`.chezmoi.hostname` rather than per-host directories — one source tree serves
all machines — and `.chezmoiexternal` keeps third-party content out of source
state. Entirely human-authored; no schema version. **Take:** filename-encoded
metadata is legible but costs you the rename story; per-host directories beat
per-host template branches once hosts differ structurally, not cosmetically.

**Puppet (Hiera + certname)** — the strongest analog to our identity question.
Puppet node identity is the **certname**, the CN in the node's TLS client
certificate, explicitly independent of the live `$::hostname`/`$::fqdn` facts:
renaming a machine's hostname does not break its Puppet identity, and
deliberately changing certname requires reissuing the certificate. Hiera is an
ordered fallback hierarchy declared in one file — `nodes/%{trusted.certname}` →
`role/%{facts.role}` → `common` — with explicit merge strategies when union is
wanted instead of override. Layout is scope-first, matching the hierarchy
order. Adding a tier is one line in `hiera.yaml`; missing files are skipped.
The compiled catalog is the machine-generated artifact and is never committed.
**Take:** we already have the certificate (the fleet SSH CA). Puppet's answer
is to use it as identity and let the name stay a name.

**Cross-cutting.** Every system with a compile step segregates generated from
authored by file or directory, never interleaved: `.tf`/`.tfstate`,
`.ps1`/`.mof`, `.nix`/`flake.lock`, manifests/catalog. Two versioning
conventions recur: per-object semver (`apiVersion`, `$schema`) with mandatory
reader tolerance of unknown fields, additive-only change within a version, and
fixed deprecation windows (Kubernetes: GA fields survive a major version, beta
≥3 minor releases); and opaque monotonic counters for write-ordering, kept
deliberately orthogonal to shape-versioning.

[inventory guide]: https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html
[variable precedence]: https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_variables.html
[sample layout]: https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html
[Flux repository structure]: https://fluxcd.io/flux/guides/repository-structure/
[Argo best practices]: https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
[workspaces]: https://developer.hashicorp.com/terraform/language/state/workspaces
[refactoring/moved]: https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
[DSC v3 config document]: https://learn.microsoft.com/en-us/powershell/dsc/reference/schemas/config/document?view=dsc-3.0
[DSC v1.1 configurations]: https://learn.microsoft.com/en-us/powershell/dsc/configurations/configurations?view=dsc-1.1
[source state attributes]: https://www.chezmoi.io/reference/source-state-attributes/
[templating]: https://www.chezmoi.io/user-guide/templating/
[externals]: https://www.chezmoi.io/user-guide/include-files-from-elsewhere/

Puppet and Nix findings were search-triangulated (puppet.com and nix.dev pages
redirected or 404'd on direct fetch); the other five are from the linked pages.

---

## Design principles

**P1 — No primaries, symmetric hosts, nothing singular.** Every host is
identical in role. No path inside the replicated tree may have a meaning that
depends on which machine is reading it, and **no part of the model may assume
exactly one of any role.** Corollaries, all enforceable:

- **P1a** Host-local operational state lives *outside the repo tree entirely* —
  never gitignored-but-present inside it. Two siblings, both already
  established by `<store>.run/`: `<store>.run/` for ephemeral per-run state
  (lock, run state, verdicts) and `<store>.local/` for durable host posture
  (store mode, signing configuration, remote-visibility verification).
- **P1b** Anything in the tree is either fleet-uniform (`README.md`,
  `.gitignore`, the fingerprint marker) or **explicitly host-keyed** — a
  `registry/machines/<name>.json` path, a `findings/<host>/` directory, a
  `host/<name>` branch. There is no third category.
- **P1c** No singular noun at the tree root. `meta/host.json` reads as *the*
  host to anyone opening the repository. `registry/machines/<name>.json` reads
  as one of many, which is the truth.
- **P1d** No stored value may be relative to the writer. `transport: "local"`,
  `~`-relative paths, and "the primary remote" are all writer-relative and
  belong to render time, not to the tree.
- **P1e** **Every role is a set.** Not "the machine on this hardware" but the
  machines sharing a `physical_host`; not "the WSL sibling" but the records a
  Windows entry's `wsl_interop_via` points at; not "the canary host" but the
  canary group. `physical_host` already proves the multiplicity is real —
  iris-windows and its WSL sibling are two records on one box — so a 1:1
  assumption is wrong today, not someday. Where a function genuinely needs one
  member of a set, that member is **explicitly designated** by a field on the
  record, never inferred from ordering, from `transport`, or from being first.
  The shipped `sync_host_name()` — which picks `[0]` of the machines whose
  transport reads `local` — is exactly the implicit-singular bug this forbids.

  **Functions that currently need a designated one: none.** Phase-1 upstream
  updates are first-capable-awake with a discard rule (D6); the canary target
  is a group; the store remote is host-local config, so a bare-relay host is
  just a machine that also serves a repo and needs no fleet-level designation.
  This is stated so the next function that thinks it needs a primary has to
  argue for it and add the explicit field, rather than quietly reintroducing
  `[0]`.

**P2 — The remote is a rendezvous, not an authority.** Every phase completes
with the remote unreachable, or defers explicitly and journals why. See
Offline-first operation.

**P3 — Human-authored is YAML and outside the store; the store is canonical
JSON and machine-managed.** No file is both.

---

## D1. Identity vs names

**Settled: Puppet's certname pattern. The filename is the display name; a
stable `id` inside the record is the reconciliation key; renames leave a
permanent record.**

- `registry/machines/<name>.json` — `<name>` is the human-chosen,
  human-readable name. It is the path key, the scope suffix
  (`desired/machine-<name>/`), the branch suffix (`host/<name>`), and what
  every diff and alert shows. No GUIDs anywhere a human reads.
- The record carries `id`: an opaque 16-hex token minted **once at enrollment**
  and written into both the machine record and host-local `identity.json`. It
  is not the node key fingerprint — key rotation is a real event this fleet
  already handles (KRL revocation exists), and an identity that changes on
  rotation is not an identity. The fingerprint lives alongside as
  `attested_by.node_key_fingerprint`, updated on rotation.
- **Rename procedure** (`roundhouse sync-rename-machine <old> <new>`), one
  atomic commit on `main` plus a branch rename: move
  `registry/machines/<old>.json` → `<new>.json`, move `desired/machine-<old>/`
  → `desired/machine-<new>/`, move `findings/<old>/` → `findings/<new>/`,
  rename branch `host/<old>` → `host/<new>`, and **append**
  `registry/renames/<epoch>-<old>.json`.
- **Rename records are retained permanently** — Terraform's rule, for
  Terraform's reason. A host that was offline across the rename fetches later
  holding local commits under `machine-<old>` and `host/<old>`. Readers resolve
  a missing name through `registry/renames/` by `id` before treating it as an
  orphan. Without the record, that host's offline work silently orphans.

**Rejected: names-as-sole-identity** (Ansible, Nix, chezmoi, GitOps). It works
for them because their offline window is a developer's afternoon and their
rename is a single-operator edit. Ours is a five-host fleet with hosts that are
legitimately offline for days and a Windows host that is *expected* to be
stale; a rename must survive that window. **Rejected: GUID filenames** —
explicitly, by the operator, and every browsable system surveyed agrees.

---

## D2. Layout

**Settled: type-first at the root, scope-first inside `desired/`, tier encoded
as a path prefix.** This is what shipped; it is right, and the change is one
safety rule, not a restructure.

`desired/<scope>/<item-type>/<id>.json` with scope ∈ `all`, `os-<platform>`,
`group-<name>`, `machine-<name>`, ascending precedence. This is Hiera's
hierarchy (`common` → `role/%{role}` → `nodes/%{certname}`) with the tier
encoded in the directory name instead of declared in a separate config file.

- **Why scope-first inside `desired/`:** effective-state resolution walks
  scopes in precedence order and unions. Scope-first makes that walk one
  `ls-tree` per tier. Type-first (`desired/plugins/<scope>/...`) would make it
  a walk per type × tier, and would scatter one machine's overrides across
  every type directory — unreadable at apply-time diff review, which is the
  security gate and therefore the read pattern that matters most.
- **Why not Ansible's `group_vars/` + `host_vars/` split:** two parallel trees
  for what is one ordered hierarchy, with the precedence rule living only in
  documentation. Hiera's single ordered tree is strictly better and is what a
  path prefix already gives us.
- **Why not numeric tier prefixes** (`00-all/`, `30-machine-<name>/`):
  inserting a tier renumbers every path.
- **Growth room, without speculative structure:** no `environments/`, no
  `roles/`, no empty directories. A new tier is a new prefix. The one rule that
  makes that safe: **an unrecognised scope prefix is held and alerted, never
  ignored.** A host that fetches `desired/env-staging/` and does not know the
  `env-` tier must not silently under-converge — it holds the run's affected
  items and alerts by name. Three lines of code; the trap it avoids is a silent
  wrong-state during a tier rollout across a fleet with a chronically stale
  Windows host.

Machine-generated per-host state stays on `host/<name>` branches
(`snapshot/`, `journal/`, `materialized/`) — the Terraform `.tf`/`.tfstate`
separation, expressed as a branch instead of a directory, which additionally
gets us the single-writer signature rule for free.

---

## D3. Formats

**Settled: YAML is human-authored and lives outside the store. The store is
canonical JSON, end to end, with exactly one prose exception.**

| File | Format | Authored by | In store |
|---|---|---|---|
| `~/.config/roundhouse/fleet.yaml` | YAML | human | never |
| `~/.config/roundhouse/config.json` | canonical JSON | rendered | never |
| `~/.config/roundhouse/identity.json` | JSON | enrollment | never (`.gitignore` tripwire) |
| `<store>.local/posture.json` | JSON | this host | never (outside tree) |
| `<store>.run/*` | JSON | this run | never (outside tree) |
| `store/**/*.json` | canonical JSON | machines | yes |
| `store/README.md` | Markdown | fleet-uniform prose | yes — the exception |
| `store/.gitignore`, `store/.roundhouse-sync-store` | text | fleet-uniform | yes |

- **Canonical JSON** means `jq -S` (sorted keys), LF endings, trailing newline,
  integers where integers will do. Every store write already routes through
  `jq -S` + `safe_output`; this makes it a rule rather than a habit. Digests are
  over file bytes, so key-order stability is what makes digest comparison
  meaningful across hosts and jq versions.
- **Why JSON in the store:** digest-stable hashing, and native parsing on both
  lanes (jq on POSIX, `ConvertFrom-Json` on the PowerShell lane) with no
  third-party YAML parser on the trusted-write path. A YAML parser inside the
  apply gate is new attack surface for zero benefit — nobody hand-edits the
  store, the README says so, and the signature gate enforces it.
- **Why YAML for authoring:** comments and multi-line strings matter where a
  human declares machines, groups, projects, and policy. JSON has neither.
- **Conversion and validation flow:** `fleet.yaml` → `yq -o=json` → the
  *existing* `validate_config_file` predicate → `sync-absorb-registry` (fleet
  subset, D5) and `sync-render-config` (host-local `config.json`). Validation
  happens once, on the JSON, so there is exactly one validator.
- **`yq` is a prerequisite on every host, same tier as `jq`** — installed by
  setup via the host's own manager (brew / apt / winget), verified by the
  phase-0 capability check alongside `jq`, and reported by doctor when missing.
  The design assumes its presence rather than branching on it. A
  conditionally-present converter would mean `fleet.yaml` is authorable on some
  hosts and not others, which makes the authoring surface itself host-relative
  — the same defect P1 forbids in the tree, one layer up. Two prerequisites
  installed uniformly are cheaper than one optional prerequisite plus every
  code path that has to ask whether it is there.

---

## D4. Schema evolution

Records carry `schema` (dotted name) and `schema_version` (integer). Rules:

1. **Additive-only within a version.** New fields are optional and have a
   defined default. Readers use the house `// default` idiom.
2. **Readers tolerate unknown fields.** Store-record validation checks a
   *required subset* — which `sync_validate_record` already does correctly.
   The exact-set pattern used elsewhere in this repo (`(keys | sort) == [...]`
   for `roundhouse.node-identity`, plan records, profile-bundle specs) is
   correct there — those are host-local trust artifacts where exactness is a
   security property — and must never be applied to a store record. Any store
   record validated by exact key set cannot receive an additive field without a
   fleet-wide lockstep upgrade.
3. **Bump only for a semantic change or a removal.** Renaming a field, changing
   its units, or dropping it. Adding one never bumps.
4. **A reader seeing `schema_version` greater than it knows holds the item and
   alerts.** It never ignores it and never applies it. Same rule as an
   unrecognised scope prefix, same reason.
5. **Readers ship before writers.** A version bump lands in a release that only
   *tolerates* N+1. The writer flips on in a later release, gated on doctor
   reporting that no enrolled host is below the tolerating version. Host
   snapshots carry `reader_schema_versions` so doctor can compute the fleet
   minimum. The trap: this fleet already updates one host first by design
   (self-update ordering); without the gate, the first-updated host writes v2
   and the other four hold every affected item until they update.

---

## D5. Config ↔ store

**Settled: the fleet-shared subset is authored in `fleet.yaml`, absorbed once,
and thereafter the store is authoritative. The host-local subset never enters
the store. The split is an allowlist.**

- **Fleet-shared → `registry/`:** machines (minus writer-relative fields),
  groups, projects, policy, capabilities.
- **Host-local → never stored:** `sync.store_path`, `sync.remote`,
  `sync.enabled`, `transport`, `skill_roots` and any other path that is only
  meaningful on one box, plus everything in `identity.json`.
- **`registry/config-base.json` is deleted, replaced by
  `registry/fleet.json`** carrying an explicitly allowlisted set of blocks. The
  shipped implementation builds it as `jq -S 'del(.machines)'` — a denylist,
  which is exactly how the host-local `sync` block (containing that host's
  `store_path` and `remote.url`) ended up replicated to the whole fleet. Every
  config key added in future would replicate by default. Allowlist, always.
- **`transport` is derived at render, never stored.** The rendering host is
  `local`; every other machine is `ssh` from its stored connection fields. This
  fixes a live correctness bug: `transport: "local"` is copied verbatim into
  `registry/machines/<name>.json` by absorb, `sync-render-config` only *sets*
  `local` for the rendering host without clearing it from others, so the
  absorbing host's record reads as local on every machine — and
  `sync_fetch_command` skips `transport == "local"` records as peer-fetch
  candidates while `sync_host_name()` picks `[0]` of the local-transport
  machines. Two hosts believe they are the same machine. (P1d.)
- **Absorb becomes upsert-only.** The shipped path does
  `rm -f registry/machines/*.json` and rebuilds from one host's config — the
  definition of a primary. Upsert the machines this host's `fleet.yaml` names;
  never delete a record it does not know about. Removal is
  `sync-remove-machine`, which is also where store-credential revocation
  already hangs.
- **set-remote / move story:** the remote is host-local by construction, so
  moving the store is `sync-set-remote <url>` on each host and *nothing in the
  tree changes*. That is the payoff for keeping the remote out of the tree; the
  shipped `remote_visibility_verified` flag moves to `<store>.local/posture.json`
  with it, since "have I verified this remote is private" is a statement about
  one host's check against one host's remote.

### We own every file we depend on

Two applications of one rule: **fleet infrastructure may not depend on a file
the operator maintains for personal reasons.** The `fleet-chezmoi` skill's own
doctrine — that a personal sync engine is an *upstream*, never infrastructure —
applies to us as hard as it applies to anyone else. It is easy to forget when
the borrowed file happens to be convenient.

- **Transport: roundhouse owns an SSH config fragment.** The shipped peer lane
  builds `peer_url="$peer_alias:$peer_store"` from the registry's `ssh_alias`,
  which resolves only if the operator's personal `~/.ssh/config` happens to
  define that alias on that machine. That config is chezmoi-synced and
  personal. On a freshly restored host, or any host the operator curated
  differently, the fleet's peer fallback silently has no route. Instead:
  `sync-render-ssh` generates `~/.ssh/config.d/roundhouse` (Windows:
  `%USERPROFILE%\.ssh\config.d\roundhouse`) from registry data alone, one
  `Host rh-<name>` block per machine carrying `HostName` (tailnet name when
  present, else hostname), `User`, `IdentityFile`, `UserKnownHostsFile`, and
  `CertificateFile` — the last three read from host-local `identity.json`,
  which already carries `private_key_path`, `known_hosts_path`, and
  `certificate_path`. Roundhouse ensures a single `Include config.d/*` line in
  `~/.ssh/config` and touches nothing else in that file. **All fleet transport
  addresses `rh-<name>`, never a personal alias.** Personal aliases stay
  personal; `remote-mac` and other interactive skills may still offer them as a
  convenience, but nothing scheduled or unattended may depend on one. Machine
  records therefore store `hostname`, `tailnet_name`, and `user` — the
  ingredients — and never an alias, which would be a name in someone else's
  namespace (P1d).
- **Harness config: the store owns the allowlisted keys, unconditionally.**
  Syncing the allowlisted key sets of `~/.codex/config.toml`,
  `~/.claude/settings.json`, and their siblings is this system's job and is
  never delegated to, or predicated on, chezmoi or any other engine. Chezmoi
  may or may not be installed on a given host; the sync must behave identically
  either way. Co-ownership of a config file **is detected and surfaced, and the
  operator chooses** which system owns each key — a key assigned to the other
  engine is dropped from our allowlist, a key assigned to us is removed from
  the other engine by the operator, and doctor watches for re-emerging
  co-ownership. That is a negotiation with a detected peer, not a dependency:
  no code path may require chezmoi to be present, and none may assume a key
  arrived because chezmoi delivered it.

---

## D6. Coordination: leases are deleted

**Settled: `leases/` is removed. Freshness records plus idempotency plus the
existing scheduler jitter cover phase 1.**

The shipped design already declares the failure a lease prevents to be
harmless — "a double-update is idempotent waste, not corruption" — and then
implements CAS pushes, TTLs, expiry evaluation, takeover, and malformed-lease
alerting to prevent it. The replacement is what the freshness records already
do:

> A host at phase 1 reads `upstreams/<id>.json` from the fetched ref. Updated
> within cadence → skip and converge from the store. Stale and this host is
> capable → run the upstream's own update, commit the result plus a new
> freshness record, push. A concurrent racer's push is rejected, it refetches,
> sees the winner's freshness record is now current, and **discards its own
> phase-1 result** rather than replaying it.

The discard is the one rule that replaces the primitive: **phase-1 output is
derived and therefore discardable on loss; alerts, findings, proposals, and
journal entries are decisions and are always replayed.** That split is also
what makes the general offline rebase safe (D7), so it is not a cost incurred
for lease removal — it was needed anyway. It is strictly better than the
shipped lease-race `-X ours` rebase, which discards the loser's edits to *any*
conflicting path, not just leases.

Honest assessment of harms beyond duplicate work:

- **Rate limits.** Upstreams are marketplace `git fetch`es and local repo
  pulls, at two scheduled runs per day across five hosts, jittered. Not real.
- **Same-path divergence on the updated content.** Real, but the discard rule
  resolves it deterministically without a lease, and the loser's content is
  regenerable by definition.
- **Thundering herd.** Prevented by the per-host scheduler jitter the design
  already specifies. Jitter *is* the coordination primitive, and it costs
  nothing.

No coordination primitive survives this. If a future upstream has metered cost
per refresh, that is the moment to reintroduce one — and it will want a budget,
not a lease.

Canary and journal mechanics are unaffected: `sync_resolve_canary` reads peer
journals off `host/<name>` branches and never consults `leases/`; journals are
written at run end. Both survive deletion untouched.

---

## D7. Offline-first operation

**P2 in detail. Git is the prior art and it is sufficient — no CRDTs.** CRDT
auto-merge would silently resolve exactly the divergences intent resolution
says to *hold* for human evidence; convergence-without-a-decision is the wrong
property for a trusted-write surface. jj's conflicts-as-data is the right
model precisely because it makes the conflict durable rather than resolving it.

**Offline write path.** Git needs no network to commit. An airplane host
fetches (fails, journals `source: none`), skips phase 1 entirely — freshness is
stale but unreachable, so the update defers and no history is written — then
runs phase 2 apply-time review against the last fetched ref and phase 3
convergence to its last-known effective desired set. That is the whole point:
**a disconnected host still converges.** Config edits, holds, verdict-driven
applies, alerts, findings, proposals, and the journal all land as local commits.

**Verdicts never replicate.** They live in `<store>.run/verdicts` because an
apply-time review verdict is evidence about *this host's* apply of *this
host's* incoming bytes, not a fleet fact — treating another host's verdict as
authorisation is the exact trust-channel hole KTD16 closes for signer material.
What propagates is the journal entry: item, digest, outcome, host, time.

**Reconnect.** Fetch, rebase local-only commits onto `origin/main`, push.
Offline-recorded review evidence needs no special handling: the review ran
against the bytes actually applied and the journal pins the digest. If the
upstream moved meanwhile, the next run's diff is current-vs-new-incoming and
re-reviews normally.

**Concurrent offline divergence.** File-per-item means two offline hosts
editing different items rebase cleanly — this is the main reason the layout is
file-per-item and it is worth stating as a load-bearing property, not an
incidental one. Same-path divergence: jj records a conflict commit; git-only
mode halts the rebase. Either way the shipped short-circuit applies — the
conflicted path converges from its last conflict-free state, is held
item-level while the rest of the run proceeds, and raises one alert naming the
path, both states, and both hosts. `sync-pending` surfaces it in any
interactive session on any host. **Same-path divergence is never auto-merged**;
the only automatic resolution in the system is the phase-1 discard rule, and it
applies to derived content only.

**Peer-to-peer, explicitly bounded.** Fetch-from-peer stays. **Push-to-peer is
out of scope, deliberately:** a push into a peer's store writes into a working
tree that peer's runner owns, and the run-lock is host-local and does not cover
a remote pusher. Two offline hosts on the same tailnet that both need to
publish instead **fetch each other and rebase locally**; whichever reaches the
primary remote first publishes both histories. That is git's own sneakernet
model, needs no new lane, and preserves the single-writer host-branch rule.

One gap to close in the existing peer lane: `sync_fetch_command` force-updates
`refs/remotes/origin/*` from the first reachable peer, so a peer that is
*behind* the real origin moves this host's view of `origin/main` backwards.
**Only fast-forward `origin/*` from a peer**; a non-fast-forward peer fetch
lands in `refs/remotes/peer/<name>/*` and is reported, not adopted. The trap:
one stale peer silently rolling back everyone's view of main.

Peer routes address `rh-<name>` from the managed SSH fragment (D5), so the
fallback lane works on a freshly restored host with no personal SSH config.

---

## D8. Seeding the desired catalog

**Settled: seeding reads a full host inventory and writes `machine-<name>`
scope records. It proposes wider scopes; it never unifies.**

Today's live inventory is the design input: plugins span every configured
marketplace (compound-engineering, ponytail, impeccable, and the rest — not a
single-marketplace assumption anywhere), and standalone skill libraries differ
per machine by **141 versus 58 items**. That gap is curation, not drift. A
seeding pass that treats the larger host as truth would install 83 skills
someone deliberately kept off a machine, and would do it through the phase-3
convergence path that also handles removals — so the reverse mistake deletes
83 instead. Either direction is a bad first impression from a system whose
whole value proposition is not surprising you.

- **Seed writes at machine scope, always.** `sync-seed <host>` reads the host's
  full inventory snapshot — plugins with enabled/disabled state across all
  marketplaces, standalone skills, agents, hooks, MCP servers — and writes
  `desired/machine-<name>/<type>/<id>.json` for each. Every host that seeds
  ends up with its current state described exactly, and the first convergence
  after seeding is a no-op by construction. That is the safety property worth
  paying a redundant catalog for.
- **Promotion is proposed, never applied.** Where an item is present at the
  same state on *every* enrolled host, seeding emits a
  `roundhouse.sync-proposal` to move it to `all`; same for an OS or group
  scope where every member agrees. Proposals are records on `main` that the
  operator reviews and accepts — the shipped proposal mechanism, reused as-is,
  no new machinery. Unanimity is the bar because anything weaker is a guess
  about intent, and D1's evidence rules already say guesses hold.
- **Divergence is data, not an alert.** An item on 3 of 5 hosts is the normal
  case for a curated fleet. It stays at machine scope on those three, produces
  no proposal, and generates no alert. Alerting on deliberate curation would
  train the operator to ignore alerts, which is the one failure mode the
  alerting design cannot survive.
- **Re-seeding is idempotent and additive.** Running `sync-seed` again upserts
  machine-scope records and never removes one — a skill uninstalled between
  seeds is a convergence decision for phase 3 to report by name, not something
  seeding silently drops from the catalog.

The cost is an initially verbose `desired/` — five machine scopes each listing
their full surface, with heavy overlap. That is the right trade: the catalog
starts *correct* and gets compact through reviewed promotions, rather than
starting compact and being wrong about 83 skills on day one.

---

## Symmetry audit: shipped violations and their new homes

| # | Shipped | Why it violates P1 | New home |
|---|---|---|---|
| 1 | `meta/host.json` | Singular noun at tree root implying a canonical host (P1c); content is 100% host-local posture — `mode`, `signing_enabled`, `signing_configured`, `remote_visibility_verified` (P1a). Committed on the fresh-root scaffold path, so it replicates; every other host then carries a foreign copy on `main` and its own dirty in the working tree. | `<store>.local/posture.json`, schema `roundhouse.sync-host-posture`. Out of the tree, out of git. |
| 2 | The `--autostash` + `meta-keep.json` rescue in the lease convergence path | Pure symptom of #1: machinery whose only job is to stop a replicated file from overwriting the local host's own state. | Deleted with #1 and with `leases/` (D6). |
| 3 | `registry/config-base.json` | One host's whole config minus `.machines`, at a non-host-keyed path, carrying that host's `sync.store_path`, `sync.remote.url`, and `skill_roots` (P1b, P1d). Built by denylist. | `registry/fleet.json`, allowlisted fleet-shared blocks only (D5). |
| 4 | `transport: "local"` inside `registry/machines/<name>.json` | Writer-relative value in the tree (P1d) — and a live bug: peer-fetch skips it, render never clears it, `sync_host_name()` picks `[0]`. | Not stored. Derived at render. |
| 5 | `sync-absorb-registry`'s `rm -f registry/machines/*.json` | Rebuilds the fleet registry from one host's config — behaviourally a primary even though no file says so. | Upsert-only; removal is an explicit command. |
| 6 | `leases/` | Fleet-writable coordination state whose only harm case is declared harmless. | Deleted (D6). |

Compliant and unchanged: `README.md` and `.gitignore` (fleet-uniform),
`.roundhouse-sync-store` (fleet-uniform fingerprint), `findings/<host>/`
(explicitly host-keyed), `host/<name>` branches, `<store>.run/` (already
outside the tree — the pattern the rest of this table extends).

Doctor gains one check: **no host-local file inside the store tree.** The
`untracked_unexpected` tripwire already exists; extend it to fail on any path
in the host-local set, tracked or not.

---

## Target layout

```text
~/.config/roundhouse/
  fleet.yaml                       # human-authored fleet config (YAML)
  config.json                      # rendered per-host, machine-generated
  identity.json                    # host identity, never synced
  store/                           # jj repo colocated with git
  store.run/                       # host-local, ephemeral: lock, run state, verdicts
  store.local/                     # host-local, durable: posture.json

~/.ssh/
  config                           # operator's; we add one Include line, nothing else
  config.d/roundhouse              # generated from the registry — all fleet transport
```

```text
store/                             # branch: main
  .roundhouse-sync-store           # fleet fingerprint marker
  .gitignore
  README.md
  registry/
    fleet.json                     # allowlisted fleet-shared config blocks
    machines/<name>.json
    groups/<name>.json
    renames/<epoch>-<from>.json    # permanent, append-only
  desired/
    all/<type>/<id>.json
    os-macos/<type>/<id>.json
    group-development/<type>/<id>.json
    machine-<name>/<type>/<id>.json
  allowlists/<config-file-id>.json
  upstreams/<id>.json              # freshness records (no leases/)
  alerts/<id>.json
  findings/<name>/<id>.json
  canary/<tuple-digest>.json

store/                             # branch: host/<name>, single-writer
  snapshot/                        # inventory as observed
  journal/                         # one record per run
  materialized/                    # allowlisted config keys as applied
```

Gone from the shipped tree: `meta/`, `leases/`, `registry/config-base.json`.

### Record examples

`registry/machines/vireo.json` — human-named path, stable `id`, no
writer-relative fields:

```json
{
  "attested_by": { "node_key_fingerprint": "SHA256:...", "rotated_at": "2026-07-02T18:04:11Z" },
  "groups": ["development"],
  "hostname": "vireo.local",
  "id": "9f2c4a71b30e8d55",
  "package_managers": ["homebrew"],
  "physical_host": "vireo-hw",
  "platform": "macos",
  "schema": "roundhouse.sync-machine",
  "schema_version": 1,
  "tailnet_name": "vireo.tailnet.ts.net",
  "user": "claire"
}
```

No `ssh_alias`: the alias is ours to generate (`rh-vireo`) from `hostname` /
`tailnet_name` / `user`, not a name borrowed from the operator's personal SSH
config (D5). No `transport`: derived at render (D5). `physical_host` is a
set-membership key — other records may carry the same value, and nothing may
assume this is the only machine on that hardware (P1e).

`registry/renames/1785024000-macbook-pro.json` — retained permanently:

```json
{
  "at": "2026-08-07T14:00:00Z",
  "by_host": "vireo",
  "from": "macbook-pro",
  "id": "9f2c4a71b30e8d55",
  "schema": "roundhouse.sync-rename",
  "schema_version": 1,
  "to": "vireo"
}
```

`upstreams/claude-marketplace.json` — the whole of phase-1 coordination:

```json
{
  "by_host": "vireo",
  "result_digest": "3b1f...",
  "schema": "roundhouse.sync-upstream",
  "schema_version": 1,
  "updated_at": "2026-08-07T09:12:44Z",
  "updated_at_epoch": 1785056364,
  "upstream": "claude-marketplace"
}
```

`<store>.local/posture.json` is the shipped `meta/host.json` payload verbatim
(`mode`, `host`, `created_at`, `signing_enabled`, `signing_configured`,
`remote_visibility_verified`) under schema `roundhouse.sync-host-posture` —
same fields, outside the tree, never replicated.

---

## Deliberately not added

Each surfaced by the research and rejected as speculative:

- No `environments/` directory and no `role-` tier — the unrecognised-prefix
  hold (D2) makes adding one safe later; until a second environment exists the
  directory is an empty promise.
- No GUID or hash filenames anywhere a human reads a path.
- No CRDT or auto-merge layer, and no push-to-peer lane (D7).
- No Kustomize-style `base/` + `overlays/` duplication — the scope tiers are
  the overlay mechanism and they already union.
- No per-record `apiVersion` URI: an integer `schema_version` plus the D4 rules
  is enough for five hosts, and a schema-document URI needs a registry we would
  not maintain.
- No `serial`/write-counter alongside `schema_version` — git commit order is
  our write-ordering axis, already durable and signed.

## Migration note

The store is recreated from scratch on the one live host. There is no
migration path and none is needed.

## Open questions for the operator

1. **`fleet.yaml` scope.** Does it replace `config.json` as the authored
   surface entirely, or only the fleet-shared blocks, leaving host-local keys
   (`sync.remote`, `store_path`) in a small host-local JSON? The second is
   cleaner against P3 but means two authored files.
2. **Rename record retention.** Permanent is Terraform's answer and this
   document adopts it. If the fleet ever prunes them, the rule must be "older
   than the longest plausible offline window" — is there a number you would
   commit to, or does permanent stand?
3. **Seed promotion threshold.** D8 promotes a seeded item to a wider scope
   only on unanimous agreement across the hosts already enrolled. With two
   hosts enrolled, "unanimous" is a weak signal. Should promotion be suppressed
   entirely below some enrolled-host count, or is reviewing the proposals
   enough?
4. **Unresolved:** whether `desired/<scope>/` should also carry a
   `machine-<name>` tier for *presence exclusion only* versus the current
   full-record-at-machine-scope model. The shipped effective-state resolver
   treats machine tier as fully authoritative (`tier == 3` short-circuits the
   enable-wins union), which is correct per the original spec, but it means a
   machine-scope record must restate `enabled` even when it only wants to
   exclude. I could not settle whether that restatement is a footgun in
   practice or a non-issue; it needs one real multi-host override to judge.
