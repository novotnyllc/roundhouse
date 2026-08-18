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
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, renameSync, unlinkSync, realpathSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

export const PROTOCOL_VERSION = "2025-06-18";

// Versions this shim will serve to a CLIENT. It is deliberately dual-era: the
// backend (a desktop app's MCP server) is legacy and will be for a long time,
// while the harness on the other side may modernize at any point. Per the
// 2026-07-28 compatibility matrix a legacy-only server FAILS a modern client,
// and a legacy-only client FAILS a modern server — so being dual-era is what
// keeps the shim working while either side moves. Newest first: a client
// choosing from this list should land on the newest we both support.
export const SUPPORTED_PROTOCOL_VERSIONS = ["2026-07-28", "2025-11-25", "2025-06-18"];

// The newest revision we speak; what the backend-era probe asks for.
export const MODERN_PROTOCOL_VERSION = "2026-07-28";

// JSON-RPC error code for UnsupportedProtocolVersionError (spec 2026-07-28).
export const UNSUPPORTED_PROTOCOL_VERSION = -32022;

// JSON-RPC "method not found". The ONLY error that identifies a legacy server:
// it means the method is unknown, which is exactly a legacy server's answer to
// server/discover. Every other error says the request failed, which is not a
// statement about the protocol.
export const METHOD_NOT_FOUND = -32601;

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export const PROTOCOL_VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion";

