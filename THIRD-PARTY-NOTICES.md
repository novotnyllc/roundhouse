# Third-party notices

roundhouse incorporates the material below. This file is the licensing
record; the [public credits page](https://novotnyllc.github.io/railyard/credits/) is
the human-facing credit page.

Only *incorporated* material is listed — code or text copied or adapted into
this repository. The tools roundhouse drives (jj, git, OpenSSH, chezmoi,
Homebrew, APT, winget, Tailscale, ShellCheck, the harnesses) are runtime
dependencies, not incorporations, and carry no obligation here.

## Skills adapted from `steipete/agent-scripts` (MIT)

- **What:** `plugins/roundhouse/skills/remote-mac/SKILL.md` and
  `plugins/roundhouse/skills/ssh-doctor/SKILL.md`.
- **From:** https://github.com/steipete/agent-scripts —
  `skills/remote-mac` at commit
  `c46ea65b6323e8a2b6f441f8b6449ae731bc8f81`, and `skills/ssh-doctor` at
  commit `6e512e6fe0546471dfce5f48c9896c6ddce669cd`.
- **Copyright:** Copyright (c) 2026 Peter Steinberger.
- **License:** MIT — text in [`LICENSE`](LICENSE), where the upstream
  copyright notice is preserved alongside ours.
- **Modifications:** both are substantially condensed and rewritten around
  roundhouse's fleet registry, configured transports, and the Windows Codex
  Desktop lane. Each skill carries its own attribution line.

## UniFi Network API specification (unlicensed — see note)

- **What:**
  `plugins/roundhouse/skills/unifi-network-api/references/current-openapi.json`,
  a verbatim copy of the UniFi Network API OpenAPI 3.1.0 document, version
  `10.5.67`. Ships by owner decision 2026-08-07: refreshed from the live device at release time; no license grant is present in the spec itself (info.license is empty) and the file is retained as reference material for administering the owner's own equipment.
- **From:** a UniFi Dream Machine Pro console, at
  `/usr/lib/unifi/webapps/ROOT/api-docs/integration.json`. It is Ubiquiti
  Inc. material extracted from device firmware.
- **Copyright:** Ubiquiti Inc.
- **License:** **none stated.** The document's own `info.license` field is
  empty, and no grant accompanies it. It is **not** covered by this
  repository's MIT [`LICENSE`](LICENSE) and must not be relicensed.
- **Status:** flagged for an ownership decision — keep and accept the
  redistribution question, replace with a link to Ubiquiti's published
  documentation, or drop the snapshot and read the live console file (which
  `references/api-usage.md` already recommends).

Corrections welcome — an incomplete or wrong notice here is a bug.
[File it](https://github.com/novotnyllc/roundhouse/issues).
