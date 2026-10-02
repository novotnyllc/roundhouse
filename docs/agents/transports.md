# Transports and privileged lanes

Keep fleet-aware SSH diagnosis and remote-machine mechanics in this plugin —
they are Roundhouse's job, not a caller's.

## Transport

- SSH enrollment and certificates (`fleet-hosts`, `certify-ssh-node`,
  `enroll-ssh-posix`, `prepare-ssh-identity`).
- `remote-mac` for remote-machine mechanics, `ssh-doctor` for diagnosis.
- The WSL interop lane to native Windows (`collect`, `apply-interop-plan`):
  SSH to the `wsl_interop_via` sibling, launch the installed, verified
  Windows executor natively. Described in the remote-control reference.
- The Codex remote-control contract:
  [`plugins/roundhouse/references/codex-remote-control.md`](../../plugins/roundhouse/references/codex-remote-control.md).

## Privileged lanes

Narrow, enrolled paths carry the few operations that need privilege — never
`sudo` sprinkled through scripts:

- The default **privilege lane** (`privilege-lane-posix`, `lib/lane.sh`;
  Linux and WSL in this version, macOS and Windows designed and deferred):
  one OS approval per host via `roundhouse privilege-enroll HOST`, then a
  root-owned helper behind an owner-only queue, reached over the host's
  ordinary transport. Closed semantic apt catalog, digest-bound requests,
  journaled results.
  Design: [`docs/specs/2026-10-01-hands-off-privilege-lane.md`](../specs/2026-10-01-hands-off-privilege-lane.md).
- The optional CA-certificate lane, selected only by an explicit
  `automation_transport`: POSIX sudoers broker (`enroll-privilege-posix`,
  `privilege-broker-posix`) and Windows SFTP slots
  ([`plugins/roundhouse/references/windows-sftp.md`](../../plugins/roundhouse/references/windows-sftp.md)).

Every mutation on these lanes rides the sealed-plan pipeline described in the
root `AGENTS.md`.
