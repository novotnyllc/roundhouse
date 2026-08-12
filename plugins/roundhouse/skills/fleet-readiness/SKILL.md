---
name: fleet-readiness
description: Assess and reconcile project, agent, plugin, skill, authentication, and host readiness across configured machines. Use before cross-host task placement, when fleet capabilities may be missing or inconsistent, or when a user asks whether machines are ready for work.
---

# Fleet Readiness

Own the readiness question, not the underlying reconciliation mechanics.
Determine the required hosts and capabilities, invoke the narrow Machine
Utilities skills below, and synthesize each host as `ready`, `not ready`, or
`unknown` with evidence and the next action. Never rename the task. When Task
Orchestrator invokes this skill, retain the parent-assigned title.

## Route readiness

- Use `roundhouse:fleet-inventory` for broad or cross-domain evidence.
- Use `roundhouse:fleet-projects` for repository identity, checkout
  state, baselines, and Codex saved-project readiness.
- Use `roundhouse:fleet-agents` for runtimes, settings, plugins, skills,
  provenance, duplicate providers, and logical capabilities.
- Use `roundhouse:fleet-auth` for credential artifacts, sessions, and
  authentication repair.

Run `roundhouse fleet-readiness [HOST]...` first. It emits one table row per
host and prerequisite for `jj` plus `yq`, `roundhouse` on PATH, SSH-name
resolvability, and a verified-private remote. A nonzero exit means at least one
row is not ready; it is a preflight, not a repair. It deliberately does not
check chezmoi: chezmoi is an optional personal integration, not a fleet
prerequisite. After the preflight, desired-state readiness is
`roundhouse fleet-doctor`, whose contract lives in `roundhouse:fleet-agents`
and is authoritative there: consume its rows, and never duplicate or
paraphrase them here. Open alerts from any host are `roundhouse fleet-pending`.

Let each routed skill retain its inventory, approval, mutation, and
post-verification contract. Do not duplicate its commands or treat raw SSH
command execution as a remote agent. Launching a destination-native harness
worker over the configured SSH transport — for example a Claude Code
`claude -p` child with its own session identity in a fleet-verified checkout,
under `railyard:orchestrate`'s placement contract — is agent
dispatch, not raw command execution, and is the supported Claude Code
placement lane. Machine entries sharing a `physical_host` value are
environments on one piece of hardware: if the hardware is unreachable, all
its entries are; report them together. For a native-Windows machine that declares a
`wsl_interop_via` sibling in the config, the **WSL interop lane** is the
preferred maintenance path: SSH to the WSL side, `cd /mnt/c`, and launch Windows-native
CLIs through the full-path `cmd.exe /c` (full-path `powershell.exe` only
when PowerShell itself is required) — the processes execute
natively as the Windows user, so their evidence IS native-Windows evidence.
(Pure WSL-side execution still never proves native Windows; interop-launched
processes are not WSL-side execution.) A Windows logoff usually stops the
WSL VM, so a logged-off host presents as plain SSH-unreachable — not an
interop-specific error. The visible Codex task remains the
lane for work needing the Desktop app surface, or when WSL is absent or
unreachable — and it covers only ordinary native Windows work. Protected or logged-off Windows work requires fresh
`privilege_broker` readiness from the enrolled `windows-sftp` route; never
substitute the visible task, WSL, or another transport. That `windows-sftp`
route is also the harness-neutral way to deliver dispatch prerequisites —
marketplace desired-records and profile bundles — to a Windows target: any
harness can stage them over SSH/SFTP (broker pickup within one minute), and
only the in-session cache install and hook-trust convergence still needs the
Codex task surface.

For macOS, report a separate root-broker state only when readiness advertises
the owner-enrolled, default-disabled `macos.install-signed-pkg.v1` or
`macos.apply-system-setting.v1` action. SSH is not elevation; root Homebrew,
arbitrary `sudo`, installer scripts, and arbitrary plist paths are unsupported.

Report the exact configured nodes checked, requirements, evidence, changes,
unknowns, and any restart or saved-project action still required. When the
request requires fleet-wide parity, verify every configured node.
