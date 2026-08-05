# AGENTS.md

## Charter

Roundhouse keeps the machines and infrastructure serviceable — the shop where
the engines are maintained so the yard can run them. It never decides, routes,
or executes delivery work; it makes sure every host and device is ready when
work arrives.

**Belongs here:** administering the operator's own machines and
infrastructure —

- *Readiness* — `fleet-readiness` synthesizes go/no-go from the narrow skills
  below; it is what `yardmaster:task-orchestrator` consults before dispatch.
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
([`yardmaster`](https://github.com/novotnyllc/yardmaster) owns routing,
delivery, orchestration, placement, and review gates — Roundhouse's dispatch
contracts require its `yardmaster/model-routing/v1` router and feed its
placement decisions); craft skills
([`agent-utilities`](https://github.com/novotnyllc/agent-utilities)).

## Legacy executor namespace

The fleet CLI ships as `scripts/machine-utilities`, and enrolled hosts keep
the `machine-utilities` system namespace
(`/usr/local/libexec/machine-utilities`,
`/etc/sudoers.d/machine-utilities-posix-broker`, `/etc/machine-utilities/ssh`,
`/var/lib/machine-utilities*`, `%ProgramData%\MachineUtilities`, the
`machine-utilities-windows` certificate principal, the
`machine-utilities-release` signing namespace, and the SSH forced-command
path). These are frozen at enrollment on every fleet host; renaming them is a
separate privileged re-enrollment migration, deliberately not part of plugin
renames. Everything plugin-side — skill names, `ROUNDHOUSE_*` environment
variables, `~/.config/roundhouse/` — uses the roundhouse name, and the CLI
falls back to a host's legacy `~/.config/machine-utilities/` files until that
host's config migrates.

## Fleet Rules

- Read inventory from `ROUNDHOUSE_CONFIG`, then
  `${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json` (legacy fallback:
  `machine-utilities/config.json`).
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

## Skill Editing Rules

- Keep skills usable by both Codex and Claude Code.
- Validate JSON manifests and skill frontmatter before committing.
