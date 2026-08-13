# AGENTS.md

Roundhouse administers the operator's own machines and infrastructure:
readiness, inventory, parity, packages, dotfiles, auth, SSH transport,
privileged installs. Plugin source lives under
`plugins/roundhouse/`; everything else is documentation.

## Always

- Default to audit/report mode. Every mutation rides the sealed-plan pipeline
  (explicit user request, target resolution, identity verification,
  preflight, post-change checks).
- Read inventory from `ROUNDHOUSE_CONFIG`, then
  `${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json`.
- Do not hard-code maintainer-local secrets, host names, vault names, or
  machine inventory.
- Never treat an installed plugin cache as the source repository.

## Verify

```sh
plugins/roundhouse/scripts/update-integrity
git diff --exit-code -- plugins/roundhouse/integrity.json
plugins/roundhouse/scripts/test-roundhouse   # must print PASS
```

That is the core of CI. The full gate list — `bash -n`, shellcheck, the
per-script `self-test` convention, skill frontmatter, the `chmod -R go-w`
prerequisite, and the Windows job — is in
[verification](docs/agents/verification.md).

## Deeper

- [Charter and boundaries](docs/agents/charter.md) — what belongs here,
  what belongs in `railyard` or `agent-utilities`
- [Verification](docs/agents/verification.md) — every CI gate, reproduced
  locally
- [Release coupling](docs/agents/release-coupling.md) — version bump,
  integrity, repin, docs-only exemption
- [Transports and privileged lanes](docs/agents/transports.md) — SSH,
  remote-control contract, brokers
