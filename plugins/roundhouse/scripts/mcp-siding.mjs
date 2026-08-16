#!/usr/bin/env node
// mcp-siding.mjs — resilient stdio MCP shim for a desktop-app HTTP MCP backend.
//
// Desktop apps that host an MCP server (Autodesk Fusion at
// http://127.0.0.1:27182/mcp, Figma at :3845, ...) only serve it while the
// app is running. Registering that URL directly with an MCP client means a
// failed server every session the app is closed, and no reconnect when it
// opens later - the client has to be restarted. This shim always starts
// clean as a stdio MCP server, proxies to the backend when it is up, serves
// a disk-cached tool list when it is down (so tools stay visible to the
// model), turns "backend is down" into a normal isError result instead of a
// transport failure, reconnects on the next call with no client restart, and
// can launch the app on demand from a real tools/call.
//
// Zero external dependencies - Node stdlib and global fetch only. Ported
// from the working ~/.claude/bin/fusion-mcp-shim.py reference (same shape,
// same message text, same launch-on-demand contract), generalized so one
// script instance serves any backend via CLI flags.
//
// The self-test lives in the sibling mcp-siding.selftest.mjs (imports the
// exports below); `--selftest` here is a thin delegation to it, kept so the
// command line is unchanged. Both files must ship together in the same
// scripts/ directory - the test file resolves this one by a relative
// sibling import, not a hardcoded path, so the pair works from any location.
//
// Usage:
//   mcp-siding.mjs --backend-url URL --name NAME [options]
//   mcp-siding.mjs --selftest
//
// See --help for the full flag list.

import { createInterface } from "node:readline";
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

export const PROTOCOL_VERSION = "2025-06-18";

