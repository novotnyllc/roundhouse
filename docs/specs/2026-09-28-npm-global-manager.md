# npm global packages, and the Node runtime under them

Status: sections 1–6 shipped in 0.9.27. Section 7 (Node runtime convergence)
shipped in 0.9.30, with the known limits in §7.8 and the deferrals in §7.9. Section 8 (`~/.npmrc`)
is follow-up design, not implemented.

## 1. Problem

Roundhouse managed Homebrew, Linuxbrew, APT and winget, and nothing managed
the Node toolchain. The fleet drifted in exactly the way unmanaged state
drifts: npm 11.x on some hosts and 12.x on others, Node 24 on Windows while
POSIX ran Node 26, different global packages per host, and a different
`~/.npmrc` per host. The owner wants that divergence to stop being possible:
Node, npm and global npm packages converge like any other package.

Facts the design rests on:

- POSIX hosts (macOS and WSL Ubuntu) get Node from fnm, itself a Homebrew or
  Linuxbrew formula. `fnm default` selects the version, and global packages
  live under that version's own prefix
  (`$FNM_DIR/node-versions/vX/installation/lib/node_modules`). A Node upgrade
  therefore starts with an empty global set.
- fnm's `fnm_multishells/<pid>/bin` directories are per-shell and deleted when
  the shell's session ends. A scheduler, SSH worker or tool that remembers one
  of those paths later fails or runs a Node nobody selected.
- Native Windows got Node from winget (`OpenJS.NodeJS`, the Current line,
  pinned with `winget pin add --id OpenJS.NodeJS --version 26.*`), whose
  global prefix, `%APPDATA%\npm`, survives Node upgrades. The MSI installs
  machine-wide, so every upgrade needs elevation; since 0.9.44 Windows
  runs fnm too (§7.7). Windows is reached through the WSL interop lane.
- Some global packages ship their own transactional updater that does more
  than replace files. opencodex's `ocx update` also restarts its background
  service, and `npm install -g` over it leaves the old service running.
- npm 12 blocks dependency install scripts unless `~/.npmrc` allows them
  (`allow-scripts[]=<name>`). `npm config set 'allow-scripts[]=x'` is
  rejected, so only the ini-array file form works.

## 2. The manager

`npm` is a `package_managers` value accepted on every platform (the system
managers stay bound to their platforms). It manages the global scope only.
Project-local `node_modules` are not packages in this sense.

### 2.1 One durable npm per host (`scripts/lib/npm.sh`)

npm's global prefix is derived from the Node that runs it, so "which npm" and
"which node" are one question. Resolution order:

1. fnm's `default` alias: `$FNM_DIR`, then `${XDG_DATA_HOME:-~/.local/share}/fnm`,
   then `~/Library/Application Support/fnm`, then `~/.fnm`, each at
   `aliases/default/bin`. This is the Node every new login shell gets.
2. `npm` on PATH.
3. The fixed prefixes a minimal scheduler PATH omits: `/opt/homebrew/bin`,
   `/usr/local/bin`, `/home/linuxbrew/.linuxbrew/bin`, `/usr/bin`.

A candidate counts only if it is outside `fnm_multishells` and its directory
holds both `npm` and `node`. Every invocation then puts that directory first
on PATH. npm is a `#!/usr/bin/env node` script, so running a durable npm under
the scheduler's Homebrew `node` would install into Homebrew's prefix. At least
one fleet host has both an fnm Node and a Homebrew `node` formula, so this is a
real hazard.

`$SHELL -lc npm …` would also reach the right Node, but under fnm every such
call mints a new multishell directory. The alias path gives the same Node with
none of that churn, and without depending on the operator's shell startup
files.

Test hook: `ROUNDHOUSE_TEST_NPM_FIXED_DIRS` replaces the fixed list only when
`ROUNDHOUSE_SELFTEST=1`, so the suite can never fall through to the real Node
on the machine running it.

### 2.2 Inventory

`collect-posix` and `collect-windows.ps1` emit one `package` record per
top-level global, `id: "npm:<name>"`:

```json
{"manager":"npm","name":"@bitkyc08/opencodex","installed_version":"2.70.0",
 "candidate_version":"2.71.0","update_available":true,"scope":"global",
 "prefix":"/Users/u/.local/share/fnm/node-versions/v26.7.0/installation",
 "node_version":"v26.7.0","updater":["ocx","update"],"updater_status":"proven"}
```

- Installed versions come from `npm ls --global --json --depth=0`. The JSON
  shape is trusted, not the exit status, because npm exits non-zero for
  extraneous or invalid trees while still printing the tree.
- Candidates come from `npm outdated --global --json`, `latest` field. It
  exits 1 exactly when something is outdated, and prints `{}` itself when
  nothing is. An `error` object or empty output is a failed query, reported as `packages:npm-updates` unavailable with `update_available:
  null`. It is never read as "everything current".
- `prefix` and `node_version` are part of the record, and so part of the
  sealed precondition digest. Under fnm a Node upgrade moves every global to a
  new prefix, so a plan sealed before the upgrade must not verify after it.
- `updater`/`updater_status` are described in 2.4.

### 2.3 Sealed-plan lane

A `package-upgrade` for `npm:<name>` seals with exactly one of two argv:

- `["npm","install","--global","<name>@<candidate_version>"]`, the exact
  candidate the snapshot reported, never `@latest`; or
- the package's own updater, exactly as configured (2.4).

