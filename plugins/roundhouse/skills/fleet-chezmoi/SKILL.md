---
name: fleet-chezmoi
description: Inspect, compare, and deliberately reconcile chezmoi source and live-state drift across configured machines. Use for chezmoi status, diff, pull, add, apply, source-repository drift, or post-apply verification.
---

# Fleet Chezmoi

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md` and
`CLI="$SKILL_DIR/../../scripts/machine-utilities"`; the shell working directory
is not the skill directory. Collect the `chezmoi` section, then use native
read-only commands such as `chezmoi status`, `chezmoi diff`,
`chezmoi source-path`, and Git status in the source repository. Determine
whether source, live state, or both changed; do not assume the source always
wins.

Reconcile each requested target path on every requested host, including hosts
that appear clean. Build a per-target evidence table containing the rendered
content or digest, mapped source path, live and source mtimes, and per-file Git
history. Timestamps are evidence, never automatic precedence: `add`, `apply`,
copy, checkout, and pull can rewrite them. Infer intent from semantic content,
Git history, templates and host conditions, and cross-host agreement.

Preserve disjoint edits with a deliberate source merge. Stop for conflicts in
the same semantic region or ambiguous intent. Never use newest-wins or blanket
`chezmoi add`/`chezmoi apply` before path-level reconciliation. Preview the
reconciled source on every requested host before any mutation.

Default to a plan per host:

- source should win: preview `chezmoi apply --dry-run --verbose`;
- live state should win: list exact `chezmoi add` targets;
- remote source advanced: plan a clean fast-forward pull before apply;
- both changed or source is dirty/diverged: stop for reconciliation.

Before apply, verify host identity, preserve a diff/backup, and seal the exact
approved operations with `"$CLI" seal-plan DRAFT SNAPSHOT PLAN`. Recapture
chezmoi inventory and require
`"$CLI" verify-preconditions PLAN CURRENT-SNAPSHOT` to succeed immediately
before mutation. Obtain separate approval and execute only the sealed argv.
Never force-reset, auto-commit, or reveal template secret values.
For a local target use `"$CLI" apply-plan PLAN PLAN-ID OUTPUT`; for SSH use
`"$CLI" apply-ssh-plan PLAN PLAN-ID OUTPUT`; native Windows uses the
remote-control worker contract. Apply recaptures trusted preflight itself and
preserves authoritative partial output after a failed operation or
postcondition when post-inventory remains available. SSH uses bounded
connection/keepalive timeouts and verifies the configured native hostname/user.
The executor
supports a clean fast-forward source pull, a non-TTY full apply, and a sealed
target-scoped apply. A target-scoped apply names 1-16 exact absolute destination
paths under the target user's home directory. Its sealed argv is exactly
`chezmoi --no-tty apply -- TARGET...`; it rejects flags, duplicates, traversal,
cross-platform path forms, and paths outside that home boundary. Its immediate
precondition and postcondition run `chezmoi status -- TARGET...`, so unrelated
drift does not authorize or fail the target change. `chezmoi add` remains
unsupported because source additions require user-specific reconciliation.

For a readiness-advertised Windows profile action, render only the already
authorized target-specific managed files into a private source root and build
the payload with `"$CLI" profile-bundle SPEC SOURCE-ROOT OUTPUT`. Codex and
Claude must produce the same bundle bytes. Do not include chezmoi secrets,
secret-backed templates, credentials, installed plugin caches, arbitrary paths,
or content outside the protected entry map. S4U is logged-off and has no
network or encrypted-file access; use ordinary user-session reconciliation
when those capabilities are required.

Use `"$CLI" privilege-status HOST SNAPSHOT` and the shared protected vocabulary
`prepare-privilege-identity`, `prepare-privilege-enrollment`,
`verify-privilege-plan`, `submit-privilege-plan`,
`lookup-privilege-result`, `preview-privilege-upgrade`, and
`preview-privilege-revocation`. Preserve all readiness/result states and never
fall back through WSL, a shell, or a visible Codex task.
Never ask for or relay a sudo or Administrator password; stop lifecycle changes at the local
human password/UAC boundary.

Use local/SSH execution. If a Windows host is configured for Codex remote
control, read and follow
`"$SKILL_DIR/../../references/codex-remote-control.md"`, including its exact
shared `yardmaster/model-routing/v1` dispatch before task creation or a
work-starting follow-up; Claude reports unsupported and no WSL fallback is
allowed. Verify `chezmoi status`, rendered
diff, source Git state, and relevant auth/tool health afterward.
