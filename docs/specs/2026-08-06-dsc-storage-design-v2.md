# Roundhouse DSC Store — merged storage design

Status: **replacement spec, rev 7** · 2026-08-07 · supersedes the storage core of
`docs/specs/2026-08-07-dsc-storage-design.md` (its feature inventory stands; its
canonical-JSON store, `schema`/`schema_version`, `leases/`, `meta/host.json`,
`registry/config-base.json`, `transport:`, `host/<name>` branches and opaque
`id:` do not).

Chassis: **inventory-layering**. Owner-proxy ranked it 1st (119/140), operator
1st (118/140), implementer **tied it at 98/140 with dotfiles-native and broke the
tie in its favour** on "its contested jj claims all survived measurement" — while
noting dotfiles-native is the cheaper build. Grafts from dotfiles-native,
gitops-reconciler and jj-native per the judges' steal-lists. Every "must NOT
survive" item is excluded and listed in §15; where the judges disagreed with each
other, §15 says so rather than claiming consensus.

One sentence: **the store is four layers of hand-written YAML plus host-keyed
machine appends, in a jj repo where a hand edit is already a signed commit, and
where every value that is ever applied exists byte-for-byte in a commit this host
verified.**

### Sourcing of factual claims

Claims are marked inline:

- **[judges]** — measured by one or more of the three judges on jj 0.44.0.
- **[rev2]** — measured by me during this revision, on jj 0.44.0 /
  OpenSSH_10.3p1 / yq v4.53.3 / jq 1.8.2 / git 2.55.0, macOS, in throwaway
  repos under `/private/tmp/dsc-fix/` with `JJ_CONFIG` isolation and every
  invocation non-interactive. Ledger: `/private/tmp/dsc-fix/VERIFIED.txt`.
- **[rev7]** — measured by me during the rev-7 revision closing W1-W2. Script:
  `/private/tmp/dsc-fix/lab18.sh`.
- **[rev6]** — measured by me during the rev-6 revision closing V1-V13. Scripts:
  `/private/tmp/dsc-fix/lab16.sh`, `lab17`.
- **[rev5-rev]** — measured by the reviewer during the targeted rev-5 pass.
- **[rev5]** — measured by me during the rev-5 (owner-direction) revision, same
  toolchain and isolation. Scripts: `/private/tmp/dsc-fix/lab14.sh`, `lab15`.
- **[rev3-fix]** — measured by me during the rev-3 revision, same toolchain and
  isolation, closing the re-review's R1-R12. Scripts: `/private/tmp/dsc-fix/lab10.sh`,
  `lab11.sh`.
- **[rev3]** — measured by the reviewer during their re-review of rev 2.
- **[unverified]** — asserted by a candidate, not measured by anyone. Treat as a
  design assumption, not a fact.

Rev 1 of this document blanket-attributed everything to the judges and got three
things wrong that a lab run would have caught. Everything operational below is
now `[rev2]` or explicitly flagged.

---

## 1. The bets

0. **Agents are the routine writers; humans are the guaranteed editors.**
   [owner clarification, 2026-08-06] "Hand-edited" throughout this document
   names a *capability guarantee*, not the expected authorship: most reads
   and writes of these layers are made by agents in the course of normal
   runs. The requirement is that a human can open any file in an editor at
   any time, understand it, change it, and walk away — easily, with no
   ceremony — and everything below (single representation, comment-safe
   digests, snapshot conflict markers, auto-snapshot signing, the review
   gate treating human and agent edits through the same path) exists to
   keep that guarantee true under routine agent traffic.

1. **One file per layer, not one file per item.** You open `hosts/vireo.yaml`
   and see that machine. *(chassis)*
2. **A conflict is a commit, and a conflicted YAML file is still a file you edit
   in vim** — with `ui.conflict-marker-style = "snapshot"`, which is what makes
   that true rather than aspirational. *(chassis)*
3. **The verdict binds the resolved *value*, never file bytes.** *(chassis +
   gitops)*
4. **Merge behaviour is fixed by data shape.** Desired state is maps keyed by
   item name, never lists. *(chassis)*
5. **Every path is either hand-edited-and-fleet-shared or machine-appended-and-
   host-keyed**, with exactly one deliberate exception: `joins/` (§7.3a B), which
   is host-keyed but written by a **non-member** and is **never applied** — inert
   by construction, which is why it can accept an `unknown` signature safely.
