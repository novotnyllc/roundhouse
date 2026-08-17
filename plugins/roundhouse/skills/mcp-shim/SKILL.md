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

Pick the install route by host first. macOS, Linux and WSL take the POSIX
route below; native Windows (PowerShell or cmd.exe, no POSIX layer) takes
"Install on native Windows" further down. Both are supported and both
resolve the script at spawn time; they differ only in the shell the
registration is written in.

The POSIX route's registrations bake in `/bin/sh -c "$SCRIPT"` and its
install snippet is POSIX shell, so running it on native Windows would be
accepted by the harness CLI and then leave a server that can never spawn.
Guard before that mutation happens, not after:

<!-- mcp-siding-selftest: windows-preflight-snippet:start -->
```bash
case $(uname -s) in
  Darwin|Linux) ;;
  *)
    echo "mcp-siding: this installer needs a POSIX shell, and native Windows (PowerShell/cmd.exe) has none. Use the PowerShell install route instead (see 'Install on native Windows' in this skill), or run this installer from inside WSL." >&2
    exit 1
    ;;
esac
```
<!-- mcp-siding-selftest: windows-preflight-snippet:end -->

WSL passes this check - it is a real Linux kernel, so `uname -s` reports
`Linux` there, and it stays a fully supported route onto Windows: a WSL
registration is an ordinary POSIX one. The guard is not a refusal of
Windows, it is a refusal of the *wrong installer* for the host.

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
| Claude Code | `claude mcp add <NAME> -s user -- /bin/sh -c "$SCRIPT"` | `claude mcp get <NAME>` — must report `Connected`; anything else is a failed mutation (diagnose below) | `claude mcp remove <NAME> -s user` |
| Codex | `codex mcp add <NAME> -- /bin/sh -c "$SCRIPT"` | `codex mcp get <NAME>` to confirm the registration, THEN the probe below — `codex mcp get` alone is not a connectivity check | `codex mcp remove <NAME>` |

**The two harnesses need genuinely different post-checks — this is not a
stylistic choice, and making them uniform is what broke this once
already.** `claude mcp get` really does spawn the registration and
attempt to connect: its `Status:` line (`✔ Connected` / `✘ Failed to
connect`) is a live probe (verified: registering a command of `/bin/false`
makes it print `Status: ✘ Failed to connect` with the real spawn error).
`codex mcp get` does not — it only echoes back the stored command/args/env
and exits 0 regardless of whether that command works at all (verified the
same way: `/bin/false` registered under Codex still prints its config and
exits 0, no failure indication whatsoever). Treating `codex mcp get`'s
clean output as "connected" would accept — and this skill's own post-check
instructions used to actively remove — every correct Codex installation as
a false failure, since Codex's check can never fail even when the
registration is completely broken.

**Claude Code:** require `Connected` from `claude mcp get`. The shim
answers `initialize` locally without ever contacting the backend — that
is the whole point (see "No copy" above) — so a closed desktop app still
yields `Connected`. `Failed to connect` therefore never means "the
backend is down"; it means the *resolver* failed before the shim could
even start.

