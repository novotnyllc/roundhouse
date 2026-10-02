---
name: fleet-update
description: Plan and explicitly apply package updates across Homebrew, APT, winget, global npm packages, and the Node runtime under them. Use for fleet patching, outdated-package reports, manager-specific updates, package or Node version drift, or post-update verification.
---

# Fleet Update

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md` and
`CLI="$SKILL_DIR/../../scripts/roundhouse"`; the shell working directory
is not the skill directory. Resolve exact hosts or groups from the user config
and inventory the package section first.

**Authorization model:** an explicit request to update ("update my packages",
"patch the fleet", a scheduled unattended run) *is* the mutation
authorization — plan, seal, verify, and apply in one pass without asking
again. A request to inspect, report, or plan stops at the read-only plan, and
apply permission is never inferred from it. The sealed pipeline below is
safety mechanics, not an approval gate. Execute ordinary CLI operations
directly. The calling workflow owns any model selection or agent dispatch
policy.

- Homebrew: on an update request, refresh metadata (`brew update`) and
  proceed; use `brew outdated --json=v2` for the plan and `brew upgrade` for
  the planned formulae/casks. macOS casks run as the ordinary Homebrew owner through the
  packaged bridge hook so Homebrew retains Caskroom authority. An unprivileged
  app upgrade (including Visual Studio Code when its destination is writable)
  follows Homebrew normally. A cask package that reaches Homebrew's hardcoded
  `sudo` succeeds only when it byte-matches an active exact
  `sealed-cask-payload-v1` enrollment; other privileged artifacts fail closed.
- APT: on an update request, `apt-get update` then plan with
  `apt-get --simulate upgrade`. Do not use `full-upgrade`, `dist-upgrade`, or
  `autoremove` unless explicitly selected.
- winget: plan with `winget upgrade --accept-source-agreements
  --disable-interactivity`; an update request covers the planned packages
  (`--all` when the request was fleet-wide).
- npm (global scope, any platform; list `npm` in the host's
  `package_managers`): the collector reports `npm:<name>` records from
  `npm ls --global --json --depth=0` and `npm outdated --global --json`, each
  carrying the global `prefix` and `node_version` it was observed under. A
  `package-upgrade` argv is exactly `["npm","install","--global",
  "<name>@<candidate_version>"]`, or the package's own updater when the
  configuration declares it under top-level `package_updaters` (for example
  `"npm:@bitkyc08/opencodex": ["ocx", "update"]`) and the snapshot record shows
  `updater_status: "proven"`, meaning `argv[0]` is a bin the installed package
  declares and its global link resolves inside that package. Nothing else
  seals. An updater takes no version, so right before it runs the executor
  asks the registry (`npm view <name> version`) and refuses, running
  nothing, unless `latest` still equals the sealed `candidate_version`. The
  post-state check still requires the installed version to equal it. A
  residual race remains: a release that lands between that check and the
  updater's own resolution installs the newer version, and the apply then
  reports `partial` rather than silently accepting it. Empty `npm outdated`
  output is a failed query (npm prints `{}` itself when nothing is
  outdated), never "all current". npm always runs through the durable npm: fnm's `default` alias first,
  then PATH, then the fixed Homebrew/Linuxbrew/system prefixes, never an
  `fnm_multishells` path, and always with npm's own directory first on PATH so
  the matching `node` owns the install. On native Windows (winget
  `OpenJS.NodeJS`) the executor resolves `npm` from PATH and an updater from
  the prefix npm reports. npm 12 blocks dependency install scripts unless
  `~/.npmrc` allows them (`allow-scripts[]=<package>`, written in the ini
  array form because `npm config set` rejects it). chezmoi owns that file;
  Roundhouse neither writes nor rewrites it.
- Node runtime (the one runtime Roundhouse owns: the host-default Node under
  the managed npm globals). On POSIX the collector reports `fnm:node` next to
  the npm records: `installed_version` is `fnm default`, `candidate_version`
  the newest published release in that major (`fnm list-remote`), plus
  `installed_versions`, `stale_versions` (installed, not the default),
  `globals` (the default's top-level globals), `globals_unpinnable` (globals
  that cannot be reinstalled by exact registry version: `file:`, `link:`,
  git, no version, as far as npm reports a source) and `switch_hooks_unproven`.
  Known limit: npm 12 reports no install source for most globals, so one
  installed from a non-registry tarball under a published `name@version`
  looks pinnable and a switch replaces it with the registry copy.
  A switch is a `package-upgrade` with `id: "fnm:node"`, argv exactly
  `["fnm","default","<candidate_version>"]`, a `carry` list
  `[{"name","version"}]`, a `hooks` list and a `required` list (both
  `[{"package","argv"}]`), placed before any `npm:*` upgrade in the same plan.
  None of them is chosen; seal-plan derives them with the one carry rule and
  requires the draft to equal it exactly: `carry` is every global the
  snapshot shows installed under the current default at its exact version,
  less what the target Node provides (`npm`, and `corepack` only when the
  target is Node 24 or older; moving 24 to 26 carries an installed corepack); `hooks` is, in carry order, every argv the configuration
  declares under top-level `node_switch_hooks` for the carried packages (for
  example `"npm:@bitkyc08/opencodex": [["ocx", "service"]]`); `required` is
  every `node_switch` hook the store definitions require for a carried
  package, each of which must be in `hooks`. An empty or partial carry, a
  hook mismatch, an unpinnable global, and a host with no store (hook
  requirements unknown) are refused. At apply, the executing host (local or
  the SSH worker) re-derives the carry from its fresh snapshot and requires
  the same carry, hooks and required hooks; no lane reads a store at apply.
  The executor takes the host's Node switch lock, proves each hook bin under
  the current prefix, and STAGES the new version before anything live
  moves: `fnm install`, the new version's npm brought up to the host's if
  older, one exact `npm install --global a@x b@y …` into the new prefix
  through its own npm, anything else left in a previously used prefix
  uninstalled (bundled npm/corepack excepted), and the set verified as
  exactly the carry at its versions. A failure there leaves the default
  untouched. Only then does it RECORD the switch in flight, FLIP `fnm
  default`, verify the default, run each hook by absolute path under the new
  node, verify the default again, and clear the record. Any failure after
  the flip points it back at the old version and the apply reports
  `partial`. Old
  versions are never removed (a service may still run from one); they are
  reported. The sealed lane moves within the current major; a major change is
  a store edit (`runtimes.node`, below). On Windows Node is winget
  `OpenJS.NodeJS`: its record carries the gating `pin` (`winget pin add --id
  OpenJS.NodeJS --version 26.*`), `line` and `install_scope` (read from the
  package's HKLM/HKCU uninstall registration, never from PATH; ambiguous
  evidence is null and treated as machine scope). The MSI
  installs machine-wide, so the ordinary lane refuses its upgrade (`hold:
  Node.js … needs elevation`); seal the protected
  `winget.upgrade-machine-package.v1` action when readiness advertises it for
  that channel, and otherwise report the hold. Never trigger a UAC prompt.
  `%APPDATA%\npm` survives the upgrade, so Windows carries nothing and runs no
  hooks.

Present exact host, manager, package, current version, candidate version, and
command. Every `package-upgrade` operation must carry the exact observed
`candidate_version`; sealing refuses a candidate not present in the snapshot,
and the fresh precondition snapshot must still report it. Put those inert
operations in a plan draft and run
`"$CLI" seal-plan DRAFT SNAPSHOT PLAN`. Before apply, verify live host and
platform identity, recapture package inventory, and require
`"$CLI" verify-preconditions PLAN CURRENT-SNAPSHOT` to succeed. This binds
config, plan integrity, and preconditions without executing plan text. Then
execute only the exact argv sealed in the plan. For a local target use `"$CLI" apply-plan PLAN PLAN-ID OUTPUT`; for SSH
use `"$CLI" apply-ssh-plan PLAN PLAN-ID OUTPUT`; for native Windows with a
`wsl_interop_via` sibling use `"$CLI" apply-interop-plan PLAN PLAN-ID OUTPUT`
(winget and npm upgrades run through the installed, verified `apply-windows.ps1`).
Each recaptures trusted preflight and enforces the same executor, identity, manager-command,
fresh-precondition, and semantic post-state checks. If an operation or
postcondition fails, preserve the authoritative partial result emitted when
post-inventory remains available. SSH uses bounded connection/keepalive
timeouts and verifies the configured native hostname/user. Never infer apply
permission from a request to inspect or plan.

Run each native manager directly on local/SSH hosts. For Windows, the
default lane is WSL interop whenever the machine declares `wsl_interop_via`:
SSH to the sibling, `cd /mnt/c`, and run winget and the other native
managers through full-path `cmd.exe /c` — native processes from any
harness. Only when WSL is absent or unreachable, or the work needs the
Desktop app surface, does Codex fall back to
`"$SKILL_DIR/../../references/codex-remote-control.md"` (model and effort
chosen per `railyard:model-routing`); Claude
reports that fallback lane as unsupported. Never run the managers
WSL-side in place of native Windows. Preserve native approval
prompts, stop per host on failure, and recapture package inventory afterward.
Cleanup and autoremove are separate explicit actions.

## Unattended schedule

Auto-updating on a schedule uses the OS scheduler calling the CLI — no new
daemon, database, or engine. **There is exactly one owned scheduler
entry per host**: the fast and full job pair that `roundhouse fleet-schedule`
installs, and it runs `roundhouse fleet-run`. Two local runners racing one
plugin cache is the failure this prevents, so a second entry is never
added: the desired-state run **absorbs** the older autoupdate entry rather
than being given one of its own. Marketplace refresh and package updates are
not a separate job — the full cadence does both, on the same convergence that
applies everything else (see `roundhouse:fleet-agents`).

Marketplace convergence compares resolved source bytes with the installed
plugin identity; a same-version SHA change reinstalls, while a matching SHA is
already current.

After every plugin `install`, `update`, or `enable` operation performed by the
DSC apply path, immediately run
the hook approval helper and verify its result before journaling the item as
applied when Codex owns that qualified plugin and the desired state is enabled.
The apply path checks Codex's
installed-plugin list first; a Claude-only plugin has no Codex hook state and
skips the helper rather than becoming a false hold. A disabled desired state
does not approve an independently enabled Codex copy. A desired `enabled`
state that is already enabled is a no-op: the manager enable verb and approval
helper are not invoked, so a locally modified hook cannot be laundered by
steady-state convergence. This is the automatic local hook trust step for
fresh and changed hook hashes; it is not a copied settings table.
If Codex does not report the installed qualified plugin at the desired source
SHA, or reports an untrusted or locally modified hook during automatic
approval, the helper refuses and the DSC item is held; refresh/repair the
Codex copy or explicitly approve that hook before retrying.
On POSIX schedulers, invoke `roundhouse approve-codex-plugin-hooks
PLUGIN@MARKETPLACE` through the user's login shell or provide a PATH containing
the harnesses and Node.js. The runtime also checks the standard
Homebrew Node locations on macOS. On native Windows, invoke
`scripts/codex-plugin-hooks.ps1 approve PLUGIN@MARKETPLACE`; it resolves Node
in this order: `node.exe` from the task PATH, the Codex-bundled runtime beside
the `codex.exe` actually in use (including its versioned siblings, newest
mtime first), then a last-resort Claude-bundled probe derived from
`claude.exe`. The helper runs only where Codex exists, so the Codex-bundled
probe makes Node effectively guaranteed and Windows never depends on Claude.
If all three probes fail it exits 69 with guidance naming the probes and the
WSL interop recovery, rather than silently claiming approval. The native DSC
executor invokes this same helper, so its scheduled task does not require Node
to be on the task PATH.

The entry drives **two cadences from one owned slot**:

| Cadence | Command | Default | Covers |
| --- | --- | --- | --- |
| Fast | `roundhouse fleet-run --fast` | every 20 min | converge desired state: fetch, review, apply, publish |
| Full | `roundhouse fleet-run --full` | twice a day | the fast pass plus marketplace refresh, unpinned package updates, re-seed, promotion proposals, and `fleet-doctor` |

The full cadence's package pass also covers npm globals the store declares.
A logical package reaches npm only through a definition with an `npm:` entry
(for example `opencodex: {npm: {name: "@bitkyc08/opencodex", update: [ocx,
update]}}`). npm never applies the default rule, and the system managers do
not guess at a package declared for npm. The pass upgrades only what
`npm outdated` reports behind, to that exact version, through the declared
`update` argv when there is one and `npm install --global <name>@<version>`
otherwise. Store content is written by every synced host, so a definition
alone never introduces a command: the pass runs a definition's `update` only
when this host's own `config.json` declares the identical argv under
`package_updaters`, with the same bin check as the sealed lane. Otherwise it
prints `hold  packages.<name> — npm updater … is not declared identically …`
and skips that package, with no `npm install` fallback. A `version:` pin
installs exactly and is skipped by the update pass, as with winget and APT.
The fast pass installs an enabled npm global that is missing, then requires
`npm ls` to list it (at the pinned version when there is one) before it
journals `applied`. A host without a durable npm holds the item.

The Node runtime under those globals is desired state too, in its own
category, `runtimes`, with exactly one item:

```yaml
# fleet.yaml: the fleet line, the newest release in major 26
runtimes:
  node: {major: 26}