`seal-plan` rejects any other argv, and an updater argv also needs the
snapshot record to show it proven. `verify-preconditions` and each apply
recapture and compare the whole record digest. The executor
(`execute_plan_operation`, and `Get-ExactArgv`/`Invoke-NpmUpdater` on
Windows) re-checks the argv shape, re-proves the updater, runs through the
durable npm, and then requires `installed_version == candidate_version` in
the post-inventory. These are the same guarantees the other managers give:
exact candidate, fresh precondition recapture, semantic post-state check. The
Windows seal allowlist now admits `npm:` next to `winget:`.

### 2.4 A package's own updater

Declared, never inferred, as **exact argv whose `argv[0]` must be a bin the
package itself installs**:

- Sealed lane: top-level `package_updaters` in `config.json`,
  `{"npm:@bitkyc08/opencodex": ["ocx","update"]}`. This follows the
  `auth_artifacts[].reauth` precedent: configured argv, compared whole,
  bound into the plan by the configuration digest. It is projected into the
  bounded worker config for the `updates` and `inventory` domains.
- Desired-state lane: an `update:` attribute on the npm entry in
  `definitions.yaml`, for example
  `opencodex: {npm: {name: "@bitkyc08/opencodex", update: [ocx, update]}}`.
  The definition is a reviewed item (`definitions.packages.opencodex`), and a
  held definition holds its package's update.

Store content is written by every synced host, so a definition cannot be the
trust root for a command. The scheduled pass runs a definition's `update`
only when the host's own `config.json` declares the identical argv under
`package_updaters`, the same trust root the sealed lane uses. A store-only
or mismatched updater holds the package (a `hold` line, no `npm install`
fallback). The definition says which updater the fleet wants, and each
host's local configuration decides whether that host will run it.

Binding to the candidate: an updater takes no version argument, so it
cannot be told to install the sealed `candidate_version`. Immediately
before running a sealed updater, the executors (POSIX and `apply-windows.ps1`)
query `npm view <name> version` through the durable npm and refuse, running
nothing, unless it equals the sealed candidate. The post-state check still
requires `installed_version == candidate_version`. Residual race: a release
published between that check and the updater's own registry lookup installs
the newer version. The post-check then fails and the apply reports
`partial`. The state is newer than planned but never silently accepted.

Grammar: 1–8 strings; `argv[0]` matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`;
each further argument matches `^[A-Za-z0-9@=:,._/+-]{1,128}$`. There is no
shell anywhere.

Proof, re-run by the collector, by `seal-plan` through the record, and by the
executor right before running it:

1. `argv[0]` is declared in the installed package's `package.json` `bin`
   (a string `bin` names the unscoped package; `directories.bin` is not read).
2. On POSIX, `<prefix>/bin/<argv[0]>` resolves through its symlinks to a path
   inside `<root>/<name>/`. A same-named bin from another package, or a file
   someone placed there by hand, fails. On Windows, the npm shim
   `<prefix>\<bin>.cmd` must exist; shims are not links, so the
   package-declares-it check is the binding.
3. It runs by absolute path, with npm's own directory first on PATH, stdin
   closed.

An unproven updater does not fail the inventory. The record carries
`updater: null, updater_status: "unproven"` and the plan will not seal.

Why not a free-form command: a definition or config value that can name any
executable turns a package-name lookup into arbitrary code execution on every
host. Tying the updater to a bin the package already ships adds no trust
beyond what `npm install -g` of that package already grants: npm runs the
package's own code either way.

## 3. Definitions and resolution

npm is opt-in per package:

- npm never applies the default rule. A logical name with no `npm:` entry is
  never guessed to be a registry package.
- A definition that declares `npm:` names a Node global. On a host that lists
  npm it resolves to npm whatever the host's list order. Other managers resolve
  it only through their own explicit entry, so a host without npm holds the
  item ("declared as an npm global; homebrew has no entry for it") rather than
  running `brew install opencodex`.
- The npm name and any `update:` are validated at resolution. A malformed
  definition is a hold that names the package.
- `version:` pins use the `flag` mechanism, as with winget and APT: installed
  exactly, and skipped by the update pass.

## 4. Desired-state run

- Fast pass (`fleet_install_package npm`): `npm install --global
  <name>@<version|latest>` through the durable npm, then `npm ls` must list the
  package, at the pin when there is one, or the item does not journal
  `applied`. No durable npm is exit 75: held, with the package-hold alert.
- Full pass: one `npm outdated` query per pass. Only packages it reports
  behind are touched, and each goes to that exact version, through the
  declared `update` argv when the local configuration declares it
  identically (2.4) and `npm install --global <name>@<version>` otherwise. The resulting version is then compared. A
  blind `@latest` reinstall twice a day would be churn, and it would bounce
  opencodex's service on every cadence.
- DSC does not run on native Windows (the design routes it through the WSL
  sibling). Windows npm globals, and the fnm Node runtime under them (§7.7),
  converge through the sealed interop lane.

## 5. Tests

`scripts/tests/77-npm.sh` runs a stub npm inside a fixture fnm tree. It covers
the grammar, durable resolution (the alias wins, multishell and node-less
candidates are refused, the fixed-dir hook is inert outside the self-check),
that npm runs under its own node, `ls`/`outdated` parsing including exit 1 and
error objects, updater proof including a declared bin whose link leaves the
package, resolver rules, fast-pass install and pin verification, the
full-pass updater versus exact install versus no-op, a store-only or
mismatched updater held with nothing executed, empty `npm outdated` output
rejected, config validation, the worker projection, the POSIX collector,
sealing refusals, apply with a wrong-version post-state, a sealed updater
refused without executing when the registry `latest` has moved, apply through
the updater, and the Windows collector under pwsh. `apply-windows.ps1
-SelfTest` covers the Windows argv allowlist and the registry-candidate check.

`scripts/tests/79-node-runtime.sh` covers §7 with a stub fnm and a stub npm
that keeps its globals per prefix: version grammar and numeric ordering, the
`runtimes.node` grammar, the release list (LTS codenames, a failed query),
switch refusals that change nothing (a carry not installed, a hook that is not
a bin of its package or of a carried one, shell syntax), a failed carry, a
failed install and a failed reconcile that never move the default (no `fnm
default` call, no in-flight record), a failed hook that restores it, a
successful switch that carries exactly the installed globals and runs the hook
under the new node while leaving the old version and its globals intact, the
carry and hook plan (store-only and mismatched hooks hold, host-only hooks
run), convergence on the reviewed apply and the
full cadence (in-line no-op, newest in line, exact pin both ways, a new
major, unreachable release list, unusable value, no fnm), the category arm,
the full cadence ordering the switch before the npm pass and skipping a held
item, config validation and the worker projection (Windows included), the `fnm:node`
collector record, sealing refusals (omitted, extra or unproven hooks, a wrong
carry, argv, candidate or runtime id), a failed sealed switch that restores
and reports `partial` and invalidates its plan, a completed sealed switch with
its post-state, the switch lock and in-flight record (a recovery leaves a
running switch alone, a stale lock is taken over, a live writer defers
recovery, two contenders for a stale lock never both take it, a holder's
start time reads the same under any TZ, `node-switch-clear` refuses without a
verified default and clears a backoff), the hook-failure backoff (including
the run loop deferring a backed-off switch to the same run's full pass), npm mutations refused while a switch is in flight (fast
install, seal, apply), and, under pwsh, the Windows pin and scope record and
the machine-scope hold, and the Windows fnm arm (the collector's `fnm:node`
record, the shadowed MSI and its refused upgrade, the switch sealed for a
Windows target). `scripts/tests/69-windows-interop.sh` runs a sealed Windows
switch end to end over the interop lane against a stub fnm. The `-SelfTest`s
of `node-fnm-windows.ps1` (discovery), `collect-windows.ps1` (the record) and
`apply-windows.ps1` (the switch phases, carry rule, post-state and bootstrap
over in-memory fnm and npm) cover the rest; `collect-windows.ps1 -SelfTest`
also covers the pin parser.

## 6. Known limits

- `npm outdated`'s `latest` can be lower than an installed prerelease. The
  full pass would then move to `latest`, and a sealed plan would show it as
  the candidate. No semver comparison is attempted.
- The Windows updater proof checks declaration plus shim existence, not link
  targets (2.4).
- A sealed updater can still race a release published between the registry
  check and the updater's own lookup. The post-check turns that into
  `partial` (2.4).

## 7. The Node runtime (implemented in 0.9.30)

The storage design's §5.1.2 now carries the amendment this needed: one
runtime, the host-default Node that runs the managed npm globals, is in scope.
Per-project and per-shell selection stay out. The first draft of this section
proposed a logical package `node` with a new `stream` pin in
`definitions.yaml`. What shipped differs where the draft could not do the job,
and each difference is noted below.

### 7.1 Desired state: `runtimes.node`

A new folded category, `runtimes`, with exactly one item:

```yaml
runtimes:
  node: {major: 26}            # the newest published release in major 26
