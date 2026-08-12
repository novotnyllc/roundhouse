# Remote Mac

Remote Mac operates and diagnoses a configured Mac elsewhere in your fleet
over SSH or Tailscale, with tmux for anything long-running and GUI
automation as a last resort. It treats your fleet config as routing hints,
not ground truth — every session confirms it actually landed on the right
box before doing anything else.

## When to use it

- "Is the Mac mini's Plex service actually running?"
- "SSH into my other Mac and check disk space."
- You need a long-running or interactive command on a remote Mac and want a
  named tmux session you can reattach to, not a one-shot SSH that dies with
  your terminal.
- A configured Tailscale address might be stale and you want the live one.

## How it works

### Confirm you're actually on the right machine

The machine inventory comes from
`${ROUNDHOUSE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json}`
(see [`config.md`](../config.md#file-location-and-resolution-order) for the
full resolution order). The skill prefers the requested machine, then its
configured `ssh_alias`, SSH config, and current Tailscale state — but
treats all of that as a routing hint until `hostname`, `id -un`, `sw_vers`,
and `pwd` on the far end actually confirm the destination. Host names,
users, paths, and services are never assumed from the config alone.

### Every command runs through the target's login shell

One-shot checks use non-interactive SSH, always executed through the
target user's configured login shell — never a raw non-login SSH `PATH`,
which would make user-level tooling under `$HOME/.local/bin` look absent
when it isn't:

```bash
ssh -o BatchMode=yes -o RequestTTY=no -o RemoteCommand=none \
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
  ALIAS "exec \"\$SHELL\" -lc 'hostname; id -un; sw_vers'"
```

The same form covers developer-tool discovery:

```bash
ssh -o BatchMode=yes -o RequestTTY=no -o RemoteCommand=none \
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 ALIAS \
  "exec \"\$SHELL\" -lc 'command -v brew; command -v pnpm; command -v node'"
```

Aliases that auto-attach tmux or run a remote command by default are
overridden explicitly rather than trusted as-is.

### Tailscale, mDNS, and never routing through a third machine

If Tailscale is involved, the skill inspects `tailscale status --json` and
uses its *current* address rather than a cached inventory address. mDNS is
tried only from the same LAN. Another fleet machine is never used as a
relay unless that route is explicitly configured and you've approved it.

### Long-running work gets a named tmux session

For anything interactive or long-running, the skill creates a clearly
named remote tmux session and reports the exact attach command — it
doesn't run long work inline and leave you no way back in.

### Finding a service before touching it

For a named service, the skill discovers its real launchd label, process,
or port from repo docs, `AGENTS.md`, or the configured project — not
guessed — before checking:

```bash
launchctl list
tmux list-sessions
ps axww
lsof -nP -iTCP -sTCP:LISTEN
```

Output is filtered locally without exposing environment values or secrets.
Before treating a loopback port as a local service, the skill checks
whether it's actually an SSH tunnel.

### Codex automations don't follow the task

Codex automations are host-local scheduler state. Moving or handing off a
task doesn't move its automation with it — the skill makes sure the
checkout and automation both exist on the intended runner, and disables
the old copy only when you want a single runner.

## Scope

- Read-only checks lead every invocation. Installation, start, stop, restart,
  unload, and service edits wait for your explicit request.
- A tmux session or development service started by another task is stopped
  only with your explicit approval.
- GUI automation serves explicitly GUI-bound work and visible security
  prompts; SSH and service APIs are the preferred paths for other work.
- Secrets stay in the keychain or browser prompts for you to approve directly
  on the machine; they remain out of chat.
- An unreachable host produces a report for every attempted configured route,
  with the specific reachability evidence.
- Native Windows transport uses direct Windows Codex Desktop; WSL serves as
  the launcher for its documented interop lane.
- Current state is captured before every action and verified afterward.

Adapted from `steipete/agent-scripts` `skills/remote-mac` (MIT).

## Example session

> **You:** "Is the media server running on the Mac mini?"
>
> **What happens:** Remote Mac resolves `mac-mini` from the fleet config,
> connects with `BatchMode=yes` and the login-shell wrapper, and confirms
> `hostname`/`id -un`/`sw_vers` match the configured entry before doing
> anything else. It discovers the service's real launchd label from the
> project's docs, then runs `launchctl list` and `lsof -nP -iTCP
> -sTCP:LISTEN` filtered to the relevant label and port. It reports running
> vs. not, the listening port, and whether anything looks like a stale SSH
> tunnel on that port — without stopping, starting, or restarting anything.

> **You:** "Kick off a long build on the Linux box and let me check on it
> later."
>
> **What happens:** the skill opens a clearly named tmux session (for
> example `roundhouse-build-2026-08-06`), starts the build inside it, and
> reports the exact `tmux attach -t roundhouse-build-2026-08-06` command to
> reconnect. It doesn't run the build inline over the one-shot SSH
> connection, where losing the connection would kill it.
