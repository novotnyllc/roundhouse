# Fleet hosts

Fleet Hosts owns the lifecycle of one fleet member at a time — adding a
machine end to end (config entry, SSH reachability, certificate identity,
target prerequisites, and a readiness proof), or removing one cleanly with
trust actually revoked, not just deleted from a file. Every mutating step
names its target and gets its own explicit consent; nothing about signing
trust or granting privilege is ever batched into silence.

## When to use it

- "Add my laptop to the fleet."
- "Onboard the new Linux box, it'll take delivery work."
- "Decommission that old Mac mini, it's retired."
- "Restore my machine from the sync store after a reinstall."
- Setting up a new fleet from scratch — `railyard:setup` delegates
  per-host work here during first-run setup, and this skill is also
  directly invocable any time after.

## How it works

### Add a host

You're asked for: display name; SSH alias (must already resolve in
`~/.ssh/config` — never invented); platform (detected via `ssh <alias>
uname -s` if you don't say); transport (`ssh`, or `codex-remote-control`
only for a native-Windows destination); groups (none by default). For a
Windows machine, you're also asked whether WSL runs on the same hardware
(and vice versa) — paired entries share a `physical_host` value, and the
Windows entry sets `wsl_interop_via: <wsl-entry-name>` so later
maintenance can use the WSL interop lane.

1. **Reachability** — `ssh -o BatchMode=yes <alias> 'echo ok'` through the
   login shell. Nothing else proceeds until this passes; `ssh-doctor`
   fixes macOS sshd faults first if it doesn't.
2. **Config entry** — added to
   `${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json` (scaffolded
   from the plugin's `config.example.json` if the file doesn't exist yet),
   with `roundhouse validate-config` required to pass.
3. **SSH certificate enrollment** (consent) — a three-step ceremony, each
   step on its proper node: `prepare-ssh-identity` on the new host
   generates its key and a public-only CSR; `certify-ssh-node` signs that
   CSR in an owner ceremony on the signing node — its own consent, since
   this is the step that mints trust; then `enroll-ssh-posix install`
   followed by `verify` places the fleet CA and the revocation list (KRL)
   on the target. Raw `authorized_keys` edits are never a shortcut here.
4. **Prerequisites on the target** (consent, via the target's own package
   managers) — `tmux` and `jq` through
   [`fleet-update`](fleet-update.md); agent harness verification and
   plugin/marketplace parity through
   [`fleet-agents`](fleet-agents.md)'s routine refresh; project checkouts
   through [`fleet-projects`](fleet-projects.md) if the host will take
   delivery work.
5. **Optional store credential** (separate consent; only if the host is
   opting into desired-state sync) — a minimal credential scoped to the
   sync store's remote alone: an SSH deploy key generated on the host and
   kept in `~/.ssh`, or a token in a credential helper. It's **never**
   embedded in the remote URL — a URL-embedded token replicates into
   config, logs, and every error message from then on. These are
   crown-jewel secrets: the store is a trusted-write surface reachable
   from every fleet machine, so a leaked store credential is a
   fleet-wide problem.
6. **Optional privilege enrollment** (separate consent; skipped by
   default) — `enroll-privilege-posix`, or on Windows
   `enroll-windows-sftp.ps1` / `enroll-privilege-windows.ps1`, only if the
   host needs the privileged install lane.
7. **Verify** — finishes by handing off to
   [`fleet-readiness`](fleet-readiness.md) for the new host and reporting
   its go/no-go table. A host isn't "added" until readiness confirms it.

### Remove a host

Order matters — clean up over SSH while access still works, then revoke:

1. **Target-side cleanup** (consent) — while still enrolled: check for and
   handle any live work (worktrees, running sessions) before touching
   anything; optionally uninstall the fleet plugins; remove enrolled
   artifacts through the enroll scripts' own uninstall/revoke paths, never
   by raw deletion of the protected trees.
2. **Revoke trust** — generate the updated owner KRL (its own owner-side
   ceremony), tear down the departing host's enrollment with
   `enroll-ssh-posix preview-revoke` then `revoke`, then deliver the new
   KRL to *every remaining* fleet host with `enroll-ssh-posix repair` —
   not just the one leaving. The store credential is revoked in the same
   step as SSH trust, so a decommissioned machine loses store write access
   exactly when it loses SSH access. Privilege enrollment, if present, is
   revoked the same way.
3. **Config removal** — delete the machine entry, re-run `roundhouse
   validate-config`, and drop the host from any groups it belonged to.
4. **Report** — if the entry shared a `physical_host` with others, that's
   called out (removing one environment doesn't remove the hardware or
   its siblings). The report states what was removed, what was revoked,
   and any state deliberately left behind — an unenrolled box keeps its
   own harnesses and user data; that's expected, and it's named rather
   than implied away.

### Restore a host

Restoring host X is *configs plus a shopping list*, not a machine image —
the store can't restore secrets, per-machine auth, or SSH identity. Read
the full delta before touching anything, then in order: re-enroll X
through the add-a-host flow (a fresh SSH certificate ceremony, since the
old identity is gone with the disk); run `roundhouse fleet-reconstitute X`
from any enrolled host — one commit that records the rebuild in `lineage/`,
installs X's new node key, retires the old entry, and reparents anything
the old X sponsored; then let the fast run converge X from the store,
where every file-carried surface (skills, agents, hooks, allowlisted
config keys) and every plugin pin is desired state it already replicates
and `applied/X.yaml` is adopted in place rather than mass-disowned. Then
work the auth shopping list by hand, since every credential is
re-established on X manually.

## Boundaries

- One host per invocation — a fleet-wide sweep belongs to
  [`fleet-readiness`](fleet-readiness.md) / [`fleet-agents`](fleet-agents.md).
- Never generates an SSH key anywhere but the host it identifies, and
  never moves a private key between machines — the CSR that travels is
  public-only by construction.
- Signing (`certify-ssh-node`) and privilege enrollment always get their
  own explicit consent naming the exact host, even inside a larger add
  flow — they're never folded into a single "yes" for the whole
  onboarding.
- Doesn't decide package drift, plugin parity in depth, or auth repair
  itself — it hands those off to `fleet-update`, `fleet-agents`, and
  `fleet-auth` as prerequisites, then verifies through `fleet-readiness`.

## Example session

> **You:** "Add my Linux dev box, alias `linux-dev` in my SSH config,
> to the development group."
>
> **What happens:** the agent confirms `ssh -o BatchMode=yes linux-dev
> 'echo ok'` works, adds the machine entry to `config.json` and validates
> it, then walks the SSH certificate ceremony with you — key generation on
> `linux-dev`, signing on your trusted node, install and verify on the
> target. It installs `tmux`/`jq` and checks agent-harness parity, asks
> whether you want a store credential for sync, and finishes by running
> `fleet-readiness` for `linux-dev` and reporting the go/no-go table. The
> host counts as added only once that table says so.
