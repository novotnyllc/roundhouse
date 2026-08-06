# Where this fits

None of these categories are wrong for what they're built for. This page is
about center of gravity — what each one is built for — so you can tell
quickly whether railyard and roundhouse are solving your problem, or
whether the tool you already have is.

## Dotfile managers (chezmoi and friends)

These are genuinely great at what they do: your `.zshrc`, your editor
config, your personal scripts, templated and versioned across machines,
with a mature diffing and templating story built specifically for personal
files.

Roundhouse doesn't compete with that lane — it deliberately builds *on* it.
A personal sync engine you already run is treated as an **upstream** and,
where a config file is co-owned, a **co-owner**: detected, surfaced, and
the ownership of each key is your explicit choice, never silently taken
over. If you point roundhouse at a file your dotfiles tool also manages,
you decide which system owns which keys, and doctor watches for the
ownership drifting back into overlap. What roundhouse adds on top is
scoped narrowly to the agent surface — plugins, skills, hooks, agents, MCP
servers, and allowlisted harness config — and to a fleet-registry, apply-
time-review model your dotfiles tool was never trying to be.

## Configuration management (Ansible, Puppet, Salt)

Proven, mature, exactly right for server fleets: idempotent state
convergence at real scale, with a huge library of existing modules and
operational muscle memory behind it.

The center of gravity here is different in a specific way: this system's
unit of state is an *agent harness surface* — which plugins are enabled,
which skills exist, whether a hook is trusted — not a general-purpose
server configuration. And the thing evaluating a proposed change isn't a
declarative module applying a diff blindly; it's apply-time review with
judgment in the loop, screening for deletion behavior, credential access,
and content that argues for its own approval, on the machine where the
change is about to run.

If your fleet is Linux servers running application
workloads, Ansible's model — and its ecosystem — is the right tool. If your
fleet is the machines *you* sit at, running agent tooling that executes as
you, the review-gated, harness-native model is built for that instead.

## MDM and fleet tools

Enterprise device management is excellent at what it's for: corporate
policy enforcement, compliance reporting, remote wipe, an IT department
managing devices that belong to the organization, not to the person using
them.

This system assumes the opposite ownership model: **you** own every
machine in your fleet, you enroll each one yourself through a ceremony you
consent to, and you can leave the fleet as cleanly as you joined it — trust
actually revoked, not just a device record archived. It's agent-native
rather than policy-native: the thing being kept in sync is Claude Code and
Codex tooling, not a corporate app catalog, and the "compliance report" is
`railyard:doctor` telling *you*, the owner, what's drifted — not reporting
up to an IT console you don't control.

## Plain plugin marketplaces

Necessary substrate, and neither railyard nor roundhouse tries to replace
it — Codex and Claude Code marketplaces are exactly where plugin content
comes from, and this system leans on manager-native install/update/enable
commands rather than reimplementing them. A marketplace answers "what's
available and how do I install it on this one machine."

What it doesn't answer is "is machine four consistent with machine one,"
"can I trust the version that just showed up before it runs," or "if I
walked away for a week, what needs my attention now." That's the layer this
system adds on top: cross-machine convergence with groups and scopes,
signed commits over a fleet SSH CA with host-local trust verification,
apply-time review as a supply-chain gate independent of where content
originated, and durable evidence — journals, provenance records, held-item
alerts — instead of a marketplace's point-in-time install log.

## What actually differentiates this

A few things worth naming plainly, because they're not universal even
among tools that look similar on the surface:

- **Agent-native.** The operator's own agents do the enrollment,
  the diffing, the review, and the delivery — through skills, in the same
  harness you already talk to — rather than a separate control plane you
  learn independently.
- **Evidence over timestamps.** When state disagrees between hosts,
  resolution weighs store history, then provenance, then locally-mined
  redacted findings — never "whichever wrote last."
- **Apply-time review as a supply-chain gate.** Every changed item is
  screened on the host where it's about to *run*, regardless of where it
  came from — the gate that actually covers a compromised store, not just a
  compromised upstream.
- **Signed store, host-local trust.** Commits are signed by enrolled host
  keys over a fleet SSH CA; every host verifies before applying; there's no
  step where "the network delivered it" is treated as "therefore trusted."
- **Opt-in, everywhere, by layer.** Fleet sync is off until you turn it on.
  Privileged actions need enrollment, activation, *and* a per-binding grant
  — three separate yeses, not one master switch.
- **Two-harness parity, honestly scoped.** Claude Code and Codex are kept
  in sync deliberately, including the asymmetries — a WSL-launcher lane for
  Windows when a harness can't drive its interactive surface, cross-harness
  work dispatch only by explicit opt-in, never a silent fallback.

## When you might not need this

If you run one machine with one harness, most of this doesn't apply to
you, and that's a fine place to stay. Fleet enrollment, cross-host sync,
and readiness checks all exist to answer questions that only come up once
there's more than one machine or more than one harness in the picture. On
a single box, railyard's delivery skills still work — plan, implement,
review, ship, with proof at the end — but the roundhouse side of this has
nothing to do until you add a second machine. And if your fleet is a
corporate server farm rather than a handful of machines you personally sit
at, the tools built for that world — Ansible or Puppet for convergence,
MDM for device policy — are the right center of gravity, not this one.

## Go deeper

- **[The value proposition](index.md)**
- **[The fleet's life, end to end](lifecycle.md)**
- **[Configuration reference](config.md)**
- **[Skills index](skills/)**
