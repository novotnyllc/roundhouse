# Fleet update

Fleet Update plans and applies OS package updates — Homebrew, APT, and
winget — across the fleet through a plan-seal-verify-apply pipeline, so a
"patch everything" request never runs a manager command against stale
information. It can also drive itself unattended on a schedule, folded
into the fleet's single owned scheduler entry.

## When to use it

- "Update my packages" / "patch the fleet."
- "What's outdated on my machines?" as a report, without applying
  anything.
- Reviewing what a scheduled unattended run actually did.
- A specific manager needs attention — Homebrew casks, an APT hold, a
  winget source — on one host or across a group.

## How it works

### The authorization model

An explicit update request — "update my packages," "patch the fleet," or
a scheduled unattended run — **is** the mutation authorization: plan,
seal, verify, and apply happen in one pass without asking again. A request
to inspect, report, or plan stops at the read-only plan; apply permission
is never inferred from it. The sealed pipeline below is safety mechanics
for a request that's already authorized, not an approval gate you have to
clear separately. Unattended runs skip anything requiring interactive
elevation and use exactly this same sealed pipeline — nothing shortcuts it
just because a human isn't watching.

This is mechanical-tier work: a session running a premium model delegates
the actual run to a cheap-model child (the routed mechanical tier) rather
than executing it inline.

### Per-manager mechanics

- **Homebrew** — `brew update` refreshes metadata, then `brew outdated
  --json=v2` builds the plan and `brew upgrade` applies the planned
  formulae/casks. macOS casks run as the ordinary Homebrew owner through
  the packaged bridge hook, so Homebrew keeps Caskroom authority. An
  unprivileged app upgrade — including VS Code, when its destination is
  writable — follows Homebrew normally. A cask that reaches Homebrew's
  hardcoded `sudo` only succeeds when it byte-matches an active, exact
  `sealed-cask-payload-v1` enrollment; every other privileged cask
  artifact fails closed rather than silently prompting for a password.
- **APT** — `apt-get update` then `apt-get --simulate upgrade` for the
  plan. `full-upgrade`, `dist-upgrade`, and `autoremove` are never used
  unless explicitly selected.
- **winget** — planned with `winget upgrade --accept-source-agreements
  --disable-interactivity`; an update request covers the planned packages
  (`--all` for a fleet-wide request).

### The sealed pipeline

Every host, manager, package, current version, candidate version, and
command goes into a plan draft first. Every `package-upgrade` operation
carries the exact observed `candidate_version` — sealing refuses a
candidate that isn't present in the snapshot, and the fresh precondition
check re-verifies it's still there right before apply. The pipeline:

1. `roundhouse seal-plan DRAFT SNAPSHOT PLAN`
2. Before apply: verify live host and platform identity, recapture package
   inventory, and require `roundhouse verify-preconditions PLAN
   CURRENT-SNAPSHOT` to succeed.
3. Execute only the exact argv sealed in the plan —
   `roundhouse apply-plan PLAN PLAN-ID OUTPUT` for a local target,
   `roundhouse apply-ssh-plan PLAN PLAN-ID OUTPUT` over SSH.

Both apply paths recapture trusted preflight themselves and enforce the
same executor, identity, manager-command, fresh-precondition, and
semantic post-state checks. If an operation or its postcondition fails,
the authoritative partial result is preserved rather than discarded, as
long as post-inventory is still available. SSH uses bounded
connection/keepalive timeouts and verifies the configured native
hostname/user before touching anything. Apply permission is never
inferred from a request to merely inspect or plan.

### Windows and WSL interop

Native managers run directly on local/SSH hosts. For Windows, the default
lane is WSL interop whenever the machine declares `wsl_interop_via`: SSH
to the sibling, `cd /mnt/c`, and run winget and the other native managers
through full-path `cmd.exe /c` — native processes, regardless of which
harness is driving. Only when WSL is absent or unreachable, or the work
needs the Desktop app surface, does Codex fall back to the
`codex-remote-control` reference path (with its own model-routing dispatch
before task creation); Claude reports that fallback as unsupported rather
than substituting WSL. Managers are never run WSL-side in place of native
Windows. Native approval prompts are preserved, a failing host stops that
host's run without aborting others, and package inventory is recaptured
afterward.

