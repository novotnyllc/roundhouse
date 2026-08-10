---
name: remote-mac
description: Operate and diagnose configured remote Macs over Tailscale or SSH, with tmux and GUI fallback. Use when a fleet Mac needs inspection, repair, service checks, or remote automation.
---

# Remote Mac

Use the machine inventory from
`${ROUNDHOUSE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json}`.
Do not assume host names, users, paths, or services. Prefer the requested
machine, then its configured `ssh_alias`, SSH config, and Tailscale state.
Treat inventory as routing hints until `hostname`, `id -un`, `sw_vers`, and
`pwd` confirm the destination.

Use non-interactive SSH for one-shot checks, and always execute the command
through the target user's configured login shell. This preserves user-level
paths such as `$HOME/.local/bin`; never infer that tooling is absent from a raw
non-login SSH `PATH`.

When the user names a specific CLI for the operation, that named tool is the
contract. Locate it on the target (`command -v <cli>`, then `<cli> --help`) and
drive the operation through it. If it genuinely lacks the operation, stop and
say so — never silently fall back to hand-editing the files it manages behind
its back, which desyncs whatever state that CLI owns.

```bash
ssh -o BatchMode=yes -o RequestTTY=no -o RemoteCommand=none \
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
  ALIAS "exec \"\$SHELL\" -lc 'hostname; id -un; sw_vers'"
```

Override aliases that auto-attach tmux or run a remote command. Use the same
configured-login-shell form for developer tools:

```bash
ssh -o BatchMode=yes -o RequestTTY=no -o RemoteCommand=none \
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 ALIAS \
  "exec \"\$SHELL\" -lc 'command -v brew; command -v pnpm; command -v node'"
```

If Tailscale is involved, inspect `tailscale status --json` and use its current
address rather than a cached inventory address. Try mDNS only from the same
LAN, and do not use another fleet machine as a relay unless that route is
configured and the user approved it. For long-running or interactive work,
create a clearly named remote tmux session and report the attach command.

Codex automations are host-local scheduler state. Moving or handing off a task
does not move its automation. Ensure the checkout and automation exist on the
intended runner, and disable the old copy when the user wants only one runner.

For a named service, discover its real launchd label, process, or port from
repo docs, `AGENTS.md`, or the configured project before checking:

```bash
launchctl list
tmux list-sessions
ps axww
lsof -nP -iTCP -sTCP:LISTEN
```

Filter locally without exposing environment values or secrets. Read-only
checks come first. Do not install, start, stop, restart, unload, or edit a
service unless the user asks. Before treating a loopback port as a local
service, check whether it is an SSH tunnel. Never stop a tmux session or dev
service that the current task did not start without explicit approval.

Prefer SSH and service APIs. Use GUI automation only for explicitly GUI-bound
work or a visible security prompt. Capture current state before each action
and verify afterward. Never type or expose a secret in chat; let the user
approve keychain or browser prompts.

If the host is unreachable, report each attempted configured route. Never
substitute WSL for a direct Windows Codex Desktop transport.

Adapted from `steipete/agent-scripts` `skills/remote-mac` at
`c46ea65b6323e8a2b6f441f8b6449ae731bc8f81` (MIT).