**Codex:** `codex mcp get` is worth doing (confirms the registration
exists and its command is what you intended) but is not a connectivity
test, so add a real probe alongside it — run the registered command
directly and send it an `initialize` request:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | /bin/sh -c "$SCRIPT"
```

(carry over any `--env` values the registration used — e.g.
`MCP_SIDING_NODE`, `MCP_SIDING_PATH` — into this command's own
environment too, since Codex passes them the same way at real spawn
time.) The shim answers `initialize` locally, exactly as it does for
Claude's own probe, so this passes with the desktop app closed and fails
exactly when the resolver cannot find the script or a usable Node — the
failure this check exists to catch. No external timeout is needed: the
input ends after one line, the shim treats that EOF as the client
disconnecting, and it exits on its own promptly either way (verified: a
working registration answers and exits in well under a second; a broken
one — resolver diagnostic on stderr, nothing on stdout — exits
immediately too). A valid response is a JSON-RPC result carrying
`protocolVersion`; anything else (empty stdout, a resolver diagnostic, a
nonzero exit) is a failed mutation, exactly like Claude's `Failed to
connect`.

Do not switch Claude to this same manual probe to make the two
mechanisms uniform. It would be strictly worse there: `claude mcp get`'s
`Connected` check uses Claude's own real client to actually spawn and
connect, which is a stronger, more authoritative signal than a hand-rolled
`initialize` round-trip could ever reconstruct. The manual probe exists
specifically because Codex's own tooling has no equivalent — it is a
workaround for Codex, not a generally better technique.

Either harness's failure — `Failed to connect` on Claude, a failed probe
on Codex — is a failed mutation, not an acceptable outcome. Diagnose
before leaving it in place: confirm `roundhouse` is actually installed
and its plugin cache contains `scripts/mcp-siding.mjs`, and that a Node
18+ with global `fetch`/`ReadableStream` resolves (PATH, Homebrew,
Volta, asdf, or `$MCP_SIDING_NODE`) — running `/bin/sh -c "$SCRIPT"`
directly surfaces the resolvers' own stderr naming exactly what was
checked (see "Resolver finds nothing" under Known holes below). If the
cause cannot be fixed immediately, remove the registration
(`<harness> mcp remove <NAME> ...`) rather than leaving a dead one
behind, and say so to the user.

`-s user` matches the existing `fusion` registration's scope (available in
every project); pass a different `-s` only if asked — Codex has no scope
flag at all (verified: not in `codex mcp add --help`), every Codex
registration is global. Before the Codex row, check `codex` is on PATH
(`command -v codex`) — the user may be on a Claude-only machine; if
absent, skip Codex and say so plainly rather than trying to install it.
`codex mcp add`/`remove` rewrite the entire `~/.codex/config.toml` (they
own the file — this is by design; verified: the file's mtime changes on
every add/remove, and this repo's own `~/.codex/config.toml` already
carries the canonicalized `startup_timeout_sec = 120.0` from an earlier
such rewrite). On a hand-maintained config this can canonicalize
unrelated entries elsewhere, e.g. `startup_timeout_sec = 120` becoming
`120.0` or an env table getting alphabetized — semantically equivalent
either way, but worth mentioning to a user who maintains that file by
hand.

## Install on native Windows

Same contract as the POSIX route — nothing is copied, nothing is
hardcoded, the script and a usable `node` are resolved fresh at every
spawn — expressed in PowerShell instead of `sh`. The logic lives in
`scripts/mcp-siding-windows.ps1`; `--platform windows` emits it as the
registration body. Use this route when `uname` is unavailable or reports
something other than `Darwin`/`Linux`. WSL is not this route: inside WSL,
use the POSIX one above.

Registration goes through `powershell.exe` (always present on Windows;
`pwsh` is not) with **`-EncodedCommand`**, never `-Command "<script>"`.
That is deliberate: the body is multi-line and contains quotes, `$`, and
backslash paths, and it has to survive the harness CLI's own argument
handling. `-EncodedCommand` takes one base64 token, so there is nothing
left to quote or re-escape at any layer. Ask the same three questions as
the POSIX route (name, backend, harness(es)) and use the same preset
table.

Run this in PowerShell, with `$SkillDir` set to the absolute directory
containing this `SKILL.md`:

```powershell
# Dot-sourcing defines the resolver functions and runs nothing, so the
# install reuses the SAME node-candidate list and capability probe the
# registered server will use at spawn time - install and runtime can never
# disagree about what counts as a usable runtime.
. (Join-Path (Join-Path $SkillDir '..\..\scripts') 'mcp-siding-windows.ps1')
$nodeBin = Resolve-McpSidingNode -Override $env:MCP_SIDING_NODE `
  -Candidates (Get-McpSidingNodeCandidates $env:MCP_SIDING_NODE)

$script = & $nodeBin (Join-Path (Join-Path $SkillDir '..\..\scripts') 'mcp-siding.mjs') `
  --print-shim-script --platform windows `
  --backend-url <URL> --name <NAME> --app "<APP_PATH>" | Out-String
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
```

`Resolve-McpSidingNode` throws with a diagnostic naming every path it
tried (and every `node` it rejected as too old) rather than returning
nothing — if it throws, stop and report that; do not register.

| Harness | Add | Verify | Remove |
| --- | --- | --- | --- |
| Claude Code | `claude mcp add <NAME> -s user -- powershell -NoProfile -NonInteractive -EncodedCommand $encoded` | `claude mcp get <NAME>` — must report `Connected` | `claude mcp remove <NAME> -s user` |
| Codex | `codex mcp add <NAME> -- powershell -NoProfile -NonInteractive -EncodedCommand $encoded` | `codex mcp get <NAME>`, THEN the probe below | `codex mcp remove <NAME>` |

