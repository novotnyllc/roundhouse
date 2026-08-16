---
name: mcp-shim
description: Install, update, or remove a resilient stdio MCP shim in front of a desktop app's HTTP MCP server (Autodesk Fusion, Figma, or any other app/URL), for Claude Code and/or Codex. Use when the user wants to "set up MCP for" a desktop app, register an MCP server that should survive the app being closed, or fix an MCP server that dies when its host app quits.
---

# MCP Shim

Registers `scripts/mcp-siding.mjs` — a zero-dependency Node stdio MCP shim —
in front of a desktop app's HTTP MCP endpoint. The problem it solves: a
desktop app's MCP server (Fusion at `http://127.0.0.1:27182/mcp`, Figma at
`http://127.0.0.1:3845/mcp`) only exists while the app runs. Registering that
URL directly means a failed server every session the app is closed, with no
reconnect when it opens later — the client has to be restarted. The shim
always starts clean, serves a disk-cached tool list while the backend is
down, turns a down backend into a normal `isError` result instead of a
transport failure, reconnects automatically on the next call, and can launch
the app itself from a real `tools/call` (never from `tools/list` or at
startup — see Launch-on-demand below).

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md`.
The reference script lives at `"$SKILL_DIR/../../scripts/mcp-siding.mjs"`.
Registration itself uses each harness's own first-party CLI — `claude mcp`
and `codex mcp` — never a custom config-file editor. No TOML/JSON parsing or
serialization lives in this skill or its scripts; that stays the harness
CLI's job, which owns the format and gets the escaping right.

## Authorization model

An explicit request naming the target — "set up MCP for Fusion," "register
figma as an MCP server," "remove the fusion-dev registration" — IS the
mutation authorization for that one registration: resolve the target
(name/backend/harness), state the exact command, run it, and verify
afterward, without a second confirmation round-trip. A request to just
inspect or explain current registrations (`claude mcp list`, `claude mcp
get NAME`, or the Codex equivalents) stays read-only and never on its own
authorizes an add or remove.

This mutates one named MCP server registration through the harness's own
first-party CLI (`claude mcp add`/`remove`, `codex mcp add`/`remove`), not
the fleet-wide package/agent/auth/chezmoi/project domains the `roundhouse`
CLI's `seal-plan`/`verify-preconditions`/`apply-plan` pipeline governs —
there is no sealed-plan action type for "register an MCP server" today,
and adding one is out of this skill's scope. The same discipline still
applies in miniature, matching what that pipeline enforces for the domains
it does cover: identity verification is the harness/PATH check
(`command -v codex`) before ever touching Codex; preflight is stating the
exact command before running it; the post-change check is
`claude mcp get`/`codex mcp get` afterward, every time, not only when
asked.

## No copy — resolve the script path at spawn time

**Never register a literal path to `mcp-siding.mjs` — plugin tree or
anywhere else — and never copy the script.** Every registration instead
embeds `mcp-siding.mjs --print-shim-script`'s output: a small POSIX
`/bin/sh` resolver that finds the script fresh at every server start
(see the `RESOLVER_SH` comment in the script for exactly how and why —
`--print-resolver` prints just that part), followed by a second resolver
(`NODE_RESOLVER_SH`) that finds a `node` capable of running it, then the
exec line for this instance's flags. A plugin update lands a new version
directory; the very next spawn picks it up automatically, for every
existing registration, with nothing to reinstall or re-copy.

The shim needs a runtime with global `fetch` and `ReadableStream` —
**Node 18 or newer**. `NODE_RESOLVER_SH` probes each candidate `node` for
those two globals directly rather than trusting a version number or mere
existence on PATH: an older Node starts the server fine and then fails
every backend request with `ReferenceError: fetch is not defined`, which
reads as the backend being down. `$MCP_SIDING_NODE` pins an exact `node`
binary the same way `$MCP_SIDING_PATH` pins the script, for the same
reason (local development, or a machine where the resolver's search order
picks the wrong one) — including the same fail-closed rule; see "Local
development" below.

## Install a server

Before anything else, confirm this host can actually run the shim. Both
documented registrations (see the harness table below) bake in
`/bin/sh -c "$SCRIPT"`, and the install snippet itself is POSIX shell -
native Windows (PowerShell or cmd.exe, with no POSIX layer) has neither,
so a registration made there would be accepted by the harness CLI and
then leave a server that can never spawn. Refuse before that mutation
happens, not after:

<!-- mcp-siding-selftest: windows-preflight-snippet:start -->
```bash
case $(uname -s) in
  Darwin|Linux) ;;
  *)
    echo "mcp-siding: this shim needs a POSIX shell to install and run - native Windows (PowerShell/cmd.exe, no WSL) is not supported yet. Use WSL (Windows Subsystem for Linux) and run this installer from inside it instead." >&2
    exit 1
    ;;
