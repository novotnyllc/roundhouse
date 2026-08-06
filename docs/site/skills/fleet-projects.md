# Fleet projects

Fleet Projects inventories and prepares your Git checkouts across the
fleet — missing clones, wrong origins, branch or dirty-state drift — and
tracks whether Codex has registered each one as a saved project on that
host. It's what tells you (or a dispatcher) that a repository is actually
in place, at the expected commit, before work gets placed there.

## When to use it

- "Is `myapp` checked out everywhere it should be?"
- "Clone the missing repos" — a bounded, reviewable action, not a blind
  `git clone` sweep.
- Before handing work to another machine — confirming both ends have a
  matching, registered checkout.
- Setting up or checking the private coordination/handoff repository a
  fleet-wide task needs.

## How it works

The `projects` inventory section covers configured path, expected source,
sanitized origin, HEAD/tree IDs, branch, dirty count, host groups, and
whether Codex exposes the environment-native checkout as a saved project.
Git readiness and Codex readiness are evaluated separately — a clean,
correct checkout with no Codex registration is a different finding than a
missing checkout. Ahead/behind values describe only the current local
remote-tracking ref; network freshness stays `unknown` until an explicitly
authorized `git fetch` actually runs.

**The default plan is conservative by design:**

| Checkout state | Default action |
| --- | --- |
| Missing | create the configured parent, clone the configured source into the exact path |
| Wrong origin, or path isn't a repository | stop for your choice — never guessed |
| Clean, behind upstream | fetch plus fast-forward-only pull |
| Dirty, detached, ahead, or diverged | reported, never touched — no reset, stash, switch, merge, or discard happens automatically |

Before apply: verify live host/platform and the destination parent, then
seal the exact source/path operations with `roundhouse seal-plan DRAFT
SNAPSHOT PLAN`. Recapture project inventory and require `roundhouse
verify-preconditions PLAN CURRENT-SNAPSHOT` to succeed. After a separate
approval, only the sealed argv executes — `roundhouse apply-plan PLAN
PLAN-ID OUTPUT` locally, `roundhouse apply-ssh-plan PLAN PLAN-ID OUTPUT`
over SSH, or the remote-control worker contract on native Windows. Apply
recaptures trusted preflight itself and preserves the authoritative
partial output if an operation or postcondition fails and post-inventory
is still available. SSH uses bounded connection/keepalive timeouts and
verifies the configured native hostname/user.

### Codex saved-project readiness

Discovery matches both host and native path. If a configured project is
missing from Codex's saved projects, you're told to add the exact checkout
in Codex Desktop on that host — this skill never edits Codex's internal
databases directly. The discovery result, and any real task/correlation
IDs, are recorded in an owner-controlled mode-0600 metadata file
(`host_id`, project name, `available`/`missing`/`unreachable`, configured
`codex_host`, observed native path and expected source, plus opaque
project/task/correlation IDs when available), then written to canonical
JSONL with `roundhouse record-codex-readiness SNAPSHOT METADATA OUTPUT`
for a downstream dispatcher to consume. Windows task creation for this
follows the plugin's `codex-remote-control.md` reference, including its
`railyard/model-routing/v1` dispatch step — and never WSL.

Cross-host handoff requires matching saved-project repository identity at
*both* ends; creating a remote task directly only requires the
destination's saved project.

### Protected broker readiness

This is independent of project and Codex saved-project readiness.
`roundhouse privilege-status HOST SNAPSHOT` reports the public
node/CA/certificate/host-key identity, transport, broker, machine-package,
and profile readiness — a visible Codex task is never treated as a
protected-broker fallback. The shared vocabulary is the same one used
across the fleet plugin: `prepare-privilege-identity`,
`prepare-privilege-enrollment`, `verify-privilege-plan`,
`submit-privilege-plan`, `lookup-privilege-result`,
`preview-privilege-upgrade`, `preview-privilege-revocation`. Project
source, Git credentials, working trees, and installed plugin caches are
never profile payloads. States like `needs_enrollment`, `drifted`,
`transport_unavailable`, `unsupported_context`,
`unsupported_security_boundary`, `partial`, and `stale` are preserved
without fallback. Nothing here asks for or relays a sudo or Administrator
password.

### The coordination / handoff repository

Each project's own Git repository, at an exact commit, is the
authoritative substrate for handoff on that project. A separately
configured private coordination repository (`handoff_project` in
`config.json`) may additionally hold structured pointers, ownership,
status, and evidence for fleet-wide or cross-repository handoffs — one
such repository can cover the whole fleet. It must never copy project
source, replace a project repository, or depend on an unrelated utility
checkout; it's treated like any other configured project, cloned into
each host's `dev_root`, and registered as a saved Codex project only where
coordination tasks actually run.

If a handoff needs a coordination repository and none is configured yet,
Fleet Projects first looks for an existing configured project or a
checkout you supply and verifies its Git remote. If it's elsewhere, you're
asked for its project ID or exact path, and the skill offers to persist
the matching configuration — it never relocates, clones, or replaces it
implicitly. If no repository exists at all, the skill explains it will
hold only pointers, ownership, status, and evidence, then proposes an
owner, name, local path, and private visibility (defaulting to a private
repo in your authenticated GitHub account). It never creates or pushes one
merely because a handoff was requested — `gh repo create`, adding a
remote, or any push all require your explicit approval first. After
approval, it verifies the resulting remote is actually private before
recording it as both an ordinary project and `handoff_project`.

## Boundaries

- Never resets, stashes, switches, merges, or discards work automatically
  — a dirty or diverged checkout is reported, not touched.
- Doesn't set up SSH access or enroll hosts — that's
  [`fleet-hosts`](fleet-hosts.md), a prerequisite this skill assumes is
  already done.
- Doesn't touch package managers — that's [`fleet-update`](fleet-update.md).
- Doesn't edit Codex's internal project database — registration happens
  in Codex Desktop, by you, on the host itself.

## Example session

> **You:** "Make sure `myapp` is checked out and up to date on every dev
> machine."
>
> **What happens:** the agent inventories the `projects` section across
> the fleet, finds one host missing the clone and one clean-but-behind,
> drafts a plan (clone on the missing host, fast-forward pull on the
> other), seals it against a fresh snapshot, and — after your approval —
> applies only that sealed plan. A third host that's dirty or diverged is
> reported with its exact state and left untouched, not silently skipped
> or forced.
