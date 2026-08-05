---
name: ssh-doctor
description: Diagnose macOS SSH and Remote Login failures, including pre-auth closes, launchd sshd exhaustion, configuration, firewall, and stale sessions. Use when SSH connects then closes or a fleet Mac cannot accept SSH.
---

# SSH Doctor

Resolve the target from the Machine Utilities config and verify its identity
before changing anything. Do not print secrets, tokens, broad environment
output, or credential files. Run SSH commands through the target user's
configured login shell (`$SHELL -lc`) so user-level paths are present; never
diagnose a tool as missing from a raw non-login SSH `PATH`.

Validate loopback first. Loopback failure points to sshd, launchd, or server
configuration; loopback success with remote failure points to the network,
firewall, filter, or listen path.

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

Use `BatchMode=yes` when password fallback would hang. Enabling Remote Login
or kickstarting sshd mutates state, so obtain approval before:

```bash
sudo systemsetup -setremotelogin on
sudo launchctl kickstart -k system/com.openssh.sshd
```

Inspect effective configuration and report suspicious lines before editing:

```bash
sudo sshd -T
sudo grep -En '^[[:space:]]*(AllowUsers|DenyUsers|AllowGroups|DenyGroups|Match|MaxStartups|LoginGraceTime|ListenAddress|AuthenticationMethods|UsePAM|PasswordAuthentication|PubkeyAuthentication)\b' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null
```

Check logs with:

```bash
sudo log show --last 30m \
  --predicate 'process == "sshd" OR process == "launchd"' --style compact
```

The combination of client
`kex_exchange_identification: Connection closed by remote host`, server
`Too many processes`, high launchd `copy count`, and many PID-1-parented
`sshd-session: USER` processes indicates stranded inetd copies.

Inspect before terminating anything:

```bash
sudo launchctl print system/com.openssh.sshd
ps -axo pid,ppid,uid,user,state,lstart,etime,comm,args
sudo lsof -nP -c sshd-session -iTCP
```

If selected stale sessions are clearly blocking new SSH, obtain approval,
terminate only those PIDs with `TERM`, then recheck. Use `KILL` only after
confirming ownership and that no active shell would be lost.

Only inspect the application firewall and PF after loopback succeeds:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps
sudo pfctl -sr
sudo pfctl -si
```

Close with root cause, exact changes, validation evidence, and whether the
remote client should retry.

Adapted from `steipete/agent-scripts` `skills/ssh-doctor` at
`6e512e6fe0546471dfce5f48c9896c6ddce669cd` (MIT).