runtimes:
  node: {version: "26.7.0"}    # an exact pin
```

- **Folded, not a definition.** Definitions sit outside the fold, so a
  `version: "26"` there could not be overridden per host. A category in the
  four layers gets per-host (or per-group, per-OS) override by ordinary
  layering, plus the review, canary gate and journal every item gets.
- **`major:` is the normal form.** fnm never moves within a major on its own,
  and the Windows pin is a major (`26.*`). Security releases arrive as patch
  releases; an exact version as the default form would need a store edit for
  each one, which is the drift this exists to end. `version:` is the opt-out,
  exactly as `version:` is for a package. Both at once must agree (the pin
  inside the major), or the item holds. `version: null` in a narrower layer
  drops a wider layer's pin.
- **A category, not a package.** A `packages.node` item would reach the
  resolver's default rule on hosts older than this change (`brew install
  node`, the very Homebrew-node hazard §2.1 describes) and would need `fnm`
  in `package_managers`, where it would then be offered every other package.
  The cost of a new category is the documented one: a host that predates it
  holds everything until it is upgraded, so `runtimes:` enters the store only
  once every host runs 0.9.30 or later.
- Any other `runtimes.<name>` holds. `runtimes.node: disabled` is satisfied
  and changes nothing.

### 7.2 Inventory

POSIX (`collect-posix`, on hosts that list `npm`): a `package` record
`fnm:node` next to the `npm:*` records.

```json
{"manager":"fnm","name":"node","installed_version":"v26.7.0",
 "candidate_version":"v26.10.0","update_available":true,"line":"26",
 "installed_versions":["v24.18.0","v26.7.0"],"stale_versions":["v24.18.0"],
 "fnm_dir":"/Users/u/.local/share/fnm",
 "prefix":"/Users/u/.local/share/fnm/node-versions/v26.7.0/installation",
 "globals":{"@bitkyc08/opencodex":"2.71.0","npm":"11.6.0"},
 "globals_unpinnable":[],"switch_hooks_unproven":[]}
