# SSH doctor

SSH Doctor diagnoses why a fleet Mac's SSH stopped working — pre-auth
closes, launchd `sshd` exhaustion, misconfiguration, firewall rules, or
stranded sessions — starting from loopback and working outward, and never
mutating anything before it's identified the actual cause.

## When to use it

- SSH connects, then immediately closes.
- A fleet Mac stopped accepting SSH at all.
- `kex_exchange_identification: Connection closed by remote host` on the
  client side.
- You suspect `sshd` has run out of process slots or Remote Login somehow
  got disabled.

## How it works

### Resolve the target, then verify identity

The skill resolves the target from the [fleet config](../config.md) and
confirms host identity before changing anything. It never prints secrets,
tokens, broad environment output, or credential files.

### Loopback first — it tells you which half is broken

Loopback failure points at `sshd`, launchd, or server configuration.
Loopback success with remote failure points at the network, firewall,
filter, or listen path instead — so this order is never skipped:

```bash
hostname; id -un; sw_vers
sudo systemsetup -getremotelogin
sudo launchctl print system/com.openssh.sshd
sudo lsof -nP -iTCP:22 -sTCP:LISTEN
nc -vz 127.0.0.1 22
ssh -4 -F /dev/null -o RequestTTY=no -o RemoteCommand=none \
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
  USER@127.0.0.1 "exec \"\$SHELL\" -lc 'hostname; id -un'"
```

Every SSH command runs through the target user's configured login shell
(`$SHELL -lc`), so a tool is never diagnosed as missing just because a raw
non-login SSH `PATH` doesn't carry it. `BatchMode=yes` is used whenever a
password-fallback prompt would otherwise hang the check.

### Enabling Remote Login or kickstarting `sshd` mutates state

These two commands change what's running on the host, so the skill asks
for approval before either one:

```bash
sudo systemsetup -setremotelogin on
sudo launchctl kickstart -k system/com.openssh.sshd
```

### Inspect configuration and logs before editing anything

```bash
sudo sshd -T
sudo grep -En '^[[:space:]]*(AllowUsers|DenyUsers|AllowGroups|DenyGroups|Match|MaxStartups|LoginGraceTime|ListenAddress|AuthenticationMethods|UsePAM|PasswordAuthentication|PubkeyAuthentication)\b' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null

sudo log show --last 30m \
  --predicate 'process == "sshd" OR process == "launchd"' --style compact
```

Suspicious lines are reported before any edit is proposed.

### Reading the fingerprint of stranded sessions

Client `kex_exchange_identification: Connection closed by remote host` +
server `Too many processes` + a high launchd copy count + many
PID-1-parented `sshd-session: USER` processes means stranded inetd-style
copies have eaten `sshd`'s process budget. Before terminating anything:

```bash
sudo launchctl print system/com.openssh.sshd
ps -axo pid,ppid,uid,user,state,lstart,etime,comm,args
sudo lsof -nP -c sshd-session -iTCP
```

If specific stale sessions are clearly blocking new SSH connections, the
skill asks for approval, terminates only those exact PIDs with `TERM`
first, and rechecks. `KILL` is used only after confirming ownership and
that no active shell would be lost.

### Firewall checks come last, and only after loopback succeeds

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps
sudo pfctl -sr
sudo pfctl -si
```

## Scope

- Secrets, tokens, broad environment dumps, and credential-file contents stay
  out of output.
- Enabling Remote Login and kickstarting `sshd` are the two mutations in the
  normal flow, and each requires your approval first.
- Session termination targets the exact PIDs identified as blockers; `KILL`
  becomes available after ownership is confirmed.
- Firewall and PF inspection follows successful loopback, preserving the
  diagnostic order.
- Every session closes with the root cause, exact changes, validating
  evidence, and whether the remote client should retry.

Adapted from `steipete/agent-scripts` `skills/ssh-doctor` (MIT).

## Example session

> **You:** "SSH to the Mac mini connects and then immediately closes, and
> it says 'Too many processes.'"
>
> **What happens:** SSH Doctor resolves the host from the fleet config,
> then checks loopback first: `getremotelogin`, `launchctl print
> system/com.openssh.sshd`, `lsof -nP -iTCP:22 -sTCP:LISTEN`, and a
> loopback SSH attempt — which fails with the same close, pointing at
> `sshd`/launchd rather than the network. It runs `ps -axo
> pid,ppid,uid,user,state,lstart,etime,comm,args` and `lsof -nP -c
> sshd-session -iTCP`, finds dozens of PID-1-parented `sshd-session`
> processes with multi-day `etime` and no active terminal, and confirms
> the launchd copy count is high — the stranded-session fingerprint. It
> proposes terminating exactly those stranded PIDs with `TERM`, asks for
> approval, then rechecks `lsof -nP -iTCP:22 -sTCP:LISTEN` to confirm new
> connections succeed.
