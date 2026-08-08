<!-- Cross-repo links: /railyard and /roundhouse are site-absolute
     placeholders for each product's own docs site. -->

# Credits and upstream sources

roundhouse orchestrates tools that other people built well. This page names
the work we depend on — these projects earned it.

This page is credit, not licensing. Almost everything below is a tool
roundhouse *drives*, which carries no license obligation. The material
actually copied into this repository — the `remote-mac` and `ssh-doctor`
skills, and the UniFi API snapshot — is recorded in
[`THIRD-PARTY-NOTICES.md`](https://github.com/novotnyllc/roundhouse/blob/main/THIRD-PARTY-NOTICES.md),
with license text in
[`LICENSE`](https://github.com/novotnyllc/roundhouse/blob/main/LICENSE).

## The store and its plumbing

**Jujutsu (jj)** — the desired-state sync store is a
[jj](https://github.com/jj-vcs/jj)-colocated git repository. jj's
conflicts-as-data model and operation log are why an unattended sync run
can hold a conflict instead of wedging, and why a run is individually
undoable. **git** remains the storage and wire format, and the always-works
fallback on hosts without jj.

**OpenSSH** — the fleet's identity layer (certificate authority, signing,
key revocation) and every transport lane are plain OpenSSH machinery:
`ssh-keygen` certificates and allowed-signers verification, no custom
crypto anywhere.

## Personal configuration

**chezmoi** — [Tom Payne](https://github.com/twpayne)'s
[chezmoi](https://www.chezmoi.io/) manages the operator's personal
dotfiles. The [fleet-chezmoi](skills/fleet-chezmoi.md) skill drives it
deliberately narrowly — chezmoi owns personal configuration; roundhouse
never treats it as fleet infrastructure, and stays out of its lane.

## Package managers

[fleet-update](skills/fleet-update.md) plans and applies updates through
each platform's own manager — [Homebrew](https://brew.sh),
[APT](https://wiki.debian.org/Apt), and
[winget](https://github.com/microsoft/winget-cli) — using their native
commands and respecting their transaction ownership rather than replacing
them.

## Network and platform

**UniFi** — [unifi-network-api](skills/unifi-network-api.md) administers
[Ubiquiti UniFi](https://ui.com) gear through its official Network API.

**Tailscale** — [Tailscale](https://tailscale.com) is the recommended (never
required) fleet transport; the registry prefers tailnet addresses when
present.

**The harnesses** — roundhouse is a plugin for
[Claude Code](https://code.claude.com) (Anthropic) and
[Codex](https://openai.com/codex) (OpenAI), and its Codex hook-trust
tooling drives the Codex app-server's own protocol.

**ShellCheck** — [ShellCheck](https://www.shellcheck.net) gates every bash
script in CI.

## The sibling

[railyard](/railyard) is the delivery system this fleet serves — see
[its credits page](/railyard/credits) for the delivery-side upstreams
(Compound Engineering, Peter Steinberger's Oracle, Cursor's Thermos
review family).

Corrections welcome: if an attribution here is incomplete or wrong, that is
a bug — [file it](https://github.com/novotnyllc/roundhouse/issues).
