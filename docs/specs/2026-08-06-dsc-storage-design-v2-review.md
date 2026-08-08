# Adversarial review — `dsc-merged-proposal.md`

Verdict: **needs-rework**. P0 ×6 · P1 ×9 · P2 ×8 · P3 ×6.

The chassis choice and the layering/digest core are sound and the judges' rulings
are substantively honoured. What breaks is the **jj operational layer**: the
conflicted-bookmark runbook deadlocks the store, the config block lands somewhere
jj 0.44 moves it, and the principal binding that §10.1 depends on does not survive
a local rewrite. All P0s are mechanical, not architectural.

Everything marked **[verified]** was measured by me on the installed jj 0.44.0 /
yq v4.53.3 / jq 1.8.2 in a throwaway repo at `/private/tmp/dsc-attack`, isolated
via `JJ_CONFIG`.

---

## P0

### P0-1 · After any real content conflict, the store can never push again
**Breaks:** §8.2 step 3, §8.4 pre-push guard, §10.6 doctor row 7, §11 row 2.

**[verified]** Two clones, divergent edits to the same key, conflicted bookmark,
ran §8.2 verbatim. The merge `M` is conflicted; the human resolves in `@` (a child
of `M`) exactly as §8.2 prescribes; jj prints the Hint §8.2 quotes. Then:

```
$ jj git push --bookmark main
Error: Won't push commit f2433eb49647 since it has conflicts
Hint: Rejected commit: zkptxsxz f2433eb4 (conflict) (empty) reconcile wren 2
```

§8.2's closing claim — "the next run promotes `@` to `main` and pushes everything
at once" — is false. The conflicted `M` is a permanent ancestor of every future
`main`. §8.4's own guard ("refuses if any head being published has a conflicted
ancestor") and §10.6's `conflicts() & ::<main targets>` is empty then fail forever.
One conflict bricks publication for the whole fleet, and §8.4's "it costs less than
it appears, because everything pushes in one fast-forward the moment the human
saves" is the exact opposite of what happens.

**Smallest fix:** the resolution must land *in* `M`, not in a child. Replace §8.2
step 3 with: leave `@` on the merge while it is conflicted, or (if a child is kept
for the workbench) the next run runs `jj squash --use-destination-message` before
promoting. **[verified]** that fix: after the squash, `conflicts() & ::@` is empty
and `jj git push` succeeds.

