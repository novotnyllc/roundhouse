# AGENTS.md

## Charter

Roundhouse keeps the machines and infrastructure serviceable — the shop where
the engines are maintained so the yard can run them. It never decides, routes,
or executes delivery work; it makes sure every host and device is ready when
work arrives.

**Belongs here:** administering the operator's own machines and
infrastructure —

- *Readiness* — `fleet-readiness` synthesizes go/no-go from the narrow skills
  below; it is what `railyard:orchestrate` consults before dispatch.
- *Host lifecycle* — `fleet-hosts` adds or removes one machine end to end
  (config, certificate enrollment/revocation, target prerequisites,
  readiness); `railyard:setup` delegates here during onboarding.
- *Inventory and parity* — `fleet-inventory` (read-only snapshots),
  `fleet-agents` (harness runtimes, plugins, skills, capabilities),
  `fleet-projects` (checkouts and saved projects), `fleet-auth` (credential
  artifacts).
- *Baselines* — `fleet-update` (packages and tools such as tmux and jq),
  `fleet-chezmoi` (dotfiles).
- *Transport* — SSH enrollment and certificates, `remote-mac`, `ssh-doctor`,
  and the Codex remote-control contract in
  `plugins/roundhouse/references/codex-remote-control.md`.
- *Privileged lanes* — the narrow, enrolled broker paths for privileged
  installs (POSIX sudoers broker, Windows SFTP slots, logged-off profile
  work).
- *Network gear* — `unifi-network-api`.

**Belongs elsewhere:** deciding what work runs and where
([`railyard`](https://github.com/novotnyllc/railyard) owns routing,
delivery, orchestration, placement, and review gates — Roundhouse's dispatch
contracts require its `railyard/model-routing/v1` router and feed its
placement decisions); craft skills
([`agent-utilities`](https://github.com/novotnyllc/agent-utilities)).

## Fleet Rules

- Read inventory from `ROUNDHOUSE_CONFIG`, then
  `${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json`.
- Default to audit/report mode. Mutations require an explicit user request,
  target resolution, identity verification, preflight, and post-change checks.
- Reuse existing chezmoi and package-manager commands instead of
  reimplementing them.
- Do not hard-code maintainer-local secrets, host names, vault names, or
  machine inventory.
- Keep fleet-aware SSH diagnosis and remote-machine mechanics in this plugin.

## Release Coupling

When changing the plugin version, update:

- `plugins/roundhouse/.codex-plugin/plugin.json`
- `plugins/roundhouse/.claude-plugin/plugin.json`
- run `plugins/roundhouse/scripts/update-integrity`
- `<marketplace-repo>/.agents/plugins/marketplace.json`
- `<marketplace-repo>/.agents/plugins/plugin-versions.json`
- `<marketplace-repo>/.claude-plugin/marketplace.json`

Never treat an installed plugin cache as the source repository.

Documentation-only changes (`docs/**`, `README.md`) need no version bump,
no integrity regeneration, no marketplace repin, and no fleet
redeploy/convergence pass — commit and push them directly. Only changes
under `plugins/` couple to the release machinery above.

## Skill Editing Rules

- Keep skills usable by both Codex and Claude Code.
- Validate JSON manifests and skill frontmatter before committing.