esac
```
<!-- mcp-siding-selftest: windows-preflight-snippet:end -->

WSL passes this check - it is a real Linux kernel, so `uname -s` reports
`Linux` there, and it is the supported route onto Windows today. A native
PowerShell resolver and launcher (so the shim could run without WSL at
all) is a real feature with its own testing surface - out of scope here;
this guard exists so an unsupported host gets a clear refusal instead of
a registration that silently cannot start.

Ask the user (do not assume): what to call this MCP server (e.g. `fusion`,
`figma`, or any name they choose — never hardcode one); which backend —
offer the presets below or "something else"; and which harness(es) —
Claude Code, Codex, or both.

| Preset | `--backend-url` | `--app` |
| --- | --- | --- |
| Autodesk Fusion | `http://127.0.0.1:27182/mcp` | `$HOME/Applications/Autodesk Fusion.app` |
| Figma | `http://127.0.0.1:3845/mcp` | `/Applications/Figma.app` |

Fusion note: confirm the app bundle exists at that path on this host
(`test -d`) before using it — it resolves the current webdeploy build, and
a wrong or stale path defeats the point. If it doesn't exist, ask the user
for their actual Fusion app path rather than guessing.

For "something else": ask for the backend URL and, optionally, an app path
to launch on demand. Omit `--app` and launch-on-demand is simply
unavailable — a down `tools/call` then always returns the plain "not
reachable, ask the user to open the app" message.

Build the registration script once, from the currently-loaded plugin
checkout. Resolve a usable `node` first, the same way `NODE_RESOLVER_SH`
resolves one for the spawned server at runtime — bare `node` can fail
before the script is even generated on a host with a self-contained
harness or no `node` on PATH, exactly the case that resolver exists to
handle. This candidate list mirrors `NODE_RESOLVER_SH` in
`scripts/mcp-siding.mjs` — keep both in sync:

<!-- mcp-siding-selftest: node-resolver-install-snippet:start -->
```bash
node_ok() {
  [ -x "$1" ] || return 1
  "$1" -e 'if (typeof fetch !== "function" || typeof ReadableStream !== "function") process.exit(1)' >/dev/null 2>&1
}
if [ -n "$MCP_SIDING_NODE" ]; then
  if [ ! -x "$MCP_SIDING_NODE" ]; then
    echo "mcp-siding: \$MCP_SIDING_NODE is set to '$MCP_SIDING_NODE' but that file does not exist or is not executable - this is an explicit override, not a hint, so it must name a usable node rather than silently falling back to another one." >&2
    exit 1
  fi
  if ! node_ok "$MCP_SIDING_NODE"; then
    echo "mcp-siding: \$MCP_SIDING_NODE is set to '$MCP_SIDING_NODE' but it lacks global fetch/ReadableStream (this shim needs Node 18+) - this is an explicit override, not a hint, so it must name a usable node rather than silently falling back to another one." >&2
    exit 1
  fi
fi
node_bin=""
for node_candidate in "$MCP_SIDING_NODE" "$(command -v node 2>/dev/null)" \
  /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node \
  "$HOME/.volta/bin/node" "$HOME/.asdf/shims/node"; do
  [ -n "$node_candidate" ] || continue
  if node_ok "$node_candidate"; then
    node_bin=$node_candidate
    break
  fi
done
[ -n "$node_bin" ] || { echo "mcp-siding: no node with global fetch/ReadableStream (this shim needs Node 18+) found on this host - cannot build the registration script. Install a newer Node or set \$MCP_SIDING_NODE." >&2; exit 1; }

SCRIPT=$("$node_bin" "$SKILL_DIR/../../scripts/mcp-siding.mjs" --print-shim-script \
  --backend-url <URL> --name <NAME> --app "<APP_PATH>")
```
<!-- mcp-siding-selftest: node-resolver-install-snippet:end -->