```

`installed_version` is read from the `aliases/default` link itself, in the fnm
root lib/npm.sh already resolves (same roots, same order, same predicate), so
the runtime observed is always the one that owns the globals. The candidate is
the newest release in that major from `fnm list-remote`, parsed by the first
token of each line; `--filter`/`--sort` are not relied on. A failed query is
`packages:fnm-updates` unavailable, never "current". `globals` and `prefix`
make the record a precondition over the whole global set, and
`globals_unpinnable` names the globals a switch could not reinstall by exact
registry version (`file:`, `link:` or git sourced, or without a version).
Both come from one `npm ls`, so they cannot disagree; when it fails both are
null, which means unknown, and the carry rule holds on unknown rather than
reading it as "none unpinnable".

Windows (`collect-windows.ps1`), once fnm has a default there (§7.7): the
same `fnm:node` record, in the same shape, next to the `npm:*` records, which
then come from the fnm default's npm. The root is the first of `%FNM_DIR%`
(the process, then the user's own setting), `%APPDATA%\fnm` and
`%LOCALAPPDATA%\fnm` whose `aliases\default` junction holds `npm.cmd` and
`node.exe` (discovery lives in `node-fnm-windows.ps1`, which the collector
and the executor both dot-source); `installed_version` is read from that
junction's target, fnm itself is `fnm.exe` on PATH or where the bootstrap puts it (winget's
`%LOCALAPPDATA%\Microsoft\WinGet\Links`, `%LOCALAPPDATA%\fnm`, or beside a
root), and `globals`/`globals_unpinnable` come from the same `npm ls` as the
npm records. `switch_inflight` is the Windows switch's record reduced to
`{old, target, at}`. The `winget:OpenJS.NodeJS` record then carries
`shadowed_by: "fnm:node"`, `managed: false` and `update_available: false`:
the MSI stays installed but is unmanaged, never drift to upgrade. Two cases
are reported, never read as "no fnm": a default alias that names no installed
version (`packages:fnm`, `fnm_default_unreadable`), and an fnm default whose
npm reports a global prefix outside fnm, from an npmrc `prefix=` or
`NPM_CONFIG_PREFIX` (`packages:fnm-node`, `fnm_npm_prefix_foreign`; no
`fnm:node` record, so no switch seals).

Without fnm, the `winget:OpenJS.NodeJS` record carries `shadowed_by: null`
and `managed: true`, and gains `pin` (`{type:"Gating",version:"26.*"}` from `winget pin list`),
`pin_query`, `line`, and `install_scope`. The scope comes from the package's
own uninstall registration, never from PATH (a per-user `node` earlier on PATH,
from fnm, Volta or a local copy, says nothing about the MSI winget manages): a
`Node.js` registration under HKLM (64- or 32-bit view) and none under HKCU is
`machine`; the reverse is `user`; both, neither, an unreadable hive, or an
`InstallLocation` contradicting the hive is null, which sealing treats as
machine scope.

### 7.3 The switch (`scripts/lib/node-runtime.sh`)

`node_runtime_switch TARGET CARRY HOOKS` is shared by the sealed executor and
the desired-state run. It works in three phases, and the live default moves
only after the target is complete.

1. **Preflight** (mutates nothing; refusal is exit 64, 65 or 69). Every
   carried `{name, version}` must be installed under the current default at
   exactly that version (the carry reproduces what exists; it never
   introduces a package). Every hook must name a carried package and be
   provable, under the current prefix, as a bin of it (the §2.4 proof). A
   switch already recorded in flight (below) refuses.
2. **Staging**, into the TARGET prefix through TARGET's own `node` and `npm`
   (`npm --prefix`, TARGET's `bin` first on PATH), while the old default stays
   live:
   - `fnm install TARGET` (fnm pinned to the root with `FNM_DIR`, stdin
     closed).
   - If the old default's global `npm` is newer than the npm TARGET bundles,
     `npm install --global npm@<installed>` into TARGET first, and carry with
     that npm. npm 12 honours `allow-scripts` in `~/.npmrc`; an older bundled
     npm installing the carry would run every dependency install script.
   - One exact `npm install --global a@x b@y …`.
   - Reconcile the TARGET prefix to exactly the carry. Old versions are kept,
     so the target may be a version used before, whose prefix still holds
     globals removed or disabled since; left there, a rollback would
     resurrect them. Every top-level global there that is neither carried nor
     bundled with the target (`npm`, and `corepack` on 24 and older) is
     uninstalled, then the set must equal the carry, each at its version.

   Any staging failure exits 1 with the default never moved and nothing
   recorded.
3. **Flip.** Record the switch in flight, `fnm default TARGET`, verify the
   default (`node_default_verified`: the alias names TARGET, the durable npm
   resolves through the alias, and its node is TARGET), run each hook by
   absolute path under the new node (re-proved under the new prefix first,
   output to a temporary file so a hook that starts a daemon cannot hold the
   caller's capture or an SSH session open), verify the default AGAIN (nothing
   may have moved it while the hooks ran), and only then clear the record.
   Any failure here points `fnm default` back at the old version, verifies
   it the same way, clears the record and exits 1; exit 70 means the restore
   could not be verified, and the record stays.

**One lock** (`node-switch.lock`, a directory taken with `mkdir`, its owner
named by PID and process start time) covers a whole switch and a whole
recovery, in every lane: the scheduled run, `fleet-apply`, and a sealed
local or SSH apply. A second switch exits 75 without touching anything; a
recovery that finds the lock held by a live process leaves the switch alone
(§7.5). A lock whose holder is gone (killed mid-switch) is stale and is
taken over, under a second mutex (`node-switch.lock.break`) and only after
re-reading that the lock still has the owner judged stale, so two contenders
can never both take it; the in-flight record, not the lock, says whether
anything needs rolling back. Start times are read in UTC and the C locale,
so lanes with different `TZ` agree on whether a holder is alive.

The lock does not reuse the run lock (`fleet_lock_*`) for three reasons. Its
holder is named by PID **and start time**, so a recycled PID never looks
like a live holder. A run must be able to recover a switch interrupted
inside that same kind of run, which a lock held by the run itself would
block. And `collect-posix`, which reports the record, does not source
`fleet-store.sh`, where the run lock lives.

**The in-flight record** (`node-switch-inflight.json`: `{old, target,
carry, writer: {pid, start}}`) is host-local and outside the store. It is
cleared only by a verified success or a verified restore, so it survives a
crash, a kill or a lost SSH session mid-flip. A record whose writer is still
running is a switch in progress, never an interrupted one. While the record
exists the collector reports it (`switch_inflight` on `fnm:node`), the carry
rule holds, every lane refuses a new switch, every npm mutation is refused
(§7.5, §7.6), and the desired-state run first tries to finish the job by
restoring the recorded old default (§7.5).

**Where.** The lock, the record and the backoff record (§7.5) live at one
fixed path, `$HOME/.local/state/roundhouse/` (`%USERPROFILE%\.local\state\roundhouse\`
on Windows, §7.7), never under `XDG_STATE_HOME`:
launchd, an SSH worker and an interactive shell disagree on that variable,
and every lane must see the same record. The runtime they guard is the
account's own fnm default, under the same `$HOME`.

**A record no run can roll back** (its old version was uninstalled, or the
file is unreadable) leaves the default unverified until a person resolves
it: `roundhouse node-switch-clear` takes the lock, refuses while the record's
writer is running, and clears the record only when the CURRENT default is
self-consistent (`node_default_verified`) and its npm globals list. It never
clears blindly; with no fnm default or an inconsistent one it exits 65 and
says to set one (`fnm default <version>`) first. It also clears the
post-switch hook backoff (§7.5). The next run converges
`runtimes.node` from that default. Hooks the interrupted switch did not
finish are not rerun, so run them by hand if they matter.

Hooks that already ran are not undone; the new version stays installed, so a
service a hook moved keeps working. **No switch removes a Node version**: a
running service may still execute from the old prefix. Old versions are
reported (`stale_versions`, and a `note` line in the run). Removal stays the
separate, capped decision of the storage design's §10.3.

### 7.4 Post-switch hooks and their trust root

opencodex's background service embeds the absolute path of its runtime; after
a switch the service must be repaired (`ocx service`), and a WSL `ocx
codex-shim` wrapper that hardcoded the old path had to be reinstalled. Rather
than special-case a package, a package declares hooks from its own bins:

- Definition (store): `node_switch:` on the npm entry, a list of 1–4 argv in
  the §2.4 updater grammar, validated at resolution (a malformed one is a hold
  naming the package).
- Local configuration (trust root): top-level `node_switch_hooks` in
  `config.json`, `{"npm:@bitkyc08/opencodex": [["ocx","service"]]}`, validated
  with the same grammar and projected into the bounded worker configuration
  for every target (Windows included since 0.9.44: fnm switches there
  too, and `ocx service` re-registers opencodex's scheduled task).

The store can only *require* a hook. A switch runs exactly the hooks the
host's own `config.json` declares for the carried packages, and holds before
touching anything if a definition requires one the host has not declared
identically. A host may declare more than the definition requires (the
WSL-only shim reinstall), because local configuration is already the trust
root for commands. This is §2.4's rule with one widening: the updater must be
declared identically because it replaces the npm install, while a hook
requirement is a floor.

### 7.5 Desired-state run

- **Reviewed apply** (fast cadence, a new or changed `runtimes.node` value):
  switch only when the default is outside the major, or is not the pin.
- **Full cadence**: before the npm package pass, move to the newest release
  in the major, or back to the pin after a drift. It skips a held or
  canary-waiting `runtimes.node`, like every other maintenance action. Running
  first means the npm pass then sees the globals under the runtime they will
  run on.
- **The carry rule, the only one: a switch carries every global installed
  under the current default, at its exact installed version.** Nothing is
  added, and nothing installed is left behind. One pure function
  (`node_switch_plan`) implements it for the reviewed apply, the full
  cadence, `fleet-apply runtimes.node`, `seal-plan` and the executor's
  `verify-preconditions`, from nothing but the installed set:
  - *Not carried*: what the TARGET Node provides itself: `npm` (every
    release bundles it), and `corepack` only when the target bundles it
    (Node 24 and older). Leaving a bundling release for one that does not
    (24 to 26) carries the installed corepack from the registry at its
    version; dropping it would remove corepack and its shims. If that
    version cannot be installed, the carry fails, the default is restored,
    and the switch holds. `npm` comes from the new Node; the npm pass that
    follows moves a store-managed npm forward.
  - *Holds*: an unknown unpinnable set (the inventory detail failed), a
    global that cannot be reinstalled by exact registry version
    (`file:`, `link:`, git, no version; the switch names it instead of
    stranding it), a malformed `node_switch` on a definition of a carried
    package, and a required hook the host has not declared.
  - *Hooks* keep their trust model: `required` is every `node_switch` hook a
    definition requires for a carried package (not only store-managed
    ones), `hooks` is what this host's `config.json` `node_switch_hooks`
    declares for the carried packages, in carry order, and is what runs.
    Every required hook must be declared; the host may add more.

  *Why not the desired state.* The first rule derived the carry from the
  store: enabled packages declared as npm globals, intersected with what was
  installed. Each review round then found another installed global it could
  strand: a package whose definition did not resolve, one whose definition
  or desired state was held this run, one renamed or re-mapped since it was
  installed, one changed to `disabled` while that change was itself held,
  and the manual `fleet-apply` path, which has no run holds at all. Every fix
  added state (hold files, applied-record annotations, a store re-derivation
  at apply) and left the class open. The installed set has none of those
  failure modes, needs no store, and is what the switch must preserve anyway.
- **A switch recorded in flight** (§7.3) is resolved before anything else
  in every run that touches `runtimes.node`. A switch still in progress (the
  lock or the record's writer is a live process) is left alone and the item
  holds this run (`hold  runtimes.node — a Node switch is in progress on this
  host …`). Otherwise the run restores the recorded old default and
  verifies it; on success the record is cleared and the item
  holds this run (`hold  runtimes.node — an interrupted switch was rolled
  back …`), to be retried on a later run. When the restore cannot be
  verified, or a switch fails and cannot confirm its restore (the executor's
  exit 70), the default is one nobody verified: the run reports it (`hold
  runtimes.node — … is unverified`), never reports the item applied, alerts
  `node-runtime-unverified`, and refuses every npm mutation while the record
  exists: the npm part of every full cadence's package pass (`hold  packages
  (npm) — Node default is unverified …`), a fast-pass install of an npm
  package (deferred, apply status 73, with its own `package-deferred` alert
  rather than "no package manager can provide it"), and sealed `npm:*`
  upgrades (§7.6). Brew, winget and the
  rest of the pass still run. An ordinary hold, which leaves the default
  untouched or restored, skips nothing.
- **Backoff for a hook that keeps failing.** A failed hook restores the old
  default, and the attempt (target, carry, hooks) is recorded. The reviewed
  apply DEFERS that exact attempt without flipping (`hold  runtimes.node —
  the post-switch hooks failed for this exact switch …`, apply status 73)
  until the target, the carry or the hooks change. The run loop journals a
  deferral as `held`, but records it with its own hold line, which the full
  cadence's Node step does not count as a hold: that step is the retry, so
  a fixed hook is picked up at most one full interval later, with or without
  a store change. Any other hold of `runtimes.node` still stops the full
  cadence. A successful switch, or `node-switch-clear`, clears the record. Without it, a hook that always fails would flip and
  restore the live default on every fast pass.
- A `runtimes.node` hold that persists is not silent: every held run writes
  a `runtime-hold` alert naming the item (`runtime-hold-runtimes-node`).
  Repeated holds collapse into one alert once alerts are keyed by kind and
  item (the alert-writer change merging alongside this one); until then
  each held run writes its own.
- `fleet-seed` never turns the `fnm:node` record into desired state: not
  `packages.node` (Homebrew would read it as its `node` formula) and not
  `runtimes.node`, which enters the store by hand. Nor does it seed an `npm:*`
  record: without an `npm:` definition it would resolve to a system manager
  instead of npm.
- Hold lines: `  hold  runtimes.node — <reason>`, for an unusable value, a
  host without an fnm default, no fnm binary, an unreachable release list, a
  failed global inventory, an unpinnable global, a malformed or undeclared
  required hook, or a failed switch (after its restore).

### 7.6 Sealed lane

A `package-upgrade` with `id: "fnm:node"`:

```json
{"type":"package-upgrade","kind":"package","id":"fnm:node",
 "candidate_version":"v26.10.0","argv":["fnm","default","v26.10.0"],
 "carry":[{"name":"@bitkyc08/opencodex","version":"2.71.0"}],
 "hooks":[{"package":"npm:@bitkyc08/opencodex","argv":["ocx","service"]}],
 "required":[{"package":"npm:@bitkyc08/opencodex","argv":["ocx","service"]}]}
