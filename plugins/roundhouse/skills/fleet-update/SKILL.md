---
name: fleet-update
description: Plan and explicitly apply package updates across Homebrew, APT, and winget machines. Use for fleet patching, outdated-package reports, manager-specific updates, package drift, or post-update verification.
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
safety mechanics, not an approval gate. This is mechanical-tier work: a
session running a premium model delegates the run to a cheap-model child
(the routed mechanical tier) rather than executing inline — skills cannot
switch the session's own model. That child's dispatch prompt carries
railyard's dispatch banner instruction (`▸ <model>/<effort> · …` echoed first,
non-blocking; see railyard's harness-model-invocation reference).

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
use `"$CLI" apply-ssh-plan PLAN PLAN-ID OUTPUT`. Both recapture trusted
preflight and enforce the same executor, identity, manager-command,
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
`"$SKILL_DIR/../../references/codex-remote-control.md"` (with its exact
shared `railyard/model-routing/v1` dispatch before task creation); Claude
reports that fallback lane as unsupported. Never run the managers
WSL-side in place of native Windows. Preserve native approval
prompts, stop per host on failure, and recapture package inventory afterward.
Cleanup and autoremove are separate explicit actions.

## Unattended schedule

Auto-updating on a schedule uses the OS scheduler calling the CLI — no new
daemon, database, or engine. **There is exactly one owned scheduler
entry per host**, and it runs `roundhouse fleet-run`. Two local runners racing one
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
On POSIX schedulers, invoke the CLI through the user's login shell or provide a
PATH containing the harnesses and Node.js. The runtime also checks the standard
Homebrew Node locations on macOS. On native Windows, invoke
`scripts/codex-plugin-hooks.ps1 approve PLUGIN@MARKETPLACE`; it first uses
`node.exe` from the task PATH and then resolves the Node runtime beside
`claude.exe` or in Claude Code's standard install directories. If neither
exists it exits 69 with the WSL interop recovery, rather than silently
claiming approval.

The entry drives **two cadences from one owned slot**:

| Cadence | Command | Default | Covers |
| --- | --- | --- | --- |
| Fast | `roundhouse fleet-run --fast` | every 20 min | converge desired state: fetch, review, apply, publish |
| Full | `roundhouse fleet-run --full` | twice a day | the fast pass plus marketplace refresh, unpinned package updates, re-seed, promotion proposals, and `fleet-doctor` |

Both intervals are jittered from the host **name**, so the fleet does not
re-synchronise on the same minute; the interval keys live in the store's
policy block, not on the machine being governed.

`railyard:setup` installs the entry on request. **Absorb, never duplicate**:
if `com.novotnyllc.roundhouse.autoupdate` (or its systemd/Task Scheduler
equivalent) exists, unload and remove it in the same step that installs the
fleet entry. A host carrying both is the exact double-runner this rule exists
to prevent.

The shape per platform, all three running the same two commands:

- **macOS** — one per-user launchd agent,
  `~/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist`, with two
  `StartCalendarInterval`/`StartInterval` slots (or two agents only if the
  scheduler cannot express both in one).
- **Linux** — a systemd **user** timer pair,
  `roundhouse-fleet-fast.timer` and `roundhouse-fleet-full.timer`, with
  `Persistent=true` so a laptop that was asleep catches up once rather than
  storming.
- **Windows** — a **per-user** scheduled task. Where the machine has a
  configured WSL sibling, register it there and drive the native side through
  the interop lane rather than registering a second native entry.

```bash
roundhouse fleet-run --fast    # the fast slot
roundhouse fleet-run --full    # the heavy slot
```

The scheduler entry must preserve that Node requirement: a POSIX entry uses
`$SHELL -lc 'roundhouse fleet-run --fast|--full'` (or an equivalent explicit
tool PATH), while a Windows task must declare its current Node prerequisite.

The run is non-interactive by construction: every jj, git and ssh invocation
it makes is closed to editors, pagers and credential prompts, so a scheduled
run can never block on a human at a machine nobody is sitting at. A local
run-lock enforces one runner at a time per host: a second run finds the lock
held and exits 0 without acting, which is the ordinary overlap and not a
failure. Exit 75 is the STALE-lock refusal — a lock past two full cadences, or
one whose `meta.json` is missing so its age cannot be read — and it names the
recovery rather than forcing. `roundhouse fleet-unlock` releases a lock left by
a killed run; `roundhouse fleet-lock` taken by hand also exits 75 when the lock
is already held. Unattended runs skip protected/privileged actions — those
stay interactive by design. Failures land in the store's own alert and journal
records, surface in `roundhouse fleet-pending`, and are reported at the next
`railyard:doctor` run.

## Protected package actions

When readiness advertises an active protected action-context pair, select only
the repository-defined semantic action already present there:
`apt.update-metadata.v1`, `apt.install-package-version.v1`,
`apt.upgrade-package.v1`, `apt.autoremove.v1`,
`macos.install-signed-pkg.v1`, `macos.apply-system-setting.v1`,
`winget.inventory-machine.v1`, `winget.install-machine-package.v1`, or
`winget.upgrade-machine-package.v1`. WinGet is required for V1 Windows
machine-package work. macOS actions are owner-enrolled and default-disabled;
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
version across both harness caches.