Omit `--app` for a backend with no launchable app. `--print-shim-script`
only emits flags you pass it explicitly — `mcp-siding.mjs`'s own defaults
handle the rest at runtime. Using the same `$node_bin` to generate the
script and `NODE_RESOLVER_SH` to run it means install and runtime agree
on what counts as a usable runtime — never install successfully with one
node and then spawn under a different one.

Then, per harness — state the exact command before running it, and always
verify afterward. `"$SCRIPT"` must be passed as captured, as a single
argument: do not re-quote, re-escape, or reconstruct it by hand.

| Harness | Add | Verify | Remove |
| --- | --- | --- | --- |
| Claude Code | `claude mcp add <NAME> -s user -- /bin/sh -c "$SCRIPT"` | `claude mcp get <NAME>` — confirm `Connected` or `Failed to connect` (it should be *this* shim listed and inert, not a raw `mcp-remote` failure) | `claude mcp remove <NAME> -s user` |
| Codex | `codex mcp add <NAME> -- /bin/sh -c "$SCRIPT"` | `codex mcp get <NAME>` | `codex mcp remove <NAME>` |

`-s user` matches the existing `fusion` registration's scope (available in
every project); pass a different `-s` only if asked. Before the Codex row,
check `codex` is on PATH (`command -v codex`) — the user may be on a
Claude-only machine; if absent, skip Codex and say so plainly rather than
trying to install it. `codex mcp add`/`remove` rewrite the entire
`~/.codex/config.toml` (they own the file — this is by design). On a
hand-maintained config this can canonicalize unrelated entries elsewhere,
e.g. `startup_timeout_sec = 120` becoming `120.0` or an env table getting
alphabetized — semantically equivalent either way, but worth mentioning to
a user who maintains that file by hand.

## Local development

To register and exercise an unpublished working-tree build instead of a
published plugin version, pin it explicitly with `MCP_SIDING_PATH` — the
resolver's first branch, checked before `$CLAUDE_PLUGIN_ROOT` and everything
below it. Build `$SCRIPT` the same way as a normal install (above), suffix
the name (e.g. `fusion-dev`) so a local build never silently clobbers a
working published registration, and add the env var to the registration:

```bash
claude mcp add fusion-dev -s user -e MCP_SIDING_PATH=/absolute/path/to/checkout/scripts/mcp-siding.mjs -- /bin/sh -c "$SCRIPT"
codex mcp add fusion-dev --env MCP_SIDING_PATH=/absolute/path/to/checkout/scripts/mcp-siding.mjs -- /bin/sh -c "$SCRIPT"
```

This pins one exact path and will not follow plugin updates — the opposite
of a normal install, and deliberately so; it is the one named exception to
the "never register a literal path" prohibition above.

One rule covers both override variables, `MCP_SIDING_PATH` and
`MCP_SIDING_NODE`: each pin fails closed. If set but unusable —
`MCP_SIDING_PATH` naming a file that does not exist (renamed, deleted, an
unmounted volume), or `MCP_SIDING_NODE` naming a binary that is missing,
not executable, or fails the `fetch`/`ReadableStream` capability probe
above — the resolver exits non-zero with a diagnostic naming the override
and the specific problem, rather than silently falling back to an
installed build or a different `node`. An explicit override is an
assertion of intent — running a published version, or a different
runtime, while the user believes they are exercising their pinned
working tree would be exactly the misleading result this mode exists to
avoid. Only leaving a variable unset (or empty) falls through to that
variable's normal resolution chain — the two never affect each other.

