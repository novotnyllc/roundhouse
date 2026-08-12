# Using Roundhouse

<img src="assets/roundhouse.png" alt="Roundhouse" width="170" align="right"/>

Roundhouse keeps machines ready for agent work through inventory, readiness,
transport, and fleet convergence. The public site is the canonical guide for
the product story, installation, first-machine flow, and operating scenarios:

<https://novotnyllc.github.io/>

## Repo-local orientation

- Configuration: `${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json`,
  overridable with `ROUNDHOUSE_CONFIG`.
- Install: use the Claude Code or Codex commands in the public site's
  [installation guide](https://novotnyllc.github.io/start/install/).
- First machine: follow the public site's
  [first-machine guide](https://novotnyllc.github.io/start/first-machine/).
- Fleet operations: see the public site's
  [fleet section](https://novotnyllc.github.io/fleet/).
- Repository rules and local engineering references live in
  [`AGENTS.md`](../AGENTS.md), [`docs/agents/charter.md`](agents/charter.md),
  [`docs/agents/verification.md`](agents/verification.md),
  [`docs/agents/transports.md`](agents/transports.md), and
  [`docs/agents/release-coupling.md`](agents/release-coupling.md).

Roundhouse's source and plugin skills remain in this repository. The public
site is the reader-facing home for the human documentation.