### P0-2 · The reconcile silently removes the operator's in-flight hand edit from disk
**Breaks:** §8.2 step 2, §6 step 2, §11 ("a bad edit narrows what is applicable;
it never breaks the store").

**[verified]** With `groups/testing.yaml` hand-written into `@` before the run,
`jj new -m "reconcile" $LOCAL $ORIGIN` reports `Added 0 files, modified 1 files,
removed 1 files` — `groups/testing.yaml` leaves the working copy. It survives only
as an **undescribed orphan commit** not reachable from `main`; nothing in the run's
output mentions it, and §8.2 never acknowledges that `@` had content. The operator
sees a file they saved five minutes ago vanish from their editor mid-run.

This is the "hand edit while the scheduled run is mid-apply" scenario, and the
design's answer to it (§6 step 2: "there is no uncommitted state and therefore no
'forgot to commit'") is what causes it — the edit *is* committed, into the commit
the runbook then walks away from.

**Smallest fix:** §8.2 step 2 includes `@` as a parent of `M` when `@` is non-empty
(`jj new -m … $LOCAL $ORIGIN $(jj log -r @ …)` — jj dedupes duplicates,
**[verified]**), or the run refuses to reconcile and tells the human to promote
first. Either way the merge must not discard `@`.

### P0-3 · §3's config file does not exist in jj 0.44, and hosts 2..N never get the config
**Breaks:** §3 (whole block), §12 per-host bootstrap, §1 bet 2, §10.6.

**[verified]** Writing `store/.jj/repo/config.toml` and running any jj command:

```
Warning: Your config file has been migrated from …/store/.jj/repo/config.toml
to /Users/claire/.config/jj/repos/d3f89cae574afd8c10c1/config.toml
$ ls -l store/.jj/repo/config.toml
… config.toml -> /Users/claire/.config/jj/repos/d3f89cae574afd8c10c1/config.toml
```

Two consequences, both worse than the migration itself:

1. The config is **host-local and outside the store**, keyed by an opaque hash.
   §12's per-host bootstrap is `jj git clone --colocate`, write `identity.yaml`,
   `fleet-seed` — **`fleet-init` is never re-run**. So every host but the first
   runs with `signing.behavior = keep` (nothing is signed at all — §7 collapses),
   `git.abandon-unreachable-commits = true` (the silent deletion of a
   three-weeks-offline host's unpushed work that §3 names as a decision), and the
   default `diff` conflict-marker style (bet 2, the judges' unanimous #1 steal,
   silently off).
2. The store tree now contains a symlink into `$HOME`, which trips §10.6's "no
   host-local file inside the store tree" check.

**Smallest fix:** §12 runs `roundhouse fleet-init` on **every** host after clone,
and §3 writes the block with `jj config set --repo …` rather than naming a file
path. Doctor asserts the effective values (`jj config get`), not the file.

### P0-4 · A fresh host bricks its own store at `fleet-init`
**Breaks:** §3, §6 ("If she edits on a host with signing unconfigured (fresh box)
… everything else works"), §11, §12.

With `signing.behavior = "own"` and `signing.key` naming a file that does not
exist, every jj command that touches the working copy fails — the store becomes
jj-inoperable. This is documented in the shipped code as an observed jj 0.44
behaviour (`roundhouse:7857-7868`), which is why the shipped `fleet-init` gates the
signing block behind a `signing_configured` flag and ships a late-enrollment heal
path (`roundhouse:7915-7941`, `sync_refresh_signers_command` at `7685-7728`).

§3 writes `signing.key` unconditionally at `fleet-init`, and §12's ordering is
`fleet-init` → … with no step that produces the certificate. The most likely
first-run state in the whole design is a brick, and it appears in neither §7.6 nor
§11. §6's claim that a signing-unconfigured host still works is contradicted by the
measured behaviour the shipped code was built around.

**Smallest fix:** `fleet-init` writes `[signing]` only if the cert path exists;
add a `fleet-enroll` / refresh-signers step that writes it later and derives
`allowed_signers` from the CA (§7.3 says the file is "derived from enrollment
material" but no command derives it).

### P0-5 · Store identity was deleted, so `jj git clone <remote>` will adopt any repository
**Breaks:** §2 layout, §12, §7.3.

§2's store root carries only `README.md` and `.gitattributes`. The shipped code
keeps a fingerprint marker and refuses at init if `origin/main` exists but its
first marker token isn't `roundhouse-sync-store` (`roundhouse:7901-7906`, exit 65),
and again at set-remote (`8064-8081`).

With the marker gone, §12's `jj git clone --colocate <remote> store` adopts
whatever is at that URL — another fleet's store, or an unrelated project. This is
not cosmetic: §7.3's layer rule is "*any* `h` that has a `hosts/<h>.yaml` may edit
fleet-shared intent", so **store identity is the only thing standing between the
fleet and a foreign writer**. Two roundhouse fleets pointed at one remote produce
one `hosts/vireo.yaml` path shared by two different machines, and §7.3 accepts
both. §9's retire-then-reuse doctor check is about host names, not stores.

**Smallest fix:** restore a one-line `store.id` marker at the root; assert it at
clone, at init, and whenever the remote URL changes.

### P0-6 · The Windows host cannot exist under this design
**Breaks:** §7.3, §10.1, §10.3, §11 row "jj missing", §14.

Two independent contradictions for `iris-windows`:

1. **Tier.** The Windows host's only sync lane is the WSL-interop, **git-only**
   lane (`docs/plans/2026-08-06-001-feat-fleet-sync-plan.md:145`, KTD15: "No
   PowerShell port in this lane"). §11 says "jj missing | Hard failure … **No
   fallback tier**" and §14 excludes "Any git-only fallback tier". Those are the
   same tier. The proposal never mentions Windows — the chassis shipped a worked
   `hosts/iris-windows.yaml`; the merge dropped it, dropped `wsl_sibling:`, and
   kept the hazard comment (`physical_host: … iris-windows/iris-wsl share theirs`)
   without the field that resolves it.
2. **Evidence.** If the WSL sibling operates the Windows store, every commit signs
   as `roundhouse-sync@iris-wsl`. §7.3: "for anything under `journal/<h>/`,
   `applied/<h>.yaml`, `alerts/<h>/` … **exactly** `roundhouse-sync@<h>`". So
   `journal/iris-windows/` never verifies, `applied/iris-windows.yaml` is never
   trustworthy, the Windows host can never be a canary (§10.1) and its removals can
   never be gated (§10.3).

**Smallest fix:** `hosts/<h>.yaml` gains `operated_by: <sibling>`; §7.3 accepts
`roundhouse-sync@<operated_by>` for that host's evidence paths; §11 carves out the
WSL-interop lane explicitly rather than banning it by omission.

---

## P1

### P1-1 · Nothing in the design pins non-interactivity, and three paths can pop UI
**Breaks:** §3, §8.2, §12, owner's "everything happens automatically".

Three live vectors, all in unattended paths:

- **jj rewrite commands fall through to `$EDITOR`.** I hit this for real: a
  `jj squash` (the P0-1 fix path) blocked for 120 s on the owner's configured
  VS Code `--wait`. §8.2 prescribes no message flag anywhere on the resolution
  path.
- **§3 omits `ui.paginate = "never"`**, which the shipped code sets
  (`roundhouse:7856`). A paging jj command in a scheduled run hangs.
- **The colocated store inherits the owner's global git signing config.**
  **[verified]** on this machine: `commit.gpgsign = true`, `gpg.format = ssh`,
  `gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign`. Any
  agent that runs `git commit` inside the colocated store pops a 1Password approval
  dialog. §8.4 bans roundhouse from calling `git push` but says nothing about
  `git commit`, and §8.4's own premise is that agents shell out to git.

Also: the P0-3 config migration prints a `Warning:` to stderr on first run.

**Smallest fix:** §3 adds `[ui] paginate = "never"` and `editor = "true"`;
`fleet-init` writes repo-local `git config commit.gpgsign false` and
`gpg.ssh.program ssh-keygen` into `store/.git/config`; every rewrite command in the
runbook carries an explicit message flag; doctor asserts no jj invocation can reach
an editor or pager.

### P1-2 · Any local history rewrite silently re-signs the whole descendant chain as this host
**Breaks:** §7.3, §7.4, §10.1, §11 row "Someone forges evidence".

**[verified]** §3 pins `email = "roundhouse-sync"` identically on every host, so
`behavior = "own"` treats *every fetched commit* as this host's own. A plain
`jj describe -r <ancestor>` re-signed the ancestor **and its descendant**:

```
before:  anc  good [roundhouse-sync@corvid]   desc good [roundhouse-sync@corvid]
after:   anc2 good [roundhouse-sync@vireo]    desc good [roundhouse-sync@vireo]
```

Every one reports `good`. So the moment vireo rewrites anything with descendants —
the P0-1 squash, any `jj rebase`, any `jj abandon`, §7.4's own re-signing story —
wren's `journal/`, `applied/` and `alerts/` commits become vireo-signed, §7.3
rejects them as evidence for wren, and §10.1's canary gate loses its evidence
silently. §7.4 describes the re-signing mechanic in detail and never says the
re-signer's principal replaces the original.

(Forgery *into* another host's directory is still blocked — the damage is evidence
destruction and a canary-gate DoS, not impersonation.)

**Smallest fix:** per-host `user.email = roundhouse-sync@<name>` in §3.
**[verified]** that `behavior = "own"` then declines to re-sign a foreign-authored
commit — it strips the signature instead, which §7.6 already handles correctly as
"unsigned → hold the affected items". Add a §7.6 row for it.

### P1-3 · Canary lying by omission: silence reads as success
**Breaks:** §10.1, and it changes the answer to §16 Q1.

§10.1 promotes when a canary published `outcome: applied` for the digest ≥
`canary_wait_hours` ago **and** published no *later* `held`/`reverted` record for
that item. A canary that applies the item, is wrecked by it, and stops journaling
satisfies both conditions — as does a canary that went **publication-silent because
of an unrelated conflict**, which is exactly the state §8.4 mandates and §16 Q1
proposes to accept. The gate reads two forms of silence as a pass.

**Smallest fix:** add a liveness term — require *some* journal record from that
canary with `at >= applied_at + canary_wait_hours`. One more directory read, same
files. This also makes §16 Q1's cost visible (promotion stalls) instead of
invisible (promotion proceeds on stale evidence).

### P1-4 · Two contradictory prescriptions fire on every run during an open conflict
**Breaks:** §6 step 4, §7.6 row 1, §8.2, §8.3.

**[verified]** the on-disk layer file under an open conflict carries snapshot
markers and `yq -e '.'` exits 1 on it. So both of these fire, every run, for the
same state:

- §6 step 4 / §7.6 row 1 → "refuse to promote, alert with `yq`'s message and line,
  **converge from last good `main`**".
- §8.2 / §8.3 → "`main` does NOT move. **R = `$M`**", hold only the contested items,
  converge the rest.

Two different reconcile points and two different hold sets, plus a spurious
"layer file doesn't parse" alert on every run pointing at a line number *inside* a
conflict marker — which sends the human to the wrong failure.

**Smallest fix:** state the precedence — §6 step 4's promote gate is skipped when
the run is on the §8.2 conflicted path, and the parse-failure alert is suppressed
for files jj reports as conflicted.

### P1-5 · §10.3's ownership table has no row for the state a reinstall produces
**Breaks:** §10.3, and it interacts with §16 Q3.

The table is titled "Four cases", lists five, and omits
`in layers = yes · in applied = no · on host = yes` — desired, already present, not
recorded as ours. That is precisely the state after a host reinstall, after
`applied/<host>.yaml` is hand-truncated (these files are hand-editable by design),
and after §16 Q3's host-local alternative loses the file with the machine. No row
matches; the nearest one ("no | no | yes → **not ours. Never touch it.**") makes
roundhouse permanently disown everything it installed.

**Smallest fix:** add the row — adopt silently on digest match, review on mismatch.

### P1-6 · §7.2's canonicalization claims are false on the installed jq/yq
**Breaks:** §7.2, §4 ("scalar or map, reader's choice… the same item"), §10.6.

**[verified]** on jq 1.8.2: number literals are **preserved**, not normalized —
`{"a":1.10,"b":1.1,"e":1.0}` round-trips unchanged. So §7.2's "jq does all
canonicalization (sorting, spacing, **number form**)" is wrong, and editing
`cadence_hours: 12` → `12.0` re-reviews the item on every host.

Worse, the scalar/map polymorphism §4 sells as free is not free at the digest
layer: `ponytail: enabled` digests `"enabled"` and `ponytail: {state: enabled}`
digests `{"state":"enabled"}`. §4 calls them "the same item"; §7.2 promises
reformatting re-reviews nothing. The day someone adds a `marketplace:` key —
the *worked example* in §5 and §6 — that item re-reviews fleet-wide.

YAML 1.1 coercion also bites through the pipeline: `0755` → `755`, `yes` → `"yes"`.

**Smallest fix:** normalize scalars to `{state: <v>}` before digesting; delete
"number form" from §7.2's claim list; add a §7.2 line about YAML 1.1 coercion.

### P1-7 · The pre-push secret sweep cannot catch the case it exists for
**Breaks:** §10.4.

§10.4 sweeps the **working tree**. The hazard it names is a hand-edited secret in
`findings/` or `alerts/` — but per §6 step 2 those files are snapshotted and signed
into a commit by the *next jj command*. A secret committed and then deleted is gone
from the tree, still in the history, and still in the push. The sweep never fires
on the case that matters. (§10.4's "it cannot un-write local history and says so"
describes the remedy, not the detection.)

**Smallest fix:** sweep the blobs in `main@origin..<targets>` under those prefixes,
not the tree. The predicate itself is fine and already exists
(`roundhouse:9123-9146`); it needs a line number added to satisfy §10.4's own
promise to "name the file and line".

### P1-8 · Self-rendered SSH aliases take unvalidated, fleet-writable input
**Breaks:** §5 (rendered block), §8.5.

§5 renders `HostName` and `User` straight from `hosts/*.yaml`, which §7.3 lets
*any* enrolled host edit. A newline in `tailnet_name` injects arbitrary ssh_config
directives (`ProxyCommand`, `LocalForward`) into a file every fleet operation
reads; the same fields then build `ssh://rh-wren/…` for `jj git remote add` in §8.5.

The shipped code guards the analogous path — `sync_validate_fetch_url`
(`roundhouse:7090-7099`): "Registry content reaches `git fetch` as an argument …
never an option-looking, whitespace-bearing, credential-bearing, or alternate-
transport string". The proposal drops it, and the exposure is *larger* than before
because the values are now hand-authored rather than absorbed from validated config.

**Smallest fix:** reuse that predicate on `hostname`, `tailnet_name`, `user` and
`<name>` before rendering or building a URL; refuse and alert on a match.

### P1-9 · `auto-track = "all()"` with no `.gitignore` publishes and signs editor droppings
**Breaks:** §3, §2 layout, §10.6.

§3 adopts jj-native's `[snapshot] auto-track = "all()"` but drops the store
`.gitignore` jj-native paired with it deliberately (its failure mode 8, "editor
swapfile snapshotted into a commit"), and §2's layout has no ignore file. The
shipped code uses `auto-track = none()` with explicit adds plus a `.gitignore`
(`roundhouse:7854`, `7943`). The first `.DS_Store`, `.hosts-vireo.yaml.swp` or
editor backup is auto-tracked, **signed**, and pushed to the shared store on the
next jj command. §10.6's "no host-local file inside the store tree" check fires
only after publication.

`auto-track`, `max-new-file-size` and `write-change-id-header` are also the three
lines in §3 with no rationale, no judge citation and no §15 provenance row — in a
block whose stated discipline is "four of these are decisions, not preferences".

**Smallest fix:** ship a `.gitignore` next to `.gitattributes`, or scope
`auto-track` to the layer and evidence paths.

---

## P2

### P2-1 · Attribution inflation — the "honours all three judges" claim is not reliable
**Breaks:** header, §7.3, §13.3, §13.5, §13.6, §14, §15.

- "**all three judges flagged it**" for the principal binding (§7.3, restated at
  §13.6 and §15) — the **operator judge never measured or ruled on principal
  binding at all**. Two judges.
- §15: "`lineage/` with `event: retired` | **new** | operator dim-7: no dead-machine
  retirement story **in any candidate**" — judge-**contradicted**. The operator
  called jj-native's `enrolled:` "**the only dead-machine-removal affordance anyone
  proposed**". The dim-7 criticism was scoped to dotfiles-native.
- §14's `enrolled:` entry cites only the judge who opposed it and hides that the
  operator listed it as a must-survive carry-forward. The proposal **overrules a
  judge** here and presents it as a clean drop.
- §14's `git verify-commit` entry says "all three judges" — wrong on both halves.
  The implementer scored dotfiles' testability **8/10 precisely because it keeps
  `git verify-commit`**, and ruled only against the "for free".
- §13 items 3 and 5 cite operator M1 / owner-proxy §0.2-0.3 as chassis defects;
  both judges said the opposite about the chassis (M1 was a defect finding against
  the *other three* candidates; owner-proxy §0.3 names dotfiles and gitops, not
  inventory-layering). The auto-merge runbook is the proposal's own invention —
  which §15 labels correctly and §13 does not.
- Header "**unanimous** winner … 98/140 implementer" conceals that the implementer
  recorded a **tie at 98** with dotfiles-native, broken on one dimension, with the
  caveat that dotfiles-native is the cheaper build.

**Smallest fix:** correct each citation; surface the `enrolled:` drop as a resolved
judge conflict rather than a consensus.

### P2-2 · §0's blanket sourcing launders five candidate-sourced jj claims
"All jj facts below are the judges' measurements on jj 0.44.0" is untrue for:
"jj merges never fail" (§8.2), `jj file show -r <parent>` returning clean YAML
(§8.3 — the mechanical foundation of the headline repair), the resolution `Hint:`
string (§8.2), `abandon-unreachable-commits` *behaviour* (§3 — judges measured only
the default value), and re-signing preserving the change ID (§7.4).

I independently **[verified]** two of them: `jj file show -r <parent>` does return
clean per-side YAML that `yq -e` parses (so §8.3's five-lines-of-yq claim holds),
and snapshot markers land at correct YAML indentation with change ID, commit ID and
description. The other three remain unsourced. **Fix:** mark them.

### P2-3 · The KRL has no distribution or refresh story
§7.1 correctly keeps the KRL host-local and never in the store — and then there is
no mechanism anywhere to revoke a compromised host's cert fleet-wide. It is five
manual out-of-band file copies, and until the last one lands the revoked host keeps
pushing to origin. §10.6's "a KRL-revoked test cert reports `bad`" also needs a
fixture revoked cert plus CA on every host, which nothing produces; and
`ssh-keygen -s ca -V +52w` fixtures **expire on a date nobody wrote down**, at
which point doctor fails closed on every host on the same day.
**Fix:** name the out-of-band revocation procedure in §12; generate doctor fixtures
on demand rather than shipping them.

### P2-4 · The "one grep-able lint" for bare `main` is not one
§8.1 promises "one grep-able lint, one doctor check". The sync section has 52 lines
matching `main`: 24 bare, plus `origin/main`, `refs/heads/main`,
`refs/remotes/origin/main`, `refs/roundhouse-move/main`, `pending_refs=main`,
`init_history='adopted-origin-main'`, prose, and the word `maintains` — and most of
the bare ones are **git refspecs where bare `main` is correct**. The lint must
distinguish revset positions from git arguments. It is also incomplete by
construction: `jj git clone --colocate` writes
`revset-aliases."trunk()" = "main@origin"` into repo config, so revsets live
outside the source tree. **Fix:** make it a doctor check that executes the run's
actual revsets, or scope the grep to `-r` arguments and say it is partial.

### P2-5 · `fleet-explain` line numbers point one line low for exactly the items it exists to explain
yq's `line` on a block map returns the **first child's** line; you need
`key | line`. §4's worked example (`hosts/vireo.yaml:16` for the map-form
`railyard`) is the map case, i.e. wrong. Provenance also has to re-read each layer
file per item rather than come from the folded result. **Fix:** `key | line`.

### P2-6 · `absent` is not part of the fold
§4: "Resolution is a left fold, and the fold is the whole rule." yq's
`ireduce`/`*d` has no knockout — `absent` needs a separate pass scoped to
`<category>.<item>`, and a naive `del(.. | select(. == "absent"))` would delete a
legitimate string `"absent"` inside a `config_files` value. The semantics are
equivalent; the sentence is one rule short. **Fix:** one clause in §4.

### P2-7 · Old-spec capabilities dropped with no §14 line
§14's job is that nothing falls out silently. These fell out silently:
**hook trust** (path-only classification, confused-deputy refusal, plugin-id
validation, hold-marker, `enabled_but_untrusted` reporting — `roundhouse:8809-8875`;
`hooks` survives only as a category name in §4); **`sync-adopt-pin`**
self-update containment (`8670-8713`); the **private-remote first-push gate**
(`7981-8034`); **`core.symlinks false`** and store-symlink detection (`7883`,
`8175-8183`); **remote migration / `set-remote`** with its ancestry check,
reachability precheck and alert-before-push rollback (`8036-8132`); **chezmoi
co-ownership detection** and its doctor re-emergence watch (reduced to one comment,
`model: unmanaged`); **`wsl_sibling:`**; the **`HostName` tailnet-else-hostname
fallback**; **stale-lock detection** (`8396-8413`); and the **`proposals/` record
shape** — the only store artifact whose contents are never shown.
**Fix:** carry them or list them with a reason.

### P2-8 · `max_removals_per_run` does not cover the truncation it was built for
§10.3 justifies the knob with "a `dd` in vim or a truncated save". A `dd` that
removes ≤ 5 items produces valid YAML, passes the promote gate, and uninstalls.
The guard only catches the large version of the accident. **Fix:** say so, or gate
on proportion as well as count.

---

## P3

- **P3-1** §7.1 and §10.6 write `git verify-commit -c gpg.ssh.program=ssh-keygen`.
  **[verified]** `error: unknown switch 'c'` — `-c` is a git *top-level* option. Must
  be `git -c … verify-commit`. It is a literal doctor command.
- **P3-2** §8.2's `jj new -m … $LOCAL $ORIGIN` relies on unquoted multi-line word
  splitting: **[verified]** correct in bash, `Failed to parse revset: Syntax error`
  in zsh. Harmless in production, but it will make the first person who tests the
  runbook interactively conclude it is broken. Also `$ORIGIN` is always already in
  `$LOCAL` after a fetch (jj merges the remote target into the local bookmark);
  **[verified]** jj dedupes, so it is dead weight rather than a bug.
- **P3-3** §8.1's "a hand edit while `@` sits on `main` silently rewrites published
  history (measured)" holds only while `main` is *ahead of* `main@origin`.
  **[verified]** once main's target is at or below `main@origin`, jj refuses:
  `Hint: This operation would rewrite 1 immutable commits`. A free second guard the
  proposal does not credit; the check-first rule still earns its keep for the
  unpushed window, but the stated blast radius is overstated.
- **P3-4** §15 cites inventory-layering "§7.2/§7.4" for re-signing-is-free; it is
  §7.2/§7.3. Same slip citing "§1.2" for "`unknown` = failure" (§1.1). §16 Q2 says
  "three of the four candidates auto-pass"; **two** do — gitops-reconciler §5.1
  explicitly does not, and the chassis reviews.
- **P3-5** §3's `.gitattributes * -text` rationale ("for the Windows host's git
  view") is vestigial under KTD15 — no git runs natively on that box. Keep the file,
  fix the reason (Windows-side editors writing CRLF into a WSL-operated store).
- **P3-6** Gates that cannot be tested as written: the cross-host fixture digest
  (§10.6) needs two hosts, or a pinned expected value that must be regenerated on
  the very event it detects; "no `.jjconflict-*` at any head" can only fire from a
  foreign agent and no fixture stages that; and **the entire sync signing lane
  currently runs under `ROUNDHOUSE_SYNC_SKIP_SIGVERIFY=1`** (`test-roundhouse:8700,
  8708, 8728, 8744, 9534`), so §7's gates have effectively zero coverage today. The
  implementer judge's headline concern — that routing content reads through jj kills
  the fake-jj bins and promotes the real-jj block to mandatory — has no answer
  anywhere in the merge.

---

## §16 — the three open questions

**Q1 (publication silence) — genuine, but re-ask it after P1-3.** As written the
cost is invisible: a canary silenced by an unrelated conflict currently *permits*
promotion on stale evidence. With the liveness term added, the same silence blocks
promotion, which is the honest version of the trade. Answer Q1 against the fixed
gate, not the current one.

**Q2 (auto-pass for local edits) — genuine.** The framing is wrong (two candidates
auto-pass, not three; P3-4) but the judgment call stands, and the chosen answer is
consistent with the constraints.

**Q3 (`applied/<host>.yaml` shared or host-local) — not a judgment call; the
owner's constraints already decide it. Propose: shared, and close it.**
"Never-opaque / browsable" and "offline-first symmetric hosts" both point the same
way — the host-local alternative makes "what does wren actually have" require an
SSH round trip, which is not offline-first, and it is host-keyed so it cannot
conflict. The stated counter-argument ("a smaller thing for a hand edit to corrupt")
is answered by §10.3's own guards plus the P1-5 row, and it applies equally to every
other hand-editable file in the store. Keeping it open invites a re-litigation the
constraints have already settled.

### Judgment calls hidden inside confident-sounding decisions

**Q4 (undeclared).** §7.3 states as a fact that "**any enrolled machine may edit
fleet-shared intent**", including `hosts/<other>.yaml`. That is the entire
authorization model, presented as a mechanism note. It is what makes store identity
load-bearing (P0-5), what makes the SSH-render input untrusted (P1-8), and what
makes the Windows/WSL case contradictory (P0-6). It deserves to be an open question:
*may every host rewrite every other host's file, or is `hosts/<h>.yaml` bound to
`<h>` the way its evidence paths are?*

**Q5 (undeclared).** §8.4 presents "conflicts never leave the host" as settled by
all three judges. The judges ruled on **`jj git push --allow-conflicts`**. §8.4 goes
further — *no ancestor of a published head may ever have been conflicted* — and that
stronger rule, not the judges' one, is what produces the P0-1 deadlock. The
strengthening is the proposal's own call and should be labelled as one.

---

## Simplicity audit

Mechanisms that earn their keep, no action: four-layer fold · maps-not-lists ·
`absent` · closed category set · file-or-directory per layer · value digest ·
`journal/` vs `store.run/verdicts/` split · host-keyed evidence paths ·
`upstreams/<id>/<host>.yaml` (deletes leases outright — the best deletion in the
document) · `max_removals_per_run` · `applied/<host>.yaml` · `lineage/` ·
jitter-as-coordination · `jj op restore` for undo.

Flagged as ceremony a lazier design covers:

- **`physical_host:`** (§5) — appears in the host file and is consumed by *nothing*
  in the entire proposal. No section reads it. Meanwhile `wsl_sibling:`, the field
  that is actually load-bearing (P0-6), was dropped. Delete `physical_host` or name
  its consumer.
- **`node_key:`** (§5, §9) — "corroboration, not identity … it exists so a rename
  can be *checked*". Nothing in the proposal ever checks it: no doctor row, no §7
  gate, no run step. One field plus two paragraphs for an unimplemented check.
  Delete it until something reads it.
- **`signer:` in the published journal** (§5) — self-asserted, and §7.3 already
  verifies the introducing commit's principal cryptographically. A field that
  restates a verified fact in an unverifiable form invites someone to trust the
  field. Drop it.
- **`held_reason:` in the published journal** — both judges' enumeration of the
  replicated record is item/digest/outcome/host/time. `held_reason` is the `reason:`
  field they scoped *out*. It is prose on a fleet-writable surface. Keep it in
  `store.run/`.
- **§9's retire-then-reuse doctor check** — a whole doctor row for a once-a-decade
  event that the `lineage/` file already makes visible to anyone who looks. A
  comment in the retirement record covers it.
- **§7.1's `git verify-commit` cross-check** — §7.1 argues "two implementations of a
  security gate means the untested one is the one that matters", then ships a second
  implementation and calls it a test. Defensible, but it is the one place the
  document's own argument eats itself; worth one sentence acknowledging that.

---
---

# Re-review — rev 2 (1,834 lines)

Verdict: **remaining-issues.** 1 P0 · 3 P1 · 4 P2 · 4 P3 open. Down from 6/9/8/6.

Rev 2 is a substantial, honest revision. 5 of 6 P0s are genuinely fixed and I
re-ran each original breaking scenario against the new prescription. All three
rejections are **correct and I concede all three** — one of them proved my
suggested fix was wrong. What remains is one new permanent-brick of the same
class as P0-1, introduced *by* the P0-2 fix, plus a privilege escalation
introduced by the P0-6 fix.

All **[rev3]** marks below are my own measurements on jj 0.44.0 / yq v4.53.3 /
jq 1.8.2, every invocation non-interactive (`ui.editor=true`,
`ui.paginate=never`, `-m` on every rewrite, `exec </dev/null`). No editor or
pager was reached at any point.

## Verdict per P0

| # | Status |
|---|---|
| P0-1 conflicted ancestor bricks publication | **Fixed — verified end to end** |
| P0-2 reconcile discards in-flight edit | **Fixed for the edit; introduces R1 (P0)** |
| P0-3 config path / hosts 2..N | **Fixed** |
| P0-4 fresh host bricks at init | **Fixed — verified, and worse than I reported** |
| P0-5 store identity | **Fixed structurally; weak in practice → R5 (P2)** |
| P0-6 Windows host | **Tier question fixed; evidence question opens R2 (P1)** |

**P0-1 — fixed.** Ran §8.2 verbatim against a real same-key divergence.
`jj squash --into "$M" --use-destination-message` folds the child's resolution
into the merge; `M2=$(jj log -r @- …)` is the rewritten merge;
`conflicts() & ::@` is empty; `jj git push` succeeds
(`bookmark: main [move forward from 6a9fe867 to 9d886d99]`). §8.3's per-head
read also re-verified *while `M` was conflicted* — each parent returns clean
YAML that `yq -o=json` parses, and the snapshot markers render at correct YAML
indentation with change ID, commit ID and description.

**P0-4 — fixed, and rev 2's escalation of it is right.** `jj git init
--colocate` with `signing.behavior=own` and a missing `signing.key` dies with
`Could not write object of type commit / Signing error / SSH sign failed …
Couldn't load public key`, and **`.jj` is never created**. The
`fleet-init`/`fleet-enroll` split is necessary, not defensive.

## Still open

### R1 · P0 — the P0-2 fix permanently blocks the push in the *normal* case
**Breaks:** §8.2 steps 1–2, §11 row "Operator's unsaved-to-`main` edit".

**[rev3]** `jj git push` refuses **any undescribed commit in the pushed range**,
not just conflicted ones. §8.2 step 1 describes `@` only `if` it is non-empty;
step 2 then passes `$WC` as a merge parent unconditionally. When there is no
pending hand edit — the normal case, and the state §6 step 6's own
`jj new <main commit>` tail leaves behind — `@` is empty **and undescribed**, so
step 1 skips and an undescribed commit becomes a permanent ancestor of `main`:

```
WC empty+undescribed: y/NODESC
jj new -m "reconcile" $MAIN $WC ; jj bookmark set main -r $M ; jj git push
-> Error: Won't push commit 961ba431 since it has no description
```

This is P0-1's failure class exactly — a permanent, fleet-wide publication brick
— reintroduced by P0-2's fix. §8.2 even names the mechanism ("an *undescribed*
merge parent makes the eventual push fail") and then guards against it with a
condition that is false precisely when it matters.

**Smallest fix (verified):** only pass `$WC` when `@` is non-empty — an empty `@`
has nothing to preserve, so there is nothing to merge. **[rev3]** the same
sequence without `$WC` pushes cleanly. One line, and lazier than describing a
placeholder:

```sh
PARENTS="$LOCAL $ORIGIN"
[ "$(jj log -r @ --no-graph -T 'if(empty,"y","n")')" = n ] && { jj describe -r @ -m "…"; PARENTS="$PARENTS $(jj log -r @ --no-graph -T commit_id)"; }
jj new -m "reconcile $HOST" $PARENTS
```

Worth stating alongside it: **[rev3]** `jj git push` itself leaves an empty
undescribed working-copy commit, which is *why* §6 step 6's explicit
`jj new <main commit>` (rather than a bare `jj new`) is load-bearing — the
document does not currently say so.

### R2 · P1 — `operated_by` is a privilege escalation, because §7.3 Q4 is open
**Breaks:** §9.2, §7.3 evidence table row 2, §10.1, §11 row "Forged evidence".

§7.3 row 2 now accepts `<operated_by of h>@<domain>` for `<h>`'s evidence paths,
and `operated_by` is read from `hosts/<h>.yaml` — **a fleet-shared layer file
that §7.3's own declared judgment call lets any enrolled host edit.** So any
host can append `operated_by: attacker` to `hosts/wren.yaml`, then legitimately
author `journal/wren/` records signed as itself, and the canary gate counts
them. §11's "Forged evidence under `journal/<other>/` → signs as the forger;
the §7.3 equality check rejects it" is no longer true.

The two fixes rev 2 shipped are individually sound and jointly unsound: Q4 is
defensible *because* the containment lives in §7.3 row 2, and `operated_by`
punches a fleet-writable hole in exactly that row.

**Smallest fix — delete the exception rather than guard it.** Have the CA issue
the WSL sibling a **second certificate** with principal
`iris-windows@<domain>`; the sibling signs `journal/iris-windows/` with it.
§7.3 stays a pure equality check with no exception, `operated_by` disappears
from the trust path (keep it as documentation if useful), and the escalation
closes. `certify-ssh-node` already issues per-principal certs.

### R3 · P1 — the narrowed guard revset errors on host 1 and on any never-fetched host
**Breaks:** §8.4 pre-push guard, §10.7 doctor row 10.

The P0-1 narrowing writes bare `main@origin..<target>`. **[rev3]** on a store
that has never fetched (host 1's first push; any host whose remote was just
re-pointed):

```
$ jj log -r "conflicts() & main@origin..$T"
Error: Revision `main@origin` doesn't exist
```

So the guard that unbricked the store cannot run on the fleet's first push. Fail
open means a conflicted commit can be published; fail closed means host 1 can
never publish. The document does not say which — and this is the same bare-name
trap §8.1 exists to forbid, reappearing inside the fix for it.

**Smallest fix (verified):** `conflicts() & present(main@origin)..<target>` —
**[rev3]** exits clean and empty on a never-fetched repo. §8.1 already uses
`present()` for exactly this; §8.4 and §10.7 need the same treatment.

### R4 · P1 — §8.1's "checked first" invariant fires on the state §8.2 deliberately leaves open
**Breaks:** §8.1, §8.2 step 4, §11 row "`@` left on `main`".

§8.1: "`@` must be a fresh child of a `main` target at run start — checked
**first**", with §11's remedy `jj new <main>`. **[rev3]** in the open-conflict
state the invariant is false by construction:

```
main targets: 6a9fe867 4e4e8623
@-          : f8c2c28d      <- M, which §8.2 deliberately does NOT make a main target
```

So on the run *after* the human resolves, the first check fires and its
prescribed remedy moves the workbench off the resolution — discarding the edit
§8.2 step 4 is about to squash. This is the same class as P1-4 (two rules firing
on one state), which rev 2 did fix for the promote gate but not here.

**Smallest fix:** exempt one state — `@` is a child of a conflicted merge this
host authored — and route it to §8.2 step 4 instead of `jj new <main>`. One
condition, and it is detectable from repo state alone (`@-` is in `conflicts()`
and its committer is this host), which the runbook also needs because `$M`,
`$WC` and `$LOCAL` do not survive between runs — the §8.2 script is written as
one block but spans two.

### R5 · P2 — the store marker cannot distinguish this fleet from another roundhouse fleet
§7.5's stated threat is "two roundhouse fleets pointed at one remote". The
marker is a token minted at `fleet-init` and **stored in the store**, so hosts
2..N obtain it *from the repo they are trying to validate*. §12's clone step
"asserts `.roundhouse-sync-store`" can therefore only prove "this is some
roundhouse store", which is the check that already existed. **Fix:** put the
expected token in host-local `identity.yaml`, pasted at enrollment; compare
against it, not merely for presence.

### R6 · P2 — `$WC` as a merge parent makes the operator's in-flight edit a phantom head in §8.3
§8.3 assumes "the parents of `M` are the heads". After the P0-2 fix they are the
heads **plus the workbench**. **[rev3]** my reconcile produced a three-parent
merge whose third parent was the operator's in-progress edit, and §8.3's fold
reads it as an equal voice: an item the operator is midway through editing is
`HELD` as though two hosts disagreed about it. **Fix:** one sentence — the
per-head fold ranges over the *bookmark* heads, not over all parents of `M`.

### R7 · P2 — tying identity to the cert principal breaks the rename story
§7.3 makes `user.email` the cert principal and §7.3 row 2 requires evidence
under `journal/<h>/` to verify as exactly `<h>@<domain>`. After a rename,
`hosts/vireo.yaml` and `journal/vireo/` exist but the host's certificate still
asserts `macbook-pro@<domain>` — so **all of the renamed host's own evidence is
rejected** until re-enrollment, and §9.1's rename procedure never mentions one.
Separately, §9.1's plain `mv` of `journal/macbook-pro/` → `journal/vireo/`
re-introduces those files in a new commit signed by whoever ran the `mv`, so
historical evidence is re-attributed to the mover. **Fix:** §9.1 states that a
rename requires `roundhouse fleet-enroll` (re-issue with the new principal), and
that moved evidence is attributed to the mover by design.

### R8 · P2 — CA rotation holds the whole fleet
§3.3 says `fleet-enroll` "re-derives `allowed_signers` whenever the CA rotates".
A rotated CA means every historical layer commit verifies `unknown`, and §7.7
holds every item resolved from a file that any such commit touched — i.e. all of
them, until every layer file is re-committed. **Fix:** `allowed_signers` retains
retired CA keys with OpenSSH's `valid-before` option, which the format already
supports; one line in `fleet-enroll`.

### R9–R12 · P3
- **R9** §3.1's block sets `user.email` to the cert principal, but §3.3 assigns
  that to `fleet-enroll` — and at `fleet-init` time no certificate exists, so the
  principal is unknown. Move the line, or mark it enroll-time in §3.1.
- **R10** §3.2's environment is scoped to "the scheduled run", but three
  prescribed commands run outside the store's repo config: `jj git clone` (§12,
  before `fleet-init` writes any pins), the doctor's synthetic conflicted-bookmark
  repo (§10.7), and the git cross-check fixture (§7.1). State that §3.2's
  environment applies to every roundhouse invocation.
- **R11** `SSH_ASKPASS_REQUIRE=never` suppresses the *GUI* prompt but still
  permits a TTY passphrase prompt; `ssh -o BatchMode=yes` is the knob that
  actually refuses. Closed stdin covers it in practice — name the right mechanism.
- **R12** The §7.3 gate's hold message renders `…!=…` even when the principals
  match and only `status` is bad. **[rev3]**
  `HOLD:bad:vireo@… != vireo@…` on a KRL revocation — an alert that points the
  operator at the wrong thing. Branch the message on `status` first.

## The three rejections — all correct, all conceded

- **P1-9 — I was wrong; concede fully.** **[rev3]** with default
  `auto-track = "all()"` on jj 0.44, `.DS_Store`, `.real.yaml.swp`, `real.yaml~`
  and `sub/.DS_Store` were **not** tracked; only `real.yaml` was. My premise was
  false. Rev 2's disposition — delete the three unjustified config lines, ship a
  `.gitignore` anyway for the colocated **git** side — is correct and lazier than
  what I proposed.
- **P2-5 — correct, and worse than rev 2 states; my suggested fix was wrong.**
  **[rev3]** on a commented file, real lines `plugins=3, ponytail=5,
  railyard=6, state=7`, yq reports:

  | expression | `line` | `key \| line` |
  |---|---|---|
  | `.plugins` | 3 ✓ | 1 |
  | `.plugins.ponytail` | 3 | 3 |
  | `.plugins.railyard` | 5 | 4 |
  | `.plugins.railyard.state` | 5 | 5 |

  Both operators drift, by *varying* amounts (0, 2, 1, 2) depending on comment
  placement. `key | line` is not a fix. Dropping line numbers and keeping
  file-level provenance is right.
- **P2-8 — concede.** `max_removal_fraction` plus the explicit statement that a
  one-line deletion is a legitimate edit whose defence is item-level review is
  the honest narrowing, and it is the anti-ceremony answer.

## The two surfaced judgment calls

- **Q4 (any host edits any file) — sound as argued.** "`fleet.yaml` is strictly
  more powerful than any host file, so scoping host files reduces blast radius
  from everything to everything" is correct, and the named containments
  (store identity, receiving-host review, canary, removal caps, KRL) are the
  right places. **One consequence rev 2 missed:** this call is exactly what turns
  `operated_by` into an escalation (R2). Fix R2 and the call stands.
- **Q5 (§8.4 back to "no conflicted commit is ever pushed") — sound and
  verified.** It matches what the judges actually ruled, it is what unbricks the
  store, and **[rev3]** the resulting history — a commit that *was* conflicted and
  was resolved in place — pushes cleanly. The guard's revset still needs R3.

## §3.2 completeness

Materially complete and the strongest new section. It pins the two live UI
vectors I found (the `code --wait` fall-through and the global
`commit.gpgsign` + `op-ssh-sign` dialog) and adds two I had not
(`ssh-keygen -Y sign`'s `overwrite (y/n)?`, `jj git fetch` passphrase). I swept
every jj/git/ssh-keygen invocation the spec prescribes: the only gaps are
**R10** (three commands that run outside the store's repo config) and **R11**
(the ssh knob is named imprecisely). Nothing in the apply path can reach an
editor or pager. No invocation in this entire re-review blocked.

## New attack surface introduced by rev 2

R1, R2, R3, R4, R6 are all new — every one of them lives in a fix for a P0. That
is the expected shape and none is architectural, but it is the reason the verdict
is remaining-issues rather than approve: the P0 fixes have not themselves been
adversarially walked, only verified against the scenario they were written for.
R1 and R3 in particular are the same failure modes as P0-2 and P0-1, one layer
down.

---
---

# Final verification — rev 3 (2,066 lines)

Scope: the twelve rev-2 dispositions only, as instructed. No new sweep.
Verdict: **not approve — one P1 defect remains (R4).** 11 of 12 verified good.

All **[rev4]** marks are my own measurements on jj 0.44.0, every invocation
non-interactive (`ui.editor=true`, `ui.paginate=never`, `-m`/
`--use-destination-message` on every rewrite, `exec </dev/null`). Nothing
blocked; no editor, pager or dialog was reached. Labs at `/private/tmp/dsc-r3`,
removed afterwards.

| # | Disposition | Result |
|---|---|---|
| R1 | conditional `$WC` parent | **Verified both ways, discriminating** |
| R2 | `operated_by` deleted | **Verified — no residual trust path** |
| R3 | `present(main@origin)..` | **Verified** |
| R4 | §8.1 exemption + §8.2 step 0 | **DEFECT — leaks (P1)** |
| R5 | `store_id:` in `identity.yaml` | Verified in text |
| R6 | fold over recomputed heads | **Verified empirically** |
| R7 | rename requires re-enroll | Verified in text |
| R8 | CA overlap, two `cert-authority` lines | **Verified empirically** |
| R9 | `user.email` in enroll block | Verified in text (§3.1 enroll block) |
| R10 | env scoped to every invocation | Verified in text |
| R11 | `BatchMode=yes` | Verified in text |
| R12 | hold message branches on status | Verified in text |

## R1 — verified, with a discriminating test

On one identical fixture (clean merge, `@` measured `empty=y desc=[]`):

```
REV-2 form (unconditional $WC) -> Error: Won't push commit 9c78d378c96a since it has no description
REV-3 form (conditional)       -> bookmark: main [move forward from ace51d8745b3 to 840d4b716d4e]
```

With a pending hand edit the rev-3 form also pushes **and** `groups/testing.yaml`
is present in a fresh clone of origin. Conflicted path re-run end to end: merge
held, cross-run resolve, squash into `M`, empty guard range, push succeeds.

## R2 — verified, no residual trust path

§7.3 row 2 reads "**exactly `<h>@<domain>`. No exception, for any host.**"
`operated_by` appears nowhere except the §9.2/§7.3 rationale and the resolution
log — never in the schema, never in a gate. `wsl_sibling:` survives only as
apply-path documentation ("the interop lane used to reach `%USERPROFILE%`"); I
grepped every occurrence and none feeds a verification decision. The
second-cert / second-instance construction is the right shape: it is a second
enrollment, not a new mechanism, and it keeps the Q4 call sound.

## R6, R8 — verified empirically

**R6.** On the later run, with `main` deliberately not moved, the recomputed
heads are byte-identical to the originals:

```
heads then: 0ae0d1a97a1c a732d9cfdcc5
heads now : 0ae0d1a97a1c a732d9cfdcc5
```

So folding over recomputed bookmark heads is stateless and correct, and the
workbench is excluded as §8.3 now requires.

**R8.** Two `* cert-authority` lines behave exactly as claimed:

| signers file | old-CA cert | new-CA cert |
|---|---|---|
| both lines | accepted | accepted |
| new only | **REFUSED** | accepted |

The overlap avoids the fleet-wide hold. Two plain lines over `valid-before=` is
the right call at five hosts.

## R4 — the exemption leaks · **P1, the one open defect**

**Breaks:** §8.1 exemption, §8.2 step 0, §8.4's guard.

Step 0 is `@-` is conflicted **AND** `@-`'s `committer.email()` is this host.
The second condition is a **self-asserted, unsigned config field**, and the first
is reachable from a peer. **[rev4]**, end to end:

```
1. peer sets JJ_EMAIL=vireo@fleet.novotny.org, builds a conflicted merge
     -> committer=vireo@fleet.novotny.org conflicted=YES
2. plain push        -> Error: Won't push commit … since it has conflicts
   --allow-conflicts -> published
3. victim fetches; §8.1's own remedy parents @ onto the fetched head
     -> @- committer=vireo@fleet.novotny.org conflicted=YES
   step 0 exemption  -> FIRES
```

The victim then skips the `jj new` and routes to step 4, which runs
`jj squash --into "$M"` where `M` is **the peer's commit** — silently adopting
and republishing a resolution of a conflict the local operator never saw,
whichever side the working copy happened to hold. §7.4's signature-stripping
makes it loud at the item level and §7.7 holds the items, so the damage is
bounded — but the mechanical path proceeds unchallenged, and the check the
document presents as sufficient is not.

**Two things make it undetected as well as reachable:**

- **[rev4]** `conflicts() & present(main@origin)..@-` is **empty** here, because
  the conflicted commit *is* `main@origin` — already published, so never in the
  push range. The narrowing that correctly fixed R3/P0-1 is exactly what blinds
  the guard to an inbound published conflict. `conflicts() & ::@-` sees it
  (`c41765aacc0a`).
- §10.7's companion clause, "no `.jjconflict-*` path at any head", is one word
  ambiguous about *which* side. **[rev4]** on the jj side the victim sees none —
  `jj file list -r @-` returns only `groups/development.yaml`, because jj
  reconstitutes the native conflict. On the git side they are all there:
  `.jjconflict-base-0/`, `.jjconflict-side-0/`, `.jjconflict-side-1/`,
  `JJ-CONFLICT-README`. The natural jj-side implementation is blind; the git-side
  one catches it.

This needs an enrolled peer to use the banned `--allow-conflicts` — but §8.4's
own premise is that jj's refusal is not self-enforcing and that agents shell out
to git, which is why the pre-push guard exists at all. A rule enforced only by
the code that is also the thing being bypassed is the case the guard is for.

**Smallest fix — replace the spoofable field with a locality test, verified:**

```sh
# step 0: @ is my resolution workbench iff @- is a conflicted commit
#         that has not been published anywhere.
[ -n "$(jj log -r '(conflicts() & @-) ~ ::remote_bookmarks()' --no-graph -T commit_id)" ]
```

**[rev4]** on the leak state it does **not** fire; on the legitimate workbench it
**does**, and the subsequent squash-and-push still succeeds
(`main [move forward from 243f34b713a5 to d25793be800d]`). One revset, and it
deletes the `committer.email()` clause and the `$PRINCIPAL` variable rather than
adding anything — a legitimate workbench parent is by construction an unpublished
local merge, so locality is the property actually being tested.

**Plus one word, in §10.7:** state that the `.jjconflict-*` check is over the
**git** tree (`git ls-tree -r <target>`), not the jj file list. Keep the narrow
`present(main@origin)..<target>` range for the pre-push guard — it is right there
— and let the git-side clause be what detects an inbound published conflict.

## Bottom line

Rev 3 fixed eleven of twelve findings cleanly, and the two I re-tested hardest
(R1, R8) hold up under a discriminating test rather than a confirming one. R4 is
the last one, it is the one the coordinator suspected, and it is a one-revset
fix that removes code. Apply the step-0 locality test and the §10.7 git-side
wording and this is done.

---

## Sign-off — rev 3 final (2,102 lines)

**APPROVED.** Both prescribed diffs match verbatim; nothing else moved
(2,066 → 2,102, +36 lines, all inside the two edited blocks and the §16 R4
disposition). Open questions still exactly two (Q1 publication silence, Q2
auto-pass), Q3 still closed.

**Diff 1 — §8.1 exemption / §8.2 step 0.** `(conflicts() & @-) ~
::remote_bookmarks()`, character-for-character as prescribed. Step 0 collapsed
from a two-condition `&&` to a single revset test; `$PRINCIPAL` and the
committer read are gone from the runbook. The only surviving `committer.email()`
uses are §7.1's verification template and §7.3's equality gate — and those are
the correct use, not the one I rejected: there the signature-derived principal
is the authority and the committer field is the *claim* being checked against
it, whereas the deleted step-0 test used the self-asserted field *as* the
authority with nothing checking it. §8.1's new prose draws exactly that
distinction and cross-references §7.3 for it. The fall-through is also right:
on the leak state the revset is empty, so the run does not treat the inbound
conflict as its own workbench and instead holds and alerts per §8.3 — which is
the correct handling of a peer-published conflict, not merely a safe failure.

**Diff 2 — the `.jjconflict-*` check.** §8.4 and §10.7 both now read "no
`.jjconflict-*` path in the **git** tree at any head", with `git ls-tree -r`
named explicitly against `jj file list` and the reason inline. §8.4 additionally
states that this clause is what catches an inbound published conflict that the
narrowed range revset cannot see — the gap I flagged, closed where I asked for
it, with the narrow `present(main@origin)..<target>` correctly retained for the
pre-push guard itself.

Nothing further from me. Across four revisions this went from 29 findings to
zero open, with three of my own findings correctly rejected on measurements I
re-ran and conceded (P1-9, P2-5, P2-8). Every P0 and P1 fix was verified against
a discriminating test, not a confirming one.

**Residual risk the owner should know, all accepted by design and documented in
the proposal:** the KRL revocation window (§12), a one-line deletion passing the
removal caps (§10.3), `outcome: applied` meaning "the run refused nothing"
rather than health (§10.1), and the Q4 authorization model (any enrolled host
may edit any fleet-shared layer, §7.3) — which is sound only because §7.3 row 2
now has no exception. If a second human ever joins the fleet, revisit Q4 first.

---
---

# Rev 5 additions — targeted adversarial pass (2,549 lines)

Scope: §8.2b, §6.1, §10.8 and their interactions with previously-approved
sections only. Verdict: **not approve — 4 P1, 4 P2, 5 P3.**

The three additions are good ideas and mostly well-built. What breaks is the
seam between them and what I already signed off: §10.8's verdict-binding change
contradicts two previously-verified properties, and §8.2b's ladder makes
**self-asserted commit text outrank cryptographically-grounded evidence**.

**[rev5-rev]** = my own measurements, jj 0.44.0, all non-interactive. Lab
removed.

## P1

### V1 · §8.2b ladder rule 2 lets a forged trailer beat a human edit
`roundhouse-reverts` is free text in a commit description. Rule 2 ("one side is
a revert of the other — the revert wins") fires **before** rule 3 (journal-
grounded) and rule 4 (human wins). Any enrolled host — and Q4 says that is every
host — can write `roundhouse-reverts: <the other side's change>` into a commit
that is not a revert, and win the ladder outright against a human's edit.

**§7.3 does not bound this.** It binds *identity* — who signed — not the truth
of content claims. The signature makes a forged trailer attributable after the
fact; it does not stop it deciding the merge. And the escalation bias §5 relies
on ("no trailer → treat as `interactive/human`") covers **omission only**:
forging `roundhouse-session: interactive/human` (rule 4) doesn't escalate, it
*wins*. Forging is strictly more powerful than omitting, which inverts the
document's own safety argument.

**Smallest fix:** make rule 2 verifiable rather than asserted — accept the claim
only if that side's resolved value equals the value the named change replaced.
Both are in history and the digest machinery already exists; a false claim then
simply fails to match and the trailer is ignored. For rule 4, an unverifiable
human claim should never *win*, only *escalate*: put the journal-grounded rule 3
above both trailer rules, and route any `interactive/human` claim on either side
to rule 6.

### V2 · §10.8's change-ID gate re-reviews every promotion, fleet-wide
**[rev5-rev]** measured: moving a value from `hosts/vireo.yaml` to `fleet.yaml`
leaves the digest input byte-identical (`{"state":"enabled"}`) but changes the
introducing change ID (`ysmkoyqpvlzk` → `zqwktnppvnyo`).

§7.2 promises, as a chosen property: "promoting `plugins.ponytail: enabled` from
three host files up to `fleet.yaml` changes no digest and **triggers no review
anywhere**. Nothing about any host's state changed." §10.2's unanimity-promotion
feature is built on that promise. The new "digest **and** change ID" gate breaks
it: every accepted promotion now triggers a review of that item on every host.

**Smallest fix:** scope the change-ID clause to the case it was added for.
Require the change-ID match only when the incoming digest is one this host
previously applied and later stopped applying — that is exactly a revert, and a
promotion never satisfies it. Same one clause, one condition narrower.

### V3 · Verdict invalidation is per-file, so one resolved conflict re-reviews the whole layer
§7.4 records "the change ID of the last commit touching **any contributing
layer**" — per file. §8.2's resolution commit rewrites the whole file, so after
any conflict in `groups/development.yaml`, *every* item that file contributes has
a new introducing change ID and is re-reviewed on every host in the group.

That is precisely the group-layer conflict amplification §8.3 was built to
eliminate and §13 item 1 claims as a headline repair — reintroduced one layer up,
at the verdict. It gets worse under §6.1: more frequent runs mean more conflicts,
and §8.2b's whole premise is that conflicts are now routine and auto-resolved.

(Good news, **[rev5-rev]** measured: `jj squash --into` **preserves** the
destination's change ID — `mrynkwqmpytp` unchanged — so the §8.2 squash itself
does not invalidate anything. The defect is the per-file granularity, not the
squash.)

**Smallest fix:** record the introducing change **per item**, not per layer file.
The run already computes per-item values through the §4 fold; this is the same
pass.

### V4 · Free-text trailers and the `resolved` rationale bypass the redaction floor
§10.4's sweep is **path-based**: a per-commit walk over `main@origin..<target>`
looking at `findings/` and `alerts/` files, with a 400-byte cap on replicated
fields. Rev 5 adds two new replicated free-text surfaces that the sweep cannot
see:

- `roundhouse-intent` — a free-text line on **every** roundhouse commit (§5),
  replicated and signed.
- `outcome: resolved`'s rationale, which §5 explicitly calls "the one replicated
  record that carries prose" and which points at a commit description holding
  "the full rationale".

Neither is swept and neither is capped. Doctor asserts trailers are *present*
(§10.7) but never inspects their content. An agent writing an intent line that
quotes a token publishes it, signed, to the shared store — and §10.4's own
remedy (`jj abandon` / `jj op restore`) explicitly cannot un-publish.

**Smallest fix:** run the existing `sync_quote_is_secret` predicate over commit
descriptions in the push range. §10.4's walk already enumerates that exact range,
so it is one more field on the same pass. Cap `roundhouse-intent` at the same
400 bytes.

## P2

### V5 · The fast run never publishes local work
§6.1's poll floor is `[ "$remote" = "$local" ] && exit 0`, evaluated first. A
host with a pending hand edit and an unchanged remote exits immediately — so its
own edit is not pushed until the remote happens to move or the 12-hour full run
comes round. §6.1's headline freshness target ("an edit published on host A is
applied on any awake host B within ≤ 25 min") assumes A published; on the fast
path A never does.

**Fix:** the short-circuit must also require nothing local to publish — `@` empty
**and** `present(main@origin)..heads(bookmarks(exact:"main"))` empty.

### V6 · Rule 5 is decided by an attacker-controlled, skew-prone field
**[rev5-rev]** `JJ_TIMESTAMP=2099-01-01T00:00:00Z` produced exactly that
committer timestamp. Rule 5 ("both sides agent-authored — newest wins") is the
*common* case at §6.1's cadence, and a host with a wrong clock or a deliberate
future timestamp wins every rule-5 contest permanently. §10.7's >5 min skew check
is on journal `at` fields, not commit timestamps.

**Fix:** decide rule 5 on the journal `at` fields (already skew-checked), and
escalate rather than guess when the two are within one fast interval — at
20-minute cadence "the later one saw more" is not true at three minutes apart.

### V7 · Rule 3's "journaled healthy" overclaims against §10.1
§10.1 states plainly that `outcome: applied` means "the run refused nothing — a
weaker claim than a health probe, and the design does not pretend otherwise."
Rule 3 then reads the same field as "applied and journaled **healthy**". One
field, two meanings, two sections.
**Fix:** reword to "applied and not subsequently reverted" — what the journal
actually supports, and what §10.1 condition 2 already computes.

### V8 · `fleet-rollback --now` is a self-asserted field disabling the only safety gate
The sole canary bypass in the system is "records an explicit operator override in
the journal". It is signed and host-attributable (§7.3) and the revert still
passes every identity and review gate, so exposure is bounded and consistent with
Q4 — but nothing states that `--now` is honoured **only** on a commit carrying
`roundhouse-reverts`, nothing binds it to the item named, and §10.7 has no row
reporting overrides.
**Fix:** one sentence plus one doctor row — `--now` is honoured only for an item
whose introducing commit carries `roundhouse-reverts`, and doctor reports every
override seen in the last N days.

## P3

- **V9** The nudge sets `ConnectTimeout=3` but nothing bounds the *remote
  command*; a peer that connects then hangs blocks the pushing host's `wait`.
  Wrap in `timeout`.
- **V10** `reachable_peers` is used but never defined in §6.1.
- **V11** A nudge landing mid-run hits the host-local lock (§10.6) and the peer
  exits without acting. Correct — best effort — but the "within seconds" claim
  silently degrades to ≤ 25 min. Say so where the claim is made.
- **V12** Rule 5 reads "newest `roundhouse-intent` wins"; `roundhouse-intent` is
  prose with no timestamp. Wording bug in a decision rule.
- **V13** §10.8 is placed between §10.6 and §10.7 — numbering out of order.

## What the additions did *not* break

I re-checked the four things most at risk and they hold:

- **`jj squash --into` preserves the destination change ID** (`mrynkwqmpytp`
  unchanged), so §8.2's verified runbook survives the new gate intact.
- **`jj sign` preserves the change ID** (author's measurement, consistent with
  mine), so §7.4's "re-signing is free" survives the narrowing.
- **`jj revert` exists in 0.44** and does what §10.8 describes.
- **The §7.3 equality gate is untouched** and still bounds *identity* — which is
  exactly why V1 matters: it was never designed to bound content claims, and
  §8.2b is the first section to lean on it as though it did.

The §6.1 hub/peer split, the traveling-laptop case, the ls-remote floor's
cheapness, the two-cadence split, §10.8's per-category reversibility table and
both canary runbooks are all sound and I found nothing to attack in them.

---
---

# Round 6 verification (2,767 lines)

Verdict: **not approve — 2 P1.** Eleven of thirteen V-findings are properly
closed, several by deletion. Two defects remain, both in §8.2b's ladder, and both
are the *same shape as V1*: a rule above rule 4 short-circuits the human
escalation. One is new (introduced by V1's own rewrite), one was always there and
V1's reordering exposed it.

**[rev6-rev]** = my measurements, jj 0.44.0, non-interactive. Lab removed.

## Verified closed

**V1's original attack is dead.** Re-ran my forgery against rule 2's predicate,
with the merge conflicted:

```
honest revert of C:  mine={"pin":"v1"}       replaced={"pin":"v1"} -> VERIFIED
forged claim on C:   mine={"pin":"v9-forged"} replaced={"pin":"v1"} -> CLAIM REJECTED
```

Checking the claim against content that is already signed, rather than adding
anti-forgery machinery, is the right shape. Rule 4's either-side test makes
forging equal omitting. The evidence-class table and the hard rule
("self-asserted may never outrank grounded, never wins alone") are the correct
frame — the defects below are places the ladder does not yet obey its own rule.

**V2/V3 closed by deletion, correctly.** The change-ID gate is gone, not
mitigated: §7.6 now annotates `change:` as "provenance only, never a gate", and
I grepped the whole file — no per-file change-ID gate survives anywhere, so V3
dissolves by construction rather than by argument. The replacement
revert-signature predicate reads this host's own replicated journal and is right
on all three cases I checked: a revert fires it (applied → superseded → back), a
promotion cannot (the digest never stopped being applied — I measured the digest
byte-identical across a promotion in round 5), and re-signing cannot. It also
survives a host reinstall, because `journal/` replicates where `store.run/` does
not. The **mirror doctor row** ("a promotion is *not* re-reviewed") is the right
lesson from V2: the bug got in because only one side was asserted.

**V4–V13** verified in text: redaction predicate over descriptions in the
existing push-range walk with a 400-byte trailer cap and a doctor row; fast-path
no-op requires nothing-to-pull **and** nothing-to-push; rule 5 reads skew-checked
journal `at` with a one-fast-interval margin (my `JJ_TIMESTAMP=2099` forgery is
no longer load-bearing); rule 3 reworded to "not subsequently reverted", matching
§10.1's disclaimer; `--now` gated to a *verified* revert, item-scoped, journaled
`override: canary`, 30-day doctor listing.

## Open

### W1 · P1 — rule 2 lost its scoping: a verified revert of an *unrelated* change beats a human edit
Rev 5's rule 2 read "one side is a revert **of the other**". Rev 6's reads: "one
side's value equals the value the change named in its `roundhouse-reverts`
trailer actually replaced." The scoping clause did not survive the rewrite, and
nothing else restores it.

**[rev6-rev]** demonstrated. History `v1 → (C: v2) → v3`. Claire hand-edits `v4`
on vireo; wren publishes `v1` claiming `roundhouse-reverts: C`:

```
human side value : {"pin":"v4"}   [interactive/human]
wren side  value : {"pin":"v1"}   [roundhouse-reverts: C]
rule 2 check     : mine={"pin":"v1"} replaced={"pin":"v1"} -> VERIFIED
is the human side asserting what C set (v2)?  no  <-- C is unrelated to the contest
```

Rule 2 fires, wren wins, and rule 4 — either-side-human → escalate — never runs.
The claim is *true* (it really is a revert of C), which is why the content check
passes; it is simply a revert of something nobody was arguing about. Reverting
any sufficiently old change becomes a way to win any contest.

**Smallest fix:** one more comparison, using the two reads the rule already
does — the **other** side's value must equal what the claimed change *set*:

```sh
[ "$mine" = "$replaced" ] && [ "$(val "$OTHER")" = "$(val "$(cid "$claim")")" ] || ignore_the_trailer
```

That is the literal reading of "a revert of the other". (I demonstrated the hole;
my confirmation run of this fix miskeyed its revsets and returned nulls, so treat
the fix as reasoned from the same machinery, not separately measured.)

### W2 · P1 — rule 3 qualifies *both* sides in the modal case, and also bypasses rule 4
§6 step 6 is: verdict → **apply** → update `applied/` → **append journal** →
describe → bookmark → **push**. Apply and journal precede publication. So in any
ordinary two-host divergence, each host has already written `outcome: applied`
for its own value with nothing later.

Rule 3 is "one side's value is recorded `outcome: applied` in some peer's journal
and not subsequently reverted or superseded there. That value wins." In the modal
case **both** sides satisfy it, and the ladder says "stop at the first rule that
fires" without saying which side wins when a rule fires for both. Two
consequences:

1. **Undefined resolution in the normal path** — two readings, opposite answers,
   and this is the common divergence, not an edge case.
2. **Rule 4 is bypassed exactly as in W1.** Claire's hand edit is applied and
   journaled on vireo before it is pushed, so a human-vs-agent conflict is
   arbitrated by rule 3 and never reaches the human-escalation rule. That defeats
   the protection V1 was raised to create.

**Smallest fix — one reordering plus one clause, and the reordering fixes W1 too:**

- **Move rule 4 (either-side-human → escalate) to immediately after rule 1.**
  Rule 1 is a no-op convergence and is safe above it. Everything below then only
  ever arbitrates agent-vs-agent, which is what rules 2, 3 and 5 are actually
  for — and it makes "self-asserted may only escalate" genuinely dominant rather
  than nominally first-in-prose and third-in-effect.
- **Rule 3 fires only when exactly one side qualifies** (the other side's value
  has never been applied anywhere). Otherwise fall through.

With both applied, W1's unrelated-revert case escalates instead of resolving,
and the scoping fix above becomes a correctness improvement for agent-vs-agent
rather than a safety requirement.

## Note

Both defects are in the ordering, not the evidence model. The evidence-class
framework rev 6 introduced is the right abstraction and I would keep it verbatim;
the ladder just has to be sorted to match it — grounded rules arbitrate, the
self-asserted rule only escalates, and escalation is checked before arbitration
rather than after.

---

## Final sign-off — round 7 (2,832 lines)

**APPROVED.** Both prescriptions applied exactly; both attacks re-run against the
final text and closed. Zero open findings.

**W1 — verified by my own measurement this round** (my round-6 confirmation run
miskeyed its revsets and returned nulls; this one is clean). Same fixture,
history `v1 → (C: v2) → v3`:

```
W1 attack, agent-vs-agent (other side = unrelated v4):
  mine={"pin":"v1"} replaced={"pin":"v1"} theirs={"pin":"v4"} set_to={"pin":"v2"}
  -> trailer ignored -> falls through   (reaches rule 6, escalate)

honest scoped revert (other side re-asserts C's v2):
  mine={"pin":"v1"} replaced={"pin":"v1"} theirs={"pin":"v2"} set_to={"pin":"v2"}
  -> RULE 3 FIRES (resolve)
```

The second comparison closes the hole without being over-restrictive: the honest
scoped revert still resolves between two agents with no escalation. And with a
human on either side the revert rule is never reached at all — rule 2 now sits
above it.

**W2 — closed structurally.** Rule 4 fires only when exactly one side qualifies,
so the modal both-applied divergence (which §6 step 6's apply-then-push ordering
makes the common case) falls through to rule 5's margin and then rule 6 instead
of resolving arbitrarily. The human-vs-agent instance is caught earlier still, at
rule 2.

**Cross-references check out.** §7.6's `reviewer:` field cites "rules 2, 5-6",
§8.6 cites "rule 2 — a human on either", §11's failure-mode row cites "rule 2 …
rule 6", and §10.8's `--now` gate cites "§8.2b **rule 3's scoped check**". The
rev-5 rule numbers that remain at §8.2b's evidence-class preamble are explicitly
historical narration of the defect, correctly scoped. No stale live references.

One thing worth naming as better than what I asked for: `--now` — the single
canary bypass in the design, and its strongest privilege — is gated on rule 3's
*scoped* predicate, so the W1 tightening propagated into the rollback path rather
than stopping at the ladder. That coupling is the right instinct.

### Closing note on the review as a whole

Seven rounds, 29 → 13 → 12 → 2 → 0 findings. Three of my own findings were
correctly rejected on measurements I re-ran and conceded (P1-9, P2-5, P2-8), one
of which proved my prescribed fix was wrong. Every P0 and P1 was verified against
a discriminating test — a scenario that fails on the old text and passes on the
new — rather than a confirming one. The recurring failure mode across revisions
was worth the iterations: five separate defects (P0-1, R1, R3, V2, W1/W2) were
introduced *by* the fix for an earlier defect, which is exactly why each round
re-attacked the repair rather than accepting it.

**Residual risk the owner should carry forward**, all accepted by design and
documented in the spec: the KRL revocation window (§12); a one-line deletion
passing the removal caps (§10.3); `outcome: applied` meaning "the run refused
nothing", not health (§10.1); the Q4 authorization model — any enrolled host may
edit any fleet-shared layer (§7.3) — which is sound only because §7.3 row 2 has
no exception; and non-reversible categories under rollback (§10.8). If a second
human ever joins the fleet, revisit Q4 first.