```

The draft proposed a new operation type with two argv; a composite with one
fixed marker argv is what the executor actually runs, and keeping
`package-upgrade` keeps the `updates` domain's existing contract (exact
observed candidate, fresh precondition recapture, semantic post-state). The
argv is the marker only; the executor knows no other `fnm` shape. `carry`,
`hooks` and `required` are refused on every other operation.

- `seal-plan`: candidate must be the observed `candidate_version` (so the
  sealed lane moves within the current major; a major change is a store edit);
  the switch must come before every `npm:*` upgrade in the same plan (an npm
  upgrade first would change a version the carry names, and the switch would
  refuse partway through an already-mutated plan); no carried package is in
  `switch_hooks_unproven`; and the carry rule (§7.5) over the snapshot's
  `globals`, `globals_unpinnable` and default, with the store's definitions
  for hook requirements, must hold nothing and give exactly the draft's
  `carry`, `hooks` and `required`. An empty, partial or padded carry, an
  omitted or extra hook, and misstated requirements are refused; so is a
  host with no store, whose hook requirements are unknown.
- No `npm:*` upgrade seals for a snapshot whose `fnm:node` record shows a
  switch in flight, verify-preconditions refuses one against a fresh
  snapshot that shows it, and the executor re-checks its own record before
  any npm upgrade (`a Node switch is recorded in flight …; npm upgrades are
  refused until it is resolved`).
- Apply time, on the host that executes, in every lane (local, and the SSH
  worker): the `fnm:node` record digest (default, installed versions, global
  set, candidate), then the carry rule over the fresh snapshot must give
  exactly the sealed `carry` and `hooks`, and every sealed `required` hook
  must be among the hooks. It needs no store: the carry is the installed set,
  and `required` is bound by the plan digest. No lane reads a store at apply.
  A Windows target seals the same operation on the ordinary lane (the WSL
  interop sibling or the Codex control project), and `apply-windows.ps1`
  runs the same checks natively (§7.7).
- Executor: re-checks the argv marker and the hooks against its own (worker)
  configuration, then runs §7.3. Seal and apply-time verification share one
  validator for the operation's shape (`node_switch_operations_valid`: at
  most one switch, the carry/hooks/required grammar, and those fields on no
  other operation) and one snapshot-to-plan path
  (`node_switch_plan_from_snapshot`), so the two cannot drift apart.
- Post-state: `installed_version == candidate_version`, the new record's
  `globals` (less what the target bundles) are exactly the carried names with
  nothing unpinnable left over, and every carried package is at its version,
  or at the
  `candidate_version` of a later `npm:*` upgrade of it in the same plan
  (seal orders those after the switch). A failure
  restores the default and reports `partial`. The `npm:*` records move to the
  new `prefix`/`node_version`, so npm plans sealed before a switch stop
  verifying after it.

### 7.7 Windows (fnm since 0.9.44)

The operator's decision (2026-10-01) is one runtime manager everywhere: fnm
is the Node runtime source on native Windows too, with no UAC and no ceremony
per upgrade. fnm installs per user, so every step runs in the user's own,
non-elevated session.

**Layout.** fnm keeps one prefix per version,
`<FNM_DIR>\node-versions\vX\installation`, holding `node.exe`, the npm shims
and `node_modules`. The release zip fnm installs carries no `npmrc` (the MSI
adds one pointing the prefix at `%APPDATA%\npm`), so that directory is also
the version's npm global prefix: a switch starts with an empty global set and
carries every global, exactly as on POSIX. `aliases\default` is a junction to
one of them.

**The switch** (`apply-windows.ps1`, the sealed `fnm:node` operation over the
existing interop apply path). The plan format is POSIX's; only the executor
arm is new. The worker:

- accepts the operation's exact shape (`argv` the fixed marker, `carry`,
  `hooks`, `required` in the npm grammar, at most one switch, before every
  `npm:*` upgrade) and requires `hooks` to equal what its worker
  configuration declares for the carried packages, in carry order;
- re-derives the carry rule (§7.5) over its fresh inventory, after the
  precondition digest: nothing may hold (unknown or unpinnable globals, a
  switch in flight), and `carry` and `hooks` must be exactly the sealed ones,
  with every `required` hook among them;
- runs §7.3's phases: PREFLIGHT (the carry is installed at exactly those
  versions, every hook a bin of a carried package under the current prefix);
  STAGING (`fnm install`; the target's npm brought up to the installed one
  when older, run by the target's `node.exe` from its own `npm-cli.js` with
  `--force`, because it overwrites the `npm.cmd` shims Node ships and must
  not run through them; one exact `npm --prefix <target> install --global
  a@x …`; leftovers uninstalled; the set verified); the FLIP (the in-flight
  record, `fnm default`, verify, each hook re-proved and run through the
  alias so a service it registers names a path that survives later
  switches, verify again, clear the record). Verifying a default also
  requires its npm's `prefix --global` to be fnm's. A failure after the flip
  restores the old default and verifies it, or leaves the record. Every
  failure carries the failing command's own output tail, as a failed sealed
  argv does;
- checks the post-state as §7.6 does (exactly the carry, nothing unpinnable,
  no record), and refuses every `npm:*` upgrade while a record exists.

The lock is `node-switch.lock` held open exclusively for the whole switch;
the OS releases it however the holder exits, so a killed switch leaves no
stale lock, only the record, which also names the fnm root the switch used.
Nothing on Windows runs the desired-state recovery, the hook-failure backoff
or `node-switch-clear` (no desired-state run reaches native Windows):
rerunning the bootstrap restores a recorded switch in its recorded root
(verified) before anything else, and refuses when the recorded old version
is gone, which leaves the record to a person.

**Bootstrap** (once per host, by its user, never elevated; idempotent):

```powershell
pwsh -NoProfile -File <plugin>\scripts\apply-windows.ps1 -BootstrapNodeFnm -NodeMajor 26
```

1. fnm, user scope: `winget install --id Schniz.fnm --exact --scope user`,
   else the pinned official release (`fnm-windows.zip` v1.39.0, SHA-256
   `8183bed4…001e10`, checked before anything is unpacked) into
   `%LOCALAPPDATA%\fnm`. An elevated session is refused.
2. `FNM_DIR`, a user variable: an existing one, else a root that already holds
   versions, else `%LOCALAPPDATA%\fnm` (machine-local, never roamed).
3. The newest release in the major as the fnm default, carrying every global
   the current npm lists (on the first run the MSI's `%APPDATA%\npm`: npm,
   `@bitkyc08/opencodex` and the rest) at its exact version, through the same
   staging and flip as the sealed switch. A default already in the major is
   left alone; a linked or `file:` global refuses, naming it.
4. `<FNM_DIR>\aliases\default` first on the user `Path` (read raw, so `%VAR%`
   entries and the value kind survive).

The MSI and `%APPDATA%\npm` stay (removing the MSI needs elevation). The
collector then reports the MSI shadowed and unmanaged, `seal-plan` refuses
any `winget:OpenJS.NodeJS` upgrade (`hold: Node.js (winget OpenJS.NodeJS) is
shadowed by fnm …`), and `runtimes.node` converges through `fnm:node`. A
service a global installed before the migration (opencodex's scheduled task)
still runs on the MSI's Node until its own repair runs (`ocx service`).

**Without fnm** (a host not yet migrated), the earlier rules stand: the MSI
installs machine-wide, a machine-scope upgrade needs elevation, unattended
runs never attempt it, and `seal-plan` refuses an ordinary-lane
`winget:OpenJS.NodeJS` upgrade unless the record shows `install_scope:
"user"`, with `hold: Node.js (winget OpenJS.NodeJS) is installed machine-wide
and needs elevation`. The protected `winget.upgrade-machine-package.v1`
semantic action, where readiness advertises it, is the only elevated lane;
otherwise the answer is the hold, never a UAC prompt.

### 7.8 Known limits

**PATH precedence on Windows.** Windows builds a new process's PATH as the
machine `Path` followed by the user's, so the MSI's `C:\Program Files\nodejs\`
(machine PATH) still answers a bare `node`, `npm` or `npx` in a new session
after the bootstrap. Global bins resolve to the fnm default (its alias is
first on the user PATH, ahead of `%APPDATA%\npm`, and every npm shim runs the
`node.exe` beside it), and Roundhouse resolves npm and node through the fnm
root itself, never PATH. Removing the MSI, or prepending the alias in a shell
profile, is the operator's own step; the bootstrap reports which `node.exe`
a new session finds.

**Unbounded Windows calls.** `fnm install`, `fnm list-remote`, the npm calls
and the hooks run without lib/timeout.sh's ceilings on Windows, like every
other native call the Windows executor makes.

**Windows hooks and daemons.** A hook runs through the executor's captured
native call, like a package updater. `ocx service` registers a scheduled
task, whose process is not the hook's child; a hook that started a daemon of
its own could hold the worker's output open, as on POSIX before the hook log.

**Install source.** `globals_unpinnable` is only as good as what npm reports. npm 12 reports no
install source for globals: `npm ls --global --json` (with or without
`--long`) gives no `resolved` or `integrity`, there is no hidden lockfile in
the global `node_modules`, and installed `package.json` files carry no
`_resolved`. Measured on npm 12.2.0, a global installed from a local tarball
shows exactly like a registry install. The blacklist therefore catches only
what npm does report (`file:`, `link:`, git, a missing version). A global
installed from a non-registry tarball (a local file or an HTTPS URL) that
shares a published `name@version` is indistinguishable, and a switch replaces
it with the registry copy, which may be different code; the version-only
post-check accepts that.

Closing this would need per-switch evidence: fetching the registry artifact
and comparing it with the installed tree. The fleet's hands-off requirement
rules that out. It costs network on every switch, and trees that a
postinstall modifies (opencodex's bundled bun, for one) would never compare
equal, so those switches would hold. Install such a global from the registry,
or remove it before a switch, if its source matters.

**Host-only hooks on a sealed remote switch.** A sealed plan binds `hooks`,
and `seal-plan` derives them from the sealing host's `config.json`. A hook
that only the target host declares (the WSL-only `ocx codex-shim` reinstall)
cannot be expressed in a plan sealed elsewhere: the target's apply-time
check derives the hooks from its own worker configuration, finds one more,
and refuses the plan without changing anything. Such a host converges
through the scheduled desired-state lane, which runs on the host and honours
its local hooks. Sealing on the target itself works too.

### 7.9 Deferred

- **Windows pin reconciliation** (hosts without fnm only; on a migrated host
  the MSI is unmanaged). The collector reports the gating pin; nothing
  yet sets `winget pin add --id OpenJS.NodeJS --version <major>.*` from
  `runtimes.node`, and nothing compares the two. That needs a sealed
  native-Windows pin operation and belongs with the WSL sibling's view of the
  Windows host.
- **A sealed major switch.** The sealed lane moves within the current major
  only; crossing majors goes through `runtimes.node` and its review and canary
  gates.
- **Removal of old versions.** Reported, never automated (§7.3).
- **Parity.** A `fleet-doctor` row comparing `fnm:node`/`OpenJS.NodeJS`
  versions against the declared line across hosts. Every input is already in
  the inventory records.
- **Post-upgrade `npm ls` on Windows.** The `npm:*` records already carry
  `node_version`, so the next inventory shows the new runtime; no explicit
  check is sealed.
- **Other runtime sources** (nvm, Volta, Homebrew `node@N` as the default) and
  other runtimes. Out of scope by the §5.1.2 amendment.
- **Consolidation follow-ups** from the pre-push review, none a behaviour
  change: one shared helper for the fnm root list (lib/npm.sh and
  lib/node-runtime.sh each walk it); a single `npm ls` parser for inventory,
  staging and post-checks; a definitions helper for the npm entry and its
  argv validation (`fleet_resolve_argv_valid`); removing the unused
  `node_version_normalize`; folding the thin wrappers around `node_fnm_run`;
  and extracting the hook-proof loop in `collect-posix` into lib/npm.sh.
  Also deferred from the final review: one PID-and-start-time lock helper
  shared with any other host-local lock; a single mapping from recovery
  results (0/74/75/76) to run outcomes; a `node_state_write` helper for the
  three state files; a `node_switch_in_flight` predicate in place of the
  `[ -n "$(node_switch_marker_read)" ]` idiom; an npm-neutral prefix for
  `release_newer`'s home; splitting the switch state (lock, record,
  backoff) into its own `node-switch-state.sh`; and binding the parsed value
  once (`as $n`) in `node_runtime_spec`.
  `seal-plan` keeps its own "at most one Node switch" check in front of the
  shared operation validator, because the validator reports only "invalid
  plan draft" and the specific message is what an operator needs.

## 8. `~/.npmrc`: chezmoi owns it

`allow-scripts[]` entries are user configuration in a dotfile, which is what
chezmoi (`agent-utilities:fleet-chezmoi`) converges. Roundhouse should not
also write the file: two writers of one dotfile is how the fleet drifted in
the first place, and the ini-array form (`npm config set` rejects
`allow-scripts[]=x`) means Roundhouse would be hand-editing an ini file that
chezmoi then reports as drift. The template should carry at least
`allow-scripts[]=oracle` and `allow-scripts[]=bun` (opencodex's `bun`
dependency needs its postinstall).

Possible follow-up: the npm inventory could report which installed globals
have dependency install scripts not covered by `allow-scripts`, as a
readiness warning. That reads the file and never writes it.
