<!-- Cross-repo links: /railyard and /roundhouse are site-absolute
     placeholders for each product's own docs site. Leave them as-is —
     they resolve once both docs sites are published together. -->

# The railyard family

![A roundhouse with engines in every bay, turntable at the center](assets/hero.jpg)

You've got a laptop, a desktop, a Windows box you keep meaning to sort out,
and two agent CLIs — Claude Code and Codex — installed across some subset of
them. Plugins are current on one machine and two versions behind on
another. A skill you trust on your Mac is a skill you've never laid eyes on
on the Windows box. Nobody can tell you, with evidence, whether a given
machine is actually ready to take on work right now — or whether "it worked
on my laptop" means anything at all on the machine you're about to point an
agent at.

And the fixes people reach for both have a cost. Auto-update everything and
you're trusting unread diffs to run as you, on every machine, unattended.
Update by hand and you're back to babysitting five machines instead of one.
Neither is where you want to live.

**railyard** and **roundhouse** are two sibling plugins that give you the
other option: a fleet that updates itself, but nothing lands anywhere
without something — you or your own agent, reading the actual diff — looking
at it first.

**[railyard](/railyard)** is the product's front door — the delivery system
you actually talk to. Say "implement X" and it picks the workflow, the
model, and the machine, then drives the change through to a merged commit.
**roundhouse** stays behind the scenes: it keeps the engines ready, so
railyard always has a machine it can trust to dispatch to.

## What each one does

**[railyard](/railyard)** is the delivery system. You say "implement X" or
"fix Y," and it picks the workflow, the model, the machine, and drives the
change through implementation, review, merge, and post-merge proof. It
never calls something done because CI is green or an agent said so — it
checks for a merged commit reachable from your base branch.

**roundhouse** is machine and infrastructure administration. It keeps
inventory of what's installed where, checks every host's readiness before
railyard dispatches work to it, and — if you opt in — keeps plugins, skills,
hooks, agents, and config in sync across the whole fleet, with every change
reviewed on the machine where it's about to run, before it runs.

Together, they mean your fleet stays consistent, current, and trustworthy,
and can still take on real delivery work the moment you ask. They're
independent installs, not a bundle: install roundhouse alone and you have a
full fleet-administration toolkit with no delivery system attached; install
railyard alone and delivery works on whatever's local, with no fleet
awareness. Install both and the seam between them just works — railyard
consults roundhouse's readiness before it dispatches anywhere.

## Who this is for

You, specifically — not an IT department managing devices that belong to
someone else. Every machine in the fleet is one you own and sit at; every
machine joins through a ceremony you personally consent to, and leaves just
as cleanly, trust actually revoked rather than just forgotten about. If
your setup is a laptop, a desktop, maybe a Windows box, and two agent CLIs
you'd like to stop manually keeping in sync, this is built for exactly that
shape of problem — not a corporate fleet, not a single machine you already
have well in hand.

## Three pillars

**Deliver work.** One entry point — "go do X" — routes to the right
workflow and the right model, whether that's a local change or a placement
across your fleet. Every unit of dispatched work carries an explicit,
recorded model and effort decision; nothing improvises that per session.
Review gates and post-merge proof are part of the route, not something you
have to remember to ask for.

**Keep engines ready.** Inventory answers "what's installed where" with
evidence, not memory. Readiness is a go/no-go railyard actually consults
before it places work on a host — an unready machine gets findings, not a
task it can't finish.

**Stay consistent and safe.** If you opt into fleet sync, your agent surface
— plugins, skills, hooks, agents, MCP servers, allowlisted config keys —
converges across every machine from a signed, replicated store. Every
change is screened on the host where it's about to run before it's applied,
never trusted just because it arrived from upstream. Secrets and session
transcripts never enter the store. The few operations that need root travel
through sealed, ceremony-gated broker requests — there's no ad-hoc `sudo`
anywhere in the system. When two machines disagree about what's true, the
system holds and asks rather than picking a side by whichever wrote last.

## How it feels

**"Set up railyard on this machine."**
`railyard:setup` inventories what's there, installs the few prerequisites
you approve as a group, checks that the API keys your plugins need are
present (never their values), and asks what your other machines are. "Just
this machine, no fleet" is a complete answer — you get a working delivery
system with nothing configured about other hosts.

**"Add my Windows desktop to the fleet."**
`roundhouse:fleet-hosts` runs the whole ceremony: reachability check,
config entry, an identity generated on the new machine itself, a signing
step you explicitly consent to, the CA installed, prerequisites checked, and
a readiness verdict at the end. Nothing about the new host's identity ever
leaves the host that generated it — only the public signing request travels.

**"Implement the retry logic in the sync client and ship it."**
railyard picks the model and effort, drives plan → work → review → PR →
CI, gets an independent review pass on record, merges with your
repository's strategy, and hands you back proof — not a claim: a merge
commit you can see reachable from your base branch.

**"Is everything in sync?"**
`railyard:doctor` checks plugin versions across harnesses and hosts, stale
marketplaces, unreachable machines, held sync items nobody's resolved yet,
and reports exactly what's drifted and why — never a shrug, never a bare
"looks fine."

**"A skill update just came in — did anyone actually look at it?"**
Yes, on every host it's about to run on. The reviewing host diffs current
against incoming, screens it against a fixed rubric — new deletion
behavior, credential access, exfiltration shapes, and content that argues
for its own approval — and either applies it or holds it with an alert.
Nothing is applied on trust because it already ran clean somewhere else.

## What ships today vs. what's designed

Everything above — delivery, fleet readiness, inventory, host enrollment,
desired-state sync with apply-time review — is real and running today.
Privileged package work (the updates that need `sudo` or Administrator) is
part of that picture, but only as an interactive step: you're prompted, you
approve, it applies through the sealed broker pipeline.

**Unattended privileged updates** — letting a scheduled run apply those
same privileged changes with nobody watching — is designed but not yet
built. The design ([roadmap chapter of the lifecycle
page](lifecycle.md#6-the-road-ahead-unattended-privileged-updates)) is
specific about how it stays safe: provenance-anchored trust instead of
byte-pinning, mandatory anti-rollback, canary hosts that have to succeed
first, and a hard cap on how much an unattended run can touch before it
stops and asks. Until it ships, that's a human-in-the-loop step, on
purpose.

## Go deeper

- **[The fleet's life, end to end](lifecycle.md)** — first machine, growing
  the fleet, the daily sync loop, what happens when things change, delivery
  placed on top, and the unattended-updates roadmap.
- **[Where this fits next to what you already know](comparison.md)** —
  dotfile managers, config management, MDM, and plugin marketplaces, and
  what's actually different here.
- **[Configuration reference](config.md)**
- **[Skills index](skills/)**
