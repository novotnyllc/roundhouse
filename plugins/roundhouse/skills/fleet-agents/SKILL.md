---
name: fleet-agents
description: Inventory and reconcile Codex and Claude runtimes, safe settings, plugins, standalone skills, skills-cli provenance, JSM-managed skills, and logical capabilities across machines. Use when agent tooling, Remote Control defaults, models, updates, or skills are missing, duplicated, stale, or inconsistent.
---

# Fleet Agents

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md` and
`CLI="$SKILL_DIR/../../scripts/machine-utilities"`; the shell working directory
is not the skill directory. Collect `--section agents --section auth` when
evaluating capability readiness; provider-only inventory may collect just
`agents`. Windows tasks must pass `-AllowAuthVerify` for the combined readiness
check. Compare
runtime versions, plugin name/version/manager, standalone skill hashes and
origins, skills-cli lock metadata, JSM provenance, and configured logical
capabilities. Read `"$SKILL_DIR/../../references/agent-settings-and-auth.md"`
before auditing agent settings, runtime installation, model policy, or Remote
Control. Treat the same capability delivered as a plugin and a standalone
skill as equivalent only when the config says so; report duplicate providers.

Use manager-native ownership:

- Codex plugins: use Codex marketplace/plugin commands.
- Claude plugins: use Claude marketplace/plugin commands.
- skills-cli installs: use `npx skills check` or `npx skills update` and retain
  `.agents/.skill-lock.json` provenance.
- JSM installs: use JSM for inventory/update when its metadata proves ownership.
- local source skills: update their owning repository; do not overwrite them
  with a package manager.

## Routine marketplace refresh

An explicit request to update or refresh one named marketplace plugin is
mutation authorization for that marketplace's already-installed plugins on the
requested hosts and applicable harnesses. A marketplace upgrade and its plugin
updates are one operation: after refreshing the catalog, update every installed
plugin owned by that marketplace, not only the plugin that prompted the refresh.
Do not install other catalog entries that were not already installed. Do not require a
fleet-wide inventory/readiness matrix or a sealed-plan round trip for this
routine path. Resolve every target
from `ROUNDHOUSE_CONFIG`, falling back to
`${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json`, and use each
target's configured `local`, `ssh`, or `codex-remote-control` transport. Never
guess an SSH alias or substitute WSL for native Windows.

Before changing a target, capture a bounded `agents` inventory and freeze a
de-duplicated set of every installed plugin owned by the marketplace. Treat the
two harnesses independently and refresh each available, applicable runtime.
For local execution set `TARGET_CLI="$CLI"` and verify the loaded executor. For
SSH, use the configured alias and target login shell (`$SHELL -lc`), resolve the
target's installed Machine Utilities version from its active Codex plugin
record, and set `TARGET_CLI` to that target cache's
`machine-utilities/VERSION/scripts/machine-utilities`; never send or interpolate
the controller's `SKILL_DIR` or `CLI`. Require `"$TARGET_CLI" verify-executor`
to pass before using it. Run only these target-native command sequences, in
order, substituting the authorized marketplace and each installed plugin ID:

```text
codex plugin list --json
codex plugin marketplace upgrade MARKETPLACE --json
"$TARGET_CLI" update-codex-plugin EACH_INSTALLED_PLUGIN@MARKETPLACE

claude plugin list --json
claude plugin marketplace update MARKETPLACE
claude plugin update EACH_INSTALLED_PLUGIN@MARKETPLACE --scope user
```

Require every frozen ID to end in the exact `@MARKETPLACE` suffix and attempt
every ID even if another update fails. Do not add IDs that appear only after the
catalog refresh. Update `roundhouse@novotnyllc` last when present, then
recapture inventory and re-resolve its installed executor. The Codex wrapper
snapshots only each plugin's already trusted or modified hook
keys, runs the exact idempotent `codex plugin add PLUGIN@MARKETPLACE --json`,
refreshes trust for those same stable keys, and leaves new or previously
untrusted hooks untrusted. Do not synchronize unrelated marketplaces, runtimes,
settings, skills, provenance, or configuration. Manager output is progress
evidence, not post-state. Recapture the bounded `agents` inventory after each
harness attempt. Require every frozen marketplace plugin record to remain
installed with its enabled state and Claude scope preserved; require every
outside-marketplace record to be unchanged. Report before/after versions per
plugin. A failure in one plugin or harness does not erase other evidence or stop
the remaining marketplace plugins from being attempted.

The only pre-helper fallback is a separately approved self-update of
`roundhouse@novotnyllc` from an integrity-verified release that lacks
`update-codex-plugin`. After upgrading the `novotnyllc` marketplace, run exactly
`codex plugin add roundhouse@novotnyllc --json`, recapture inventory,
reload the new target-native plugin, and require its version `0.1.0` executor
and integrity verification before any other mutation. Never use that raw-add
fallback for another plugin or once the helper command is available.

For a configured `codex-remote-control` target, follow the routine-refresh
path in `"$SKILL_DIR/../../references/codex-remote-control.md"`, using a visible
native task and native PowerShell. Before its task creation and every chunk or
other work-starting follow-up, invoke the reference's exact shared
`yardmaster/model-routing/v1` runtime-skill contract; no local model
policy is permitted. Lazy-discover the task-control app tools before declaring
them unavailable.

Use the sealed-plan reconciliation path below instead when the request includes
broad drift, runtime or settings changes, provenance repair, provider
conversion, ambiguous plugin/marketplace/host scope, or any mutation beyond
the explicit named-plugin refresh.

Default to a plan listing exact host, harness, manager, source, current version
or hash, and desired action. Seal it with
`"$CLI" seal-plan DRAFT SNAPSHOT PLAN`. Before apply, require exact scope,
recapture inventory, and require
`"$CLI" verify-preconditions PLAN CURRENT-SNAPSHOT` to succeed. Obtain
separate user approval and execute only the exact sealed argv. Do not silently
convert a standalone skill into a plugin or vice versa. For a local target use
`"$CLI" apply-plan PLAN PLAN-ID OUTPUT`; for SSH use
`"$CLI" apply-ssh-plan PLAN PLAN-ID OUTPUT`; Windows uses the native worker
contract in the remote-control reference. Apply recaptures trusted preflight
itself. Preserve its authoritative partial output when an operation or
postcondition fails.
The executor supports exact `codex update` and `claude update` runtime updates,
plus updates for skills-cli, JSM, and Claude plugins.
Codex replacement uses the native idempotent `codex plugin add
PLUGIN@MARKETPLACE --json` operation through the same hook-preserving wrapper.
An already-current runtime is a successful
no-op after it remains present in post-inventory. For a missing runtime, use the
official installer interactively or delegate a manager-owned install to
`fleet-update`; downloaded installer pipelines, removals, and provider
conversion are unsupported by sealed plans.

Configured `agent_artifacts` may declare an allowlisted `settings` object for a
JSON or TOML config file. Inventory emits one `agent_setting` record per key,
including observed value, desired value, presence, and `in_sync`; it never emits
unlisted config fields. Reconcile the owning file through `fleet-chezmoi` where
possible. Do not write Claude Desktop internal state or undocumented Codex
Desktop preferences. Claude's supported Remote Control default lives in the
shared Code settings file; the invoking agent must check Codex Desktop host
enablement manually.

Codex hook approval is target-local state, not a portable settings allowlist.
After the user explicitly approves the current hooks for one exact plugin and
host scope, local runs
`"$CLI" approve-codex-plugin-hooks PLUGIN@MARKETPLACE`; SSH runs the same command
through the previously resolved and verified `"$TARGET_CLI"` in the target login
shell. Native Windows uses the integrity-gated `-ApproveCodexPluginHooks` path
in `"$SKILL_DIR/../../references/codex-remote-control.md"`. Each path discovers
hooks with a fresh Codex app server, writes only matching `trusted_hash` leaves,
preserves disabled and unrelated hook state, and verifies every current matching
hook is trusted. Never copy the complete `[hooks.state]` table between hosts.
Later updates inherit approval only for the same stable hook keys; new hooks
require a new explicit approval.

Use local/SSH execution where configured. SSH uses bounded connection and
keepalive timeouts and must match the configured native hostname/user before
mutation. Run every SSH operation through the target user's configured login
shell (`$SHELL -lc`) so user-level paths such as `$HOME/.local/bin` are
available. Never use raw non-login SSH command execution or infer that tooling
is absent from its restricted `PATH`. For Windows Codex tasks read and follow
`"$SKILL_DIR/../../references/codex-remote-control.md"`; its explicit routine
named-plugin path may run the native Claude CLI in the visible native PowerShell
task only after the shared routing dispatch is admitted and claimed. Outside
that narrow path, Claude reports the transport control surface as unsupported
rather than using WSL. Re-inventory after changes and report
unresolved provenance as unknown, not guessed.

## Protected profile actions

Use `"$CLI" privilege-status HOST SNAPSHOT` before proposing protected profile
work. The only agent-content action is the readiness-advertised
`profile.apply-managed-bundle.v1` or read-only
`profile.inventory-managed-state.v1` in `windows-user-s4u-v1`. Build identical
Codex/Claude bytes with `"$CLI" profile-bundle SPEC SOURCE-ROOT OUTPUT`; include
only bounded config scalars, standalone-skill files, agent definitions, and
local marketplace desired records already authorized by the protected entry
map. Never copy credentials, secret-backed templates, installed plugin caches,
agent internal state, startup tasks, or arbitrary paths. A staged plugin
desired record is `manager_activation_pending` until the next ordinary user
session lets its manager activate it; logged-off S4U success is not plugin
activation evidence.

The shared protected lifecycle vocabulary is `prepare-privilege-identity`,
`prepare-privilege-enrollment`, `verify-privilege-plan`,
`submit-privilege-plan`, `lookup-privilege-result`,
`preview-privilege-upgrade`, and `preview-privilege-revocation`. Preserve every
readiness/result state without fallback, including
`unsupported_security_boundary`, `partial`, and `stale`.
Never ask for or relay a sudo or Administrator password; stop at the local human
password/UAC boundary.
