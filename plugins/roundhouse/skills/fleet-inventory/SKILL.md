---
name: fleet-inventory
description: Inventory and compare a configured fleet of macOS, Linux, WSL, and Windows machines. Use for packages, agent runtimes, allowlisted Claude/Codex settings, plugins, standalone skills and provenance, auth-file or native session status, projects, startup tasks, chezmoi state, SHA-256 comparisons, install-time inference, or human and JSONL status reports.
---

# Fleet Inventory

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md` and
`CLI="$SKILL_DIR/../../scripts/roundhouse"`; the shell working directory
is not the skill directory. Start with `"$CLI" validate-config`, resolve
requested host names or groups from the config, then collect only the sections
needed. Default to all configured hosts and a human report; preserve the JSONL
snapshot when another agent will consume it.

For `local` and `ssh` targets, run `collect --target HOST --section SECTION`.
Exit 2 means a usable partial snapshot; show its errors instead of discarding
valid records. SSH collection uses the exact installed executor and returns
`executor_update_required` when its version or hashes are stale; inventory
does not update the plugin implicitly. Its connection and keepalive waits are
bounded; mutating skills additionally require the target's configured native
hostname/user to match. Use `validate`, `render`, and `compare` rather than
parsing the records ad hoc.

Inventory is private but not cosmetically redacted: show operational values the
owner requested. Never include credential contents, tokens, environment values,
or authenticated Git URL credentials. Credential records may include path,
owner, mode, size, mtime, SHA-256, strategy, and native health. A Codex plugin
cache directory birth time is only `inferred_installed_at`, never an
authoritative install date.

For configured JSON/TOML agent settings, show the allowlisted observed and
desired values plus `in_sync`; never dump the surrounding config file. Treat
Claude CLI and Desktop Code as sharing supported settings but separate login
state. The invoking agent must check and report Codex Desktop Remote enablement
manually because it has no documented persistent config key or inventory record.

For `codex-remote-control`, Codex must read and follow
`"$SKILL_DIR/../../references/codex-remote-control.md"`, including its exact
shared `yardmaster/model-routing/v1` dispatch before task creation or a
work-starting follow-up. Claude must report that
transport as unsupported. Never route Windows through WSL unless the config
explicitly chooses a different transport.

## Protected broker readiness

For an enrolled or proposed protected target, run
`"$CLI" privilege-status HOST SNAPSHOT` and report transport, node identity,
broker, adapter mechanism, protected machine-package, and bounded profile
readiness separately. The shared protected workflow vocabulary for both Codex
and Claude is `prepare-privilege-identity`, `prepare-privilege-enrollment`,
`verify-privilege-plan`, `submit-privilege-plan`,
`lookup-privilege-result`, `preview-privilege-upgrade`, and
`preview-privilege-revocation`. This inventory skill invokes none of the
mutating commands.

For macOS, report root-broker enrollment, default-disabled/active state, and
only `macos.install-signed-pkg.v1` and `macos.apply-system-setting.v1` when
advertised. Root Homebrew, arbitrary `sudo`, installer scripts, and arbitrary
plist paths are unsupported; owner-local interactive elevation is separate from SSH.

Preserve `needs_enrollment`, `drifted`, `transport_unavailable`,
`unsupported_context`, `unsupported_security_boundary`, `partial`, and
`stale` exactly. Show the public audit identity: fleet CA fingerprint and
generation, originating node ID, node-key fingerprint, certificate serial and
validity, and pinned host-key fingerprint. Never print private-key material.
Never ask for or relay a sudo or Administrator password. Enrollment,
upgrade, policy activation, and revocation stop at their local human
password/UAC boundary; no WSL, shell, Codex-task, or interactive SSH fallback
may substitute for the configured protected adapter.

Conclude with observed drift, unavailable evidence, and exact next actions.
Do not mutate anything from this skill.
