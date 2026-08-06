# Transports and privileged lanes

Keep fleet-aware SSH diagnosis and remote-machine mechanics in this plugin —
they are Roundhouse's job, not a caller's.

## Transport

- SSH enrollment and certificates (`fleet-hosts`, `certify-ssh-node`,
  `enroll-ssh-posix`, `prepare-ssh-identity`).
- `remote-mac` for remote-machine mechanics, `ssh-doctor` for diagnosis.
- The Codex remote-control contract:
  [`plugins/roundhouse/references/codex-remote-control.md`](../../plugins/roundhouse/references/codex-remote-control.md).

## Privileged lanes

Narrow, enrolled broker paths carry the few operations that need privilege —
never `sudo` sprinkled through scripts:

- POSIX sudoers broker (`enroll-privilege-posix`,
  `privilege-broker-posix`).
- Windows SFTP slots
  ([`plugins/roundhouse/references/windows-sftp.md`](../../plugins/roundhouse/references/windows-sftp.md))
  and logged-off profile work.

Every mutation on these lanes rides the sealed-plan pipeline described in the
root `AGENTS.md`.
