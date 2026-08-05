# Roundhouse

Machine and infrastructure administration for agent fleets. In a rail yard,
the roundhouse is where locomotives are serviced and kept ready to run — the
yard doesn't move a train the shop hasn't cleared.

This plugin (for Codex and Claude Code) keeps the operator's machines and
infrastructure serviceable:

| Bay | Skills |
| --- | --- |
| Readiness | `fleet-readiness` — the go/no-go the dispatcher consults |
| Inventory & parity | `fleet-inventory`, `fleet-agents`, `fleet-projects`, `fleet-auth` |
| Baselines | `fleet-update` (packages/tools), `fleet-chezmoi` (dotfiles) |
| Transport | `remote-mac`, `ssh-doctor`, SSH certificate enrollment, the Codex remote-control contract |
| Privileged lanes | enrolled POSIX/Windows brokers for narrow privileged installs |
| Network gear | `unifi-network-api` |

Work routing and delivery live in the sibling
[`yardmaster`](https://github.com/novotnyllc/yardmaster) plugin; craft skills
in [`agent-utilities`](https://github.com/novotnyllc/agent-utilities). See
[AGENTS.md](AGENTS.md) for the charter, the belongs-here/belongs-elsewhere
rules, and the legacy `machine-utilities` executor namespace notes.
