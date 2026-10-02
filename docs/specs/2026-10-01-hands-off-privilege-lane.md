# Hands-off privilege lane — design

Status: implemented in this change (v1) · 2026-10-01
Owner: roundhouse (lane helpers, controller library, fleet-run, readiness)

## Purpose

Roundhouse needs root on macOS/Linux/WSL and LocalSystem on Windows for a
small, fixed set of package operations: apt metadata/upgrade/install,
winget machine-scope install/upgrade, and signed macOS package installs.
Until now every one of those sat behind an owner ceremony: an offline fleet
CA, node certificates, a signer account with a native-isolation receipt, a
Windows SFTP request account, CMS-signed controller intents, and a human
preview/confirm/verify loop per generation. Nobody can run that, so nothing
privileged ever runs.

This design replaces it with a **local privilege lane**: after exactly one
OS approval per host — a single `sudo` password on POSIX, a single UAC
consent on Windows, both triggered by Roundhouse during onboarding or the
first time privilege is needed — every privileged action the fleet needs
runs unattended, including upgrades of the lane itself. No ceremony, no
PKI, no recurring human step.

The previous CA/SFTP lane stays in the tree as an optional high-assurance
mode behind an explicit `privilege_broker.automation_transport`
configuration. It is not the default and no skill tells a user to perform
its ceremonies.

## Trust model, stated plainly

Per host, the lane trusts **the owning user**. Anything that can run as that
user (an SSH session, an agent, a scheduled task, malware with the user's
token) can ask the lane to perform any of its allowlisted actions. The lane
does not try to distinguish "the user" from "a process the user runs"; the
offline CA that used to make that distinction is the thing being removed.

What the lane still guarantees:

- **Closed action set.** A request names one semantic action from a fixed
  per-platform catalog plus a package token and a version. There is no
  argv, no shell, no path, no environment, no installer selector in a
  request. The root/SYSTEM side builds every native command itself.
- **Owner-only ingress.** Requests are files in a queue whose ingress
  directory only the enrolled owner can write (0700 owner-owned on POSIX;
  owner-SID Modify / SYSTEM-BA Full on Windows). The privileged side
  authenticates a request by the file's owner (uid / SID), not by its
  content, and binds the enrolled owner identity at enrollment time.
- **Digest-bound.** Each request carries the sealed plan id, plan digest and
  operation index it came from, and ends with a digest over its own lines.
  Results and journal entries repeat those values, so a result can be
  matched to a sealed plan after the fact and a truncated or edited request
  is refused.
- **Freshness, replay, size, rate.** `created-at` must be within 10 minutes,
  `expires-at` within one hour, a request id can be claimed once ever
  (claims are kept for the retention window; a replay is journaled and
  dropped without touching the original result), a request file is at most
  8 KiB, and at most 32 requests are claimed — executed or rejected — per
  rolling hour per host.
- **Journaled, tamper-evident results.** The privileged side keeps a
  root-only claim directory and append-only journal; results published to
  the owner carry the lane's own digest of the result lines and of the
  request they answer.
- **Root never executes owner-owned bytes except at enrollment and at
  self-upgrade**, and both copy to a root-owned temporary file and hash
  that copy before use.

What it gives up, honestly: a compromised owner session can install any
package the configured sources offer at machine scope, run apt metadata
refreshes, and — through self-upgrade — replace the lane's root-owned
script with any file that is accompanied by a self-consistent
`integrity.json` claiming to be a newer Roundhouse release. That last item
is the sharpest edge; see "Residual risks".

## Per-platform mechanism

### POSIX (macOS, Linux, WSL): sudoers exact-binary grant

The one approval installs, as root:

| Path | Owner / mode | Content |
| --- | --- | --- |
| `/usr/local/libexec/roundhouse-lane/privilege-lane` | root 0755 | root-owned copy of `scripts/privilege-lane-posix` |
| `/usr/local/libexec/roundhouse-lane/lane.identity` | root 0644 | `lane-identity\|1` record (owner uid/name, host id, platform, plugin root, marketplace, version, digest) |
| `/etc/sudoers.d/roundhouse-lane` | root 0440 | `OWNER ALL=(root) NOPASSWD:NOSETENV: /usr/local/libexec/roundhouse-lane/privilege-lane dispatch` |
| `/var/lib/roundhouse-lane/ingress` | owner 0700 | request files |
| `/var/lib/roundhouse-lane/claims` | root 0700 | one directory per claimed request |
| `/var/lib/roundhouse-lane/results` | root 0755 / files 0644 | `request-<id>.result` |
| `/var/lib/roundhouse-lane/journal` | root 0700 | `events.log` |

