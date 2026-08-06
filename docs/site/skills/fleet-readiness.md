# Fleet readiness

Fleet Readiness answers one question with evidence instead of a hunch: is
this machine — or this whole fleet — ready to receive agent work right
now? It doesn't own inventory, reconciliation, or credential mechanics
itself; it determines which hosts and capabilities a request needs, routes
to the narrow skill that owns each answer, and synthesizes every host as
`ready`, `not ready`, or `unknown`, with the evidence and the next action
attached.

## When to use it

- Before placing a task on a remote machine — "is my Linux box ready to
  take this?"
- "Are my machines ready for agent work?" as a standing health check.
- A dispatcher (Railyard's orchestrator, or you) needs a go/no-go table
  across several hosts before committing to a plan.
- Fleet capabilities look like they might be missing or inconsistent and
  you want the authoritative read before acting on a hunch.

## How it works

Readiness never re-implements the mechanics behind the answer — it routes:

| Question | Routed to |
| --- | --- |
| Broad or cross-domain evidence | [`fleet-inventory`](fleet-inventory.md) |
| Repository identity, checkout state, Codex saved-project readiness | [`fleet-projects`](fleet-projects.md) |
| Runtimes, settings, plugins, skills, provenance, duplicate providers, logical capabilities | [`fleet-agents`](fleet-agents.md) |
| Credential artifacts, sessions, auth repair | `fleet-auth` |

Each routed skill keeps its own inventory, approval, mutation, and
post-verification contract — Fleet Readiness never duplicates those
commands or treats a raw SSH command as if it were a verified remote
agent. Launching a destination-native harness worker over the fleet's
configured SSH transport (a `claude -p` child with its own session
identity in a fleet-verified checkout, under Railyard's placement
contract) *is* the supported dispatch lane — it's agent dispatch, not raw
command execution.

**Desired-state sync's doctor checks live in `fleet-agents`, not here.**
This skill (and `railyard:doctor`) reads that list as authoritative and
never paraphrases it — see
[`fleet-agents`'s doctor check contract](fleet-agents.md#desired-state-sync)
for the actual checks.

**Hardware pairing.** Machine entries that share a `physical_host` value
are environments on one piece of hardware (a Windows install and its WSL
sibling, for example). If the hardware is unreachable, every entry on it
is — Readiness reports them together rather than as independent failures.

**The WSL interop lane is the preferred maintenance path** for a
native-Windows machine that declares `wsl_interop_via`: SSH to the WSL
side, `cd /mnt/c`, launch Windows-native CLIs through full-path `cmd.exe
/c` (or `powershell.exe` only when PowerShell itself is required). Those
processes run natively as the Windows user, so their evidence *is*
native-Windows evidence — pure WSL-side execution never proves that, but
interop-launched processes aren't WSL-side execution. A Windows logoff
usually stops its WSL VM too, so a logged-off host just presents as plain
SSH-unreachable, not an interop-specific error. The visible Codex task
remains the lane for work needing the Desktop app surface, or when WSL is
absent or unreachable — and it only covers ordinary native work. Protected
or logged-off Windows work requires fresh `privilege_broker` readiness
from the enrolled `windows-sftp` route; nothing else substitutes for it.
That same route is also the harness-neutral way to *deliver* dispatch
prerequisites (marketplace desired-records, profile bundles) to a Windows
target — any harness can stage them over SSH/SFTP, with broker pickup
inside a minute; only the in-session cache install and hook-trust
convergence still need the Codex task surface.

**macOS root-broker state** is reported separately, and only when
readiness advertises the owner-enrolled, default-disabled
`macos.install-signed-pkg.v1` or `macos.apply-system-setting.v1` actions.
SSH access is never treated as elevation — root Homebrew, arbitrary
`sudo`, installer scripts, and arbitrary plist paths are all unsupported
regardless of SSH reachability.

Readiness reports the exact configured nodes it checked, the requirements,
the evidence, what changed, what's unknown, and any restart or
saved-project action still required. When a request implies fleet-wide
parity, it verifies every configured node — not a sample.

## Boundaries

- Never renames the task it's given. When something upstream (like a
  task-orchestrator) invokes this skill, it keeps the parent-assigned
  title in its report.
- Never mutates anything itself — every fix runs through the owning
  routed skill, with that skill's own approval and verification.
- Doesn't do host onboarding or removal — that's
  [`fleet-hosts`](fleet-hosts.md), which calls this skill to prove
  readiness once a host is added.
- Doesn't decide package or agent-tooling drift on its own — it reports
  what the routed skills found.

## Example session

> **You:** "Is the Linux box ready to take a delivery task?"
>
> **What happens:** Fleet Readiness checks the Linux entry's SSH
> reachability and platform identity, pulls agent-tooling parity from
> `fleet-agents`, checkout state and any Codex saved-project registration
> from `fleet-projects`, and credential health from `fleet-auth`. It
> reports `ready` with the evidence behind it, or `not ready` with the
> exact gap — say, a stale plugin pin or a dirty checkout — and the next
> action to close it, rather than a bare pass/fail.
