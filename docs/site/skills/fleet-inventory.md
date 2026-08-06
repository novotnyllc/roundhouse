# Fleet inventory

Fleet Inventory takes a read-only snapshot of what's actually installed
and configured across your macOS, Linux, WSL, and Windows machines —
packages, agent runtimes, allowlisted Claude/Codex settings, plugins,
standalone skills and their provenance, auth-file or native session
status, projects, startup tasks, chezmoi state — and compares it across
hosts. It's the evidence layer everything else in the plugin builds on:
`fleet-readiness` synthesizes a verdict from it, `fleet-agents` and
`fleet-update` plan mutations against it.

## When to use it

- "What's installed on my machines?" as a standing audit.
- "Any drift between my Mac and my Linux box?"
- You need a JSONL snapshot for another agent or a script to consume,
  rather than a human-readable report.
- Checking install-time inference, SHA-256 comparisons, or startup-task
  state before deciding whether something needs fixing.
- Reviewing protected/root-broker enrollment state without touching it.

## How it works

Every run starts with `roundhouse validate-config`, then resolves the
requested host names or groups from `config.json` and collects only the
sections actually needed — default is all configured hosts with a human
report. Preserve the JSONL snapshot instead when another agent will
consume it downstream. In a human report, machine entries sharing a
`physical_host` value are grouped under one hardware heading rather than
reported as unrelated machines.

For `local` and `ssh` targets, collection runs as `roundhouse collect
--target HOST --section SECTION`. Exit code 2 means a usable *partial*
snapshot — its errors are shown alongside the valid records rather than
discarding the whole thing. SSH collection always uses the exact installed
executor on the target and returns `executor_update_required` when its
version or hashes are stale; inventory itself never updates the plugin
implicitly, that stays a `fleet-agents` mutation. Connection and keepalive
waits are bounded, and any *mutating* skill built on top of this data
additionally requires the target's configured native hostname/user to
match before it acts. Use `roundhouse validate`, `roundhouse render`, and
`roundhouse compare` against the collected records rather than parsing the
raw JSONL ad hoc.

**Inventory is private but not cosmetically redacted** — it shows the
operational values you asked for. It never includes credential contents,
tokens, environment values, or authenticated Git URL credentials.
Credential *records* may include path, owner, mode, size, mtime, SHA-256,
strategy, and native health — never the secret itself. A Codex plugin
cache directory's birth time is reported only as `inferred_installed_at`,
never presented as an authoritative install date.

For configured JSON/TOML agent settings, inventory shows the allowlisted
observed and desired values plus an `in_sync` flag — never the surrounding
config file dumped wholesale. Claude CLI and Desktop Code are treated as
sharing supported settings but keeping separate login state. Codex Desktop
Remote enablement has no documented persistent config key or inventory
record, so the invoking agent checks and reports it manually rather than
inferring it.

For `codex-remote-control` targets, Codex follows the shared dispatch
contract documented in the plugin's `codex-remote-control.md` reference,
including the `railyard/model-routing/v1` routing step before any task
creation. Claude reports that transport as unsupported rather than
substituting another lane. Windows is never routed through WSL unless the
config explicitly names a different transport for that host.

### Protected broker readiness

For an enrolled or proposed protected target, `roundhouse privilege-status
HOST SNAPSHOT` reports transport, node identity, broker, adapter
mechanism, protected machine-package, and bounded profile readiness as
separate fields. The shared vocabulary both Codex and Claude use here is
`prepare-privilege-identity`, `prepare-privilege-enrollment`,
`verify-privilege-plan`, `submit-privilege-plan`,
`lookup-privilege-result`, `preview-privilege-upgrade`, and
`preview-privilege-revocation` — this skill invokes none of the mutating
ones, only the status read.

For macOS, inventory reports root-broker enrollment and its
default-disabled/active state, and only surfaces the
`macos.install-signed-pkg.v1` / `macos.apply-system-setting.v1` actions
when readiness actually advertises them. Root Homebrew, arbitrary `sudo`,
installer scripts, and arbitrary plist paths are unsupported outright;
owner-local interactive elevation is a separate thing from SSH reach.

States like `needs_enrollment`, `drifted`, `transport_unavailable`,
`unsupported_context`, `unsupported_security_boundary`, `partial`, and
`stale` are preserved exactly as reported, never smoothed over. The public
audit identity — fleet CA fingerprint and generation, originating node ID,
node-key fingerprint, certificate serial and validity, pinned host-key
fingerprint — is shown; private-key material never is. Enrollment,
upgrade, policy activation, and revocation all stop at the local human
password/UAC boundary; nothing here asks for or relays a sudo or
Administrator password, and no WSL, shell, Codex-task, or interactive SSH
fallback substitutes for the configured protected adapter.

Every run concludes with observed drift, unavailable evidence, and exact
next actions — never a mutation.

## Boundaries

- Read-only, always — nothing here writes to a target. Mutations belong to
  the skill that owns the surface: [`fleet-update`](fleet-update.md) for
  packages, [`fleet-agents`](fleet-agents.md) for runtimes/plugins/skills,
  [`fleet-hosts`](fleet-hosts.md) for host lifecycle, `fleet-auth` for
  credentials.
- Doesn't synthesize a ready/not-ready verdict — that's
  [`fleet-readiness`](fleet-readiness.md), which consumes this skill's
  evidence rather than duplicating its collection logic.
- Doesn't update the target's plugin executor even when it detects one is
  stale — it reports `executor_update_required` and stops.

## Example session

> **You:** "Give me a JSONL snapshot of plugins and settings on every
> development-group machine."
>
> **What happens:** the agent validates the config, resolves the
> `development` group to its member hosts, and runs `roundhouse collect
> --target HOST --section agents` (plus `settings` coverage) against each
> one over its configured transport. It preserves the raw JSONL rather
> than rendering a human report, groups any `physical_host`-paired entries
> in its summary, and calls out any host that returned a partial (exit 2)
> snapshot or an `executor_update_required` flag instead of silently
> treating it as clean.