### Unattended schedule

Auto-updating on a schedule uses the OS scheduler calling the CLI — no
new daemon, database, or engine. **There's exactly one owned scheduler
entry per host, and desired-state sync owns it**: this update step is
absorbed into sync's single entry, so two local runners never race one
plugin cache. Package updates aren't a separate job — the full cadence
does them on the same convergence that applies everything else.
`railyard:setup` installs the entry on request and absorbs an existing
autoupdate entry into it.

The entry drives two cadences from one owned slot:
`roundhouse fleet-run --fast` every 20 minutes ± 5, and
`roundhouse fleet-run --full` every 12 hours ± 90 minutes, which is the
pass that refreshes marketplaces and updates unpinned packages. On macOS
it's a per-user launchd agent
(`~/Library/LaunchAgents/com.novotnyllc.roundhouse.fleet.plist`); Linux
uses a systemd user timer pair with `Persistent=true`; Windows a per-user
scheduled task. Both intervals are jittered from the host **name**, and
the interval keys live in the store's policy block rather than on the
machine being governed — see [running it](../operating.md#the-scheduler).

A local run-lock enforces one runner at a time per host: a second run
finds the lock held and exits 0 without acting, which is the ordinary
overlap rather than a failure. Exit 75 is the *stale*-lock refusal — a
lock past two full cadences, or one whose metadata can't be read — and it
names the recovery instead of forcing. Failures land in the store's own
alert and journal records, surface in `roundhouse fleet-pending`, and are
reported at the next `railyard:doctor` run.

### Protected package actions

When readiness advertises an active protected action-context pair, only
the repository-defined semantic action already present there is used —
`apt.update-metadata.v1`, `apt.install-package-version.v1`,
`apt.upgrade-package.v1`, `apt.autoremove.v1`,
`macos.install-signed-pkg.v1`, `macos.apply-system-setting.v1`,
`winget.inventory-machine.v1`, `winget.install-machine-package.v1`, or
`winget.upgrade-machine-package.v1`. macOS actions are owner-enrolled and
default-disabled; they're only used when readiness advertises the exact
active action. Root Homebrew, arbitrary `sudo`, arbitrary installer
scripts, and arbitrary plist paths are never used — `sealed-cask-payload-v1`
is the sole scripted-package exception, and even it only authorizes one
exact owner-enrolled Apple-signed package through the fixed broker
installer action, never an unenrolled app target or arbitrary Homebrew
sudo shape.

The pipeline here is `roundhouse privilege-status HOST SNAPSHOT`, then
`verify-privilege-plan` immediately before `submit-privilege-plan`, with
`lookup-privilege-result PLAN INDEX OUTPUT` for recovery without
resubmitting. States like `needs_enrollment`, `drifted`,
`transport_unavailable`, `unsupported_context`,
`unsupported_security_boundary`, `partial`, and `stale` are preserved
exactly, with no fallback path around them. Nothing here ever asks for or
relays a sudo or Administrator password — human enrollment, upgrade,
activation, and revocation all stop at the local password/UAC boundary
(on macOS, that's owner-local interactive elevation, never an SSH
fallback).

## Scope

- Plugin, skill, and agent-runtime updates belong to
  [`fleet-agents`](fleet-agents.md).
- Project checkout work belongs to [`fleet-projects`](fleet-projects.md).
- Cleanup and autoremove remain separate, explicit actions alongside an
  ordinary update request.
- Installer scripts, arbitrary `sudo`, and unenrolled privileged paths stay
  outside the update surface. The protected-action list above is exhaustive
  and defines the enrolled actions this skill can run.

## Example session

> **You:** "Patch the fleet."
>
> **What happens:** the agent inventories the package section on every
> configured host, refreshes each manager's metadata, builds a plan with
> exact current/candidate versions per package, and seals it —
> `seal-plan` then `verify-preconditions` against a freshly recaptured
> snapshot. Because "patch the fleet" is itself the mutation
> authorization, it proceeds straight to `apply-plan` / `apply-ssh-plan`
> without asking again, reports before/after versions per host and
> manager, and stops a given host's run on failure without aborting the
> others.
