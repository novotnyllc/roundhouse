---
name: fleet-hosts
description: "Add a host to the fleet or remove one, end to end: config entry, SSH reachability, the privilege lane's one-time OS approval, target prerequisites (agent harnesses, plugins, tmux/jq), and readiness verification. Use when the user says to add, enroll, onboard, remove, retire, or decommission a machine."
---

# Fleet Hosts

Own the lifecycle of one fleet member at a time. Every mutating step names
its target and gets explicit consent; the one privilege approval is its own
consented step, never batched into silence. Resolve
`SKILL_DIR` and `CLI="$SKILL_DIR/../../scripts/roundhouse"` as usual.

## Add a host

Ask for (defaults in brackets): display name; SSH alias — it must already
resolve in `~/.ssh/config`, never invent one; platform
[detect via `ssh <alias> uname -s`]; transport [`ssh`; `codex-remote-control`
only for a native-Windows destination]; groups [none]. For a Windows
machine, also ask whether WSL runs on the same hardware (and vice versa):
paired entries share a `physical_host` value, and the Windows entry sets
`wsl_interop_via: <wsl-entry-name>` so maintenance can use the interop
lane. Validation requires that sibling to be a configured `platform: wsl`,
`transport: ssh` entry on the same `physical_host`.

1. **Reachability** — `ssh -o BatchMode=yes <alias> 'echo ok'` through the
   login shell. Fix reachability first (`roundhouse:ssh-doctor` for macOS
   sshd faults); nothing else proceeds without it.
2. **Config entry** — add the machine to
   `${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json` (scaffold from
   the plugin's `config.example.json` if absent) and require
   `"$CLI" validate-config` to pass.
3. **Privilege lane** (consent; the one OS prompt) — `"$CLI" privilege-enroll
   HOST`. On macOS, Linux and WSL that is a single `sudo` password typed in
   the terminal running the command (over `ssh -t` for a remote host); on
   Windows it is a single UAC consent on the console, raised through the
   WSL sibling. The approval installs a root/SYSTEM-owned copy of the lane
   helper, an owner-only request queue and (POSIX) one exact sudoers grant
   or (Windows) one LocalSystem scheduled task; after it, every privileged
   package action the fleet needs runs unattended, including upgrades of
   the lane itself. Without a terminal the command does not prompt: it
   prints the exact command for the owner and readiness reports
   `needs_one_time_approval` until it has run. Never ask for or relay the
   sudo or Administrator password. The lane is on by default; set
   `privilege_lane: "disabled"` in the machine entry to opt a host out.
   The former CA-certificate lane (`prepare-ssh-identity`,
   `certify-ssh-node`, `enroll-ssh-posix`, the `windows-sftp` route) is an
   optional high-assurance mode selected only by an explicit
   `privilege_broker.automation_transport`; it is not part of adding a host.
4. **Prerequisites on the target** (consent, via the target's own managers) —
   `tmux` and `jq` through `roundhouse:fleet-update`; agent harnesses
   verified and user-authorized plugin/marketplace desired state supplied by
   the owning workflows applied through `roundhouse:fleet-agents`' routine
   refresh; project checkouts through
   `roundhouse:fleet-projects`
   when the host will take delivery work.
5. **Optional store credential** (separate consent; only when the host opts
   into desired-state sync) — provision this host's own minimal credential
   for the sync store's remote: an SSH deploy key generated on the host and
   kept in `~/.ssh`, or a token held by a credential helper. **Never embed
   the credential in the remote URL** — a URL-embedded token replicates into
   config, logs, and every error message. Scope it to the single private
   store repository and reuse it for nothing else; these are crown-jewel
   secrets, since the store is a trusted-write surface on every fleet
   machine.
6. **Lane check** — `"$CLI" privilege-lane-status HOST OUT.json` must report
   `ready` (or `disabled` when the host opted out). `drifted` means the
   root/SYSTEM copy, grant or queue no longer matches its identity record:
   run `privilege-enroll` again (one more approval) rather than editing the
   protected tree.
7. **Verify** — finish with `roundhouse:fleet-readiness` for the new host and
   report the go/no-go table. A host is not "added" until readiness reports
   it.

## Remove a host

Order matters: clean up over SSH while access still works, revoke second.

1. **Target-side cleanup** (consent) — while still enrolled: remove or
   transfer any live work (worktrees, running sessions — check before
   touching); optionally uninstall the fleet plugins on the target; remove
   enrolled artifacts via the enroll scripts' own uninstall/revoke paths
   (never raw deletion of the protected trees).
2. **Revoke trust** — remove the privilege lane on the departing host:
   `sudo /usr/local/libexec/roundhouse-lane/privilege-lane revoke` (POSIX)
   or an elevated `privilege-lane-windows.ps1 -Revoke` (Windows), each one
   local approval; it removes the grant or task, the protected copy and the
   queue and keeps the journal. A host on the optional CA lane follows
   `"$SKILL_DIR/../../references/windows-sftp.md"` instead.
   **Revoke the store credential alongside SSH trust**:
   delete the host's deploy key or token at the remote in the same step, so
   a decommissioned machine loses store write access exactly when it loses
   SSH trust.
3. **Config removal** — delete the machine entry, re-run
   `"$CLI" validate-config`, and drop the host from any groups.
4. **Report** — if the entry shares a `physical_host` with others, say so
   (removing one environment does not remove the hardware or its siblings).
   State what was removed, what was revoked, and any residual
   state deliberately left on the machine (an unenrolled box keeps its own
   harnesses and user data — that is expected, name it rather than
   implying a wipe).

## Restore a host

Restoring host X from the sync store is **configs plus a shopping list**,
not a machine image: the store cannot restore secrets, per-machine auth, or
SSH identity. **Read first** — show the full delta before touching
anything. Then, in this order:

1. **Enrollment** — run the add-a-host flow above for X: config entry and
   the privilege lane's one approval.
2. **Store credentials** — provision X's own store credential (step 5
   above), never reusing another host's.
3. **Materialize file-carried surfaces** — skills, agents, hooks, and
   allowlisted config keys from the `host/X` branch, each through the
   ordinary apply-time review.
4. **Replay manager installs** — reinstall the plugins and manager-owned
   items recorded in X's inventory snapshot, using each manager's own
   commands at the recorded pins.
5. **Per-artifact reauth** — work the auth shopping list with the user;
   every credential is re-established on X by hand.

If X's reviewed-ref names a fully abandoned reviewed line, re-enrollment is
the sanctioned recovery: back up `~/.config/roundhouse/identity.yaml`, never
delete it, then re-add X from the hub with `fleet-add`. That flow performs the
host bootstrap, clones the published hub store, fetches the enrollment head,
and seeds the host; do not run a second manual clone. If the roster commit was
already published but the fetch or seed stopped, use the printed recovery:
run `fleet-verify-remote`, fetch the published enrollment head, rerun
`fleet-seed`, then `fleet-run`. Do not hand-edit or force the abandoned ref.

## Boundaries

- One host per invocation; a fleet-wide sweep is `fleet-readiness` /
  `fleet-agents` territory.
- Never generate SSH keys anywhere but the host they identify; never move a
  private key between machines; the CSR is public-only by construction.
- Privilege enrollment always gets its own explicit consent naming the exact
  host, even inside a larger add flow: it is the one OS prompt, and nothing
  else in the lifecycle needs one.
- `railyard:setup` delegates per-host work here during first-run setup;
  this skill is also directly invocable any time after.
