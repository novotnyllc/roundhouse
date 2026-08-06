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
switch the session's own model.

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

Auto-updating on a schedule uses the OS scheduler calling the harness — no
new daemon, database, or engine. **There is exactly one owned scheduler
entry per host, and desired-state sync owns it**: the entry below is
absorbed into sync's single entry, which drives marketplace refresh,
package updates, and the sync run together. Two local runners racing one
plugin cache is the failure this prevents. `railyard:setup` installs the
entry on request and migrates an existing autoupdate entry into it; the
shape on macOS is a per-user launchd agent
(`~/Library/LaunchAgents/com.novotnyllc.roundhouse.autoupdate.plist`) whose
program runs:

```bash
claude -p --model sonnet 'Unattended roundhouse maintenance run: refresh the installed marketplaces and update their plugins (fleet-agents routine refresh), then plan and apply pending package updates (fleet-update), then — when desired-state sync is enabled — drive the three-phase sync run (fleet-agents desired-state sync): fetch and open the run, review and record a verdict on every changed item, then converge, journal, and end the run. Unattended: no questions; skip anything requiring interactive elevation; write a summary to ~/.local/state/roundhouse/autoupdate.log and exit.' --output-format text
```

(Linux: a systemd user timer; Windows: a per-user scheduled task running the
same prompt through the installed harness.) The prompt text is fixed and
maintained in lockstep with fleet-agents' sync doctrine. A local run-lock
enforces one runner at a time per host: a second run exits 75 and stops
rather than forcing. Unattended runs use exactly the same sealed pipeline
and skip protected/privileged actions — those stay interactive by design.
Failures land in the log and surface at the next `railyard:doctor` run.

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