// ---------------------------------------------------------------------------
// Resolver: the shell snippet a registration embeds via `/bin/sh -c` so the
// registration itself never hardcodes a path to this script. Plugin install
// paths are version-pinned for Claude
// (~/.claude/plugins/cache/novotnyllc/roundhouse/<version>/...) and a plugin
// update creates a new version directory - a path baked into a registration
// breaks the moment the old version is pruned. Resolving at spawn time
// instead means every registration keeps working across plugin updates with
// no reinstall. Tried in order, first hit wins:
//   0. $MCP_SIDING_PATH, if set and naming an existing file - the explicit
//      local-development override (see the skill's "Local development"
//      section): register a dev instance with this env var pinned to a
//      working checkout, distinct from a normal install, which resolves
//      through the branches below instead.
//   1. $CLAUDE_PLUGIN_ROOT/scripts/mcp-siding.mjs - unpopulated for
//      user-registered servers today (verified), kept first for any future
//      plugin-declared registration where it would be.
//   2. every versioned plugin cache directory across BOTH harnesses -
//      ~/.claude/plugins/cache/*/roundhouse/*/scripts/mcp-siding.mjs and
//      the ~/.codex equivalent - compared in ONE pass, globally newest
//      wins regardless of which harness owns it. (Earlier versions of this
//      resolver checked the whole Claude cache before considering Codex at
//      all, so a Codex-updated roundhouse lost to a stale Claude copy -
//      fixed by scanning both roots in the same loop, exactly like
//      fleet_remote_cli_prologue below.) Verified live on this machine:
//      Codex's plugin cache IS version-nested
//      (~/.codex/plugins/cache/<marketplace>/roundhouse/<version>/...),
//      matching Claude's shape - an earlier version of this comment
//      claimed otherwise from a stale observation.
// POSIX sh only (no bashisms) so it runs on minimal cloud images - and no
// `sort -V`: it isn't POSIX, this repo's own guard section
// (scripts/tests/75-guards.sh) fails the build on it, and its presence in
// an earlier draft only passed locally because this machine's `sort`
// happens to support it. Numeric version comparison instead uses the exact
// awk-based approach `fleet_remote_cli_prologue` in
// scripts/lib/fleet-init.sh already established for this identical
// problem (resolving this plugin's own CLI across both harness caches) -
// modeled on it directly, not reinvented, and kept in sync by hand since
// one is a POSIX heredoc and the other a JS template literal with no
// shared runtime. That prologue extracts a candidate's version with
// `${var%pattern}`; this resolver globs for the version *directory* first
// and reads it with `basename` instead of parameter expansion, because
// this string is a JS template literal AND gets embedded in a
// `claude mcp add`/`codex mcp add` argument - `${...}` here would either
// be JS-interpolated at build time or risk Claude Code's own `${VAR}`
// expansion of registered server args (see below); `$(basename ...)` has
// no braces and is exactly as POSIX. Only bare $VAR forms are used
// elsewhere too, never ${VAR} - Claude Code expands ${VAR} tokens in
// registered server args (verified: ${HOME} resolves, an unset ${VAR}
// warns and passes through literally), and this snippet must reach
// /bin/sh unexpanded. Every expansion is double-quoted since $HOME (and in
// principle CLAUDE_PLUGIN_ROOT) may contain spaces.
export const RESOLVER_SH = `p="$MCP_SIDING_PATH"
[ -n "$p" ] && [ -f "$p" ] || p=""
if [ -z "$p" ]; then
  p="$CLAUDE_PLUGIN_ROOT/scripts/mcp-siding.mjs"
  [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "$p" ] || p=""
fi
if [ -z "$p" ]; then
  # Login profiles can enable Bash's failglob; the first absent harness
  # cache must not stop the other cache from being considered. Same
  # defensive line as fleet_remote_cli_prologue, same reason.
  shopt -u failglob 2>/dev/null || :
  p_best=
  p_best_version=
  mcp_siding_version_gt() {
    awk -F. -v left="$1" -v right="$2" '
      function part(version, part_index, pieces) {
        return split(version, pieces, /[.]/) >= part_index ? pieces[part_index] + 0 : 0
      }
      BEGIN {
        for (part_index = 1; part_index <= 4; part_index++) {
          l = part(left, part_index)
          r = part(right, part_index)
          if (l > r) exit 0
          if (l < r) exit 1
        }
        exit 1
      }
    '
  }
  for p_version_dir in "$HOME"/.claude/plugins/cache/*/roundhouse/* \\
    "$HOME"/.codex/plugins/cache/*/roundhouse/*; do
    p_candidate="$p_version_dir/scripts/mcp-siding.mjs"
    [ -f "$p_candidate" ] || continue
    p_version=$(basename "$p_version_dir")
    case $p_version in
      ''|.*|*.|*..*|*[!0-9.]*) continue ;;
    esac
    if [ -z "$p_best" ] || mcp_siding_version_gt "$p_version" "$p_best_version"; then
      p_best=$p_candidate
      p_best_version=$p_version
    fi
  done
  p=$p_best
fi
if [ -z "$p" ]; then
  echo "mcp-siding: could not find mcp-siding.mjs (checked \\$MCP_SIDING_PATH, \\$CLAUDE_PLUGIN_ROOT, ~/.claude/plugins/cache/*/roundhouse/*/scripts, ~/.codex/plugins/cache/*/roundhouse/*/scripts). Is the roundhouse plugin installed?" >&2
  exit 1
fi`;