The Claude/Codex asymmetry is exactly as described in the POSIX section —
`claude mcp get` really connects, `codex mcp get` only echoes stored
config — so Codex still needs a real probe. The Windows spelling of it:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' |
  powershell -NoProfile -NonInteractive -EncodedCommand $encoded
```

A valid response is a JSON-RPC result carrying `protocolVersion`; anything
else (empty stdout, a resolver diagnostic on stderr, a nonzero exit) is a
failed mutation.

To read back what a registration actually runs — the registered command is
one opaque base64 token, which is the point, but it makes diagnosis
opaque too:

```powershell
[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
```

Two Windows-specific notes worth carrying:

- The version-directory scan compares versions **numerically**, so
  `0.10.0` outranks `0.7.4`. Both harness caches
  (`%USERPROFILE%\.claude\plugins\cache` and the `.codex` equivalent) are
  scanned in one pass, so a Codex-updated roundhouse wins over a stale
  Claude copy and vice versa.
- `MCP_SIDING_PATH` and `MCP_SIDING_NODE` fail closed here identically to
  the POSIX resolvers — set but unusable is an error naming the override,
  never a silent fallback. See "Local development" below; pass them with
  `-e NAME=VALUE` (Claude) or `--env NAME=VALUE` (Codex) exactly as there.

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
re-add — always, on both harnesses, but for different reasons verified
separately: `claude mcp add` genuinely rejects an existing name (`MCP
server <NAME> already exists`, exit 1), a safety net that catches a
stray double-add. `codex mcp add` does **not** — a second `codex mcp add`
for the same name exits 0 and silently overwrites the existing
registration with whatever was just passed (verified: re-adding the same
name with a different command replaced it in place, one entry, no
warning). Do not rely on Codex to catch a forgotten remove; the
remove-then-re-add sequence is what keeps this safe there, not the tool.

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
  every path it checked. That subprocess-level failure is identical on
  both harnesses, since both spawn the literal identical `/bin/sh -c
  "$SCRIPT"` command — but the two harnesses do not surface it
  identically, and this skill's own post-checks do not treat it
  identically either (see Install a server above): `claude mcp get`
  reports `Failed to connect` directly, a genuine probe; `codex mcp get`
  never attempts to connect at all and will not show this, so the manual
  `initialize` probe in Install a server is what actually catches it on
  Codex.
- **Native Windows is unverified on a real Windows host.** The PowerShell
  route above is implemented and tested — `scripts/mcp-siding-windows.ps1
  -SelfTest` covers numeric version ordering across both harness caches,
  the fail-closed overrides, the `fetch`/`ReadableStream` capability
  probe, Windows argument quoting, and a parse of the exact registration
  `--print-shim-script --platform windows` generates — but that self-test
  runs under PowerShell, not under a real `claude mcp add` on a real
  Windows machine. What remains unproven is the end-to-end registration:
  the harness CLI accepting the `-EncodedCommand` argument, and
  `powershell.exe` (5.1) handing stdio to `node` unchanged. WSL remains
  the route with production mileage. If the native route misbehaves, the
  first thing to check is the decoded registration (see Install on native
  Windows) and the resolver's own stderr.

## Cloud

Not verified directly — treat as expected-to-work, unverified. The resolver
depends on the plugin cache existing under that session's `$HOME`; if a
cloud registration fails, its stderr (see the resolver-finds-nothing hole
above) names exactly which paths it checked there.

## Self-check

```bash
node "$SKILL_DIR/../../scripts/mcp-siding.mjs" --selftest
```

Exercises the shim end to end — parsing, timeouts, caching, recovery,
notification forwarding, the resolver, and more — against fake backends
and temp directories only, never the real caches. Exits non-zero on any
failure.

The PowerShell resolver has its own, which needs a PowerShell host (so it
runs on Windows, or anywhere `pwsh` is installed) and a `node` on PATH:

```powershell
pwsh -NoProfile -NonInteractive -File "$SkillDir\..\..\scripts\mcp-siding-windows.ps1" -SelfTest
```