## Config flags

All of the following are `mcp-siding.mjs` CLI flags — the installer's job is
picking sensible values and passing them explicitly to `--print-shim-script`,
since the registration bakes them in as argv.

| Flag | Purpose | Default |
| --- | --- | --- |
| `--backend-url` | HTTP MCP backend URL | required |
| `--name` | Server display name (also part of the cache key) | required |
| `--app` | App to launch on demand | none (launch disabled) |
| `--cache` | Tool-list cache file path | `~/.cache/mcp-siding/<name>-<url-hash>.json` |
| `--timeout` | Backend request timeout, ms | `180000` |
| `--launch` / `--no-launch` | Launch-on-demand opt-in/out | on iff `--app` is set |
| `--launch-grace` | Debounce window before relaunching, seconds | `150` |

The cache is keyed by `--name` plus a short hash of `--backend-url`, so a
repoint (remove and re-add the same `--name` with a different
`--backend-url`, per Update below) can never collide with the old
backend's cached tool list — each `(name, url)` pair gets its own file.
Two different backends still should not share a `--name` for its own
sake (the display name itself would be ambiguous to the user), but doing
so no longer corrupts either one's cache.

## Launch-on-demand

Only triggers from a real `tools/call` when the backend is unreachable —
**never** at startup and **never** from `tools/list` (clients issue
`tools/list` every session; launching the app on that would launch it
constantly). Repeated calls inside the grace window are debounced to one
launch. The first `tools/call` after a launch returns immediately — it does
not block through the roughly one-minute cold start — with a message noting
the app was just started, to retry shortly, and that a freshly launched app
may have no active document yet.

## Update

Nothing to re-copy — the resolver picks up a plugin update on the very next
spawn, automatically, for every existing registration. To change a
registration's *flags* (URL, app path, launch settings), remove then
re-add: both `claude mcp add` and `codex mcp add` reject an existing name.

## Known holes

- **Never-seeded cache.** If the cache was never written (fresh install,
  fresh machine) and the app is closed at session start, `tools/list` has
  nothing to serve — the model sees zero tools for that session, even
  though the shim itself is healthy. There is no workaround inside the
  shim: seed it once by using this MCP server with the app open right
  after installing (any normal `tools/list` does this); after that the
  cache persists across app restarts. The same thing happens once, for an
  existing registration, on the first run after upgrading past the cache
  key change that mixed backend identity into the filename (see Config
  flags above) — the old name-only file is simply orphaned, not migrated,
  so a session that starts with the app closed sees zero tools until it
  has been opened once at least one time post-upgrade. Self-healing, same
  workaround as a fresh install.
- **Resolver finds nothing.** Most likely `roundhouse` isn't installed on
  this machine, or was removed after this server was registered. The
  registered command exits immediately with a message on stderr naming
  every path it checked; the MCP client reports the server as failed to
  connect. Same failure shape in both harnesses, since both spawn the
  identical `/bin/sh -c` command.
- **Native Windows is not supported yet.** The preflight check in Install
  a server above refuses before registering anything - not because it is
  impossible, but because a POSIX-shell-only shim needs a native
  PowerShell resolver and launcher to run without WSL, which does not
  exist yet. WSL is the supported route onto Windows today.

## Cloud

Not verified directly — treat as expected-to-work, unverified. The resolver
depends on the plugin cache existing under that session's `$HOME`; if a
cloud registration fails, its stderr (see the resolver-finds-nothing hole
above) names exactly which paths it checked there.

## Self-check

```bash
node "$SKILL_DIR/../../scripts/mcp-siding.mjs" --selftest
```

Exercises the shim end to end — parsing, timeouts, caching, recovery, the
resolver, and more — against fake backends and temp directories only, never
the real caches. Exits non-zero on any failure.