6. **Nothing is applied that does not exist in a commit.** When histories
   diverge, an item converges only at a value identical at *every* head;
   anything else is held. There is no synthesised merge state. *(gitops'
   granularity, without gitops' unreproducible merge)*
7. **No conflicted commit is ever pushed**, and the resolution is folded back
   into the commit that carried the conflict so history stays pushable. §8.4.
8. **Nothing this system runs can ever wait for a human at a UI.** §3.2.

---

## 2. Layout

### Host-local, never in the store

```text
~/.config/roundhouse/
  identity.yaml        # this host's name, domain, key + pin. Never synced.
  local.yaml           # store path, remote URL, enabled
  # Trust artifacts. Root-owned under /usr/local/etc/roundhouse where the
  # privileged lane is configured (§7.9); these ~/.config paths are the degraded
  # fallback, which alerts. Never read live from the working copy — `trustd`
  # re-derives them from the store's own verified history.
  allowed_signers      # materialized roster (§7.9)
  reviewed-ref         # monotonic high-water mark (§7.11.2, §7.12.3)
  generation           # monotonic roster generation (§7.12.3)
  krl                  # emergency retroactive lever only (§7.1b)
  store/               # the jj repo (colocated .git)
  store.run/           # ephemeral per run: lock, run state, VERDICTS
  store.local/         # durable host posture

~/.ssh/config.d/roundhouse   # generated from hosts/*.yaml. Never hand-edited.
```

`~/.config/roundhouse/identity.yaml`, complete:

```yaml
# Everything here is about this machine only. Nothing here is also in the store.
# There is no absorb step and no rendered twin of this file.
name: vireo
principal: vireo@fleet.novotny.org   # this host's roster principal; also the
                                     # store's committer identity (§7.3)
store_id: 7f3a2c9e1b04d55a           # the GENESIS COMMIT ID (or the checkpoint
                                     # id you started from, §7.11.1). Handed down
                                     # the instruction chain as data, or read back
                                     # over the enrollment channel — never pasted
                                     # by a human. Unforgeable rather than merely
                                     # secret: knowing it does not let anyone
                                     # produce a store with that genesis (§7.5).
key:   ~/.ssh/roundhouse_node_ed25519
krl:   /usr/local/etc/roundhouse/krl # emergency retroactive lever only (§7.1b).
                                     # Falls back to ~/.config/roundhouse/krl
                                     # where the privileged lane is absent (§7.9).
known_hosts: ~/.ssh/roundhouse_known_hosts
```

**The jj repo config is also host-local and lives outside the store.**
**[rev2]** Writing `store/.jj/repo/config.toml` makes jj 0.44 migrate it to
`~/.config/jj/repos/<opaque-hash>/config.toml` and replace the original with a
**symlink into `$HOME` inside the store tree**. So the config is written with
`jj config set --repo` (§3), read back with `jj config get`, and
`roundhouse fleet-init` runs on **every** host, not just the first (§12).

### The store — one bookmark, `main`. No host branches, no status branch.

```text
store/
  # (no identity marker file: the fleet discriminator is the GENESIS COMMIT ID,
  #  compared against identity.yaml's store_id — §7.5. A file could be copied
  #  into a hostile store; a genesis commit cannot.)
  .gitattributes                          # one line: *  -text
  .gitignore                              # editor artefacts, for the git side
  README.md

  fleet.yaml            OR fleet/*.yaml            ┐  layer 1
  os/macos.yaml         OR os/macos/*.yaml         │  layer 2   hand-edited,
  groups/development.yaml OR groups/development/*.yaml │ layer 3 fleet-shared,
  hosts/vireo.yaml      OR hosts/vireo/*.yaml      ┘  layer 4   may conflict

  trust/signers.yaml                       # THE fleet roster (§7.1). Hand-editable.
                                           # Changes valid only if signed by a key
                                           # trusted at the PARENT commit.
  joins/<host>.yaml                        # inert enrollment requests (§7.3a B)
  checkpoints/<epoch>.yaml                 # signed roster+state snapshots (§7.11)
  definitions.yaml                         # logical name -> concrete artifact,
                                           # keyed by category (packages/plugins/
                                           # skills). DEFINITIONS, not desired
                                           # state: fleet-wide, outside the fold,
                                           # exceptions only. §5.1
  lineage/1785024000-macbook-pro.yaml      # rename/retire ledger. Permanent.
  proposals/promote-ponytail-to-fleet.yaml # content-named; identical => dedupe

  journal/<host>/<date>.yaml               ┐
  applied/<host>.yaml                      │  machine-written, host-keyed.
  alerts/<host>/<stamp>-<slug>.yaml        │  exactly one writer per path.
  findings/<host>/<stamp>-<slug>.yaml      │  cannot conflict, ever.
  upstreams/<id>/<host>.yaml               ┘
```

**Every layer takes a file *or* a directory**, merged in filename order. This is
Ansible's `group_vars/x.yml` vs `group_vars/x/`, applied uniformly instead of to
host files only — the operator judge's headline repair. Three lines of code, and
it is the escape valve that keeps bet 1 honest at every tier.

**No `host/<name>` branches** (deletes the `git checkout host/$x … git checkout -`
sandwich that can strand the store on the wrong branch). **No disjoint-root
`status/<host>` branch** — evidence a human cannot `ls` is evidence they will not
read. Host-keyed *paths* on one bookmark give the same single-writer guarantee.

**No `snapshots/`.** Observed inventory is the largest, noisiest, most derived
thing in the shipped tree and its consumers (`fleet-inventory`) collect live.

### The two path kinds, and the third that is deliberately empty

| Kind | Paths | Concurrent-write behaviour |
|---|---|---|
| Hand-edited, fleet-shared | the four layers, `trust/signers.yaml`, `definitions.yaml`, `lineage/`, `proposals/`, `checkpoints/` | jj line-merge; contested keys become a conflict the run's **agent** resolves from evidence (§8.2b), escalating to a human only when both sides are deliberate human edits |
| Machine-appended, host-keyed | `journal/`, `applied/`, `alerts/`, `findings/`, `upstreams/<id>/<host>.yaml` | **cannot conflict** — different directories |
| *(exception)* Inert, non-member-written | `joins/<host>.yaml` | cannot conflict (one file per requester); **never applied**, only read as a hint (§7.3a B) |
| ~~Derived, shared, discardable~~ | *(none)* | host-keying `upstreams/` eliminated the category |

dotfiles-native's third kind existed to hold `upstreams/<id>.yaml`, a shared
mutable file. The chassis keys it per host, so there is nothing left to discard.
`jj restore --from main@origin <path>` survives as the **documented one-command
recovery** for "I mangled a shared file" — the path prefix is still the
discardability boundary, and it is the answer if the third kind ever returns.
*(dotfiles-native, honoured and reduced)*

`lineage/` and `proposals/` are machine-appendable but fleet-shared; both are
content-named, so two hosts writing the *same* record write identical bytes and
jj merges them, and two hosts writing *different* records write different files.

---

## 3. Host configuration

### 3.1 The jj config block

Written by `roundhouse fleet-init` **on every host** with `jj config set --repo`
**[rev2]**, never by writing a config file path. Doctor asserts effective values
with `jj config get`, never file contents.

```sh
jj config set --repo user.name  "roundhouse-sync"
# user.email is NOT set here: it must equal this host's roster principal, and at
# fleet-init time no key exists yet. fleet-enroll mints it and sets this (§3.3).

jj config set --repo ui.paginate               never
jj config set --repo ui.editor                 true
jj config set --repo ui.conflict-marker-style  snapshot
jj config set --repo ui.show-cryptographic-signatures true

jj config set --repo git.abandon-unreachable-commits false
jj config set --repo git.write-change-id-header      true
```

**`[signing]` is written by `roundhouse fleet-enroll`, not by `fleet-init`** —
see §3.3, this is P0-4:

```sh
jj config set --repo user.email "vireo@fleet.novotny.org"   # == roster principal
jj config set --repo signing.backend  ssh
jj config set --repo signing.behavior own
jj config set --repo signing.key      "$HOME/.ssh/roundhouse_node_ed25519"
jj config set --repo signing.backends.ssh.program         /usr/bin/ssh-keygen
jj config set --repo signing.backends.ssh.allowed-signers "$TRUST/allowed_signers"
jj config set --repo signing.backends.ssh.revocation-list "$TRUST/krl"
```

`$TRUST` is `/usr/local/etc/roundhouse` where the privileged materialization lane
is configured, and `~/.config/roundhouse` where it is not — §7.9's ladder, and the
degraded case alerts rather than being the silent default.

> **These two repo-config values are the steady-state defaults only, and
> verification always overrides them per commit.** They serve signing (which needs
> a roster at *now*) and any ad-hoc `jj log` a human runs. **Every trust decision
> passes `--config signing.backends.ssh.allowed-signers=$RUN/roster.<commit>`**,
> the roster derived from that commit's parents (§7.1a). Implementing this block
> alone would build head-roster verification — the file being verified supplying
> the keys that verify it — which §7.1 opens by calling broken.

Every line is a decision traceable to an observed failure:

- **`user.email` is this host's roster principal, per host, and it is set at
  enroll time.** Not a fleet-wide constant, and not writable at `fleet-init`
  because the key does not exist yet. **[rev2]** With one shared `user.email` on every host,
  `behavior = "own"` treats every fetched commit as this host's own: a plain
  `jj describe -r <ancestor>` on vireo re-signed corvid's ancestor **and its
  descendant** as `good [vireo@…]`, silently destroying corvid's evidence. With
  per-host identities the same rewrite **strips** the signature instead
  (`UNSIGNED`), which falls into the existing "unsigned → hold" path (§7.7).
  This one line also makes the §7.3 equality gate meaningful. It fixes two
  findings at once.
- **`behavior = "own"`** signs the working-copy snapshot: one signature per jj
  command, no watcher **[judges]**. **`git.sign-on-push` is rejected** — it
  signs at *publication*, so the host that relays another host's commits signs
  them, breaking every host-attribution rule in §7.3.
- **`conflict-marker-style = "snapshot"`.** The default `diff` style prefixes
  `+`/`-`/space onto every line — a one-column shift where whitespace is
  semantic. **[rev2]** reproduced: snapshot style puts every side at correct
  YAML indentation, labelled with change ID, commit ID and description. *(all
  three judges' #1 steal)*
- **`abandon-unreachable-commits = false`.** With the default `true`, a
  force-pushed origin makes `jj git fetch` abandon local commits that became
  unreachable — silent deletion of an offline host's unpushed work. **[judges]**
  measured the default; the abandon behaviour itself is **[unverified]**
  (jj-native's observation) and is pinned because the cost of pinning is zero
  and the cost of being wrong is data loss.
- **`ui.paginate = never`, `ui.editor = true`** — §3.2.
- `snapshot.auto-track` and `snapshot.max-new-file-size` are **not set.**
  Rev 1 copied them from jj-native with no rationale. **[rev2]** on jj 0.44 the
  default `auto-track = "all()"` did *not* track `.DS_Store`, `*.swp` or `*~`,
  so the setting bought nothing. The store still ships a `.gitignore` covering
  those patterns, because it protects the **colocated git side** from an agent
  running `git add -A`, which jj's behaviour does not.

### 3.2 Non-interactivity is a hard requirement

> **No jj, git or ssh-keygen invocation this system makes — scheduled or
> supervised — may be capable of falling through to an editor, a pager, a
> credential prompt, or any other UI. A run that can block on a human is a run
> that hangs a machine nobody is sitting at.**

Enforced in four places:

1. **jj repo config** pins `ui.paginate = never` and `ui.editor = true`
   **[rev2]** — with `ui.editor = true` a bare `jj squash` completes silently;
   without it the reviewer measured a real 120 s block on the owner's
   `code --wait`.
2. **Every rewrite command carries an explicit message flag.** `jj describe -m`,
   `jj new -m`, `jj squash --use-destination-message` (or `-m`). The runbook in
   §8 does this on every line. No command in roundhouse may omit it.
3. **The colocated `.git` is pinned hermetic at `fleet-init`.** **[rev2]** the
   owner's global git config today is `commit.gpgsign = true`,
   `gpg.format = ssh`,
   `gpg.ssh.program = /Applications/1Password.app/…/op-ssh-sign` — so **any**
   agent running `git commit` inside the store pops a 1Password approval dialog,
   and §8.4's own premise is that agents shell out to git. `fleet-init` writes
   repo-local overrides, verified to win over the global values **[rev2]**:

   ```sh
   git -C "$store" config commit.gpgsign     false
   git -C "$store" config tag.gpgsign        false
   git -C "$store" config gpg.ssh.program    ssh-keygen
   git -C "$store" config core.pager         cat
   git -C "$store" config core.editor        true
   ```
4. **Environment — for *every* roundhouse invocation, not just the scheduled
   run.** `JJ_EDITOR=true`, `GIT_EDITOR=true`, `PAGER=cat`,
   `GIT_TERMINAL_PROMPT=0`, `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, and stdin
   closed (`exec < /dev/null`). Two live traps this catches: **[rev2]**
   `ssh-keygen -Y sign` prompts `overwrite (y/n)?` when the `.sig` already
   exists — it hung this revision's own lab for 120 s — and `jj git fetch` over
   SSH will prompt for a passphrase if the agent is not loaded.

   Two corrections rev 2 needed here:

   - **`BatchMode=yes` is the knob, not `SSH_ASKPASS_REQUIRE=never`.** The latter
     only suppresses the *GUI* askpass; a TTY passphrase prompt still happens.
     `ssh -o BatchMode=yes` refuses to prompt at all. Closed stdin covers it in
     practice, but naming the wrong mechanism invites someone to drop the stdin
     redirect later.
   - **Three prescribed commands run *outside* the store's repo config**, so
     repo-local pins do not reach them and the environment is the only thing
     that does: `jj git clone` in §12 (it runs before `fleet-init` writes any
     pins), the doctor's synthetic conflicted-bookmark repo (§10.7), and the git
     cross-check fixture (§7.1). Each is invoked with the environment above and
     with an explicit `--config ui.editor=true --config ui.paginate=never`
     (or `git -c core.pager=cat -c core.editor=true`).

Doctor asserts (1)–(3) by reading effective values, and greps roundhouse's own
source for a rewrite subcommand without a message flag.

### 3.3 Bootstrap order, because signing config can brick the store

**[rev2]** With `signing.behavior = "own"` and `signing.key` naming a file that
does not exist, jj does not merely fail to sign — `jj git init --colocate`
itself dies with `Internal error: Failed to check out the initial commit / …
Signing error` and **the repo is never created**. This is worse than the shipped
code's documented observation and it is the most likely first-run state in the
design.

So the order is fixed, and the two commands are separate:

1. **`roundhouse fleet-init`** — `jj git init --colocate` (or clone), the §3.1
   block *without* `[signing]`, the §3.2 git pins, `.gitattributes`, `.gitignore`,
   `README.md`. The store is fully operable, unsigned.
2. **`roundhouse fleet-enroll`** — **generates this machine's own keypair and
   registers it in the roster.** No certificate request, no authority to contact,
   **no sudo**, no ceremony:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/roundhouse_node_ed25519 -N ''   # 0600, no passphrase
jj config set --repo user.email "<node_id>@<domain>"            # == the principal
jj config set --repo signing.key "$HOME/.ssh/roundhouse_node_ed25519"
# … then the rest of the §3.1 [signing] block
```

   The roster line itself is committed **by the sponsor**, not by this host
   (§7.3a) — a machine cannot enrol itself, which is the ratchet. At genesis
   there is no sponsor and the host writes its own self-signed roster (§7.3a).

The brick-ordering rationale survives intact: `[signing]` must still follow key
existence, because the failure mode is `jj git init` dying rather than merely not
signing. What changed is only what step 2 *does* — mint and register, rather than
request and install.

A host between (1) and (2) commits unsigned, and its commits are held by every
peer until it is enrolled. `fleet-enroll` is idempotent and is also the heal path,
the rename path (§9.1 — a rename requires it, because the principal is in the
roster), the reconstitution path (§7.8 C), and the second-identity path for an
operated host (§9.2).

**Key rotation is one roster edit, not a rotation protocol.** A host that needs a
new key mints one and a durable member commits the swap — the old key moves to
`retired:` with `revoked_at_commit`, so its history stays valid (§7.1b) while its
new commits must use the new key. There is no overlap window to manage, because
there is no shared authority whose replacement has to be staged: **each key stands
alone, and history is evaluated at the roster that existed when it was written.**

---

## 4. The merge rule

Four layers, low to high:

1. `fleet.yaml` (or `fleet/*.yaml`)
2. `os/<platform>.yaml`
3. `groups/<g>.yaml` **for each `g` in the order the host lists them**
4. `hosts/<name>.yaml`

**Group precedence is the host's own list order** — `groups: [development,
canary]` means canary wins ties, and it says so in the file you already have
open. No priority field, no alphabetical rule, no `hiera.yaml`. **No transitive
group membership.**

**Resolution is a left fold with one knockout clause:**

- map + map → deep merge, key by key
- anything else → the higher layer replaces it whole
- `null` / empty document → no opinion at this layer; skip it
- **`absent` knockout is applied as a separate scoped pass, not by the fold.**
  yq's `ireduce`/`*d` has no knockout operator, and a naive
  `del(.. | select(. == "absent"))` would delete a legitimate string `"absent"`
  nested inside a `config_files` value. So: after each layer is folded in, any
  key at exactly `<category>.<item>` whose value is the scalar `absent` is
  deleted from the accumulator. Scoped to item position, never recursive. The
  semantics are the chassis's; the sentence "the fold is the whole rule" was one
  clause short.

No configuration knob. `absent` cannot fail at depth the way Hiera's
`knockout_prefix` does, because there is no collect-then-merge phase.

**No lists in desired state.** Lists appear only as facts in the host file
(`groups`, `package_managers`), which is the top layer and never merges.

**Item identity** is `<category>.<name>`, and the name is **logical**: `packages`,
`plugins`, `skills`, `agents` and `hooks` names are mapped to concrete artifacts by
`definitions.yaml` (§5.1), which carries only the exceptions. **A definition is
itself an item, under the reserved `definitions.` prefix** —
`definitions.packages.jj` is the mapping, `packages.jj` is the desired state, and
they are different items with different digests and different verdicts. A **plugin-qualified**
name (`superpowers/brainstorming`) resolves through its plugin; a bare name is a
standalone item (§5.1.3). Categories are a
closed set:
`policy`, `packages`, `plugins`, `skills`, `agents`, `hooks`, `mcp_servers`,
`config_files`, `projects`. Adaptive reading, with a deliberate asymmetry:

- **unknown key *inside* a known item → ignored** (cannot under-converge)
- **unknown *category*, or an unrecognised layer directory → every item held,
  with an alert naming it** (could under-converge, so never silent). **The
  recognised top-level set is therefore part of the design, not discovered at
  runtime:** the four layer paths, plus `trust/`, `joins/`, `checkpoints/`,
  `definitions.yaml`, `lineage/`, `proposals/`, and the host-keyed evidence
  directories. **A directory this document adds is added to that set in the same
  change** — otherwise every host holds everything the first time it fetches the
  new layout, which is the rule working exactly as designed against its own
  authors.
- **scalar or map, reader's choice.** `ponytail: enabled` and
  `ponytail: {state: enabled}` are the same item — and §7.2 now normalizes the
  scalar form before digesting, so they are the same item *at the digest layer
  too*. In rev 1 they were not.

### Provenance ships as a command — file, not file:line

```
$ roundhouse fleet-explain vireo plugins.railyard
plugins.railyard = {"marketplace":"claire-local","state":"enabled"}

  fleet.yaml                  —          (no opinion)
  os/macos.yaml               —          (no opinion)
  groups/development.yaml     enabled
  hosts/vireo.yaml            {state: enabled, marketplace: claire-local}   <- wins
```

Rev 1 promised line numbers. **[rev2] yq's `line` operator cannot deliver them
on the files this design actually has.** Measured: `line` does not count
comment-only lines, so in a commented file every reported number drifts by an
amount that depends on how many comments precede the key — a key on file line 4
reported as 3, another on line 7 reported as 6 by `key | line` and 7 by `line`.
Neither `line` nor `key | line` is right in both the scalar and map cases.
Layer files are commented by design, so a line number here would be confidently
wrong. **Dropped.** File-level per-key provenance still beats every system
surveyed except Puppet, whose `lookup --explain` also gives only file names.

---

## 5. Real files

### `fleet.yaml`

```yaml
# Applies to every host unless a narrower layer says otherwise.
# Precedence: fleet.yaml < os/<platform>.yaml < groups/<g>.yaml (host's order) < hosts/<name>.yaml

policy:
  # Two cadences. Fast is the one that determines freshness (§6.1).
  fast_interval_minutes: 20   # fetch + converge. The propagation SLO.
  fast_jitter_minutes: 5      # per-host, seeded from the name: stable, spread out
  cadence_hours: 12           # heavy maintenance only: upstreams, seed, doctor,
                              # proposals. Never the propagation path.
  jitter_minutes: 90          # for the heavy run. The whole coordination
                              # primitive, still. No leases.
  canary_group: canary
  canary_wait_hours: 24
  # Trust knobs (§7). Soak delays a newly-enrolled DURABLE key's fleet-layer
  # writes; leaves have no soak because they cannot write fleet layers at all.
  signers_soak_hours: 24        # channel_auth: known_hosts | tailscale | runtime
  signers_soak_hours_tofu: 72   # channel_auth: tofu — the weakest path, visibly slowest
  ephemeral_ttl_hours: 24       # default TTL stamped at leaf enrollment (§7.1b)
  evidence_retention_days: 90   # journal/ alerts/ findings/ aging (§7.11.3)
  reroot_after_commits: 20000   # checkpoint + re-root trigger (§7.11.2)
  # Blast-radius guards on removals. §10.3.
  max_removals_per_run: 5
  max_removal_fraction: 0.25  # ...or this share of the applied set, whichever is smaller

plugins:
  ponytail: enabled
  compound-engineering: enabled
  roundhouse: enabled

skills:
  superpowers/brainstorming: enabled
  superpowers/systematic-debugging: enabled

config_files:
  ~/.claude/settings.json:
    keys:
      env.DISABLE_TELEMETRY: managed
      permissions.deny: managed
      model: unmanaged            # chezmoi owns this one on every host
    never:                        # refused even if a narrower layer says managed
      - env.ANTHROPIC_API_KEY
      - apiKeyHelper
      - mcpServers
```

`never` beats `managed` from any layer, in either prefix direction; a collision
is a refusal plus an alert. This is the one mechanical validation in the system;
it is a security boundary, and it carries over from the shipped code unchanged.

**Chezmoi co-ownership** is detected, not assumed: for every `managed` key,
convergence checks whether another engine also writes it (chezmoi's source state
is queried if chezmoi is installed; its absence is never an error). A key claimed
by both is **held** with an alert naming both owners, and the operator resolves
it by marking it `unmanaged` here or removing it from the other engine. Doctor
re-runs the same check every run so re-emerging co-ownership is caught. No code
path may require chezmoi to be present.

### `os/macos.yaml`

```yaml
# LOGICAL package names (§5.1). jq/yq/gh need no definition — same name on
# every manager, and unpinned means `latest`. jj needs one: winget spells it
# differently and apt does not carry it at all.
packages:
  jq: enabled
  yq: enabled
  jj: enabled          # hard prerequisite, same tier as jq/yq
  gh: enabled
```

### 5.1 `definitions.yaml` — logical name → concrete artifact

Every category in the layers names things **logically**. `jj` is not a package
name; it is the name of a thing this fleet wants, and every manager spells it
differently — `jj` on homebrew, `jj-vcs.jj` on winget, nothing at all on apt.
`ponytail` is not a marketplace coordinate. `definitions.yaml` is the one place
those mappings live, keyed by the same categories the layers use.

*(Supersedes the `packages.yaml` filename of the first amendment: the owner's
requirement was the mapping, not the file, and once plugins needed the identical
treatment a file per category would have been three paths and one reader. Keying
one file by category also gives it exactly the shape of a layer file.)*

```yaml
# ONLY exceptions live here. No entry means the logical name IS the concrete
# name — true for most things (jq, yq, gh, ripgrep, most plugins).

packages:
  jj:
    homebrew: jj
    winget: jj-vcs.jj
    apt: unavailable      # not packaged; ensure alerts, never guesses

  tailscale:
    homebrew:
      name: tailscale
      cask: true          # map form when there is more to say

  # A pinned package. Absent `version:` means `latest` (§5.1.1).
  # NOTE the homebrew entry: brew cannot select a version at install time, so a
  # pin there resolves only via a real <name>@<version> formula (§5.1.1).
  postgresql@16:
    version: "16.4"
    homebrew: postgresql@16          # the formula IS the pin
    winget: {name: PostgreSQL.PostgreSQL, version: "16.4"}
    apt: {name: postgresql-16, repo: https://apt.postgresql.org/pub/repos/apt}

  # Major-version streams are separate logical packages (§5.1.2).
  node@24:
    homebrew: node@24
    winget: OpenJS.NodeJS.LTS
  node@26:
    homebrew: node@26
    winget: OpenJS.NodeJS

plugins:
  railyard:
    marketplace: claire-local     # not on the default marketplace
  legal:
    marketplace: novotnyllc

skills:
  # Plugin-qualified names (superpowers/brainstorming) need no entry — they come
  # from their plugin. A standalone item needs one only when its source is not
  # the category default (§5.1.3).
  grilling:
    source: github:claire/grilling-skill

agents:
  triage-bot:
    source: github:claire/triage-bot-agent

hooks:
  # Plugin-delivered hooks ride the plugin's trust flow; only a standalone hook
  # from a non-default source needs an entry.
  commit-guard:
    source: github:claire/commit-guard
```

**The default rule is the whole point.** Absent an entry, the logical name is the
concrete name, resolved by that category's default source: the package manager's
own index, the fleet's default marketplace, or the owning plugin. `jq` needs no
definition and never will. `definitions.yaml` carries divergent names, install
attributes, version pins, non-default sources, and explicit `unavailable`
markers — nothing else. A fleet that never hits a divergence never creates the
file, and a missing file reads exactly like an empty one (§4's "no opinion").

**Reading is adaptive, per §4.** A scalar is the concrete name; a map is the name
plus attributes, with `name:` defaulting to the logical name. Unknown attributes
are passed through to the manager or marketplace invocation and otherwise ignored,
so a new install flag needs no reader change. An unknown *manager* key is ignored
by hosts that lack that manager — a Windows-only `scoop:` entry costs the macOS
hosts nothing.

**Why definitions sit at the store root and not in the fold.** The four layers
answer *what does this host want*; a mapping is not a want but a lookup, identical
for every host that has the manager or marketplace — so folding it would invite
hosts to "disagree" about what `jj` is, which is not a meaningful disagreement,
and would multiply four layers by the number of managers for no expressive gain.
*(Ceiling: if a genuine per-host divergence appears — two macOS hosts wanting
different taps for the same tool — that is the signal to split it into two logical
names, not to layer the definitions.)*

**Resolution at apply time.** For packages, the host's `package_managers:` list
(already in `hosts/<name>.yaml`) picks the manager; the definition — or the
default rule — yields the concrete package and its attributes. If every manager
the host has resolves to `unavailable`, the item is **held with an alert naming
the logical name and the managers tried**. Never a guess, never a silent skip.

```
vireo   package_managers: [homebrew]  ->  jj  ->  homebrew: jj
iris-windows              [winget]    ->  jj  ->  winget: jj-vcs.jj
some-debian-box           [apt]       ->  jj  ->  unavailable  => HOLD + alert
```

**The prerequisites read the same mapping.** `jj`, `jq` and `yq` are hard
prerequisites installed before the store exists (§12), and they resolve through
this same file — one mapping, one code path, no second table of "bootstrap package
names" to drift. The bootstrap reads `definitions.yaml` when there is a store and
falls back to the default rule when there is not, which is the fresh-host case.

**Definitions are items like any others, under their own namespace.** An entry is
`definitions.packages.<name>` / `definitions.plugins.<name>` /
`definitions.skills.<name>` / `definitions.agents.<name>` /
`definitions.hooks.<name>`, and gets a digest, a verdict, and apply-time review
just like desired state.

**The `definitions.` prefix is load-bearing, not decoration.** Without it,
`packages.jj` would name two different things — the desired state "enabled" and
the mapping `{homebrew: jj, winget: jj-vcs.jj}` — sharing one verdict key and one
`applied/<host>.yaml` entry, so each would clobber the other's digest and the item
would sit in permanent apply mismatch. The namespace is also what makes the
no-invalidation rule below coherent: it presupposes **two distinct verdicts**, one
for the desired item and one for the definition, which only exist if the ids
differ.

**A definition change does not invalidate verdicts on desired items that
reference it.** `definitions.packages.jj` changing does not touch the digest of
`packages.jj`, whose value is still `enabled` — so §7.2's "insensitive to which
layer supplied the value" reasoning applies unchanged. What surfaces the change is
the definition's **own** review as `definitions.packages.jj`, plus the apply-time
diff on the desired item, which shows the **concrete resolution**
(`jj -> winget: jj-vcs.jj`) rather than the logical name.

#### 5.1.1 Versions: `latest` by default, pinning is opt-in and honest

**The default is `latest` and it is never written down.** This fleet auto-updates;
`fleet-update`'s package pass keeps every unpinned package current, which is the
behaviour anyone gets by doing nothing. A `version:` key opts one package out.

```yaml
packages:
  ripgrep:
    version: 14.1.0             # applies to every manager that can express it
    apt: {name: ripgrep}
  postgresql@16:                # on homebrew this IS how you pin (below)
    homebrew: postgresql@16
    winget: {name: PostgreSQL.PostgreSQL, version: "16.4"}
```

**A pin is enforced or it is refused — never best-effort.** Where the manager can
express an exact version at install time (winget's `--version`), the pin is
applied **and `fleet-update` skips that package**, so the update pass cannot
quietly undo it. Where the manager cannot, the item is treated exactly like
`unavailable`: **held with an alert** naming the package, the manager and the
requested version. A pin that silently degrades to "whatever installed" is worse
than no pin, because it reads as a guarantee.

**Homebrew is on the refusing side, and the first draft of this clause got that
wrong.** Measured on this machine: `brew install` has **no `--version` flag`, and
`brew pin` only prevents a *later* upgrade of whatever is already installed — it
cannot select a version, so on a host that does not have the package yet it pins
the wrong thing. The draft's `terraform: {version: 1.9.8}` example was exactly the
silent degrade this clause forbids: `brew info terraform@1.9.8` →
`No available formula`.

So on homebrew a `version:` pin resolves **only when `<name>@<version>` exists as
a real formula**, which is §5.1.2's mechanism reused rather than a second one:

```
brew info --json=v2 node@24        -> EXISTS       => resolves, pin honoured
brew info --json=v2 postgresql@16  -> EXISTS       => resolves, pin honoured
brew info terraform@1.9.8          -> no formula   => HOLD + alert
```

`brew pin` is still issued **after** a resolved install, so `fleet-update` and a
stray manual `brew upgrade` both leave it alone — but it is the belt, never the
mechanism that selects the version.

#### 5.1.2 Major-version streams are separate logical packages

`node@24` and `node@26` are two logical names, each mapping per-manager to that
stream's package. Two streams coexist on one host by being two items, which needs
no version-range syntax, no resolver, and no new mechanism — the definition file
already maps names to packages, and this is just two names.

**Explicitly out of scope: language version managers and per-project versioning.**
`nvm`, `pyenv`, `rbenv`, `asdf` and friends are not managed here, and nothing in
this design tries to select a runtime per project or per shell. This system
manages **host-level packages**: what is installed on the machine. Per-project
version selection is a different problem with mature tools, and pulling it in
would trade a two-line definition for a resolver nobody asked for.

#### 5.1.3 The four agent-surface categories resolve the same way

`plugins`, `skills`, `agents` and `hooks` are all agent surface, and each of the
last three arrives in one of **two delivery forms**:

- **Plugin-delivered** — the common case today. The *plugin* is the unit of
  install, and a member is named in its plugin's namespace
  (`superpowers/brainstorming`). Resolving the plugin resolves the member, so a
  plugin-qualified name **never needs a definition of its own**.
- **Standalone** — a skill, agent or hook installed directly, with its own
  source. A bare (unqualified) name is standalone by definition.

Desired-state layers carry `plugins:`, `skills:`, `agents:` and `hooks:` maps with
the same value grammar as everything else — `enabled`, `disabled`, `absent`, or
the map form. Nothing new: these are four of the categories §4 already closes over.

```yaml
# in any layer
plugins:
  ponytail: enabled
skills:
  superpowers/brainstorming: enabled    # plugin-qualified -> rides the plugin
  grilling: enabled                     # bare -> standalone
agents:
  codex-rescue: enabled                 # plugin-qualified names work here too
hooks:
  ponytail/session-start: enabled
```

**Sources, and the zero-config default per category.** A definitions entry exists
only when the source diverges from the default:

| Category | Default source (no entry) | Definition entry says |
|---|---|---|
| `plugins` | the fleet's default marketplace | `marketplace:` (+ attributes) |
| `skills` (standalone) | a directory in a configured **skill root**; when it is a git clone, its `origin` remote is the recorded source — this is what the shipped inventory already collects, with a directory SHA-256 and `origin` as provenance | `source:` (git URL or other) |
| `agents` (standalone) | `~/.claude/agents/<name>.md`, user scope | `source:` |
| `hooks` (standalone) | a hook entry in the harness's own settings file, already under `config_files` key ownership (§5) | `source:` |

**A host's map-form override still wins.** `hosts/vireo.yaml`'s
`railyard: {state: enabled, marketplace: claire-local}` (§5) remains legal and
beats the definition. **The definition is the default source, not a lock** — which
is what keeps local development on one box possible without editing a fleet-wide
file. The same holds for a standalone skill or agent pointed at a working copy.

**Hooks get their own paragraph, because they are the highest-trust item kind.**
A hook is arbitrary code that runs on every session start. A definition can say
*where a hook comes from*; only a trust gate says whether it runs. The Codex
hook-approval step (`codex-plugin-hooks approve <plugin>@<marketplace>`) rides the
plugin trust flow rather than being a second mechanism — approving the plugin
approves its hooks, which is why plugin-delivered hooks need no separate
definition and no separate approval path.

> **The hook trust gate is RE-IMPLEMENTED against this layout, not carried, and
> until it lands the `hooks` category is HELD — not syncable.**
>
> An earlier draft deferred to "§10.6's shipped gate, unchanged". That deferral
> was unsound. Verified against the post-refactor code
> (`lib/sync-init.sh:397-405`): the shipped gate reads
> `materialized/desired/**/hooks/*.json` off `refs/heads/host/<name>` with raw
> `git ls-tree` / `git show`, and classifies on `.schema ==
> "roundhouse.sync-hook-hold"`. **Every one of those is gone here** — §12 deletes
> `materialized/`, §2 deletes the `host/<name>` branch, §14 bans `schema:`, and
> §8.4 forbids those git calls. It also never handled standalone hooks at all,
> which §5.1.3 introduces.
>
> **What the re-implemented gate reads instead:** the desired `hooks:` map and
> `definitions.yaml` **at the reviewed ref `R`** (§8.1) through the ordinary §4
> fold and `jj file show` — no status branch, no `materialized/`, no `schema` key,
> no raw git. It classifies a hook as trusted only when its resolved source is a
> plugin whose approval this host holds, or a standalone source explicitly
> reviewed on this host — and, because `hooks` is a fleet-shared layer, only a
> **durable** member could have written the desired entry at all (§7.1);
> everything else is held and reported
> `enabled_but_untrusted`, which is the one behaviour that carries over intact.
>
> **Until that gate exists in implementation, `hooks` is a held category:**
> expressible in the layers, resolvable through definitions, reviewed and
> journaled — and **never applied**. A standalone hook must never be installable
> ungated, not even transiently, and "the gate is coming" is not a gate.

**What "enable/disable" concretely means, per harness.** Marked N/A where a
harness lacks the capability rather than emulated:

| | Claude Code | Codex |
|---|---|---|
| `plugins` | install + enable/disable state | install + enable via config edit |
| `skills` | plugin-scoped and standalone skill roots, per-harness exposure | standalone skill roots only, per-harness exposure |
| `agents` | user-scope agent definitions | **N/A** — no equivalent surface |
| `hooks` | settings-file hook entries — **HELD until the re-implemented gate lands** | plugin-delivered hooks via the approval flow above — **HELD, same reason** |

**Known inventory gap, stated rather than assumed.** The shipped collector emits
`plugin`, `skill` and `skill_root` (plus runtimes and settings); it does **not**
yet emit standalone *agents* or standalone *hooks*, and `agent` in the existing
inventory means a *runtime*, not a subagent definition. So those two standalone
forms are expressible as desired state and resolvable through definitions, but
their observed-state side needs collector work before convergence can compare
them. Until it lands they behave like any unobservable item: applied and
journaled, but with no drift detection. Naming it here so it is a scheduled gap
rather than a surprise.

So every category tells the same story, and that is the point of the
rationalization:

| Category | Logical name resolves through | Zero-config default |
|---|---|---|
| `packages` | the host's package managers | the manager's own index, name unchanged |
| `plugins` | a marketplace | the fleet's default marketplace |
| `skills` / `agents` / `hooks` | the owning plugin, or a standalone source | the plugin that provides it, else the category's default location above |

One rule in several costumes: **logical name → concrete artifact, defaulting to
zero configuration, with `definitions.yaml` carrying only the exceptions.**

### `groups/development.yaml`

```yaml
plugins:
  railyard: enabled
  impeccable: enabled

skills:
  tdd: enabled
```

### `groups/canary.yaml`

```yaml
# Deliberately carries no desired state.
#
# Canary is a blast-radius label. If it also delivered software, "make this host
# a canary" would silently mean "install extra things on it". An empty document
# is "no opinion" (§4), so this file costs nothing and says something.
```

### `hosts/vireo.yaml`

```yaml
# Claire's daily driver. Renamed from macbook-pro on 2026-08-07 (see lineage/).

platform: macos
hostname: vireo.local
tailnet_name: vireo.tail1234.ts.net
user: claire
package_managers: [homebrew]
groups: [development, canary]      # left to right, last wins

plugins:
  legal: absent                    # knockout: not installed here, not just off
  railyard:
    state: enabled
    marketplace: claire-local      # map form, because there is something to say

skills:
  ponytail-audit: enabled

config_files:
  ~/.claude/settings.json:
    keys:
      permissions.deny: unmanaged  # hand-curated on this box; roundhouse keeps off
```

Not here, deliberately: no `transport`, no `ssh_alias`, no `id`, no `enrolled`,
no `schema`, no `schema_version`, no `store_path`, no `remote`. Each is either
writer-relative or ceremony.

**Also gone since rev 1, because nothing read them** (the reviewer's simplicity
audit, and it is right):

- `physical_host:` — the old spec's P1e set-membership key. No section of this
  design consumes it. The thing it was standing in for on the one box where it
  mattered is `wsl_sibling:`, below, which the apply path does read. Deleted.
- `node_key:` — "corroboration, not identity … so a rename can be *checked*". No
  doctor row, no gate and no run step ever checked it. Deleted until something
  reads it.

### `hosts/iris-windows.yaml` — the Windows host

```yaml
# The Windows box. Its store is operated by its WSL sibling (§9.2); nothing
# roundhouse runs executes on native Windows.

platform: windows
hostname: iris.local
user: claire
package_managers: [winget]
groups: [development]

wsl_sibling: iris-wsl              # the interop lane used to reach %USERPROFILE%.
                                   # Documentation for the APPLY path only. It
                                   # grants nothing: this host's evidence is
                                   # signed with a key whose principal is
                                   # iris-windows@<domain> (§9.2), so §7.3 needs
                                   # no exception and this field cannot be abused
                                   # by editing it.

plugins:
  impeccable: absent               # PowerShell lane, no browser tooling
```

### `hosts/wren/` — the same host, split because one file got long

```text
hosts/wren/host.yaml       # platform, hostname, groups, package_managers
hosts/wren/skills.yaml     # a curated 141-skill library
hosts/wren/plugins.yaml
```

Merged in filename order, then folded as layer 4. The same split is available at
`fleet/`, `os/<platform>/` and `groups/<g>/`.

### Commit descriptions — the resolver's provenance channel

Every commit roundhouse makes carries a one-line summary and a trailer block.
This is not decoration: it is the evidence a **peer's agent** reads when it has
to resolve a conflict without asking anyone (§8.2). Descriptions replicate, are
signed as part of the commit, and are readable while a merge is still conflicted
— **[rev5]** verified across the git wire and on the conflicted side.

```
bump ponytail pin v2.4.1 -> v2.5.0

roundhouse-host: vireo
roundhouse-session: scheduled/agent 01J9X2      # scheduled/agent | interactive/agent
                                                # | interactive/human | seed | revert
roundhouse-intent: adopt upstream release; changelog reviewed, no hook changes
roundhouse-items: plugins.ponytail
```

Four trailers, and each earns its place by being something the resolver cannot
get anywhere else:

- **`roundhouse-host`** — who made it. The signature proves it (§7.3); the
  trailer makes it greppable without a verification round trip.
- **`roundhouse-session`** — *what kind of actor*, which is the escalation
  discriminator. `interactive/human` on both sides of a conflict is the one case
  the agent must not resolve alone (§8.2).
- **`roundhouse-intent`** — one line of *why*. Without it a resolver comparing
  `pin: v2.5.0` against `pin: v2.4.1` has two strings and no way to tell an
  upgrade from a rollback.
- **`roundhouse-items`** — which items this commit's paths resolve to, so a
  resolver can skip commits irrelevant to the contested item.

A hand edit made outside roundhouse has no trailers. That is fine and expected:
the resolver treats a missing `roundhouse-session` as `interactive/human` — the
most conservative reading, which biases toward escalation rather than toward a
confident wrong merge.

### `journal/vireo/2026-08-07.yaml` — replicated evidence, **not** consent

```yaml
# Appended by vireo only. Nothing else writes this path, so it cannot conflict.
# EVIDENCE ONLY: item, digest, outcome, host, time. Not authorization, and not
# prose. The verdict that authorized the apply, and its reason, live in
# ~/.config/roundhouse/store.run/ on vireo and are never replicated.
- item: plugins.railyard
  digest: 4f1c9a02e8...
  outcome: applied              # applied | satisfied | held | reverted | alive
  change: qpvuntsmwlqt          # jj change id of the last commit touching a layer
  commit: 8a3f19c4bb21          # what the signature was verified against
  at: 2026-08-07T09:14:02Z

- item: skills.legal
  digest: b71e...
  outcome: held
  at: 2026-08-07T09:14:05Z

# `satisfied` is the no-op-BECAUSE-CORRECT record, and it is a distinct outcome
# from `held` so an audit can tell it from no-op-because-blocked. It is written
# when the item resolved, was reviewed, and this design has no state-alignment
# verb to run for its category (boundary B-3) — so there was nothing to do,
# here or on any other host.
- item: mcp_servers.context7
  digest: 5a7b...
  outcome: satisfied
  at: 2026-08-07T09:14:06Z

# A conflict the run's agent resolved (§8.2). This is the one replicated record
# that carries a rationale, and it is the exception that proves the rule: a hold
# reason is duplicated in store.run/, but a resolution is a fleet-affecting
# decision no other artifact records. Peers must be able to see why.
- item: plugins.railyard
  digest: 9c14ab77e2...          # the winning value
  outcome: resolved
  sides:                          # both parents, by change id
    - {change: knzkquxztzss, host: vireo, session: scheduled/agent, at: 2026-08-07T08:02:11Z}
    - {change: nzqoyoprnokz, host: wren,  session: scheduled/agent, at: 2026-08-07T08:14:47Z}
  resolution: qpvuntsmwlqt        # change id of the resolution commit; its
                                  # description carries the full rationale
  at: 2026-08-07T09:14:09Z
```

Rev 1 also published `signer:`, `layers:` and `held_reason:`. `signer:` is
self-asserted and restates in unverifiable form what §7.3 verifies
cryptographically — a field that invites someone to trust it. `held_reason:` is
the `reason:` the judges scoped *out* of the replicated record. Both moved to
`store.run/`. `layers:` stayed out too; `fleet-explain` recomputes it.

The `alive` outcome is a run-level heartbeat record with no `item`, written once
per completed run. §10.1 needs it.

### `applied/vireo.yaml` — the ownership record

```yaml
# What roundhouse actually put on this host, at what digest. This is the ONLY
# thing that makes a removal legal: an item is uninstalled because it appears
# here and left the layers. Software that never appears here is never touched.
items:
  plugins.ponytail:
    digest: 91ac33...
    at: 2026-08-06T09:14:12Z
  plugins.railyard:
    digest: 4f1c9a02e8...
    at: 2026-08-07T09:14:12Z
```

### `alerts/vireo/20260807T0914-unsigned-hand-edit.yaml`

```yaml
kind: unsigned-edit
host: vireo
items: [plugins.impeccable]
file: groups/development.yaml
change: znyskwlmrmyw
commit: 6705e1a3b501
detail: >
  Commit 6705e1a3 carries no SSH signature. Items resolved from
  groups/development.yaml are held on this host until it is signed or
  superseded. Re-signing does not require re-review: the value digest is
  unchanged.
at: 2026-08-07T09:14:31Z
```

Resolution is `rm` on the file. There is no state machine.

### `proposals/promote-ponytail-to-fleet.yaml`

The only store artifact rev 1 never showed.

```yaml
# Accept with `roundhouse fleet-accept promote-ponytail-to-fleet`, or do the two
# edits yourself and delete this file. Ignoring it does nothing.
proposes: move
item: plugins.ponytail
value: enabled
from: [hosts/vireo.yaml, hosts/iris-wsl.yaml, hosts/wren.yaml]
to: fleet.yaml
evidence: identical value on all 3 enrolled hosts since 2026-07-14
by: vireo
at: 2026-08-07T09:14:31Z
```

### `lineage/1785024000-macbook-pro.yaml` — rename **and** retirement

```yaml
event: renamed          # renamed | retired
from: macbook-pro
to: vireo
at: 2026-08-07T14:00:00Z
by: vireo
note: >
  Retirement records: if this name is ever reused for a different machine, that
  is a human decision. Read this file before reusing a name.
```

### `upstreams/claude-marketplace/vireo.yaml`

```yaml
updated_at: 2026-08-07T09:12:44Z
result: sha256:3b1f9c...
```

Fleet freshness is `max(updated_at)` across the directory. One file per host per
upstream, so the last shared mutable path in the system is gone — no lease, no
CAS, no TTL, no discard rule, nothing to contend over.

### Rendered, outside the store: `~/.ssh/config.d/roundhouse`

```sshconfig
# Generated by roundhouse from store/hosts/*.yaml. Do not edit.
# All fleet transport addresses rh-<name>. Personal aliases stay personal.
Host rh-vireo
  HostName vireo.tail1234.ts.net
  User claire
  IdentityFile ~/.ssh/roundhouse_node_ed25519
  UserKnownHostsFile ~/.ssh/roundhouse_known_hosts
```

`HostName` is `tailnet_name` when present, else `hostname`. The store carries the
*ingredients* and never an alias, which would be a name in the operator's
personal namespace. Roundhouse ensures exactly one `Include config.d/*` line in
`~/.ssh/config` and touches nothing else.

**Every value that reaches this file, or a peer URL, is validated first.**
`hostname`, `tailnet_name`, `user` and `<name>` are hand-authored by any
**durable** member (`hosts/` is a fleet-shared layer, so leaves are refused —
§7.1), so a newline in `tailnet_name` would inject arbitrary ssh_config
directives — `ProxyCommand`, `LocalForward` — into a file every fleet operation
reads, and the same fields build `ssh://rh-wren/…` for `jj git remote add`. The
shipped predicate `sync_validate_fetch_url` (`roundhouse:7090-7099`) already
states the rule — "never an option-looking, whitespace-bearing,
credential-bearing, or alternate-transport string" — and is reused verbatim on
these four fields. A match **refuses to render and alerts**; it never emits a
partial file. Rev 1 dropped this and made the exposure larger than the shipped
code's, because the values became hand-authored rather than absorbed.

---

## 6. The edit story, end to end

**Claire opens `hosts/vireo.yaml` in vim on vireo, changes `railyard: enabled`
to `railyard: {state: enabled, marketplace: claire-local}`, and saves.**

*On vireo:*

1. Nothing happens yet. `main` is untouched; `@` is the empty child the last run
   left behind.
2. The next jj command — the scheduled run, `jj status`, anything — snapshots the
   edit into `@` and **signs it** with the host's own key. There is no
   uncommitted state and therefore no "forgot to commit".
3. The run resolves the effective set from **the reconcile point `R`** (§8.1),
   normally `main` — never from `@`. The workbench is not the reviewed line.
4. **Promote gate.** The run parses every changed layer file in `@` with
   `yq -e '.'`. If they parse, it describes `@` and moves `main` to it. If they
   don't, it **refuses to promote**, alerts with `yq`'s message and line, and
   converges from the last good `main`. A broken file never becomes the reviewed
   line.

   > **Precedence, which rev 1 left ambiguous and which fires on every run
   > during an open conflict:** when the run is on the §8.2 conflicted path, the
   > promote gate is **skipped entirely** and the parse-failure alert is
   > **suppressed for any path jj reports as conflicted**. **[rev2]** a layer
   > file carrying snapshot markers fails `yq -e '.'`, so without this rule the
   > run would raise a spurious "layer file doesn't parse" alert every run,
   > pointing at a line number *inside* a conflict marker, and would pick a
   > different reconcile point and a different hold set than §8.2/§8.3. One
   > state, one answer: §8.2 wins.
5. Re-resolution finds `plugins.railyard` changed. Apply-time review shows
   provenance, not a file diff:

   ```
   plugins.railyard   groups/development.yaml  enabled
                      hosts/vireo.yaml         {state: enabled, marketplace: claire-local}  <- wins
   effective          {"marketplace":"claire-local","state":"enabled"}
   digest             4f1c9a02e8...
   signature          good — principal vireo@fleet.novotny.org == committer, change qpvuntsm
   ```
6. Verdict recorded in `store.run/verdicts/` → apply → update `applied/vireo.yaml`
   → append `journal/vireo/2026-08-07.yaml` → describe → `jj bookmark set main
   -r @` → `jj git push --bookmark main` → **`jj new <main commit>`**.

*On wren, next run:* fetch, fast-forward, re-resolve. `plugins.railyard` is
`groups/development.yaml`'s `enabled` — wren has no host-layer override, so the
change is a **no-op for wren**. The host-layer edit did not reach it. That is the
layering working.

**If she forgets to push:** there is nothing to forget — step 6 pushes, and then
nudges whichever peers it can reach (§6.1). If the network is down, vireo
converges to her edit locally and every other host picks it up on its next poll
after the network returns. No host is ever wrong, some are briefly behind.

**If she edits `~/.claude/settings.json` directly** on a key marked `managed`:
the run **reports the drift and changes nothing** — value on disk, value desired,
value in `applied/vireo.yaml`, and the two commands that resolve it either way.
A twice-daily job that silently reverts what someone typed four hours ago is the
exact surprise this system exists not to deliver. Keys marked `unmanaged` are not
compared, not reported, and not read. *(graft: gitops-reconciler §5.5, Argo's
default over Flux's)*

---

### 6.1 Propagation — how fast, and by what path

**Steady state is minutes-fresh.** An edit made on host A is applied on every
*awake* host within one fast interval. A daily cadence as the sole propagation
mechanism is the wrong design centre: "I changed it Monday, I'm on the other
machine Tuesday, it should already be there."

**Freshness target, stated so it can be missed:**

> An edit published on host A is applied on any awake host B within
> `fast_interval_minutes + fast_jitter_minutes` (default ≤ 25 min) via the hub
> alone, or **within seconds** if A can currently reach B. Items under an open
> canary gate are additionally delayed by `canary_wait_hours` — that is a
> deliberate safety wait, not propagation latency, and it applies only to
> non-canary hosts.

#### Topology: hub is the baseline, peers are opportunistic

| Path | Status | When it works |
|---|---|---|
| **Hub** (the GitHub remote) | **The universal path.** Everything converges through it eventually. | Anywhere a host has internet — including a laptop on hotel wifi with no route to any peer. |
| **Peer** (`rh-<name>` over SSH, namespaced per §8.5) | **Opportunistic accelerator.** Never assumed, never required. | When hosts can currently reach each other. Tailscale makes that usual; it is a *recommendation*, never a dependency. |

The fleet already renders SSH aliases from the registry and already uses SSH for
fleet operations, so the peer path costs no new transport, no new credential, and
no new listener.

#### (a) The poll floor — a cheap head check, not a fetch

The notification problem has no inbound answer: webhooks would require an
inbound HTTP listener on machines that mostly sit behind NAT and sleep. So hosts
poll — and the poll is made cheap enough that a short interval is not a load
question.

```sh
# the entire fast-path check: exit only if there is nothing to PULL and
# nothing to PUSH.
remote=$(git -C "$store" ls-remote origin refs/heads/main | cut -f1)
local=$( jj  -R "$store" log -r 'present(main@origin)' --no-graph -T 'commit_id')
pending=$(jj -R "$store" log -r 'present(main@origin)..heads(bookmarks(exact:"main"))' \
             --no-graph -T 'commit_id')
dirty=$( jj  -R "$store" log -r @ --no-graph -T 'if(empty,"","x")')

[ "$remote" = "$local" ] && [ -z "$pending" ] && [ -z "$dirty" ] && exit 0
```

**All three conditions are needed.** Rev 5 checked only the first, so a host with
a committed-but-unpushed edit and an unchanged remote exited immediately — its own
edit sat unpublished until the remote happened to move or the 12-hour run came
round, which breaks §6.1's own freshness target at the *publishing* end.
**[rev6]** verified all three states: fully published + empty `@` → all three
empty (true no-op); local edit committed and `main` moved but not pushed →
`ls-remote` still matches but the pending range is non-empty (`182b9d508cbc`);
pending hand edit in `@` → `dirty` non-empty. The predicate also does not error on
a never-fetched store (`present()`, per §8.4).

**[rev5]** verified: `git ls-remote` returns the remote head in a form directly
comparable to the local `main@origin` commit id, and **moves no local ref** —
before and after, `main@origin` was byte-identical. It is one HTTPS round trip
with no object negotiation and no transfer; the local work is one revset read.
The full `jj git fetch` is run **only when the ids differ**.

So the no-op cost, in full, is: *one HTTPS round trip, one string compare, exit.*
No snapshot (the working copy is untouched by a read with `@` empty), no object
transfer, no commit, no push. At a 20-minute interval that is ~72 round trips per
host per day. `fast_interval_minutes` is the knob; the floor exists so that
turning it down is a bandwidth decision, not a "will this bog the machine down"
decision.

`git ls-remote` joins `git verify-commit` as the second and last read-only git
invocation roundhouse makes (§8.4's rule is about `git push` and `git commit`,
which remain forbidden). It runs with §3.2's environment and the repo-local
hermetic pins.

#### (b) The push-nudge — optional accelerator, outbound only

After a successful push to the hub, the pushing host tells whoever it can reach:

```sh
# reachable_peers: every host in hosts/*.yaml except this one, minus any the
# last nudge could not reach within the timeout (remembered in store.run/ for
# one interval only, so a peer that comes back is retried next run).
for peer in $(reachable_peers); do
    timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=3 "rh-$peer" \
        roundhouse fleet-sync --fast &      # best effort, backgrounded
done
wait
```

`timeout 10` bounds the **remote command**, not just the connect: `ConnectTimeout`
alone leaves a peer that connects and then hangs holding the pushing host's
`wait` indefinitely.

Properties that keep this honest:

- **Outbound only.** No listener, no daemon, no inbound port, no webhook. It
  rides the SSH access the fleet already has for every other fleet operation.
- **Best effort.** An unreachable peer is skipped without an error, without a
  retry queue, and without a record. The poll floor catches it within one
  interval. A peer that is asleep, travelling, or on a network with no route is
  simply a peer that converges in ≤ 25 minutes instead of in seconds.
- **It carries no data.** The nudge says "go look", nothing more. The peer then
  runs its ordinary fast path — fetch from the **hub**, full review gates, canary,
  the lot. A nudge from a compromised host can therefore cause exactly one thing:
  an early fetch of content that is signature-gated anyway.
- **It degrades to poll speed, silently and safely.** A nudge landing while the
  peer is mid-run hits the host-local lock (§10.6) and the peer exits without
  acting — correct for a best-effort accelerator, but it means the "within
  seconds" claim above is *best case*: a busy, asleep, or unreachable peer
  converges on its next poll instead, ≤ 25 min. The guarantee is the poll floor;
  the nudge is the optimisation.
- **Genuinely deletable.** Remove the loop and the system still converges, just
  at poll speed. That is the test for whether an accelerator has earned its keep,
  and this one passes it: it is six lines and nothing depends on it.

#### (c) The traveling laptop

Stated explicitly because it is the case that kills peer-first designs: a laptop
on hotel wifi has a route to GitHub and to nothing else. It polls the hub every
20 minutes, fetches when the head moves, converges, and pushes its own edits back
to the hub where every other host will see them. **It never needs to reach a
peer, and no part of the design degrades when it cannot.** The peer lane exists
for the *hub* outage (§8.5), which is the mirror-image case.

#### The two cadences

| Run | Default | Does |
|---|---|---|
| **fast** | every 20 min ± 5, per-host jitter seeded from the name | ls-remote; on change: fetch, resolve, review, apply, journal, push. Full gates, no shortcuts. |
| **full** | every 12 h ± 90 min | everything the fast run does, plus upstream refresh, re-seed, proposal generation, doctor, the redaction sweep, **expired-leaf pruning and evidence retention** (§7.11.3). |

The fast run is the propagation path; the full run is maintenance. Splitting them
is what lets the propagation interval be short without running discovery,
doctoring and upstream fetches 72 times a day.

## 7. Integrity, signing, and binding

Four independent bindings. Keeping them separate is what makes hand editing
survivable.

### 7.1 The trust ratchet — what it is, in one paragraph

> The store carries `trust/signers.yaml`, a plain hand-editable list of which
> machine key may write. **A change to that file counts only if it is signed by a
> key the file already trusted one commit earlier** — so membership can only ever
> be extended by a current member, and the chain traces back to a genesis commit
> whose id every host pins. To add a machine, tell any machine you already have:
> "add wren". Its agent reaches wren over the same SSH lane the fleet already uses
> to run commands there, has wren mint a key, reads it back over that channel, and
> commits it to the roster. Every other machine accepts wren within one fast
> interval because it can verify the whole story from the repository it already
> fetches — **nothing is ever run on any other host, and no human touches them.**
> To remove a machine, say "remove wren": its block moves to `retired:`, its old
> commits stay valid, and its new ones stop verifying everywhere on the next fetch.

Everything below is detail on that paragraph. There is no CA, no certificate, no
authority key, and nothing anyone has to keep safe beyond the ordinary
per-machine key each host already holds.

**Why a ratchet rather than a roster read at head.** Reading the roster from the
current head is circular: the file being verified supplies the keys that verify
it, so an attacker who lands one commit replacing the whole roster with their own
key writes a commit that is self-consistent and passes. Evaluating at the
**parent** is not circular — it reads a strictly earlier point in a history whose
ordering is hash-secured. That single ordering rule is the entire load-bearing
part of this section.

#### The roster

`store/trust/signers.yaml` — hand-editable, one block per machine, two classes:

```yaml
# The fleet roster. A change here counts only if signed by a key this file
# already trusted one commit ago. Genesis is pinned in identity.yaml.
generation: 47

durable:                       # full authority; may sponsor either class
  vireo:
    principal: vireo@fleet.novotny.org
    key: "ssh-ed25519 AAAAC3Nza...OM3wmFt"
    enrolled_by: genesis
    channel_auth: genesis
  wren:
    principal: wren@fleet.novotny.org
    key: "ssh-ed25519 AAAAC3Nza...EW2hm/c"
    enrolled_by: vireo
    enrolled_at: "2026-08-07T09:00:00Z"   # QUOTED — see the yq traps below
    channel_auth: known_hosts   # genesis | known_hosts | tailscale | runtime | tofu

ephemeral:                     # leaf. Own evidence paths only. MAY NOT SPONSOR.
  build-x7f2:
    principal: build-x7f2@fleet.novotny.org
    key: "ssh-ed25519 AAAAC3Nza...9qT4vLm"
    sponsor: vireo
    job: railyard-deliver-01J9X2
    channel_auth: runtime
    valid_after:  2026-08-07T09:00:00Z
    valid_before: 2026-08-08T09:00:00Z

retired:
  corvid:
    key: "ssh-ed25519 AAAAC3Nza...gJ07"
    revoked_at_commit: 8a1f2c9e   # commits BEFORE this stay good
```

> **Two yq traps, both measured, both silent — and both live exactly here,
> because this file is the one records-shaped YAML the trust path reads.**
>
> **(a) Quote every timestamp.** **[rev11]** an unquoted `2026-08-07T09:00:00Z`
> types as `!!timestamp`; quoted, `!!str`. The type is decided invisibly by a
> quote mark, and it changes what `+` *means*: on `!!timestamp` it is **duration
> arithmetic** (`+ "24h"` → `2026-08-08T09:00:00Z`), on `!!str` it is
> **concatenation** (`→ 2026-08-07T09:00:00Z24h`). So the same expression silently
> computes either a correct soak deadline or a garbage boundary, and comparisons
> against the garbage are meaningless without erroring — which in a roster
> derivation renders as *entries quietly filtered out*, i.e. "nobody is trusted".
> **Roster and record timestamps are always quoted** (stable bytes, digest-stable,
> immune to accidental mutation), and window arithmetic is done as an explicit
> ISO-aware step rather than `+` on a bare field.
>
> **(b) An assignment inside `map()` or `(.x // {} | .y = z)` does not write what
> you think.** **[rev11]** `[to_entries | .[] | .value.y = 9] | from_entries`
> applies the assignment to **every** entry, not the selected one; and
> `(.missing // {} | .added = 1)` evaluates against a *temporary* — the output
> shows `added: 1` while the document is still `{}`. Both are silent. Roster edits
> address the entry by path (`.durable.wren.valid_before = …`), never through a
> `map()` or a `//`-defaulted sub-expression.

`enrolled_by` / `sponsor` are **cleanup metadata and nothing else** — see the
invariant in §7.3 and the lifecycle flows in §7.8. `generation:` is a monotonic
counter, §7.11's rollback defence.

**Membership class is the security boundary, not the TTL.**

| | `durable` | `ephemeral` (leaf) |
|---|---|---|
| Fleet-shared layers (`fleet/`, `os/`, `groups/`, `hosts/`, `definitions.yaml`, `lineage/`, `proposals/`) | write | **refused** |
| Own host-keyed paths (`journal/<self>/`, `applied/<self>.yaml`, `alerts/<self>/`, `findings/<self>/`) | write | write |
| Another member's host-keyed paths | refused | refused |
| `trust/signers.yaml` — i.e. sponsoring | write | **refused** |

The class is the section of the file the entry sits in, and putting it there was
itself a ratchet-valid act by a durable member — it is never self-asserted.
**"Leaves may not sponsor" is the whole anti-explosion rule:** a 40-container
burst produces 40 leaves, all at depth 1 under one durable sponsor, so chain of
custody is one hop always, with no transitive closure to compute and no cycle to
detect. It costs one refusal.

#### The verification rule

A commit `C` signed by principal `P` is accepted iff **all** of:

1. `signature.status() == "good"` — `unknown` is failure, always (§7.1a).
2. `signature.display() == committer.email()` — the equality gate, §7.3, verbatim.
3. `P` is in the roster **materialized from every one of `C`'s parents** —
   *additions gate forward.*
4. `P` is in the roster **materialized from this host's current reviewed head** —
   *removals bite backward.*
5. `P` is not in the host-local KRL.
6. `P`'s class — **read from the same roster rule 3 used, i.e. every parent's** —
   permits the paths `C` touches (table above). Reading class from the current head
   instead would let a later promotion retroactively legalise a past commit, and a
   later demotion retroactively void one.

Rules 3 and 4 are the two-sided check. **3 alone** would let a removed host keep
pushing forever by parenting its commits before its own removal. **4 alone** would
reject a legitimate newcomer on any host that had not yet fetched the roster
change — except that it cannot, because of the ancestry property below.

**"Every parent" is not pedantry — the singular reading is exploitable, and §8.2
manufactures merges as its normal path.** **[rev10]** two branches off one base,
the left still listing `mallory` and the right having removed her, with a merge
authored by mallory:

```
merge under LEFT  parent roster {alpha,beta,mallory} -> good mallory@fleet.internal
merge under RIGHT parent roster {alpha,beta}         -> unknown

any-parent   rule -> ACCEPT   <- a removed member keeps pushing forever
every-parent rule -> HOLD     <- the rule as stated
legitimate merge by an enrolled member, every-parent -> ACCEPT (ok=2 bad=0)
```

The intersection is the safe direction and **costs legitimate authors nothing**:
the ancestry property below guarantees a newcomer clones *after* its enrollment is
on `main@origin`, so every head it can merge already descends from that
enrollment. Worth stating explicitly because the natural implementation of "the
parent" is `-r <C>-`, which for a merge silently picks one.

**[rev9] verified**, the primitive the whole rule rests on: a per-commit roster
override discriminates correctly.

```
c1 (signed by alpha) under roster{alpha}        -> good alpha@fleet.internal
c2 (signed by beta)  under roster{alpha}        -> unknown
c2 (signed by beta)  under roster{alpha,beta}   -> good beta@fleet.internal
c3 (signed by alpha) under roster{beta}         -> unknown        # alpha removed
```

```sh
# EVERY parent, not `-r <C>-` — which for a merge silently picks one.
for PARENT in $(jj log -r "parents($C)" --no-graph -T 'commit_id ++ "\n"'); do
    jj file show -r "$PARENT" root:"trust/signers.yaml" > "$RUN/signers.$PARENT"
    derive_roster "$RUN/signers.$PARENT" "$(commit_time "$C")" > "$RUN/roster.$PARENT"
    jj log -r "$C" --no-graph \
       --config signing.backends.ssh.allowed-signers="$RUN/roster.$PARENT" \
       -T '…' || return 1        # ANY parent failing is a refusal (rule 3)
done
```

**[rev9]** confirmed `jj file show -r <parent>` is readable at an arbitrary
ancestor, including while a merge is conflicted. `derive_roster` is where the TTL
window, the class, and `enrolled_at` are all evaluated against **that commit's own
timestamp** (§7.1b) — never against wall clock.

#### The ancestry property — why additions have no propagation window

The enrolling commit is authored by the **sponsor**, not the newcomer, and the
newcomer clones after it lands. Therefore **every commit the newcomer ever authors
has the enrolling commit as an ancestor**, and:

> A host cannot possess a newcomer's commit without possessing the commit that
> enrolled it.

A host offline for six weeks fetches once and receives the enrollment and the work
it authorizes in the same transfer, correctly ordered by the DAG, with no
`unknown` state ever observed and no action anywhere. Enforcement is one rule:
**enrollment is not complete until the sponsor's commit is on `main@origin`** —
`fleet-add` blocks on that push and fails loudly, leaving the newcomer holding a
keypair and nothing else.

**Additions are fetch-state-independent: two hosts at wildly different fetch
positions reach identical verdicts on rule 3, because the roster it uses is a
property of the history rather than of the verifier.** Rule 4 is deliberately
*not* — it reads this host's current reviewed head, so during divergence a host
that has fetched a removal holds a commit that a host that has not will accept.
That asymmetry is the design ("removals bite backward"), it converges within one
fast interval, and it is worth stating precisely because "identical verdicts" is
the claim a reader will lean on when reasoning about split-brain.

#### Possession proof at enrollment

The sponsor watches the key being generated over the channel, which already proves
possession — but the newcomer additionally signs its own principal in a dedicated
namespace, so a sponsor cannot enroll a key nobody controls (a typo, or an
attacker-supplied blob):

```sh
printf '%s' "wren@fleet.novotny.org" | ssh-keygen -Y sign -n roundhouse-enroll -f <key>
```

`namespaces="git"` on every roster line is what keeps these two worlds apart.
**[rev9]** verified: a `roundhouse-enroll` proof offered as a commit signature is
refused with `namespace does not match`, and vice versa. One option per line, and
it stops the proof being replayed as a commit signature.

#### The identity namespace, derived rather than configured

Principals are `<node_id>@<domain>`. Setup derives the domain once, in order:

1. **The owner's own domain**, from `git config user.email`, when it is not a
   freemail provider — `claire@novotny.org` → `fleet.novotny.org`.
2. **`<github-username>.fleet.internal`** — the `gh` CLI is already a prerequisite,
   so the username is already available, and `.internal` is ICANN-reserved for
   exactly this private use.
3. **`fleet.internal`** — the last resort.

**Non-unique defaults are safe, and that is a property of the ratchet rather than
of the name.** Two unrelated fleets both landing on `fleet.internal` cannot touch
each other: trust anchors to *this fleet's roster*, which lists specific keys, and
to the genesis pin (§7.5). A principal string is a label for a key that is either
in your roster or is not; it is never itself an authorization. That is why no
uniqueness ceremony, registry, or collision check is needed anywhere.

### 7.1a Signature mechanics

**jj is the gate.** **[rev9]** with per-key roster lines (no certificates), all of
§7's mechanics hold: `signature.status()` is `good` for an enrolled key,
`signature.display()` returns the principal, an unenrolled signer is `unknown`
with an empty display, and `ssh-keygen -Y verify` refuses a key offered under
another principal.

```sh
jj -R "$store" \
   --config signing.backends.ssh.program=/usr/bin/ssh-keygen \
   --config signing.backends.ssh.allowed-signers="$RUN/roster.$C" \
   --config signing.backends.ssh.revocation-list="$KRL" \
   log -r "$C" --no-graph \
   -T 'if(signature, signature.status() ++ " " ++ signature.display(), "unsigned|-") ++ " " ++ committer.email() ++ "\n"'
```

Six rules, each traceable to a measured failure:

- **Pin the signing program on every verification.** The owner's global
  `~/.gitconfig` sets `gpg.ssh.program` to 1Password's `op-ssh-sign`, which
  rejects `-r` and takes the whole gate down. jj does not read git's key, but
  `signing.backends.ssh.program` is inheritable, so it is pinned explicitly.
- **`unknown` is a failure, never "probably fine."** This rule becomes *more*
  load-bearing here than under any authority model, because "not yet enrolled" is
  now a newcomer's normal transient state and is **deliberately indistinguishable
  from an attacker**. No provisional acceptance, no grace period.
- **Gate on exit status, never on output text.**
- **Trust roots are host-local, read fresh per invocation** — §7.7 says which file
  and who may write it.
- **A missing or typo'd KRL path returns `bad` for everything**, indistinguishable
  from mass revocation. Doctor asserts the path resolves and that a known revoked
  key fails while a known good one passes.
- **`git -c … verify-commit`, not `git verify-commit -c …`** — the latter is
  `unknown switch 'c'`.

**`behavior = "own"` keys on the commit's *author*, not its committer.**
**[rev9]** measured: a commit whose author is another host is not signed by this
host's config — the signature is stripped rather than re-attributed. The run must
therefore create its own commits under its own config; a `jj new` left over from
another identity produces an unsigned commit that then holds. This is the same
property §7.4 relies on to make cross-host rewrites fail safe.

### 7.1b Revocation, retirement, suspension, and why the KRL is not the default

**[rev9]** confirmed the trap that shapes all of this: **the KRL is retroactive
and total.** Revoking a key flips *every commit it ever made* from `good` to
`bad`, and §7.11 then holds every item resolved from every file those commits
touched. On a fleet where any durable host may edit any shared layer, revoking one
machine that way is a self-inflicted fleet outage that only a full re-commit of
every layer file clears.

So revocation lives **in the chain**, and position in history decides validity:

| Operation | Mechanism | Effect on the key's *past* commits |
|---|---|---|
| **Retire / revoke** | move the block to `retired:` with `revoked_at_commit` | **still valid** — the roster at their parent still listed the key |
| **Expire (TTL)** | `valid_before` passes; the ratchet's roster derivation filters it out | **still valid** — same evaluation point |
| **Suspend** | move to `retired:`, then re-enrol the **same key** later with a fresh window | past valid; the gap is a gap |
| **Burn history** | KRL entry, deliberately | **all invalid, retroactively** — this is the point |

**Freeze-at-expiry, freeze-at-revocation and freeze-at-suspension are one rule:
position in history.** The KRL survives solely as the emergency lever for "this
key's history is itself suspect", and its totality is a feature once it is not the
only lever.

**TTL is implemented only in the ratchet's roster derivation, filtered against the
commit's own timestamp — never as native OpenSSH `valid-before`/`valid-after` in
any file jj or ssh-keygen reads for historical verification.** **[rev9]** measured
why: native expiry is evaluated at *wall clock*, so an expired line retroactively
invalidates the node's entire signed history, and **jj has no verify-time
control** — the full signing surface is `signing.backends.ssh.program`,
`.allowed-signers`, `.revocation-list` and two GPG-only `allow-expired-keys`
knobs. `ssh-keygen -Y verify -Overify-time=…` *can* pin the evaluation instant,
but jj never passes it, and jj renders an expired line as **`unknown` with an
empty display** — identical to "not in the roster", so the failure is silent as to
cause. `signers.yaml` therefore keeps `valid_after:` / `valid_before:` as ordinary
human-readable YAML and the ratchet loop enforces them, emitting roster lines with
no time options at all.

**Backdating is the honest residual.** A commit's timestamp is inside the signed
object, so it is tamper-evident but self-asserted: a node whose window closed
could sign a commit backdated into it. The loop already walks commits in order, so
it **asserts `timestamp >= parent's timestamp`** — free, and it bounds backdating
to "no earlier than the parent", whose position is set by other members.
**[rev9]** verified the assert catches a `JJ_TIMESTAMP`-backdated commit (2020 vs
a 2026 parent). The remaining slack is acceptable **only because of the leaf
class**: a forged expired ephemeral can write nothing but its own inert evidence.
**TTL is hygiene; the class is the security boundary.**

**Lineage is cleanup metadata, never validity**, and the distinction is
load-bearing enough to be its own invariant:

> **No verification path ever reads `sponsor:` or `enrolled_by:`.** A member's
> validity is decided by exactly three things: is its key in the roster at the
> verifying commit's parent, is its class permitted to write this path, and is the
> commit's timestamp inside its validity window. **A sponsor's departure cannot
> invalidate its leaves.** Lineage answers "what should I clean up?", never
> "should I trust this?".

Auto-invalidating leaves on sponsor departure would be the retroactive-revocation
mistake a third time: one machine's removal cascading into a fleet-wide outage. In
an agent fleet sponsors are rebuilt routinely — a parent going away is a Tuesday,
not an incident — and a rebuild that silently killed forty running sandboxes would
be a failure mode the design manufactured for itself.

**Cascade survives as a default *action*, not a rule.** Told "remove vireo", the
agent's revocation commit *also* retires vireo's unexpired ephemera **in the same
commit, by default**. Same propagation, same containment — but it is now one
explicit, reviewable edit visible in the diff, and "remove vireo but keep its
sandboxes running" is simply different commit content rather than an impossible
request. Because leaves cannot sponsor, building that set is one `yq` select over
`signers.yaml`, never a graph walk (§7.10.2).

**Pruning is safe here and would not be in a snapshot model.** Any durable member
may delete `ephemeral:` entries whose window has passed, as an ordinary
ratchet-valid commit, on the existing 12 h full cadence. It cannot break history,
because an old commit is verified against the roster at *its* parent, where the
entry still exists. At 40 joins/day with a 24 h TTL pruned every 12 h the file
holds ≤ ~60 leaf lines, and `durable:` — the part a human reads — stays five lines.
If `ephemeral:` ever swamps the file, §2's existing file-or-directory valve
applies: split to `trust/signers.d/ephemeral.yaml`. No second mechanism.

### 7.2 Value digest — over the resolved value, answering *what*

```
normalize  = if type=="object" then . else {state:.} end
value_json = <resolved value> | yq -o=json -I=0 | jq -Sc "$normalize"
digest     = sha256( "<item>\n" + value_json + "\n" )
```

yq does YAML→JSON only; **jq does the canonicalization it actually can do**.

Properties, corrected against measurement:

- Insensitive to comments, key order, quoting, indentation, blank lines.
- Insensitive to **line endings**. **[judges]** identical documents saved CRLF vs
  LF give different raw sha256 and identical normalized digests. With a Windows
  editor in the fleet, byte-binding would re-review everything on a line-ending
  default.
- Insensitive to which layer supplied the value, so promoting an item from three
  host files up to `fleet.yaml` changes no digest and triggers no review.
- **Insensitive to scalar-vs-map form**, because of the `normalize` step above.
  **[rev2]** without it, `ponytail: enabled` digests `"enabled"` and
  `ponytail: {state: enabled}` digests `{"state":"enabled"}` — so §4's
  "reader's choice" polymorphism would re-review the item fleet-wide the day
  someone adds a `marketplace:` key, which is the worked example in §5 and §6.
  Rev 1 claimed they were the same item and they were not.
- **Sensitive to number form, and that is not fixable here.** **[rev2]** jq 1.8.2
  preserves literals: `{"a":1.10}` round-trips unchanged, so editing
  `cadence_hours: 12` to `12.0` re-reviews that item on every host. Rev 1 claimed
  jq normalizes number form; it does not. The consequence is one spurious review
  prompt, never a wrong apply, and the alternative (a number-rewriting pass) is
  more machinery than the harm.
- **YAML 1.1 coercion happens before the digest and is visible in it.**
  **[rev2]** `0755` → `755`, `yes` → `"yes"`, `on` → `"on"`. Quote anything where
  the literal form matters. Doctor's fixture digest exercises all three.

**A digest mismatch means re-review, never reject-forever.** *(dotfiles-native)*

### 7.3 Principal — the equality check, answering *which machine*

**What is already true, structurally** — **[rev9]**, OpenSSH_10.3p1, with per-key
roster lines:

- A key offered under another principal is refused:
  `ssh-keygen -Y verify -I wren@…` against a vireo-signed payload → exit 255.
- An unenrolled key is refused outright.
- `-Y find-principals` derives the principal from the signature alone.

Per-key lines therefore bind the principal *natively*, which a wildcard authority
line never did. The equality gate is now belt **and** braces rather than the only
strap — and it is still required, because a valid roster key can still author a
commit claiming another host's identity.

**The gate:** `status == "good"` **and** `signature.display() == committer.email()`.
**[rev9]** verified against impersonation: a commit signed by wren's key with
committer `vireo@…` renders `good [wren@…]` vs committer `vireo@…` → **HOLD**.

**Which identity each path requires** — the table gains one column, membership
class, rather than a new mechanism; the enforcement point is the same post-verify
comparison:

| Path | Required identity | Class required |
|---|---|---|
| a layer file (`fleet/`, `os/`, `groups/`, `hosts/`), `definitions.yaml`, `lineage/`, `proposals/` | any `<h>@<domain>` in the roster at the parent | **durable** |
| `trust/signers.yaml` | any `<h>@<domain>` in the roster at the parent | **durable** |
| `journal/<h>/`, `applied/<h>.yaml`, `alerts/<h>/`, `findings/<h>/`, `upstreams/*/<h>.yaml` | **exactly `<h>@<domain>`. No exception, for any host.** | either |
| `joins/<h>.yaml` | any signer, including `unknown` — **inert, never applied** (§7.5B) | n/a |

Row 3 has no exception, and that is load-bearing: it is what gives the canary gate
its integrity and makes forged peer evidence inert, and it is why an ephemeral leaf
slots into the canary/journal machinery with no changes to it — a leaf cannot forge
anyone else's evidence.

Doctor asserts the check rejects: it mints a commit whose committer says one host
and whose signature says another, and requires a `hold`.

**The hold message branches on `status` first.** Four distinct messages —
`unsigned`, `signature <status>`, `identity mismatch: signature says X, commit says
Y`, and `not in the roster at this commit's parent` — because the last is the
newcomer/attacker case and rendering it as an identity mismatch points the operator
at the wrong thing.

> **Declared judgment call: any *durable* member may edit any fleet-shared layer,
> including `hosts/<other>.yaml` and the roster itself.** Scoping host files to
> their own host was considered and rejected: the shared layers must stay open —
> that is what lets the owner edit fleet intent from whichever machine they are at —
> and `fleet.yaml` is strictly *more* powerful than any host file, so the scoping
> would add exceptions while reducing blast radius from "everything" to
> "everything". Containment is elsewhere and specified: the class boundary, the
> soak, store identity (§7.5), apply-time review on the *receiving* host, the canary
> gate, `max_removals_per_run`, and revocation. The **ephemeral** class is the real
> scoping, and it is where the churn is.

### 7.3a Enrollment, removal, and genesis — all agent-executed

**The authority root, stated plainly before the mechanics.**

> **Authority = custody of the owner's GitHub account × integrity of the
> instruction chain.**
>
> There is no human-held secret, no fingerprint glance, and no verification step
> anywhere in this design. What authorizes enrolling a machine is that *some agent
> session that was told to do it* executed the enrollment with credentials it
> already holds. Two things, and only two:
>
> 1. **GitHub account custody.** The store is a private repo; only the owner's
>    credential can create, find, clone or push to it. That is the outer boundary
>    on who participates at all.
> 2. **Instruction-chain integrity.** Whichever session was told "set up the fleet"
>    or "add wren" carries the authority, whether the instruction came from the
>    owner typing it or an orchestrator relaying it.
>
> Everything else here — the ratchet, channel binding, soak, alerts, lineage
> cascade — **bounds what a compromise of those two can do and how fast it is
> noticed. None of it replaces them.** An agent that is prompt-injected into running
> "add attacker-box" enrols an attacker, and no cryptography here detects that,
> because from the store's point of view it is indistinguishable from the owner
> asking. **The trust model secures the wire, not the intent.** That is the bottom
> of the stack and it is not dressed up anywhere in this document.

**The channel is one the fleet already trusts completely.** §6.1's push-nudge runs
`roundhouse fleet-sync` on peers over SSH; `fleet-inventory` and `fleet-update` run
commands on every host. The fleet already grants SSH-to-a-named-host full code
execution, so enrollment over that channel introduces no new trust assumption — and
the converse is the argument: if SSH-to-wren is compromised the attacker already
owns wren, so enrolling their key changes nothing about their power *over wren*,
only about their power over the fleet, which is exactly what soak and lineage
cascade bound.

Enrollment is two-sided and needs no bearer credential: an **enrolled host** supplies
authorization (its roster key makes the commit ratchet-valid), and the **channel**
supplies identity binding (the key was generated on, and read back from, a machine
that host could reach at the name the instruction gave). Neither side alone enrols.

#### Genesis — no human at the first machine either

```
agent on vireo, told: "set up the roundhouse fleet store"

  gh repo create claire/fleet-store --private
  mint ~/.ssh/roundhouse_node_ed25519            (vireo@fleet.novotny.org)
  write trust/signers.yaml listing that key, self-signed   (generation 1)
  jj git init --colocate; fleet-init; push genesis

  store_id  = <the genesis commit id>
  remote    = git@github.com:claire/fleet-store.git
```

`store_id` **is the genesis commit id** — an *output* of setup, reported upward to
the orchestrator or into the session transcript, never an input a human pastes.
From then on it is ordinary data travelling down the instruction chain, or read back
over the SSH channel from an enrolled host. This strictly improves on a minted
token: an attacker who *knows* your `store_id` still cannot produce a store with
that genesis, so the pin is **unforgeable rather than merely secret**.

The genesis roster is self-signed, which is fine because there is no counterparty at
genesis to fool. One check: **the genesis roster must list the key that signed it**;
a genesis listing anyone else is refused.

#### A. Told on an enrolled host — "add wren" (the normal case)

```
agent on vireo, told: "add wren to the fleet"

  1. resolve `wren` -> tailnet, else ~/.ssh/config, else hosts/*.yaml, else DNS
  2. ssh wren -> host key in roundhouse_known_hosts   => channel_auth = known_hosts
                 else reached over the tailnet           => channel_auth = tailscale
                 else FIRST CONTACT, key unknown         => channel_auth = tofu
                      (proceeds — §7.12.4 — but takes the 72 h soak and a
                       distinct alert class naming tofu on every host)
  3. over that channel: install jj/jq/yq via definitions.yaml default rule;
     roundhouse fleet-init; mint ~/.ssh/roundhouse_node_ed25519
  4. read the pubkey + roundhouse-enroll possession proof back over that channel
  5. hand wren the remote URL + store_id over that channel      <- data, not paste
  6. commit wren into trust/signers.yaml, generation++, signed by vireo; push
  7. wren clones, checks genesis == store_id, ratchets to head, sees itself
     enrolled, starts syncing

Nothing was run on any other host. No human touched any other host.
```

#### B. Told on the newcomer — "join my fleet" (the fallback)

```
agent on wren, told: "join claire's fleet"
  1. gh auth present -> locate + clone the PRIVATE store     <- credential possession
  2. verify genesis == store_id
  3. mint key; write joins/wren.yaml {pubkey, proof, reachable address}; push
     (this commit signs as `unknown` — wren is not trusted, and that is correct)

any enrolled host, next fast run:
  4. sees joins/wren.yaml. DOES NOT TRUST IT.
  5. SSHes to the address; confirms the same pubkey is present on that machine
  6. commits wren into the roster; push
  7. unreachable? hold the request, alert, retry next run
```

**B reduces to A.** The hub proves credential possession and carries notification;
SSH proves the key belongs to a reachable machine actually running roundhouse.
`joins/` is **inert by construction** — never applied, only read as a hint — so an
`unknown`-signed commit landing there is harmless, which is why §7.3's table gives it
its own row. **The hub is the outer boundary and never the authorization:** if
hub-push alone could enrol, a stolen token would escalate from "noisy nuisance" to
total compromise. Today a stolen hub credential yields disclosure plus bounded
rollback/DoS attempts and no ability to write desired state, and that property is
worth keeping.

**Known limit, not papered over:** a newcomer behind NAT with no tailnet that no
enrolled host can reach stalls at step 7, and the answer is flow A. No NAT-traversal
path is proposed.

#### C. Told anywhere — "remove wren"

```
agent on any enrolled host, told: "remove wren from the fleet"
  1. move wren's block to retired:, revoked_at_commit = <current head>
  2. lineage cascade: retire every key wren sponsored (one grep — leaves can't sponsor)
  3. generation++, commit, push
  4. delete hosts/wren.yaml; append the lineage/ retirement record (§9.1)
  5. KRL: NOT by default. Only when the instruction is "burn its history too."

every host, next fetch (<=25 min, no per-host step):
  wren's FUTURE commits verify against a roster-at-parent that no longer lists it
    -> unknown -> held
  wren's PAST commits verify against rosters that DID list it -> still good
```

#### D. Ephemeral leaves — "run job X in a clean sandbox"

The highest-volume flow, and deliberately not a variant of A or B: a sandbox is not
*discovered* over a channel, it is *instantiated* by its sponsor.

```
  1. sponsor creates the container / VM / sandbox
  2. hands it, over the runtime boundary it just created:
       remote URL, store_id, a freshly minted node key    => channel_auth = runtime
  3. commits the leaf: ephemeral, sponsor=vireo, job=X, valid_before = now + TTL
     (one commit, no soak, no page)
  4. container: full clone, verify genesis == store_id, ratchet genesis -> head
  5. operates OFFLINE for the whole job — a complete clone is a complete peer
  6. pushes evidence to journal/<self>/, applied/<self>.yaml, findings/<self>/
     — host-keyed, single-writer, cannot conflict
  7. discard. Entry ages out; the next 12 h prune removes the line.
```

**`channel_auth: runtime` is the strongest binding in the system** — stronger than
`known_hosts` or `tailscale` — because the sponsor did not *find* this node, it
instantiated the process namespace. There is no first-contact window to MITM. A
containerized member with its own complete clone and no host mount is a first-class
member, and that works **because the design has no primaries: every copy is
complete.**

#### Soak and alerting, by class

| `channel_auth` | Soak before fleet-layer writes land | Alerting |
|---|---|---|
| `genesis` | **none** | n/a — there is no fleet to alert yet |
| `known_hosts` / `tailscale` / `runtime` (durable) | 24 h | page-level, every host, leads the recap |
| `tofu` (durable) | **72 h** | page-level + a distinct class naming `tofu` |
| any (ephemeral leaf) | **none** — leaves cannot write fleet layers at all | audit trail only (journal record) |

**`genesis` takes no soak, and that is not an exemption to argue about — it is the
only coherent value.** Host 1 *is* the fleet at that moment; if its own key soaked
for 24 h it could not seed the very layers the instruction that created it told it
to seed, and there is no second member for the delay to protect. The soak exists
to bound a *newly added* key's authority against the members that predate it, and
at genesis that set is empty.

The policy falls out of the class rather than being a knob: a class that cannot
write fleet layers has nothing to delay, and paging on 40 enrollments a day trains
the owner to ignore the one that matters. The soak makes the enroll-then-write race
**strictly worse for an attacker than not enrolling at all** — writing as the
compromised host lands in 20 minutes, writing as a freshly enrolled key lands in
24 h — and it costs a real new machine nothing, because a real new machine is not
editing fleet policy on its first day. Evidence paths are live immediately, so the
newcomer converges, applies and reports at once; it just cannot change fleet policy.

**`enrolled_at` is what makes the soak evaluable, and it is derived per-parent
like the class.** The soak window is measured from the `enrolled_at` in the roster
**at the verifying commit's parents** (§7.1 rule 3), against that commit's own
timestamp — never from the value in the roster at head, and never against wall
clock. An attacker who edits their own `enrolled_at` to backdate it is writing a
roster change, which is itself subject to the ratchet and lands in a *later*
commit; the parents of their earlier commits still carry the original value. So
**a member cannot shorten their own soak window**, for the same structural reason
they cannot promote their own class.

**Every roster change alerts on every host, always, and leads the recap.** On a
five-host fleet this is a two-to-three-times-a-year event. If it fires and the human
did not just ask for a machine to be added, that *is* the compromise notification,
and it fires within one fast interval.

### 7.4 Change ID — gated only for verdict validity; re-signing is still free

The journal records the jj **change ID** of the last commit touching any
contributing layer, alongside the commit ID that was signature-checked.

When an unsigned commit is re-signed **by the host that authored it**, jj
rewrites it: change ID stable, commit ID new, content identical. **[rev5]**
verified directly: `jj sign -r <rev>` took `a23c5484` → `f8c8ca9d` while the
change ID `zxyvorrs` was unchanged, and the signature went `unsigned` → `good`.
The value digest is unchanged, the recorded verdict still binds, and **the item
applies without re-review.**

**The change ID stays evidence, not a gate.** Rev 5 briefly made verdict
validity depend on the introducing change ID matching, to force reverts to be
re-reviewed. That broke two things at once and has been withdrawn:

- **[rev6]** measured: **promotion keeps the digest and changes the change ID.**
  Moving `plugins.ponytail: enabled` from `hosts/vireo.yaml` up to `fleet.yaml`
  left the digest input byte-identical (`{"state":"enabled"}`) while the
  introducing change went `vztuxprvlvvk` → `qmmxsllwvtqm`. So the gate would have
  re-reviewed **every promotion on every host**, breaking §7.2's chosen property
  ("promoting … triggers no review anywhere") and the §10.2 feature built on it.
- The recorded change is *the last commit touching any contributing layer* — per
  **file**. §8.2's resolution commit rewrites the whole file, so one resolved
  conflict in `groups/development.yaml` would have re-reviewed every item that
  layer contributes, on every host in the group. That is exactly the group-layer
  amplification §8.3 exists to eliminate, reintroduced at the verdict — and §8.2b
  makes conflicts routine, so it would have fired often.

§10.8 achieves the same end with a narrower predicate that needs no change ID at
all, so both defects are deleted rather than mitigated. Fixing a signing mistake is not a security event; making it cost a
review is how you train an operator to click through prompts.

**What rev 1 did not say:** a rewrite by a *different* host is not free.
**[rev2]** with per-host identities (§3.1), a rewrite of a foreign-authored
commit **strips** its signature rather than re-attributing it — `behavior = "own"`
declines to sign what it did not author. The descendants are rebased and lose
their signatures too. So any `jj describe`, `jj rebase`, `jj abandon` or
`jj squash` touching another host's commits converts them to unsigned, and every
affected item is **held** until the authoring host re-signs or the content is
superseded. That is loud, recoverable, and correct — and it is the reason the
runbook in §8 confines rewrites to commits this host authored, with one named
exception (the §8.2 squash, which targets a merge this host just created).

*One sharp edge:* two hosts independently re-signing the same commit makes the
change **divergent** — one change ID, two commits. Treated exactly like a
conflict: hold the contributing items, alert with both commit IDs, converge
everything else.

### 7.5 Store identity — the genesis pin

`store_id` is **the genesis commit id** — or, after a re-root, the id of the
checkpoint a host started from (§7.11.1). It is compared at clone, at
`fleet-init` against an existing `main@origin`, and whenever the remote URL
changes.

**It is unforgeable rather than merely secret.** A minted token could simply be
*contained* by a hostile store; a genesis commit id cannot be, because producing a
store with that genesis means producing that commit. An attacker who knows your
`store_id` still cannot substitute a store for it. That is a strict improvement
over a token, and it costs nothing — the value was already being carried.

**It is data, not a human step.** Genesis produces it as an *output*, reported
upward to the orchestrator or into the session transcript; from then on it travels
down the instruction chain, or is read back over the enrollment channel from an
enrolled host (§7.3a A step 5). A human pasting it is one of several ways that
datum can travel, never a required one.

**[rev9]** `jj git clone` performs no check whatsoever on remote content — a clone
of an unrelated repository succeeds silently — so this comparison is the only thing
standing between the fleet and a foreign store. Two roundhouse fleets pointed at
one remote would otherwise share one `hosts/vireo.yaml` path between two different
machines and the gate would accept both.

One additional genesis check: **the genesis roster must list the key that signed
it.** A genesis listing anyone else is refused.

**The honest residual:** a compromised orchestrator can hand a joining agent the
wrong `store_id`, and that agent joins the wrong fleet. That is instruction-chain
integrity (§7.13 residual 1), not a gap in the trust model, and it fails loudly —
the machine simply never appears in the real fleet.

### 7.6 Where the verdict lives

`~/.config/roundhouse/store.run/verdicts/<item>.yaml` — **host-local, never
replicated.**

```yaml
item: plugins.railyard
verdict: pass
reason: marketplace claire-local already trusted; state unchanged from group layer
digest: 4f1c9a02e8...
change: qpvuntsmwlqt        # provenance only, never a gate (§7.4). The apply
                            # gate matches the DIGEST, plus §10.8's revert-
                            # signature predicate.
reviewer: agent             # agent | human — the run's driving agent reviews by
                            # default; a human reviews in supervised sessions and
                            # on escalations (§8.2b rules 2, 5-6).
signer: vireo@fleet.novotny.org
layers: [groups/development.yaml, hosts/vireo.yaml]
decided_at: 2026-08-07T09:13:58Z
```

The chassis published this at `verdicts/<host>/<date>.yaml` and all three judges
named it as the one thing that must not survive: it puts a consent-shaped
artifact on a fleet-writable surface and then needs prose to say it is not one.
The canary gate needs the **evidence** (item, digest, outcome, host, time), which
is what `journal/` carries.

### 7.7 When a hand edit breaks an expectation

| What happened | What the run does |
|---|---|
| Layer file doesn't parse | Refuse to promote `@`→`main`. Alert with `yq`'s message and line. Converge from last good `main`. *Suppressed on the §8.2 conflicted path (§6 step 4).* |
| Duplicate YAML key | Last wins; doctor flags it. Odd shape, not a security event. |
| Unknown category or unrecognised layer directory | Every item under it held + alerted by name. |
| Unknown field inside a known item | Ignored. Cannot under-converge. |
| Unsigned / `unknown` / revoked / **principal ≠ committer** / not in the roster at every parent | Hold **only the items resolved from files that commit touched**. Everything else converges. Alert names file, change ID, both identities. |
| **Class refusal** (rule 6: a leaf touched a fleet-shared layer) | Narrower: hold **only the items whose values that commit changed — additions, edits and removals alike** (§7.13 residual 7). Computed by the same per-revision value comparison §8.3 uses — fold each side, diff the resolved values — with the two sides here being the commit and its parent, not §8.3's two heads. The content parses and the signature is good, only the authority is wrong, so there is no reason to distrust the untouched items. |
| **Signature stripped by another host's rewrite** | Same row as unsigned — held, alerted, recovered when the authoring host re-signs. §7.4. |
| Signed by an enrolled key, value you didn't expect | Applies. The gates are apply-time review on the host where it lands, plus canary. |
| Conflicted file | Hold only items whose value differs across heads (§8.3). Converge the rest. |
| Divergent change on a layer file | Same as a conflict. |
| Item disappears from the layers | Removal path (§10.3), never the parse-failure path. |
| Cannot read the source at all (fetch fails, file unreadable) | **Converge from last known. Never prune.** Distinct code path. |
| A field that reaches ssh_config or a peer URL fails validation | Refuse to render, alert. §5. |

The unifying rule: **a bad edit narrows what is applicable; it never breaks the
store and never blocks unrelated items.** Every failure is item-scoped.

---

### 7.8 Lifecycle — reparenting, suspension, reconstitution

All three are ordinary ratchet-valid edits, all agent-executed, and all cheap
**because sponsorship is not validity** (§7.1b's invariant).

**A. Reparenting.** An *orphan* is an `ephemeral:` entry whose `sponsor:` no longer
appears in `durable:`. Any durable member may adopt orphans, in the same commit
that retires the departing sponsor:

```
one commit:  vireo -> retired: {revoked_at_commit: <head>}
             orphans of vireo -> sponsor: wren      # adopted by the acting host
             generation++
```

No coordination, no election, no race that matters: two hosts adopting the same
orphans produce a value-level conflict in one YAML field, which §8.3 already holds
and §8.2b's agent resolves from the commit descriptions. **Reparenting is safe to
be unilateral precisely because it is cosmetic to the security model** — it keeps
the cleanup queries answerable and nothing else depends on it.

**B. Suspension.** A stopped container is not a security event and must not become
one.

```
t0      leaf enrolled, valid_before = t0+24h
t0+3h   container stopped.  Nothing happens.  No alert, no hold.
t0+24h  window lapses.  FREEZE: every commit it already made stays `good`,
        because each verifies against its own roster-at-parent.
t0+90d  restarted.  Renewal by any durable member:
          entry survived pruning -> valid_before = now + TTL     (one field)
          entry was pruned       -> re-add the SAME key          (one block)
```

**Identity continuity is free because the key never changed** — same principal,
same key, same historical commits still verifying. Whether the entry survived
pruning changes only whether the edit is one field or one block, which is why no
tombstone mechanism exists: the two cases are already the same operation.
Re-adding a pruned key is a fresh enrollment and takes the ordinary channel
binding — for a container that is `channel_auth: runtime`, the strongest class.

**C. Reconstitution.** New hardware means a new key, correctly. One commit:

```
one commit:  lineage/<ts>-vireo-rebuild.yaml     # §9.1's EXISTING ledger
             durable.vireo -> new key, new channel_auth, enrolled_by: <actor>
             old entry     -> retired: {revoked_at_commit: <head>}
             orphans of old vireo -> sponsor: vireo    # reparent to the new entry
             generation++
```

The old key's history stays valid, the new key starts clean, and **the orphans
never lapsed at any point during the rebuild** — the payoff of the invariant.
`lineage/` is reused, not invented: §9.1 already defines it as the permanent
rename/retire ledger, and a rebuild is a rename with a key change.

### 7.9 Local materialization and tamper posture

**What jj and ssh-keygen actually read** — never the working copy. Reading
`trust/signers.yaml` straight from the checkout would be the naive version of this
model and it is broken: the file being verified would supply its own verification
keys.

| Artifact | Path | Owner/mode | Written by |
|---|---|---|---|
| Steady-state roster | `/usr/local/etc/roundhouse/allowed_signers` | `root:wheel 0644` | `roundhouse-trustd`, via the existing privileged lane |
| Per-commit roster | `store.run/roster.<commit>` | `claire 0600`, unlinked at run end | the run, for the ratchet only |
| High-water mark | `/usr/local/etc/roundhouse/reviewed-ref` | `root:wheel 0644` | `roundhouse-trustd` |
| **Generation high-water mark** | `/usr/local/etc/roundhouse/generation` | `root:wheel 0644` | `roundhouse-trustd` |
| KRL | `/usr/local/etc/roundhouse/krl` | `root:wheel 0644` | `roundhouse-trustd` |

**`generation` gets the same custody as `reviewed-ref` because it does the same
job.** It is the other half of the rollback defence (§7.11.2 step 6, §7.12.3), and
custody is the whole of its value: **in the store it is attacker-controlled by
construction** — the attacker is force-pushing history, so they write the
generation too — and in user-writable `store.local/` it falls to exactly the shell
compromise root ownership exists to survive. Same lane, same degrade-and-report
behaviour, same doctor row.

**The update path.** The run replays the ratchet unprivileged, computes the roster
at the new head, and calls `roundhouse-trustd apply` — a small root helper whose
entire job is to **re-derive the roster from the store independently**, refuse if
`generation` went backward, refuse if the new head is not a descendant of
`reviewed-ref`, then write atomically. **The helper does not trust the run's
output; it recomputes it.** That is what makes root ownership mean something
rather than being decoration.

**The position, argued honestly.** A same-user-writable roster makes every trust
model equivalent to no model: an attacker with the user's shell appends their key
and the host accepts anything. But that same attacker already holds
`~/.ssh/roundhouse_node_ed25519`, because the signing key must be readable by the
process that signs — **they do not need to self-enrol, they are already this
machine.** Root ownership therefore does not prevent the attack. It prevents
something narrower and genuinely valuable: **persistence past revocation of the
compromised host.** Revoke vireo and, with a root-owned roster, the attacker's
locally-appended key never existed anywhere else and vireo's own copy is corrected
on the next `trustd apply`. With a user-owned roster, vireo keeps trusting the
attacker after revocation — and vireo is exactly the machine you were cutting off.

**Where the privileged lane is not configured, degrade to same-user and alert.** A
seamless setup with a named, reported weakness beats a hard stop; the "easy setup"
constraint outranks the hardening. Windows uses
`%ProgramData%\roundhouse\allowed_signers` with an ACL denying the interactive
user write. **If the user has passwordless sudo, root ownership collapses to
same-user** — doctor *reports* this rather than failing on it, and the docs must
not imply protection that is not there.

**And take detection too, because it is nearly free and fails in a different
direction.** Every run and every `fleet-doctor` compares the materialized roster
against the roster the ratchet derives **from the reviewed ref — never from the
head being adopted.** That distinction is the whole usability of the check:
comparing against the head would flag *every legitimate roster change* as drift,
since the materialized file is by construction one ratchet step behind until
`trustd` advances it. The reviewed ref is the state this host has actually
verified, so a mismatch means the file was changed by something other than
`trustd`. A mismatch is a
**loud alert and a full hold**, not a repair. One `sha256` compare, no privileges,
and it catches the case ownership misses entirely: an attacker who *does* get root.

**`roundhouse-trustd` threat model, stated plainly.** The helper (`scripts/
roundhouse-trustd`, `apply <store> <reviewed-rev>`) **defends** exactly one
thing: **persistence past revocation** of a compromised host. The local trust
files the host reads at verify time — roster, `reviewed-ref`, `generation`, KRL —
are same-user writable on the degraded rung, so a process holding this host's
signing key can locally truncate the KRL or edit the roster to **un-revoke its
own key after the fleet has revoked it**. trustd writes those files root-owned, so
the un-revocation does not survive the next `apply`. It **does not defend entry**:
the attacker already holds `~/.ssh/roundhouse_node_ed25519` and *is* this machine —
root ownership buys persistence protection only, never a substitute for revoking
the key in the roster. And **invoking trustd cannot inject a hostile roster**:
it is root-invoked but trusts none of its same-user arguments — its only trusted
inputs are the signed jj history and the genesis pin. It re-derives the roster the
way the read path does, replaying the ratchet from its own **root-owned**
`reviewed-ref` (or the genesis pin, on first apply) up to the adopted revision and
holding any commit that does not verify against the roster at its own parents; a
working-copy roster edit signed by a key the parent did not trust never
materializes, and a rewound head fails the descendant and generation gates because
those high-water marks are root-owned and the attacker cannot move them.

> **Install and the degraded rung.** trustd is installed **root-owned via the same
> one-time consented privileged step that installs the POSIX broker** — the
> `enroll-privilege-posix install-trustd` lane, a deliberate setup action run once
> as root, never interactive sudo in the unattended run path. The lane roots a
> single prefix `/usr/local/libexec/roundhouse-trustd/` holding the **binary**, the
> **`roundhouse` library and `lib/` tree it sources**, and a **pinned toolchain**
> (`toolchain.d/{jj,yq,jq}` copied root-owned, recorded in `toolchain`); it seeds
> `<TRUST>/krl` root-owned from the enrollment-time KRL (residual 2 — never
> whatever same-user file is present at first root); and it installs the
> `NOPASSWD:NOSETENV` sudoers entry the run uses to reach root. The run then invokes
> trustd through **`env -i … sudo -n`** — an explicit minimal environment, the
> store and rev as the only arguments — so nothing the caller sets reaches the root
> process; trustd additionally re-establishes each trusted input itself (it ignores
> `ROUNDHOUSE_TRUSTD_HOME` off the self-check, verifies the sourced tree and each
> pinned tool root-owned before use, and replaces rather than appends PATH), so the
> two layers fail independently. Until `install-trustd` has run the resolver reports
> no privileged lane and both the run and `fleet-doctor` report **same-user custody**
> every time (residual 5) rather than assuming the stronger posture; the digest
> compare above still runs and carries the weight meanwhile. Root ownership of the
> helper binary **and of the library/toolchain it sources** is load-bearing: a
> same-user-writable trustd is trustd defeated, so `fleet-doctor` asserts the whole
> prefix's ownership. And because a host that was ever privileged writes a
> root-owned `<TRUST>/privileged` marker, `fleet-doctor` distinguishes a host that
> **never had a lane** (OK, seamless) from one **forced back to same-user custody**
> by an attacker who unlinked the binary (a FINDING — residual 7).

**Explicitly not taken:** immutable flags, a separate service account, TPM/Secure
Enclave key storage. Each is real hardening and each costs more than the marginal
risk at this scale. The upgrade trigger is the one §7.3 already names: a second
human.

### 7.10 jj capabilities this leans on — verified on 0.44

#### 7.10.1 Trust-history immutability is free, via **tags**

**[rev9]** jj 0.44's default is
`builtin_immutable_heads() = 'trunk() | tags() | untracked_remote_bookmarks()'`,
so a git tag on a checkpoint commit makes it **and all its ancestors** immutable
with zero configuration:

```
git tag rh-checkpoint-1 <commit>; jj git import
jj log -r <commit>  -T 'immutable'   -> YES
jj describe -r <commit> -m tamper    -> Error: Commit … is immutable
jj log -r <ancestor> -T 'immutable'  -> YES     # protection reaches back
```

**A bookmark does not do this** — **[rev9]** and **[rev10]** on properly isolated
sibling commits, the same rewrite succeeded. That distinction is the whole finding:
**checkpoints are tags.**

**Scoped honestly, though: most of the protection is already there without any
tag.** `builtin_immutable_heads()` includes `trunk()`, so **every ancestor of
`main@origin` is immutable already** — which in steady state is all of enrollment
history. The tag's marginal contribution is protection for checkpoint commits
*outside* main's ancestry, and it is not load-bearing against a hub attacker: tags
are ordinary hub refs, deletable with the credential §7.12.5 contemplates and
absent from any clone taken afterwards. **[rev10]** a fresh clone does inherit hub
tags, and hub-side deletion does not strip an already-local tag. So: cheap, worth
having, and not a control anything else depends on.

**The TOML gotcha, if the alias is ever set explicitly:** the key must be quoted or
`jj config set` rejects it — `revset-aliases.immutable_heads()` is an invalid
unquoted TOML key, `'revset-aliases."immutable_heads()"'` works. It fails loudly
here only because parens are invalid TOML; a subtly wrong *revset* would not.
Rely on the tag default; set the alias only if a live bookmark ever needs
protecting.

#### 7.10.2 Revsets answer one of the two graphs, and only one

| Question | Graph | Tool |
|---|---|---|
| "what did this leaf write?" / audit range since enrollment | the **commit DAG** | revsets — `descendants(<enrollment commit>)`, `<checkpoint>..head` |
| "what did vireo sponsor?" / teardown set for job X | the **sponsor graph in YAML** | `yq` select over `signers.yaml` |

**The sponsor graph is not in the DAG and revsets cannot query it** — and it does
not matter, because the no-transitive-sponsorship rule makes that graph exactly one
hop deep, so every lineage question is a one-hop `yq` select, never a traversal.
Revsets earn their place on the other question only.

#### 7.10.3 Sparse workspaces are ergonomics, not a security control

**[rev9]** verified: `jj sparse set --clear --add trust` materializes only those
paths, **and history stays complete** — `jj file show -r <commit> <non-sparse path>`
still returns content, and the full log is present. So a leaf materializes only its
own host-keyed paths plus the layers that apply to it, while holding the entire
chain it needs to verify.

Limits, stated rather than implied:

- Sparse is a **working-copy** feature. It reduces materialization and snapshot
  cost, **not clone size or history size** — the objects are all still there. The
  lever for bounded repo growth is §7.11, not this.
- It is therefore an ergonomics and blast-radius nicety, **not a security
  control.** The security control is the membership class, enforced at verification
  on every *other* host, which does not depend on the leaf's local config at all.
- It is per-workspace local state, not replicated, and needs setting on each leaf —
  one line in the bootstrap that already mints the key.

### 7.11 Checkpoints, re-root, and three aging policies

Nothing may grow indefinitely. Three things would: the roster, the evidence
records, and the history. Each gets its own lever, and they are **deliberately
separate** because they answer different questions.

#### 7.11.1 The checkpoint

An ordinary commit containing one file:

```yaml
# checkpoints/1785024000.yaml
generation: 412                  # carried forward — monotonicity survives a re-root
covers_through: 8a1f2c9e
prior_checkpoint: 3f9b1d02
roster_digest: sha256:4f1c9a...  # the derived roster at covers_through
state_digest:  sha256:9e2b70...  # the resolved desired state at covers_through
```

**Ratchet-valid like anything else** — signed by a durable member, verified against
the roster at its parent. No new trust rule, no new signature type, no quorum. Only
durable members may checkpoint, and that needs no new enforcement: a checkpoint is
a fleet-shared path, which leaves are already refused. It is **tagged**
`rh-checkpoint-<n>`, which per §7.10.1 makes it and its ancestors immutable for
free.

Verification then replays from the last checkpoint rather than from genesis, which
is the difference between a bounded startup cost and one that grows forever. The
honest cost: a fresh clone's anchor becomes the checkpoint id rather than the
genesis id — the same trust shape (an id handed down the instruction chain), one
string, one comparison, so `store_id` means "the genesis commit id, or the id of
the checkpoint you are starting from".

#### 7.11.2 Re-root, and why **the archive ref is mandatory**

```
1. write + sign the checkpoint record; tag it
2. archive current history:  refs/roundhouse/archive/<date>  -> push
3. re-root main on the checkpointed state
4. push. New clones start here.
```

> **A re-root is byte-for-byte indistinguishable from the rollback attack in
> §7.12.3, except by the archive.** A host offline across one fetches and finds its
> monotonic `reviewed-ref` is not an ancestor of the new root — which the rollback
> rule says to treat as an attack, hold, and alert. **That behaviour is correct and
> must not be softened.** The archive ref is what distinguishes the two, so it is
> part of the protocol, not hygiene.
>
> **The trigger is a changed ROOT, not a moved head**, and reading it that way is
> what keeps the protocol from firing constantly. Ordinary history motion — a
> rewind, a squash, an amended tip, §8.2's reconcile merges — leaves the root
> commit alone, so it is not a re-root and does not enter this path; it is handled
> by the ordinary fast-forward and divergence rules. Only a store whose *genesis
> differs from the one this host pinned* is a re-root. Truncation that keeps the
> same genesis is not a re-root either — it is the §7.12.3 rollback attack, and the
> monotonic `reviewed-ref` and `generation` rows catch it without any archive
> lookup.

```
host offline across a re-root, catching up:
  1. fetch main -> new root is not a descendant of my reviewed-ref. DO NOT ADOPT.
  2. fetch refs/roundhouse/archive/*
  3. find my reviewed-ref in the archive.       # ABSENT -> HOLD + ALERT. Stop.
  4. verify the archived chain forward from reviewed-ref to the checkpoint,
     by the ordinary ratchet rule
  5. check the checkpoint is signed by a key trusted at its parent
  6. check checkpoint.generation >= my last-seen generation
  7. only now adopt the new root and advance reviewed-ref
```

Step 3's failure branch **is** the rollback protection: an attacker who re-roots
without publishing an archive containing the victim's `reviewed-ref` cannot get the
victim to adopt. Step 6 keeps generation monotonic across the re-root, so a re-root
cannot launder a generation rollback. A host that has never seen the store is
unaffected — it has no `reviewed-ref` and starts from the checkpoint.

#### 7.11.3 Three aging policies, none unbounded

| What grows | Policy | Cadence | Trust consequence |
|---|---|---|---|
| `ephemeral:` roster entries | TTL at birth + prune expired | existing 12 h full run | none — pruning is safe because verification reads roster-at-parent |
| Evidence (`journal/`, `alerts/`, `findings/`) | retention window, e.g. 90 d | existing 12 h full run | **none** — host-keyed, single-writer, inert. A pure size operation. |
| History | checkpoint + re-root | time or size trigger, instruction-driven | the §7.11.2 protocol |

**Evidence retention is deliberately decoupled from trust checkpointing.** They
have different natural periods — a canary window is hours, a trust checkpoint is
months — and coupling them would mean keeping evidence far too long or re-rooting
far too often. Because evidence paths are never inputs to verification, aging them
out is a pure `rm` with no trust reasoning attached.

**No new scheduler.** All of it rides §6.1's existing 12 h full run. Re-root is the
one operation that stays deliberate and instruction-driven, because it rewrites
what every clone starts from.

**"Ledger in concept, blockchain no":** the chain is strictly append-only *between*
checkpoints, which is where the security properties live, and deliberately
re-rootable *at* them, which is where the growth bound lives.

### 7.12 Attack analysis

#### 7.12.1 A compromised member enrols an attacker, then immediately writes

| t | Action | What hosts see |
|---|---|---|
| t0 | Attacker (holding vireo's shell, hence vireo's key) appends key **K**, generation++ | Ratchet-valid: vireo was trusted at the parent. **Accepted.** |
| t0+1s | Attacker commits malicious `fleet.yaml`, signed by **K** | Ratchet-valid: K was trusted at *that* commit's parent. **Accepted.** |
| t0+~20m | Peers fetch | Both verify |

**The crypto does not stop this and no crypto can — and enrolling K gave the
attacker nothing they did not already have.** vireo could have written the
identical malicious commit with vireo's own key, one commit and zero seconds
sooner. Any model where a member can write is a model where a compromised member
can write. **The enrollment is not the attack; it is the persistence mechanism for
it.** So the controls sit downstream, and the design already had most of them:

1. **Apply-time agent review on the receiving host** — the item is reviewed on
   wren, by wren's agent, against wren's posture. Unchanged by any trust model.
2. **`hooks` is a held category** (§5.1.3) — the highest-value payload is already
   unreachable until its gate is re-implemented.
3. **Canary gate + `canary_wait_hours`** — non-canary hosts wait, and the canary's
   journal evidence must be signed *as the canary*, which K cannot forge (§7.3 row
   3).
4. **`max_removals_per_run` / `max_removal_fraction`** — bounds the destructive
   variant.

And two the trust model adds, both targeting the *persistence*:

5. **Soak.** A commit touching a fleet-shared layer signed by a key enrolled less
   than the soak window ago is **held**. **During the soak window the attacker's K
   can write nothing but its own inert evidence paths** — so the race makes things
   *worse* for the attacker than not enrolling: writing as vireo lands in 20
   minutes, writing as K lands in 24 h. Costs a real new machine nothing.
6. **Loud alert on every roster change, on every host, leading the recap.** A
   two-to-three-times-a-year event. If it fires and nobody asked for a machine to
   be added, **that is the compromise notification**, within one fast interval.

#### 7.12.2 Stolen machine key

Blast radius is **one machine**. Move the block to `retired:` on any host — one
edit, one commit, propagating in ≤25 min through the path already carrying
everything else. Old commits by that key **stay `good`**, so nothing is
retroactively held and the fleet does not take an outage to cut off one machine.
The KRL is used *additionally* only to deliberately burn that key's history.

#### 7.12.3 Replay / downgrade of an older roster state

An attacker with hub write access force-pushes a history truncated to before a
revocation.

- **Host already past it:** `reviewed-ref` is monotonic → the fetched head is not a
  descendant → **alert and hold**, no reset. `git.abandon-unreachable-commits =
  false` (§3.1, pinned for a different reason) prevents local work being abandoned.
- **Host behind but which saw the newer roster:** `generation` is below its
  last-seen value → **refused**, even though the chain is internally valid.
- **Host offline since before the revocation, or restored from an old backup:**
  **accepts.** No in-band fix exists without an external witness, which the
  self-contained constraint forbids. Bounded by: the attacker needs a key that was
  valid at the rollback point, so **they already had write access — this buys
  persistence, not entry** — and the moment that host talks to any current host or
  the real hub, the generation check fires.
- Distinguishing a legitimate re-root from this attack is §7.11.2's archive
  protocol, and that is why the archive is mandatory.

#### 7.12.4 The first-host TOFU window

Enrollment reaches a newcomer over SSH. On genuine first contact an attacker
positioned between the sponsor and whatever the name resolves to can answer
instead, and the sponsor bootstraps the attacker's machine under the newcomer's
principal.

**What the attacker gains:** a fleet writer key. Not entry to any existing host,
not the owner's SSH private key, not the hub credential. **What contains it:**
`channel_auth: tofu` selects the **72 h soak** rather than 24 h, so the weakest
path is visibly the slowest; a distinct alert class fires on every host naming
`tofu` explicitly; revocation is one instruction. And decisively — **the real
machine never joins, and a human just asked for it to.** This is the most-noticed
attack in the document, in contrast to every other one here, which is silent by
design.

Shrinking the window is opportunistic and never required: `known_hosts` (the owner
has SSH'd there before → not TOFU at all) or a tailnet address (the tunnel
authenticates the node, so MITM requires compromising the tailnet). Both are reads
of things `identity.yaml` already carries.

**Honest bottom line: TOFU on genuine first contact cannot be closed without a
human check or a pre-shared secret.** The zero-touch requirement forbids the first
and there is no second. So it is accepted, recorded in `channel_auth`,
differentiated by soak class, and made loud.

#### 7.12.5 Hub (GitHub) credential theft

Today a stolen hub credential is **not** fleet compromise: the attacker can push,
but every commit is signature-gated, so they cannot write desired state. They get
disclosure of fleet config plus rollback and denial-of-service attempts, both
bounded above. **That property is why the hub is the outer boundary and never the
authorization** — if hub-push could enrol, one credential theft would escalate from
noisy nuisance to total. A hub-only attacker who pushes a `joins/` request gains
nothing unless they *also* control what an enrolled host resolves that name to, at
which point they are mounting §7.12.4 and inherit its containment.

### 7.13 Residuals — what this model does not solve

Stated plainly, because a trust model that hides its floor is worse than one that
names it.

1. **Instruction-chain compromise has no technical mitigation.** A prompt-injected
   agent session, or a compromised orchestrator, can issue "add attacker-box" and
   the entire model executes it correctly. Every signature verifies, every gate
   passes, the ratchet is working as designed. The store cannot distinguish a
   correctly-executed instruction from a correctly-executed instruction. What still
   applies is containment — the roster-change alert on every host within one fast
   interval, the soak, and one-instruction revocation. What does not apply is
   **detection**. This is the largest residual and it is structural.

2. **Authority reduces to two dependencies**: custody of the owner's GitHub account
   and integrity of whatever session was told to do the work. Everything else in
   §7 is blast-radius engineering on top of those two.

3. **TOFU on genuine first contact is open** (§7.12.4), closable only by a human
   check or a pre-shared secret, both of which the zero-touch requirement forbids.

4. **Rollback against a host that has been offline since before a revocation, or
   restored from an old backup, succeeds** (§7.12.3). No in-band fix exists without
   an external witness. It buys an attacker persistence, never entry.

5. **A same-user-writable roster reduces this model to no model**, and root
   ownership does not prevent the attack — only persistence past revocation
   (§7.9). Where passwordless sudo exists, root ownership collapses to same-user
   and doctor reports it.

6. **Backdating within the parent's timestamp is possible** (§7.1b). Bounded by the
   monotonicity assert and acceptable only because a forged expired leaf can write
   nothing but its own inert evidence. **TTL is hygiene; the class is the boundary.**

7. **Availability is out of scope, and the leaf class is the sharpest instance.**
   Residuals 1-6 and 8 are *integrity* residuals; this one is not. **Every control
   in this document fails to `hold`**, and a held item is an unavailable item. Rule
   6 refuses an `ephemeral` leaf's write to a fleet-shared layer — at verification,
   on every host — but **the refused commit still exists in the history every host
   fetches**. So the lowest-trust class in the design, instantiated ~40×/day by
   construction, can degrade a shared layer for the whole fleet by touching it
   once, and it stays degraded until a durable member supersedes the file. The same
   is true of anyone holding the hub credential (§7.12.5).

   **What is real containment:** such a commit is signed, attributable to a
   specific key, visible in the same alert channel as everything else, and one
   `retired:` edit away from being cut off — and because leaves cannot sponsor, the
   population that can do it is exactly the set some durable member instantiated.
   **What is not claimed:** that an authenticated member cannot degrade
   availability. It can. This design buys integrity and attribution, not
   availability, and a control that fails closed is a control that can be made to
   fail closed on purpose.

   **The blast radius is narrowed, though, and with machinery that already
   exists.** For a commit refused by rule 6 specifically — a *class* refusal, where
   the content parses and the signature is good and only the author's authority is
   wrong — §7.7 holds **only the items whose values that commit actually changed**,
   not every item the file contributes. That is §8.3's per-parent value comparison
   reused verbatim. **[rev10]** verified on a leaf touching one key of a three-key
   layer file: file-scoped hold = `["a","b","c"]`, item-scoped hold = `["b"]`.
   A leaf can still degrade what it touched; it can no longer freeze a file by
   brushing against it.

   **"Changed" includes removals, and that is load-bearing.** A deletion is a
   change to the resolved value, so the changed-item set is computed over the
   **union of the keys on both sides**, not the keys present afterwards. An
   additions-only reading would let a refused author delete an item and have the
   deletion pass unheld — which converts a narrowing into a hole.

8. **The genesis pin inherits git's hash strength.** Irrelevant at this threat
   level — an attacker would need a colliding commit that is *also* ratchet-valid —
   but it is a real dependency, and the pin would become
   `sha256(genesis_commit_id ‖ genesis roster bytes)` if anyone ever cared.

## 8. Offline, divergence, and conflicts

**Steady state is minutes-fresh; offline is the survivable exception.** §6.1 is
the design centre: awake hosts converge within one poll interval. Long divergence
windows are *tolerated*, not expected, and the distinction matters — a design that
treats week-long divergence as the norm optimises for the wrong case and lets
conflicts sit.

**What offline costs, when it happens.** jj commits without a network. A host
dark for three weeks fetches (fails, journals `source: none`), skips upstream
refresh, reviews against its last fetched state, converges, journals,
`jj new <main>`. Nothing is degraded except freshness, and there is nothing to
expire, no lease to reclaim, and no state that went stale.

**And when it comes back, the agent absorbs it.** A three-week reconvergence is
the same code path as a twenty-minute one: fetch, merge by commit ID, and if the
merge conflicts, **the run's agent resolves it from the evidence** (§8.2). No
human is involved by default, regardless of how the divergence arose. The
returning host is not a special mode and does not get a special ceremony; it is
just a host with more to merge.

### 8.1 The reconcile point, and never writing the bare token `main`

**[judges]** and **[rev2]**: when two hosts have both moved `main`, the bookmark
goes conflicted and **every bare `main` revset read exits 1** — `jj log -r main`
and `jj file show -r main` both return
``Error: Name `main` is conflicted``. `present()` does not help; it guards
absence, not ambiguity. `main@origin`, `jj bookmark list --all-remotes` and
`heads(bookmarks(exact:"main"))` all work in that state **[rev2]**.

> **Rule: the bare token `main` never appears in a revset argument.**

Every run begins by resolving names into commit IDs:

```sh
LOCAL=$(jj log -r 'heads(bookmarks(exact:"main"))' --no-graph -T 'commit_id ++ "\n"')
ORIGIN=$(jj log -r 'present(main@origin)'          --no-graph -T 'commit_id ++ "\n"')
```

From here on the run refers to commits, not names. The **reconcile point `R`** is
the single head, or the merge §8.2 makes.

**Resolution reads `R`, never `@`.** `@` must be a fresh child of a `main` target
at run start — checked **first**, because the window it covers is a crashed
previous run. A hand edit made while `@` sits *on* `main` rewrites the commit
`main` names and drags the bookmark with it **[judges]** — though **[rev2]**
confirms this only bites while `main` is *ahead of* `main@origin`; once the
target is at or below `main@origin`, jj refuses
(`This operation would rewrite 1 immutable commits`). The check still earns its
keep for the unpushed window; rev 1 overstated the blast radius.

> **The invariant has exactly one exemption, and without it the check destroys
> the thing §8.2 exists to protect.** During an open conflict §8.2 deliberately
> leaves `@` as a child of the conflicted merge `M`, and deliberately does *not*
> make `M` a `main` target — so on the run *after* the resolution is written
> (usually the same run, §8.2b; a later one only on escalation), the
> invariant is false by construction, and its remedy (`jj new <main target>`)
> would move the workbench off the resolution and discard it. This is the same
> two-rules-one-state defect as §6 step 4's promote gate, one section over.
>
> **Exemption:** if `@-` is conflicted **and was created locally**, `@` is the
> resolution workbench. Skip the `jj new`, and route to §8.2 step 4. One revset,
> readable from repo state alone — which the runbook needs anyway, because `$M`,
> `$WC` and `$LOCAL` do **not** survive between runs: §8.2 is written as one
> block but spans two.
>
> ```
> (conflicts() & @-) ~ ::remote_bookmarks()
> ```
>
> **"Created locally" means "not reachable from any remote bookmark", not "the
> committer says it is us".** **[rev4-fix]** the committer test this replaced was
> spoofable and leaked: a peer sets `JJ_EMAIL` to the victim's principal,
> publishes a conflicted merge with `jj git push --allow-conflicts`, the victim
> fetches, §8.1's *own* remedy parents `@` onto the fetched head, and the
> committer clause fires on a commit the victim never made — so the victim
> squash-resolves and republishes a conflict its operator never saw. The
> committer field is self-asserted and unsigned, so it can never be a gate
> (§7.3 says exactly this about identity and it applies here too).
> Reachability is not assertable: an inbound conflict is by construction
> reachable from `main@origin`, and a locally created merge by construction is
> not. Verified: on the leak state the revset is empty (the run falls through to
> hold-and-alert, §8.3), on the legitimate workbench it is non-empty and the
> subsequent squash-and-push still succeeds. The fix deletes the `$PRINCIPAL`
> variable and the committer read from the runbook.

**On the lint.** Rev 1 promised "one grep-able lint". It is not one: the sync
section has ~52 lines matching `main`, most of them git refspecs where bare
`main` is correct, and `jj git clone --colocate` writes
`revset-aliases."trunk()" = "main@origin"` into repo config, so revsets also live
outside the source tree. The honest version: a **partial** grep scoped to `-r`/
`--revision` arguments, plus a doctor check that *executes* the run's actual
revsets against a repo with a deliberately conflicted bookmark and requires them
all to exit 0. The executable check is the real one.

### 8.2 The conflicted-bookmark and divergence runbook

Verified end to end **[rev2]** in `/private/tmp/dsc-fix/lab1.sh`.

```bash
# bash. Nothing here reads the name `main`; everything is a commit ID.

# --- STEP 0: is this the second half of an earlier reconcile? (§8.1 exemption) --
if [ -n "$(jj log -r '(conflicts() & @-) ~ ::remote_bookmarks()' --no-graph -T 'commit_id')" ]; then
    goto_step_4=yes          # @ is the resolution workbench; do NOT `jj new`
fi

# --- STEPS 1-3: first half -----------------------------------------------------
# 1. The operator may have left an edit in @. It must not be discarded, and it
#    must have a description or the push in step 7 is refused.
PARENTS="$LOCAL $ORIGIN"
if [ "$(jj log -r @ --no-graph -T 'if(empty,"y","n")')" = n ]; then
    jj describe -r @ -m "hand edit on $HOST: $(jj diff -r @ --name-only | tr '\n' ' ')"
    PARENTS="$PARENTS $(jj log -r @ --no-graph -T 'commit_id')"
fi
# An EMPTY @ is never a parent: it has nothing to preserve, and it is undescribed.

# 2. Merge every head, by commit ID. jj dedupes duplicates.
jj new -m "reconcile $HOST" $PARENTS
M=$(jj log -r @ --no-graph -T 'commit_id')

# 3. Is the merge clean?
jj new "$M"                          # workbench off the merge, either way
if [ -z "$(jj log -r "conflicts() & $M" --no-graph -T 'commit_id')" ]; then
    jj bookmark set main -r "$M"     # dominates every head; loses nothing
    # ... converge, journal, push
else
    : # main does NOT move yet. R = $M. Go to step 3b.
fi

# --- STEP 3b: THE AGENT RESOLVES. Usually same run; §8.2b. --------------------
#   Gather evidence, decide, write the resolution into @ (a child of M),
#   describe it with the rationale, then fall through to step 4.
#   Escalate to hold-and-alert ONLY per §8.2b's escalation rule.

# --- STEP 4: fold the resolution back INTO the merge --------------------------
#   Same run if 3b resolved; a later run if a human resolved after an escalation.
M=$(jj log -r '@-' --no-graph -T 'commit_id')      # recovered from repo state
jj squash --into "$M" --use-destination-message
M2=$(jj log -r '@-' --no-graph -T 'commit_id')
jj bookmark set main -r "$M2"

# --- STEP 5: push. History now contains no conflicted commit. ------------------
jj git push --bookmark main
jj new "$M2"        # explicit: `jj git push` leaves an empty UNDESCRIBED @
```

Four things this fixes, all measured:

- **`$WC` is a merge parent only when `@` is non-empty.** **[rev3-fix]** rev 2
  described `@` only `if` it was non-empty but passed it as a parent
  *unconditionally* — so in the normal case (no pending hand edit, which is
  exactly the state step 5's `jj new` leaves behind) an **empty, undescribed**
  commit became a permanent ancestor of `main` and every push failed forever with
  `Won't push commit 8e379e63bba2 since it has no description`. That is P0-1's
  failure class reintroduced by P0-2's fix. Verified both ways in
  `/private/tmp/dsc-fix/lab11.sh`: rev 2's form bricks the push on a clean merge
  with no hand edit; the fixed form pushes cleanly (`main [move forward from
  c01e2945 to f30480ca]`) and still carries the operator's `groups/testing.yaml`
  to origin when one *is* pending.
- **Step 1's `describe` is load-bearing** for the non-empty case, for the same
  reason. **[rev2]**
- **Including `@` at all.** **[rev2]** without it, `jj new -m … $LOCAL $ORIGIN`
  reports `removed 1 files` and the operator's just-saved `groups/testing.yaml`
  **leaves the working copy**, surviving only as an undescribed orphan commit.
- **Step 4's squash.** **[rev2]** resolving in a *child* of `M` leaves `M`
  permanently conflicted and permanently an ancestor of every future `main`. One
  conflict would brick publication for the whole fleet. After
  `jj squash --into "$M" --use-destination-message`, the push range is
  conflict-free and the push succeeds. `--use-destination-message` is also what
  keeps the squash non-interactive (§3.2).

**Why step 5's `jj new "$M2"` is explicit rather than a bare `jj new`.**
**[rev3]** `jj git push` itself leaves an empty *undescribed* working-copy commit
behind. Naming the target makes `@` a child of the bookmark rather than of
whatever jj left, which is the §8.1 invariant. Rev 2 wrote this line without
saying why.

**If it escalates, the human's surface is unchanged:** `@` is a child of the conflicted `M`, so
the markers are in the files on disk at correct YAML indentation, each side
labelled with change ID, commit ID and description. She deletes the lines she
doesn't want and saves. No `jj resolve`, no `--continue`, no `--abort`.

**A merge commit dominates every head and discards nothing**, so resolving a
conflicted bookmark this way is not an automatic decision about intent — the
content merge is jj's line merge, and any genuine disagreement surfaces as a
conflict in `M` and is held. Automation stops only where a human is required.

### 8.2b The resolver is the run's agent, not the human

**A conflict is a task for the agent driving the run, not a ticket for the
operator.** It has the evidence, it can read both sides, and it is already
reviewing every diff in this run anyway. Waiting for a human is what turns a
five-minute merge into a week of silence.

**The evidence set**, all of it readable **while the merge is still conflicted**
— **[rev5]** verified: `jj file show -r <parent>` returns clean per-side YAML,
and `jj log -r "parents($M)"` renders each side's committer, timestamp and
description even though the merge itself is conflicted.

| Input | Command | Answers |
|---|---|---|
| Each side's value for the contested item | `jj file show -r <head> root:"<path>"` then the §4 fold | *what* each side wants |
| Each side's summary and trailers | `jj log -r "parents($M)" -T description` | *who*, *what kind of session*, and **why** (§5's `roundhouse-intent`) |
| Each side's timestamp | `... -T 'committer.timestamp()'` | which is newer, and by how much |
| Each host's recent journal | `journal/<h>/*.yaml` | the **trend**: has this item been flip-flopping? did the other host apply it and stay healthy, or apply and revert? |
| The item's own history | `jj log -r 'files(<path>)'` | whether one side is re-asserting a value the other already reverted |
| `applied/<h>.yaml` | — | what each host actually has on disk right now |

**Every rule is labelled with what grounds it, and the ordering follows from
those labels.** Three kinds of evidence, strongest first:

| Grounding | What it is | Can a hostile enrolled host fake it? |
|---|---|---|
| **signed history** | file content at a commit, and what a named change replaced | **No.** It is the content, verified by §7.3. |
| **replicated journal** | `journal/<h>/` outcomes, §7.3-bound to `<h>` | **Only about itself**, and only by lying about its own applies. |
| **self-asserted text** | the §5 trailers | **Yes, freely.** Free text in a description. |

> **The hard rule: a self-asserted field may never outrank a grounded one, and
> may never *win* a contest on its own — it may only point at evidence to check,
> or trigger an escalation.**
>
> Rev 5's ladder violated this. Its rule 2 ("one side is a revert of the other")
> fired on the *unverified* `roundhouse-reverts` trailer, ahead of both the
> journal-grounded rule and the human rule — so any enrolled host could write
> that trailer into a commit that was not a revert and win outright against a
> human's edit. Worse, its rule 4 let a forged `roundhouse-session:
> interactive/human` *win*, which made **forging strictly more powerful than
> omitting** and inverted §5's own escalation bias (omitting a trailer escalates;
> forging one won). §7.3 does not bound this: it binds *identity*, not the truth
> of content claims, and §8.2b was the first section to lean on it as if it did.

**The decision, in order.** Stop at the first rule that fires. **Rule 2 sits
where it does on purpose: every arbitration rule below it decides agent-vs-agent
contests only.**

1. **Not actually contested** — the item's resolved value is identical on both
   sides. Converge. *[signed history]* Most of a conflicted *file* is this case.

2. **Either side is, or defaults to, `interactive/human` → escalate.**
   *[self-asserted — so it can only escalate, never win]* A missing trailer block
   reads as `interactive/human` (§5), so omission and forgery land in the same
   place. Deliberately an **either-side** test: forging `scheduled/agent` on your
   own side does not avoid escalation, because the other side still reads as
   human.

   Rev 5 had "the human side wins", as rule 4, *below* both arbitration rules.
   Two separate defects, and this position fixes both. It could not **win**,
   because the claim is unverifiable and honouring it hands the merge to whoever
   types the right string. And it could not stay **below**, because any rule above
   it short-circuits human escalation entirely: rev 6's revert rule let a
   sufficiently old true revert claim beat a hand edit, and the applied-elsewhere
   rule arbitrated human-vs-agent without a human ever being consulted — which,
   given §6 step 6 applies and journals *before* pushing, is the modal two-host
   divergence, not an edge case.

   The cost is that a genuine hand edit conflicting with an agent edit escalates
   instead of silently winning. That is the right trade: it is precisely the
   moment a person's intent is at stake.

3. **Verified revert, scoped to this conflict** — one side's value equals what
   the change named in its `roundhouse-reverts` trailer *replaced*, **and the
   other side's value equals what that change *set***. That side wins.
   *[signed history; the trailer is only a pointer to what to check]*

   ```sh
   claim=$(jj log -r "$SIDE" --no-graph -T description | sed -n 's/^roundhouse-reverts: //p')
   c=$(cid "$claim")
   mine=$(    jj file show -r "$SIDE" root:"$path" | fold_item "$item")
   replaced=$(jj file show -r "$c-"   root:"$path" | fold_item "$item")
   set_to=$(  jj file show -r "$c"    root:"$path" | fold_item "$item")
   theirs=$(  jj file show -r "$OTHER" root:"$path" | fold_item "$item")
   [ "$mine" = "$replaced" ] && [ "$theirs" = "$set_to" ] || ignore_the_trailer
   ```

   **Both comparisons are required, and the second is the one rev 6 was missing.**
   Checking only `mine == replaced` verifies the claim is *true about history*,
   not that it is *about this conflict*. Demonstrated: history `v1 → (C: v2) → v3`;
   Claire hand-edits `v4`; another host publishes `v1` claiming
   `roundhouse-reverts: C`. That claim is genuinely true — `v1` does revert `C` —
   so the one-sided check passed and the revert won, meaning **reverting any
   sufficiently old change won any contest**. Requiring `theirs == set_to` says
   the other side is holding exactly what the named change introduced, i.e. this
   conflict really is about that change. It costs one more read of a revision the
   rule already fetches.

   **[rev7]** verified: the stale-revert attack now falls through — agent-vs-agent
   it reaches rule 6 (`theirs(v4) != set(v2)`), and with a human on either side it
   never gets past rule 2. **[rev6]** an outright forged claim was already
   rejected (`my={"pin":"v9-forged"} replaced={"pin":"v1"}`), and **[rev7]** the
   honest scoped revert still resolves without escalation between two agents
   (`mine(v1)==replaced(v1)` and `theirs(v2)==set(v2)`).

4. **Verified applied-elsewhere, and exactly one side qualifies** — one side's
   value is recorded `outcome: applied` in some peer's journal and **not
   subsequently reverted or superseded** there, *and the other side's value is
   not*. That value wins; the other side is stale. *[replicated journal]*

   **"Exactly one" is load-bearing.** §6 step 6 applies and journals **before**
   pushing, so in the ordinary two-host divergence *both* sides carry
   `outcome: applied` — each host applied its own edit locally before publishing.
   Rev 6's rule had no uniqueness requirement and no defined winner in that case,
   which is the common case rather than a rare one. When both sides qualify, or
   neither does, the rule does not fire and the ladder falls through.
   **[rev7]** verified: both-applied agent-vs-agent falls through to rule 6.

   The wording is deliberate and matches §10.1: the journal attests that a run
   *refused nothing*, not that the item is healthy. Rev 5 read the same field as
   "applied and journaled **healthy**", which overclaimed against §10.1's own
   disclaimer. "Applied and not subsequently reverted" is exactly what the record
   supports, and it is what §10.1 condition 2 already computes.

5. **Both sides agent-authored, and their journal `at` times differ by more than
   one fast interval** — the later one wins, on the reasoning that it was derived
   from more recent upstream state. *[replicated journal, skew-checked]*

   Two corrections rev 5 needed here. It decided this rule on
   `committer.timestamp()`, which **[rev6]** confirmed is forgeable —
   `JJ_TIMESTAMP=2099-01-01T00:00:00Z` produced exactly that committer timestamp,
   so one host with a wrong clock or a deliberate future stamp would win every
   rule-5 contest forever. Journal `at` fields are what §10.7's >5 min skew check
   already covers, so those are what the rule reads. And the margin matters: at a
   20-minute cadence "the later one saw more" is not a real claim three minutes
   apart, so inside one fast interval this rule does not fire. *(Rev 5 also said
   "newest `roundhouse-intent` wins"; `roundhouse-intent` is prose and carries no
   timestamp. Wording bug in a decision rule, fixed.)*

6. **Otherwise — escalate.** Hold the item, alert, converge everything else.

**Escalation, stated once:** the agent escalates when a human is on either side
(rule 2 — checked before any arbitration), when neither side is grounded or both
are equally grounded (rule 6), or when two agent edits are too close together to
order honestly (rule 5's margin). Everything else it resolves,
and every resolution it makes rests on signed content or a §7.3-bound journal —
never on a string someone typed into a commit message.

**Recording the resolution.** The resolution commit's description carries the
rationale, and a `journal/<host>/` record with `outcome: resolved` names both
parent change IDs, the winning digest, and the resolution commit (§5). Together
they mean a peer — human or agent — can reconstruct *what was contested, what
won, and why*, from replicated, signed content. This is the one replicated record
that carries prose, and §5 says why the exception is warranted here and nowhere
else.

**Why this is safe rather than clever.** The agent is not being trusted with
anything new. Its resolution is an ordinary commit: signed at creation (§3.1),
subject to the §7.3 identity gate on every peer, digest-bound and re-reviewed by
every receiving host (§7.2), gated by canary before it reaches non-canary
machines (§10.1), capped by `max_removals_per_run` (§10.3), and revertable
through §10.8 like any other change. If the agent resolves badly, that is a bad
*change* — and the whole rest of this document is about surviving bad changes.

**And the window is minutes.** With §6.1's fast cadence, two hosts rarely diverge
far enough to contest the same key; when they do, the conflict is found and
resolved on the next fast run rather than sitting until someone notices.

### 8.3 What converges while a conflict is open — item level, from real commits

```
for each head H:  effective_H = fold(layers at H)     # H is a real commit
item is HELD      iff  effective_H[item] differs across heads
item CONVERGES    at   that identical value, otherwise
```

**"The heads" means the bookmark heads — `$LOCAL` and `$ORIGIN`, recomputed —
never `parents($M)`.** Since §8.2 step 1 may add the workbench as a third parent,
`parents($M)` is the heads *plus the operator's in-flight edit*, and folding that
in as an equal voice makes an item the operator is halfway through editing read
as a two-host disagreement and get **held**. Recomputing is also free and
stateless: `main` did not move on the conflicted path, so
`heads(bookmarks(exact:"main"))` and `present(main@origin)` still return exactly
the heads on the later run too. Rev 2 said "the parents of `M` are the heads",
which stopped being true the moment P0-2 was fixed.

So this is `jj file show -r <head> <path>` per side. **[rev2]** verified: that returns clean per-side YAML that `yq` parses,
*while the merge is conflicted*, and the same read on the conflicted commit's own
content fails `yq -e '.'` as expected. Worked run, one contested key and one
uncontested key in the same conflicted file:

```
  parent A: {"ponytail":"1.6.0-a","railyard":"enabled","legal":"enabled"}
  parent B: {"ponytail":"1.6.0-b","railyard":"enabled","legal":"absent"}
  -> ponytail HELD · legal HELD · railyard converges at "enabled"
```

Two things this buys:

- **The group-layer amplification is fixed.** One contested key in
  `groups/development.yaml` no longer holds every item that layer contributes on
  every host in the group.
- **Adjacent-line conflicts stop over-holding.** **[judges]** adjacent-line YAML
  edits conflict even when the keys are unrelated. Because the hold set comes
  from per-head values and never from marker positions, an adjacent-line
  collision costs a marker in the file and nothing else.

And the property that keeps it legible: **every value applied is byte-identical
to the value at a real, signed, verifiable commit — and during divergence, at
*every* head.** No synthesised state.

### 8.4 Publication policy for conflicts

> **Declared judgment call (the reviewer's undeclared Q5).** The three judges
> ruled against **`jj git push --allow-conflicts`**. Rev 1 silently strengthened
> that to *no ancestor of a published head may ever have been conflicted*, which
> is what produced the deadlock. **The rule is the judges' rule: no conflicted
> commit is ever pushed.** History may contain a commit that *was* conflicted and
> was resolved in place — that is exactly what §8.2 step 4 produces.

**`--allow-conflicts` is banned.** **[judges]** it works, and it publishes
`.jjconflict-base-0/`, `.jjconflict-side-0/`, `.jjconflict-side-1/`,
`JJ-CONFLICT-README` and a non-standard `jj:trees` header — the whole tree three
times over. Every non-jj reader, the GitHub browser, every backup, and **any host
that clones fresh during the conflict window** pays for it. Under §8.2b that
window is one run rather than open-ended, but publishing broken trees is not
something a shorter window makes acceptable.

While a conflict is open the host is **locally converging and
publication-silent** — the same state it is in when offline. Everything it
decides lands as durable signed local commits and pushes in one fast-forward
after the squash.

**That window is now minutes, not days, and that is what closed the open
question rev 3 left here.** Under §8.2b the run's own agent resolves the conflict
in the same run it detects it; the silence lasts as long as the resolve-and-
squash takes. Only an escalation (§8.2b rule 2 — a human on either
side) leaves it open longer, and that case has a human's attention by
construction, because a human just made one of the edits. The alternative rev 3
weighed — a host-keyed evidence bookmark that fast-forwards independently of
`main` — existed to stop a conflict sitting unnoticed for weeks. With
agent resolution plus §6.1's fast cadence, *that state no longer exists*, so the
second bookmark would be a mechanism guarding a case the design has removed.

Two guards, because jj's refusal is not self-enforcing:

- **Raw `git push` from the colocated repo bypasses jj's conflict guard**
  (jj#9571). A **pre-push check** refuses if any commit *being published* is
  conflicted — `conflicts() & present(main@origin)..<target>` — and doctor
  asserts the same plus no `.jjconflict-*` path in the **git** tree at any head
  (`git ls-tree -r`, not `jj file list`: jj reconstitutes the native conflict and
  never shows those paths, while the git side carries all four — verified). That
  check is also what catches an *inbound* published conflict, which the range
  revset below cannot see, because there the conflicted commit **is**
  `main@origin`. Two details in that
  revset, both of them corrections:
  - it is the **range being pushed**, not `::<target>`, which is what unbricks
    the store after a resolved conflict (§8.2 step 4);
  - `main@origin` is wrapped in **`present()`**. **[rev3-fix]** the bare form
    fails with ``Error: Revision `main@origin` doesn't exist`` on any store that
    has never fetched — host 1's very first push, and any host whose remote was
    just re-pointed — so the guard that unbricked the store could not run on the
    fleet's first push, and the document never said whether that failed open or
    closed. `present(main@origin)..<target>` exits 0 with an empty result on a
    never-fetched repo, verified. This is the same bare-name trap §8.1 exists to
    forbid, which had reappeared inside the fix for it.
- **No roundhouse code path invokes `git push` or `git commit`.** git is the wire
  format underneath, the doctor cross-check, and the repo-local config pins
  (§3.2), nothing else.

### 8.5 Peer fetch — 8(b) closed by deletion

Each peer is its own jj remote; jj namespaces remote-tracking bookmarks per
remote, so `main@origin` and `main@peer-wren` are different refs.

```sh
jj git remote add peer-wren ssh://rh-wren/~/.config/roundhouse/store
jj git fetch --remote peer-wren
```

The peer URL is built only from validated fields (§5). The shipped
`+refs/heads/*:refs/remotes/origin/*` peer refspec — the thing that lets one
stale peer roll back everyone's view of main — is **not expressible here**. The
fix is deleting code.

Residual, stated precisely: this closes the *peer* case completely. It does not
make `main@origin` monotonic — a force-pushed origin is recorded. That degrades
gracefully: with `abandon-unreachable-commits = false` the commits are not lost,
and a value that moved backwards is another value change, reviewed on arrival.

**Push-to-peer stays out of scope.**

### 8.6 Undo

`jj undo` / `jj op restore <op>`; the run records its starting operation ID in
`store.run/`. This deletes `sync_undo_command`'s branch/reset machinery. Undo
after a successful push is local-only, so the run prints its op ID *and* whether
it pushed.

**The op log is not the journal.** Host-local, never pushed, erasable, and it
records jj operations rather than roundhouse decisions.

---

## 9. Identity, rename, retirement, and the Windows host

### 9.1 Names

**There is no opaque id. The filename is the identity.** Both opaque-token
proposals are rejected: the shipped 16-hex `id:` and jj-native's
`enrolled: <change-id>`.

> **This overrules a judge, and rev 1 hid that.** The operator judge listed
> `enrolled:` as a must-survive carry-forward and called it "the only
> dead-machine-removal affordance anyone proposed"; the owner-proxy judge called
> it "a GUID by another name" and put it on the must-not-survive list. The owner
> constraint ("no opaque ids; human filenames") is absolute and breaks the tie
> toward owner-proxy. The capability the operator wanted is preserved by
> `lineage/`'s `retired` event, below, which covers retire-then-reuse without a
> token in a hand-edited file.

**`lineage/` carries rename and retirement**, append-only, retained permanently
(Terraform's rule: prune one and any host still holding the old name orphans).

- **A rename requires `roundhouse fleet-enroll` on the renamed host, and the
  rename is not complete until it runs.** §7.3 ties the store's committer
  identity to the roster principal and requires evidence under
  `journal/<h>/` to verify as exactly `<h>@<domain>` — so the moment
  `hosts/vireo.yaml` and `journal/vireo/` exist while the host's roster entry
  still asserts `macbook-pro@<domain>`, **all of the renamed host's own new
  evidence is rejected by every peer**, including its own canary records. Rev 2
  introduced the identity rule and never connected it to the rename procedure.
  a durable member commits the new principal into the roster and the host resets
  `user.email`; the `lineage/` record is written by whoever performs the rename,
  and doctor flags a host whose `identity.yaml` name and roster principal
  disagree.
- **Moved evidence is attributed to the mover, by design.** Renaming
  `journal/macbook-pro/` → `journal/vireo/` re-introduces those files in a new
  commit signed by whoever ran the `mv`, so the historical records now verify as
  the mover rather than as their original author. That is correct and not worth
  machinery to avoid: the moved files are a *copy* of history whose original
  commits are still in the log under the old path, and the canary gate only ever
  reads recent records. Stated so nobody later reads it as a forgery.
- A host offline across a rename returns holding `hosts/macbook-pro.yaml` and
  `journal/macbook-pro/`. The resolver reads `lineage/`, maps old→new, and moves
  the files with plain `mv` (**[judges]** `jj mv` and `jj file move` do not
  exist; jj snapshots the moves).
- Chained renames resolve transitively. Two simultaneous renames produce two
  files, both retained; newest `at` wins, alert on the other.
- **Retirement** is `event: retired` plus deleting `hosts/<name>.yaml`. Reusing a
  retired name is a human decision that the ledger record makes visible; rev 1
  added a doctor row for it and the reviewer is right that a once-a-decade event
  does not earn one. The record carries a `note:` saying so. Row deleted.
- **Machine rename and roundhouse rename are separate** (Ansible's
  `inventory_hostname` / `ansible_host` split). Renaming the box in System
  Settings is a one-line edit to `hostname:`.

### 9.2 The Windows host

Rev 1 never mentioned Windows, which made three of its own rules contradict
KTD15. The resolution needs no new tier and no native-Windows claim:

- **Nothing roundhouse runs executes on native Windows.** Per KTD15
  (`docs/plans/2026-08-06-001-feat-fleet-sync-plan.md:144`), `iris-windows` is
  driven through the existing WSL-interop lane: its `wsl_sibling` operates it.
  Under this design that sibling is an ordinary Linux host running jj, so **there
  is no git-only tier and §14's ban on one is not contradicted.** The reason
  KTD15 said "git-only mode" was that jj was optional; here it is a prerequisite
  and it is satisfied on the machine that actually runs the code.
- **The store for `iris-windows` lives in the WSL filesystem, not under
  `/mnt/c`.** The store is a jj repo; only *convergence* needs Windows paths, and
  that already goes through the interop lane. Keeping the repo off DrvFs avoids
  betting on jj's locking semantics over a 9p mount, which nobody has measured.
  This is a path choice, not a mechanism.
- **Evidence attribution is solved with a second key, not an exception.** The WSL
  sibling mints a **second keypair whose roster principal is
  `iris-windows@<domain>`**, and a durable member enrols it as an ordinary roster
  entry — a second enrollment, not a new mechanism, and no authority involved. The
  sibling then runs **two roundhouse instances**: its own
  (`~/.config/roundhouse/`, `name: iris-wsl`) and the one it operates
  (`~/.config/roundhouse-iris-windows/`, `name: iris-windows`, the second key,
  its own store clone and its own jj repo config). Same code, run twice, two keys,
  two roster entries — which is what "operating another host" already meant. Both
  entries are `durable:`; nothing about the class differs.
  `journal/iris-windows/` is therefore signed as `iris-windows@<domain>` and
  §7.3 row 3 (host-keyed evidence) stays a **pure equality check with no
  exception**.

  Rev 2 instead accepted `<operated_by of h>@<domain>` in row 2, reading
  `operated_by` from a fleet-shared layer file. Because the §7.3 Q4 call lets any
  enrolled host edit any layer file, that let any host grant itself another
  host's evidence rights by appending one line to `hosts/<h>.yaml`. **The field
  is deleted from the schema and from the trust path.** `wsl_sibling:` remains,
  because the *apply* path genuinely needs to know which interop lane reaches
  `%USERPROFILE%`, and it grants nothing.

If a native-Windows lane is ever wanted, that is a separate decision requiring
its own measurement of jj on Windows. This design does not depend on one.

---

## 10. The remaining capabilities

### 10.1 Canary, with a liveness term

A non-canary host applies item X at digest D only when, for some canary host `c`:

1. `journal/c/` contains `outcome: applied` **or `outcome: satisfied`** for
   `{X, D}`, at least `canary_wait_hours` ago, **and**
2. no later record for X from `c` with `outcome: held` or `reverted`, **and**
3. **`c` has published *some* record — any item, or an `alive` heartbeat — dated
   at or after `applied_at + canary_wait_hours`.**

Condition 3 is new and it closes a lie by omission the reviewer found: a canary
that applies an item, is wrecked by it, and stops journaling satisfies (1) and
(2), as does a canary that went **publication-silent because of an unrelated
conflict** — which is precisely the state §8.4 mandates. Two forms of silence
were reading as a pass. One more read over the same directory.

This also makes §16 Q1's cost visible rather than invisible: with the liveness
term, a silenced canary *blocks* promotion instead of permitting it on stale
evidence. Answer Q1 against this gate, not the old one.

Attribution is real because of §7.3: the commit introducing a record under
`journal/c/` must verify as **exactly `c`** — no exception, for any host. No bypass flag; the only
exemption is canary membership. Time comes from journal `at` fields, never commit
timestamps. `outcome: applied` claims only "the run refused nothing" — a weaker
claim than a health probe, and the design does not pretend otherwise.

`satisfied` counts in condition 1 and `held` does not, and the asymmetry is
what makes the gate terminate. An item whose category has no state-alignment
verb can never produce an `applied` record **on any host**, so gating peers on
one holds it forever and buys nothing — the peer would no-op identically. An
item a host tried and could not apply, or that a gate refused, still journals
`held` and still blocks: a genuine apply failure must never read as evidence of
success.

*Ceiling:* "who is in canary" is a grep across 5 host files. At ~30 hosts that
flips and membership should move into `groups/canary.yaml`.

### 10.2 Proposals and unanimity promotion

`roundhouse fleet-seed` reads installed-state discovery and writes the host's own
`hosts/<name>.yaml` and `applied/<host>.yaml` to match, so the **first
convergence after seeding is a no-op by construction**. Where an item has an
identical value in *every* enrolled host file, seeding emits
`proposals/promote-*.yaml` (shape in §5).

Unanimity is the bar. 3-of-5 is normal curation for this fleet (141 vs 58
standalone skills is intent, not drift) and produces no proposal and no alert.
Accepting is `roundhouse fleet-accept <slug>` or a human doing the two edits.
Re-seeding upserts and never removes.

### 10.3 Ownership, removal, and the damage guards

**Five cases, from `applied/<host>.yaml`:**

| in layers | in `applied/<host>.yaml` | on host | action |
|---|---|---|---|
| yes | no | no | adopt — review, then apply |
| yes | **no** | **yes** | **adopt in place** — silently if the on-host value's digest matches the desired one, review if it does not. **Never** treated as "not ours". |
| yes | yes, same digest | matches | nothing |
| yes | yes, different digest | — | changed — review, then apply |
| no | yes | yes | **prune** — ours, and it left the layers |
| no | no | yes | **not ours. Never touch it.** |

Row 2 is the one rev 1 omitted, and it is the state a **host reinstall** produces
— also what a hand-truncated `applied/<host>.yaml` produces, and these files are
hand-editable by design. Without it the nearest matching row is "never touch it",
which makes roundhouse permanently disown everything it installed.

**Three genuinely separate code paths**, because conflating them has a body count
(Rancher Fleet #5406 removed everything a cluster managed when the agent lost its
source):

1. **Cannot reach the source** (fetch failed) → converge from last known.
   **Never prune.**
2. **Cannot read the source** (parse failure, conflict, unsigned, principal
   mismatch) → hold the affected items at their last-applied value. **Never
   prune.** A file that does not parse is *not* an empty file.
3. **The source says this is gone** → each removal gets its own review record.

**`max_removals_per_run` (5) and `max_removal_fraction` (0.25), whichever is
smaller.** A run whose effective set removes more than that **holds the entire
removal set** and alerts. Rev 1 justified the knob with "a `dd` in vim or a
truncated save" and the reviewer is right that a `dd` removing ≤5 items sails
through: the count-only guard catches the large accident, not the small one. The
fraction term narrows it; the honest statement is that **neither catches a
one-line deletion, and nothing should — that is a legitimate edit, and its
defence is apply-time review naming the item, not a cap.**

`applied/<host>.yaml` records the **item id only, never the scope that produced
it**, so a host whose `groups:` list changes still sees every previously applied
item as a prune candidate and reviews it by name (KEP-3659's failure mode).

### 10.4 Findings and the redaction floor

`findings/<host>/<stamp>-<slug>.yaml`, host-keyed. The shipped
`sync_quote_is_secret` predicate (`roundhouse:9123-9146`) stays **verbatim** —
named secret classes (`-----BEGIN`, JWT shape, `gh[pousr]_`, `glpat-`,
`xox[bp]-`, `sk-`, `AKIA`) plus one bounded 32-char mixed-charset entropy check,
plus a 400-byte cap on every replicated field. A quote that trips it is
**refused, not silently redacted**.

**The sweep covers commit descriptions as well as files.** Rev 5 added two
replicated free-text surfaces the path-based sweep could not see: `roundhouse-intent`
on *every* roundhouse commit (§5), and the rationale behind an `outcome: resolved`
record. Both are signed and replicated; neither was swept or capped, and doctor
only checked that trailers were *present*, never what was in them. An agent
quoting a token into an intent line would publish it to the shared store, and
§10.4's own remedy explicitly cannot un-publish.

The fix is one more field on a walk that already exists: the same per-commit pass
over the push range runs `sync_quote_is_secret` over **`description`** as well as
over the `findings/`/`alerts/` paths, and refuses the push on a match. Free-text
trailers are capped at the same **400 bytes** as every other replicated field —
`roundhouse-intent` is one line, and a rationale that does not fit in 400 bytes
belongs in `store.run/`, not on the wire.

**The sweep runs over the commit range being pushed, not the working tree.**
Rev 1 swept the tree, which cannot catch the case the sweep exists for: a secret
hand-written into `findings/` is snapshotted and signed by the next jj command,
and deleting it afterwards leaves the tree clean while the blob is still in the
range about to be pushed. **[rev2]** the enumeration that does catch it is a
per-commit walk — `jj diff -r <c> --name-only` for each `c` in
`main@origin..<target>` — which sees a create-then-delete that a range diff
elides. A match refuses the push, names the file **and the line within it**
(§10.4's own promise, which the predicate needs one extra field to keep), and
gives the `jj abandon` / `jj op restore` command to drop it from local history.

### 10.5 Upstream freshness

`upstreams/<id>/<host>.yaml`, one file per host per upstream. Freshness is
`max(updated_at)` across the directory. **No leases, no CAS, no TTLs, no
takeover.** Jitter is the coordination primitive.

### 10.6 Hooks, self-update containment, and the private-remote gate

Five shipped capabilities rev 1 dropped without a line. **[rev8]** every citation
below was re-checked against the *post-refactor* `lib/` code, and the "carried
unchanged" claim was downgraded wherever the code no longer has that shape. A
claim that cites code which no longer exists is worse than no claim.

| Capability | Post-refactor code | Status here |
|---|---|---|
| Hook trust gate | `lib/sync-init.sh:397-405` | **Re-implemented** — §5.1.3 |
| `sync-adopt-pin` self-update containment | `lib/sync-run.sh:362-399` | **Carried, record shape re-implemented** |
| Private-remote first-push gate | `lib/sync-run.sh:122-142`, `lib/sync-init.sh:164,230` | **Carried, source moves** |
| `core.symlinks false` | `lib/sync-init.sh:95` | **Carried unchanged** |
| Store-symlink detection | `lib/sync-init.sh:386-393` | **Re-implemented** |
| Stale run-lock detection | `lib/sync-run.sh:89-99` | **Carried, threshold must be re-based** |

- **Hook trust** — the deferral was unsound; see §5.1.3's block for what the
  re-implemented gate reads and why the `hooks` category is held until it lands.
- **`sync-adopt-pin` self-update containment.** The *containment* carries:
  roundhouse updating itself stays gated separately from ordinary convergence.
  The *record* does not — `lib/sync-run.sh:399` writes
  `schema:"roundhouse.sync-adopt-pin", schema_version:1`, and §14 bans both keys.
  The record becomes an ordinary item under the closed category set.
- **The private-remote first-push gate.** The logic carries verbatim: no push to
  a remote whose visibility is unverified. Its *source* moves —
  `lib/sync-run.sh:122` reads `"$store/meta/host.json"`, and §2/§12 delete that
  file, so the flag reads from `store.local/posture.yaml` instead. It is a
  statement about one host's check of one host's remote, which is why it belongs
  outside the tree anyway.
- **`core.symlinks false`** (`lib/sync-init.sh:95`) is a plain repo-local
  `git config` write, which §3.2 already sanctions as part of pinning the
  colocated `.git` hermetic. Genuinely unchanged; it just joins the §3.2 block.
- **Store-symlink detection** is **re-implemented**, for two reasons. It reads the
  tree with a raw `git ls-tree` walk (`lib/sync-init.sh:386-393`), and §8.4 admits
  only `git ls-remote` and `git verify-commit` as read-only git calls — so it
  reads the jj tree instead. And **[rev2]** the P0-3 config migration puts a
  symlink into `$HOME` *inside* `.jj/`, so the detector must scope to the tracked
  tree rather than the whole directory or it fires on jj's own plumbing.
- **Stale run-lock detection** carries — host-local, about the host, not the
  store — but its **threshold must be re-based on the full cadence**.
  `lib/sync-run.sh:91` computes `stale_after = cadence_hours * 7200`, i.e. two
  cadences. §6.1 introduces a second, much shorter cadence; if that arithmetic
  ever reads `fast_interval_minutes`, a 40-minute threshold would declare a live
  run's lock stale on the next fast run. It keys on `cadence_hours` (the 12-hour
  maintenance cadence), and this sentence exists so the fast cadence is not
  wired into it by accident.

### 10.7 Doctor

Every check exists because something was observed to fail silently.

| Check | Why |
|---|---|
| `yq`, `jj`, `jq` present, versions recorded | Hard prerequisites; version-sensitive behaviour is pinned by the checks below. |
| Effective jj config matches §3.1 (via `jj config get`, not a file) | §3.1 — the config file is migrated out of the tree. |
| `ui.paginate`, `ui.editor`, repo-local `commit.gpgsign=false`, `gpg.ssh.program=ssh-keygen`, `core.pager` | §3.2 — the owner's global git config makes `git commit` pop a 1Password dialog. |
| No rewrite subcommand in roundhouse's source without a message flag | §3.2. |
| A commit signed by an enrolled key reports `good`, not `unknown` | §7.1a. |
| A freshly-minted KRL-revoked key reports `bad`; a freshly-minted enrolled one reports `good` | §7.1a — fixtures generated on demand. |
| The KRL path resolves and is non-empty | §7.1a — a typo'd path returns `bad` for everything. |
| **Roster coherence**: every entry has a well-formed principal and key; every enrolled host has exactly one entry; no durable entry lacks a `hosts/<h>.yaml`; `generation:` present | §7.1 — the roster is hand-editable, so it is hand-breakable. |
| **Materialization digest**: the materialized `allowed_signers` is byte-identical to the roster the ratchet derives from `reviewed-ref` | §7.9 — a hand-edited materialized file is precisely the self-enrollment signature. Mismatch ⇒ alert + full hold, never a repair. |
| **Ratchet replay**: every commit in `reviewed-ref..head` verifies against its own roster-at-parent | §7.1 — the gate itself, asserted rather than assumed. |
| **Timestamp monotonicity**: no commit in the verified range predates its parent | §7.1b — bounds backdating. |
| **`generation:` never decreased** against the host's last-seen value | §7.12.3. |
| `reviewed-ref` is an ancestor of the fetched head, **or** the §7.11.2 archive protocol succeeded | §7.11.2 — a re-root and a rollback attack are otherwise indistinguishable. |
| The privileged materialization lane is configured; if not, report the same-user degradation | §7.9 — passwordless sudo collapses root ownership; report, do not fail. |
| Checkpoints are **tags**, not bookmarks | §7.10.1 — a bookmark confers no immutability. |
| **Class enforcement**: a fixture `ephemeral` key touching a fleet-shared path, and one touching `trust/signers.yaml`, are both **refused** | §7.1 rule 6 — "the class is the security boundary" is the only rule with no row otherwise, asserted in prose with nothing observing it. |
| The **archive ref exists** for the last re-root, on the producing side | §7.11.2 — the archive is "part of the protocol, not hygiene"; the consuming-side row only catches it after a host is already stuck. |
| The **genesis roster lists the key that signed the genesis commit** | §7.3a — a genesis listing anyone else is refused. |
| Every roster line carries `namespaces="git"` and **no** time options | §7.1b — time options in a file jj reads are retroactive; the namespace is what stops an enrollment proof being replayed as a commit signature. |
| **Soak enforcement**: a fixture commit to a fleet layer signed by a key enrolled inside the soak window is **held** | §7.3a — the containment for the enroll-then-write race. |
| `generation` high-water mark is present, root-owned where the lane exists, and never decreased | §7.9, §7.12.3. |
| A commit whose committer says one host and whose signature says another is **held** | §7.3 — the equality check must be observed to reject. |
| `git -c gpg.ssh.program=ssh-keygen … verify-commit` agrees with jj on a fixture | §7.1 cross-check, not a gate. |
| `conflicts() & present(main@origin)..<target>` empty before push; no `.jjconflict-*` in the **git** tree at any head | §8.4 — `present()` because the bare form errors on a never-fetched store; **git** tree because jj reconstitutes the native conflict and shows no such path, and because this is the check that sees an inbound published conflict. |
| `@` is not any target of `main` | §8.1. |
| The run's actual revsets all exit 0 against a repo with a deliberately conflicted bookmark | §8.1 — this is the real "no bare `main`" check; the grep is partial. |
| **Genesis pin**: the root commit of this store's ancestry equals `identity.yaml`'s `store_id` | §7.5 — a revset comparison, not a file read. A marker file could be *contained* by a hostile store; a genesis commit id cannot. |
| No host-local file inside the tracked store tree | Shipped tripwire, scoped per §10.6. |
| Secret predicate over the push range under `findings/`/`alerts/` | §10.4. |
| Host clock vs peer journal timestamps (>5 min skew) | Canary waits are only as good as the clocks. |
| Digest of a checked-in fixture matches a value recomputed now | §7.2 — catches yq/jq behaviour change on *this* host. Cross-host comparison is `fleet-doctor --all` over ssh, not a pinned constant. |
| Every `hostname`/`tailnet_name`/`user`/`<name>` passes the fetch-URL predicate | §5 — ssh_config injection. |
| Chezmoi co-ownership has not re-emerged on any `managed` key | §5. |
| `git ls-remote origin refs/heads/main` succeeds and its output is comparable to `main@origin` | §6.1 — the poll floor is the propagation mechanism; if it silently fails the fleet degrades to the 12 h cadence without saying so. |
| Every roundhouse-authored commit on `main` carries the §5 trailer block | §5/§8.2b — the resolver's evidence. A run that stops writing trailers degrades every future conflict to an escalation. |
| Every canary override (`--now`) in the last 30 days, with item, host and time | §10.8 — the only canary bypass in the design; an uncounted bypass becomes routine. |
| The redaction predicate runs over commit **descriptions** in the push range | §10.4 — `roundhouse-intent` is replicated free text on every commit. |
| A revert of a previously-applied change is re-reviewed, not auto-passed | §10.8 — the digest matches an old verdict; only the revert-signature predicate stops it. Must be observed to prompt. |
| A **promotion** is *not* re-reviewed | §7.2/§10.8 — the mirror assertion. Rev 5's change-ID gate broke this and nothing caught it; a fixture promotion must apply silently. |

---

### 10.8 Rollback — first-class, and it is just another change

Rollback is not a special path. **A fleet-wide rollback is a signed revert commit
on `main` that flows through the exact same review, canary and apply gates as any
other change.** That is the whole design, and it is why it can be trusted: there
is no privileged "undo" code path that has never been exercised.

#### Two mechanisms, for two different failures

| Failure | Mechanism | Scope |
|---|---|---|
| "This change is wrong; get it off the fleet." | **Signed revert commit on `main`** — item-level or whole-change | Fleet, through the normal gates |
| "This *run* did something wrong on *this box*." | **`jj op restore <op>`** (§8.6) | One host, local, immediate |

The second is the abort button for a bad local apply and nothing more: the op log
is host-local and never replicates, so it can never be the fleet mechanism.

#### The revert flow, verified

**[rev5]** verified end to end in `/private/tmp/dsc-fix/lab14.sh`:

```sh
jj revert -r "$BAD" -d "$(current main target)"
#   Reverted 1 commits as follows:
#     krtnonor 053191b8 Revert "bump ponytail pin v2.4.1 -> v2.5.0"
jj describe -r "$REV" -m "revert ponytail pin v2.5.0 -> v2.4.1

roundhouse-host: wren
roundhouse-session: revert
roundhouse-intent: rollback; v2.5.0 removed the ultra intensity level
roundhouse-reverts: skwvtltpmpnz
roundhouse-items: plugins.ponytail"
jj bookmark set main -r "$REV"
jj git push --bookmark main
```

Measured outcomes, all three load-bearing:

- **Content returns exactly** — `pin: v2.4.1` restored.
- **The digest returns to the prior value** — `0ada03724bef`, byte-identical to
  the pre-change digest.
- **The change ID is new** — `krtnonorpswt`, distinct from the bad change
  `skwvtltpmpnz`.
- The receiving host reads the rationale straight off the wire:
  `roundhouse-intent: rollback; v2.5.0 removed the ultra intensity level` and
  `roundhouse-reverts: skwvtltpmpnz`.

#### Why a revert must be re-reviewed — the revert-signature predicate

The third measurement above is the interesting one. A revert restores a value
this host **has already reviewed and passed before**, so a verdict keyed on
`(item, digest)` alone would match a stale pass and **auto-apply the rollback
with no review at all**. That is wrong in both directions: an accidental revert
would sail through, and a deliberate one would be unreviewable.

> **A stored verdict does not satisfy the apply gate when the incoming digest is
> one this host previously applied and later stopped applying.** That pattern —
> applied, then withdrawn, now back — *is* the signature of a revert. The item is
> re-reviewed as the new decision it is.

The predicate reads this host's **own** `journal/<host>/` records, which it
already writes: digest `D` for item `X` has an `outcome: applied` record, followed
by a later record for `X` at a different digest or with `outcome: reverted`. No
change ID, no new field, no history walk over layer files.

Three properties, and they are why this replaced rev 5's change-ID gate:

- **A revert re-reviews.** `D_prior` was applied, then superseded by `D_bad`, and
  is now incoming again. Predicate fires.
- **A promotion does not.** The digest never stopped being applied — it is the
  *currently* applied value; only the layer that supplies it moved. **[rev6]**
  verified the digest is byte-identical across a promotion, so §7.2's "triggers
  no review anywhere" survives intact.
- **Re-signing does not.** Same digest, still currently applied, nothing
  withdrawn. §7.4's "re-signing is free" survives without needing the change-ID
  property at all — though **[rev5]** confirmed `jj sign` preserves the change ID
  (`a23c5484` → `f8c8ca9d`, `zxyvorrs` unchanged) and **[rev5-rev]** confirmed
  `jj squash --into` preserves the destination's, so the §8.2 runbook is
  unaffected either way.

#### What rollback *means*, per category

Reverting the manifest is one thing; putting the machine back is another. Each
category states its own semantics, because the honest answer differs:

| Category | Rollback semantics |
|---|---|
| `plugins`, `skills`, `agents` | **Reversible.** Reinstall the prior pin/version from the reverted value. The prior state is fully described by the item's value. |
| `packages` | **Reversible in practice, best-effort.** Package managers can usually pin back; where a manager cannot install an older version, the item **holds and alerts** rather than pretending. |
| `config_files` | **Reversible.** Managed keys are restored to their prior values from `applied/<host>.yaml`, which records exactly what roundhouse wrote. Unmanaged keys are untouched, as always. |
| `mcp_servers`, `hooks` | **Reversible for configuration; not for effects.** Removing a hook stops it firing; it does not undo what it already did. |
| `projects` | **Not reversible by this system.** Reverting a project entry stops managing it; it does not restore repository state. Says so here and in the category docs. |

**Anything non-reversible must say so in its category documentation**, and the
apply-time review shows that flag before the operator or agent passes the revert.
A rollback that silently cannot roll something back is worse than no rollback.

#### Runbook A — canary caught it (the normal case)

1. A canary host applies `plugins.ponytail` at the new digest, journals
   `outcome: applied`.
2. It breaks. The next fast run on that canary detects it (a failing item, a
   finding, or the operator says so).
3. The canary publishes a revert. Because the item never satisfied
   `canary_wait_hours`, **no non-canary host ever applied it** — §10.1's gate did
   its job.
4. The canary's own rollback is the revert flowing through its own gates.
5. §10.1 condition 2 also now sees a later `held`/`reverted` record for that
   item, so the original change cannot promote even if someone re-pushes it.

Blast radius: one machine, one fast interval.

#### Runbook B — canary missed it (the bad case)

1. The change passed canary and applied fleet-wide.
2. Any host publishes the revert — including the one that shipped the change;
   §7.3 makes no distinction, and there is no "owner" of a change.
3. Every host picks it up on its next fast run (≤ 25 min, §6.1), reviews it as a
   new change (new change ID, above), and applies the prior value.
4. Non-canary hosts wait `canary_wait_hours` behind the canary **for the revert
   too** — which is the one place this hurts, and it is deliberate: a revert is a
   change, and a panicked bad revert is a real failure mode. To move faster,
   `roundhouse fleet-rollback <item> --now` publishes the revert *and* records an
   explicit operator override in the journal, which is the only canary bypass in
   the design and exists solely for this case.

   Because it is the only bypass, it is bound and auditable rather than a flag
   that turns a gate off:

   - **`--now` is honoured only for an item whose introducing commit carries a
     `roundhouse-reverts` trailer that verifies** against history by §8.2b rule
     3's scoped check. It cannot accelerate a forward change, and it cannot accelerate a
     commit that merely *claims* to be a revert.
   - **It is scoped to the named item**, not to the run and not to the commit.
   - **It is signed and journaled** like everything else — `outcome: applied` with
     `override: canary` — so §7.3 attributes it to a host and every peer sees it.
   - **Doctor reports every override** seen in the journal in the last 30 days
     (§10.7). A bypass nobody counts is a bypass that becomes routine.
5. Categories that are not fully reversible are named in the review output before
   anything is applied (table above).

#### Rolling back a rollback

Nothing special: revert the revert. Change IDs make the chain readable
(`roundhouse-reverts` trailers form a linked list), and the journal's
`outcome: resolved`/`applied` records show what each host actually did at each
step.

## 11. Failure modes

| Failure | Behaviour |
|---|---|
| Layer file unparseable | Promotion refused, alert with line number, converge from last good `main`. Suppressed on the conflicted path (§6 step 4). |
| Conflicted layer file | Only items differing across heads are held (§8.3); the rest converges. **The run's agent resolves it from the evidence in the same run** (§8.2b); the host is publication-silent for that interval only. |
| A machine tries to enrol itself | Refused — a roster change must be signed by a key trusted at the parent, and a newcomer is not (§7.1). Its `joins/` request is inert. |
| A removed host keeps pushing | Future commits verify against a roster-at-parent that no longer lists it ⇒ `unknown` ⇒ held everywhere within one fast interval. Past commits stay valid (§7.1b). |
| A compromised host enrols an attacker key | Accepted by the crypto — and gains the attacker nothing they lacked (§7.12.1). Bounded by soak, the every-host alert, downstream review/canary/caps, and one-instruction revocation with default cascade. |
| An ephemeral leaf tries to write a fleet layer or sponsor a node | Refused by class (§7.1). The class is the security boundary; the TTL is hygiene. |
| A leaf's sponsor is revoked or rebuilt | The leaf stays valid — no verification path reads `sponsor:` (§7.1b). Cleanup is a default action in the revocation commit, not a rule. |
| A host is offline across a re-root | Archive protocol (§7.11.2). **Archive missing ⇒ hold + alert** — that branch *is* the rollback protection. |
| The materialized roster is hand-edited | Digest mismatch against the ratchet-derived roster ⇒ alert + full hold (§7.9). |
| Forged `roundhouse-reverts` or `roundhouse-session` trailer | Self-asserted text never wins a contest (§8.2b). A revert claim is verified against history and discarded if false; a human claim only escalates. |
| Secret quoted into a commit description | Redaction predicate runs over descriptions in the push range; push refused (§10.4). |
| Conflict the agent cannot resolve | A human is on either side (§8.2b rule 2), or no rule is grounded (rule 6). Item held, alert raised, everything else converges, and a human decides. |
| Layer commit with no roundhouse trailers | Read as `interactive/human` — the conservative default, biasing toward escalation rather than a confident wrong merge (§5). |
| A bad change reached the fleet | Signed revert on `main` through the normal gates (§10.8). Canary-caught: one machine. Canary-missed: every host within one fast interval, plus the canary wait unless `fleet-rollback --now` overrides. |
| Hub (GitHub) unreachable | Peer fetch over `rh-<name>` (§8.5) converges whoever can reach whom; the hub catches everyone up when it returns (§6.1). |
| Peer unreachable when a push-nudge fires | Skipped silently, no retry, no record. The poll floor catches that host within one fast interval (§6.1). |
| **Conflicted bookmark (`main??`)** | Detected via `bookmarks(exact:"main")`, merged by commit ID (§8.2). No command reads the bare name, so nothing exits 1. Clean merge → resolved automatically and pushed. |
| **Operator's unsaved-to-`main` edit present when the run reconciles** | `@` is described and included as a merge parent (§8.2 step 1). It is never discarded. |
| **No pending hand edit when the run reconciles** (the normal case) | `@` is empty, so it is **not** a merge parent. Including it would make an undescribed commit a permanent ancestor and refuse every future push (§8.2). |
| Run crashes between the two halves of a reconcile | Step 0 re-detects the state from the repo alone — `@-` conflicted and committed by this host — and resumes at step 4 (§8.1, §8.2). |
| First push on a store that has never fetched | The pre-push guard uses `present(main@origin)`, which is empty rather than an error (§8.4). |
| Unsigned / `unknown` / revoked / principal ≠ committer | Items from files that commit touched held. |
| Another host's rewrite stripped a signature | Same as unsigned; recovered when the authoring host re-signs (§7.4). |
| Divergent change ID on a layer file | Treated as a conflict. |
| Unknown category or layer directory | Held + alerted. |
| A standalone `hook` is desired before the re-implemented trust gate exists | The whole `hooks` category is **held** (§5.1.3): reviewed and journaled, never applied. Ungated hook installation is not permitted even transiently. |
| A definition and a desired item share a name (`jj`) | Different item ids — `definitions.packages.jj` vs `packages.jj` (§4, §5.1) — so different digests, verdicts and `applied/` keys. Without the prefix they would clobber each other into permanent apply mismatch. |
| A `version:` pin on homebrew with no `<name>@<version>` formula | Held + alert (§5.1.1). `brew install` has no `--version` and `brew pin` cannot select one, so the pin is refused rather than silently degraded. |
| A standalone `agent` or `hook` drifts on disk | Not detected today — the collector emits no such kind (§5.1.3's named gap). Applied and journaled, but no drift comparison until the collector lands. |
| A hook arrives from a definition-named source | The definition says *where from*; §10.6's trust gate still says *whether it runs*. Untrusted ⇒ held and reported `enabled_but_untrusted`, definition or not. |
| A logical package is `unavailable` on every manager the host has | Held + alert naming the logical name and the managers tried (§5.1). Never a guess, never a silent skip. |
| A `version:` pin the manager cannot express | Same treatment as `unavailable` — held + alert naming package, manager and requested version (§5.1.1). Never best-effort: a pin that degrades to "whatever installed" reads as a guarantee it is not. |
| `fleet-update` runs against a pinned package | Skipped by the update pass (§5.1.1), so the pin cannot be quietly undone. |
| `definitions.yaml` maps a name to the **wrong** artifact | Not caught by the store — the mapping is signed, reviewed and internally consistent, so nothing mechanical can know `jj-vcs.jj` was meant to be something else. Three things bound it: the definition is reviewed as its own item when it lands; the apply-time diff shows the **concrete resolution** rather than the logical name, so the wrong package is visible before it installs; and it reaches non-canary hosts only after `canary_wait_hours` (§10.1). Correction is an ordinary revert (§10.8). |
| Whole host file deleted or truncated | Removal guards trip (§10.3). A ≤5-item deletion is not caught by the cap and is not meant to be — apply-time review names each item. |
| Fetch fails entirely | Converge from last known. Never prune. Journal `source: none`. |
| Host reinstalled; `applied/<host>.yaml` gone or stale | §10.3 row 2 — adopt in place, review on digest mismatch. Never mass-disown. |
| Agent runs raw `git push` / `git commit` in the store | Pre-push check + doctor (§8.4); repo-local git pins stop the signing dialog (§3.2). |
| `fleet-init` run before a key exists | `[signing]` is not written yet, so init succeeds (§3.3). Writing it early makes `jj git init` fail outright — measured. |
| Clone points at a foreign repository, or at another roundhouse fleet | Genesis commit id compared against `identity.yaml`'s `store_id`, refuse (§7.5). Unforgeable: knowing the id does not let anyone produce a store with that genesis. |
| Origin force-pushed backwards | `main@origin` records it; `abandon-unreachable-commits = false` keeps local unpushed work. |
| `@` left on `main` by a crashed run | Next run's *first* act is the check and `jj new <main>`. Bites only while `main` is ahead of `main@origin`. |
| Canary applies an item then dies or goes silent | Liveness term (§10.1 condition 3) blocks promotion. |
| Two hosts rename simultaneously | Both records kept, newest `at` wins, alert on the loser. |
| Half-saved file snapshotted mid-write | jj commits it; the promote gate refuses; resolution reads `R`, so nothing is applied. |
| Two roundhouse runs on one host at once | Host-local lock in `store.run/` with the shipped stale-lock detection. Store-level locking is deleted. |
| Forged evidence under `journal/<other>/` | Signs as the forger; the §7.3 equality check rejects it as evidence. |
| Windows host | Operated by its WSL sibling, which holds a **second key** whose roster principal is `iris-windows@<domain>`; §7.3 needs no exception (§9.2). |
| Host returning after weeks offline | Not a special mode: fetch, merge by commit ID, agent-resolve any conflict (§8.2b). Steady state is minutes-fresh; this is the tolerated exception, absorbed without ceremony. |
| Host renamed but not re-enrolled | Its roster entry still carries the old principal, so its own new evidence is rejected by every peer. Doctor flags name/principal disagreement; a durable member's roster edit completes the rename (§9.1). |
| A host's key rotated | One roster edit: new key in, old key to `retired:` with `revoked_at_commit`. History stays valid; no overlap window to manage (§3.3, §7.1b). |
| jj missing | Hard failure with an install instruction. No fallback tier — and none is needed, because no lane requires one (§9.2). |
| Store on a network filesystem or DrvFs | Explicitly unsupported. Local disk on every host, including the WSL-operated one. |

---

## 12. Migration and enrollment

Recreate. Single user, recreate acceptable, and the shapes have no overlap worth
a converter. **Recreate is also what makes §7.3's committer-identity rule free:**
there is no back-catalogue of commits signed before the rule existed.

**Host 1 — genesis, agent-executed, no human at the machine:**

```sh
gh repo create <owner>/fleet-store --private     # the hub is transport, not authority
roundhouse fleet-init            # jj git init --colocate; remote add; §3.1 block
                                 # via `jj config set --repo`; §3.2 git pins;
                                 # .gitattributes, .gitignore, README.md.
                                 # NO [signing] yet — §3.3's brick constraint.
roundhouse fleet-enroll          # mint this host's keypair; user.email = its
                                 # principal; write [signing]; then write
                                 # trust/signers.yaml listing that key and
                                 # commit it SELF-SIGNED.  <- this commit IS
                                 # the genesis; store_id does not exist before it.
jj git push --bookmark main      # genesis is now published
roundhouse fleet-seed            # discovery -> hosts/<name>.yaml + applied/<h>.yaml
$EDITOR store/fleet.yaml         # lift the commonalities. Ten minutes.
roundhouse fleet-doctor          # every §10.7 check must pass before host 2
# fleet-enroll reports store_id (= the genesis commit id) UPWARD — to the
# orchestrator, or into the session transcript. It is an output, not an input,
# and it cannot be reported until the roster commit exists.
```

Ordering matters and §3.3 and §7.3a agree on it: `[signing]` must follow key
existence (or `jj git init` dies), and the genesis commit id cannot be reported
before the roster commit that *is* the genesis. So `fleet-init` cannot be the step
that names `store_id`.

**Hosts 2..N — one instruction, on a machine you already have:**

```sh
# on any enrolled host:
roundhouse fleet-add wren
```

That is the whole bootstrap for a new machine. The agent resolves `wren`, reaches
it over the existing SSH lane, installs prerequisites, runs `fleet-init`, has wren
mint a key, reads the key and possession proof back over the same channel, hands
wren the remote URL and `store_id` over that channel, commits the roster line, and
pushes (§7.3a A). **`fleet-init` still runs on every host** — the jj repo config is
host-local and outside the store, so a clone does not inherit it.

`roundhouse fleet-join --sponsor <host>` is the fallback when the instruction lands
on the newcomer instead (§7.3a B); `roundhouse fleet-remove wren` is removal
(§7.3a C). All three are agent-executed and none touches any other host.

**Revocation is one instruction and needs no fan-out.** `roundhouse fleet-remove
wren` moves wren's block to `retired:` in the roster, which propagates through the
ordinary store path within one fast interval, on every host, with no per-host step
(§7.3a C). This is the mechanism; there is no checklist.

**The KRL stays host-local and off the normal path.** It exists solely for the
deliberate "burn this key's history too" case, because **[rev9]** it is retroactive
and total — adding a key to the KRL flips every commit it ever made to `bad` and
holds every item resolved from every file those commits touched. When that *is* the
intent (the key's history is itself suspect), the out-of-band fan-out is the honest
procedure and it is small:

```sh
ssh-keygen -k -u -f $TRUST/krl <compromised-key.pub>          # $TRUST per §7.9
for h in <every host except the removed one>; do
  roundhouse-trustd-push rh-$h $TRUST/krl     # privileged lane where configured
  ssh rh-$h roundhouse fleet-doctor      # asserts the revoked key now fails
done
```

Until the last copy lands, that host's *history* still verifies where the KRL has
not arrived — but its *future* commits are already refused everywhere by the roster
removal, which travelled in-band. **The in-band lever bites first and bites
everywhere; the KRL is the deliberate second one.**

Gone from the shipped tree: `meta/host.json`, `leases/`,
`registry/config-base.json`, `desired/<scope>/<type>/<id>.json`, `host/<name>`
branches, `materialized/`, `snapshot/`, the `--autostash`/`meta-keep.json`
rescue, `sync_absorb_registry_command`, `sync_render_config_command`,
`sync_validate_record`, `sync_lease_command`, `sync_undo_command`, and every
`schema`/`schema_version` field — ~250 lines of deletion before this design's own
changes.

### 12.1 Test-harness consequences

The implementer judge's headline concern has an answer, and rev 1 did not give
one. Today `test-roundhouse` drives the sync block with **fake `jj` bins** and
real git, and the entire signing lane runs under
`ROUNDHOUSE_SYNC_SKIP_SIGVERIFY=1` — so §7's gates have effectively zero coverage
now.

This design splits cleanly along that seam, which is the reason it is affordable:

- **Content reads stay on the filesystem plus `yq`.** The layer fold, the
  `absent` pass, the digest pipeline, the `applied/` ownership table, the removal
  caps, the canary arithmetic and the redaction predicate are all pure
  yq/jq/bash over files. They fixture with **no jj at all** — and they are the
  parts most likely to be wrong.
- **jj is required for exactly three things**: `conflicts()` and the §8.2 merge/
  squash runbook, snapshot-marker rendering, and the §7.1/§7.3 signature gate.
  These get a **real-jj block that becomes mandatory**, gated on jj being
  installed in CI. It is a small, well-bounded suite: the labs behind this
  revision are ~200 lines of bash and cover the whole of §8.2.
- **`ROUNDHOUSE_SYNC_SKIP_SIGVERIFY` is deleted**, not carried. A gate with an
  env-var bypass and no coverage is not a gate. The fixtures it was standing in
  for — a two-key roster, a KRL, a principal-mismatch commit, a removed-member merge — are generated
  on demand by a ~30-line helper, verified in this revision.

---

## 13. What this repairs in the chassis

Attribution corrected per the reviewer's P2-1; where a judge is cited, the
finding really is that judge's and really is about the chassis.

1. **Group- and fleet-layer conflict amplification** *(operator judge's worst
   unacknowledged failure for the chassis)* — repaired twice: the
   file-or-directory escape valve now applies at every layer (§2), and the hold
   set is per item from per-head values (§8.3).
2. **Replicated `verdicts/`** *(all three judges, unanimously, against the
   chassis)* — split into published `journal/` and host-local
   `store.run/verdicts/` (§7.6).
3. **No conflicted-bookmark runbook.** The chassis alerted and held, which is
   correct but incomplete; the operator judge's M1 was a defect finding against
   the *other three* candidates, not against the chassis. §8.2's auto-merge is
   **this document's own invention**, and the deadlock rev 1 introduced with it
   was this document's own bug.
4. **No removal guard and no ownership record** *(all three judges)* — §10.3.
5. **Verification routed through git.** Owner-proxy §0.2/§0.3 named
   dotfiles-native and gitops-reconciler, not the chassis; the chassis was right
   about jj and right about the 1Password bug. What this document adds is making
   jj the *sole* gate (§7.1).
6. **Principal binding** *(owner-proxy §0.4 and the implementer's finding A; the
   operator judge did not rule on it)* — and the fix has since been superseded by
   measurement: per-host allowed_signers lines buy nothing, and the real fix is
   the committer-identity equality check (§7.3).
7. **Digest canonicalization** — jq owns what it can, the scalar form is
   normalized, and the claims that were false are removed (§7.2).
8. **Two stale claims in the chassis** — `yq` *is* installed, and the shipped
   `sync_verify_commit` *does* already set `gpg.ssh.program`.
9. **`jj mv` / `jj file move` do not exist** — §9.1 uses plain `mv`.
10. **No dead-machine story** — `lineage/` carries `event: retired` (§9.1).

---

## 14. Deliberately out

**On a judge's must-not-survive list:**

- **`jj git push --allow-conflicts` onto `main`** *(jj-native; all three judges)*
  — §8.4.
- **`enrolled: <change-id>` in a hand-edited file** *(owner-proxy against it;
  **operator judge for it**)* — dropped on the owner constraint, with the
  disagreement stated in §9.1 rather than hidden.
- **"Author-host binding, for free"** *(dotfiles-native; owner-proxy and
  implementer measured it false; the operator judge did not rule)* — replaced by
  §7.3's equality check.
- **`git verify-commit` as the *sole* gate** *(owner-proxy against the premise;
  the implementer scored dotfiles' testability 8/10 **because** it keeps
  `git verify-commit`, and ruled only against the "for free")* — jj is the gate
  and git is a fixture cross-check, which is a compromise, not a consensus.
- **`git.sign-on-push`** *(dotfiles-native; operator judge)* — signs at
  publication, so a relaying host signs another host's bytes.
- **The disjoint-root `status/<host>` branch** *(gitops; owner-proxy)*.
- **Converging to a merged value that exists in no commit** *(gitops; operator)*.
- **The two-workspace split** *(gitops; implementer)*.
- **Published `verdicts/`** *(chassis; all three judges)*.

**On an owner constraint:**

- **Schemas, `schema:`, `schema_version:`, and any validator** — the closed
  category set plus hold-on-unknown-category is the whole compatibility story.
  dotfiles-native's `minimum_roundhouse:` is the same idea one layer up and goes
  too.
- **Leases, CAS, TTLs, takeover** — §10.5.
- **Any git-only fallback tier** — and §9.2 shows none is needed.
- **Opaque ids, GUIDs, certname-as-identity, hash filenames** — §9.1.
- **File-per-item** — the escape valve is directory splitting.
- **Merge-behaviour configuration** — made unrepresentable (§4).
- **CRDTs and any auto-merge of intent.**
- **Push-to-peer.**
- **Host branches, `environments/`, a `role-` tier, empty scaffolding.**

**On ponytail grounds — proposed, and not worth its keep:**

- **Version *ranges* or constraint syntax** — a definition pins an exact version
  or says nothing and means `latest` (§5.1.1). Ranges need a resolver, and a
  resolver needs a lockfile, and neither is a thing five hosts need.
- **Language version managers and per-project versioning** — `nvm`, `pyenv`,
  `rbenv`, `asdf`. Host-level packages only (§5.1.2). Coexisting major streams
  are two logical names, which needs no mechanism at all.
- **A file per definition category** — one `definitions.yaml` keyed by category
  has the shape of a layer file and one reader; three files would have three
  paths and the same reader.
- **Per-host or per-layer definitions** — §5.1's ceiling: a genuine divergence
  means two logical names, not four layers of lookup tables.
- **`physical_host:` and `node_key:`** — no consumer anywhere in the design.
  Deleted (§5).
- **`signer:` and `held_reason:` in the published journal** — self-asserted and
  prose respectively, on a fleet-writable surface. Kept in `store.run/` (§5).
- **A doctor row for retire-then-reuse** — a once-a-decade event the ledger
  already makes visible (§9.1).
- **`snapshot.auto-track` / `max-new-file-size` pins** — measured to buy nothing
  on 0.44 (§3.1).
- **`git.private-commits`** — nothing but the gated `main` push publishes.
- **jj workspaces and `jj fix`** — the shared working copy is the
  point; the store is kilobytes; a YAML formatter on the commit path is an absorb
  pipeline in disguise.
- **A separate run-health journal record** — folded into the item record, except
  the one-line `alive` heartbeat §10.1 needs.
- **PillarStack's `__:` verbs**, **`ansible_group_priority`**, **transitive group
  membership**, **`kapp`'s `orphan` verb**, **a health model**,
  **confirm-or-rollback on apply**.

---

## 15. Provenance

| Element | From | Judge finding that drove it |
|---|---|---|
| Four-layer fold, maps-not-lists, `absent` knockout, closed category set | **inventory-layering** (chassis) | implementer: "four bullets I can implement without a decision" |
| File-or-directory at **every** layer | inventory-layering, extended | operator: group-layer conflict amplification |
| `ui.conflict-marker-style = "snapshot"` | inventory-layering | all three judges' #1 steal |
| Value-digest binding; re-signing costs no re-review | inventory-layering §7.2/§7.3 | owner-proxy steal #4 |
| `yq -o=json -I=0 \| jq -Sc`, jq owns what it can | gitops-reconciler §4 | implementer: CRLF re-digests |
| Digest mismatch ⇒ re-review, never reject-forever | dotfiles-native | implementer carry-forward #3 |
| Pin the verification program; `unknown` = failure; doctor asserts a revoked key fails | inventory-layering §1.1/§1.2 | owner-proxy §0.3, operator M8 |
| **jj** as the signature gate, trust roots per invocation | jj-native + inventory-layering | owner-proxy §0.2, operator M5/M6, implementer #2 |
| Doctor check for a bad KRL **path** | *none of the four* | operator M7 |
| Committer-identity == signature-principal equality check | *none of the four; supersedes both the judges' and rev 1's fix* | owner-proxy §0.4 + implementer finding A identified the hole; the shipped-code worker measured that allowed_signers patterns cannot close it |
| Three-way path taxonomy; `jj restore --from main@origin` | dotfiles-native | owner-proxy steal #3 |
| Per-host `upstreams/<id>/<host>.yaml` | inventory-layering | operator #5 — "strictly better than the discard rule" |
| `git.abandon-unreachable-commits = false` | **jj-native**, unique to it | owner-proxy steal #5 |
| `.gitattributes` `* -text` | dotfiles-native | implementer: only design to reason about line endings. *(Reason corrected: no git runs natively on the Windows box; the file protects a WSL-operated store from Windows-side editors writing CRLF.)* |
| Per-remote peer namespacing | all four | implementer #4 |
| Resolve from `R` never `@`; `jj new <main>` checked first | inventory-layering §1.7 | operator M12 |
| Conflicted-bookmark runbook; the `@`-as-parent and squash fixes | **this document** | operator M1 identified the state; the deadlock and the discarded hand edit were rev 1's own bugs |
| Item-level hold from per-head values | gitops-reconciler's granularity, without its merge | owner-proxy + operator on gitops' "exists in no commit" |
| Conflicts never publish; ban `--allow-conflicts` | jj-native's cost, all three judges' ruling | operator: "a new machine bootstraps into the wreckage" |
| `applied/<host>.yaml`, ownership table, removal caps, three code paths | **gitops-reconciler** §4/§6 + inventory-layering | all three judges |
| Report-don't-stomp on target drift | gitops-reconciler §5.5 (Argo's default) | operator dim-5 |
| `journal/` publishes evidence; verdict stays home | dotfiles/gitops/jj-native | all three judges against the chassis |
| `fleet-explain` per-key provenance *(file only; line numbers dropped)* | inventory-layering §3.4 | operator: "the only design where a human answers *why*" |
| `lineage/` with `event: retired` | this document | operator dim-7 criticised **dotfiles-native** for having no retirement story and praised jj-native's `enrolled:` as the only one proposed; this replaces that capability without a token |
| Canary liveness term | *none of the four* | reviewer P1-3 |
| Non-interactivity as a spec requirement | *none of the four* | reviewer P1-1 |
| Agent-driven conflict resolution; structured commit trailers; `outcome: resolved` journal record | **owner direction** | owner: "the context resolution needs to be handled by the LLM… don't ask the human" |
| Two cadences; `git ls-remote` poll floor; opportunistic push-nudge; traveling-laptop case | **owner direction** | owner: "the Tuesday machine should have already had the update"; "something should be checking at some reasonable frequency, but don't overload the machine"; hub-and-spoke baseline, Tailscale a recommendation not a requirement |
| §10.8 rollback: signed revert through the normal gates, per-category semantics, change-ID verdict clause | **owner direction** | owner: "there does need to be a robust rollback mechanism" |
| Offline reframed as tolerated exception, not steady state | **owner direction** | owner clarification: steady state is minutes-fresh; the agent absorbs offline reconvergence too |
| `definitions.yaml` — logical-name → concrete-artifact mapping, outside the fold, absent-entry-means-default | **owner direction** | owner: "there needs to be a specific definition of the package mapping, because jj could have different names depending on which manager and operating system installs it" |
| `latest` by default with opt-in exact pins, enforced-or-held per manager; update pass skips pinned | **owner direction** | owner: pinning is opt-in because the fleet auto-updates |
| Major streams as separate logical packages (`node@24` / `node@26`); nvm/pyenv/asdf and per-project versioning explicitly out | **owner direction** | owner: "I don't want to get into the messiness of Node versioning for Python… don't overcomplicate it" |
| `plugins:`/`skills:` definitions on the same pattern; host map-form override beats the definition | **owner direction** | owner: "ponytail could be defined as a plugin somewhere — rationalize the process" |
| Four agent-surface categories (plugins/skills/agents/hooks) × two delivery forms (plugin-delivered / standalone); per-harness enable table with explicit N/A; Codex plugin-approval flow; collector gap named | **owner direction** | owner: "Don't forget skills, agent definitions, and hooks — which usually come in the form of a plugin these days, but not always" |
| `definitions.` item-id namespace | amendment review A2 | definition and desired item shared one verdict/applied key and clobbered each other |
| Homebrew pins resolve only via `<name>@<version>` formulae, else held | amendment review A3 | **[rev8]** `brew install` has no `--version`; `brew pin` cannot select a version; `terraform@1.9.8` is not a formula |
| Hook trust gate re-implemented against the new layout; `hooks` held until it lands | amendment review A1 | the shipped gate reads `materialized/` off a status branch keyed on `.schema` via raw git — all four deleted or banned here |
| §10.6 citations re-verified against post-refactor `lib/`; three claims downgraded from "carried unchanged" | reviewer flag | no "carried unchanged" claim may cite code that no longer exists in that shape |
| **Trust ratchet** — in-store `trust/signers.yaml`, changes valid only if signed by a key trusted at the commit's PARENT; genesis via the store-id chain | **owner direction** + both researchers, converged independently | owner: "no primaries applies to EVERYTHING — there can't be a primary/sole anything"; "every time a new host is added, a human must not be needed on each other host" |
| Ancestry property (sponsor authors the enrollment, so it precedes everything the newcomer writes); two-sided verification (roster at ancestry **and** at head); possession proof in namespace `roundhouse-enroll` | prior-art researcher (git in-repo signers, Keybase sibkeys, Apple circle, OpenSSH `hostkeys-prove`) | no host ever sees a newcomer's work without its enrollment |
| Zero-touch enrollment both directions; genesis, removal and reparenting agent-executed; authority root = GitHub custody × instruction-chain integrity, with the prompt-injection residual **named** | first-principles researcher | owner's zero-human-steps constraint |
| Durable/ephemeral classes as the security boundary; TTL only in the ratchet's roster derivation, never native `valid-before` | first-principles researcher | measured: jj has no verify-time; native expiry is retroactive and renders as unexplained `unknown` |
| Lineage is cleanup metadata, never validity; cascade is a default **action** | first-principles researcher (rider correction) | auto-invalidating leaves on sponsor departure would be retroactive revocation a third time |
| Checkpoints are **git tags** (not bookmarks); archive ref **mandatory** because a re-root is indistinguishable from a rollback attack without it; three decoupled aging policies on the existing 12 h run | first-principles researcher | measured: `builtin_immutable_heads()` already includes `tags()` |
| Root-owned materialization via the privileged lane, degrade-to-same-user **with alert**, plus per-run digest compare | both researchers, same position | the two controls fail in different directions |
| Domain defaults ladder (own domain → `<gh-user>.fleet.internal` → `fleet.internal`) | **owner direction** | safe because trust anchors to the roster, not the name |
| Implementation clarifications from the shipped conversion: per-parent read in the §7.1a snippet, the two yq traps (quoted timestamps, `map()`/`//`-defaulted assignment), `enrolled_at` derived per-parent, `genesis` takes no soak, archive triggers on a changed root, digest compares against the reviewed ref, removals count as changes, `trustd` declared as a seam | trust conversion report | no behavior changes — the code follows the rules; these are the places the spec was thinner than the verified reality |
| Implementation clarifications from the shipped trust conversion: per-parent read in §7.1a's snippet; the two yq traps (quoted timestamps, `map()`/`//`-defaulted assignment); `enrolled_at` derived per-parent; `genesis` takes no soak; the archive protocol triggers on a changed root; the digest compare uses the reviewed ref; removals count as changes; `roundhouse-trustd` declared a seam | trust conversion report | no behavior changes — the code follows the rules; these are the places the spec was thinner than verified reality |
| Rule 3 evaluates **every** parent, not "the parent" | reviewer T1 | measured: a removed member's merge verifies `good` under one parent's roster and `unknown` under another; any-parent ACCEPTs, every-parent HOLDs, legitimate merges unaffected |
| `generation` high-water mark gets `reviewed-ref`'s custody | reviewer T2 | in the store it is attacker-controlled by construction; in `store.local/` it falls to the shell compromise root ownership exists to survive |
| Residual 7 — **availability**, and class-refused commits hold only the items they changed | reviewer T4 | all other residuals are integrity; every control fails to `hold`, so the lowest-trust class could freeze a shared layer fleet-wide by touching it once |
| Windows lane: second key + second instance, no §7.3 exception | *none of the four* | reviewer P0-6 + KTD15; re-review R2 (the `operated_by` exception rev 2 shipped was a privilege escalation) |
| Self-rendered SSH aliases, seeding, unanimity promotion, canary, hook trust, self-update containment, private-remote gate | shipped spec's retained capabilities | — |

---

## 16. Review resolutions

Every finding, one line: fixed-how, or rejected-why.

### P0

- **P0-1 · conflicted ancestor bricks publication** — **Fixed.** §8.2 step 4
  squashes the resolution *into* `M` with
  `jj squash --into "$M" --use-destination-message`; §8.4's guard and §10.7's
  doctor row narrowed from `::<target>` to `main@origin..<target>`. **[rev2]**
  verified: push refused before, `conflicts() & ::@` empty and push succeeds
  after.
- **P0-2 · reconcile discards the operator's in-flight edit** — **Fixed.** §8.2
  step 1 describes `@` and step 2 passes `$WC` as a merge parent. **[rev2]**
  verified: `groups/testing.yaml` survives; jj dedupes the parent list; and an
  *undescribed* parent makes the later push fail, which is why the `describe` is
  in the runbook.
- **P0-3 · `.jj/repo/config.toml` does not exist / hosts 2..N unconfigured** —
  **Fixed.** §3.1 uses `jj config set --repo`; §12 runs `fleet-init` on every
  host; §10.7 asserts effective values via `jj config get`. **[rev2]** verified
  the migration and the resulting `$HOME` symlink in the tree.
- **P0-4 · fresh host bricks itself at `fleet-init`** — **Fixed.** §3.3 splits
  `fleet-init` (no `[signing]`) from `fleet-enroll` (mint the key, register it in
  the roster, then `[signing]`). **[rev2]** verified worse than
  reported: `jj git init --colocate` itself dies and the repo is never created.
- **P0-5 · store identity deleted, clone adopts anything** — **Fixed.**
  store identity restored (§2, §7.5), asserted at clone/init/set-remote. *(Now the
  genesis commit id rather than a minted marker file — see §7.5.)*
  **[rev2]** verified `jj git clone` checks nothing.
- **P0-6 · the Windows host cannot exist** — **Fixed.** §9.2: nothing runs on
  native Windows, the WSL sibling is an ordinary jj host so no git-only tier is
  needed, and the store lives in the WSL filesystem. `hosts/iris-windows.yaml`
  restored with `wsl_sibling:`. *(Evidence attribution: rev 2 solved it with an
  `operated_by:` exception in §7.3, which the re-review showed was a privilege
  escalation — see R2. It is now a second key and a second roundhouse instance,
  with no exception in §7.3.)*

### P1

- **P1-1 · nothing pins non-interactivity** — **Fixed.** §3.2 is a new
  requirement section: `ui.paginate`/`ui.editor`, message flags on every rewrite,
  repo-local git pins (**[rev2]** the owner's global `commit.gpgsign=true` +
  `op-ssh-sign` confirmed live, and the repo-local override confirmed to win),
  and the run environment. Doctor asserts all three.
- **P1-2 · rewrites re-sign the descendant chain as this host** — **Fixed** by
  per-host `user.email` = the host's roster principal (§3.1), the same line the
  coordinator's principal-binding correction requires. **[rev2]** reproduced the
  hazard under a shared email and verified the fix strips rather than
  re-attributes; §7.4 and §7.7 gained the row.
- **P1-3 · canary silence reads as success** — **Fixed.** §10.1 condition 3, a
  liveness term, plus the `alive` heartbeat record in §5. §16 Q1 re-asked against
  the fixed gate.
- **P1-4 · promote gate and conflicted path both fire** — **Fixed.** §6 step 4
  states the precedence: §8.2 wins, the promote gate is skipped, and the
  parse-failure alert is suppressed for conflicted paths.
- **P1-5 · missing ownership row** — **Fixed.** §10.3 row 2 (`in layers, not in
  applied, present on host` → adopt in place; review on digest mismatch).
- **P1-6 · canonicalization claims false** — **Fixed.** §7.2: "number form"
  deleted (**[rev2]** jq preserves `1.10`), scalar→`{state:}` normalization added
  so §4's polymorphism is real at the digest layer, YAML 1.1 coercion documented
  with measured examples.
- **P1-7 · secret sweep cannot catch its own case** — **Fixed.** §10.4 sweeps the
  push range with a per-commit `jj diff -r <c> --name-only` walk (**[rev2]**
  verified it catches create-then-delete) and the predicate gains a line number.
- **P1-8 · SSH render takes fleet-writable input** — **Fixed.** §5 reuses the
  shipped `sync_validate_fetch_url` predicate on `hostname`, `tailnet_name`,
  `user` and `<name>` before rendering or building a peer URL; refuse and alert.
- **P1-9 · `auto-track = all()` with no `.gitignore`** — **Partly rejected,
  partly fixed.** **[rev2]** on jj 0.44 the default `auto-track = "all()"` did
  *not* track `.DS_Store`, `*.swp` or `*~` — the three examples the finding names
  — so the premise is false. The finding's second half is right: those three
  config lines had no rationale, so they are deleted, and a `.gitignore` ships
  anyway to protect the colocated **git** side from `git add -A`.

### P2

- **P2-1 · attribution inflation** — **Fixed**, every instance: header now states
  the implementer's 98–98 tie and the cheaper-build caveat; §7.3/§13.6/§15 say
  two judges, not three, on principal binding; §9.1 and §14 surface the
  `enrolled:` drop as a judge conflict resolved against the operator judge on an
  owner constraint; §14 states the implementer's pro-`git verify-commit` position;
  §13.3 and §13.5 no longer claim judge findings against the chassis that were
  findings against other candidates; §15 credits the runbook to this document.
- **P2-2 · blanket sourcing** — **Fixed.** Every claim is now `[judges]`,
  `[rev2]`, or `[unverified]`. "jj merges never fail" and the resolution `Hint:`
  string are dropped as load-bearing claims; `abandon-unreachable-commits`
  behaviour is marked `[unverified]` with the reason it is pinned anyway.
- **P2-3 · no KRL distribution or refresh story** — **Fixed.** §12 names the
  out-of-band revocation procedure and its residual window; §10.7 generates the
  good/revoked fixtures on demand so nothing expires on an unwritten date.
- **P2-4 · the bare-`main` lint is not one grep** — **Fixed.** §8.1 downgrades
  the grep to explicitly partial and makes the real check an executable doctor
  test that runs the run's own revsets against a conflicted bookmark.
- **P2-5 · `fleet-explain` line numbers** — **Fixed by deletion, and the
  suggested fix rejected.** **[rev2]** `key | line` is *also* wrong: yq's `line`
  does not count comment-only lines, so in a commented file — which every layer
  file is — both operators drift. Line numbers dropped; file-level provenance
  kept.
- **P2-6 · `absent` is not part of the fold** — **Fixed.** §4 states the scoped
  knockout pass and why a recursive `del(...)` would be wrong.
- **P2-7 · capabilities dropped silently** — **Fixed.** §10.6 carries hook trust,
  `sync-adopt-pin`, the private-remote gate, `core.symlinks`/store-symlink
  detection (with a new reason from P0-3) and stale-lock detection; §5 restores
  the `proposals/` record shape, `wsl_sibling:`, the tailnet-else-hostname
  fallback, and chezmoi co-ownership detection with its doctor watch.
- **P2-8 · `max_removals_per_run` misses the small truncation** — **Fixed by
  narrowing the claim.** §10.3 adds `max_removal_fraction` and states plainly
  that neither catches a one-line deletion and that nothing should — that is a
  legitimate edit whose defence is item-level review.

### P3

- **P3-1 · `git verify-commit -c`** — **Fixed.** `git -c … verify-commit`
  everywhere. **[rev2]** confirmed `unknown switch 'c'`.
- **P3-2 · unquoted multi-line word splitting; `$ORIGIN` redundant** —
  **Fixed/accepted.** §8.2 keeps `$ORIGIN` (harmless, and it is *not* always in
  `$LOCAL` — an offline host that never fetched has no local target for it) and
  the runbook is now marked bash. **[rev2]** confirmed jj dedupes.
- **P3-3 · `@`-on-`main` blast radius overstated** — **Fixed.** §8.1 credits the
  immutable-commits refusal and scopes the hazard to the unpushed window.
- **P3-4 · citation slips** — **Fixed.** §15 cites inventory-layering §7.2/§7.3
  and §1.1; §16 Q2 says two candidates auto-pass, not three.
- **P3-5 · `.gitattributes` rationale vestigial** — **Fixed.** §15 restates the
  reason as Windows-side editors writing CRLF into a WSL-operated store.
- **P3-6 · untestable gates; the fake-jj problem unanswered** — **Fixed.** §12.1
  is new: the yq/jq core fixtures without jj, a small mandatory real-jj block for
  the three things that need it, `ROUNDHOUSE_SYNC_SKIP_SIGVERIFY` deleted, and
  the cross-host digest check replaced with a local recompute plus
  `fleet-doctor --all`.

### Simplicity audit

`physical_host:`, `node_key:`, journal `signer:`, journal `held_reason:` and the
retire-then-reuse doctor row are **all deleted** (§5, §9.1, §14). The
`git verify-commit` cross-check is **kept**, with the self-contradiction
acknowledged in §7.1 and an instruction to delete rather than trust it if it ever
drifts.

### Owner direction (rev 5)

Three substantive changes and two closures, all verified in
`/private/tmp/dsc-fix/lab14.sh` and `lab15`:

- **Agent-driven conflict resolution.** §8.2 step 3b + new §8.2b: the run's agent
  gathers evidence (both sides' values, trailers, timestamps, each host's journal
  trend, `applied/`), decides by a six-rule ladder, and records the resolution
  with its rationale. Escalates only on two contradictory recent human edits. §5
  adds the commit trailer block the resolver depends on and an
  `outcome: resolved` journal record. **[rev5]** verified the full description
  block survives the git wire and that a peer can read each side's committer,
  timestamp and description *while the merge is still conflicted*.
- **Fast propagation.** New §6.1: two cadences (fast 20 min ± 5 for propagation,
  12 h for maintenance), a stated freshness target, hub-as-baseline with
  opportunistic peers, a `git ls-remote` poll floor, an optional outbound-only
  push-nudge, and the traveling-laptop case. **[rev5]** verified `ls-remote`
  returns a directly comparable head id and **moves no local ref**, and that a
  no-op fast run is one round trip plus a string compare.
- **Robust rollback.** New §10.8: signed revert through the identical gates,
  `jj op restore` for local aborts, both canary runbooks, per-category
  reversibility, and rolling back a rollback. **[rev5]** verified `jj revert`
  restores the content exactly, the digest returns to the prior value
  (`0ada03724bef`), and the change ID is new (`krtnonorpswt` ≠ `skwvtltpmpnz`).
  That last fact forced a change to the apply gate, because digest alone would
  auto-apply a revert. *(Rev 5's first attempt — matching digest **and** change ID
  — was withdrawn in rev 6: it re-reviewed every promotion and amplified across a
  layer file. See V2/V3; the shipped mechanism is §10.8's revert-signature
  predicate.)*
- **Q1 closed** — accept publication silence; the evidence bookmark guarded a
  state that agent resolution plus the fast cadence removes.
- **Q2 closed** — always-review stands; the reviewer is the run's agent, so it
  costs no human interaction. Verdicts record `reviewer: agent | human`.

### Final gate on the ladder (W1–W2)

Two P1s of the same shape — a rule above rule 4 short-circuiting human
escalation. Both closed by one reordering plus one comparison; the evidence-class
framework is unchanged. Verification: `/private/tmp/dsc-fix/lab18.sh`, which
implements the ladder and runs every scenario.

- **W1 · P1 — rule 2 lost rev 5's scoping, so any true-but-stale revert claim
  won** — **Fixed.** The revert rule now requires **both** `mine == replaced`
  *and* `theirs == set_to`: the claim must be about *this* conflict, not merely
  true about history. One more read of a revision the rule already fetches.
  **[rev7]** verified against the demonstrated attack (`v1 → C:v2 → v3`, hand-edit
  `v4` vs `v1` claiming `reverts C`): agent-vs-agent it now falls through to rule
  6 (`theirs(v4) != set(v2)`), and with a human on a side it never passes rule 2.
- **W2 · P1 — both sides journal `applied` before pushing, so the
  applied-elsewhere rule arbitrated human-vs-agent with no defined winner** —
  **Fixed two ways, as prescribed.** (a) The human-escalation rule moves from 4 to
  **2**, immediately after "not actually contested", so every arbitration rule
  below decides agent-vs-agent only. (b) The applied-elsewhere rule fires only
  when **exactly one** side qualifies. **[rev7]** verified: the modal case (both
  applied, one human) escalates at rule 2; both-applied agent-vs-agent falls
  through to rule 6.
- **Regression check.** **[rev7]** all six original scenarios still land where
  intended: uncontested → converge; missing trailers → escalate at rule 2;
  exactly-one applied-elsewhere → that side wins; agent-vs-agent >1 interval apart
  → later wins (rule 5 confirmed still reachable); within one interval → escalate;
  no evidence → escalate. The honest scoped revert between two agents still
  resolves without escalation.

### Targeted pass on the rev-5 additions (V1–V13)

All in the new surface and its seams; everything previously approved held.
Verification: `/private/tmp/dsc-fix/lab16.sh`, `lab17`.

- **V1 · P1 — a forged trailer could beat a human edit** — **Fixed by
  re-deriving the ladder around evidence grounding.** §8.2b now classifies every
  input as *signed history* / *replicated journal* / *self-asserted text* and
  states the hard rule: **self-asserted may never outrank grounded, and may never
  win on its own — only point at evidence or escalate.** Rule 2 verifies the
  `roundhouse-reverts` claim against history; rule 4 turns "human wins" into
  "either side human ⇒ escalate", so forging and omitting land in the same place.
  **[rev6]** verified with the merge still conflicted: honest revert VERIFIED
  (`my={"pin":"v1"} replaced={"pin":"v1"}`), forged claim REJECTED
  (`my={"pin":"v9-forged"}`).
- **V2 · P1 — the change-ID gate re-reviewed every promotion** — **Fixed by
  withdrawing the gate.** **[rev6]** reproduced: promotion keeps the digest input
  byte-identical (`{"state":"enabled"}`) while the introducing change moves
  (`vztuxprvlvvk` → `qmmxsllwvtqm`). §10.8 now uses a **revert-signature
  predicate** — the incoming digest was applied here and later withdrawn — read
  from this host's own journal. A promotion never satisfies it; §7.2's "triggers
  no review anywhere" is restored.
- **V3 · P1 — per-file verdict invalidation amplified across a layer** —
  **Dissolved by the same fix.** With no change ID in the gate there is nothing
  per-file to invalidate, so one resolved conflict in `groups/development.yaml`
  no longer re-reviews every item that layer contributes. The reviewer's proposed
  fix (record the introducing change per item) is not needed and is not added.
  The journal's `change:` stays as provenance, explicitly not a gate.
- **V4 · P1 — trailers and resolution prose bypassed the redaction floor** —
  **Fixed.** §10.4's existing per-commit push-range walk now runs
  `sync_quote_is_secret` over `description` as well as the `findings/`/`alerts/`
  paths, and free-text trailers are capped at the same 400 bytes. New doctor row.
- **V5 · P2 — the fast run never published local work** — **Fixed.** The
  short-circuit now requires nothing to pull **and** nothing to push: remote ==
  local, empty `present(main@origin)..heads(bookmarks(exact:"main"))`, and empty
  `@`. **[rev6]** verified all three states, including that the predicate does not
  error on a never-fetched store.
- **V6 · P2 — rule 5 decided on a forgeable timestamp** — **Fixed.** **[rev6]**
  confirmed `JJ_TIMESTAMP=2099-01-01T00:00:00Z` yields exactly that committer
  timestamp. Rule 5 now reads journal `at` fields (already skew-checked by
  §10.7) and does not fire inside one fast interval, escalating instead.
- **V7 · P2 — rule 3 overclaimed "journaled healthy"** — **Fixed.** Reworded to
  "applied and not subsequently reverted", matching §10.1's own disclaimer and
  what condition 2 already computes.
- **V8 · P2 — `--now` was an unbound self-asserted bypass** — **Fixed.** It is
  honoured only for an item whose introducing commit carries a *verified*
  `roundhouse-reverts`, is scoped to the named item, is signed and journaled with
  `override: canary`, and doctor reports every override in the last 30 days.
- **V9 · P3** — `timeout 10` bounds the remote command, not just the connect.
- **V10 · P3** — `reachable_peers` defined inline.
- **V11 · P3** — stated where the claim is made: a nudge hitting a peer's
  host-local lock degrades to poll speed, so "within seconds" is best case.
- **V12 · P3** — rule 5's "newest `roundhouse-intent` wins" was a wording bug
  (prose carries no timestamp); it reads journal `at` now.
- **V13 · P3** — §10.8 moved after §10.7.

### Re-review of rev 2 (R1–R12)

Every remaining finding lived inside a rev-2 P0 fix. All are closed. Verification
scripts: `/private/tmp/dsc-fix/lab10.sh`, `lab11.sh`; ledger `VERIFIED.txt`.

- **R1 · P0 — the P0-2 fix bricks the push in the normal case** — **Fixed.**
  §8.2 step 1 accumulates `PARENTS` and adds `@` **only when `@` is non-empty**;
  an empty `@` has nothing to preserve and is undescribed, so it is never a merge
  parent. **[rev3-fix]** verified both ways on a clean merge: rev 2's form →
  `Won't push commit 8e379e63bba2 since it has no description`; the fixed form →
  `bookmark: main [move forward from c01e2945 to f30480ca]`. Re-verified with a
  pending hand edit: push succeeds **and** `groups/testing.yaml` reaches origin.
  Re-verified the conflicted path end to end (merge held, cross-run resolve,
  squash, empty push range, push succeeds). §11 gained the normal-case row.
  Also documented: `jj git push` leaves an empty undescribed `@`, which is why
  §8.2 step 5 names its target instead of running a bare `jj new`.
- **R2 · P1 — `operated_by` is a privilege escalation** — **Fixed by deletion.**
  §9.2 gives the WSL sibling a second key with roster principal
  `iris-windows@<domain>` and runs a second roundhouse instance; §7.3 row 3 is a
  pure equality check with **no exception**; `operated_by` is removed from the
  schema and the trust path. `wsl_sibling:` stays as apply-path documentation
  that grants nothing. This is what keeps the Q4 call sound.
- **R3 · P1 — the narrowed guard errors on a never-fetched store** — **Fixed.**
  `conflicts() & present(main@origin)..<target>` in §8.4 and §10.7.
  **[rev3-fix]** verified: bare form → ``Error: Revision `main@origin` doesn't
  exist``; `present()` form → empty, exit 0.
- **R4 · P1 — §8.1's invariant fires on the state §8.2 leaves open** —
  **Fixed.** §8.1 gains exactly one exemption (`@-` conflicted **and created
  locally** ⇒ `@` is the resolution workbench; skip the `jj new`, go to §8.2
  step 4), and §8.2 gains an explicit step 0 that recovers that state from the
  repo alone. **[rev3-fix]** verified the state is readable with no persisted
  variables and that the resulting squash-and-push succeeds.
- **R4-leak · P1 — the step-0 exemption was spoofable** — **Fixed by deletion.**
  Rev 3's exemption tested `committer.email()`, which is self-asserted and
  unsigned; **[rev4-fix]** a peer setting `JJ_EMAIL` to the victim's principal
  and pushing a conflicted merge with `--allow-conflicts` made the victim's own
  §8.1 remedy parent `@` onto the fetched head, firing step 0 on a commit the
  victim never made and causing it to squash-resolve and republish a conflict its
  operator never saw. Replaced with the locality test
  `(conflicts() & @-) ~ ::remote_bookmarks()`, which deletes the committer read
  and the `$PRINCIPAL` variable from the runbook. Verified: empty on the leak
  state (falls through to hold-and-alert), non-empty on the legitimate workbench,
  squash-and-push still succeeds. The same run also confirmed the
  `.jjconflict-*` doctor check must be over the **git** tree — it is the only
  check that sees an inbound published conflict, since there the conflicted
  commit *is* `main@origin` and the range revset is empty.
- **R5 · P2 — the marker cannot distinguish two roundhouse fleets** — **Fixed.**
  `store_id:` in host-local `identity.yaml` is the expected value; §7.5 compares
  rather than checks presence; §12 pastes it before the clone.
- **R6 · P2 — the workbench becomes a phantom head in §8.3** — **Fixed.** §8.3
  now folds over the recomputed **bookmark heads**, never `parents($M)`, so an
  item the operator is midway through editing is not read as a two-host
  disagreement. Recomputing is stateless because `main` does not move on the
  conflicted path.
- **R7 · P2 — the principal goes stale on rename** — **Fixed.** §9.1 states
  that a rename requires a roster edit and is incomplete without it,
  that doctor flags name/principal disagreement, and that moved evidence is
  attributed to the mover **by design** (the originals remain in the log under
  the old path).
- **R8 · P2 — key rotation must not hold the whole fleet** — **Fixed, and the
  mechanism is now simpler than the fix that was written for it.** Rotation is one
  roster edit: the new key in, the old key to `retired:` with `revoked_at_commit`
  (§3.3, §7.1b). History stays valid because each commit is verified against the
  roster at *its* parent, so there is no overlap window to stage and nothing to
  remove later.
- **R9 · P3 — `user.email` set before a key exists** — **Fixed.** Moved
  out of the `fleet-init` block into the `fleet-enroll` block, with the reason
  inline in both places.
- **R10 · P3 — three commands run outside the repo config** — **Fixed.** §3.2's
  environment is now scoped to *every* roundhouse invocation, and the three
  outliers (`jj git clone`, the doctor's synthetic repo, the git cross-check
  fixture) are named with their explicit per-invocation `--config` flags.
- **R11 · P3 — wrong ssh non-interactivity knob** — **Fixed.**
  `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` replaces `SSH_ASKPASS_REQUIRE=never`,
  with a note that the latter suppresses only the GUI prompt.
- **R12 · P3 — the hold message misreports a revocation as an identity
  mismatch** — **Fixed.** §7.3 branches on `status` first: three messages, and
  only the identity-mismatch one names two principals.

---

## 17. Open questions — none

Both questions rev 3 left open are closed by owner direction, and the reasoning
is recorded here because the closures depend on other changes in this revision.

**Q1 — publication silence during an unresolved conflict: CLOSED. Accept the
silence; no evidence bookmark.**
The bookmark existed to stop a conflict sitting unnoticed for days while the host
published nothing. Two changes in this revision remove that state rather than
mitigate it: §8.2b makes the run's **agent** the resolver, so a conflict is
resolved in the run that finds it, and §6.1's fast cadence means the run that
finds it happens within ~20 minutes of the divergence. The silence window is
minutes. The only case that stays open longer is an §8.2b escalation — chiefly
rule 2, a human on either side — and that case has a human's attention by
construction, because a human just made one of the edits. A second bookmark would be a mechanism
guarding a case the design no longer has.

**Q2 — review of edits authored on the applying host: CLOSED. Always-review
stands, and the reviewer is the run's driving agent.**
The cost objection ("one keystroke per edit on the box you typed it on") assumed
a human at the prompt. Under the same direction that produced §8.2b, the reviewer
is the agent: it reads every diff, on every host, including the host that
authored the change. The human reviews only in supervised sessions and on
escalations. So always-review costs no human interaction at all, and it keeps the
property that made it right — a typo made at 2am gets one look before it applies,
and there is no auto-pass branch whose "who authored this" test §7.3 already
showed to be subtle. The verdict record carries `reviewer: agent | human` so the
distinction is visible after the fact.

**Nothing else is open.** Q3 (`applied/<host>.yaml` shared vs host-local) was
closed as **shared** in rev 3 on the owner's constraints. Q4 (any host edits any
layer file) and Q5 (conflict publication policy) were surfaced as declared
judgment calls in §7.3 and §8.4 and both were reviewed and upheld.