// The version a request declares, if it speaks the modern per-request style.
// Absent means legacy: the caller negotiated (or will negotiate) by handshake.
export function requestedProtocolVersion(params) {
  const meta = params?._meta;
  if (meta === null || typeof meta !== "object") return undefined;
  const v = meta[PROTOCOL_VERSION_META_KEY];
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

// ---------------------------------------------------------------------------
// Resolver: the shell snippet a registration embeds via `/bin/sh -c` so the
// registration itself never hardcodes a path to this script. Plugin install
// paths are version-pinned for Claude
// (~/.claude/plugins/cache/novotnyllc/roundhouse/<version>/...) and a plugin
// update creates a new version directory - a path baked into a registration
// breaks the moment the old version is pruned. Resolving at spawn time
// instead means every registration keeps working across plugin updates with
// no reinstall. Tried in order, first hit wins:
//   0. $MCP_SIDING_PATH, if set - the explicit local-development override
//      (see the skill's "Local development" section): register a dev
//      instance with this env var pinned to a working checkout, distinct
//      from a normal install, which resolves through the branches below
//      instead. An explicit pin is an assertion of intent, not a hint: if
//      it is set but names a file that does not exist (renamed, deleted,
//      an unmounted volume), this fails closed rather than silently
//      falling through to an installed build - running a published
//      version while the user believes they are exercising their working
//      tree is exactly the misleading result dev mode exists to avoid.
//      Only UNSET (or empty) falls through to the branches below.
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
if [ -n "$p" ] && [ ! -f "$p" ]; then
  echo "mcp-siding: \\$MCP_SIDING_PATH is set to '$p' but that file does not exist - this is an explicit local-development override, not a hint, so it must name a real file rather than silently falling back to an installed build." >&2
  exit 1
fi
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

// Node resolver: finds a node that can actually RUN this shim before the
// final exec, not merely a node that exists. Resolving mcp-siding.mjs's
// path (above) is not enough on its own - a GUI-launched harness on macOS
// does not inherit a login shell's PATH, and a self-contained Claude/Codex
// install does not guarantee a `node` on PATH at all, so the registration
// would resolve the script and then fail to start anything. And existence
// alone is not enough either: an old Node (16, say) starts the server fine
// and then throws ReferenceError: fetch is not defined on the first
// backend request - which this shim classifies as Down, producing silent
// empty tool listings and launches of an already-running app. So every
// candidate is probed for what this shim actually needs - a cheap `-e`
// check for global fetch and ReadableStream, one exec per candidate, run
// at every server start - rather than accepted on existence or compared
// by version number (a proxy for the capability, not the capability
// itself; version numbers also drift out of date the moment a
// runtime backports or removes a feature).
//
// Candidates tried in order, first one that PASSES THE PROBE wins:
//   0. $MCP_SIDING_NODE - the same kind of explicit override
//      $MCP_SIDING_PATH above is, for the same reason, including the same
//      fail-closed rule: set but unusable (missing, not executable, or
//      failing the capability probe below) exits non-zero naming the
//      override, rather than silently continuing to PATH/the fixed
//      fallbacks - a registration could otherwise quietly run under a
//      different Node than the one being pinned for testing. Only UNSET
//      (or empty) falls through to the branches below - same distinction,
//      same reason, one rule applied to both overrides in this file.
//   1. `command -v node` - the normal case, an already-working PATH.
//   2. Common install locations: Homebrew's arm64 and x86_64 default
//      prefixes, then /usr/bin, then Volta's and asdf's default shims.
//      nvm is deliberately skipped - its active version lives behind an
//      alias file, not a fixed path, so a cheap existence check cannot
//      resolve it the way it can for Volta/asdf.
// A harness-bundled node is deliberately NOT probed here, unlike
// codex-plugin-hooks.ps1's Windows resolver (which locates Codex's and
// Claude Desktop's own bundled node.exe): that Windows logic was built
// from verified, empirical install-layout knowledge. No equivalent
// macOS/Linux bundle path is currently known, and guessing one would be
// worse than not trying it - a wrong path fails exactly like no path, but
// with false confidence that it was checked.
// Same POSIX-sh-only constraint as RESOLVER_SH above, for the same reason
// (minimal cloud images), and the same fail-closed shape: if nothing
// qualifies, exit non-zero with a diagnostic naming what was tried AND
// what was rejected (and why), rather than exec'ing an empty command or
// starting a server that is guaranteed to fail on its first real request.
//
// SKILL.md's "Install a server" section duplicates this exact candidate
// list and probe (as a standalone snippet run before `--print-shim-script`
// itself, which needs a working node just to be generated at all - the
// same bootstrap problem this resolver exists to solve at spawn time).
// Keep the two in sync; mcp-siding.selftest.mjs extracts and runs the
// SKILL.md copy directly against this list's own test scenarios, so a
// drift between them fails the test suite rather than surfacing only as
// an install succeeding under one node and the server spawning under
// another.
export const NODE_RESOLVER_SH = `node_ok() {
  [ -x "$1" ] || return 1
  "$1" -e 'if (typeof fetch !== "function" || typeof ReadableStream !== "function") process.exit(1)' >/dev/null 2>&1
}
if [ -n "$MCP_SIDING_NODE" ]; then
  if [ ! -x "$MCP_SIDING_NODE" ]; then
    echo "mcp-siding: \\$MCP_SIDING_NODE is set to '$MCP_SIDING_NODE' but that file does not exist or is not executable - this is an explicit override, not a hint, so it must name a usable node rather than silently falling back to another one." >&2
    exit 1
  fi
  if ! node_ok "$MCP_SIDING_NODE"; then
    echo "mcp-siding: \\$MCP_SIDING_NODE is set to '$MCP_SIDING_NODE' but it lacks global fetch/ReadableStream (this shim needs Node 18+) - this is an explicit override, not a hint, so it must name a usable node rather than silently falling back to another one." >&2
    exit 1
  fi
fi
node_bin=""
node_rejected=""
for node_candidate in "$MCP_SIDING_NODE" "$(command -v node 2>/dev/null)" \\
  /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node \\
  "$HOME/.volta/bin/node" "$HOME/.asdf/shims/node"; do
  [ -n "$node_candidate" ] || continue
  if node_ok "$node_candidate"; then
    node_bin=$node_candidate
    break
  fi
  [ -x "$node_candidate" ] && node_rejected="$node_rejected $node_candidate"
done
if [ -z "$node_bin" ]; then
  node_diag="mcp-siding: no node with global fetch/ReadableStream (this shim needs Node 18+) found (checked \\$MCP_SIDING_NODE, PATH, /opt/homebrew/bin, /usr/local/bin, /usr/bin, Volta, asdf)."
  if [ -n "$node_rejected" ]; then
    node_diag="$node_diag Rejected as too old:$node_rejected."
  fi
  echo "$node_diag Install a newer Node or set \\$MCP_SIDING_NODE." >&2
  exit 1
fi`;

// Single-quotes a value for safe literal embedding in the sh script this
// module emits - nothing inside single quotes is special except one, so
// this is correct for arbitrary paths/URLs (including the space in
// "Autodesk Fusion.app") without needing to reason about $ or backslashes.
export function shQuote(value) {
  return `'${String(value).replaceAll("'", `'\\''`)}'`;
}

// Single-quotes a value for literal embedding in the PowerShell script this
// module emits for a native-Windows registration. PowerShell single-quoted
// strings are fully literal - a doubled '' is the only escape, and neither
// $ nor \ nor " means anything inside them - so this is correct for
// arbitrary paths and URLs, exactly like shQuote is for sh.
export function psQuote(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

// The shim's own argv for one registration, unquoted: only what the caller
// explicitly set (mcp-siding.mjs's defaults handle the rest at runtime, so
// nothing is baked in redundantly). Shared by both script builders so the
// POSIX and PowerShell registrations can never disagree about which flags
// a given set of install options produces - only about how they are
// quoted.
function shimFlagArgs(flags) {
  const args = ["--backend-url", flags["backend-url"], "--name", flags.name];
  if (flags.app) args.push("--app", flags.app);
  if (flags.cache) args.push("--cache", flags.cache);
  if (flags.timeout) args.push("--timeout", flags.timeout);
  if (flags["launch-grace"]) args.push("--launch-grace", flags["launch-grace"]);
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
  return args.map(String);
}

// Builds the full sh -c script body (resolvers + the final exec line) for
// a registration: `RESOLVER_SH`, then `NODE_RESOLVER_SH`, then
// `exec "$node_bin" "$p" <flags>`.
export function buildShimScript(flags) {
  return `${RESOLVER_SH}\n${NODE_RESOLVER_SH}\nexec "$node_bin" "$p" ${shimFlagArgs(flags).map(shQuote).join(" ")}\n`;
}

// The marked region of the sibling mcp-siding-windows.ps1 - the PowerShell
// twin of RESOLVER_SH + NODE_RESOLVER_SH, plus the launcher that hands
// this process's stdio to node. Extracted rather than duplicated here: that
// file is the single source, it carries its own -SelfTest (run by the
// Windows CI job and by this script's own self-test), and a registration
// built from it therefore runs exactly the text those tests exercise.
export function extractWindowsResolver(ps1Text) {
  const match = ps1Text.match(
    /^# <!-- mcp-siding: windows-resolver:start -->\n([\s\S]*?)\n# <!-- mcp-siding: windows-resolver:end -->$/m,
  );
  if (!match) {
    throw new Error("mcp-siding-windows.ps1: the windows-resolver marker region was not found - did that file's structure change?");
  }
  return match[1];
}

// Resolved as a sibling of THIS module, not from CWD or a fixed path, for
// the same reason the self-test resolves its own subject that way: the
// pair has to keep working from any copy of the scripts/ directory.
function readWindowsResolver() {
  const ps1Path = fileURLToPath(new URL("./mcp-siding-windows.ps1", import.meta.url));
  let text;
  try {
    text = readFileSync(ps1Path, "utf8");
  } catch (err) {
    throw new Error(`--platform windows needs the sibling mcp-siding-windows.ps1 (${ps1Path}): ${err.message}`);
  }
  return extractWindowsResolver(text);
}

// The native-Windows registration body: the PowerShell resolver region,
// then one Invoke-McpSidingShim call carrying this instance's flags. Same
// contract as buildShimScript - self-contained text that resolves the
// script and a usable node at every spawn, so a plugin update is picked up
// with nothing to reinstall.
export function buildShimScriptPowerShell(flags, resolverPs1) {
  return `${resolverPs1}\nInvoke-McpSidingShim -ShimArgs @(${shimFlagArgs(flags).map(psQuote).join(", ")})\n`;
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

// A non-2xx HTTP response that is NOT the stale-session case (404) - a
// real HTTP-level failure (401, 400, 500, ...) from a backend that DID
// answer. Same reasoning as BackendReported, one layer down: reachability
// is the distinction, not status code. If an HTTP response arrived at all,
// the app is running, so this must never launch or be reported as
// "not reachable" - only genuine transport failure (post()'s fetch/timeout
// catch, below) may. Carries the raw status and a body snippet, since
// there is no JSON-RPC envelope to read a code/message from here.
class HttpRejected extends Error {
  constructor(status, bodySnippet) {
    super(`HTTP ${status}${bodySnippet ? `: ${String(bodySnippet).slice(0, 200)}` : ""}`);
    this.status = status;
    // The spec's documented modern-detection case is an
    // UnsupportedProtocolVersionError delivered inside an HTTP 400, so the era
    // probe has to be able to READ the body of a rejection. Parsed here, once,
    // rather than making every caller re-parse a snippet.
    this.body = null;
    try { this.body = JSON.parse(bodySnippet); } catch { /* not JSON: no body to offer */ }
  }
}

// A client-initiated cancellation (notifications/cancelled), not downtime
// and not a backend rejection - we stopped waiting, the backend did not go
// away. Set as post()'s AbortController's `abort(reason)` so the catch
// block there can tell a deliberate cancel apart from a timeout-triggered
// abort, which both produce the same AbortError from fetch/res.text().
class Cancelled extends Error {}

// A response body that could not be parsed as the protocol expects -
// malformed JSON, a malformed SSE data payload, or (e.g.) an HTML error
// page from an intermediary proxy served with a 200. Same reachable-is-
// not-down principle as BackendReported/HttpRejected/the sessionless-404
// fix: a response arrived, so the app is up - only a fetch/stream failure
// or a timeout (post()'s outer catch, below) is downtime. Thrown directly
// from the parse paths (parseBody/parseSseEvent) and rethrown as-is by
// post()'s catch, the same way Cancelled is.
class MalformedResponse extends Error {}

// Presence of `result` (checked by backend(), just above where this is
// called) is not the same as it having the right shape - {"result": null}
// or a tools/call result with no `content` array both pass that check and
// would otherwise be forwarded as a successful call, after the operation
// may already have run. Deliberately narrow: only the one thing each
// method's result type requires per MCP, not a schema validator - this is
// not the place to reject a shape a real backend legitimately sends.
// Methods with no shape requirement here (initialize, ...) pass through
// unchecked.
// A client that DECLARED a modern protocol version relies on resultType to
// tell a complete answer from an interim one, and the backend is legacy and
// supplies none - so without this the normal app-up tools/list and tools/call
// paths hand a modern client legacy-shaped results for nearly every real call.
//
// Applied only when the request declared a modern version. A legacy client
// neither expects the field nor benefits from it, and adding it there would
// change bytes on the wire for callers that never asked to move.
//
// Absent means complete: an interim result always states its own resultType
// (input_required), so anything silent is a finished answer. Never overwrite
// one the backend did set.
function withResultType(result, declaredVersion) {
  if (declaredVersion === undefined || declaredVersion < "2026-07-28") return result;
  if (result === null || typeof result !== "object" || Array.isArray(result)) return result;
  if (result.resultType !== undefined) return result;
  return { ...result, resultType: "complete" };
}

export function validateResultShape(method, result) {
  // MCP 2026-07-28 multi-round-trip requests: an INTERIM result carries
  // `resultType: "input_required"` and neither a `content` nor a `tools` array,
  // because the operation has not produced one yet - it is asking for input.
  // The per-method checks below would call that malformed and turn a legitimate
  // response into an error the moment a backend adopts the newer revision. Only
  // a `complete` result (or an older backend that says nothing, which is the
  // same thing) is subject to shape rules.
  if (result !== null && typeof result === "object" && result.resultType !== undefined && result.resultType !== "complete") return;
  if (method === "tools/call") {
    if (result === null || typeof result !== "object" || !Array.isArray(result.content)) {
      throw new MalformedResponse(`${method}: result is not a valid CallToolResult (missing a content array)`);
    }
  } else if (method === "tools/list") {
    if (result === null || typeof result !== "object" || !Array.isArray(result.tools)) {
      throw new MalformedResponse(`${method}: result is not a valid ListToolsResult (missing a tools array)`);
    }
  } else if (method === "initialize") {
    // N45: presence of `result` is not shape, same as N37 one level up -
    // {"result":null} or {"result":{}} used to complete the handshake,
    // send notifications/initialized, mark the session connected, and
    // forward the caller's (possibly mutating) request to a backend that
    // never actually negotiated a session. Required here: protocolVersion
    // (a non-empty string - connect() reads this value directly right
    // after, see this.protocolVersion below) and capabilities (an object -
    // its presence is part of a valid handshake per MCP even though this
    // shim does not inspect any specific capability flag). serverInfo is
    // also spec-required but deliberately NOT checked - nothing in this
    // file ever reads it back from a backend's result, so requiring it
    // would only add a way to reject an otherwise-fine response for no
    // protective benefit, the same restraint N37 already applied.
    if (
      result === null ||
      typeof result !== "object" ||
      typeof result.protocolVersion !== "string" ||
      result.protocolVersion === "" ||
      result.capabilities === null ||
      typeof result.capabilities !== "object"
    ) {
      throw new MalformedResponse(`${method}: result is not a valid InitializeResult (missing protocolVersion or capabilities)`);
    }
  }
}

// The rule this encodes: classify by whether the request is PROVEN
// UNDELIVERED, not by whether we aborted it. A timeout (post()'s own timer
// fired - Cancelled is already ruled out before this class is ever thrown,
// see post()'s catch) never proves the backend did not receive the
// request, whether or not headers ever arrived. Neither does a connection
// that failed AFTER the request was already transmitted - a reset, EPIPE,
// or socket hang-up (Node/undici surface this as cause.code
// UND_ERR_SOCKET/ECONNRESET/EPIPE) means the app may have crashed or
// restarted mid-operation, not that it never saw the request. Only a
// failure proven to precede delivery - connection refused, host
// unreachable, DNS failure (cause.code ECONNREFUSED/EHOSTUNREACH/
// ENOTFOUND/EAI_AGAIN) - proves nothing was delivered; see
// PROVEN_UNDELIVERED_CODES below, which post()'s catch checks explicitly,
// defaulting every other (including unrecognized) code to Indeterminate -
// the safe direction is to under-claim downtime, never to over-claim it.
// Aborting our own fetch, or the connection failing out from under us,
// does not stop the backend from continuing whatever it started, so
// retrying (and worse, downCallResult() launching an already-running app)
// can duplicate a mutation - for CAD, running the operation twice. Never
// launches, never phrased as unreachable - the message says the operation
// may have started and may still be running, so a retry could repeat it.
class Indeterminate extends Error {}

// Error codes that PROVE a request was never delivered - the connection
// itself never succeeded, so nothing reached the backend. Anything else
// (a reset/EPIPE/hang-up after the request went out, or a code this list
// does not recognize) defaults to Indeterminate in post()'s catch, on
// purpose: understating downtime is safe, overstating it risks a launch
// and a retry that duplicates a mutation.
const PROVEN_UNDELIVERED_CODES = new Set(["ECONNREFUSED", "ENOTFOUND", "EHOSTUNREACH", "EAI_AGAIN"]);

// N47: the fixed, published "bad port" list fetch() (via undici/the Fetch
// spec's port-blocking list) refuses client-side, for any of these ports,
// before attempting a connection at all - reserved for other protocols
// (echo, ftp-data, telnet, smtp, ...), not something a real MCP backend
// would ever legitimately use. Embedded here (matches the WHATWG Fetch
// spec's list, verified live against this runtime) rather than probed,
// since it never changes at runtime and probing would mean actually
// trying to connect. buildShimFromArgs rejects a --backend-url naming one
// of these at validation time (before any registration or connection
// attempt); post()'s catch, independently, classifies a "bad port"
// rejection reaching the request path some other way as a
// ConfigurationError rather than Indeterminate - see both call sites.
const FETCH_FORBIDDEN_PORTS = new Set([
  1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102, 103, 104, 109, 110,
  111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515, 526, 530, 531, 532,
  540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 5060, 5061, 6000,
  6566, 6665, 6666, 6667, 6668, 6669, 6697, 10080,
]);

// The configured backend URL itself is malformed, so fetch() rejected
// before anything was ever transmitted - not even a connection attempt.
// This should be unreachable in practice: buildShimFromArgs validates
// --backend-url at startup, before the stdio server even opens (see N30
// there). Guarded here anyway for any other construction path (e.g. a
// Shim built directly with a raw URL string, bypassing that check).
// Neither Down nor Indeterminate fits: Down's "may launch" is pointless
// here - repeatedly launching the app cannot fix a malformed URL, unlike
// a genuine down-app case - and Indeterminate would say "the operation
// may have run," which is backwards when nothing was ever sent. Never
// launches, never retried, surfaces the real configuration problem.
class ConfigurationError extends Error {}

// Per MCP streamable-HTTP: "If a server receives a request with an invalid
// or expired session ID, the server MUST respond with 404." Only 404 is
// classified Stale (worth a reconnect-and-retry); every other non-2xx
// (400, 401, 403, 500, ...) is a real backend problem and must not pay a
// handshake-and-retry on every single call. This can't perfectly
// distinguish a truly expired session from an unrelated 404 (e.g. a
// typo'd --backend-url that happens to hit a route that also 404s) - by
// status code alone there is no way to tell those apart - but it stops
// every OTHER non-2xx from paying that cost, which covers the common case.
// A 404 can only mean an expired session if the request actually carried
// one - see post()'s `sid &&` guard on this check. A 404 on the initial
// sessionless request (no session established yet) is a real HTTP
// rejection (e.g. a wrong --backend-url path against an otherwise-live
// app), not staleness, and must not be retried as if it were.
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
  // HTTP media types are case-insensitive ("Text/Event-Stream" is the same
  // type as "text/event-stream") - lowercase once here so this function is
  // correct regardless of what a caller passes, not just when post() below
  // happens to have already normalized it.
  const normalizedContentType = (contentType || "").toLowerCase();
  if (!normalizedContentType.includes("text/event-stream")) {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (err) {
      // Reachable (a body arrived at all) - not downtime. Covers malformed
      // JSON and any non-JSON body served as if it were (e.g. an HTML
      // error page from an intermediary proxy).
      throw new MalformedResponse(`malformed response body: ${err.message}`);
    }
    // Same exact-id correlation the SSE path already does (see
    // parseSseEvent's caller, below) - a response carrying a different id
    // (or none at all) than the one this request sent must not be
    // accepted as this call's answer. Without this, a delayed or
    // misrouted response for some other request would be consumed as a
    // false success on the current, possibly mutating, call. Being
    // lenient about a missing/mismatched `jsonrpc` field is fine (some
    // backends omit or vary it) - the id is what actually correlates a
    // response to a request, and it must match exactly.
    if (expectedId !== undefined && (!parsed || typeof parsed !== "object" || parsed.id !== expectedId)) {
      throw new MalformedResponse(`response id mismatch: expected ${JSON.stringify(expectedId)}`);
    }
    return parsed;
  }
  if (expectedId === undefined) return null;
  // SSE events are separated by a blank line; a body with no blank line at
  // all (the common single-event case) is just one event and split() below
  // returns it unsplit - parseSseEvent scans it the same way either way.
  for (const rawEvent of body.split("\n\n")) {
    const msg = parseSseEvent(rawEvent);
    if (msg && typeof msg === "object" && "id" in msg && msg.id === expectedId) return msg;
  }
  return null;
}

// Extracts the JSON-RPC message out of one SSE event's raw text, or null
// if the event carries no "data:" field. Shared by parseBody (a full
// already-buffered body, used for the plain-JSON/empty cases and direct
// unit testing) and readSseUntilMatch (the incremental reader below, used
// for the live SSE case).
//
// Per the SSE spec, an event's data can be split across multiple "data:"
// fields - each contributes one line, joined with "\n" to form the full
// payload (this is how a large JSON body legally gets sent). Parsing only
// the first field would truncate/corrupt any such payload and throw
// MalformedResponse on a perfectly valid response. Also per spec, a single
// leading space right after the colon is stripped ("data: x" and "data:x"
// both yield "x") - anything past that first space is part of the value.
function parseSseEvent(rawEvent) {
  const fields = [];
  for (const line of rawEvent.split("\n")) {
    if (!line.startsWith("data:")) continue;
    const rest = line.slice(5);
    fields.push(rest.startsWith(" ") ? rest.slice(1) : rest);
  }
  if (fields.length === 0) return null;
  const payload = fields.join("\n");
  if (!payload.trim()) return null;
  try {
    return JSON.parse(payload);
  } catch (err) {
    throw new MalformedResponse(`malformed SSE event: ${err.message}`);
  }
}

// Is this parsed value a JSON-RPC message at all - i.e. something that is
// meaningful to hand to an MCP client? Deliberately structural, not a
// schema check: an object carrying jsonrpc "2.0" and either a method (a
// notification, or a server->client request) or a correlated result/error.
// Anything else that happens to sit in an SSE `data:` field - a bare
// number, an array, a keepalive object, a JSON fragment some intermediary
// injected - is not a message and must never be written to the client's
// stdio stream, where it would be a protocol violation the client has no
// way to recover from. Used by readSseUntilMatch before forwarding; the
// awaited response itself never reaches it (that returns first).
function isJsonRpcMessage(msg) {
  if (msg === null || typeof msg !== "object" || Array.isArray(msg)) return false;
  if (msg.jsonrpc !== "2.0") return false;
  if (typeof msg.method === "string") return true;
  return "id" in msg && ("result" in msg || "error" in msg);
}

// ---------------------------------------------------------------------------
// Incremental SSE reading. MCP streamable HTTP explicitly permits a backend
// to deliver the JSON-RPC response matching a request's id and then keep
// the SSE stream open for later events (further progress notifications,
// etc). Waiting for the stream to close (the old `res.text()`) would
// misreport an already-succeeded call as a timeout - and the shim could
// then launch the app after the operation had already succeeded. This
// reads `stream` (a web ReadableStream, i.e. `res.body`) chunk by chunk and
// returns as soon as the event whose id matches `expectedId` arrives,
// without waiting for EOF.
//
// `onMessage`, when given, receives every JSON-RPC message on the stream
// that is NOT the awaited response - a notifications/progress for a
// long-running call, a server->client request, or a (misrouted, delayed)
// response correlated to some other id. That is what lets the shim relay a
// multi-minute operation's progress to the stdio client instead of looking
// stalled (issue #15). Three properties this relies on, all of them
// structural rather than defensive:
//   - The match check runs FIRST, so the awaited response is returned, never
//     forwarded: a notification can never be mistaken for it, and the
//     response can never be double-delivered.
//   - Events are drained in arrival order and this returns at the match, so
//     everything forwarded was genuinely emitted BEFORE the response, and
//     nothing after the match is even parsed - the shim cannot write a
//     stray message once it has moved on.
//   - Only a real JSON-RPC message is passed on (see isJsonRpcMessage);
//     anything else in a `data:` field is dropped, not relayed. A payload
//     that does not parse as JSON at all still throws MalformedResponse
//     exactly as before - unchanged, and never forwarded either.
// The callback is called synchronously from the read loop; the caller (see
// Shim.forwardNotification) is responsible for never throwing back into it.
//
// Timeout/cancellation: this does no signal handling of its own - it
// relies entirely on the same fetch() AbortController/signal that already
// covers the rest of post(). Aborting that controller (on timeout or via
// cancel()) errors the underlying stream, so a pending reader.read() call
// rejects the same way res.text() used to - the surrounding try/catch in
// post() is unchanged and still covers this.
export async function readSseUntilMatch(stream, expectedId, onMessage) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  // A trailing lone \r held back across reads - SSE permits \r\n, \r, or \n
  // as the line terminator, and a \r\n pair can straddle a chunk boundary
  // (\r ending one read, \n starting the next). Normalizing each chunk in
  // isolation (or the whole buffer on every append) would count that split
  // pair as two terminators instead of one - carrying the lone \r forward
  // and folding it into the START of the next chunk keeps a straddled pair
  // intact.
  let carry = "";
  // Process every complete event already in the buffer and keep any
  // trailing partial one for the next chunk - a chunk boundary is not an
  // event boundary, one event can legally arrive split across multiple
  // reads. Called once per chunk, and once more at EOF (see below) to
  // flush a carried trailing \r that turns out to have been the stream's
  // very last byte.
  const drainMatch = () => {
    let sep;
    while ((sep = buffer.indexOf("\n\n")) !== -1) {
      const rawEvent = buffer.slice(0, sep);
      buffer = buffer.slice(sep + 2);
      const msg = parseSseEvent(rawEvent);
      if (msg && typeof msg === "object" && "id" in msg && msg.id === expectedId) return msg;
      // NOTIFICATIONS ONLY - a message with an id is a server-to-client
      // REQUEST (sampling/createMessage, elicitation/create), and we have no
      // path to carry its reply back: the client's response has no method, so
      // handle() would read it as a fresh backend request, and the reply would
      // serialize behind the still-running call that produced it. The backend
      // would wait for a correlated reply that never arrives. Dropping it is
      // safe rather than merely convenient: connect() declares
      // `capabilities: {}` to the backend, so a spec-compliant server has been
      // told this client supports no sampling or elicitation and must not ask.
      // NOTIFICATIONS ONLY - nothing carrying an id may reach the client.
      //
      // Two distinct hazards, one rule. A message with a method AND an id is a
      // server-to-client REQUEST (sampling/createMessage, elicitation/create)
      // and we have no path to carry its reply back: the client's response has
      // no method, so handle() would read it as a fresh backend request, and it
      // would serialize behind the still-running call that produced it. Safe to
      // drop - connect() declares `capabilities: {}`, so a compliant server has
      // been told this client does no sampling or elicitation.
      //
      // A RESPONSE whose id does not match this call must be dropped too, and
      // this is the subtler one: forwardNotification() writes to the client's
      // stdout, but these ids come from this.nextBackendId - the shim's OWN
      // counter for backend requests - not from the client. Relaying one puts a
      // foreign id into the client's id namespace, where it can prematurely
      // satisfy an unrelated pending client request that happens to share the
      // number and make the real reply arrive as a duplicate. There is no
      // caller it could legitimately reach either: readSseUntilMatch is
      // per-request and returns only the matching id, so a foreign response on
      // this stream is orphaned by construction.
      if (onMessage && isJsonRpcMessage(msg) && msg?.id === undefined) onMessage(msg);
    }
    return undefined;
  };
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) {
        // A trailing lone \r held back from the previous chunk, with
        // nothing after it, is still a real terminator, not a partial one -
        // flush it in case it completes a pending delimiter before giving
        // up as "no matching event."
        if (carry) buffer += "\n";
        return drainMatch() ?? null;
      }
      let chunk = carry + decoder.decode(value, { stream: true });
      carry = "";
      if (chunk.endsWith("\r")) {
        carry = "\r";
        chunk = chunk.slice(0, -1);
      }
      buffer += chunk.replace(/\r\n|\r/g, "\n");
      const found = drainMatch();
      if (found !== undefined) return found;
    }
  } finally {
    // Release the stream as soon as we're done with it - whether that's
    // because we found the match (the common case: stop before EOF, the
    // whole point of this function) or the read loop threw/was aborted -
    // so the underlying socket does not leak.
    try {
      await reader.cancel();
    } catch {
      // Already closed/errored - nothing to clean up.
    }
  }
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
  // Atomic: write to a sibling temp file, then rename it into place, rather
  // than writeFileSync straight to cachePath - writeFileSync truncates the
  // target before writing, so an ENOSPC, an I/O error, or an interruption
  // mid-write used to leave an empty or partial file, silently swallowed by
  // the catch below, destroying a complete cached inventory the offline
  // tools/list path depends on. A rename within the same directory is
  // atomic on the same filesystem - a reader only ever sees the old
  // complete file or the new complete one, never a partial write.
  const dir = dirname(cachePath);
  const tmpPath = join(dir, `.${basename(cachePath)}.${process.pid}.tmp`);
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(tmpPath, JSON.stringify(tools));
    renameSync(tmpPath, cachePath);
  } catch {
    // Best effort, same outcome as before: a read-only cache dir (or any
    // other write failure) degrades to "cache unchanged", not a crash -
    // but now that "unchanged" is real, since nothing at cachePath itself
    // was ever touched until the rename, which only happens after a
    // complete write. Clean up the temp file so a failed write doesn't
    // also leak one; ignored if it was never created.
    try {
      unlinkSync(tmpPath);
    } catch {
      // Nothing to clean up, or cleanup itself failed - best effort only.
    }
  }
}

// Appends `page` onto `base`, de-duplicating by tool name and keeping the
// newest definition - a client re-walking the same page sequence (e.g.
// after a reconnect) must not leave duplicate entries, and if a tool's
// definition legitimately changed between walks the newer one should win,
// not sit alongside a stale copy.
// A reconcile walk is bounded so a backend that keeps handing back cursors
// cannot spin it forever.
const MAX_RECONCILE_PAGES = 50;

// Spec (2026-07-28, server/utilities/caching): a client "SHOULD NOT treat TTL
// as a polling interval that triggers automatic background refetches...
// Implementations that do choose to poll MUST apply jitter and backoff." We do
// choose to poll, because the backend reports listChanged:false yet serves
// dynamic tools - it will never tell us the inventory moved. So: jittered
// base interval, exponential backoff while the backend is down (the common
// case - the app is usually closed), reset to base on first success.
const RECONCILE_BASE_MS = 30_000;
const RECONCILE_MAX_MS = 10 * 60_000;
const RECONCILE_JITTER = 0.25;

function jittered(ms) {
  return Math.round(ms * (1 + (Math.random() * 2 - 1) * RECONCILE_JITTER));
}

// Key order inside an object is not meaningful, so it must not change the
// digest.
function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${stableStringify(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

// Hashes the COMPLETE tool object, not a hand-picked subset. A backend that
// changes only outputSchema, annotations, title, icons or _meta has still
// changed the definition the client is holding, and naming fields explicitly
// means every field the spec adds later is silently exempt from change
// detection. List ORDER stays insignificant - a backend may return the same
// inventory in any order, which is not worth waking the client for - hence
// sorting the per-tool strings rather than hashing the array as given.
export function toolsDigest(tools) {
  const norm = tools.map(stableStringify).sort();
  return createHash("sha256").update(norm.join("\u0000")).digest("hex");
}

function mergeToolPage(base, page) {
  const byName = new Map(base.map((tool) => [tool?.name, tool]));
  for (const tool of page) byName.set(tool?.name, tool);
  return [...byName.values()];
}

export function defaultCachePath(name, url) {
  const safe = String(name).replace(/[^A-Za-z0-9._-]+/g, "_") || "mcp-siding";
  // Keyed on name AND backend identity, not name alone. A repoint (remove
  // then re-add the same --name with a different --backend-url, per
  // SKILL.md's Update section) used to leave the previous backend's tool
  // inventory sitting at the name-only path: if the new backend was
  // initially unavailable, the shim would advertise the OLD backend's
  // tools as belonging to the new one. A short hash of the URL is enough
  // to make that collision impossible - keeping `safe` in the filename too
  // is what keeps it greppable/human-identifiable, the original reason for
  // keying on name at all.
  const urlHash = createHash("sha256").update(String(url)).digest("hex").slice(0, 8);
  return join(homedir(), ".cache", "mcp-siding", `${safe}-${urlHash}.json`);
}

// ---------------------------------------------------------------------------
// App launcher. Kept as a swappable field on the Shim (a spawn seam) so
// tests can assert "did we try to launch" without ever spawning anything.

function defaultLauncher(appPath, onFailed) {
  // ponytail: macOS `open -a` only, since every current preset (Fusion,
  // Figma) is a macOS .app bundle; add a platform branch if a non-mac
  // desktop-app target shows up.
  const child =
    process.platform === "darwin"
      ? spawn("open", ["-a", appPath], { detached: true, stdio: "ignore" })
      : spawn(appPath, [], { detached: true, stdio: "ignore" });
  // spawn() does not throw synchronously for a missing/non-executable
  // path (ENOENT/EACCES) - the returned ChildProcess emits an 'error'
  // event instead, asynchronously, well after this function (and
  // downCallResult's try/catch around calling it) has already returned.
  // An EventEmitter's unhandled 'error' event terminates the process, so a
  // bad --app value used to take down the whole stdio server on the first
  // tools/call that tried to launch - exactly the failure this shim
  // exists to prevent (N1). That guarantee stays intact - onFailed is
  // best effort and never allowed to throw back into this handler.
  //
  // Two distinct failure shapes, neither of which throws synchronously.
  // spawn() itself failing is this 'error' event. The more common macOS
  // shape for a bad --app path is different, though: `open -a <bad path>`
  // spawns FINE and simply exits nonzero, which nothing here previously
  // observed at all - downCallResult() had already set launchedAt, so the
  // next call (and every one for the rest of the grace window) reported
  // "still starting" for an app that was never going to start. Observe
  // both and let the caller (onLaunchFailed) clear that debounce state.
  child.on("error", (err) => {
    try {
      onFailed?.(err.message);
    } catch {
      // Best effort - never let a failure here propagate.
    }
  });
  child.on("exit", (code, signal) => {
    if (code === 0) return;
    try {
      onFailed?.(signal ? `terminated by signal ${signal}` : `exited with code ${code}`);
    } catch {
      // Best effort - never let a failure here propagate.
    }
  });
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
    // Where a forwarded server notification goes (issue #15). null - the
    // default - means "do not forward", which is what every unit-level
    // construction of a Shim wants: nothing should reach a real stdout
    // unless main() deliberately wired it there. main() sets this to emit
    // (the same one-object-per-line writer every response already goes
    // through) so framing is identical for both. See forwardNotification.
    this.onNotification = opts.onNotification ?? null;
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
    // The BACKEND's era: "modern" (per-request _meta, 2026-07-28+), "legacy"
    // (initialize handshake), or null for not-yet-probed. The spec says era is
    // a property of the server, not of a request, and SHOULD be cached for the
    // lifetime of the origin — so this is decided once and reused, not
    // re-probed on every reconnect.
    this.backendEra = null;
    // Client request id -> the AbortController post() built for it, so a
    // notifications/cancelled naming that id can abort the matching
    // in-flight HTTP request. Entries are added/removed by post() itself,
    // for the lifetime of exactly one request.
    this.inFlight = new Map();
    // Monotonically increasing backend-facing JSON-RPC request id, and the
    // client request id -> backend request id it produced, for the
    // lifetime of one backend() call. Every real call used to hardcode id
    // 1 - harmless when calls are strictly serialized, but cancellation
    // (see cancel()) is deliberately dispatched OUTSIDE that serialization,
    // so a cancel for one call could arrive after another call had already
    // started and be forwarded against the wrong (or an ambiguously
    // shared) id. connect()'s own initialize uses id 0 - this starts at 1
    // so the two namespaces never collide.
    this.nextBackendId = 1;
    this.backendIdForClient = new Map();
    // Set by the launcher's failure observation (see defaultLauncher/
    // onLaunchFailed) when a launch is known to have failed - read and
    // cleared by downCallResult() on the next call, instead of reporting a
    // bogus "still starting" for an app that is never going to start.
    this.launchFailure = null;
    // Staging buffer for an in-progress tools/list pagination walk - pages
    // accumulate here and are committed to the persistent cache (see
    // toolsList) only once the terminal page (no nextCursor) arrives. null
    // means no walk is currently staged. See toolsList for the full commit
    // rule and what happens if a walk is abandoned mid-sequence.
    this.pendingToolsPage = null;
    // Client request ids main() has enqueued but whose own turn in the
    // serialized queue has not yet come up - set by main() the moment an
    // id-carrying message is enqueued, cleared by handle() the moment
    // that same id is actually dispatched (cancelled or not - see
    // handle()). This is what lets cancel() tell "this id is still
    // queued" apart from "this id is unknown or already finished" -
    // only the former is worth tombstoning below. Bounded by queue depth,
    // not a constant: an id is added once and removed once, so nothing
    // can accumulate past what is genuinely still queued.
    this.pendingIds = new Set();
    // Client request ids cancelled while still pending (see
    // this.pendingIds) - not yet in this.inFlight, because main()'s
    // serialized queue has not reached them yet (see cancel()). Consumed
    // (one-shot) by handle() when that id's own turn comes up, so it
    // never contacts the backend with a call the user already cancelled.
    // No cap here (an earlier version had one, oldest-eviction at 50
    // entries - deleted, not raised, because ANY fixed number is the same
    // bug further away: cancel more requests than the cap while the queue
    // is stalled behind one slow call, and the oldest tombstones are
    // evicted, so THOSE cancelled tools/call operations reach the backend
    // for real). An entry only ever exists for an id this.pendingIds
    // already confirmed is genuinely still queued, and is removed the
    // moment that id dispatches - bounded by queue depth, exactly like
    // this.pendingIds, so there is nothing to leak.
    this.cancelledQueuedIds = new Set();
    // Digest of the tool list the CLIENT currently holds, so reconcileTools()
    // can tell "the inventory moved" from "nothing to say." null means the
    // client has never been served a list.
    this.lastServedToolsDigest = null;
    this.reconciling = false;
  }

  // The client only re-lists when told to, so a list that changes while it is
  // idle never reaches it: a backend serving DYNAMIC tools changes its
  // inventory mid-session, and the shim additionally moves between the
  // last-known cached list (backend down) and the live one (backend up).
  // tools/list never launches the app - only toolsCall does - so polling a
  // closed backend is a cheap failed connect with no side effect.
  //
  // Returns true if the client was notified, false if the list was reached and
  // matched (or there was nothing to compare against), and null if the backend
  // could not be reached at all - the caller uses null to back off.
  async reconcileTools() {
    // A client-driven paged walk owns this.pendingToolsPage; never race it.
    if (this.reconciling || this.pendingToolsPage !== null) return false;
    this.reconciling = true;
    try {
      let tools = [];
      let cursor;
      let complete = false;
      for (let page = 0; page < MAX_RECONCILE_PAGES; page++) {
        const result = await this.backend("tools/list", cursor ? { cursor } : undefined);
        if (!Array.isArray(result?.tools)) return null;
        tools = mergeToolPage(tools, result.tools);
        if (!result.nextCursor) { complete = true; break; }
        cursor = result.nextCursor;
      }
      // Hitting the cap with a cursor still outstanding means we never saw a
      // terminal page - either the backend genuinely has more than
      // MAX_RECONCILE_PAGES, or its cursor loops. Either way this is a PARTIAL
      // inventory. Committing it would overwrite a complete cached list with a
      // truncated one and, worse, notify the client that tools disappeared
      // when they did not. A reconcile that could not finish has learned
      // nothing; treat it exactly like an unreachable backend and back off.
      if (!complete) return null;
      writeCache(this.cachePath, tools);
      const digest = toolsDigest(tools);
      // Only a list the client already holds can go stale. If it has never
      // listed, it gets this one live the first time it asks - waking it for a
      // list it never had would be noise.
      const changed = this.lastServedToolsDigest !== null && digest !== this.lastServedToolsDigest;
      this.lastServedToolsDigest = digest;
      if (changed) this.onNotification?.({ jsonrpc: "2.0", method: "notifications/tools/list_changed" });
      return changed;
    } catch {
      // Backend down or refusing: the client keeps what it holds and the cache
      // stays the last known good list. Nothing changed that we know of.
      return null;
    } finally {
      this.reconciling = false;
    }
  }

  // `clientRequestId`, when given, registers this call's AbortController in
  // `this.inFlight` under that id for the duration of the request, so
  // cancel() can find and abort it - see the Cancelled class and cancel()
  // below. Omitted for internal calls (connect()'s own initialize/
  // notifications/initialized) that the client never addresses directly.
  async post(payload, sid, clientRequestId) {
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
    if (clientRequestId !== undefined) this.inFlight.set(clientRequestId, controller);
    let res, body, errorText;
    try {
      res = await fetch(this.url, {
        method: "POST",
        headers,
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      // HTTP media types are case-insensitive - a backend answering
      // "Text/Event-Stream" is exactly as SSE as "text/event-stream".
      // Header NAMES are already case-insensitive via Headers.get; this is
      // specifically about the VALUE. Lowercased once here so every
      // comparison below (and whatever this gets passed into, e.g.
      // parseBody) sees a normalized value.
      const contentType = (res.headers.get("content-type") || "").toLowerCase();
      if (res.ok && contentType.includes("text/event-stream")) {
        // The timeout must cover reading the body, not just the headers -
        // a backend that answers 200 and then stalls mid-stream (a legal
        // SSE keepalive that never closes) previously hung here with
        // nothing watching it, blocking every later stdin message behind
        // it (main() serializes all requests through one queue, so one
        // stuck request wedges the whole server). See readSseUntilMatch
        // for why this is read incrementally rather than via res.text().
        if (payload.id === undefined) {
          // A notification - there is no id to correlate a response
          // against (and none is expected: every caller discards this
          // body regardless). Cancel immediately rather than either
          // waiting for EOF (the exact hang this branch exists to avoid)
          // or scanning for an id that will never arrive.
          try {
            await res.body?.cancel();
          } catch {
            // Already closed - nothing to clean up.
          }
          body = null;
        } else {
          body = await readSseUntilMatch(res.body, payload.id, (msg) => this.forwardNotification(msg));
        }
      } else {
        // Plain JSON, an empty notification response, and any non-2xx
        // status (an error response is not the long-lived-stream case
        // above, whatever its content-type claims) all read the whole
        // body, exactly as before.
        const text = await res.text();
        if (!res.ok) {
          errorText = text;
        } else {
          body = parseBody(text, contentType, payload.id);
        }
      }
    } catch (err) {
      // A cancel-triggered abort and a timeout-triggered abort throw the
      // same shape of AbortError from fetch/res.text()/the stream reader -
      // the reason cancel() set on the controller (only it ever passes
      // one) is what tells them apart. A cancellation must surface as
      // Cancelled, never as Down: it must not reach downCallResult() or
      // launch the app - we stopped waiting, the backend did not go away.
      if (controller.signal.reason instanceof Cancelled) throw controller.signal.reason;
      // A parse failure (malformed JSON/SSE) means a response DID arrive -
      // reachable, not downtime - see MalformedResponse.
      if (err instanceof MalformedResponse) throw err;
      // A malformed backend URL means fetch() rejected before anything
      // was transmitted at all - see ConfigurationError for why this is
      // neither Down nor Indeterminate.
      if (err?.cause?.code === "ERR_INVALID_URL" || err?.code === "ERR_INVALID_URL") {
        throw new ConfigurationError(`the configured backend URL is invalid: ${err.message}`);
      }
      // N47: a fetch-forbidden port (see FETCH_FORBIDDEN_PORTS) - undici
      // blocks these client-side before attempting any connection, and
      // carries no recognized error code (bare "bad port" on err.cause,
      // no .code at all), so this used to fall through to Indeterminate:
      // "the operation may have run," when nothing was ever transmitted.
      // buildShimFromArgs rejects this at validation time already; this
      // is independent protection in case a forbidden port ever reaches
      // this path some other way (a Shim built directly, bypassing that
      // check - same reasoning as ConfigurationError's own guard above).
      if (err?.cause?.message === "bad port") {
        throw new ConfigurationError(`the configured backend URL uses a port fetch() refuses to connect to: ${this.url}`);
      }
      // Classify by whether delivery is PROVEN, not by whether WE aborted -
      // see Indeterminate/PROVEN_UNDELIVERED_CODES above for the reasoning.
      // Only two call sites ever abort this controller (the timer just
      // below, and cancel(), already ruled out above), so `aborted` here -
      // with Cancelled excluded - can only mean the timer fired: a timeout,
      // never proof of non-delivery. Otherwise, only an error code proven
      // to precede delivery is Down; every other code (a reset/EPIPE/hang-
      // up after transmission, or one this list does not recognize) is
      // Indeterminate too, on purpose - understating downtime is the safe
      // direction, overstating it is not.
      if (!controller.signal.aborted && PROVEN_UNDELIVERED_CODES.has(err?.cause?.code ?? err?.code)) {
        throw new Down(err?.message ?? String(err));
      }
      throw new Indeterminate(
        controller.signal.aborted
          ? `no response within ${this.timeoutMs}ms - the backend may have received the request and could still be processing it`
          : `the connection failed after the request may already have been sent (${err?.message ?? String(err)}) - the backend may have received it and could still be processing it`,
      );
    } finally {
      clearTimeout(timer);
      if (clientRequestId !== undefined) this.inFlight.delete(clientRequestId);
    }
    if (!res.ok) {
      if (sid && STALE_HTTP_STATUSES.has(res.status)) throw new Stale(`HTTP ${res.status}`);
      // Pass the WHOLE body, not a 200-char snippet: HttpRejected parses it so
      // the era probe can recognise a modern error delivered in a 4xx, and a
      // truncated body never parses. The message still shows only a snippet.
      throw new HttpRejected(res.status, errorText ?? "");
    }
    return { body, sid: res.headers.get("mcp-session-id") };
  }

  // `clientRequestId`, when given, is threaded through to both of the
  // handshake's own post() calls (not just the caller's eventual real
  // call) - a client that cancels while connect() is still awaiting either
  // one must be able to abort it. Without this, a cancel during the
  // handshake found no entry in this.inFlight (post() had registered under
  // the handshake's own internal calls, never under the client's id) and
  // was a silent no-op: the handshake ran to completion and the shim went
  // on to run the very tool call the client had already cancelled.
  // Is the backend modern? Probes server/discover once and caches the verdict.
  // Per the Streamable HTTP backward-compatibility rules: attempt a modern
  // request, and treat a RECOGNIZED modern reply (a DiscoverResult, or an
  // UnsupportedProtocolVersionError) as proof of a modern server. Anything
  // else — an unknown-method error, a 4xx with no modern body, a transport
  // failure — means legacy, and we fall back to `initialize`.
  //
  // Deliberately fail-safe toward legacy: every desktop backend today speaks
  // the handshake, so an ambiguous answer must not strand us in modern mode
  // against a server that cannot serve it.
  // Adds the per-request protocol version when, and only when, the backend has
  // been PROVEN modern. A legacy backend negotiated once by handshake and must
  // not receive _meta it never asked for. One definition, so every outbound
  // path - requests and bare notifications alike - decorates identically.
  withProtocolMeta(params) {
    if (this.backendEra !== "modern") return params;
    return {
      ...(params ?? {}),
      _meta: { ...(params?._meta ?? {}), [PROTOCOL_VERSION_META_KEY]: this.protocolVersion ?? MODERN_PROTOCOL_VERSION },
    };
  }

  async probeBackendEra(clientRequestId) {
    if (this.backendEra !== null) return this.backendEra;
    // Declared out here: the verdict below the try needs to inspect the reply,
    // and a `const` inside the block is not in scope there.
    let body;
    try {
      ({ body } = await this.post(
        {
          jsonrpc: "2.0",
          id: 0,
          method: "server/discover",
          params: {
            _meta: {
              [PROTOCOL_VERSION_META_KEY]: MODERN_PROTOCOL_VERSION,
              "io.modelcontextprotocol/clientInfo": { name: "mcp-siding", version: "1" },
              "io.modelcontextprotocol/clientCapabilities": {},
            },
          },
        },
        null,
        clientRequestId,
      ));
      if (Array.isArray(body?.result?.supportedVersions)) {
        const shared = body.result.supportedVersions.filter((v) => SUPPORTED_PROTOCOL_VERSIONS.includes(v));
        // A modern server we share no version with is still MODERN — falling
        // back to initialize would just fail differently and hide why.
        this.backendEra = "modern";
        this.protocolVersion = shared[0] ?? MODERN_PROTOCOL_VERSION;
        return this.backendEra;
      }
      if (body?.error?.code === UNSUPPORTED_PROTOCOL_VERSION) {
        this.backendEra = "modern";
        const supported = body.error.data?.supported;
        const shared = Array.isArray(supported) ? supported.filter((v) => SUPPORTED_PROTOCOL_VERSIONS.includes(v)) : [];
        this.protocolVersion = shared[0] ?? MODERN_PROTOCOL_VERSION;
        return this.backendEra;
      }
    } catch (err) {
      // A CANCELLATION is not an era verdict and must not be swallowed. The
      // client asked us to stop; returning null here let connect() carry on,
      // start a fresh initialize, and ultimately run the caller's (possibly
      // mutating) tool call against the backend after it had been cancelled.
      if (err instanceof Cancelled) throw err;
      // The spec's documented modern-detection case: an
      // UnsupportedProtocolVersionError delivered inside an HTTP 4xx. Without
      // reading that body a modern-only backend looks like a legacy one, we
      // send initialize, and it fails for a reason nothing explains.
      if (err instanceof HttpRejected && err.body?.error?.code === UNSUPPORTED_PROTOCOL_VERSION) {
        this.backendEra = "modern";
        const supported = err.body.error.data?.supported;
        const shared = Array.isArray(supported) ? supported.filter((v) => SUPPORTED_PROTOCOL_VERSIONS.includes(v)) : [];
        this.protocolVersion = shared[0] ?? MODERN_PROTOCOL_VERSION;
        return this.backendEra;
      }
      // A CLIENT-error rejection with no recognisable modern body is a legacy
      // server, per the Streamable HTTP fallback rule - the server understood
      // us and refused, which is the evidence that rule is built on.
      //
      // Deliberately NOT every HttpRejected. A 5xx means the server FAILED, not
      // that it rejected our era, and 408/429 are explicitly transient. Caching
      // any of those as "legacy" would be permanent: every later connection
      // skips discovery and sends an initialize a modern-only backend cannot
      // answer, with no recovery short of restarting the shim. A transient
      // blip must leave the era undecided so the next attempt can probe again.
      if (err instanceof HttpRejected) {
        const s = err.status;
        // 401/403/407 are authentication or authorization challenges, not a
        // statement about which protocol the server speaks - a desktop app
        // waiting on login answers this way and becomes reachable moments
        // later. Caching legacy here is permanent: discovery is skipped
        // forever after, and a modern-only backend can never be reached again
        // without restarting the shim.
        if (s >= 400 && s < 500 && ![401, 403, 407, 408, 429].includes(s)) {
          this.backendEra = "legacy";
          return this.backendEra;
        }
        return null;
      }
      // Anything else - unreachable, timeout, malformed - is genuinely
      // inconclusive about the ERA, but it is conclusive about REACHABILITY
      // right now. Returning null let connect() immediately issue a second
      // request, so an endpoint that accepts connections and never answers
      // burned the full timeout twice before reporting anything. Leave the era
      // uncached for the next call and re-throw, so this attempt fails once.
      throw err;
    }
    // Reached only when the backend ANSWERED over HTTP 200 without a
    // DiscoverResult. Only an error that actually identifies a legacy server
    // may settle the verdict: method-not-found (-32601) means "I do not know
    // server/discover", which is precisely what a legacy server says. A
    // generic server error (-32603 and friends) says the request FAILED, not
    // that the method is unknown — a modern backend having a bad moment would
    // otherwise be cached as legacy permanently, and every later connection
    // would skip discovery and send initialize it cannot answer.
    const code = body?.error?.code;
    if (code === METHOD_NOT_FOUND || !isObject(body?.error)) {
      this.backendEra = "legacy";
      return this.backendEra;
    }
    return null;
  }

  async connect(clientRequestId) {
    // A modern backend needs no handshake at all: version, identity and
    // capabilities all travel per-request. Marking the session connected is
    // the whole of "connecting" there.
    if ((await this.probeBackendEra(clientRequestId)) === "modern") {
      this.sid = null;
      this.connected = true;
      return;
    }
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
      clientRequestId,
    );
    // A backend that answered at all is reachable - a JSON-RPC error
    // envelope rejecting the handshake is a BackendReported failure, not
    // Down (same reasoning as backend()'s own body?.error check), and must
    // not be silently absorbed into a default protocol version and a
    // connected session. Without this, connect() fell back to
    // PROTOCOL_VERSION, still sent notifications/initialized, marked the
    // session connected, and the shim went on to run the caller's
    // (possibly mutating) tool call against a backend that had explicitly
    // rejected the handshake.
    if (body?.error) {
      throw new BackendReported(body.error.code, body.error.message ?? "backend error");
    }
    // Same class as N10's fix in backend() (this request always carries an
    // id, so a response was expected): require a real RESULT, not merely
    // the absence of an error. A 200 with an empty body, or an envelope
    // with neither result nor error, is a protocol failure, not a
    // completed handshake - it must not be silently absorbed into a
    // default protocol version, notifications/initialized, and a
    // connected session that then runs the caller's (possibly mutating)
    // tool call as if initialize had actually succeeded.
    if (!body || !("result" in body)) {
      throw new MalformedResponse("initialize: no response received for the handshake");
    }
    validateResultShape("initialize", body.result);
    this.sid = sid ?? null;
    // Capture what the backend actually negotiated, not just what we
    // asked for - a compliant backend may echo back a different (older)
    // version it supports, and that is the value every later request must
    // carry, not our own requested one.
    this.protocolVersion = body?.result?.protocolVersion || PROTOCOL_VERSION;
    await this.post({ jsonrpc: "2.0", method: "notifications/initialized" }, this.sid, clientRequestId);
    this.connected = true;
    return body;
  }

  // Calls the backend, reconnecting once if the session went stale (the
  // backend restarted while this shim kept running). A JSON-RPC error
  // envelope from a live, answering backend is a BackendReported failure,
  // not Down - see that class - and does not reset session state (the
  // session itself is still fine; only this one call was rejected).
  async backend(method, params, clientRequestId) {
    try {
      for (const attempt of [1, 2]) {
        try {
          if (!this.connected) await this.connect(clientRequestId);
          // Cancellation is dispatched OUTSIDE the serialized queue
          // (deliberately - see cancel()/main()), so a call started here
          // can genuinely overlap another one in flight (or one just
          // cancelled). A hardcoded id would let a cancel meant for one
          // call land on another, or two outstanding requests share an
          // id - allocate a fresh one per call and remember it so cancel()
          // can name the right one.
          const backendRequestId = this.nextBackendId++;
          if (clientRequestId !== undefined) this.backendIdForClient.set(clientRequestId, backendRequestId);
          // A modern backend expects the version on EVERY request; a legacy
          // one negotiated it once and must not receive _meta it never asked
          // for, so this is added only for a backend proven modern.
          const outbound = this.withProtocolMeta(params);
          const { body } = await this.post({ jsonrpc: "2.0", id: backendRequestId, method, params: outbound }, this.sid, clientRequestId);
          if (body?.error) throw new BackendReported(body.error.code, body.error.message ?? "backend error");
          // This call always sends an id, so a response was expected - a 200
          // with an empty body, or an SSE stream that reached EOF without
          // ever emitting the matching event, both leave `body` null here.
          // Do NOT synthesize {}: that reads as a successful call whose
          // outcome nothing here ever actually saw - the worst failure mode
          // in this file, since a mutating tool call would be reported as
          // having succeeded. A post() call completed without throwing, so
          // this is reachable, not downtime - same family as
          // MalformedResponse (and handled identically by every caller).
          if (!body || !("result" in body)) {
            throw new MalformedResponse(`${method}: no response received for the request`);
          }
          validateResultShape(method, body.result);
          return body.result;
        } catch (err) {
          // BackendReported/HttpRejected/MalformedResponse mean "reachable";
          // Cancelled means "we stopped waiting, the backend did not go
          // away"; Indeterminate means "we don't know, and must not guess
          // by resetting state"; ConfigurationError means "nothing was ever
          // sent, and reconnecting won't help - the URL itself is broken."
          // None of the six is proof the SESSION itself is bad, so
          // session/connection state is left untouched for all of them,
          // and none ever gets a reconnect retry (that's only for Stale).
          // If the session really did go bad, the next call's own Stale
          // classification (a real 404) catches it then.
          if (
            err instanceof BackendReported ||
            err instanceof HttpRejected ||
            err instanceof Cancelled ||
            err instanceof MalformedResponse ||
            err instanceof Indeterminate ||
            err instanceof ConfigurationError
          )
            throw err;
          this.connected = false;
          this.sid = null;
          this.protocolVersion = null;
          if (err instanceof Stale && attempt === 1) continue;
          throw err instanceof Down ? err : new Down(err?.message ?? String(err));
        }
      }
    } finally {
      // The call has settled (returned, thrown, or exhausted its retry) -
      // this id no longer names anything cancel() should act on.
      if (clientRequestId !== undefined) this.backendIdForClient.delete(clientRequestId);
    }
  }

  // Aborts the in-flight HTTP request for `clientRequestId`, if any is
  // still tracked, and forwards notifications/cancelled to the backend on
  // a best-effort basis. Be precise about what this achieves: aborting our
  // own request only stops US from waiting on it and frees the queue for
  // the next message - it does NOT stop the backend from continuing to run
  // the operation to completion. Only a backend that honors the forwarded
  // notification actually stops the work; this shim cannot cancel a CAD
  // operation mid-flight by itself.
  //
  // A request that is not in this.inFlight is not necessarily unknown or
  // already finished - it may simply be QUEUED behind an earlier call,
  // not yet reached by main()'s serialized queue (post() only registers a
  // controller once it actually starts). Cancelling that id used to be a
  // silent no-op: once its turn came up, handle() would dispatch it
  // normally and send the very mutating tool call the user had already
  // cancelled. Tombstoned instead (see this.cancelledQueuedIds) so
  // handle() can catch it before ever contacting the backend - but only
  // when this.pendingIds confirms the id really is still queued; a
  // genuinely unknown or already-finished id stays exactly the harmless
  // no-op it always was, not a tombstone nothing will ever consume.
  // Returns the forward's promise (already caught, so it never rejects) so
  // a caller that cares whether it actually landed - shutdown() below,
  // specifically - can await it. main()'s own live notifications/cancelled
  // handler deliberately ignores the return value and stays fire-and-
  // forget: waiting there would block the serialized queue behind a slow
  // or unresponsive backend, which is exactly what dispatching cancel()
  // outside that queue (N6) exists to avoid. Returns undefined when there
  // is nothing to forward (already covered by the comments below).
  cancel(clientRequestId, reason) {
    if (clientRequestId === undefined || clientRequestId === null) return undefined;
    const controller = this.inFlight.get(clientRequestId);
    if (!controller) {
      if (this.pendingIds.has(clientRequestId)) this.cancelledQueuedIds.add(clientRequestId);
      return undefined;
    }
    controller.abort(new Cancelled(reason ? `cancelled by client: ${reason}` : "cancelled by client"));
    // Name the backend id THIS call actually used (see backend()) - not a
    // hardcoded value, which could now name a different, still-running
    // call. If backend() had not yet allocated one (e.g. still stuck in
    // connect()'s handshake - see N6), there is nothing meaningful to
    // forward; the abort above already freed the queue either way.
    const backendRequestId = this.backendIdForClient.get(clientRequestId);
    if (this.connected && backendRequestId !== undefined) {
      return this.post(
        // cancel() bypasses backend(), so it must add the modern metadata
        // itself. Without it a modern backend can reject or ignore the
        // cancellation and keep running a possibly-mutating operation - the
        // one message where being ignored is worst.
        { jsonrpc: "2.0", method: "notifications/cancelled", params: this.withProtocolMeta({ requestId: backendRequestId, reason }) },
        this.sid,
      ).catch(() => {});
    }
    return undefined;
  }

  // Best-effort cleanup when the transport closes (the client disconnected
  // - see main()'s readline 'close' handler): cancels every in-flight
  // request the same way an explicit client cancellation would, reusing
  // cancel()'s existing abort-and-forward machinery rather than a second
  // one, then releases the backend session (a streamable-HTTP DELETE), if
  // one was established. Same honesty as cancel()'s own comment: this
  // tells a COOPERATING backend to stop - a backend that ignores the
  // forwarded notification (or this DELETE) keeps running the operation
  // and holding the session regardless; this shim cannot force either.
  //
  // Bounded by `deadlineMs` and never throws: best-effort means bounded -
  // shutdown must not block indefinitely on a backend that may already be
  // gone, and an unhandled rejection on the way out is worse than the
  // orphan it replaces, so every failure here is swallowed, not surfaced.
  async shutdown(deadlineMs = 2_000) {
    // N43: this used to only abort what was already IN FLIGHT - but
    // aborting it is exactly what frees main()'s serialized queue to
    // advance to the next message, so a queued tools/call (never even
    // started yet) would reach handle(), then the backend, and complete
    // AFTER the client has disconnected and can never see the result.
    // Reuses the exact tombstone machinery N26/N27 already built for a
    // live client cancelling a queued id: handle() already checks
    // cancelledQueuedIds before ever reaching the backend (see handle()'s
    // own comment on this.pendingIds/this.cancelledQueuedIds). Tombstone
    // every id still queued, synchronously, before cancel() below aborts
    // the in-flight one - the abort is what lets the queue actually reach
    // these ids, so the tombstones must already be in place, not raced
    // against it. Genuinely in-flight requests are untouched here; their
    // forwards still go through cancel() and still complete within the
    // deadline exactly as before.
    for (const pendingId of this.pendingIds) {
      this.cancelledQueuedIds.add(pendingId);
    }
    const cleanup = (async () => {
      // "Best effort" means actually attempted and given its deadline, not
      // fired and abandoned: cancel()'s notifications/cancelled forward
      // used to be pure fire-and-forget here, so the DELETE request right
      // below it (or, with no session, nothing at all) could resolve and
      // let process.exit() cut the forward off before its bytes ever
      // reached the backend - a real race, not just a slow assertion in
      // the test that observes it. Collect and await every forward this
      // loop produces (each already caught by cancel() itself, so none of
      // these can reject) before moving on - still bounded by the SAME
      // deadline as everything else here, via the outer Promise.race
      // below, so an unresponsive backend still cannot hold shutdown open.
      const forwards = [];
      for (const clientRequestId of [...this.inFlight.keys()]) {
        const forward = this.cancel(clientRequestId, "client disconnected");
        if (forward) forwards.push(forward);
      }
      if (forwards.length > 0) await Promise.all(forwards);
      if (this.connected && this.sid) {
        const headers = { "MCP-Session-Id": this.sid };
        if (this.protocolVersion) headers["MCP-Protocol-Version"] = this.protocolVersion;
        await fetch(this.url, { method: "DELETE", headers });
      }
    })().catch(() => {});
    await Promise.race([cleanup, new Promise((r) => setTimeout(r, deadlineMs))]);
  }

  // Relays one server-originated JSON-RPC message (already validated as a
  // message, and already known not to be the awaited response - see
  // readSseUntilMatch) to the stdio client. Issue #15: without this, a
  // backend emitting notifications/progress during a multi-minute Fusion
  // operation gives the client nothing and the call looks stalled.
  //
  // Three things this deliberately does NOT do. It does not go through
  // main()'s serialized queue: that queue orders REQUEST HANDLING, and a
  // server notification is not a request - routing it through the queue
  // would deadlock it behind the very call whose progress it reports.
  // Framing is safe without the queue because both this and every response
  // go through the same emit(), which writes one complete
  // JSON-object-plus-newline per call, and a Writable serializes whole
  // writes in call order - so a forward can never land inside a response's
  // line. It does not touch session, correlation, or cancellation state:
  // nothing here can change which response a caller accepts. And it never
  // throws back into the read loop - a failed write (a closed stdout, a
  // client that already went away) must not turn into a failed tool call.
  forwardNotification(msg) {
    if (!this.onNotification) return;
    try {
      this.onNotification(msg);
    } catch {
      // Best effort - a broken stdout is the client's disconnect, which
      // readline's 'close' already handles; it is not this call's failure.
    }
  }

  // -- message handlers -----------------------------------------------------

  async toolsList(params, clientRequestId) {
    try {
      const result = await this.backend("tools/list", params, clientRequestId);
      // Guard the cache write on a real array (no future response shape
      // surprise can blank a previously good cache). N19's original design
      // committed to the persistent cache on every page, including an
      // uncursored (first) page - which meant a *refresh* of an already-
      // complete multi-page inventory replaced it with page one alone the
      // instant that first page arrived, and if the backend then failed
      // mid-walk, the previously complete cache was gone: the same loss
      // N19 was meant to prevent, just reached through an interrupted walk
      // instead of a partial read. So the persistent cache (this.cachePath)
      // is now only ever touched on the TERMINAL page of a walk (a
      // response with no nextCursor) - an interrupted walk leaves it
      // untouched. Pages accumulate in this.pendingToolsPage in the
      // meantime, entirely in memory:
      //   - an uncursored (first-page) request starts a FRESH staging
      //     buffer, discarding any previous one outright - a new walk
      //     replaces, it does not resume, whatever a prior walk (complete,
      //     interrupted, or abandoned) left staged.
      //   - a cursored (later-page) request appends to the existing
      //     staging buffer (or starts one from just this page if none was
      //     staged - a cursor arriving without an uncursored request first
      //     is a client-driven edge case, and the least surprising thing
      //     to do with it is stage what actually arrived).
      //   - only once a page arrives with no nextCursor (single-page
      //     listings are terminal on arrival, so they still commit
      //     immediately, exactly as before) does the FULL staged result
      //     get written to the persistent cache, replacing it outright -
      //     a completed walk is a fresh inventory, not an append to the
      //     old one. The buffer is then cleared.
      // A client that starts a walk and never finishes it (crashes,
      // disconnects, simply stops paging) leaves this.pendingToolsPage
      // holding a partial page set - it is never written to disk, never
      // read by the offline fallback below (which only ever reads the
      // persistent cache), and does not grow unbounded: it is simply
      // overwritten whole the next time an uncursored request starts a
      // new walk, or dropped when this Shim instance exits. Nothing
      // leaks, and a later fresh listing never resumes stale pages.
      // The live result passes through unchanged regardless of caching -
      // e.g. nextCursor stays intact for the live caller - this only ever
      // touches disk on a terminal page.
      if (Array.isArray(result.tools)) {
        const base = params?.cursor ? (this.pendingToolsPage ?? []) : [];
        const staged = mergeToolPage(base, result.tools);
        if (result.nextCursor) {
          this.pendingToolsPage = staged;
        } else {
          writeCache(this.cachePath, staged);
          this.pendingToolsPage = null;
          // This is what the client now holds; reconcileTools() compares
          // against it to decide whether anything is worth notifying about.
          this.lastServedToolsDigest = toolsDigest(staged);
        }
      }
      return result;
    } catch {
      // Never launches - clients call tools/list every session, and
      // launching the app on that would launch it constantly. Applies the
      // same way whether the backend was unreachable (Down) or reachable
      // but rejected the call (BackendReported): tools/list has nowhere to
      // put an error message anyway, so serving *something* is correct
      // either way, not a misreport.
      //
      // N41: a CURSORED request failing mid-walk must NOT be answered with
      // the full persisted cache the way an uncursored one is - the client
      // already holds an earlier page live and would append this "next
      // page" onto it, duplicating that page's tools and mixing what it
      // already has with whatever (possibly stale, possibly a different
      // snapshot entirely) inventory happens to be on disk from a prior
      // walk. There is no coherent remainder to serve instead either:
      // this.pendingToolsPage holds only what THIS walk has staged so far,
      // which is exactly what the client already received, not a page
      // reconciled against the persisted cache. Returning an empty page
      // with no nextCursor cleanly terminates the walk instead - the
      // client keeps exactly the live page(s) it already has, stops
      // asking for more, and never duplicates or mixes stale data. This
      // reads as "return nothing" to a future eye, but the alternative
      // (the full cache) is strictly worse, not better - terminating a
      // walk early is recoverable (a fresh uncursored request next time
      // gets a clean full listing); a client silently holding duplicate
      // or inconsistent tool definitions is not. An uncursored request -
      // a fresh listing, no walk in progress to protect - is unaffected
      // and still serves the full persisted cache exactly as before.
      if (params?.cursor) return { tools: [] };
      const cached = readCache(this.cachePath);
      this.lastServedToolsDigest = toolsDigest(cached);
      // Serving a stale copy because the backend is down is explicitly
      // permitted ("Clients MAY serve stale responses if errors occur during
      // re-fetching... server downtime"), but the client should not go on to
      // cache OUR stale copy as if it were fresh. ttlMs:0 is the spec's way to
      // say "immediately stale, re-ask when you can" - the honest label for a
      // last-known-good list served from disk.
      // resultType marks this a COMPLETE result (2026-07-28) — it is a real
      // answer, just a stale one — while ttlMs:0 stops the client caching our
      // stale copy as fresh. Harmless to a legacy client, which ignores both.
      return { tools: cached, resultType: "complete", ttlMs: 0 };
    }
  }

  async toolsCall(params, clientRequestId) {
    try {
      return await this.backend("tools/call", params, clientRequestId);
    } catch (err) {
      if (err instanceof BackendReported) {
        // Reachable, and rejected the call - an unknown tool, bad
        // arguments, an internal tool error. Not downtime: never launch,
        // never claim the app is unreachable, surface the real message.
        return this.errorResult(
          err.code != null ? `${err.message} (backend error ${err.code})` : err.message,
        );
      }
      if (err instanceof HttpRejected) {
        // Same reasoning, one layer down: an HTTP response arrived at all
        // (401/400/500/...), which proves the app is running. Never
        // launch, never say "not reachable" - surface the real status.
        return this.errorResult(`${this.name} responded with ${err.message} - not a downtime issue, no restart needed.`);
      }
      if (err instanceof MalformedResponse) {
        // Same reasoning, one layer further down: a 200 arrived at all,
        // which proves the app is running - the body just wasn't what the
        // protocol expects (malformed JSON/SSE, an intermediary's HTML
        // error page, a result present but the wrong shape for this method
        // per validateResultShape, ...). Never launch, never say "not
        // reachable" - and never claim success either: a malformed
        // response tells us nothing about whether the work happened, the
        // same uncertainty Indeterminate carries, so a mutating call gets
        // the same retry caution.
        return this.errorResult(
          `${this.name} sent a response this shim could not parse (${err.message}) - not a downtime issue, no restart needed. ` +
            "Do not retry automatically, especially if it was a mutating action - check whether it already completed before trying again.",
        );
      }
      if (err instanceof Indeterminate) {
        // A timeout never proves the backend did not receive the request -
        // it only proves we stopped waiting, whether or not headers ever
        // arrived. Never launch, never say "not reachable": warn plainly
        // that the operation may have started and may still be running,
        // since aborting our own request did not stop it, and a blind
        // retry (or a launch) could duplicate a mutation.
        return this.errorResult(
          `${this.name}: ${err.message}. Do not retry automatically, especially if it was a mutating action - ` +
            "check whether it already completed before trying again.",
        );
      }
      if (err instanceof ConfigurationError) {
        // Nothing was ever transmitted - fetch() rejected on the URL
        // itself, before any connection attempt. Never launch (a broken
        // URL is not fixed by restarting the app) and never phrase this
        // as a timing/retry issue - it is a registration problem the user
        // needs to fix.
        return this.errorResult(`${this.name}: ${err.message} - check the --backend-url this server was registered with.`);
      }
      if (err instanceof Cancelled) {
        // The client asked us to stop waiting - not downtime, never
        // launch. See cancel() for what this does and does not achieve.
        return this.errorResult(`${this.name}: call cancelled.`);
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
    if (this.launchFailure != null) {
      // A previous launch attempt observably failed (see
      // onLaunchFailed/defaultLauncher) - report that, once, instead of
      // either a bogus "still starting" for an app that will never start,
      // or silently trying to launch again forever without saying why the
      // last attempt didn't work.
      const failure = this.launchFailure;
      this.launchFailure = null;
      return this.errorResult(
        `${this.name} failed to start (${this.appPath}): ${failure}. Check the --app path and ` +
          "that the app is installed, then retry.",
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
      this.launcher(this.appPath, (reason) => this.onLaunchFailed(reason));
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

  // Called by the launcher (async, well after downCallResult() has already
  // returned - see defaultLauncher) when a launch is known to have failed.
  // Clears the debounce so the NEXT call re-evaluates instead of reporting
  // "still starting" for the rest of the grace window, and remembers why
  // so that call can say so.
  onLaunchFailed(reason) {
    this.launchedAt = null;
    this.launchFailure = reason;
  }

  errorResult(text) {
    return { content: [{ type: "text", text }], isError: true };
  }

  async handle(msg) {
    const method = msg?.method;
    const id = msg?.id;
    const params = msg?.params ?? {};

    // This id's own turn has now arrived - it is no longer "pending" (see
    // this.pendingIds/main()), whichever branch below actually answers
    // it. Clearing this HERE, before every branch (including initialize),
    // is what keeps both records bounded by queue depth: an id is added
    // exactly once when enqueued and removed exactly once when dispatched,
    // never leaked. If it was cancelled while it was still queued, that
    // tombstone is consumed (one-shot, via delete's own return value) the
    // same way and takes priority over any dispatch - a cancelled request
    // must not reach the backend, whatever method it named.
    if (id !== undefined) {
      this.pendingIds.delete(id);
      if (this.cancelledQueuedIds.delete(id)) {
        // N48: this used to be ok(id, this.errorResult(...)) - a
        // CallToolResult ({content, isError}) - regardless of which
        // method was actually cancelled. That is a valid response shape
        // for tools/call, but a cancelled tools/list (or any other
        // method) got a body with no `tools` array: an invalid
        // ListToolsResult, a protocol failure at the client. A JSON-RPC
        // ERROR response is valid for any method's cancellation
        // uniformly - no per-method shape to get right or keep in sync
        // with validateResultShape - so it is the answer here regardless
        // of what was cancelled.
        return { jsonrpc: "2.0", id, error: { code: -32000, message: `${this.name}: call cancelled.` } };
      }
    }
    if (method === "initialize") {
      // Answered locally so the server always starts, backend up or not.
      return ok(id, {
        protocolVersion: PROTOCOL_VERSION,
        // NOT a mirror of the backend's own flag, deliberately. The backend
        // reports listChanged:false while actually serving dynamic tools, and
        // regardless of that, the SHIM's list genuinely changes: it moves
        // between the last-known cached list (backend down) and the live one
        // (backend up). A client told `false` is entitled to call tools/list
        // once and keep the answer for the whole session - which is exactly
        // how a client that first asked while the app was closed ends up
        // believing this server exposes no tools at all, with no way for us
        // to correct it. We advertise the capability we actually need and
        // drive it from reconcileTools().
        capabilities: { tools: { listChanged: true } },
        serverInfo: { name: this.name, version: "1.0.0" },
      });
    }
    if (typeof method === "string" && method.startsWith("notifications/")) return null;
    // A message with no id cannot be answered - and, critically, this must
    // gate every dispatch branch below, not just the generic fallback:
    // tools/call can launch the app, and a launch for a reply nobody will
    // ever read is a real, user-visible side effect, not a no-op.
    if (id === undefined) return null;
    // A modern client declares its version on EVERY request. Reject one we do
    // not serve with the error the spec defines, listing what we do serve, so
    // the client can retry on a mutually supported version instead of guessing.
    // A request with no such declaration is legacy and passes through here
    // untouched.
    const wanted = requestedProtocolVersion(params);
    if (wanted !== undefined && !SUPPORTED_PROTOCOL_VERSIONS.includes(wanted)) {
      return {
        jsonrpc: "2.0",
        id,
        error: {
          code: UNSUPPORTED_PROTOCOL_VERSION,
          message: "Unsupported protocol version",
          data: { supported: SUPPORTED_PROTOCOL_VERSIONS, requested: wanted },
        },
      };
    }
    // Servers MUST implement server/discover (2026-07-28). It is also the stdio
    // backward-compatibility probe: a dual-era client sends it first and falls
    // back to `initialize` on any non-modern error. Answering it locally, like
    // initialize, keeps the shim describable while the backend is closed.
    if (method === "server/discover") {
      return ok(id, {
        resultType: "complete",
        supportedVersions: SUPPORTED_PROTOCOL_VERSIONS,
        capabilities: { tools: { listChanged: true } },
        _meta: {
          "io.modelcontextprotocol/serverInfo": { name: this.name, version: "1.0.0" },
        },
        // Zero: this shim's own tool list genuinely changes (cached list while
        // the app is closed, live list once it opens), so a client must never
        // hold this answer as fresh.
        ttlMs: 0,
        cacheScope: "public",
      });
    }
    if (method === "ping") return ok(id, {});
    if (method === "tools/list") return ok(id, withResultType(await this.toolsList(params, id), wanted));
    if (method === "tools/call") return ok(id, withResultType(await this.toolsCall(params, id), wanted));
    try {
      const result = await this.backend(method, params, id);
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
// Every flag this shim (and its builders) actually reads, matching
// usage() below exactly - kept as one list so it can never quietly drift
// from what buildShimFromArgs/buildShimScript consume.
const VALUE_FLAGS = new Set(["backend-url", "name", "app", "cache", "timeout", "launch-grace", "platform"]);
const VALID_FLAGS = new Set([...BOOL_FLAGS, ...VALUE_FLAGS]);
// Which registration flavour --print-resolver/--print-shim-script emit.
// "posix" is the default and everything this shim did before native
// Windows support existed; "windows" emits the PowerShell twin instead.
const SHIM_PLATFORMS = new Set(["posix", "windows"]);

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
    // N44: an unrecognized flag used to be silently stored and then just
    // never read by anything - a misspelling like --no-launh=true was
    // accepted, dropped from the generated script, and (with --app
    // present) launch-on-demand ended up ENABLED, the opposite of what
    // was asked. This is the preflight class again (N30/N35): a
    // configuration mistake must fail before the registration mutation,
    // not produce one that quietly behaves differently than requested.
    // Checked here, in parseArgs itself, so BOTH callers (main()'s real
    // launch and --print-shim-script's generation - run()'s CLI dispatch
    // calls this exact function once, before branching to either) reject
    // it the same way, not just one of the two.
    if (!VALID_FLAGS.has(key)) {
      throw new Error(`unknown flag: --${key} (valid flags: ${[...VALID_FLAGS].sort().join(", ")})`);
    }
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
  // Same class as N44's unknown-flag rejection: a --platform value this
  // script does not understand must fail here, before a registration is
  // generated, rather than silently producing the POSIX flavour on a host
  // that asked for the other one.
  if (flags.platform !== undefined && !SHIM_PLATFORMS.has(flags.platform)) {
    throw new Error(`invalid value for --platform: ${flags.platform} (expected ${[...SHIM_PLATFORMS].sort().join(" or ")})`);
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
  --platform posix|windows     Registration flavour --print-resolver/--print-shim-script
                                 emit: POSIX sh (default) or native-Windows PowerShell
  --selftest                   Run the built-in self-check (delegates to the sibling
                                 mcp-siding.selftest.mjs) and exit
  --print-resolver              Print the backend-path resolver and exit
  --print-shim-script            Print the full registration script (resolver +
                                   launch line) for --backend-url/--name/--app/etc and exit
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
  // Validate at startup, before the stdio server opens - a schemeless
  // value (127.0.0.1:27182/mcp, an easy thing to type or paste, missing
  // only "http://") would otherwise pass this truthiness check, let local
  // MCP initialize complete, and fail every subsequent fetch when it
  // cannot be parsed as a URL. Two things make that worse than a plain
  // error: post()'s catch would classify a URL-parse failure as
  // Indeterminate (see that class) - "the operation may have run" - when
  // in fact nothing was ever sent, precisely backwards; and it suppresses
  // launch-on-demand the same way, leaving the user with neither a
  // working shim nor a useful diagnostic. Same fail-closed posture as the
  // resolvers: reject anything that does not parse as an http(s) URL here,
  // before the server ever starts.
  let parsedUrl;
  try {
    parsedUrl = new URL(url);
  } catch {
    throw new Error(`--backend-url must be a valid URL - got ${JSON.stringify(url)} (expected e.g. http://127.0.0.1:27182/mcp)`);
  }
  if (parsedUrl.protocol !== "http:" && parsedUrl.protocol !== "https:") {
    throw new Error(
      `--backend-url must use http: or https: - got ${JSON.stringify(url)} (protocol was ${parsedUrl.protocol})`,
    );
  }
  // N47: a syntactically valid http(s) URL naming a fetch-forbidden port
  // (127.0.0.1:1, say) used to pass every check here, generate a working
  // registration, and only fail at request time - where undici's client-
  // side block carries no recognized error code, so post()'s catch fell
  // through to Indeterminate: "the operation may have run," when nothing
  // was ever transmitted, not even a connection attempt. Reject it here
  // instead, before any registration is built.
  if (parsedUrl.port && FETCH_FORBIDDEN_PORTS.has(Number(parsedUrl.port))) {
    throw new Error(
      `--backend-url uses port ${parsedUrl.port}, which fetch() refuses to connect to (reserved for another protocol, blocked client-side before any connection attempt) - got ${JSON.stringify(url)}`,
    );
  }
  const appPath = flags.app ?? null;
  const timeoutMs = parsePositiveNumber(flags.timeout ?? 180_000, "timeout");
  const launchGraceMs = parsePositiveNumber(flags["launch-grace"] ?? 150, "launch-grace") * 1000;
  const cachePath = flags.cache ?? defaultCachePath(name, url);
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
  // Issue #15: server notifications arriving mid-call go to the client
  // through the SAME writer every response uses, so both share one framing
  // guarantee rather than two. Wired here, at the transport boundary, not
  // in buildShimFromArgs - a Shim built for a unit test has no stdio client
  // and must never write to a real stdout.
  shim.onNotification = emit;
  const rl = createInterface({ input: process.stdin, terminal: false });

  // The client closing stdin (readline's 'close') is the only signal a
  // stdio transport gets for "the client disconnected." Without this, an
  // active tools/call's outstanding fetch and its timer kept the process
  // alive, the backend could keep working unaware nobody is listening
  // anymore, and any allocated MCP session was never released. See
  // shim.shutdown() for what cleanup does and does not achieve, and why
  // it is bounded rather than awaited indefinitely.
  rl.on("close", () => {
    shim.shutdown().finally(() => process.exit(0));
  });

  // Process lines strictly in order: concurrent handling could race two
  // in-flight requests over the same session id (this.sid).
  let queue = Promise.resolve();

  // Detects an inventory that moved while the client sat idle - the app being
  // opened after we served the cached fallback, or its dynamic tools changing
  // mid-session. Self-rescheduling rather than setInterval so the delay can
  // back off while the app is closed (the usual state) instead of retrying at
  // full rate forever. unref() so this timer never keeps the process alive.
  //
  // Runs THROUGH the same serialized queue every client request uses. Calling
  // reconcileTools() directly off the timer raced a client request that was
  // also connecting: both observe `connected === false`, both send their own
  // initialize, and the second overwrites this.sid - so the first then sends
  // its real request against a session whose notifications/initialized never
  // completed, and it is rejected or silently falls back to cached tools. The
  // queue exists precisely to prevent that; background work is not exempt.
  let reconcileDelay = RECONCILE_BASE_MS;
  const scheduleReconcile = () => {
    const timer = setTimeout(() => {
      queue = queue.then(async () => {
        const changed = await shim.reconcileTools();
        reconcileDelay = changed === null
          ? Math.min(reconcileDelay * 2, RECONCILE_MAX_MS)
          : RECONCILE_BASE_MS;
        scheduleReconcile();
      });
    }, jittered(reconcileDelay));
    timer.unref?.();
  };
  scheduleReconcile();
  rl.on("line", (raw) => {
    const line = raw.trim();
    if (!line) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      // Never die on one malformed stdin message. Parsed synchronously
      // here (not deferred into the queue below) precisely so a bad line
      // can't block behind an unrelated in-flight call either.
      queue = queue.then(() => {
        emit({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
      });
      return;
    }
    // notifications/cancelled is dispatched immediately, outside the
    // serialized queue below - queued behind the very call it is meant to
    // cancel would make it useless by construction: that call would
    // already be done, or the notification would sit unprocessed until
    // the 180s timeout. This is the one exception to "everything goes
    // through the queue," not a redesign of the loop.
    if (msg?.method === "notifications/cancelled") {
      shim.cancel(msg.params?.requestId, msg.params?.reason);
      return;
    }
    // Recorded as pending BEFORE enqueueing (synchronously, in this same
    // handler call) so a notifications/cancelled for this id arriving
    // before its turn comes up - dispatched immediately above, outside
    // this queue - can find it and tombstone it. See
    // this.pendingIds/handle() for the other half.
    if (msg?.id !== undefined) shim.pendingIds.add(msg.id);
    queue = queue.then(async () => {
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
    process.stdout.write(flags.platform === "windows" ? `${readWindowsResolver()}\n` : `${RESOLVER_SH}\n`);
    return;
  }
  if (flags["print-shim-script"]) {
    // Route through the SAME validation the runtime uses (URL format and
    // protocol, --timeout/--launch-grace) rather than the truthiness-only
    // check this used to have - buildShimScript below builds the actual
    // output text directly from flags and does not itself validate
    // anything, so generation must fail for exactly the inputs the
    // spawned server would reject, with the same diagnostics, before a
    // registration is made rather than after. The built Shim is discarded
    // - only its validation matters here.
    try {
      buildShimFromArgs(flags);
    } catch (err) {
      process.stderr.write(`${err.message}\n${usage()}`);
      process.exit(2);
    }
    process.stdout.write(flags.platform === "windows" ? buildShimScriptPowerShell(flags, readWindowsResolver()) : buildShimScript(flags));
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
