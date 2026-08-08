# The fleet store

The fleet store is a jj repository of plain YAML that says what every
machine you own should have on it — plugins, skills, agents, hooks, MCP
servers, packages, projects, and the harness config keys you've chosen to
manage. Every host holds a complete copy, converges itself against it on a
schedule, and publishes back into the same repository what it actually
did. There is one bookmark, `main`, and every host is an equal peer of it.

That's the whole mental model: **a repository of files that describe your
fleet, replicated everywhere, applied locally, with evidence written back.**
Open any file in an editor and you can read what it says. Change it and
the change travels.

## Who writes it

Agents are the routine readers and writers. Your scheduled run edits it,
your supervising agent edits it, an enrollment edits it — most of the
traffic through these files is machine traffic, and it is meant to be.

What the format guarantees is that **a human can open any file at any
time, understand it, change it, and walk away.** No schema to satisfy, no
generated twin to keep in step, no import step to run afterward. One
representation, editable in vim, with comments that survive. Everything
downstream — comment-insensitive digests, conflict markers that render at
correct YAML indentation, signing that happens on snapshot rather than on
a commit command — exists to keep that guarantee true while agents write
to the same files all day.

## What converges

Item identity is `<category>.<name>`, and the categories are a closed set:

| Category | What it names |
| --- | --- |
| `policy` | the fleet's own cadences, canary settings, and removal caps |
| `packages` | host-level packages, through each host's own managers |
| `plugins` | Claude Code and Codex plugins, with their enabled state |
| `skills` | plugin-delivered (`superpowers/brainstorming`) or standalone (`grilling`) |
| `agents` | user-scope agent definitions |
| `hooks` | plugin-delivered or standalone hooks, each gated by trust before it runs |
| `mcp_servers` | MCP server configuration |
| `config_files` | named keys inside a harness config file, key by key |
| `projects` | project checkouts the fleet keeps |

An unknown key *inside* a known item is ignored — it cannot cause a host
to under-converge. An unknown *category*, or a layer directory nobody
recognises, holds every item under it and raises an alert naming it,
because that one *could*.

Secrets and session transcripts stay on the host that has them. A quote
that trips the redaction floor is refused rather than silently trimmed:
the remedy for a published secret cannot un-publish it.

## Four layers, folded low to high

```text
fleet.yaml               applies to every host
os/<platform>.yaml       every macOS box, every Linux box
groups/<group>.yaml      in the host's own `groups:` order, last wins
hosts/<name>.yaml        this machine
```

Every tier also takes a **directory** — `hosts/wren/host.yaml`,
`hosts/wren/skills.yaml` — merged in filename order. That's the escape
valve for a file that got long, available at all four tiers.

The fold is a left reduce with one clause: map plus map deep-merges key by
key, anything else is replaced whole by the higher layer, an empty
document is "no opinion at this layer," and the scalar `absent` at item
position knocks the item out entirely. **Group precedence is the host's
own list order**, written in the file you already have open:

```yaml
# hosts/vireo.yaml
platform: macos
package_managers: [homebrew]
groups: [development, canary]      # left to right, canary wins ties

plugins:
  legal: absent                    # knocked out here, not merely disabled
  railyard:
    state: enabled
    marketplace: claire-local      # map form, because there's more to say
```

Desired state is **maps keyed by item name, never lists.** That is what
fixes merge behaviour by data shape rather than by configuration: two
hosts adding two different plugins touch two different keys and merge
cleanly, and two hosts setting the same key to different values is a
genuine disagreement that surfaces as one.

`fleet-explain` answers "why does this host have that value" per key:

```text
$ roundhouse fleet-explain vireo plugins.railyard
plugins.railyard = {"marketplace":"claire-local","state":"enabled"}

  fleet.yaml                   —          (no opinion)
  os/macos.yaml                —          (no opinion)
  groups/development.yaml      "enabled"
  hosts/vireo.yaml             {"marketplace":"claire-local","state":"enabled"}   <- wins
```

Provenance is per file. Layer files are commented by design, and a line
number computed over a commented file drifts by however many comments
precede the key — so the file is where provenance honestly stops.

## Values

Every category shares one value grammar. A scalar and its map form are the
same item:

```yaml
plugins:
  ponytail: enabled                          # scalar
  railyard: {state: enabled, marketplace: claire-local}   # map
```