// Single-quotes a value for safe literal embedding in the sh script this
// module emits - nothing inside single quotes is special except one, so
// this is correct for arbitrary paths/URLs (including the space in
// "Autodesk Fusion.app") without needing to reason about $ or backslashes.
export function shQuote(value) {
  return `'${String(value).replaceAll("'", `'\\''`)}'`;
}

// Builds the full sh -c script body (resolver + the final exec line) for a
// registration: `RESOLVER_SH` followed by `exec node "$p" <flags>`, flags
// taken only from what the caller explicitly set (mcp-siding.mjs's own
// defaults handle the rest at runtime, so nothing is baked in redundantly).
export function buildShimScript(flags) {
  const args = ["--backend-url", shQuote(flags["backend-url"]), "--name", shQuote(flags.name)];
  if (flags.app) args.push("--app", shQuote(flags.app));
  if (flags.cache) args.push("--cache", shQuote(flags.cache));
  if (flags.timeout) args.push("--timeout", shQuote(flags.timeout));
  if (flags["launch-grace"]) args.push("--launch-grace", shQuote(flags["launch-grace"]));
  // Same tri-state resolution as buildShimFromArgs: either flag's explicit
  // value wins over the other's absence, "off" wins a genuine conflict.
  // Collapsed to the canonical bare form in the generated script - an
  // explicit --launch=false must still forward as --no-launch here, or the
  // spawned shim would fall back to "on iff --app is set" and silently
  // launch anyway.
  const launchOff = flags["no-launch"] === true || flags.launch === false;
  const launchOn = flags.launch === true || flags["no-launch"] === false;
  if (launchOff) args.push("--no-launch");
  else if (launchOn) args.push("--launch");
  return `${RESOLVER_SH}\nexec node "$p" ${args.join(" ")}\n`;
}

// ---------------------------------------------------------------------------
// Errors used to distinguish "backend unreachable" from "backend rejected
// our session id" - the latter gets one transparent reconnect-and-retry,
// the former is reported to the caller.

class Down extends Error {}
class Stale extends Error {}

// A JSON-RPC error envelope from a backend that IS reachable and DID
// answer - an unknown tool, bad arguments, an internal tool error, ...
// Distinct from Down: a live rejection is not downtime. Regression fixed
// here - an earlier version threw Down for this case too (to stop it
// silently laundering into an empty success, the actual bug it fixed),
// which overcorrected into misreporting a live error as the app being
// unreachable, discarding the real message and letting toolsCall relaunch
// an already-running app. Carries the backend's own code/message through
// unchanged.
class BackendReported extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// Per MCP streamable-HTTP: "If a server receives a request with an invalid
// or expired session ID, the server MUST respond with 404." Only 404 is
// classified Stale (worth a reconnect-and-retry); every other non-2xx
// (400, 401, 403, 500, ...) is a real backend problem and must not pay a
// handshake-and-retry on every single call. This can't perfectly
// distinguish a truly expired session from an unrelated 404 (e.g. a
// typo'd --backend-url that happens to hit a route that also 404s) - by
// status code alone there is no way to tell those apart - but it stops
// every OTHER non-2xx from paying that cost, which covers the common case.
const STALE_HTTP_STATUSES = new Set([404]);

// ---------------------------------------------------------------------------
// Response body parsing: an MCP HTTP backend may answer with a plain JSON
// body, an SSE stream, or an empty body (notifications get no response
// payload). For SSE, the server may legally interleave notifications or
// progress updates on the same stream before the real JSON-RPC response -
// this is the normal case for a long call, which is exactly why the
// default timeout is 180s - so every "data:" event is scanned and the one
// whose id matches the request is selected; anything without a matching id
// (a notification) is skipped, never mistaken for the response.

export function parseBody(body, contentType, expectedId) {
  if (!body || !body.trim()) return null;
  if (!(contentType && contentType.includes("text/event-stream"))) {
    return JSON.parse(body);
  }
  if (expectedId === undefined) return null;
  for (const line of body.split("\n")) {
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (!payload) continue;
    const msg = JSON.parse(payload);
    if (msg && typeof msg === "object" && "id" in msg && msg.id === expectedId) return msg;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tool-list cache. Keyed per-backend by the server's display name (the
// installer assigns one name per backend registration), so two shim
// instances - e.g. fusion and figma - never collide on one cache file.

export function readCache(cachePath) {
  try {
    const parsed = JSON.parse(readFileSync(cachePath, "utf8"));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export function writeCache(cachePath, tools) {
  try {
    mkdirSync(dirname(cachePath), { recursive: true });
    writeFileSync(cachePath, JSON.stringify(tools));
  } catch {
    // Best effort - a read-only cache dir degrades to "no cache", not a crash.
  }
}

function defaultCachePath(name) {
  const safe = String(name).replace(/[^A-Za-z0-9._-]+/g, "_") || "mcp-siding";
  return join(homedir(), ".cache", "mcp-siding", `${safe}.json`);
}

// ---------------------------------------------------------------------------
// App launcher. Kept as a swappable field on the Shim (a spawn seam) so
// tests can assert "did we try to launch" without ever spawning anything.

function defaultLauncher(appPath) {
  // ponytail: macOS `open -a` only, since every current preset (Fusion,
  // Figma) is a macOS .app bundle; add a platform branch if a non-mac
  // desktop-app target shows up.
  const child =
    process.platform === "darwin"
      ? spawn("open", ["-a", appPath], { detached: true, stdio: "ignore" })
      : spawn(appPath, [], { detached: true, stdio: "ignore" });
  child.unref();
}

// ---------------------------------------------------------------------------
// The shim itself.

export class Shim {
  constructor(opts) {
    this.url = opts.url;
    this.name = opts.name;
    this.cachePath = opts.cachePath;
    this.timeoutMs = opts.timeoutMs;
    this.launchEnabled = opts.launchEnabled;
    this.appPath = opts.appPath;
    this.launchGraceMs = opts.launchGraceMs;
    this.launcher = opts.launcher ?? defaultLauncher;
    this.sid = null;
    // Separate from `sid`: session management is optional in MCP
    // streamable HTTP, so a backend that never issues a session id would
    // otherwise look permanently "unconnected" and get re-handshaked on
    // every single call.
    this.connected = false;
    this.launchedAt = null;
    // Set once initialize's response is known, cleared alongside
    // sid/connected on any reconnect - see post()/connect().
    this.protocolVersion = null;
  }

  async post(payload, sid) {
    const headers = {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
    };
    if (sid) headers["MCP-Session-Id"] = sid;
    // Required on every request after initialize by the 2025-06-18
    // streamable-HTTP transport - a backend enforcing that contract
    // rejects (HTTP 400) any post-initialization request missing it, which
    // this shim would otherwise misreport as the app simply being down.
    // Absent (undefined) before the first successful initialize, which is
    // correct: the version is what that exchange negotiates.
    if (this.protocolVersion) headers["MCP-Protocol-Version"] = this.protocolVersion;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let res, text;
    try {
      res = await fetch(this.url, {
        method: "POST",
        headers,
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      // The timeout must cover reading the body, not just the headers - a
      // backend that answers 200 and then stalls mid-stream (a legal SSE
      // keepalive that never closes) previously hung here with nothing
      // watching it, blocking every later stdin message behind it (main()
      // serializes all requests through one queue, so one stuck request
      // wedges the whole server).
      text = await res.text();
    } catch (err) {
      throw new Down(err?.message ?? String(err));
    } finally {
      clearTimeout(timer);
    }
    if (!res.ok) {
      if (STALE_HTTP_STATUSES.has(res.status)) throw new Stale(`HTTP ${res.status}`);
      throw new Down(`HTTP ${res.status}`);
    }
    let body;
    try {
      body = parseBody(text, res.headers.get("content-type") || "", payload.id);
    } catch (err) {
      throw new Down(`invalid response body: ${err.message}`);
    }
    return { body, sid: res.headers.get("mcp-session-id") };
  }

  async connect() {
    const { body, sid } = await this.post(
      {
        jsonrpc: "2.0",
        id: 0,
        method: "initialize",
        params: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: { name: "mcp-siding", version: "1" },
        },
      },
      null,
    );
    this.sid = sid ?? null;
    // Capture what the backend actually negotiated, not just what we
    // asked for - a compliant backend may echo back a different (older)
    // version it supports, and that is the value every later request must
    // carry, not our own requested one.
    this.protocolVersion = body?.result?.protocolVersion || PROTOCOL_VERSION;
    await this.post({ jsonrpc: "2.0", method: "notifications/initialized" }, this.sid);
    this.connected = true;
    return body;
  }

  // Calls the backend, reconnecting once if the session went stale (the
  // backend restarted while this shim kept running). A JSON-RPC error
  // envelope from a live, answering backend is a BackendReported failure,
  // not Down - see that class - and does not reset session state (the
  // session itself is still fine; only this one call was rejected).
  async backend(method, params) {
    for (const attempt of [1, 2]) {
      try {
        if (!this.connected) await this.connect();
        const { body } = await this.post({ jsonrpc: "2.0", id: 1, method, params }, this.sid);
        if (body?.error) throw new BackendReported(body.error.code, body.error.message ?? "backend error");
        return body?.result ?? {};
      } catch (err) {
        if (err instanceof BackendReported) throw err;
        this.connected = false;
        this.sid = null;
        this.protocolVersion = null;
        if (err instanceof Stale && attempt === 1) continue;
        throw err instanceof Down ? err : new Down(err?.message ?? String(err));
      }
    }
  }

  // -- message handlers -----------------------------------------------------

  async toolsList(params) {
    try {
      const result = await this.backend("tools/list", params);
      // Guard the cache write on a real array so no future response shape
      // surprise (an error already handled above, or just a malformed
      // `tools` field) can blank a previously good cache. The live result
      // itself passes through unchanged either way - e.g. nextCursor stays
      // intact - this only ever touches what gets written to disk.
      if (Array.isArray(result.tools)) writeCache(this.cachePath, result.tools);
      return result;
    } catch {
      // Never launches - clients call tools/list every session, and
      // launching the app on that would launch it constantly. Applies the
      // same way whether the backend was unreachable (Down) or reachable
      // but rejected the call (BackendReported): tools/list has nowhere to
      // put an error message anyway, so serving the cache is correct
      // either way, not a misreport.
      return { tools: readCache(this.cachePath) };
    }
  }

  async toolsCall(params) {
    try {
      return await this.backend("tools/call", params);
    } catch (err) {
      if (err instanceof BackendReported) {
        // Reachable, and rejected the call - an unknown tool, bad
        // arguments, an internal tool error. Not downtime: never launch,
        // never claim the app is unreachable, surface the real message.
        return this.errorResult(
          err.code != null ? `${err.message} (backend error ${err.code})` : err.message,
        );
      }
      return this.downCallResult();
    }
  }

  downCallResult() {
    if (!this.launchEnabled || !this.appPath) {
      return this.errorResult(
        `${this.name} is not reachable at ${this.url}. Ask the user to open the app, ` +
          "then retry - no restart needed.",
      );
    }
    const now = Date.now();
    if (this.launchedAt != null && now - this.launchedAt < this.launchGraceMs) {
      const ageSec = Math.round((now - this.launchedAt) / 1000);
      return this.errorResult(
        `${this.name} is still starting (launched ${ageSec}s ago) and its backend is not ` +
          "answering yet. Wait a bit longer, then retry.",
      );
    }
    this.launchedAt = now;
    try {
      this.launcher(this.appPath);
    } catch {
      // Best effort - report "starting" regardless; the next call will
      // re-evaluate reachability on its own.
    }
    return this.errorResult(
      `${this.name} was not running, so I started it (${this.appPath}). Cold start takes ` +
        "roughly a minute. Tell the user it is starting, wait, then retry this call - the " +
        "connection recovers on its own. If it then reports no active document, a freshly " +
        "launched app may need one opened or created.",
    );
  }

  errorResult(text) {
    return { content: [{ type: "text", text }], isError: true };
  }

  async handle(msg) {
    const method = msg?.method;
    const id = msg?.id;
    const params = msg?.params ?? {};

    if (method === "initialize") {
      // Answered locally so the server always starts, backend up or not.
      return ok(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: this.name, version: "1.0.0" },
      });
    }
    if (typeof method === "string" && method.startsWith("notifications/")) return null;
    // A message with no id cannot be answered - and, critically, this must
    // gate every dispatch branch below, not just the generic fallback:
    // tools/call can launch the app, and a launch for a reply nobody will
    // ever read is a real, user-visible side effect, not a no-op.
    if (id === undefined) return null;
    if (method === "ping") return ok(id, {});
    if (method === "tools/list") return ok(id, await this.toolsList(params));
    if (method === "tools/call") return ok(id, await this.toolsCall(params));
    try {
      const result = await this.backend(method, params);
      return ok(id, result);
    } catch (err) {
      const code = err instanceof BackendReported && err.code != null ? err.code : -32000;
      return { jsonrpc: "2.0", id, error: { code, message: err.message } };
    }
  }
}

function ok(id, result) {
  return id === undefined ? null : { jsonrpc: "2.0", id, result };
}

// ---------------------------------------------------------------------------
// CLI

const BOOL_FLAGS = new Set(["selftest", "help", "launch", "no-launch", "print-resolver", "print-shim-script"]);

// Throws a plain Error, with a message meant to be shown to the user
// as-is, on any argv shape it can't make sense of - the caller (run())
// turns that into usage()+exit(2) rather than a stack trace.
export function parseArgs(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    const key = eq === -1 ? arg.slice(2) : arg.slice(2, eq);
    if (BOOL_FLAGS.has(key)) {
      if (eq === -1) {
        flags[key] = true;
        continue;
      }
      // --flag=value forms are still meaningful for a boolean flag (most
      // concretely --no-launch=false / --launch=false) - interpreted as a
      // string, "false" is truthy, so --no-launch=false previously
      // disabled launch, the opposite of what it reads as.
      const raw = arg.slice(eq + 1).toLowerCase();
      if (raw === "true" || raw === "1") flags[key] = true;
      else if (raw === "false" || raw === "0") flags[key] = false;
      else throw new Error(`invalid value for --${key}: ${arg.slice(eq + 1)} (expected true or false)`);
      continue;
    }
    if (eq !== -1) {
      flags[key] = arg.slice(eq + 1);
      continue;
    }
    const value = argv[i + 1];
    // Never treat the next flag as this one's value - a missing --timeout
    // value used to silently swallow the following --whatever token.
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`missing value for --${key}`);
    }
    flags[key] = value;
    i++;
  }
  return flags;
}

// Rejects non-finite or non-positive input with a clear message rather
// than letting a bad/missing numeric flag silently become NaN - which
// downstream is a 0ms timeout or a broken debounce, not an error.
function parsePositiveNumber(value, flagName) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) {
    throw new Error(`invalid value for --${flagName}: ${value} (expected a positive number)`);
  }
  return n;
}

function usage() {
  return `usage: mcp-siding.mjs --backend-url URL --name NAME [options]

Required (unless --selftest / --print-resolver / --print-shim-script):
  --backend-url URL      HTTP MCP backend, e.g. http://127.0.0.1:27182/mcp
  --name NAME             Server display name reported to the MCP client

Options:
  --app PATH               App to launch on demand (macOS .app bundle path)
  --cache PATH              Tool-list cache file (default: ~/.cache/mcp-siding/<name>.json)
  --timeout MS               Backend request timeout in ms (default: 180000)
  --launch / --no-launch      Launch-on-demand opt-in/out (default: on iff --app is set)
  --launch-grace SECONDS      Debounce window before relaunching (default: 150)
  --selftest                   Run the built-in self-check (delegates to the sibling
                                 mcp-siding.selftest.mjs) and exit
  --print-resolver              Print the POSIX sh backend-path resolver and exit
  --print-shim-script            Print the full sh -c registration script (resolver +
                                   exec line) for --backend-url/--name/--app/etc and exit
  --help                        Show this message
`;
}

// Pure and testable: throws a plain Error (message meant to be shown
// as-is) on anything invalid, never calls process.exit itself. main() is
// the only caller and is the CLI boundary that turns a thrown error into
// usage()+exit(2).
export function buildShimFromArgs(flags) {
  const url = flags["backend-url"];
  const name = flags.name;
  // Both required, matching usage() - the installer always passes --name
  // explicitly anyway (the cache is keyed on it), so a silent "mcp-siding"
  // default here just meant two unrelated instances misconfigured the same
  // way would silently collide on one cache file instead of failing loudly.
  if (!url || !name) {
    throw new Error("--backend-url and --name are required");
  }
  const appPath = flags.app ?? null;
  const timeoutMs = parsePositiveNumber(flags.timeout ?? 180_000, "timeout");
  const launchGraceMs = parsePositiveNumber(flags["launch-grace"] ?? 150, "launch-grace") * 1000;
  const cachePath = flags.cache ?? defaultCachePath(name);
  // --no-launch and --launch are two spellings of one boolean; either
  // flag's *explicit* value wins over the other's absence, "off" wins a
  // genuine conflict (e.g. both passed bare), and neither present falls
  // back to the old default of "on iff an app is configured". Explicit
  // false now means false (a plain truthy-string bug before parseArgs
  // started producing real booleans for --flag=value on a bool flag).
  const launchOff = flags["no-launch"] === true || flags.launch === false;
  const launchOn = flags.launch === true || flags["no-launch"] === false;
  const launchEnabled = launchOff ? false : launchOn ? true : Boolean(appPath);
  return new Shim({ url, name, cachePath, timeoutMs, launchEnabled, appPath, launchGraceMs });
}

function main(flags) {
  // Built before stdin opens: an invalid flag combination exits(2) here,
  // rather than opening a stdio server that would just sit there silent.
  let shim;
  try {
    shim = buildShimFromArgs(flags);
  } catch (err) {
    process.stderr.write(`${err.message}\n${usage()}`);
    process.exit(2);
  }
  const rl = createInterface({ input: process.stdin, terminal: false });

  // Process lines strictly in order: concurrent handling could race two
  // in-flight requests over the same session id (this.sid).
  let queue = Promise.resolve();
  rl.on("line", (raw) => {
    const line = raw.trim();
    if (!line) return;
    queue = queue.then(async () => {
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        // Never die on one malformed stdin message.
        emit({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
        return;
      }
      let response;
      try {
        response = await shim.handle(msg);
      } catch (err) {
        response = {
          jsonrpc: "2.0",
          id: msg?.id ?? null,
          error: { code: -32603, message: String(err?.message ?? err) },
        };
      }
      if (response != null) emit(response);
    });
  });
}

function emit(response) {
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

function run() {
  let flags;
  try {
    flags = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`${err.message}\n${usage()}`);
    process.exit(2);
  }
  if (flags.help) {
    process.stdout.write(usage());
    return;
  }
  if (flags["print-resolver"]) {
    process.stdout.write(`${RESOLVER_SH}\n`);
    return;
  }
  if (flags["print-shim-script"]) {
    if (!flags["backend-url"] || !flags.name) {
      process.stderr.write(usage());
      process.exit(2);
    }
    process.stdout.write(buildShimScript(flags));
    return;
  }
  if (flags.selftest) {
    // Thin delegation to the sibling test file, resolved relative to this
    // module's own location (not CWD) so the pair works from anywhere,
    // including a relocated copy of the scripts/ directory. Keeps
    // `node mcp-siding.mjs --selftest` working unchanged.
    import("./mcp-siding.selftest.mjs")
      .then((mod) => mod.selftest())
      .then(() => process.exit(0))
      .catch((err) => {
        process.stderr.write(`selftest FAILED: ${err.stack ?? err}\n`);
        process.exit(1);
      });
    return;
  }
  main(flags);
}

// Only run when this file is the program Node was invoked on - not when
// mcp-siding.selftest.mjs (or anything else) imports it for its exports.
// fileURLToPath, not the raw URL .pathname, for the same reason the
// self-test spawns children by fileURLToPath: .pathname is percent-encoded
// and breaks on a path containing a space. realpathSync on the argv[1]
// side matters too, separately from that: Node's loader resolves symlinks
// when it turns the entry-point path into import.meta.url (verified: on
// macOS, invoking via a path under /tmp or /var produces a
// /private/tmp or /private/var import.meta.url, since both are symlinks
// there), so a purely lexical resolve() of argv[1] silently never matches
// and this guard would never fire under any invocation through a
// symlinked directory - not just an edge case, since /tmp is exactly
// that on macOS, and this file's own self-test copies itself there.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(resolve(process.argv[1]))) {
  run();
}
