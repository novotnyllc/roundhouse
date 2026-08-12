# Charter and boundaries

Roundhouse keeps the machines and infrastructure serviceable — the shop where
the engines are maintained so the yard can run them. It never decides,
routes, or executes delivery work; it makes sure every host and device is
ready when work arrives.

## Belongs here

Administering the operator's own machines and infrastructure —

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
- *Transport and privileged lanes* — see
  [transports](transports.md).
- *Network gear* — `unifi-network-api`.

## Belongs elsewhere

Deciding what work runs and where:
[`railyard`](https://novotnyllc.github.io/) owns routing, delivery,
orchestration, placement, and review gates — Roundhouse's dispatch contracts
require its `railyard/model-routing/v1` router and feed its placement
decisions. Craft skills are maintained outside Roundhouse.

Scope discipline inside the plugin follows the same rule: reuse existing
chezmoi and package-manager commands instead of reimplementing them.
