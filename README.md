<img src="docs/assets/roundhouse.png" alt="Roundhouse" width="150" align="right"/>

# Roundhouse

**Your machines, always ready for agent work.**

Roundhouse keeps a fleet of machines serviceable for AI agents — for both
Codex and Claude Code. It knows what every host has installed, keeps
harnesses, plugins, packages, and dotfiles in sync, enrolls new machines with
one guided flow, and answers the only question a dispatcher cares about:
*is this host ready to receive work?*

- ➕ **Add a machine in one flow.** `fleet-hosts` takes a box from SSH alias
  to enrolled, provisioned, and readiness-verified — certificate ceremony,
  prerequisites, plugins — with consent at every trust step.
- 🔄 **Drift, found and fixed.** Inventory and parity checks across every
  host: runtime versions, plugins, skills, auth, packages, dotfiles.
- 🔐 **Privilege, narrowly.** Signed, enrolled broker lanes for the few
  privileged operations that need them — never `sudo` sprinkled in scripts.
- 🚉 **The dispatcher's go/no-go.** `fleet-readiness` is what
  [yardmaster](https://github.com/novotnyllc/yardmaster) consults before
  placing work on a host.

```sh
claude plugin marketplace add novotnyllc/marketplace
claude plugin install roundhouse@novotnyllc
# then: "add my laptop to the fleet"
```

(Codex: `codex plugin add roundhouse --marketplace novotnyllc`.)

**Read the [user guide](docs/guide.md)** — the fleet config, the enrollment
ceremony, transports, and how readiness feeds dispatch, with diagrams.

## What's inside

In a rail yard, the roundhouse is where locomotives are serviced — the yard
doesn't move a train the shop hasn't cleared:

| Bay | Skills |
| --- | --- |
| Readiness | `fleet-readiness` — the go/no-go the dispatcher consults |
| Host lifecycle | `fleet-hosts` — add/remove a machine end to end |
| Inventory & parity | `fleet-inventory`, `fleet-agents`, `fleet-projects`, `fleet-auth` |
| Baselines | `fleet-update` (packages/tools), `fleet-chezmoi` (dotfiles) |
| Transport | `remote-mac`, `ssh-doctor`, SSH certificate enrollment, the Codex remote-control contract, the signed `windows-sftp` lane |
| Network gear | `unifi-network-api` |

## The family

Work routing and delivery live in
[`yardmaster`](https://github.com/novotnyllc/yardmaster); craft skills in
[`agent-utilities`](https://github.com/novotnyllc/agent-utilities). Charter,
boundaries, and the legacy executor-namespace notes:
[AGENTS.md](AGENTS.md).
