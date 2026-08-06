# Fleet chezmoi

Fleet Chezmoi inspects, compares, and deliberately reconciles drift between
your chezmoi dotfiles source and the live state on every configured
machine. It never assumes the source repository is automatically right, and
it never assumes a newer timestamp means a better answer — `chezmoi add`,
`apply`, `pull`, and plain file copies all rewrite mtimes, so timestamps are
evidence, not precedence.

## When to use it

- "Did my dotfiles drift on the Linux box?"
- You edited a config file directly on a remote machine and need to decide
  whether that edit should flow back into the source repo.
- A `chezmoi apply` on one host would clobber changes that look
  intentional, and you want a plan, not a blind `apply`.
- You're auditing whether every host's live state actually matches what the
  source repository says it should be — including hosts that look clean.

## How it works

### Read-only reconnaissance first

The skill uses native read-only commands — `chezmoi status`, `chezmoi
diff`, `chezmoi source-path`, and Git status inside the source repo — on
every requested host, including ones that appear clean. For each requested
target path it builds a per-target evidence table: rendered content or
digest, the mapped source path, live and source mtimes, and per-file Git
history. It infers intent from semantic content, Git history, chezmoi
templates and host conditions, and cross-host agreement — never from
mtimes alone.

### Reconciliation is a plan, not a guess

Disjoint edits are preserved with a deliberate source merge. Anything that
conflicts in the same semantic region, or where intent is genuinely
ambiguous, stops for you to resolve rather than picking a side. The default
plan per host is one of:

- **Source should win** — preview `chezmoi apply --dry-run --verbose`.
- **Live state should win** — list the exact `chezmoi add` targets (see
  below on why this step is a *plan*, never an automatic action).
- **Remote source is ahead** — plan a clean fast-forward pull before apply.
- **Both changed, or source is dirty/diverged** — stop for reconciliation;
  no automatic resolution.

Every reconciled source is previewed on every requested host before any
mutation runs.

### Applying: sealed, scoped, and verified

Before `apply`, the skill verifies host identity, preserves a diff/backup,
and seals the exact approved operations with `seal-plan DRAFT SNAPSHOT
PLAN`. It recaptures chezmoi inventory and requires `verify-preconditions
PLAN CURRENT-SNAPSHOT` to succeed immediately before mutation, then
executes only the sealed argv after separate approval — never a
force-reset, never an auto-commit, and never a reveal of a template's
secret values.

- Local target: `apply-plan PLAN PLAN-ID OUTPUT`.
- SSH target: `apply-ssh-plan PLAN PLAN-ID OUTPUT`.
- Native Windows: the remote-control worker contract (see
  [`config.md`](../config.md#machines) for `codex-remote-control`
  transport).

The executor's sealed apply is narrowly scoped by design: it names 1–16
exact absolute destination paths under the target user's home directory,
and its argv is exactly `chezmoi --no-tty apply -- TARGET...` — no flags,
no duplicates, no path traversal, no cross-platform path forms, and nothing
outside the home boundary. Its immediate precondition and postcondition
both run `chezmoi status -- TARGET...`, so drift in some *other* file never
authorizes — or blocks — the change you actually approved.

### Why `chezmoi add` stays unsupported

`chezmoi add` is deliberately not part of this skill's mutation surface,
sealed or otherwise. The reason is the same one that makes reconciliation a
plan and not a guess: adding a file to a personal dotfiles source is a
decision about *what belongs in that repository at all* — whether it should
be templated, whether it's host-specific, whether some of its content is a
secret that must never land in the source tree unencrypted. That decision
is inherently user-specific in a way "live state should win, apply" isn't.
An agent that ran `chezmoi add` on your behalf could just as easily commit
a machine-local path, an unredacted token, or a value that should have been
a template variable — into a dotfiles repository you may sync to every
other machine you own. So the skill will *plan* the exact targets a
live-state-wins resolution would add, and hand you that list — but the
actual `chezmoi add` is yours to run, deliberately, once you've looked at
what's in the file.

### Windows without a shell fallback

For a readiness-advertised Windows profile action, the skill renders only
the already-authorized, target-specific managed files into a private
source root and builds the payload with `profile-bundle SPEC SOURCE-ROOT
OUTPUT`. Codex and Claude must produce identical bundle bytes for the same
input. The bundle never carries chezmoi secrets, secret-backed templates,
credentials, installed plugin caches, arbitrary paths, or anything outside
the protected entry map — the S4U context that receives it is logged off
and has no network or encrypted-file access, so ordinary user-session
reconciliation is used instead whenever those capabilities are actually
needed.

For a Windows host configured for Codex remote control, the skill follows
`references/codex-remote-control.md`, including its shared
`railyard/model-routing/v1` dispatch step before creating a task. Claude
reports this transport as unsupported; there's no WSL shell fallback for it.

## Boundaries

- Never uses newest-wins or a blanket `chezmoi add` / `chezmoi apply`
  before path-level reconciliation has actually happened.
- Never force-resets, auto-commits, or reveals a template's secret values.
- `chezmoi add` is a plan output, not an executable action this skill runs.
- The privilege broker's enrollment vocabulary
  (`prepare-privilege-identity`, `verify-privilege-plan`, and the rest) is
  available for status only; profile mutation still stops at the local
  human password/UAC boundary, and no sudo or Administrator password is
  ever requested or relayed.
- Uses local or SSH execution, or the Windows remote-control worker
  contract — never a WSL shell as a stand-in for a native Windows path, and
  never a visible Codex task as a silent fallback.

## Example session

> **You:** "Did my shell config drift on the remote Mac?"
>
> **What happens:** Fleet Chezmoi runs `chezmoi status` and `chezmoi diff`
> on the remote host and checks the source repo's Git status locally. It
> builds an evidence table for the target file — live mtime, source mtime,
> rendered digest on each side, and recent Git history — and reports that
> the *live* file changed after the last `chezmoi apply` while the source
> is unchanged. It proposes a plan: "live state should win," lists the
> single target it would add, and stops there. It does not run
> `chezmoi add` itself.
>
> **You:** "Yes, add that one."
>
> **What happens:** you run the `chezmoi add` yourself (or explicitly ask
> the skill to walk you through it) so you see exactly what content is
> about to enter your dotfiles source. Once the source reflects the
> change, the skill can seal and apply that state to any other host you
> name, with the usual preview, seal, precondition-verify, approve,
> execute sequence.
