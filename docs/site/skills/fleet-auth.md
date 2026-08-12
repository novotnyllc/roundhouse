# Fleet auth

Fleet Auth audits every configured authentication artifact across your
fleet — Codex's `auth.json`, Claude's CLI session, GitHub CLI's stored
token, `xurl`'s encrypted credential file, anything else you've declared in
`auth_artifacts` — and reconciles it deliberately when you ask. It never
reads a credential's contents into the conversation, a log, a JSONL
snapshot, a command argument, or a task prompt. What it reports is metadata:
path, strategy, owner, mode, size, mtime, a SHA-256 hash, link status, and
the result of the tool's own native verification command.

## When to use it

- "Is everyone still logged in?" — a fleet-wide auth health sweep.
- "Why does the Linux box keep asking me to reauth `gh`?"
- Two machines show matching SHA-256 hashes for the same credential file and
  you want to know if that's expected or a portability accident.
- You're provisioning a new host and need an `encrypted-install` artifact
  (like `xurl`'s `auth.yml`) delivered from its `op://` reference.
- You're deciding whether a credential *should* be portable at all.

## How it works

### Inventory first

Run the `auth` section of `fleet CLI` collect before anything else. For
each artifact declared under `auth_artifacts` in
[`config.json`](../config.md#auth_artifacts) it reports configured name,
path, strategy, owner, mode, size, mtime, SHA-256, symlink status, and the
result of that artifact's own `verify` command — never file contents.
Reference material on the distinct Claude CLI/Desktop and Codex credential
boundaries lives in `references/agent-settings-and-auth.md` alongside the
skill.

### Four strategies, honored as configured

| Strategy | What happens |
| --- | --- |
| `chezmoi` | Delegated entirely to [`fleet-chezmoi`](fleet-chezmoi.md) — declarative dotfiles state, not this skill's problem. |
| `reauth` | The tool's own native login runs on that machine. Codex: `codex login`. Claude Code: `claude auth login`. GitHub CLI: `gh auth login`. |
| `encrypted-install` | The configured secret reference (an `op://` path) is resolved only after you approve the exact source, target hosts, and destination path. |
| `ignore` | State is reported; nothing changes. |

`config.example.json` shows all four flavors in miniature: `github-cli` and
`codex` and `claude-code` are `reauth`; `xurl` is `encrypted-install` with a
`secret_ref` of `op://your-vault/xurl-auth/credential-file`.

### Mutation is sealed, like everywhere else in roundhouse

Before touching a file, the skill drafts the exact operation, seals it with
`seal-plan DRAFT SNAPSHOT PLAN`, re-verifies live host identity, recaptures
a fresh auth inventory, and requires
`verify-preconditions PLAN CURRENT-SNAPSHOT` to succeed immediately before
executing. You approve the exact sealed operation separately from the
draft. Symlink destinations are refused outright, and current metadata is
captured for rollback before anything is touched.

For `encrypted-install`, the secret is fetched directly into a mode-`0600`
temporary file on the *target* — never through a world-readable
intermediate — validated for type and size, then atomically renamed into
the user-owned parent directory:

- Local target: `apply-plan PLAN PLAN-ID OUTPUT`.
- Remote target over SSH: `apply-ssh-plan PLAN PLAN-ID OUTPUT`.

Either way, apply recaptures trusted preflight itself, runs the artifact's
configured native verification command afterward, and restores the prior
file (or removes the new one) on a failed verification. It also preserves
authoritative partial output after a failed operation or postcondition, as
long as post-inventory is still available.

### Pathless artifacts are status-only

`per-machine` or `native-store` artifacts without a `path` — Codex and
Claude Code's session auth, for example — are inventoried by their native
verification command alone; the skill doesn't infer where the credential
backend actually lives. An unhealthy result is reported as
`reauth_required`, with a manual host action, never silently retried.

## Scope

- Credential *contents* stay out of conversations, logs, snapshots, and
  command arguments; this skill reports metadata and hashes. Matching
  SHA-256 establishes identical bytes, while the artifact's own verify
  command establishes authentication validity.
- This release handles native Windows auth changes through interactive
  reauthentication on that host, with credentials staying outside task
  payloads.
- SSH reauthentication uses a visible interactive terminal or browser.
  Complete the one-time login on the target, then re-run inventory;
  `apply-ssh-plan` remains available for noninteractive encrypted installs.
- Each Remote Control host receives a full Claude login once. Setup tokens
  do not substitute for that login, and Claude state remains per-machine.
- Codex's file-backed `auth.json` becomes portable through an explicit
  `encrypted-install`; its ordinary storage remains per-machine.
- Secrets stay on their owning machine; WSL and other fleet machines provide
  no credential bridge.
- Per-machine least-privilege credentials are preferred for unattended work.
- The privilege broker's enrollment records are status-only here: this skill
  reads `privilege-status` and the shared broker vocabulary. Profile bundles
  and protected requests carry zero auth artifacts, credential material,
  secret references, encrypted files, tokens, or private keys. Enrollment
  and lifecycle changes stop at the local human password/UAC boundary, with
  sudo and Administrator passwords remaining with the local human.

## Example session

> **You:** "Check auth across the fleet — is `xurl` actually installed on
> the Linux box, and is everyone's `gh` session healthy?"
>
> **What happens:** Fleet Auth collects the `auth` section from every
> configured machine. It reports `xurl`'s `auth.yml` on the Linux host —
> path, mode `0600`, owner, size, mtime, SHA-256, and the result of
> `xurl auth status` — without ever showing the file's contents. For
> `github-cli` on each host it runs `gh auth status` and reports pass/fail
> per machine. If the Linux box comes back unhealthy, it's marked
> `reauth_required` with the exact native command to run there — not
> retried automatically and not routed through another host.

> **You:** "Install the `xurl` credential on the new Windows box from
> 1Password."
>
> **What happens:** the skill confirms the exact `op://` reference, the
> target host, and the destination path with you, then drafts the
> operation, seals it, re-verifies host identity and current auth
> inventory, and asks for separate approval on the sealed plan. On approval
> it resolves the secret directly into a private mode-`0600` file on the
> target, verifies type and size, atomically renames it into place, and
> runs `xurl auth status` to confirm. A failed verification rolls the file
> back rather than leaving a half-installed credential.