A requester writes `ingress/request-<id>.request`, then runs
`sudo -n /usr/local/libexec/roundhouse-lane/privilege-lane dispatch`. The
root process drains the queue: each file is moved (same filesystem rename)
into the root-only claims directory before it is read, so the owner cannot
swap it after validation starts; symlinks, hard links, wrong owner,
oversize, malformed, stale, replayed or rate-limited requests are rejected
with a result that says why. The requester polls `results/`.

Why sudoers rather than a resident root daemon on every POSIX platform:

- The lane is pull-based. A request exists only because a Roundhouse process
  is running as the owner at that moment, so there is nothing for a
  logged-off daemon to do; a LaunchDaemon/systemd service would add a
  resident root process, log rotation and unit lifecycle for no
  functional gain.
- One mechanism covers macOS, Linux and WSL (where systemd is often not
  PID 1). The grant is a single readable line naming one root-owned binary
  and one fixed argument; `visudo -cf` checks it before it is installed
  and the enrollment canary proves that any other argument is refused.
- It is the shape the previous POSIX broker already proved on this fleet.

### Windows: LocalSystem scheduled task over an owner-writable queue

The one UAC consent installs:

| Path | ACL | Content |
| --- | --- | --- |
| `C:\ProgramData\Roundhouse-Lane\` | SYSTEM F, BA F, owner RX | root |
| `…\privilege-lane-windows.ps1` | SYSTEM F, BA F, owner R | SYSTEM-owned copy |
| `…\lane.identity` | SYSTEM F, BA F, owner R | identity record |
| `…\queue\ingress\` | SYSTEM F, BA F, owner Modify | request files |
| `…\queue\results\` | SYSTEM F, BA F, owner R (list, read) | results |
| `…\claims\`, `…\journal\` | SYSTEM F, BA F, owner READ_CONTROL (directory only, no inheritance) | claims and journal; the owner can read the descriptor to verify it, nothing inside |
| `…\winget\Microsoft.WinGet.Client\` | SYSTEM F, BA F, owner R | pinned WinGet client module |
| task `\RoundhouseLaneV1` | `O:SYG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;OWNER)` | LocalSystem, ServiceAccount logon, PT1M repetition, StartWhenAvailable |

The task runs `pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
-File C:\ProgramData\Roundhouse-Lane\privilege-lane-windows.ps1 -Dispatch`
(the lane script is not Authenticode-signed; the SYSTEM-only ACL on the copy
and the digest check against `lane.identity` on every dispatch stand in)
as **LocalSystem**: no user token, no S4U, no stored password, no
dependency on a domain controller or on the account type (Entra ID-joined
accounts are fine because the task principal is `S-1-5-18`, never the user).
The owner SID is granted read + execute on the task so the requester can
start it immediately with `schtasks.exe /Run /TN RoundhouseLaneV1`; the
one-minute repetition is the fallback if that right is ever stripped.

The requester is the existing ordinary lane: SSH into the WSL sibling, write
`/mnt/c/ProgramData/Roundhouse-Lane/queue/ingress/request-<id>.request`
(drvfs performs the write as the Windows user who owns the WSL session, so
the NTFS owner is the enrolled SID), run `schtasks.exe` through interop, and
poll `/mnt/c/ProgramData/Roundhouse-Lane/queue/results/`. No SFTP, no
`RoundhouseRequest` account, no certificate.

WinGet under LocalSystem cannot use `winget.exe` (the App Installer package
is per-user and absent from session 0), so the lane does what the previous
broker did: it installs the pinned `Microsoft.WinGet.Client` PowerShell
module from `references/windows-winget-provider.lock` (package hash, file
set and Microsoft Authenticode checked) at enrollment and calls
`Find-/Get-/Install-/Update-WinGetPackage -Scope System` in-process.

#### User-scope work and the interop token

Anything that must run **as the user** — user-scope winget packages, fnm
and Node globals, profile/agent configuration — stays in the ordinary
interop lane under the user's own logged-on session token. The S4U profile
task (`register-profile-task-windows.ps1`, `profile-worker-windows.ps1`)
is deprecated with this change: S4U cannot be used for Entra ID-only
accounts, and the interop lane already covers everything the profile task
did. User-scope work therefore requires an active user session, which the
WSL interop lane already requires; readiness reports
`user_session_unavailable` when the sibling is unreachable rather than
falling back to any other identity.

The observed winget behaviour from the interop lane — user-scope upgrades
refused with `APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED` while
some machine-scope installers ran with no visible prompt — is explained by
the token the interop process inherits. Processes launched through WSL
interop run under the token of the Windows process that started the WSL
session, which may be an **elevated** token, and winget refuses user-scope
installs or upgrades (for example portable packages) from an elevated
context so they do not land in the admin's profile. The same elevated token
is why machine-scope installers succeeded without a prompt. This change
makes the split explicit: machine-scope work goes to the LocalSystem lane,
user-scope work goes to the interop lane, and
`privilege-lane-windows.ps1 -Status` reports whether the interop token is
elevated; the controller maps `interop-token|elevated` to
`user_session_unavailable`, because requests written under that token are
owned by Administrators and refused, so a WSL session launched from an
elevated shell is reported for what it is instead of surfacing as an
unexplained winget error.

## Request and result records

Both are canonical ASCII (0x20–0x7e plus LF, one trailing LF, no CR),
fixed field order, header and trailer, one `name|value` per line.

```text
lane-request|1
request-id|request-<32 hex>
host-id|<machine name from config>
owner|<uid on POSIX | SID on Windows>
plan-id|<plan-… or fleet-run token>
plan-sha256|<64 hex or ->
operation-index|<uint or ->
action-id|<catalog action>
package|<package token or ->
version|<version token or ->
source|<winget source | Developer ID team id | ->
payload-sha256|<64 hex or ->
created-at|<unix seconds>
expires-at|<unix seconds>
end-request|
request-sha256|<sha256 of every line above>
```

```text
lane-result|1
request-id|…
plan-id|…
plan-sha256|…
operation-index|…
action-id|…
package|…
version|…
state|completed|rejected|failed|partial
reason|<token>
native-exit|<int or ->
pre-state-sha256|<64 hex or ->
post-state-sha256|<64 hex or ->
started-at|<unix seconds>
finished-at|<unix seconds>
lane-version|<plugin version>
lane-sha256|<sha256 of the privileged script>
request-sha256|<the request digest this answers>
end-result|
result-sha256|<sha256 of every line above>
```

`state|partial` means the native command ran but the post-state check did
not confirm the expected outcome; the requester never infers success from
it.

## Action catalog (v1)

| Action | Platform | Request fields | Native effect | Post-state |
| --- | --- | --- | --- | --- |
| `apt.update-metadata.v1` | linux, wsl | — | `apt-get -q update` | metadata digest changed or unchanged, both reported |
| `apt.upgrade-package.v1` | linux, wsl | package, version | `apt-get -q -y --no-remove --only-upgrade install PKG=VER`, only when `apt-cache policy` names VER as the candidate and PKG is installed below it | `dpkg-query` version equals VER |
| `apt.install-package-version.v1` | linux, wsl | package, version or `-` | `apt-get -q -y --no-install-recommends install PKG[=VER]` | PKG installed (at VER when given) |
| `apt.autoremove.v1` | linux, wsl | — | `apt-get -q -y autoremove` | simulate reports nothing left |
| `macos.install-signed-pkg.v1` | macos | package (pkg id), version, source (Team ID), payload-sha256 | copy owner-staged payload into the claim, verify digest, `pkgutil --check-signature` Developer ID Installer with the given Team ID, expanded `PackageInfo` identifier/version match, no scripts; `installer -pkg … -target /` | `pkgutil --pkg-info` version equals VER |
| `winget.inventory-machine.v1` | windows | — | `Get-WinGetPackage` machine-scope listing | — |
| `winget.install-machine-package.v1` | windows | package (id), version or `-`, source | `Install-WinGetPackage -Scope System -Mode Silent` | installed version equals VER |
| `winget.upgrade-machine-package.v1` | windows | package (id), version, source | `Update-WinGetPackage -Scope System -Mode Silent` when installed < VER and VER is available | installed version equals VER |
| `lane.probe.v1` | all | — | nothing | identity reported |
| `lane.self-upgrade.v1` | all | version, payload-sha256 | see below | identity reports the new version |

Node runtime operations need no elevation on any platform in this fleet
(fnm is user-space; winget `OpenJS.NodeJS` is an ordinary machine-scope
winget action), so no Node-specific action exists.

Homebrew cask steps that reach Homebrew's hard-coded `sudo` are **not** in
v1. The bridge hook that routed them through the old broker depended on
per-payload owner enrollment; routing them through
`macos.install-signed-pkg.v1` is the intended follow-up and is listed under
"Deferred".

## Self-upgrade

`lane.self-upgrade.v1` carries the target plugin version and the SHA-256 of
the lane script at that version. The privileged side:

1. Reads `plugin-root` and `marketplace` from its own `lane.identity`
   (recorded at enrollment from the installed plugin cache, e.g.
   `~/.claude/plugins/cache/novotnyllc/roundhouse`).
2. Requires `<plugin-root>/<version>/integrity.json` to parse as a
   Roundhouse integrity manifest whose `plugin`, `marketplace` and
   `version` fields match, and copies every listed file's digest and the
   candidate script into a root-owned temporary directory before hashing —
   the owner-owned tree is never read twice.
3. Requires the candidate script's digest to equal both the manifest entry
   and the request's `payload-sha256`, and `version` to sort strictly above
   the installed lane version (anti-rollback).
4. Runs `bash -n` on the candidate, installs it atomically over the
   root-owned path, rewrites `lane.identity`, and journals the change.

Trust check, stated honestly: `integrity.json` is produced by the release
and verified byte-for-byte, but it is not signed. The pinned marketplace and
plugin names and the monotonic version are what stop an accidental
downgrade or a stray plugin; they do not stop the owner (or anything running
as the owner) from fabricating a plugin directory and upgrading root's copy
of the lane with arbitrary code. That is the same authority the owner
already holds through the queue — the lane never claimed to protect root
from its owner — but it means self-upgrade is the single most valuable
target in the design. Mitigations in v1: the candidate must sit under the
plugin root recorded at enrollment, the version must be strictly newer, the
install is journaled with before/after digests, and `fleet-doctor` reports
the installed lane version and digest on every host so a divergence from
the fleet's released version is visible.

## Enrollment: one approval, triggered by Roundhouse

`roundhouse privilege-enroll HOST` is the single command. It never asks for,
relays or stores a password or administrator credential.

| Platform / transport | What happens | The one human action |
| --- | --- | --- |
| macOS / Linux / WSL, `transport: local` | `sudo -p … scripts/privilege-lane-posix enroll --host-id HOST --owner $(id -un) --plugin-root …` | type the sudo password in the terminal running the command |
| macOS / Linux / WSL, `transport: ssh` | `ssh -t ALIAS "sudo -p … \"\$(roundhouse privilege-lane-path)\" enroll …"` | same, over the forwarded TTY |
| Windows with `wsl_interop_via` | through the WSL sibling: `pwsh.exe -File <installed plugin>\scripts\privilege-lane-windows.ps1 -Enroll -HostId HOST`, which re-launches itself elevated with `Start-Process -Verb RunAs` | click **Yes** on the UAC consent dialog that appears on the console |

When the command runs without a terminal (an agent, a scheduled run) it does
not attempt the prompt: it prints the exact command for the owner, exits 75,
and readiness reports `needs_one_time_approval` naming the host. Windows is
the exception where the agent may trigger the prompt itself, because UAC
consent is a GUI dialog on the console and not a terminal interaction; if
no interactive session is available the enrollment reports
`user_session_unavailable` and nothing is installed.

The enrollment is one transaction: layout (parents created 0755 and the
whole directory chain required to be root-owned and not group/world
writable, since the grant trusts the path), identity, grant/task, module (on
Windows) and a canary that proves (a) the requester can reach the privileged
side, (b) any other sudo argument is refused — an owner who already holds a
broader passwordless grant is recorded as `broad-sudo-present` rather than
refused, and (c) a `lane.probe.v1` request completes end to end. On Windows
the probe is submitted by the unelevated launcher after the elevated child
returns, because a file created under the elevated token is owned by
Administrators and the dispatcher would refuse it. Any failure before the
canary passes rolls the installed pieces back on POSIX (an EXIT trap) and
reports `needs_one_time_approval` again. Windows activates in two halves
instead: the elevated child installs with `activation|pending`, status
reports `canary_pending`, the dispatcher executes nothing but
`lane.probe.v1`, and the owner's own probe flips the identity to `passed`.
A failed probe therefore leaves nothing enabled, and re-running
`privilege-enroll` on a pending lane at the same version submits only the
probe — no second consent.

## Readiness and the scheduled run

- `fleet-readiness` adds a `privilege-lane` row per host:
  `ready`, `needs_one_time_approval` (with the exact command),
  `user_session_unavailable` (Windows: the WSL sibling is unreachable or
  the interop token is elevated), `disabled` (`privilege_lane: "disabled"`
  in the machine entry), `legacy` (an explicit `automation_transport`
  route is configured), `unreachable`, or `drifted`. The row is a finding
  only when the lane is enrolled and broken; a host that is merely not yet
  enrolled is reported as **pending** and does not block ordinary work.
- `fleet-doctor` reports the same state plus the installed lane version and
  digest for the local host.
- `roundhouse fleet-run` (both cadences) routes privileged package work
  through the lane **automatically** when the host is enrolled: the fast
  pass installs a missing apt package through `apt.install-package-version.v1`,
  and the full pass refreshes metadata then upgrades each unpinned apt
  package that `apt-cache policy` reports behind through
  `apt.upgrade-package.v1`. When the lane is not enrolled the run keeps the
  existing hold (`no privileged lane enrolled`) and raises one
  `privilege-lane` alert with the exact enrollment command; a scheduled run
  never prompts.
  Every such mutation is a sealed plan against the host itself
  (`lane_host_apply`: seal from a fresh snapshot, then apply with the full
  precondition — readiness and package versions — observed again
  immediately before submission); there is no unsealed root mutation.
- The controller's sealed-plan verbs (`privilege-status`,
  `verify-privilege-plan`, `submit-privilege-plan`,
  `lookup-privilege-result`) keep their names and file formats. For a host
  without a legacy route they dispatch through the lane: `privilege-status`
  reports the lane state as `privilege_broker` readiness,
  `submit-privilege-plan` writes one lane request per protected operation,
  and `lookup-privilege-result` reads the published result for an operation
  index without resubmitting.

## Deferred (not in v1)

- The sealed lane plan does not bind a payload digest yet, so the
  controller does not advertise `macos.install-signed-pkg.v1` or
  `lane.self-upgrade.v1`: both are implemented and fixture-tested on the
  host side (`privilege-lane-posix request … --payload`), but a plan naming
  them is refused at sealing until the format carries the digest and stages
  the bytes.

- Homebrew cask root steps on macOS through the bridge hook.
- fleet-run convergence of a native Windows sibling's winget packages: the
  scheduled run converges only the host it runs on; Windows machine-scope
  packages reach the lane through the controller's sealed plan.
- `lane.self-upgrade.v1` is implemented and tested on POSIX and Windows in
  fixture mode; wiring it into the fleet-run full cadence (upgrade the lane
  when the installed plugin version is newer than the enrolled lane version)
  is left for the follow-up that also pins the released digest fleet-wide.
- Revocation is `privilege-lane-posix revoke` / `-Revoke` (root/UAC, one
  approval); there is no remote revocation path by design.

## Residual risks

1. **Owner equals root authority for the allowlisted set.** Any process
   running as the owner can install or upgrade packages at machine scope
   and refresh apt metadata. Package *content* trust rests entirely on the
   configured sources (apt sources with their keyrings, the winget `winget`
   / `msstore` sources, Developer ID signatures), not on Roundhouse.
2. **Self-upgrade is unsigned.** See above. A signed release manifest would
   close it; until then the fleet-wide version/digest report is the
   detection control.
3. **Windows task start right.** The owner's `GRGX` on the task is believed
   sufficient for `schtasks /Run`; if a Windows build refuses it the lane
   still works on the one-minute repetition, at the cost of latency.
4. **drvfs ownership.** The design relies on files written through
   `/mnt/c` carrying the Windows user's SID as NTFS owner. The enrollment
   canary writes a probe request through the same path and refuses to
   report `ready` unless the dispatcher saw the expected owner.
5. **TOCTOU on request files is closed by rename-then-read, but the owner
   can still delete or replace results they can read.** Results are
   advisory to the owner; the root-only journal is the record.
6. **A stale `expires-at` clock skew of more than ten minutes between
   controller and host rejects every request.** This fails closed and is
   reported as `stale_request`.
7. **Fixture coverage.** The Windows task registration, ACL application,
   module download and WinGet cmdlets are exercised only through fixture
   stubs on macOS/Linux CI and the `-SelfTest` on the Windows CI job; the
   first real enrollment on `iris-windows` is the acceptance test for the
   Windows-only pieces.