`enabled`, `disabled`, and `absent` are the state tokens. `absent` means
"knocked out of the effective set here," which is different from
`disabled` — one uninstalls, the other leaves it installed and off.

## definitions.yaml — logical name to concrete artifact

Layers name things **logically**. `jj` is not a package name; it's the
name of something this fleet wants, and every manager spells it
differently. `definitions.yaml` maps logical names to concrete artifacts,
keyed by the same categories the layers use, and it carries **only the
exceptions**:

```yaml
packages:
  jj:
    homebrew: jj
    winget: jj-vcs.jj
    apt: unavailable       # not packaged; the item holds and alerts

plugins:
  railyard:
    marketplace: claire-local
```

Absent an entry, the logical name *is* the concrete name, resolved through
that category's default source: the package manager's own index, the
fleet's default marketplace, or the plugin that provides the skill. `jq`
needs no definition and never will. A fleet that never hits a divergence
never creates the file, and a missing file reads exactly like an empty one.

The default for a version is `latest`, and it's never written down — the
full cadence keeps unpinned packages current, which is what you get by
doing nothing. A `version:` key opts one package out, the update pass then
skips it, and **a pin is enforced or refused**: where the manager can
select an exact version at install time the pin is applied; where it
can't, the item holds with an alert naming the package, the manager, and
the requested version. On Homebrew a pin resolves through a real
`<name>@<version>` formula (`node@24`, `postgresql@16`), which is also how
two major streams coexist — as two logical names.

A definition is an item in its own right, under the reserved prefix:
`definitions.packages.jj` is the mapping, `packages.jj` is the desired
state, and they carry separate digests and separate verdicts.

## Evidence: what each host publishes about itself

```text
journal/<host>/<date>.yaml     what this host applied, held, reverted, resolved
applied/<host>.yaml            what this host owns, at what digest
alerts/<host>/<stamp>-<slug>.yaml
findings/<host>/<stamp>-<slug>.yaml
upstreams/<id>/<host>.yaml     freshness, one file per host per upstream
```

Exactly one host writes each of these paths, which is why they can never
conflict — different directories. They are **evidence, not consent**: the
verdict that authorised an apply stays host-local and is never replicated.
`applied/<host>.yaml` is the ownership record, and it's the only thing
that makes a removal legal: an item is uninstalled because it appears
there *and* left the layers. Software that never appears there is never
touched.

Alerts have no state machine. Resolving one is `rm` on the file.

## Where it lives

```text
${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/
  identity.yaml     this host's name, principal, key, and store id. Host-local.
  store/            the jj repository, colocated with git
  store.run/        this run: verdicts, the lock, the starting operation id
  store.local/      durable host posture
~/.ssh/config.d/roundhouse   generated from hosts/*.yaml
```

`ROUNDHOUSE_FLEET_STORE` moves the store, and every host-local path
follows it — which is how one machine operates a second instance on behalf
of a host that can't run the code itself.

The store's own remote is jj's `origin`, set by `roundhouse fleet-init`
and moved by `roundhouse fleet-set-remote`. Cadences, canary group, and
canary wait are policy keys inside the store's `fleet.yaml`, deliberately
not knobs on the machine being governed.

## Words used here

**Item** — one `<category>.<name>` pair, the unit of review, apply, and
hold. **Fold** — the four layers reduced to this host's effective desired
state. **Digest** — the SHA-256 over the item id and its resolved value,
canonicalised so comments, key order, quoting, indentation, and line
endings don't change it. **Verdict** — a host-local decision about one
item at one digest. **Held** — resolved but deliberately not applied,
recorded by name. **Reconcile point** — the commit the run resolves from,
which is never the working copy. **Roster** — `trust/signers.yaml`, the
list of which machine key may write what. **Durable** and **ephemeral** —
the two membership classes; see [Trust](trust.md). **Canary** — a host
that adopts a changed item first, and whose journal every other host reads
before adopting it.

## Go deeper

- **[How a change travels](convergence.md)** — edit to applied, end to end.
- **[Trust](trust.md)** — the ratchet, enrollment, revocation.
- **[Why jj](why-jj.md)** — what the version control buys.
- **[Running it](operating.md)** — the verbs, the schedule, the audit trail.