# hosts/<name>.yaml: a per-host override, by ordinary layering
runtimes:
  node: {major: 24}          # or {version: "26.7.0"}: an exact pin
```

`major:` is the normal form: fnm never moves within a major on its own, so
the full cadence does, to the newest published release in that major. An
exact `version:` pins, like a package `version:`, and the full cadence then
only restores it after a drift (a host that must drop a fleet pin sets
`version: null`). The reviewed apply (fast cadence, on a new or changed value)
switches only when the default is outside the major or is not the pin. One
rule governs every lane: a switch carries every global installed under the
current default at its exact version (less what the target Node provides:
`npm`, and `corepack` only on Node 24 and older), then runs post-switch
hooks. It never adds a
package and never leaves an installed one behind, whatever the store says
about it (disabled, renamed, held); a global it cannot reinstall by exact
registry version (`file:`, `link:`, git) holds the switch by name. The
carry is installed and verified in the new Node's own prefix before the
default moves, so a failed carry never touches the live default; the npm
that installs it is upgraded first if the host's global npm is newer than
the one the new Node bundles. The move itself is recorded in flight
(`~/.local/state/roundhouse/node-switch-inflight.json`, a fixed path whatever
`XDG_STATE_HOME` says) until it verifies or its restore does, and one lock
covers every switch and every recovery, so a run never rolls back a switch
that is still running (it holds the item instead). A record left by a crash
is rolled back by the next run (that run holds the item). One that cannot be
rolled back reports the default as unverified, alerts
`node-runtime-unverified`, and refuses every npm mutation (the full pass's
npm step, fast-pass npm installs, sealed `npm:*` upgrades) until it is
resolved. When the old version is gone for good, set a working default
(`fnm default <version>`) and run `roundhouse node-switch-clear`: it clears
the record (and any hook backoff) only if no switch is running and the
current default verifies. A post-switch hook that fails restores the old
default, and the reviewed apply then defers that exact attempt instead of
flipping again every fast pass; the full cadence retries it, even in a run
whose apply loop just deferred it. An npm install deferred by a switch in
flight alerts `package-deferred`, not `package-hold`. A `runtimes.node` hold of any kind also
alerts (`alerts/<host>/runtime-hold--runtimes.node.yaml`), so a persistent hold is visible.
These three alerts are conditions: each clears itself on the first pass that
checks the item and finds the hold, the deferral or the in-flight record gone.
Hooks a definition requires are sealed from the sealing host's config; a
hook only the target host declares cannot ride a plan sealed elsewhere (the
target refuses it), so such a host converges through its scheduled run. `fleet-seed` never seeds `packages.node` or
`runtimes.node` from the runtime record, nor a package from an `npm:*`
record (npm manages only through an `npm:` definition). A definition may require hooks with
`node_switch:` on its npm entry (`opencodex: {npm: {name:
"@bitkyc08/opencodex", update: [ocx, update], node_switch: [[ocx,
service]]}}`), but only this host's `config.json` `node_switch_hooks`
introduces a command: every hook a definition requires for a carried
package must be declared there identically, or the switch prints `hold
runtimes.node — npm:<name> requires node_switch hook …` and changes nothing.
The host may declare further host-only hooks (a WSL-only shim reinstall,
say); those run too. What the new Node provides, and older Node versions
(never removed), are reported as `note` lines. `runtimes.node: disabled` stops managing the
runtime. Only fnm is a runtime source; DSC never runs on native Windows, whose
Node converges only through the sealed lane above. Add `runtimes:` to the
store only once every host runs a Roundhouse that knows the category (0.9.30
or later): an older host holds everything on an unknown category.

Both intervals are jittered from the host **name**, so the fleet does not
re-synchronise on the same minute; the interval keys live in the store's
policy block, not on the machine being governed.

The calling workflow installs the entry on request, on the host itself, after
`roundhouse launcher-install` (the jobs run that `~/.local/bin/roundhouse`
shim):

```bash
roundhouse fleet-schedule install     # write and load both jobs; idempotent
roundhouse fleet-schedule status      # installed / enabled / loaded, definition matches or differs
roundhouse fleet-schedule uninstall   # unload and remove both
```

`install` and `uninstall` are mutations, so they ride the **sealed-plan
pipeline** like `launcher-install` (they need the mutation configuration and
one local machine whose `expected_hostname`/`expected_user` are this host's).
The collector observes the jobs (an `agent_artifact roundhouse:schedule`
record: every definition file's sha256 or its absence, each job's
loaded/disabled or enabled/active state, the superseded entries); the plan
lists the exact files to write, keep, remove or absorb (each written file with
its rendered sha256) and the exact `launchctl`/`systemctl --user` commands, in
order, and is sealed with that record as its precondition. `apply-plan`
re-collects and refuses if anything changed since the seal — a job disabled or
a definition edited in between gets a refusal, not a surprise — then runs only
those steps (a definition only while it still renders to the sealed digest, a
command only when it names this host's own jobs), checks every written file is
at its sealed digest and every removed one is gone, and `status` must then
report the result. `status` is read-only and unsealed. On Linux, lingering is
checked before anything is planned: without it `install` exits 75 with the
`loginctl enable-linger` fix and writes nothing.

`install` matches a job that already exists: an identical definition is left
alone (not rewritten, not reloaded); a differing one is reported by path
(never by content — a hand-added environment variable may be a secret), then
replaced and reloaded. **Absorb, never duplicate**: if
`com.novotnyllc.roundhouse.autoupdate` or the older one-plist
`com.novotnyllc.roundhouse.fleet` (or a systemd/Task Scheduler equivalent)
exists, unload it and set it aside (renamed `.absorbed`, never deleted) in the
same step that installs the fleet entry; `install` does this for both macOS
labels. A replaced definition that differed is kept as `.replaced`, and one
`uninstall` removes as `.removed`; a backup that cannot be made stops the step.
`uninstall` unloads a job the scheduler still holds before it removes the file,
and is not done until the scheduler has let go of it. It also opts the host
out of triggers: after `uninstall`, a trigger or peer nudge only stamps and
starts no pass until `install` runs again. A host carrying both
is the exact double-runner this rule exists to prevent. `install` is also the only thing that enables a job: a scheduled pass
never re-enables one an operator disabled, it raises a `schedule-disabled`
alert (and `schedule-missing` for a job that disappeared) instead.

The shape per platform, all three running the same two commands:

Both intervals come from the same policy the run reads
(`fast_interval_minutes` ± `fast_jitter_minutes`, `cadence_hours` ±
`jitter_minutes`; 20 ± 5 min and 12 h ± 90 min by default), with the offset
seeded from the host name, so each host's jobs fire on their own stable
minute. Re-run `install` after changing those keys.

- **macOS** — two per-user launchd agents (launchd cannot run two commands
  from one), `~/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet-fast.plist`
  and `com.novotnyllc.roundhouse.fleet-full.plist`, each a `StartInterval`
  job running
  `/bin/zsh -lc 'exec "$HOME/.local/bin/roundhouse" fleet-run --fast|--full'`
  and logging to `~/Library/Logs/roundhouse-fleet-fast.log` /
  `roundhouse-fleet-full.log`. Over SSH with nobody logged in at the console
  there is no GUI domain to load into; the agents load at the next login.
- **Linux** — a systemd **user** timer pair, each timer with its oneshot
  service, `roundhouse-fleet-fast.timer` and `roundhouse-fleet-full.timer`, on
  `OnBootSec`/`OnUnitActiveSec` monotonic intervals, so a laptop that was
  asleep resumes its cadence at wake rather than storming. The user manager
  must linger (`loginctl enable-linger`) for the timers to outlive a login
  session — `install` checks that first, exits 75 and names the fix, and
  writes nothing — and WSL needs systemd enabled (an unreachable user manager
  is its own diagnostic). A job is its timer AND its service: either one
  missing is a missing job, and `status` compares both.
- **Windows** — a **per-user** scheduled task. Where the machine has a
  configured WSL sibling, register it there and drive the native side through
  the interop lane rather than registering a second native entry.
  `fleet-schedule` does not manage native Windows.

```bash
roundhouse fleet-run --fast    # the fast slot
roundhouse fleet-run --full    # the heavy slot
```

The scheduler entry must preserve that Node requirement: a POSIX entry uses
`$SHELL -lc 'roundhouse fleet-run --fast|--full'` (or an equivalent explicit
tool PATH), while a Windows task invokes `codex-plugin-hooks.ps1`, which uses
PATH Node first, then the Codex-bundled runtime (effectively guaranteed because
the helper runs only where Codex exists), then Claude's bundled `node.exe` as a
last fallback, otherwise exiting 69 with the documented recovery guidance.

The run is non-interactive by construction: every jj, git and ssh invocation
it makes is closed to editors, pagers and credential prompts, so a scheduled
run can never block on a human at a machine nobody is sitting at. A local
run-lock enforces one runner at a time per host: a second run finds the lock
held and exits 0 without acting, which is the ordinary overlap and not a
failure. The holder is checked before the age: the lock records the holder's
pid, process start time, command and a random nonce, and a lock whose holder is
dead — the pid is gone, or now belongs to a process with a different start time
or command — is taken over (renamed aside, verified by nonce, recreated) and
raises a `lock-takeover` alert. A holder that is provably the recorded run
(pid, start time and command all match) but has held the lock past the pass
ceiling (2 h) is a hung pass, not a slow one: the next run stops it and every
process under it (TERM, then KILL, then confirms it is gone), takes the lock
over the same way, and raises a `lock-takeover` alert naming the stopped run.
A `manual` lock is never stopped. Every package- and agent-manager query a
pass makes is bounded (about a minute for a listing, longer only for an
install), so a manager that hangs makes only its own inventory unknown for
that pass and raises an `inventory-timeout` alert. A run releases the lock only while it still
carries that run's nonce. Exit 75 is the STALE-lock refusal — a lock past two
full cadences whose holder cannot be shown dead, or one
whose `meta.json` is missing so its age cannot be read — and it names the
recovery rather than forcing. `roundhouse fleet-unlock` releases a lock by hand, and refuses while a
verified-live run holds it unless given `--force`; `roundhouse fleet-lock` marks
its lock `manual`, which is never judged dead (the age rule governs it), and also
exits 75 when the lock is already held. Unattended runs skip protected/privileged actions — those
stay interactive by design. Failures land in the store's own alert and journal
records and surface in `roundhouse fleet-pending` and `roundhouse fleet-doctor`.

## Protected package actions

When readiness advertises an active protected action-context pair, select only
the repository-defined semantic action already present there:
`apt.update-metadata.v1`, `apt.install-package-version.v1`,
`apt.upgrade-package.v1`, `apt.autoremove.v1`,
`macos.install-signed-pkg.v1`, `macos.apply-system-setting.v1`,
`winget.inventory-machine.v1`, `winget.install-machine-package.v1`, or
`winget.upgrade-machine-package.v1`. WinGet is required for V1 Windows
machine-package work; it is also the only lane for a machine-scope Node.js
(`OpenJS.NodeJS`) upgrade, within the channel its policy token enrolls. macOS actions are owner-enrolled and default-disabled;
use them only when readiness advertises the exact active action. Never use root
Homebrew, arbitrary `sudo`, arbitrary installer scripts, or arbitrary plist
paths. `sealed-cask-payload-v1` is the sole scripted-package exception: it
authorizes one exact owner-enrolled Apple-signed package and still invokes only
the fixed broker installer action. During a normal `homebrew-cask:*` apply,
Homebrew remains the ordinary-user transaction owner and writes its own
Caskroom metadata. A human-enrolled `macos-cask-app` record may bind the cask
token to one existing `/Applications/<Name>.app`; the typed broker prepares
only that non-symlink tree for the enrolled UID, then Homebrew replaces it as
the ordinary user. For package casks, the root bridge ignores Homebrew's
submitted package path after matching its bytes and executes the protected
artifact instead. It does not authorize unenrolled app targets, package
receipt-pattern deletion, installer choices, or any other Homebrew sudo shape; those return
`unsupported_homebrew_cask_privilege_boundary`. Never add argv, executable,
source, installer, dependency, environment, shell, or elevation controls to a
protected request; WinGet source dependency selection remains delegated to the
attested provider.

Run `"$CLI" privilege-status HOST SNAPSHOT`, seal the semantic action, use
`verify-privilege-plan` immediately before `submit-privilege-plan`, and use
`lookup-privilege-result PLAN INDEX OUTPUT` for recovery without resubmission.
The shared Codex/Claude lifecycle vocabulary is
`prepare-privilege-identity`, `prepare-privilege-enrollment`,
`preview-privilege-upgrade`, and `preview-privilege-revocation`. Preserve
`needs_enrollment`, `drifted`, `transport_unavailable`,
`unsupported_context`, `unsupported_security_boundary`, `partial`, and
`stale`; perform no fallback. Never ask for or relay a sudo or Administrator password.
Human enrollment, upgrade, activation, and revocation stop at the local
password/UAC boundary; on macOS that is owner-local interactive elevation, not
an SSH fallback.
After a Roundhouse plugin install or update on POSIX, run
`roundhouse launcher-install ~/.local/bin/roundhouse` so the maintained
launcher is refreshed from the installed plugin and selects the highest
version across both harness caches. It resolves the local target by the
configured hostname/user; when more than one local entry matches, pass its
machine id as the second argument instead of relying on inventory order.
