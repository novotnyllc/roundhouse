# npm global packages, and the Node runtime under them

Status: sections 1–6 shipped in 0.9.27. Section 7 (Node runtime convergence)
and section 8 (`~/.npmrc`) are follow-up design, not implemented.

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
- Native Windows gets Node from winget (`OpenJS.NodeJS`, the Current line,
  pinned with `winget pin add --id OpenJS.NodeJS --version 26.*`). Its global
  prefix, `%APPDATA%\npm`, survives Node upgrades. Windows is reached through
  the WSL interop lane.
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
  sibling). Windows npm globals converge through the sealed interop lane.

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

## 6. Known limits

- `npm outdated`'s `latest` can be lower than an installed prerelease. The
  full pass would then move to `latest`, and a sealed plan would show it as
  the candidate. No semver comparison is attempted.
- The Windows updater proof checks declaration plus shim existence, not link
  targets (2.4).
- A sealed updater can still race a release published between the registry
  check and the updater's own lookup. The post-check turns that into
  `partial` (2.4).

## 7. Follow-up: converge the Node runtime (not implemented)

Deferred because it cuts across a decision the storage design states
explicitly. §5.1.2 of `2026-08-06-dsc-storage-design-v2.md` puts language
version managers (nvm, pyenv, rbenv, asdf) out of scope. fnm is used here as
the host's Node source, not for per-project selection, but that is an
amendment to §5.1.2 and should be made deliberately rather than slipped in
with a package manager. Carrying globals across a Node upgrade is also a
multi-step mutation with its own failure modes.

Proposed shape:

1. **Amend §5.1.2.** A version manager may be a package manager for the
   single host-default runtime it selects (`fnm default`). Per-project and
   per-shell selection stay out of scope.
2. **Logical package `node`, stream-pinned.**
   `node: {version: "26", fnm: node, winget: OpenJS.NodeJS}`. Here `version`
   is a stream (major), not an exact pin. That is a new pin mechanism,
   `stream`, allowed only for `fnm` and `winget`.
3. **POSIX `fnm` manager.**
   - Inventory: `fnm list`, the `fnm default` alias target, and the newest
     remote in the stream (`fnm ls-remote` filtered to `v26.*`). Emit
     `fnm:node` with `installed_version` set to the default version and
     `candidate_version` set to the newest stream version.
   - Sealed operation `runtime-upgrade` (a new type, so it cannot be confused
     with a package upgrade), `id: "fnm:node"`, with fixed argv
     `["fnm","install","<v>"]` then `["fnm","default","<v>"]`. The executor
     knows only these two.
   - **Global carry-over, inside the same operation:** before switching,
     record the old default's globals (`npm ls -g --json --depth=0` through
     the durable npm). After `fnm default <v>`, the durable npm resolves to
     the new prefix. Install the same set there at the same versions
     (`npm install --global a@x b@y …`, one exact list). Declared updaters
     are not used for carry-over; an exact reinstall is.
   - Post-state: the default equals `<v>`, and every recorded global is
     present under the new prefix at its recorded version. On failure, point
     `fnm default` back at the old version, which is never uninstalled here
     (removal is the separately capped decision §10.3 already describes).
     Report `partial` with both prefixes.
   - The precondition digest already covers `prefix` and `node_version` on
     every `npm:*` record, so npm plans sealed before a runtime upgrade stop
     verifying after it.
4. **Windows.** winget `OpenJS.NodeJS` already resolves through the existing
   winget manager. What is missing is the stream pin. Map `version: "26"` to
   `winget pin add --id OpenJS.NodeJS --version 26.*` (idempotent, reported
   by `winget pin list`) and upgrade within the stream with the existing
   exact-version `winget.upgrade-machine-package.v1` path. `%APPDATA%\npm`
   survives the upgrade, so Windows needs no carry-over. Only a post-upgrade
   `npm ls` check is needed.
5. **Parity.** A `fleet-doctor` row comparing `node_version` and each
   `npm:*` `installed_version` across hosts. Both are already in the
   inventory records.

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
