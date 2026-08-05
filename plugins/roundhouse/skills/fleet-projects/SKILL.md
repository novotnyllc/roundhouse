---
name: fleet-projects
description: Inventory and prepare configured Git repositories and Codex saved-project readiness across machines. Use for missing clones, wrong origins, branch or dirty-state drift, development-root discovery, distributed task placement, Codex project registration, or cross-host handoff readiness.
---

# Fleet Projects

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md` and
`CLI="$SKILL_DIR/../../scripts/machine-utilities"`; the shell working directory
is not the skill directory. Collect the `projects` section with `"$CLI"`.
Evaluate configured path, expected source, sanitized origin, HEAD/tree IDs,
branch, dirty count, host groups, and whether Codex exposes the
environment-native checkout as a saved project. Git readiness and Codex
readiness are separate. Ahead/behind values describe only the current local
remote-tracking ref; treat network freshness as unknown until an explicitly
authorized `git fetch` succeeds.

Default to a plan:

- missing checkout: create the configured parent and clone the configured
  source into the exact path;
- wrong origin or non-repository path: stop for user choice;
- clean checkout behind its upstream: allow fetch plus fast-forward-only pull;
- dirty, detached, ahead, or diverged checkout: report it; never reset, stash,
  switch, merge, or discard work automatically.

Before apply, verify live host/platform and the destination parent, then seal
the exact source/path operations with
`"$CLI" seal-plan DRAFT SNAPSHOT PLAN`. Recapture project inventory and require
`"$CLI" verify-preconditions PLAN CURRENT-SNAPSHOT` to succeed. Obtain
separate approval, execute only the sealed argv, and inventory again afterward.
For a local target use `"$CLI" apply-plan PLAN PLAN-ID OUTPUT`; for SSH use
`"$CLI" apply-ssh-plan PLAN PLAN-ID OUTPUT`; native Windows uses the
remote-control worker contract. Apply recaptures trusted preflight itself and
preserves authoritative partial output after a failed operation or
postcondition when post-inventory remains available. SSH uses bounded
connection/keepalive timeouts and verifies the configured native hostname/user.

For Codex readiness, discover saved projects and match both host and native
path. The controller does not need that path locally. If missing, tell the user
to add the exact checkout in Codex Desktop on that host; do not edit Codex
internal databases. Record the discovery result and any real task/correlation
IDs in an owner-controlled mode-0600 metadata file containing `host_id`,
configured project name, `available`/`missing`/`unreachable`, configured
`codex_host`, exact observed native path and expected source, plus opaque
project/task/correlation IDs when available. Then run
`"$CLI" record-codex-readiness SNAPSHOT METADATA OUTPUT` so Director receives
the controller-observed status in canonical JSONL. Direct Windows task creation follows
`"$SKILL_DIR/../../references/codex-remote-control.md"`, including its exact
shared `yardmaster/model-routing/v1` dispatch before task creation or a
work-starting follow-up, and never WSL.
Cross-host handoff requires matching saved-project repository identity at both
ends; creating a remote task directly only requires the destination saved
project.

Protected broker readiness is independent of project and Codex saved-project
readiness. Use `"$CLI" privilege-status HOST SNAPSHOT` and report the public
node/CA/certificate/host-key identity, transport, broker, machine-package, and
profile readiness without treating a visible Codex task as a protected
fallback. The shared Codex/Claude vocabulary is
`prepare-privilege-identity`, `prepare-privilege-enrollment`,
`verify-privilege-plan`, `submit-privilege-plan`,
`lookup-privilege-result`, `preview-privilege-upgrade`, and
`preview-privilege-revocation`. Project source, Git credentials, working trees,
and installed plugin caches are never profile payloads. Preserve
`needs_enrollment`, `drifted`, `transport_unavailable`,
`unsupported_context`, `unsupported_security_boundary`, `partial`, and
`stale` without fallback. Never ask for or relay a sudo or Administrator password;
stop lifecycle changes at the local human
password/UAC boundary.

Use each project's own Git repository and exact commit as the authoritative
handoff substrate for project work. A separately configured private
coordination repository may hold structured pointers, ownership, status, and
evidence for machine-wide or cross-repository handoffs. One coordination
repository can cover the fleet; it must not copy project source, replace the
project repository, or depend on an unrelated utility checkout. Treat it like
any other configured project: clone it into each host's `dev_root` and register
it as a saved Codex project only where coordination tasks will run. When
`handoff_project` is configured, resolve that project through its configured
source and path; never assume a repository name or maintainer-local checkout.

If a handoff needs a coordination repository and none is configured, first
look for an existing configured project or user-supplied checkout and verify
its Git remote. If it is elsewhere, ask for its project ID or exact path and
offer to persist the corresponding user-owned configuration; do not relocate,
clone, or replace it implicitly. If no repository exists, explain that it will
hold only handoff pointers, ownership, status, and evidence, then propose an
owner, repository name, local path, and private visibility. Require explicit
user approval before `gh repo create`, adding a remote, or any push. Default the
proposal to a private repository in the authenticated user's GitHub account,
but never create or push it merely because a handoff was requested. After
approval, verify the resulting remote is private and record it as an ordinary
project plus `handoff_project`; otherwise report the exact one-time setup still
needed and continue using project repositories where possible.
