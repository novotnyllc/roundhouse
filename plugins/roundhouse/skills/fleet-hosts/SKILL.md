---
name: fleet-hosts
description: "Add a host to the fleet or remove one, end to end: config entry, SSH reachability, SSH-certificate identity enrollment or revocation, privilege-broker enrollment where wanted, target prerequisites (agent harnesses, plugins, tmux/jq), and readiness verification. Use when the user says to add, enroll, onboard, remove, retire, or decommission a machine."
---

# Fleet Hosts

Own the lifecycle of one fleet member at a time. Every mutating step names
its target and gets explicit consent; signing and privileged steps are
individually consented ceremonies, never batched into silence. Resolve
`SKILL_DIR` and `CLI="$SKILL_DIR/../../scripts/roundhouse"` as usual.

## Add a host

Ask for (defaults in brackets): display name; SSH alias — it must already
resolve in `~/.ssh/config`, never invent one; platform
[detect via `ssh <alias> uname -s`]; transport [`ssh`; `codex-remote-control`
only for a native-Windows destination]; groups [none]. For a Windows
machine, also ask whether WSL runs on the same hardware (and vice versa):
paired entries share a `physical_host` value, and the Windows entry sets
`wsl_interop_via: <wsl-entry-name>` so maintenance can use the interop
lane.

1. **Reachability** — `ssh -o BatchMode=yes <alias> 'echo ok'` through the
   login shell. Fix reachability first (`roundhouse:ssh-doctor` for macOS
   sshd faults); nothing else proceeds without it.
2. **Config entry** — add the machine to
   `${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json` (scaffold from
   the plugin's `config.example.json` if absent) and require
   `"$CLI" validate-config` to pass.
3. **SSH certificate enrollment** (consent) — the three-step ceremony, in
   order, each on its proper node: `prepare-ssh-identity` on the new host
   generates its key and public-only CSR; `certify-ssh-node` signs that CSR
   in the owner ceremony on the signing node (its own consent — this mints
   trust); `enroll-ssh-posix install` then `verify` places the fleet CA and
   KRL on the target. Do not shortcut with raw `authorized_keys` edits.
4. **Prerequisites on the target** (consent, via the target's own managers) —
   `tmux` and `jq` through `roundhouse:fleet-update`; agent harnesses
   verified and plugin/marketplace parity (railyard, roundhouse,
   agent-utilities, compound-engineering) through `roundhouse:fleet-agents`'
   routine refresh; project checkouts through `roundhouse:fleet-projects`
   when the host will take delivery work.
5. **Optional privilege enrollment** (separate consent; skip by default) —
   `enroll-privilege-posix`, or on Windows `enroll-windows-sftp.ps1` /
   `enroll-privilege-windows.ps1`, only when the host needs the privileged
   install lane.
6. **Verify** — finish with `roundhouse:fleet-readiness` for the new host and
   report the go/no-go table. A host is not "added" until readiness reports
   it.

## Remove a host

Order matters: clean up over SSH while access still works, revoke second.

1. **Target-side cleanup** (consent) — while still enrolled: remove or
   transfer any live work (worktrees, running sessions — check before
   touching); optionally uninstall the fleet plugins on the target; remove
   enrolled artifacts via the enroll scripts' own uninstall/revoke paths
   (never raw deletion of the protected trees).
2. **Revoke trust** — generate the updated owner KRL (an owner-side
   ceremony), tear down the departing host's enrollment with
   `enroll-ssh-posix preview-revoke` then `revoke`, and deliver the new KRL
   to every remaining fleet host with `enroll-ssh-posix repair` — not just
   the departing one. Revoke privilege enrollment the same way when present.
3. **Config removal** — delete the machine entry, re-run
   `"$CLI" validate-config`, and drop the host from any groups.
4. **Report** — if the entry shares a `physical_host` with others, say so
   (removing one environment does not remove the hardware or its siblings).
   State what was removed, what was revoked, and any residual
   state deliberately left on the machine (an unenrolled box keeps its own
   harnesses and user data — that is expected, name it rather than
   implying a wipe).

## Boundaries

- One host per invocation; a fleet-wide sweep is `fleet-readiness` /
  `fleet-agents` territory.
- Never generate SSH keys anywhere but the host they identify; never move a
  private key between machines; the CSR is public-only by construction.
- Signing (`certify-ssh-node`) and privilege enrollment always get their own
  explicit consent naming the exact host, even inside a larger add flow.
- `railyard:setup` delegates per-host work here during first-run setup;
  this skill is also directly invocable any time after.
