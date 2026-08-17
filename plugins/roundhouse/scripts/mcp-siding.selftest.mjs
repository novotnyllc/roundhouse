#!/usr/bin/env node
// mcp-siding.selftest.mjs — self-test for the sibling mcp-siding.mjs.
//
// Split out of mcp-siding.mjs so production code and its tests aren't one
// file: imports mcp-siding.mjs's exports (Shim, parseBody, cache
// read/write, the resolver, the script builder) and never duplicates their
// logic. Zero external dependencies, same as the file it tests - Node
// stdlib only, runnable directly, no package.json, no install step. Spins
// up real in-process HTTP servers to exercise reachability/recovery/
// stale-session/timeout/SSE behavior, and real child processes (of
// mcp-siding.mjs, resolved as a relative sibling so this works from any
// copy of the pair) to exercise stdin resilience and a space-containing
// path.
//
// Usage:
//   mcp-siding.selftest.mjs
//   node mcp-siding.mjs --selftest   (thin delegation to this file)

import { spawn, spawnSync } from "node:child_process";
import { mkdtemp, mkdir, writeFile, copyFile, chmod, rm, readFile, readdir } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import assert from "node:assert/strict";
import {
  Shim,
  parseBody,
  readSseUntilMatch,
  writeCache,
  readCache,
  RESOLVER_SH,
  buildShimScript,
  buildShimScriptPowerShell,
  extractWindowsResolver,
  shQuote,
  psQuote,
  PROTOCOL_VERSION,
  parseArgs,
  buildShimFromArgs,
  defaultCachePath,
  toolsDigest,
} from "./mcp-siding.mjs";

// Resolved relative to *this file*, not CWD or a hardcoded repo path - so
// the pair keeps working after both files are copied somewhere else
// entirely (verified as part of this self-test's own release-gate run).
const MCP_SIDING_PATH = fileURLToPath(new URL("./mcp-siding.mjs", import.meta.url));

export async function selftest() {
  // -- 1. body parsing, including multi-event SSE selection by id --------
  assert.deepEqual(parseBody('data: {"a":1,"id":5}\n', "text/event-stream", 5), { a: 1, id: 5 });
  // N14: the JSON path now enforces the same exact-id correlation the SSE
  // path already did - a response must carry the id it is being checked
  // against.
  assert.deepEqual(parseBody('{"a":2,"id":7}', "application/json", 7), { a: 2, id: 7 });
  assert.throws(
    () => parseBody('{"a":2,"id":8}', "application/json", 7),
    /response id mismatch/,
    "a JSON response for a different id must be rejected",
  );
  assert.equal(parseBody("", "application/json", 1), null);
  assert.equal(parseBody("   ", "text/event-stream", 1), null);
  const multiEvent =
    'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\n' +
    'data: {"jsonrpc":"2.0","id":9,"result":{"tools":[{"name":"real"}]}}\n\n';
  assert.deepEqual(
    parseBody(multiEvent, "text/event-stream", 9),
    { jsonrpc: "2.0", id: 9, result: { tools: [{ name: "real" }] } },
    "must select the id-matching response, skipping the leading notification",
  );
  assert.equal(
    parseBody(multiEvent, "text/event-stream", 999),
    null,
    "a response for a different id than expected must not be picked up",
  );

  // -- 1b2. N28: HTTP media types are case-insensitive - "Text/Event-
  //         Stream" is exactly as SSE as "text/event-stream", with or
  //         without trailing parameters. Existing lowercase behavior
  //         (asserted above) must stay unchanged. -----------------------
  assert.deepEqual(
    parseBody('data: {"a":3,"id":11}\n', "Text/Event-Stream", 11),
    { a: 3, id: 11 },
    "a mixed-case content type must still take the SSE path",
  );
  assert.deepEqual(
    parseBody('data: {"a":4,"id":12}\n', "Text/Event-Stream; charset=UTF-8", 12),
    { a: 4, id: 12 },
    "a mixed-case content type with parameters must still take the SSE path",
  );

  // -- 1c. N5: readSseUntilMatch must parse an event split across chunk
  //        boundaries - a chunk boundary is not an event boundary, and
  //        nothing before this asserted that directly. Split mid-value,
  //        not just mid-line, to prove the buffering is byte-level, not
  //        line-level. Tested directly against a synthetic stream (no real
  //        server involved) - end-to-end coverage of the same reader over
  //        a real socket is 7m/7n below. -----------------------------------
  function fakeReadableStream(chunks) {
    let i = 0;
    return {
      getReader() {
        return {
          async read() {
            if (i >= chunks.length) return { done: true, value: undefined };
            return { done: false, value: new TextEncoder().encode(chunks[i++]) };
          },
          async cancel() {},
        };
      },
    };
  }
  const splitMatch = await readSseUntilMatch(
    fakeReadableStream(['data: {"jsonrpc":"2.0","id":9,"resu', 'lt":{"ok":true}}\n\n']),
    9,
  );
  assert.deepEqual(splitMatch, { jsonrpc: "2.0", id: 9, result: { ok: true } }, "an event split across two chunks must parse");

  // -- 1d. N8: CRLF-delimited SSE events. The spec permits \r\n and lone \r
  //        as line terminators, not just \n - a CRLF backend must not be
  //        silently unparseable (a closing stream would otherwise return
  //        null -> backend() returns {} -> a tools/call reports FALSE
  //        SUCCESS for a mutation that never ran). Lone-\r events, and the
  //        specific trap: a \r\n pair split so the \r ends one chunk and
  //        the \n starts the next must collapse to ONE delimiter, not two -
  //        a naive per-chunk-in-isolation normalization gets this wrong. --
  const crlfMatch = await readSseUntilMatch(fakeReadableStream(['data: {"jsonrpc":"2.0","id":9,"result":{"crlf":true}}\r\n\r\n']), 9);
  assert.deepEqual(crlfMatch, { jsonrpc: "2.0", id: 9, result: { crlf: true } }, "a CRLF-delimited event must parse");

  const loneCrMatch = await readSseUntilMatch(fakeReadableStream(['data: {"jsonrpc":"2.0","id":9,"result":{"cr":true}}\r\r']), 9);
  assert.deepEqual(loneCrMatch, { jsonrpc: "2.0", id: 9, result: { cr: true } }, "a lone-\\r-delimited event must parse");

  // The straddle: chunk 1 ends with the \r half of the terminating pair,
  // chunk 2 starts with its \n half. A correct fix carries the lone \r
  // forward and folds it into chunk 2 as ONE terminator; a naive fix that
  // normalizes each chunk in isolation would treat chunk 1's trailing \r as
  // already a full terminator on its own, fabricating a delimiter that was
  // never sent.
  const straddledMatch = await readSseUntilMatch(
    fakeReadableStream(['data: {"jsonrpc":"2.0","id":9,"result":{"straddled":true}}\r\n\r', "\n"]),
    9,
  );
  assert.deepEqual(
    straddledMatch,
    { jsonrpc: "2.0", id: 9, result: { straddled: true } },
    "a \\r\\n pair split across two chunks must parse as one delimiter, not two",
  );

  // -- 1e. N11: SSE joins consecutive "data:" fields within one event with
  //        newlines to form a single payload - a compliant backend may
  //        legally split a large JSON body across several data: fields.
  //        Parsing only the first field truncates that payload and throws
  //        MalformedResponse on a perfectly valid response. ---------------
  const multiFieldEvent = 'data: {"jsonrpc":"2.0",\ndata: "id":9,\ndata: "result":{"multi":true}}\n\n';
  assert.deepEqual(
    parseBody(multiFieldEvent, "text/event-stream", 9),
    { jsonrpc: "2.0", id: 9, result: { multi: true } },
    "JSON split across three data: fields must parse as one payload",
  );

  // A single leading space after the colon is stripped ("data: x" and
  // "data:x" both yield "x") - the rest of the field is untouched.
  assert.deepEqual(
    parseBody('data: {"jsonrpc":"2.0","id":9,"result":{}}\n\n', "text/event-stream", 9),
    { jsonrpc: "2.0", id: 9, result: {} },
    "data: with a leading space must parse",
  );
  assert.deepEqual(
    parseBody('data:{"jsonrpc":"2.0","id":9,"result":{}}\n\n', "text/event-stream", 9),
    { jsonrpc: "2.0", id: 9, result: {} },
    "data: with no leading space must parse",
  );

  // A single-field event is unchanged (no regression from the join logic).
  assert.deepEqual(
    parseBody('data: {"jsonrpc":"2.0","id":9,"result":{"single":true}}\n\n', "text/event-stream", 9),
    { jsonrpc: "2.0", id: 9, result: { single: true } },
    "a single-field event must still parse",
  );

  // A genuinely malformed multi-field payload must still raise
  // MalformedResponse rather than silently passing.
  assert.throws(
    () => parseBody('data: {"jsonrpc":"2.0",\ndata: not valid json here\n\n', "text/event-stream", 9),
    /malformed SSE event/,
    "a malformed multi-field payload must still be rejected",
  );

  // -- 1f. #15: readSseUntilMatch must FORWARD every server-originated
  //        JSON-RPC message that is not the awaited response, in arrival
  //        order, while still returning the correlated response. Without
  //        it, a backend emitting notifications/progress during a
  //        multi-minute operation gives the client nothing and the call
  //        looks stalled. The three properties that make forwarding safe
  //        are asserted here directly, at the reader, since that is where
  //        the ordering and the classification actually happen. ----------
  const forwarded = [];
  const progressThenResponse = await readSseUntilMatch(
    fakeReadableStream([
      'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1,"total":3}}\n\n',
      'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":2,"total":3}}\n\n',
      'data: {"jsonrpc":"2.0","id":9,"result":{"done":true}}\n\n',
    ]),
    9,
    (msg) => forwarded.push(msg),
  );
  assert.deepEqual(
    progressThenResponse,
    { jsonrpc: "2.0", id: 9, result: { done: true } },
    "forwarding must not disturb which message is accepted as the response",
  );
  assert.deepEqual(
    forwarded,
    [
      { jsonrpc: "2.0", method: "notifications/progress", params: { progress: 1, total: 3 } },
      { jsonrpc: "2.0", method: "notifications/progress", params: { progress: 2, total: 3 } },
    ],
    "every progress notification preceding the response must be forwarded, in arrival order",
  );

  // A message carrying a DIFFERENT id is a message, not this call's
  // answer: it must be forwarded and the reader must keep waiting, never
  // accept it as the response (the failure that would report some other
  // request's outcome as this one's).
  const otherIdForwarded = [];
  const otherIdMatch = await readSseUntilMatch(
    fakeReadableStream([
      'data: {"jsonrpc":"2.0","id":8,"result":{"other":true}}\n\n',
      'data: {"jsonrpc":"2.0","id":9,"result":{"mine":true}}\n\n',
    ]),
    9,
    (msg) => otherIdForwarded.push(msg),
  );
  assert.deepEqual(otherIdMatch, { jsonrpc: "2.0", id: 9, result: { mine: true } }, "a non-matching id must never be taken as the response");
  // Deliberately NOT forwarded. forwardNotification() writes to the client's
  // stdout, but these ids come from this.nextBackendId - the shim's own counter
  // - not from the client. Relaying id 8 puts a foreign id into the client's
  // namespace, where it can prematurely satisfy an unrelated pending client
  // request numbered 8 and turn the real reply into a duplicate. Nothing else
  // needs it either: readSseUntilMatch is per-request and returns only the
  // matching id, so a foreign response on this stream is orphaned by
  // construction. This assertion previously required the opposite and was
  // encoding the bug.
  assert.deepEqual(
    otherIdForwarded,
    [],
    "a response carrying a non-matching backend id must never reach the client",
  );

  // A server-to-CLIENT request (method AND id) must NOT be forwarded. The
  // shim has no path to carry its reply back: the client's response has no
  // method, so handle() would read it as a fresh backend request, and it
  // would serialize behind the still-running call that produced it - the
  // backend waits forever for a correlated reply. Notifications and
  // responses still go through; only requests are dropped.
  const mixedForwarded = [];
  const mixedMatch = await readSseUntilMatch(
    fakeReadableStream([
      'data: {"jsonrpc":"2.0","id":41,"method":"sampling/createMessage","params":{}}\n\n',
      'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"p":1}}\n\n',
      'data: {"jsonrpc":"2.0","id":42,"result":{"other":true}}\n\n',
      'data: {"jsonrpc":"2.0","id":43,"result":{"mine":true}}\n\n',
    ]),
    43,
    (msg) => mixedForwarded.push(msg),
  );
  assert.deepEqual(mixedMatch, { jsonrpc: "2.0", id: 43, result: { mine: true } });
  assert.deepEqual(
    mixedForwarded,
    [{ jsonrpc: "2.0", method: "notifications/progress", params: { p: 1 } }],
    "only id-less notifications reach the client: server-to-client requests have no reply path, and other-id responses carry backend ids that would collide with the client's own",
  );

  // Anything in a data: field that is not a JSON-RPC message - a bare
  // number, an array, an object with no jsonrpc, a jsonrpc envelope with
  // neither method nor result/error - is dropped, never written to the
  // client's stdio stream where it would be an unrecoverable protocol
  // violation. The response after them must still arrive.
  const droppedForwarded = [];
  const afterJunk = await readSseUntilMatch(
    fakeReadableStream([
      "data: 42\n\n",
      'data: ["not","a","message"]\n\n',
      'data: {"progress":1}\n\n',
      'data: {"jsonrpc":"2.0"}\n\n',
      'data: {"jsonrpc":"1.0","method":"notifications/progress"}\n\n',
      'data: {"jsonrpc":"2.0","id":9,"result":{"survived":true}}\n\n',
    ]),
    9,
    (msg) => droppedForwarded.push(msg),
  );
  assert.deepEqual(afterJunk, { jsonrpc: "2.0", id: 9, result: { survived: true } }, "non-message events must not stop the real response arriving");
  assert.deepEqual(droppedForwarded, [], "only a real JSON-RPC message may be forwarded - everything else is dropped");

  // A payload that does not parse as JSON at all keeps its existing
  // behavior exactly: MalformedResponse, not a forward, not a silent drop.
  const throwForwarded = [];
  await assert.rejects(
    () => readSseUntilMatch(fakeReadableStream(['data: {"jsonrpc":"2.0",not json\n\n']), 9, (msg) => throwForwarded.push(msg)),
    /malformed SSE event/,
    "an unparseable event must still raise MalformedResponse",
  );
  assert.deepEqual(throwForwarded, [], "an unparseable event must never be forwarded");

  // Omitting the callback entirely (every caller before #15) must behave
  // exactly as it always did.
  assert.deepEqual(
    await readSseUntilMatch(
      fakeReadableStream([
        'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\n',
        'data: {"jsonrpc":"2.0","id":9,"result":{"nocb":true}}\n\n',
      ]),
      9,
    ),
    { jsonrpc: "2.0", id: 9, result: { nocb: true } },
    "the reader must still work with no forwarding callback",
  );

  // -- 1b. CLI parsing (C7/C8/C9 regressions) ------------------------------
  // --no-launch=false / --launch=false must be real booleans, not truthy
  // strings - the concrete bug: --no-launch=false used to disable launch
  // (the string "false" is truthy), the exact opposite of what it reads as.
  assert.equal(parseArgs(["--no-launch=false"])["no-launch"], false);
  assert.equal(parseArgs(["--launch=false"]).launch, false);
  assert.equal(parseArgs(["--launch=true"]).launch, true);
  assert.throws(() => parseArgs(["--launch=maybe"]), /invalid value for --launch/, "a non-boolean =value on a bool flag must be rejected");
  // N44: an unrecognized flag must be rejected outright, not silently
  // stored and then just never read by anything - a misspelling like
  // --no-launh=true used to be accepted, dropped by the builders (never
  // forwarded into the generated script, never applied to a real launch),
  // and with --app set, launch-on-demand ended up ENABLED - the opposite
  // of what was asked.
  assert.throws(() => parseArgs(["--no-launh", "true"]), /unknown flag: --no-launh/, "a misspelled flag must be rejected by name, not silently accepted");
  assert.throws(
    () => parseArgs(["--no-launh=true"]),
    /unknown flag: --no-launh/,
    "the exact near-miss from the finding must be rejected, not silently flip launch behavior",
  );
  assert.throws(() => parseArgs(["--timeuot", "5000"]), /unknown flag: --timeuot/, "a misspelled value flag must also be rejected");
  assert.throws(
    () => parseArgs(["--bogus-flag"]),
    /unknown flag: --bogus-flag.*backend-url/s,
    "the diagnostic must name the offending flag and list the valid ones",
  );
  // A valid, fully-specified flag set must still parse unchanged.
  assert.deepEqual(
    parseArgs([
      "--backend-url",
      "http://x",
      "--name",
      "t",
      "--app",
      "/A.app",
      "--cache",
      "/c.json",
      "--timeout",
      "5000",
      "--launch-grace",
      "10",
      "--no-launch",
    ]),
    {
      "backend-url": "http://x",
      name: "t",
      app: "/A.app",
      cache: "/c.json",
      timeout: "5000",
      "launch-grace": "10",
      "no-launch": true,
    },
    "a valid flag set must parse exactly as before",
  );
  // A missing value must never swallow the following flag token.
  assert.throws(() => parseArgs(["--timeout", "--name", "x"]), /missing value for --timeout/);
  assert.throws(() => parseArgs(["--timeout"]), /missing value for --timeout/, "a value-less flag at the end of argv must also be rejected");
  // Numeric flags reject non-finite/non-positive input instead of a silent
  // NaN (a 0ms timeout, a broken debounce).
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "http://x", name: "t", timeout: "notanumber" }),
    /invalid value for --timeout/,
  );
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "http://x", name: "t", timeout: "0" }),
    /invalid value for --timeout/,
    "zero is not a valid timeout",
  );
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "http://x", name: "t", "launch-grace": "-5" }),
    /invalid value for --launch-grace/,
  );
  // --name has no silent default - required, matching usage(); the
  // installer always passes it explicitly, and the cache is keyed on it.
  assert.throws(() => buildShimFromArgs({ "backend-url": "http://x" }), /--backend-url and --name are required/);
  assert.throws(() => buildShimFromArgs({ name: "t" }), /--backend-url and --name are required/);
  // N30: --backend-url must parse as an http(s) URL, validated at startup
  // (before the stdio server even opens) rather than truthiness alone - a
  // schemeless value like "127.0.0.1:27182/mcp" (missing only "http://",
  // an easy thing to type or paste) would otherwise pass, let local
  // initialize complete, and fail every subsequent fetch - misclassified
  // as Indeterminate ("may have run") when nothing was ever sent, and
  // suppressing launch-on-demand too.
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "127.0.0.1:27182/mcp", name: "t" }),
    /--backend-url must be a valid URL/,
    "a schemeless value must be rejected",
  );
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "ftp://127.0.0.1:27182/mcp", name: "t" }),
    /--backend-url must use http: or https:/,
    "a non-HTTP scheme must be rejected",
  );
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "not a url at all", name: "t" }),
    /--backend-url must be a valid URL/,
    "unparseable junk must be rejected",
  );
  // N47: a syntactically valid http(s) URL naming a fetch-forbidden port
  // (e.g. 1) used to pass every check here and only fail at request time,
  // where undici's client-side block carries no recognized error code -
  // post()'s catch fell through to Indeterminate ("the operation may have
  // run") when nothing was ever transmitted. Rejected here instead, same
  // family as the schemeless/non-HTTP cases above.
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "http://127.0.0.1:1/mcp", name: "t" }),
    /--backend-url uses port 1\b.*fetch\(\) refuses to connect/,
    "a fetch-forbidden port must be rejected, naming the port",
  );
  assert.throws(
    () => buildShimFromArgs({ "backend-url": "http://127.0.0.1:6667/mcp", name: "t" }),
    /--backend-url uses port 6667\b/,
    "any port on the fetch-forbidden list must be rejected, not just port 1",
  );
  // Valid http and https values must keep starting normally.
  assert.equal(buildShimFromArgs({ "backend-url": "http://127.0.0.1:27182/mcp", name: "t" }).url, "http://127.0.0.1:27182/mcp");
  assert.equal(buildShimFromArgs({ "backend-url": "https://example.com/mcp", name: "t" }).url, "https://example.com/mcp");
  // A normal, non-forbidden port must be unaffected by the new check.
  assert.equal(
    buildShimFromArgs({ "backend-url": "http://127.0.0.1:65533/mcp", name: "t" }).url,
    "http://127.0.0.1:65533/mcp",
    "an ordinary high port must not be rejected",
  );
  // --launch=false must actually disable launch (not fall through to
  // Boolean(appPath)), and --no-launch=false must not disable it.
  const launchFalseShim = buildShimFromArgs({ "backend-url": "http://x", name: "t", app: "/A.app", launch: false });
  assert.equal(launchFalseShim.launchEnabled, false);
  const noLaunchFalseShim = buildShimFromArgs({ "backend-url": "http://x", name: "t", app: "/A.app", "no-launch": false });
  assert.equal(noLaunchFalseShim.launchEnabled, true);
  // buildShimScript must forward the same resolved intent into the
  // generated registration script, not just buildShimFromArgs's in-process
  // Shim - an explicit --launch=false with no corresponding --no-launch in
  // the generated argv would silently re-enable launch at the next spawn.
  assert.match(
    buildShimScript({ "backend-url": "http://x", name: "t", app: "/A.app", launch: false }),
    /--no-launch/,
    "--launch=false must forward as --no-launch in the generated script",
  );
  assert.doesNotMatch(
    buildShimScript({ "backend-url": "http://x", name: "t", app: "/A.app", "no-launch": false }),
    /--no-launch/,
    "--no-launch=false must not forward --no-launch",
  );

  // -- 1c. N16: the default cache path is keyed on name AND backend
  //        identity, not name alone - a repoint (remove/re-add the same
  //        --name with a different --backend-url, per SKILL.md's Update
  //        section) must not resolve to the same file the old backend's
  //        tool inventory lives at, or an initially-unavailable new
  //        backend would have the OLD backend's tools advertised as its
  //        own. -------------------------------------------------------
  assert.notEqual(
    defaultCachePath("fusion", "http://127.0.0.1:27182/mcp"),
    defaultCachePath("fusion", "http://127.0.0.1:9999/mcp"),
    "same name, different backend-url must not share a cache file",
  );
  assert.equal(
    defaultCachePath("fusion", "http://127.0.0.1:27182/mcp"),
    defaultCachePath("fusion", "http://127.0.0.1:27182/mcp"),
    "same name and url must resolve to the same path across runs",
  );
  assert.match(defaultCachePath("fusion", "http://127.0.0.1:27182/mcp"), /fusion/, "the filename must still contain the name");

  // -- 2. initialize always answered locally, even pointed at nothing ---
  const tmpRoot = await mkdtemp(join(tmpdir(), "mcp-siding-"));
  const deadShim = new Shim({
    // Not :1 - Node/undici blocks that port client-side ("bad port", no
    // error code) before ever attempting a connection, so it does not
    // reliably produce a real ECONNREFUSED/Down classification (see N25).
    // Section 3 below needs a real refused port for its "not reachable"
    // assertion.
    url: "http://127.0.0.1:65533/mcp",
    name: "test",
    cachePath: join(tmpRoot, "cache.json"),
    timeoutMs: 500,
    launchEnabled: false,
    appPath: null,
    launchGraceMs: 150_000,
  });
  const init = await deadShim.handle({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
  assert.equal(init.result.serverInfo.name, "test");

  // -- 3. backend-down tools/call returns isError, not a thrown error ---
  const call = await deadShim.handle({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "whatever", arguments: {} },
  });
  assert.equal(call.result.isError, true);
  assert.match(call.result.content[0].text, /not reachable/);

  // -- 4. notifications produce no reply ---------------------------------
  assert.equal(await deadShim.handle({ jsonrpc: "2.0", method: "notifications/initialized" }), null);

  // -- 5. tools/list serves the disk cache when the backend is down -----
  const cacheDir = await mkdtemp(join(tmpdir(), "mcp-siding-cache-"));
  const cachePath = join(cacheDir, "seeded.json");
  const seededTools = [{ name: "seeded_tool", description: "from a prior session" }];
  writeCache(cachePath, seededTools);
  const cachedShim = new Shim({
    url: "http://127.0.0.1:1/mcp",
    name: "test",
    cachePath,
    timeoutMs: 500,
    launchEnabled: false,
    appPath: null,
    launchGraceMs: 150_000,
  });
  const listed = await cachedShim.handle({ jsonrpc: "2.0", id: 3, method: "tools/list", params: {} });
  assert.deepEqual(listed.result.tools, seededTools);

  // -- 5b. N38: cache writes must be atomic - write to a sibling temp
  //        file, then rename into place, so an interrupted or failing
  //        write can never leave an empty/partial file behind. A
  //        successful write still produces exactly the expected content;
  //        a failed write (a real unwritable target directory, not a
  //        stubbed fs call) must leave the PREVIOUS cache completely
  //        intact and readable, and must not leak a temp file either way. -
  const atomicDir = await mkdtemp(join(tmpdir(), "mcp-siding-atomic-"));
  const atomicCachePath = join(atomicDir, "atomic.json");
  const originalAtomicTools = [{ name: "original_tool" }];
  writeCache(atomicCachePath, originalAtomicTools);
  assert.deepEqual(readCache(atomicCachePath), originalAtomicTools, "a successful write must produce exactly the expected content");
  assert.deepEqual(await readdir(atomicDir), ["atomic.json"], "a successful write must leave no temp file behind");

  // N39: chmod-based denial does not stop uid 0 - a root-owned container
  // (a normal way to run this gate) would still be able to write through
  // a read-only directory, so this needs a failure permissions cannot
  // bypass. Pre-create a DIRECTORY at the exact path writeCache computes
  // for its temp file (same basename + this process's own pid, since the
  // test calls writeCache in-process) - writeFileSync onto a directory
  // fails with EISDIR regardless of uid, root included, because it is a
  // type mismatch at the VFS level, not a permission check.
  const collisionTmpPath = join(atomicDir, `.atomic.json.${process.pid}.tmp`);
  await mkdir(collisionTmpPath);
  try {
    writeCache(atomicCachePath, [{ name: "should_never_land" }]);
  } finally {
    // writeCache's own cleanup (unlinkSync) cannot remove a directory
    // either - remove it here so the "no temp file left behind" check
    // below reflects writeCache's own behavior, not this test's fixture.
    await rm(collisionTmpPath, { recursive: true, force: true });
  }
  assert.deepEqual(
    readCache(atomicCachePath),
    originalAtomicTools,
    "a failed write must leave the previous cache completely intact and readable, not empty or partial",
  );
  assert.deepEqual(await readdir(atomicDir), ["atomic.json"], "a failed write must not leak a temp file behind");

  // -- 6. launch-on-demand: tools/list never launches, tools/call does,
  //       repeated calls during the grace window are debounced, and a
  //       tools/call with no id must neither reply nor launch ------------
  const launches = [];
  const launchShim = new Shim({
    // A genuinely refused port, not :1 - Node/undici blocks :1 client-side
    // ("bad port", no error code) before ever attempting a connection, so
    // it does not reliably produce a real ECONNREFUSED/Down classification
    // (see N25). This test is specifically about the Down-must-launch
    // path, so it needs a port real connection-refused behavior.
    url: "http://127.0.0.1:65533/mcp",
    name: "test-app",
    cachePath: join(cacheDir, "launch.json"),
    timeoutMs: 500,
    launchEnabled: true,
    appPath: "/fake/Test.app",
    launchGraceMs: 60_000,
    launcher: (appPath) => launches.push(appPath),
  });
  await launchShim.handle({ jsonrpc: "2.0", id: 4, method: "tools/list", params: {} });
  assert.equal(launches.length, 0, "tools/list must never trigger a launch");
  const noIdReply = await launchShim.handle({
    jsonrpc: "2.0",
    method: "tools/call",
    params: { name: "x", arguments: {} },
  });
  assert.equal(noIdReply, null, "a tools/call with no id must produce no reply");
  assert.equal(launches.length, 0, "a tools/call with no id must not launch the app either");
  const firstCall = await launchShim.handle({
    jsonrpc: "2.0",
    id: 5,
    method: "tools/call",
    params: { name: "x", arguments: {} },
  });
  assert.equal(launches.length, 1, "tools/call with the backend down must launch");
  assert.match(firstCall.result.content[0].text, /started it/);
  const secondCall = await launchShim.handle({
    jsonrpc: "2.0",
    id: 6,
    method: "tools/call",
    params: { name: "x", arguments: {} },
  });
  assert.equal(launches.length, 1, "a second call inside the grace window must be debounced");
  assert.match(secondCall.result.content[0].text, /still starting/);

  // -- 7a. real backend: recovery on the next call, no shim restart, and
  //        stale-session-id retry --------------------------------------
  const port = await getFreePort();
  const backendUrl = `http://127.0.0.1:${port}/mcp`;
  const liveShim = new Shim({
    url: backendUrl,
    name: "test",
    cachePath: join(cacheDir, "recover.json"),
    timeoutMs: 1_000,
    launchEnabled: false,
    appPath: null,
    launchGraceMs: 150_000,
  });
  const downResult = await liveShim.handle({ jsonrpc: "2.0", id: 7, method: "tools/call", params: {} });
  assert.equal(downResult.result.isError, true, "nothing listening yet -> isError");

  let session = "session-1";
  const fakeTools = [{ name: "live_tool", description: "served by the fake backend" }];
  const server = createServer((req, res) => {
    readJsonBody(req).then((msg) => {
      const gotSid = req.headers["mcp-session-id"];
      if (msg.method === "initialize") {
        sendJson(
          res,
          200,
          { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
          { "MCP-Session-Id": session },
        );
        return;
      }
      if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
      if (gotSid !== session) {
        // Stale session id (e.g. the backend restarted) -> 404, the
        // MCP-spec status for an invalid/expired session.
        return sendJson(res, 404, { error: "unknown session" });
      }
      if (msg.method === "tools/call") return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { content: [], isError: false } });
      if (msg.method === "tools/list") return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: fakeTools } });
      sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
    });
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  try {
    const recovered = await liveShim.handle({ jsonrpc: "2.0", id: 8, method: "tools/call", params: {} });
    assert.equal(recovered.result.isError, false, "backend now up -> real result, no restart needed");

    const liveList = await liveShim.handle({ jsonrpc: "2.0", id: 9, method: "tools/list", params: {} });
    assert.deepEqual(liveList.result.tools, fakeTools);

    session = "session-2"; // simulate the backend restarting (fresh session)
    const afterRestart = await liveShim.handle({ jsonrpc: "2.0", id: 10, method: "tools/call", params: {} });
    assert.equal(afterRestart.result.isError, false, "stale session must reconnect and retry once");
    assert.equal(liveShim.sid, session, "shim must be holding the fresh session id");
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }

  // -- 7b. a backend that stalls the response body must still be bounded
  //        by the timeout, and a message queued behind it must still get
  //        answered afterward (the whole point: one stuck request must
  //        not wedge the server forever) --------------------------------
  await withServer(
    (req, res) => {
      // Accept the connection, send SSE headers plus one keepalive event,
      // then never end the body - a spec-legal hang.
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write(": keepalive\n\n");
    },
    async (url) => {
      const stallShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "stall.json"),
        timeoutMs: 200,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const startedAt = Date.now();
      const stalled = await stallShim.handle({ jsonrpc: "2.0", id: 20, method: "tools/call", params: {} });
      assert.ok(Date.now() - startedAt < 3_000, "a stalled response body must still be bounded by the timeout");
      assert.equal(stalled.result.isError, true);
      const secondStartedAt = Date.now();
      const again = await stallShim.handle({ jsonrpc: "2.0", id: 21, method: "tools/call", params: {} });
      assert.ok(Date.now() - secondStartedAt < 3_000, "a message queued after a timeout must still get answered");
      assert.equal(again.result.isError, true);
    },
  );

  // -- 7c. multi-event SSE end to end: the response is selected by id and
  //        the disk cache is written with the real tools, not the
  //        leading progress notification ---------------------------------
  const sseTools = [{ name: "sse_tool", description: "arrived via a multi-event SSE stream" }];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "sse-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          const notification = JSON.stringify({ jsonrpc: "2.0", method: "notifications/progress", params: {} });
          const response = JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { tools: sseTools } });
          res.writeHead(200, { "Content-Type": "text/event-stream" });
          res.end(`data: ${notification}\n\ndata: ${response}\n\n`);
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const sseCachePath = join(cacheDir, "sse.json");
      const sseShim = new Shim({
        url,
        name: "test",
        cachePath: sseCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const listedSse = await sseShim.handle({ jsonrpc: "2.0", id: 22, method: "tools/list", params: {} });
      assert.deepEqual(listedSse.result.tools, sseTools, "must select the id-matching response, not the notification");
      assert.deepEqual(readCache(sseCachePath), sseTools, "cache must be written with the real tools");
    },
  );

  // -- 7d/7e. cache PRESERVED when the backend answers with a JSON-RPC
  //           error envelope, and when it answers with a non-array
  //           `tools` - nothing before this asserted the cache survives a
  //           bad-but-live answer, only that it survives no answer at all.
  const seededError = [{ name: "good_cached_tool" }];
  const errorCachePath = join(cacheDir, "error-envelope.json");
  writeCache(errorCachePath, seededError);
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "error-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "not ready" } });
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const errorShim = new Shim({
        url,
        name: "test",
        cachePath: errorCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const errored = await errorShim.handle({ jsonrpc: "2.0", id: 23, method: "tools/list", params: {} });
      assert.deepEqual(errored.result.tools, seededError, "a JSON-RPC error envelope must fall back to cache, not blank it");
      assert.deepEqual(readCache(errorCachePath), seededError, "cache on disk must survive a backend error untouched");
    },
  );

  const seededNonArray = [{ name: "still_good" }];
  const nonArrayCachePath = join(cacheDir, "non-array.json");
  writeCache(nonArrayCachePath, seededNonArray);
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "non-array-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: "not-an-array" } });
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const nonArrayShim = new Shim({
        url,
        name: "test",
        cachePath: nonArrayCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      await nonArrayShim.handle({ jsonrpc: "2.0", id: 24, method: "tools/list", params: {} });
      assert.deepEqual(readCache(nonArrayCachePath), seededNonArray, "cache must survive a non-array tools shape untouched");
    },
  );

  // -- 7e2. C5 regression: a tools/call JSON-RPC error envelope from a
  //         reachable backend must NOT be treated as downtime - no launch,
  //         no "app is unreachable" message, the real backend message (and
  //         code) surfaces instead. Companion to the transport-failure
  //         launch case already covered in section 6 above (backend
  //         completely unreachable -> launches) and the tools/list
  //         cache-preservation case just above (error envelope -> cache
  //         survives) - together these are the three cases C5 asked for. --
  const toolsCallErrorLaunches = [];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "tools-call-error-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, error: { code: -32602, message: "unknown tool: bogus_tool" } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const toolsCallErrorShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "tools-call-error.json"),
        timeoutMs: 2_000,
        launchEnabled: true,
        appPath: "/fake/ReachableButRejecting.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => toolsCallErrorLaunches.push(appPath),
      });
      const rejected = await toolsCallErrorShim.handle({
        jsonrpc: "2.0",
        id: 30,
        method: "tools/call",
        params: { name: "bogus_tool", arguments: {} },
      });
      assert.equal(toolsCallErrorLaunches.length, 0, "a live backend rejection must never launch the app");
      assert.equal(rejected.result.isError, true);
      assert.match(rejected.result.content[0].text, /unknown tool: bogus_tool/, "the real backend message must surface");
      assert.doesNotMatch(rejected.result.content[0].text, /not reachable|is not reachable/i, "must not be misreported as the app being down");
    },
  );

  // -- 7e3. N2: a non-2xx HTTP response (not the 404 stale-session case) is
  //         the same class of bug one layer down from C5/7e2 - reachable,
  //         so it must never launch or be phrased as unreachable, even
  //         though there is no JSON-RPC envelope to read a message from
  //         here (HttpRejected, not BackendReported). Checked at 500 and
  //         401, since a launch-gate bug could plausibly be status-code-
  //         specific. -------------------------------------------------------
  for (const status of [500, 401]) {
    const httpErrorLaunches = [];
    await withServer(
      (req, res) => {
        readJsonBody(req).then((msg) => {
          if (msg.method === "initialize") {
            return sendJson(
              res,
              200,
              { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
              { "MCP-Session-Id": `http-${status}-session` },
            );
          }
          if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
          if (msg.method === "tools/call") {
            res.writeHead(status, { "Content-Type": "text/plain" });
            res.end(`backend says no (${status})`);
            return;
          }
          sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        });
      },
      async (url) => {
        const httpErrorShim = new Shim({
          url,
          name: "test",
          cachePath: join(cacheDir, `http-${status}.json`),
          timeoutMs: 2_000,
          launchEnabled: true,
          appPath: "/fake/ReachableButHttpRejecting.app",
          launchGraceMs: 150_000,
          launcher: (appPath) => httpErrorLaunches.push(appPath),
        });
        const httpRejected = await httpErrorShim.handle({
          jsonrpc: "2.0",
          id: 32,
          method: "tools/call",
          params: { name: "x", arguments: {} },
        });
        assert.equal(httpErrorLaunches.length, 0, `an HTTP ${status} must never launch the app`);
        assert.equal(httpRejected.result.isError, true);
        assert.match(httpRejected.result.content[0].text, new RegExp(String(status)), "the real HTTP status must surface");
        assert.doesNotMatch(
          httpRejected.result.content[0].text,
          /not reachable|is not reachable/i,
          `HTTP ${status} must not be misreported as the app being down`,
        );
      },
    );
  }

  // -- 7e4. N3/N19/N36: pagination must not corrupt the offline cache, and
  //         a walk that never reaches the terminal page must not destroy a
  //         previously complete one either. Pages accumulate in memory as
  //         the walk proceeds; the persistent cache is only REPLACED once
  //         a page arrives with no nextCursor (N36) - fetching page two
  //         must not overwrite page one's entries while the walk is still
  //         in progress, and once the client has walked the whole
  //         sequence and the backend goes away, the offline tools/list
  //         must serve BOTH pages' tools (not just page one - N3's fix
  //         stopped a middle page from standing in as the complete set,
  //         but replaced it with page one alone always doing that
  //         instead), and must not claim more pages are fetchable (no
  //         stale nextCursor). ------------------------------------------
  const page1Tools = [{ name: "page1_tool" }];
  const page2Tools = [{ name: "page2_tool" }];
  const paginationCachePath = join(cacheDir, "pagination.json");
  let paginationShim;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "pagination-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          if (msg.params?.cursor === "page2") {
            return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: page2Tools } }); // last page, no nextCursor
          }
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: page1Tools, nextCursor: "page2" } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      paginationShim = new Shim({
        url,
        name: "test",
        cachePath: paginationCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const page1 = await paginationShim.handle({ jsonrpc: "2.0", id: 40, method: "tools/list", params: {} });
      assert.deepEqual(page1.result.tools, page1Tools);
      assert.equal(page1.result.nextCursor, "page2");
      const page2 = await paginationShim.handle({
        jsonrpc: "2.0",
        id: 41,
        method: "tools/list",
        params: { cursor: "page2" },
      });
      assert.deepEqual(page2.result.tools, page2Tools);
      assert.deepEqual(
        readCache(paginationCachePath),
        [...page1Tools, ...page2Tools],
        "cache must hold both pages after the full sequence has been walked",
      );
    },
  );
  // The backend is gone now (withServer tore it down on return).
  const offlineListing = await paginationShim.handle({ jsonrpc: "2.0", id: 42, method: "tools/list", params: {} });
  assert.deepEqual(
    offlineListing.result.tools,
    [...page1Tools, ...page2Tools],
    "offline tools/list must serve BOTH pages' tools, not just the first",
  );
  assert.equal(offlineListing.result.nextCursor, undefined, "offline listing must not claim more pages are fetchable");

  // An uncursored request after that must RESET the cache, not append to
  // the old (now stale) set - a fresh listing starts over.
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "pagination-reset-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: page1Tools } }); // single page, no nextCursor
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const freshShim = new Shim({
        url,
        name: "test",
        cachePath: paginationCachePath, // same file, still holding both pages from the walk above
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      await freshShim.handle({ jsonrpc: "2.0", id: 43, method: "tools/list", params: {} });
      assert.deepEqual(
        readCache(paginationCachePath),
        page1Tools,
        "an uncursored request must reset the cache to the fresh listing, not append to the stale old one",
      );
    },
  );

  // A re-walk of the same two pages must not duplicate entries.
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "pagination-rewalk-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          if (msg.params?.cursor === "page2") {
            return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: page2Tools } });
          }
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: page1Tools, nextCursor: "page2" } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const rewalkCachePath = join(cacheDir, "pagination-rewalk.json");
      const rewalkShim = new Shim({
        url,
        name: "test",
        cachePath: rewalkCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      // Walk the sequence twice.
      for (let i = 0; i < 2; i += 1) {
        await rewalkShim.handle({ jsonrpc: "2.0", id: 44, method: "tools/list", params: {} });
        await rewalkShim.handle({ jsonrpc: "2.0", id: 45, method: "tools/list", params: { cursor: "page2" } });
      }
      assert.deepEqual(
        readCache(rewalkCachePath),
        [...page1Tools, ...page2Tools],
        "re-walking the same pages must not duplicate entries",
      );
    },
  );

  // -- 7e5. N36: a REFRESH interrupted mid-walk must leave a previously
  //         complete cache untouched. N19's append design committed the
  //         uncursored (first) page to the persistent cache immediately -
  //         so refreshing an already-complete multi-page inventory
  //         replaced it with page one alone the instant that page arrived,
  //         and if the backend then failed before the walk finished, the
  //         previously complete cache was gone. Seed a complete two-page
  //         cache directly, then run a fresh walk whose first page
  //         succeeds (staged in memory only) and whose second page hits a
  //         dead backend - the persisted cache must still be the OLD
  //         complete set, not page one. --------------------------------
  const interruptedCachePath = join(cacheDir, "pagination-interrupted.json");
  writeCache(interruptedCachePath, [...page1Tools, ...page2Tools]);
  const refreshPage1Tools = [{ name: "refresh_page1_tool" }];
  let interruptedShim;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "pagination-interrupted-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          // Only ever answers the uncursored (first) page - the walk's
          // continuation request is made after this server is gone.
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: refreshPage1Tools, nextCursor: "page2" } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      interruptedShim = new Shim({
        url,
        name: "test",
        cachePath: interruptedCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const refreshPage1 = await interruptedShim.handle({ jsonrpc: "2.0", id: 46, method: "tools/list", params: {} });
      assert.deepEqual(refreshPage1.result.tools, refreshPage1Tools);
      assert.deepEqual(
        readCache(interruptedCachePath),
        [...page1Tools, ...page2Tools],
        "a not-yet-terminal page must not touch the persistent cache at all - the old complete inventory must survive untouched",
      );
    },
  );
  // The backend is gone now - the walk's continuation request fails.
  const interruptedPage2 = await interruptedShim.handle({
    jsonrpc: "2.0",
    id: 47,
    method: "tools/list",
    params: { cursor: "page2" },
  });
  // N41: a cursored request failing mid-walk must NOT fall back to the
  // full persisted cache (this test's own assertion until N41) - the
  // client already holds refreshPage1Tools live and would append the
  // full old cache onto it, duplicating page1_tool (present in both) and
  // mixing the live refresh with a stale, unrelated snapshot. An empty
  // terminal page cleanly ends the walk instead.
  assert.deepEqual(
    interruptedPage2.result.tools,
    [],
    "an interrupted cursored request must return an empty page, not duplicate/mix in the old complete cache",
  );
  assert.equal(
    interruptedPage2.result.nextCursor,
    undefined,
    "an interrupted cursored request's empty fallback page must not claim more pages are fetchable",
  );
  assert.deepEqual(
    readCache(interruptedCachePath),
    [...page1Tools, ...page2Tools],
    "the persistent cache must still hold the previously complete inventory after an interrupted refresh - it must never have been replaced with page one alone",
  );

  // -- 7e5b. N41: the exact scenario from the finding - walk page one
  //          live, kill the backend, request page two. The offline
  //          fallback for a CURSORED request used to return the entire
  //          persisted cache as if it were "page two": a client that
  //          appends pages together would then get page one's tools
  //          twice (once from the live page it already has, once again
  //          from the full-cache fallback) plus whatever else was on
  //          disk from an unrelated prior walk. Assert directly that
  //          appending the two responses together, the way a real client
  //          would, produces no duplicate tool names. An UNCURSORED
  //          offline request is unaffected - still returns the full
  //          cached inventory, exactly as before N41. -------------------
  const offlineCursorCachePath = join(cacheDir, "offline-cursor.json");
  const staleUnrelatedTools = [{ name: "stale_unrelated_tool" }];
  writeCache(offlineCursorCachePath, staleUnrelatedTools);
  const livePage1Tools = [{ name: "live_page1_tool" }];
  let offlineCursorShim;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "offline-cursor-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: livePage1Tools, nextCursor: "page2" } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      offlineCursorShim = new Shim({
        url,
        name: "test",
        cachePath: offlineCursorCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const livePage1 = await offlineCursorShim.handle({ jsonrpc: "2.0", id: 50, method: "tools/list", params: {} });
      assert.deepEqual(livePage1.result.tools, livePage1Tools);
    },
  );
  // Backend is gone - request page two, offline.
  const offlinePage2 = await offlineCursorShim.handle({
    jsonrpc: "2.0",
    id: 51,
    method: "tools/list",
    params: { cursor: "page2" },
  });
  // A real client just concatenates pages as they arrive - no dedup of
  // its own to rely on, so any repeat here would be a real duplicate.
  const clientAccumulatedNames = [...livePage1Tools, ...offlinePage2.result.tools].map((t) => t.name);
  assert.deepEqual(
    clientAccumulatedNames,
    ["live_page1_tool"],
    "appending the offline page-two response to the live page one a client already has must not duplicate page one's tools or mix in a stale unrelated snapshot",
  );
  // An uncursored offline request is unaffected - a fresh listing, no
  // walk to protect, still serves the full persisted cache as before.
  const offlineUncursored = await offlineCursorShim.handle({ jsonrpc: "2.0", id: 52, method: "tools/list", params: {} });
  assert.deepEqual(
    offlineUncursored.result.tools,
    staleUnrelatedTools,
    "an uncursored offline request must still return the full cached inventory, unaffected by N41",
  );

  // -- 7e6. N36: an abandoned staged walk must not leak into, or be
  //         resumed by, a later fresh uncursored listing. Start a walk,
  //         fetch its first (non-terminal) page, then never continue it -
  //         a client that reconnects, gives up, or simply calls tools/list
  //         again without a cursor must get a clean fresh listing, not
  //         page two of an old abandoned sequence, and not a merge of the
  //         two. -----------------------------------------------------------
  const abandonedCachePath = join(cacheDir, "pagination-abandoned.json");
  const abandonedPageTools = [{ name: "abandoned_tool" }];
  const freshRefreshTools = [{ name: "fresh_refresh_tool" }];
  let callCount = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "pagination-abandoned-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          callCount += 1;
          if (callCount === 1) {
            // The abandoned walk's first (non-terminal) page - never continued.
            return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: abandonedPageTools, nextCursor: "page2" } });
          }
          // A later, unrelated uncursored request - single page, terminal on arrival.
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: freshRefreshTools } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const abandonedShim = new Shim({
        url,
        name: "test",
        cachePath: abandonedCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const firstPage = await abandonedShim.handle({ jsonrpc: "2.0", id: 48, method: "tools/list", params: {} });
      assert.deepEqual(firstPage.result.tools, abandonedPageTools);
      assert.deepEqual(readCache(abandonedCachePath), [], "an abandoned walk's non-terminal page must never reach the persistent cache");
      // Never call cursor="page2" - the walk is abandoned here. A fresh
      // uncursored request instead (e.g. the client reconnected).
      const freshListing = await abandonedShim.handle({ jsonrpc: "2.0", id: 49, method: "tools/list", params: {} });
      assert.deepEqual(
        freshListing.result.tools,
        freshRefreshTools,
        "a fresh uncursored request must discard the abandoned walk's staged page, not resume or merge with it",
      );
      assert.deepEqual(
        readCache(abandonedCachePath),
        freshRefreshTools,
        "the persistent cache must hold only the fresh listing - not merged with the abandoned walk's staged page",
      );
    },
  );

  // -- 7f. stale-session retry happens EXACTLY ONCE against a permanently
  //        rejecting backend (a request counter, not just eventual
  //        success) -------------------------------------------------------
  let staleRealCount = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "always-stale" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        staleRealCount++;
        sendJson(res, 404, { error: "unknown session" });
      });
    },
    async (url) => {
      const staleShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "stale-once.json"),
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const staleResult = await staleShim.handle({ jsonrpc: "2.0", id: 25, method: "tools/call", params: {} });
      assert.equal(staleResult.result.isError, true);
      assert.equal(staleRealCount, 2, "a permanently-stale session must retry exactly once (2 real attempts), never loop");
    },
  );

  // -- 7g. L3: a non-404 non-2xx (e.g. an unrelated 500) must be
  //        classified Down, not Stale - no reconnect-and-retry cost -----
  let realCount500 = 0;
  let connectCount500 = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          connectCount500++;
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "s500" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        realCount500++;
        sendJson(res, 500, { error: "server error" });
      });
    },
    async (url) => {
      const shim500 = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "l3.json"),
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const result500 = await shim500.handle({ jsonrpc: "2.0", id: 26, method: "tools/call", params: {} });
      assert.equal(result500.result.isError, true);
      assert.equal(realCount500, 1, "a 500 must be classified Down and not retried");
      assert.equal(connectCount500, 1, "Down must not force a second reconnect handshake");
    },
  );

  // -- 7h. L2: a session-less backend (never issues MCP-Session-Id) must
  //        only be handshaked once, not re-connected on every call -------
  let l2ConnectCount = 0;
  let l2ListCount = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          l2ConnectCount++;
          return sendJson(res, 200, {
            jsonrpc: "2.0",
            id: msg.id,
            result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } },
          }); // deliberately no MCP-Session-Id header
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        l2ListCount++;
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: [] } });
      });
    },
    async (url) => {
      const l2Shim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "l2.json"),
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      await l2Shim.handle({ jsonrpc: "2.0", id: 27, method: "tools/list", params: {} });
      await l2Shim.handle({ jsonrpc: "2.0", id: 28, method: "tools/list", params: {} });
      await l2Shim.handle({ jsonrpc: "2.0", id: 29, method: "tools/list", params: {} });
      assert.equal(l2ConnectCount, 1, "a session-less backend must only be handshaked once, not on every call");
      assert.equal(l2ListCount, 3, "all three logical calls must still reach the backend");
    },
  );

  // -- 7i. C6: MCP-Protocol-Version is sent on every post-initialize
  //        request, carrying the version the BACKEND negotiated (not just
  //        echoing our own outgoing PROTOCOL_VERSION) - a streamable-HTTP
  //        backend enforcing the 2025-06-18 transport contract rejects any
  //        post-initialization request missing it (HTTP 400), which would
  //        otherwise present as the app simply being down. Absent on the
  //        initialize request itself, since that is what negotiates it. --
  const negotiatedProtocolVersion = "2024-11-05"; // deliberately not this file's own PROTOCOL_VERSION
  const protocolHeaderSeen = { onInitialize: "missing", onNotify: null, onToolsList: null };
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        const gotHeader = req.headers["mcp-protocol-version"] ?? null;
        if (msg.method === "initialize") {
          protocolHeaderSeen.onInitialize = gotHeader;
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: negotiatedProtocolVersion, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "protocol-version-session" },
          );
        }
        if (msg.method === "notifications/initialized") {
          protocolHeaderSeen.onNotify = gotHeader;
          return sendJson(res, 200, undefined);
        }
        protocolHeaderSeen.onToolsList = gotHeader;
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: [] } });
      });
    },
    async (url) => {
      const protocolShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "protocol-version.json"),
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      await protocolShim.handle({ jsonrpc: "2.0", id: 31, method: "tools/list", params: {} });
      assert.equal(protocolHeaderSeen.onInitialize, null, "the initialize request itself must not carry a version yet");
      assert.equal(protocolHeaderSeen.onNotify, negotiatedProtocolVersion, "notifications/initialized must carry the negotiated version");
      assert.equal(protocolHeaderSeen.onToolsList, negotiatedProtocolVersion, "every later request must carry the negotiated version");
    },
  );

  // -- 7j. N1: a real spawn() failure in the launcher must not kill the
  //        shim - through the REAL defaultLauncher, not the injected
  //        launcher seam every other launch test above uses (that seam is
  //        exactly what let this hide: it never exercises spawn()'s real
  //        async 'error' event). See selftestLauncherErrorDoesNotCrash for
  //        why PATH, not just a missing --app target, is what actually
  //        reproduces it on this platform. ---------------------------------
  await selftestLauncherErrorDoesNotCrash();

  // -- 7j3. N21: the generated registration script must resolve a usable
  //         `node` before exec'ing, not assume one is on PATH - a GUI-
  //         launched harness on macOS does not inherit a login shell's
  //         PATH, and a self-contained Claude/Codex install does not
  //         guarantee node on PATH at all. A subprocess test with a
  //         doctored PATH, running buildShimScript()'s FULL output through
  //         a real /bin/sh -c (the same way a registration actually
  //         invokes it), is the only honest way to check this - the same
  //         technique that made the N1 launcher test above real. "none
  //         available anywhere" and "only a too-old node anywhere" are
  //         constructed (the three hardcoded absolute fallback paths are
  //         rewritten into a temp dir, see rewriteHardcodedNodeFallbacks)
  //         rather than conditionally skipped when this host happens to
  //         have a real node at one of those paths - a skipped-by-
  //         construction assertion is how the EPIPE-on-fail-closed-exit
  //         regression this file's runShimScript guard now handles went
  //         unnoticed through 20 passes on a machine where it never ran. -
  await selftestNodeResolver();

  // -- 7j3b. N32: SKILL.md's install instructions must resolve a usable
  //          node too, not assume bare `node` works - a self-contained
  //          harness with no node on PATH fails the install step before
  //          --print-shim-script can even run, exactly the case
  //          NODE_RESOLVER_SH exists to handle at spawn time. Extracts
  //          and runs the ACTUAL documented snippet (marked in SKILL.md,
  //          not a reimplementation) so a drift between the doc and this
  //          test fails loudly rather than silently. --------------------
  await selftestInstallNodeResolverSnippet();

  // -- 7j3c. N42: SKILL.md's install section must refuse on native Windows
  //          before ever running `mcp add` - both documented registrations
  //          bake in `/bin/sh -c "$SCRIPT"`, which cannot spawn there.
  //          Extracts and runs the ACTUAL documented preflight snippet
  //          (marked in SKILL.md, same pattern as the node-resolver
  //          snippet above), with a stubbed `uname` on PATH rather than a
  //          faked platform - an honest way to control the one input the
  //          snippet actually reads, on any host this runs on. -----------
  await selftestWindowsPreflightSnippet();

  // -- 7j3d. #15: the unit assertions in 1f prove the READER forwards; this
  //          proves the whole transport does - a real child process, a real
  //          socket, real stdout framing. That is the half that cannot be
  //          checked in-process: forwarding writes to stdout from inside
  //          the SSE read loop while a request is in flight, so the risk is
  //          a message landing inside a response's line or out of order
  //          relative to it, neither of which an injected callback can
  //          show. -------------------------------------------------------
  await selftestNotificationForwardingEndToEnd();
  await selftestToolListReconcileNotifiesClient();
  await selftestInterimResultsArePassedThrough();
  await selftestDualEraServerFace();
  await selftestReconcileNeverCommitsTruncatedWalk();

  // -- 7j3e. #16: native Windows. The PowerShell resolver/launcher lives in
  //          the sibling mcp-siding-windows.ps1 and carries its own
  //          -SelfTest (numeric version ordering, fail-closed overrides,
  //          the capability probe, argument quoting, and a parse of the
  //          registration this script generates) - run by the Windows CI
  //          job on a real Windows host, where a PowerShell parser is not
  //          optional. What belongs HERE is everything provable without
  //          PowerShell: that generation emits the right text, quotes it
  //          correctly, fails closed on a bad --platform, and has not
  //          drifted from either the .ps1 or the skill. Deliberately not
  //          gated on `pwsh` being installed - a conditional assertion is
  //          how a hole hides. -----------------------------------------
  await selftestWindowsRegistration();

  // -- 7j4. N30: an invalid --backend-url must exit non-zero before the
  //         stdio server ever opens - not just that buildShimFromArgs
  //         throws (asserted directly above), but that main() actually
  //         wires that into "no readline interface, no reply to a
  //         message sent regardless." A real subprocess is the only way
  //         to prove that end to end. ---------------------------------
  await selftestInvalidBackendUrlExitsBeforeStdio();

  // -- 7j4b. N35: --print-shim-script must be rejected by the SAME
  //          validation buildShimFromArgs applies to a real launch, not
  //          just the old truthiness-only check - a malformed
  //          --backend-url or a bad --timeout used to generate a script
  //          happily, so `mcp add` would register something that could
  //          never start. Real subprocess, real flags, same diagnostic. --
  await selftestPrintShimScriptValidatesLikeBuildShimFromArgs();

  // -- 7j4c. N44: an unrecognized flag must be rejected on BOTH paths -
  //          a real launch (before the stdio server ever opens) and
  //          --print-shim-script (before a script is generated) - since
  //          both route through the same parseArgs. The near-miss from
  //          the finding itself: --no-launh=true used to be silently
  //          stored and ignored. -------------------------------------
  selftestUnknownFlagRejectedOnBothPaths();

  // -- 7j4d. N47: a fetch-forbidden --backend-url port must be rejected
  //          at a real launch too, not just --print-shim-script (covered
  //          just above) - same parseArgs/buildShimFromArgs choke point,
  //          same reasoning as every other pair of these tests. -------
  selftestForbiddenPortRejectedAtLaunch();

  // -- 7j2. N13: the OTHER real macOS launch-failure shape - `open -a
  //         <bad path>` spawns fine and simply exits nonzero, which
  //         nothing previously observed at all. downCallResult() had
  //         already set launchedAt, so every call for the rest of the
  //         150s grace window reported "still starting" for an app that
  //         was never going to start. PATH is left intact here (unlike
  //         selftestLauncherErrorDoesNotCrash) so `open` itself resolves
  //         and actually runs, reproducing the real nonzero-exit shape
  //         rather than a spawn() failure. --------------------------------
  await selftestLaunchFailureReportsAccurately();

  // -- 7k. N4: cancellation stops waiting without misreporting downtime,
  //        never launches, forwards notifications/cancelled to the
  //        backend, and is a harmless no-op for an unknown or
  //        already-finished request id. A stalling tools/call (never
  //        res.end()s) gives cancel() something real to interrupt - the
  //        long timeoutMs proves it was the cancellation that ended the
  //        wait, not the timeout racing it. ------------------------------
  let cancelForwardReceived = null;
  const cancelLaunches = [];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "cancel-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") {
          cancelForwardReceived = msg.params;
          return sendJson(res, 200, undefined);
        }
        if (msg.method === "tools/call") {
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const cancelShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "cancel.json"),
        timeoutMs: 60_000, // long enough that only cancel(), not the timeout, can end the wait
        launchEnabled: true,
        appPath: "/fake/CancelTest.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => cancelLaunches.push(appPath),
      });
      const callPromise = cancelShim.handle({
        jsonrpc: "2.0",
        id: 60,
        method: "tools/call",
        params: { name: "x", arguments: {} },
      });
      // Give the call a moment to actually reach the stalling backend and
      // register in inFlight before cancelling it.
      await new Promise((r) => setTimeout(r, 200));
      cancelShim.cancel(60, "user requested");
      const cancelled = await callPromise;
      assert.equal(cancelled.result.isError, true);
      assert.match(cancelled.result.content[0].text, /cancel/i, "a cancelled call must say so, not claim downtime");
      assert.doesNotMatch(
        cancelled.result.content[0].text,
        /not reachable|is not reachable/i,
        "a cancellation must not be reported as unreachable",
      );
      assert.equal(cancelLaunches.length, 0, "a cancelled call must never launch the app");

      // This is the LIVE cancel() call site (matching main()'s own
      // notifications/cancelled handler, which deliberately never awaits
      // cancel()'s return - see cancel()'s own comment) - the forward is
      // genuinely fire-and-forget here, unlike shutdown()'s use of it, so
      // a fixed sleep is a real race, not just an assertion timed too
      // early. Poll with a bounded wait instead, the way this file's
      // existing waitFor pattern does.
      const cancelForwardDeadline = Date.now() + 2_000;
      while (cancelForwardReceived === null && Date.now() < cancelForwardDeadline) {
        await new Promise((r) => setTimeout(r, 25));
      }
      assert.deepEqual(
        cancelForwardReceived,
        { requestId: 1, reason: "user requested" },
        "the backend must receive the forwarded notifications/cancelled",
      );

      // Unknown or already-finished request id: harmless no-op, no throw.
      assert.doesNotThrow(() => cancelShim.cancel(999_999, "never existed"));
      assert.doesNotThrow(() => cancelShim.cancel(60, "already finished")); // id 60 is no longer in-flight
    },
  );

  // -- 7k2. N27: cancelling far more queued requests than the deleted
  //         50-entry cap must not lose any of them - lifecycle tracking
  //         (bounded by queue depth: an id is marked pending once when
  //         enqueued and cleared once when dispatched) replaces the cap
  //         entirely, so there is nothing to evict. Simulates main()'s
  //         own enqueue pattern directly (mark this.pendingIds, then
  //         queue the dispatch) rather than going through a real
  //         subprocess (7l/7l2 already cover that end to end) - direct
  //         access to shim.pendingIds/cancelledQueuedIds afterward is
  //         what lets "nothing accumulates once the queue drains" be
  //         checked at all. ------------------------------------------
  let manyToolCallCount = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "many-cancel-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          manyToolCallCount += 1;
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const manyShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "many-cancel.json"),
        // Short, deliberately: in working code none of these 120 ever
        // reach post() at all, so the value does not matter there - but a
        // reverted/capped version lets the evicted ones actually reach
        // the stalled backend and wait out the full timeout, sequentially,
        // one request at a time. A short timeout keeps a revert-check
        // finishing in seconds instead of potentially over an hour.
        timeoutMs: 300,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const COUNT = 120; // well over the deleted 50-entry cap
      const ids = Array.from({ length: COUNT }, (_, i) => 200 + i);
      let queue = Promise.resolve();
      const replies = new Map();
      for (const id of ids) {
        const msg = { jsonrpc: "2.0", id, method: "tools/call", params: {} };
        manyShim.pendingIds.add(id); // mirrors main()'s own enqueue-time marking
        queue = queue.then(async () => {
          replies.set(id, await manyShim.handle(msg));
        });
      }
      // All 120 are still purely queued (no .then() callback above has
      // had a chance to run yet - nothing here has awaited since the
      // synchronous loop started) - cancel every one now, before any of
      // them could possibly dispatch.
      for (const id of ids) manyShim.cancel(id, "bulk cancel");
      await queue;

      for (const id of ids) {
        const reply = replies.get(id);
        assert.ok(reply, `id ${id} never got a reply`);
        // N48: a cancelled QUEUED request answers as a JSON-RPC error, not
        // a CallToolResult - valid for any method uniformly, since tools/
        // list (or any other method) could just as easily be the one
        // sitting in this queue, not only tools/call.
        assert.equal(reply.result, undefined, `id ${id} must not carry a result`);
        assert.ok(reply.error, `id ${id} must be a JSON-RPC error response`);
        assert.match(reply.error.message, /cancel/i, `id ${id} must say cancelled`);
      }
      assert.equal(manyToolCallCount, 0, "none of the 120 cancelled requests may reach the backend");
      assert.equal(manyShim.pendingIds.size, 0, "nothing may remain pending once the queue drains");
      assert.equal(manyShim.cancelledQueuedIds.size, 0, "no tombstone may remain once the queue drains");
    },
  );

  // -- 7l. N4 (process level): cancellation frees the serialized queue - a
  //        message queued behind the cancelled call must be answered
  //        promptly too, proving the notification really is dispatched
  //        outside the queue and not just that the Shim class itself is
  //        cancellable (7k proves that half). --------------------------
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "queue-cancel-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const child = spawn(
        process.execPath,
        [MCP_SIDING_PATH, "--backend-url", url, "--name", "test", "--timeout", "60000"],
        { stdio: ["pipe", "pipe", "pipe"] },
      );
      let out = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => (out += chunk));
      let err = "";
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => (err += chunk));
      const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

      const waitFor = async (marker, deadlineMs) => {
        const deadline = Date.now() + deadlineMs;
        while (!out.includes(marker) && Date.now() < deadline) {
          await new Promise((r) => setTimeout(r, 25));
        }
        return out.includes(marker);
      };

      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 70, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 71, method: "ping", params: {} })}\n`);
      // Give the tools/call a moment to actually be in flight (past
      // connect(), registered in inFlight) before cancelling it.
      await new Promise((r) => setTimeout(r, 300));
      const cancelledAt = Date.now();
      child.stdin.write(
        `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 70, reason: "test" } })}\n`,
      );

      assert.ok(await waitFor('"id":70', 5_000), `cancelled tools/call never answered (stderr: ${err})`);
      assert.ok(Date.now() - cancelledAt < 5_000, "cancellation must free the call promptly, not wait out the 60s timeout");
      assert.ok(
        await waitFor('"id":71', 5_000),
        `the message queued behind the cancelled call never answered - queue stayed blocked (stderr: ${err})`,
      );

      child.stdin.end();
      await Promise.race([exited, new Promise((r) => setTimeout(r, 2_000))]);
      if (child.exitCode == null) child.kill();

      const lines = out.trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
      const cancelledReply = lines.find((l) => l.id === 70);
      assert.equal(cancelledReply.result.isError, true);
      assert.match(cancelledReply.result.content[0].text, /cancel/i);
    },
  );

  // -- 7l2. N26 (process level): a cancellation for a request B QUEUED
  //         behind an active request A - not yet in this.inFlight, since
  //         main()'s serialized queue has not reached it - used to be
  //         silently discarded: cancel() found no controller and returned,
  //         so once A settled, B was dispatched normally and sent the very
  //         mutating tool call the user had already cancelled. A request
  //         counter on the fake backend proves B never reaches it at all
  //         (not just that its reply looks cancelled - 7l above already
  //         covers the in-flight case; this is specifically the queued-
  //         but-not-yet-started one). Also exercises an unknown id, which
  //         must remain a harmless no-op despite now being tombstoned. ---
  let queuedCancelToolCallCount = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "queued-cancel-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          queuedCancelToolCallCount += 1;
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const child = spawn(
        process.execPath,
        [MCP_SIDING_PATH, "--backend-url", url, "--name", "test", "--timeout", "60000"],
        { stdio: ["pipe", "pipe", "pipe"] },
      );
      let out = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => (out += chunk));
      let err = "";
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => (err += chunk));
      const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

      const waitFor = async (marker, deadlineMs) => {
        const deadline = Date.now() + deadlineMs;
        while (!out.includes(marker) && Date.now() < deadline) {
          await new Promise((r) => setTimeout(r, 25));
        }
        return out.includes(marker);
      };

      // A - will stall on the backend. B - queued right behind it, still
      // waiting for its own turn when it gets cancelled below.
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 80, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 81, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      // Give A a moment to actually reach the stalling backend and
      // register in this.inFlight - B, right behind it, is still purely
      // queued at this point (main()'s queue is strictly sequential).
      await new Promise((r) => setTimeout(r, 300));
      // An unknown id must remain a harmless no-op even though it is now
      // tombstoned rather than an immediate true no-op.
      child.stdin.write(
        `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 999_999, reason: "never existed" } })}\n`,
      );
      // Cancel B first (still queued, exercises the tombstone path this
      // test is about), then A (in flight, frees the queue so B's own
      // turn - and its tombstone check - actually gets reached promptly).
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 81, reason: "B" } })}\n`);
      const cancelledAt = Date.now();
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 80, reason: "A" } })}\n`);

      assert.ok(await waitFor('"id":80', 5_000), `A never answered (stderr: ${err})`);
      assert.ok(await waitFor('"id":81', 5_000), `B never answered - the tombstone did not free it (stderr: ${err})`);
      assert.ok(Date.now() - cancelledAt < 5_000, "both must be answered promptly, not wait out the 60s timeout");

      child.stdin.end();
      await Promise.race([exited, new Promise((r) => setTimeout(r, 2_000))]);
      if (child.exitCode == null) child.kill();

      const lines = out.trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
      const replyA = lines.find((l) => l.id === 80);
      const replyB = lines.find((l) => l.id === 81);
      // A was cancelled IN-FLIGHT (toolsCall's own Cancelled handling, not
      // the tombstone path) - still a CallToolResult, unaffected by N48.
      assert.equal(replyA.result.isError, true);
      assert.match(replyA.result.content[0].text, /cancel/i);
      // B was cancelled while still QUEUED - the tombstone path (N48):
      // a JSON-RPC error, valid for any method uniformly, not a
      // CallToolResult that would be an invalid shape for e.g. tools/list.
      assert.equal(replyB.result, undefined, "B must not carry a result");
      assert.ok(replyB.error, "B must be a JSON-RPC error response");
      assert.match(replyB.error.message, /cancel/i, "B must say cancelled");
      // The tombstone short-circuits inside handle(), before toolsCall()/
      // backend() (and so before downCallResult(), the only place that
      // launches) are ever reached - proven directly by the request
      // counter below, and "never launches" follows structurally from
      // that: a subprocess test has no injected launcher spy to check
      // directly (see 7j/7j2/7j3 above for why the real launcher needs a
      // real subprocess in the first place).
      assert.equal(queuedCancelToolCallCount, 1, "B must never reach the backend - only A's tools/call should arrive");
    },
  );

  // -- 7l2b. N48: a cancelled QUEUED request must answer with a shape
  //          valid for whatever method was actually cancelled - the
  //          tombstone path used to always return a CallToolResult
  //          ({content, isError}), which is a valid shape for tools/call
  //          (asserted above) but an INVALID ListToolsResult (missing a
  //          `tools` array) for tools/list or anything else. B here is a
  //          tools/list, queued behind a stalled A (tools/call), cancelled
  //          while still queued - the shape is asserted against what
  //          tools/list actually requires: a JSON-RPC error response,
  //          which is valid for any method uniformly (no per-method
  //          shape to keep in sync). -------------------------------------
  let queuedCancelToolsListCount = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "queued-cancel-list-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        if (msg.method === "tools/list") {
          queuedCancelToolsListCount += 1;
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: [] } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const child = spawn(
        process.execPath,
        [MCP_SIDING_PATH, "--backend-url", url, "--name", "test", "--timeout", "60000"],
        { stdio: ["pipe", "pipe", "pipe"] },
      );
      let out = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => (out += chunk));
      let err = "";
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => (err += chunk));
      const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

      const waitFor = async (marker, deadlineMs) => {
        const deadline = Date.now() + deadlineMs;
        while (!out.includes(marker) && Date.now() < deadline) {
          await new Promise((r) => setTimeout(r, 25));
        }
        return out.includes(marker);
      };

      // A - will stall on the backend. B - a tools/list, queued right
      // behind it, still waiting for its own turn when cancelled below.
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 82, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 83, method: "tools/list", params: {} })}\n`);
      await new Promise((r) => setTimeout(r, 300));
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 83, reason: "B" } })}\n`);
      const cancelledAt = Date.now();
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 82, reason: "A" } })}\n`);

      assert.ok(await waitFor('"id":82', 5_000), `A never answered (stderr: ${err})`);
      assert.ok(await waitFor('"id":83', 5_000), `B (tools/list) never answered - the tombstone did not free it (stderr: ${err})`);
      assert.ok(Date.now() - cancelledAt < 5_000, "both must be answered promptly, not wait out the 60s timeout");

      child.stdin.end();
      await Promise.race([exited, new Promise((r) => setTimeout(r, 2_000))]);
      if (child.exitCode == null) child.kill();

      const lines = out.trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
      const replyB = lines.find((l) => l.id === 83);
      assert.ok(replyB, "no reply for the cancelled queued tools/list");
      assert.equal(
        replyB.result,
        undefined,
        "a cancelled queued tools/list must not carry a result at all - a CallToolResult shape would be an invalid ListToolsResult",
      );
      assert.ok(replyB.error, "a cancelled queued tools/list must be a JSON-RPC error response, valid for any method");
      assert.match(replyB.error.message, /cancel/i, "the diagnostic must say cancelled");
      assert.equal(queuedCancelToolsListCount, 0, "the cancelled tools/list must never reach the backend");
    },
  );

  // -- 7l3. N33: the client closing stdin (readline's 'close') must clean
  //         up rather than leave the process hanging on the outstanding
  //         fetch/timer - abort the in-flight call, best-effort forward
  //         notifications/cancelled for it (reusing cancel()'s existing
  //         machinery), and exit promptly. A request counter on the fake
  //         backend proves the forward actually arrives, not just that
  //         the process exits. -----------------------------------------
  let disconnectCancelledForwardReceived = null;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "disconnect-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") {
          disconnectCancelledForwardReceived = msg.params;
          return sendJson(res, 200, undefined);
        }
        if (msg.method === "tools/call") {
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const child = spawn(process.execPath, [MCP_SIDING_PATH, "--backend-url", url, "--name", "test", "--timeout", "60000"], {
        stdio: ["pipe", "pipe", "pipe"],
      });
      let err = "";
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => (err += chunk));
      const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 90, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      // Give the call a moment to actually reach the stalling backend and
      // register in inFlight before disconnecting.
      await new Promise((r) => setTimeout(r, 300));

      const disconnectedAt = Date.now();
      child.stdin.end();
      const exitResult = await Promise.race([exited, new Promise((r) => setTimeout(() => r("timeout"), 5_000))]);
      assert.notEqual(exitResult, "timeout", `process never exited after stdin closed with a call in flight (stderr: ${err})`);
      assert.ok(
        Date.now() - disconnectedAt < 5_000,
        "disconnecting must exit promptly, not wait out the 60s tools/call timeout",
      );
      assert.equal(err, "", `shutdown must not throw on the way out (stderr: ${err})`);

      // No extra wait needed here, and none was ever safe to rely on: this
      // used to be a fixed sleep on the theory that the forward is fire-
      // and-forget, which was true of shutdown()'s cleanup and was the
      // real bug (flaky ~1-in-5, not just a slow assertion) - shutdown()
      // now genuinely awaits cancel()'s forward, bounded by its own
      // deadline, before ever calling process.exit(). That makes this
      // deterministic by construction: the child cannot have exited
      // unless the fake server (this same test process) already received
      // the notification and sent its response back - the response is
      // what let the awaited forward resolve in the first place.
      assert.deepEqual(
        disconnectCancelledForwardReceived,
        { requestId: 1, reason: "client disconnected" },
        "the backend must receive the forwarded notifications/cancelled for the in-flight call",
      );
    },
  );

  // -- 7l3b. N43: shutdown must tombstone QUEUED calls too, not just abort
  //          the in-flight one - aborting the in-flight request is exactly
  //          what frees main()'s serialized queue to advance, so a queued
  //          tools/call (never even started) used to reach the backend
  //          and complete AFTER the client had already disconnected and
  //          could never see the result. A request counter on the fake
  //          backend proves neither queued call reaches it, not just that
  //          the process exits. -------------------------------------------
  let shutdownQueuedToolCallCount = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "shutdown-queued-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          shutdownQueuedToolCallCount += 1;
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const child = spawn(process.execPath, [MCP_SIDING_PATH, "--backend-url", url, "--name", "test", "--timeout", "60000"], {
        stdio: ["pipe", "pipe", "pipe"],
      });
      let err = "";
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk) => (err += chunk));
      const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

      // A stalls on the backend (becomes in-flight). B and C are queued
      // right behind it - main()'s queue is strictly sequential, so
      // neither has even started by the time EOF arrives below.
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 100, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 101, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 102, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
      // Give A a moment to actually reach the stalling backend and
      // register in inFlight before disconnecting.
      await new Promise((r) => setTimeout(r, 300));

      const disconnectedAt = Date.now();
      child.stdin.end();
      const exitResult = await Promise.race([exited, new Promise((r) => setTimeout(() => r("timeout"), 5_000))]);
      assert.notEqual(
        exitResult,
        "timeout",
        `process never exited after stdin closed with queued calls behind an in-flight one (stderr: ${err})`,
      );
      assert.ok(
        Date.now() - disconnectedAt < 5_000,
        "disconnecting with queued calls behind an in-flight one must still exit promptly",
      );
      assert.equal(err, "", `shutdown must not throw with queued calls pending (stderr: ${err})`);
      assert.equal(
        shutdownQueuedToolCallCount,
        1,
        "only the in-flight call may ever reach the backend - both queued calls must be tombstoned before the queue reaches them",
      );
    },
  );

  // -- 7l4. N33: a disconnect with no active call must still exit cleanly -
  //         nothing to cancel, no session to release since none was ever
  //         established (initialize is answered locally; nothing here
  //         ever sends a real message at all). ----------------------------
  const idleChild = spawn(process.execPath, [MCP_SIDING_PATH, "--backend-url", "http://127.0.0.1:65533/mcp", "--name", "test"], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let idleErr = "";
  idleChild.stderr.setEncoding("utf8");
  idleChild.stderr.on("data", (chunk) => (idleErr += chunk));
  const idleExited = new Promise((resolvePromise) => idleChild.on("exit", resolvePromise));
  idleChild.stdin.end(); // never sent a single message - nothing was ever in flight, no session was ever established
  const idleExitResult = await Promise.race([idleExited, new Promise((r) => setTimeout(() => r("timeout"), 5_000))]);
  assert.notEqual(idleExitResult, "timeout", `idle process never exited after stdin closed (stderr: ${idleErr})`);
  assert.equal(idleErr, "", `idle disconnect must not throw (stderr: ${idleErr})`);

  // -- 7l5. N33: a disconnect while the backend is already unreachable
  //         (ECONNREFUSED, not merely stalled) must still exit promptly
  //         and must not throw - shutdown()'s own best-effort cleanup
  //         (the cancellation forward and the session-release DELETE)
  //         can itself hit a dead connection, and that must be swallowed
  //         too, not surface as an unhandled rejection on the way out.
  //         No artificial delay before disconnecting, to maximize the
  //         chance shutdown() races the still-settling connection attempt
  //         rather than waiting for it to finish first. -----------------
  const refusedChild = spawn(process.execPath, [MCP_SIDING_PATH, "--backend-url", "http://127.0.0.1:65533/mcp", "--name", "test"], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let refusedErr = "";
  refusedChild.stderr.setEncoding("utf8");
  refusedChild.stderr.on("data", (chunk) => (refusedErr += chunk));
  const refusedExited = new Promise((resolvePromise) => refusedChild.on("exit", resolvePromise));
  refusedChild.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 91, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
  refusedChild.stdin.end();
  const refusedExitResult = await Promise.race([refusedExited, new Promise((r) => setTimeout(() => r("timeout"), 5_000))]);
  assert.notEqual(refusedExitResult, "timeout", `process against an unreachable backend never exited (stderr: ${refusedErr})`);
  assert.equal(refusedErr, "", `disconnect against an unreachable backend must not throw (stderr: ${refusedErr})`);

  // -- 7m. N5: a backend that sends the matching SSE response and then
  //        holds the stream open (never closes) must resolve promptly -
  //        MCP streamable HTTP explicitly permits keeping the stream open
  //        for later events, and reading must not wait for EOF to see it.
  //        A long timeout proves it was the incremental match, not the
  //        timeout, that ended the wait; the launcher spy proves an
  //        already-succeeded call is never misreported as downtime. -------
  const heldOpenLaunches = [];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "held-open-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          // A valid CallToolResult shape (N37 now requires one) - this
          // test is about held-open transport timing, not shape, so the
          // fixture just needs to pass shape validation to stay focused
          // on what it actually exercises.
          const response = JSON.stringify({
            jsonrpc: "2.0",
            id: msg.id,
            result: { content: [{ type: "text", text: "held" }] },
          });
          res.writeHead(200, { "Content-Type": "text/event-stream" });
          res.write(`data: ${response}\n\n`);
          // Deliberately never res.end() - the exact "deliver then keep
          // the stream open" pattern N5 exists to handle.
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const heldOpenShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "held-open.json"),
        timeoutMs: 60_000, // long enough that only the incremental match, not the timeout, can end the wait
        launchEnabled: true,
        appPath: "/fake/HeldOpen.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => heldOpenLaunches.push(appPath),
      });
      const startedAt = Date.now();
      const held = await heldOpenShim.handle({ jsonrpc: "2.0", id: 80, method: "tools/call", params: {} });
      assert.ok(
        Date.now() - startedAt < 3_000,
        "a matching response must resolve promptly, not wait for the held-open stream to close",
      );
      assert.deepEqual(held.result, { content: [{ type: "text", text: "held" }] });
      assert.equal(heldOpenLaunches.length, 0, "a successful held-open response must never launch");
    },
  );

  // -- 7n. N5: a stream that never sends the matching id must still time
  //        out - the incremental reader must not hang indefinitely waiting
  //        for a match that will never arrive. Same bounded-wall-clock
  //        shape as 7b's plain stall test. ---------------------------------
  await withServer(
    (req, res) => {
      // Accept the connection, send SSE headers plus an event that will
      // never match any request id this shim sends, then never end the
      // body.
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write(`data: ${JSON.stringify({ jsonrpc: "2.0", id: 999_999, result: {} })}\n\n`);
    },
    async (url) => {
      const neverMatchShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "never-match.json"),
        timeoutMs: 200,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const startedAt = Date.now();
      const never = await neverMatchShim.handle({ jsonrpc: "2.0", id: 81, method: "tools/call", params: {} });
      assert.ok(
        Date.now() - startedAt < 3_000,
        "a stream that never sends the matching id must still be bounded by the timeout",
      );
      assert.equal(never.result.isError, true);
    },
  );

  // -- 7o. N6: cancelling while connect() is still awaiting the handshake
  //        (initialize) must abort it - a hole in the N4 work, which
  //        threaded the client request id through the later backend()
  //        post() call but not through connect()'s own two post() calls.
  //        Left uncancelled, the handshake would complete and the shim
  //        would go on to run the tool call the client had already
  //        cancelled. A request counter (not just timing) proves the tool
  //        call itself never reaches the backend. -------------------------
  let handshakeCancelToolCalls = 0;
  const handshakeCancelLaunches = [];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          res.writeHead(200, { "Content-Type": "application/json" }); // stall - deliberately never end()
          return;
        }
        if (msg.method === "tools/call") {
          handshakeCancelToolCalls += 1;
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const handshakeCancelShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "handshake-cancel.json"),
        timeoutMs: 60_000, // long enough that only cancel(), not the timeout, can end the wait
        launchEnabled: true,
        appPath: "/fake/HandshakeCancel.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => handshakeCancelLaunches.push(appPath),
      });
      const callPromise = handshakeCancelShim.handle({
        jsonrpc: "2.0",
        id: 90,
        method: "tools/call",
        params: { name: "x", arguments: {} },
      });
      // Give the call a moment to actually reach connect()'s stalling
      // initialize post and register in inFlight before cancelling it.
      await new Promise((r) => setTimeout(r, 200));
      handshakeCancelShim.cancel(90, "cancelled during handshake");
      const cancelledDuringHandshake = await callPromise;
      assert.equal(cancelledDuringHandshake.result.isError, true);
      assert.match(cancelledDuringHandshake.result.content[0].text, /cancel/i);
      assert.equal(
        handshakeCancelToolCalls,
        0,
        "the tool call must never reach the backend once the handshake was cancelled",
      );
      assert.equal(handshakeCancelLaunches.length, 0, "a cancelled handshake must never launch");
    },
  );

  // -- 7p. N7: a 404 on the initial SESSIONLESS request (no session was
  //        ever established) must be HttpRejected, not treated as a stale
  //        session - only a request that actually carried a session id can
  //        be stale. A wrong --backend-url path against an otherwise-live
  //        app is the realistic trigger: today this retried as if stale
  //        and then reported Down (and could launch a running app) even
  //        though the app answered. The initialize counter proves it was
  //        not retried. -------------------------------------------------
  let sessionlessNotFoundInitCalls = 0;
  const sessionlessNotFoundLaunches = [];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          sessionlessNotFoundInitCalls += 1;
          res.writeHead(404, { "Content-Type": "text/plain" });
          res.end("not found");
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const sessionlessNotFoundShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "sessionless-404.json"),
        timeoutMs: 2_000,
        launchEnabled: true,
        appPath: "/fake/SessionlessNotFound.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => sessionlessNotFoundLaunches.push(appPath),
      });
      const notFound = await sessionlessNotFoundShim.handle({ jsonrpc: "2.0", id: 91, method: "tools/call", params: {} });
      assert.equal(notFound.result.isError, true);
      assert.match(notFound.result.content[0].text, /404/, "must surface the real HTTP status");
      assert.doesNotMatch(
        notFound.result.content[0].text,
        /not reachable|is not reachable/i,
        "a sessionless 404 is a real HTTP rejection, not downtime",
      );
      assert.equal(
        sessionlessNotFoundInitCalls,
        1,
        "a sessionless 404 must not be retried as if the session were stale",
      );
      assert.equal(sessionlessNotFoundLaunches.length, 0, "a sessionless 404 must never launch");
    },
  );

  // -- 7q. N8 end to end: a real CRLF-delimited SSE response over an actual
  //        socket must resolve with the real result, not {} (the false-
  //        success failure mode: a stream that closes without the reader
  //        ever finding a "\n\n" delimiter returns null, backend() turns
  //        that into {}, and a tools/call would report success for a
  //        mutation that never ran). -------------------------------------
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "crlf-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          // A valid CallToolResult shape (N37 now requires one) - this
          // test is about CRLF parsing, not shape.
          const response = JSON.stringify({
            jsonrpc: "2.0",
            id: msg.id,
            result: { content: [{ type: "text", text: "crlf" }] },
          });
          res.writeHead(200, { "Content-Type": "text/event-stream" });
          res.end(`data: ${response}\r\n\r\n`);
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const crlfShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "crlf.json"),
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const crlfReply = await crlfShim.handle({ jsonrpc: "2.0", id: 93, method: "tools/call", params: {} });
      assert.deepEqual(
        crlfReply.result,
        { content: [{ type: "text", text: "crlf" }] },
        "a CRLF-delimited response must resolve with the real result, not a false-success {}",
      );
    },
  );

  // -- 7q2. N28 end to end: a real backend answering with a mixed-case
  //         Content-Type must still take the incremental SSE path in
  //         post() itself (not just parseBody in isolation, 1b2 above) -
  //         the fallback (a plain res.text()) would wait for EOF on a
  //         stream a compliant backend may legally keep open, and
  //         eventually time out even though the matching event already
  //         arrived. Held open deliberately, matching 7m's own pattern,
  //         so a case-sensitive regression would show up as a timeout
  //         here, not just a wrong branch taken. -------------------------
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "mixed-case-content-type-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          // A valid CallToolResult shape (N37 now requires one) - this
          // test is about Content-Type case-sensitivity, not shape.
          const response = JSON.stringify({
            jsonrpc: "2.0",
            id: msg.id,
            result: { content: [{ type: "text", text: "mixedCase" }] },
          });
          res.writeHead(200, { "Content-Type": "Text/Event-Stream; charset=UTF-8" });
          res.write(`data: ${response}\n\n`);
          // Deliberately never res.end() - if the mixed-case type falls
          // through to the plain-text branch, this would hang until the
          // timeout below instead of resolving immediately.
          return;
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const mixedCaseShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "mixed-case-content-type.json"),
        timeoutMs: 60_000, // long enough that only taking the SSE path, not the timeout, can end the wait
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const startedAt = Date.now();
      const mixedCaseReply = await mixedCaseShim.handle({ jsonrpc: "2.0", id: 94, method: "tools/call", params: {} });
      assert.ok(
        Date.now() - startedAt < 3_000,
        "a mixed-case Content-Type must resolve promptly via the SSE path, not fall through and wait for EOF",
      );
      assert.deepEqual(
        mixedCaseReply.result,
        { content: [{ type: "text", text: "mixedCase" }] },
        "a mixed-case Content-Type must still resolve with the real result",
      );
    },
  );

  // -- 7r. N9: a reachable backend that answers HTTP 200 with a body this
  //        shim cannot parse (an HTML error page from an intermediary, or
  //        truncated JSON) must not be classified as downtime - a response
  //        arrived, so the app is up. Must surface the real parse/protocol
  //        problem, never say "not reachable", never launch. -------------
  for (const [label, contentType, malformedBody, cacheName] of [
    ["an HTML error page", "text/html", "<html><body>502 Bad Gateway</body></html>", "malformed-html.json"],
    ["truncated JSON", "application/json", '{"jsonrpc":"2.0","id":1,"resu', "malformed-truncated.json"],
  ]) {
    const malformedLaunches = [];
    await withServer(
      (req, res) => {
        readJsonBody(req).then((msg) => {
          if (msg.method === "initialize") {
            return sendJson(
              res,
              200,
              { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
              { "MCP-Session-Id": "malformed-session" },
            );
          }
          if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
          if (msg.method === "tools/call") {
            res.writeHead(200, { "Content-Type": contentType });
            res.end(malformedBody);
            return;
          }
          sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        });
      },
      async (url) => {
        const malformedShim = new Shim({
          url,
          name: "test",
          cachePath: join(cacheDir, cacheName),
          timeoutMs: 2_000,
          launchEnabled: true,
          appPath: "/fake/Malformed.app",
          launchGraceMs: 150_000,
          launcher: (appPath) => malformedLaunches.push(appPath),
        });
        const malformed = await malformedShim.handle({ jsonrpc: "2.0", id: 94, method: "tools/call", params: {} });
        assert.equal(malformed.result.isError, true, `${label}: must be an error result`);
        assert.doesNotMatch(
          malformed.result.content[0].text,
          /not reachable|is not reachable/i,
          `${label}: a parse failure on a 200 response must not be reported as unreachable`,
        );
        assert.equal(malformedLaunches.length, 0, `${label}: must never launch`);
      },
    );
  }

  // -- 7r2. N37: presence of `result` is not the same as it having the
  //         right shape. {"result":null}, a tools/call result missing
  //         `content`, and a `content` that is not an array must all be
  //         rejected the same way 7r's unparseable bodies are - reachable,
  //         not downtime, never launched, never read as success, and (for
  //         a mutating tools/call) the model must be told the operation
  //         may already have run. A valid result passes through unchanged. -
  for (const [label, malformedResult, cacheName] of [
    ["a null result", null, "shape-null.json"],
    ["a result missing content", { notContent: [] }, "shape-no-content.json"],
    ["a content that is not an array", { content: "not an array" }, "shape-content-not-array.json"],
  ]) {
    const shapeLaunches = [];
    await withServer(
      (req, res) => {
        readJsonBody(req).then((msg) => {
          if (msg.method === "initialize") {
            return sendJson(
              res,
              200,
              { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
              { "MCP-Session-Id": "shape-session" },
            );
          }
          if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
          if (msg.method === "tools/call") {
            return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: malformedResult });
          }
          sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        });
      },
      async (url) => {
        const shapeShim = new Shim({
          url,
          name: "test",
          cachePath: join(cacheDir, cacheName),
          timeoutMs: 2_000,
          launchEnabled: true,
          appPath: "/fake/Shape.app",
          launchGraceMs: 150_000,
          launcher: (appPath) => shapeLaunches.push(appPath),
        });
        const shapeReply = await shapeShim.handle({ jsonrpc: "2.0", id: 95, method: "tools/call", params: {} });
        assert.equal(shapeReply.result.isError, true, `${label}: must be an error result, never a false success`);
        assert.doesNotMatch(
          shapeReply.result.content[0].text,
          /not reachable|is not reachable/i,
          `${label}: a malformed shape from a reachable backend must not be reported as unreachable`,
        );
        assert.match(
          shapeReply.result.content[0].text,
          /may have (already )?(started|run|completed)|do not retry automatically/i,
          `${label}: the model must be told the operation may have already run, same as the Indeterminate class`,
        );
        assert.equal(shapeLaunches.length, 0, `${label}: must never launch`);
      },
    );
  }

  // A valid tools/call result (content array present) must pass through
  // completely unchanged - this is not a schema validator, only the one
  // shape MCP requires.
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "shape-valid-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          return sendJson(res, 200, {
            jsonrpc: "2.0",
            id: msg.id,
            result: { content: [{ type: "text", text: "fine" }], isError: false },
          });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const validShapeShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "shape-valid.json"),
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const validShapeReply = await validShapeShim.handle({ jsonrpc: "2.0", id: 96, method: "tools/call", params: {} });
      assert.deepEqual(
        validShapeReply.result,
        { content: [{ type: "text", text: "fine" }], isError: false },
        "a valid CallToolResult must pass through completely unchanged",
      );
    },
  );

  // A tools/list with a non-array `tools` must be rejected the same way -
  // this used to be only a caching guard (silently skip writing a bad
  // shape to disk), which let the malformed shape through to the live
  // caller anyway. Falls back to whatever cache already exists, exactly
  // like every other tools/list error (see toolsList's own catch).
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "shape-list-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/list") {
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: "not an array" } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const shapeListCachePath = join(cacheDir, "shape-list.json");
      writeCache(shapeListCachePath, [{ name: "preexisting_tool" }]);
      const shapeListShim = new Shim({
        url,
        name: "test",
        cachePath: shapeListCachePath,
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const shapeListReply = await shapeListShim.handle({ jsonrpc: "2.0", id: 97, method: "tools/list", params: {} });
      assert.deepEqual(
        shapeListReply.result.tools,
        [{ name: "preexisting_tool" }],
        "a non-array tools/list result must be rejected and fall back to the existing cache, not forwarded live",
      );
      assert.deepEqual(
        readCache(shapeListCachePath),
        [{ name: "preexisting_tool" }],
        "the persistent cache must be untouched by a rejected shape",
      );
    },
  );

  // -- 7s. N10: a request that expects a response (it always carries an id)
  //        but never gets a correlated result/error envelope must not be
  //        synthesized into a silent {} success - that reports a mutating
  //        tool call as having succeeded when its outcome was never
  //        received, the worst failure class in this file. Covers both
  //        ways it happens: a 200 with a genuinely empty body, and an SSE
  //        stream that reaches EOF without ever emitting the matching
  //        event. notifications/initialized returning an empty 200 stays
  //        fine throughout - every withServer test here (including this
  //        one) depends on exactly that already working. -----------------
  for (const [label, respond, cacheName] of [
    [
      "a 200 with an empty body",
      (res) => {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end();
      },
      "no-envelope-empty200.json",
    ],
    [
      "an SSE stream that closes with no matching id",
      (res) => {
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        res.end(`data: ${JSON.stringify({ jsonrpc: "2.0", id: 999_999, result: {} })}\n\n`);
      },
      "no-envelope-sse-eof.json",
    ],
  ]) {
    const noEnvelopeLaunches = [];
    await withServer(
      (req, res) => {
        readJsonBody(req).then((msg) => {
          if (msg.method === "initialize") {
            return sendJson(
              res,
              200,
              { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
              { "MCP-Session-Id": "no-envelope-session" },
            );
          }
          if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
          if (msg.method === "tools/call") return respond(res);
          sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        });
      },
      async (url) => {
        const noEnvelopeShim = new Shim({
          url,
          name: "test",
          cachePath: join(cacheDir, cacheName),
          timeoutMs: 2_000,
          launchEnabled: true,
          appPath: "/fake/NoEnvelope.app",
          launchGraceMs: 150_000,
          launcher: (appPath) => noEnvelopeLaunches.push(appPath),
        });
        const noEnvelope = await noEnvelopeShim.handle({ jsonrpc: "2.0", id: 95, method: "tools/call", params: {} });
        assert.equal(noEnvelope.result.isError, true, `${label}: a missing response must not read as success`);
        assert.match(
          noEnvelope.result.content[0].text,
          /no response|not received/i,
          `${label}: must name the missing response`,
        );
        assert.equal(noEnvelopeLaunches.length, 0, `${label}: must never launch`);
      },
    );
  }

  // -- 7t. N14: the plain-JSON transport must enforce the same exact-id
  //        correlation the SSE path already does - a response for a
  //        different id than the one this request sent must not be
  //        accepted as this call's answer (a delayed or misrouted
  //        response would otherwise read as a false success on a
  //        mutating call). The matching-id case stays unchanged. --------
  const mismatchedIdLaunches = [];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "mismatch-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "tools/call") {
          // Answer with a DIFFERENT id than the one this request sent - a
          // delayed/misrouted response for some other request.
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id + 999, result: { wrong: true } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const mismatchedIdShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "mismatched-id.json"),
        timeoutMs: 2_000,
        launchEnabled: true,
        appPath: "/fake/MismatchedId.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => mismatchedIdLaunches.push(appPath),
      });
      const mismatched = await mismatchedIdShim.handle({ jsonrpc: "2.0", id: 96, method: "tools/call", params: {} });
      assert.equal(mismatched.result.isError, true, "a mismatched response id must not read as success");
      assert.doesNotMatch(
        mismatched.result.content[0].text,
        /not reachable|is not reachable/i,
        "a mismatched-id response is reachable, not downtime",
      );
      assert.equal(mismatchedIdLaunches.length, 0, "a mismatched-id response must never launch");
    },
  );

  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "match-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        sendJson(res, 200, {
          jsonrpc: "2.0",
          id: msg.id,
          // A valid CallToolResult shape (N37 now requires one) for
          // tools/call - this test is about id correlation, not shape.
          result: msg.method === "tools/call" ? { content: [{ type: "text", text: "ok" }] } : {},
        });
      });
    },
    async (url) => {
      const matchedIdShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "matched-id.json"),
        timeoutMs: 2_000,
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const matched = await matchedIdShim.handle({ jsonrpc: "2.0", id: 97, method: "tools/call", params: {} });
      assert.deepEqual(matched.result, { content: [{ type: "text", text: "ok" }] }, "a matching-id JSON response must still work");
    },
  );

  // -- 7u. N12: backend() must allocate a unique id per call, not always
  //        "1" - cancellation is dispatched OUTSIDE the serialized queue
  //        (deliberately, since N6), so a cancel for call A can arrive
  //        after call B has started; a shared hardcoded id would let the
  //        cancel land on B, or leave two outstanding requests sharing an
  //        id. Assert via a request counter, not timing: the forwarded
  //        cancellation must name A's own backend id, and B (started
  //        immediately after A is cancelled, without waiting for A to
  //        settle) must complete normally with its own result. ----------
  let idRaceCancelForward = null;
  const idRaceToolCallIds = [];
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        if (msg.method === "initialize") {
          return sendJson(
            res,
            200,
            { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
            { "MCP-Session-Id": "id-race-session" },
          );
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        if (msg.method === "notifications/cancelled") {
          idRaceCancelForward = msg.params;
          return sendJson(res, 200, undefined);
        }
        if (msg.method === "tools/call") {
          idRaceToolCallIds.push(msg.id);
          if (idRaceToolCallIds.length === 1) {
            // Call A - stall so there is something real for cancel() to
            // interrupt.
            res.writeHead(200, { "Content-Type": "application/json" });
            return;
          }
          // Call B - answer normally, correlated by its OWN id. Valid
          // CallToolResult shape (N37 now requires one) - this test is
          // about id allocation, not shape.
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: "callB" }] } });
        }
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const idRaceShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "id-race.json"),
        timeoutMs: 60_000, // long enough that only cancel(), not the timeout, ends call A's wait
        launchEnabled: false,
        appPath: null,
        launchGraceMs: 150_000,
      });
      const callA = idRaceShim.handle({ jsonrpc: "2.0", id: 98, method: "tools/call", params: {} });
      // Give A a moment to actually reach the stalling backend and
      // register in inFlight before cancelling it.
      await new Promise((r) => setTimeout(r, 200));
      idRaceShim.cancel(98, "cancel A");
      // Immediately start B, without awaiting A's settlement - exactly the
      // queue-bypass race N12 describes.
      const callB = idRaceShim.handle({ jsonrpc: "2.0", id: 99, method: "tools/call", params: {} });
      const [resultA, resultB] = await Promise.all([callA, callB]);
      assert.equal(resultA.result.isError, true, "call A must report as cancelled");
      assert.deepEqual(
        resultB.result,
        { content: [{ type: "text", text: "callB" }] },
        "call B must complete normally with its own result",
      );

      // idRaceToolCallIds is already deterministic here - resultB only
      // resolved because the fake server's tools/call handler (which
      // pushes to it) already ran. idRaceCancelForward is different:
      // idRaceShim.cancel(98, ...) above is the LIVE cancel() call site
      // (matching main()'s own notifications/cancelled handler, which
      // deliberately never awaits cancel()'s return), so that forward is
      // genuinely fire-and-forget - poll with a bounded wait instead of a
      // fixed sleep, the way this file's existing waitFor pattern does.
      assert.equal(idRaceToolCallIds.length, 2, "both calls must have reached the backend");
      assert.notEqual(
        idRaceToolCallIds[0],
        idRaceToolCallIds[1],
        "call A and call B must use different backend request ids, not a shared hardcoded one",
      );
      const idRaceForwardDeadline = Date.now() + 2_000;
      while (idRaceCancelForward === null && Date.now() < idRaceForwardDeadline) {
        await new Promise((r) => setTimeout(r, 25));
      }
      assert.deepEqual(
        idRaceCancelForward,
        { requestId: idRaceToolCallIds[0], reason: "cancel A" },
        "the forwarded cancellation must name A's own backend id, not B's and not a hardcoded 1",
      );
    },
  );

  // -- 7v. N15: connect() must require a successful initialize result
  //        before sending anything else - an error envelope from a
  //        reachable backend must not be silently absorbed into a default
  //        protocol version and a connected session. Assert on the fake
  //        backend's received-methods list (not just the client-visible
  //        result) that notifications/initialized was never sent, and
  //        that a SUBSEQUENT call re-handshakes rather than proceeding as
  //        if already connected (a stale this.connected=true would skip
  //        straight to the real, possibly mutating, call). --------------
  const rejectedHandshakeLaunches = [];
  const rejectedHandshakeMethods = [];
  let initializeCalls = 0;
  await withServer(
    (req, res) => {
      readJsonBody(req).then((msg) => {
        rejectedHandshakeMethods.push(msg.method);
        if (msg.method === "initialize") {
          initializeCalls += 1;
          return sendJson(res, 200, {
            jsonrpc: "2.0",
            id: msg.id,
            error: { code: -32000, message: "handshake rejected: license expired" },
          });
        }
        if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
      });
    },
    async (url) => {
      const rejectedShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "rejected-handshake.json"),
        timeoutMs: 2_000,
        launchEnabled: true,
        appPath: "/fake/RejectedHandshake.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => rejectedHandshakeLaunches.push(appPath),
      });
      const first = await rejectedShim.handle({ jsonrpc: "2.0", id: 100, method: "tools/call", params: {} });
      assert.equal(first.result.isError, true, "a rejected handshake must not read as success");
      assert.match(first.result.content[0].text, /license expired/, "must surface the backend's own message");
      assert.equal(rejectedHandshakeLaunches.length, 0, "a rejected handshake is reachable, not downtime - must never launch");
      assert.equal(rejectedShim.connected, false, "a rejected handshake must not mark the session connected");
      assert.equal(
        rejectedHandshakeMethods.includes("notifications/initialized"),
        false,
        "notifications/initialized must never be sent after a rejected handshake",
      );

      // A SUBSEQUENT call must re-handshake, not proceed as if connected.
      const second = await rejectedShim.handle({ jsonrpc: "2.0", id: 101, method: "tools/call", params: {} });
      assert.equal(second.result.isError, true);
      assert.equal(initializeCalls, 2, "a subsequent call must re-attempt the handshake, not skip it as if already connected");
    },
  );

  // -- 7v2. N23: connect() must require a real RESULT, not merely the
  //         absence of an error - a 200 with an empty body, or an envelope
  //         carrying neither result nor error, is a protocol failure, not
  //         a completed handshake. Same assertions as 7v: no launch, no
  //         notifications/initialized (checked against the fake backend's
  //         received-methods list), session left unconnected so a
  //         subsequent call re-handshakes rather than proceeding as if
  //         initialize had actually succeeded. -------------------------
  for (const [label, respondToInitialize] of [
    ["an empty 200 body", (res) => sendJson(res, 200, undefined)],
    ["an envelope with neither result nor error", (res, msg) => sendJson(res, 200, { jsonrpc: "2.0", id: msg.id })],
  ]) {
    const noResultLaunches = [];
    const noResultMethods = [];
    let noResultInitializeCalls = 0;
    await withServer(
      (req, res) => {
        readJsonBody(req).then((msg) => {
          noResultMethods.push(msg.method);
          if (msg.method === "initialize") {
            noResultInitializeCalls += 1;
            return respondToInitialize(res, msg);
          }
          if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
          sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        });
      },
      async (url) => {
        const noResultShim = new Shim({
          url,
          name: "test",
          cachePath: join(cacheDir, `no-result-handshake-${noResultMethods.length}.json`),
          timeoutMs: 2_000,
          launchEnabled: true,
          appPath: "/fake/NoResultHandshake.app",
          launchGraceMs: 150_000,
          launcher: (appPath) => noResultLaunches.push(appPath),
        });
        const first = await noResultShim.handle({ jsonrpc: "2.0", id: 105, method: "tools/call", params: {} });
        assert.equal(first.result.isError, true, `${label}: a missing handshake result must not read as success`);
        assert.equal(noResultLaunches.length, 0, `${label}: a reachable-but-resultless handshake must never launch`);
        assert.equal(noResultShim.connected, false, `${label}: must not mark the session connected`);
        assert.equal(
          noResultMethods.includes("notifications/initialized"),
          false,
          `${label}: notifications/initialized must never be sent after a resultless handshake`,
        );

        const second = await noResultShim.handle({ jsonrpc: "2.0", id: 106, method: "tools/call", params: {} });
        assert.equal(second.result.isError, true);
        assert.equal(
          noResultInitializeCalls,
          2,
          `${label}: a subsequent call must re-attempt the handshake, not skip it as if already connected`,
        );
      },
    );
  }

  // -- 7v3. N45: presence of a handshake `result` is not shape, same as
  //         N37 one level up - {"result":null}, {"result":{}}, and a
  //         result missing protocolVersion must all fail the handshake
  //         the same way 7v2's resultless cases do: no
  //         notifications/initialized (checked against the fake backend's
  //         received-methods list), session left unconnected so a
  //         subsequent call re-handshakes, no launch. A valid
  //         initialization result (used everywhere else in this file) is
  //         unaffected. ---------------------------------------------------
  for (const [label, badInitializeResult] of [
    ["a null result", null],
    ["an empty object result", {}],
    ["a result missing protocolVersion", { capabilities: {}, serverInfo: { name: "fake" } }],
  ]) {
    const badShapeLaunches = [];
    const badShapeMethods = [];
    let badShapeInitializeCalls = 0;
    await withServer(
      (req, res) => {
        readJsonBody(req).then((msg) => {
          badShapeMethods.push(msg.method);
          if (msg.method === "initialize") {
            badShapeInitializeCalls += 1;
            return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: badInitializeResult });
          }
          if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
          sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        });
      },
      async (url) => {
        const badShapeShim = new Shim({
          url,
          name: "test",
          cachePath: join(cacheDir, `bad-shape-handshake-${badShapeMethods.length}.json`),
          timeoutMs: 2_000,
          launchEnabled: true,
          appPath: "/fake/BadShapeHandshake.app",
          launchGraceMs: 150_000,
          launcher: (appPath) => badShapeLaunches.push(appPath),
        });
        const first = await badShapeShim.handle({ jsonrpc: "2.0", id: 107, method: "tools/call", params: {} });
        assert.equal(first.result.isError, true, `${label}: a malformed handshake result must not read as success`);
        assert.equal(badShapeLaunches.length, 0, `${label}: a malformed-shape handshake must never launch`);
        assert.equal(badShapeShim.connected, false, `${label}: must not mark the session connected`);
        assert.equal(
          badShapeMethods.includes("notifications/initialized"),
          false,
          `${label}: notifications/initialized must never be sent after a malformed-shape handshake`,
        );

        const second = await badShapeShim.handle({ jsonrpc: "2.0", id: 108, method: "tools/call", params: {} });
        assert.equal(second.result.isError, true);
        assert.equal(
          badShapeInitializeCalls,
          2,
          `${label}: a subsequent call must re-attempt the handshake, not skip it as if already connected`,
        );
      },
    );
  }

  // -- 7w. N20/N22: a timeout never proves the backend did not receive the
  //        request - it only proves we stopped waiting, whether or not
  //        headers ever arrived. Both shapes below must be Indeterminate:
  //        never launch, never say "not reachable", warn the operation may
  //        still be running (retrying could duplicate a mutation -
  //        aborting our own fetch does not stop the backend). N20's own
  //        discriminator (res.ok - headers received) left the "backend
  //        withholds headers until the operation completes" shape
  //        misclassified as Down; N22 closes that by classifying on
  //        WHETHER WE TIMED OUT, not on how far the response got. Only a
  //        genuine connection-level failure (below, 7w2) is real downtime.
  //        -------------------------------------------------------------
  const establishedTimeoutLaunches = [];
  await withServer(
    (req, res) => {
      // Establish the response - 200, SSE headers, one byte of body - then
      // stall forever without ever sending the matching event or closing.
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.write(": keepalive\n\n");
    },
    async (url) => {
      const establishedTimeoutShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "established-timeout.json"),
        timeoutMs: 200,
        launchEnabled: true,
        appPath: "/fake/EstablishedTimeout.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => establishedTimeoutLaunches.push(appPath),
      });
      const timedOut = await establishedTimeoutShim.handle({ jsonrpc: "2.0", id: 102, method: "tools/call", params: {} });
      assert.equal(timedOut.result.isError, true);
      assert.doesNotMatch(
        timedOut.result.content[0].text,
        /not reachable|is not reachable/i,
        "a timeout after headers arrived must not be reported as unreachable",
      );
      assert.match(
        timedOut.result.content[0].text,
        /still be running|do not retry/i,
        "must warn that the operation may still be running and must not be retried blindly",
      );
      assert.equal(establishedTimeoutLaunches.length, 0, "a timeout after headers arrived must never launch");
    },
  );

  const noHeadersTimeoutLaunches = [];
  await withServer(
    () => {
      // Accept the connection but withhold everything - not even headers -
      // until the timeout fires. A backend that only answers once an
      // operation completes looks exactly like this. N20's res.ok
      // discriminator misclassified this as Down; it must be Indeterminate
      // for the same reason the established-then-stalls case above is.
    },
    async (url) => {
      const noHeadersTimeoutShim = new Shim({
        url,
        name: "test",
        cachePath: join(cacheDir, "no-headers-timeout.json"),
        timeoutMs: 200,
        launchEnabled: true,
        appPath: "/fake/NoHeadersTimeout.app",
        launchGraceMs: 150_000,
        launcher: (appPath) => noHeadersTimeoutLaunches.push(appPath),
      });
      const timedOut = await noHeadersTimeoutShim.handle({ jsonrpc: "2.0", id: 103, method: "tools/call", params: {} });
      assert.equal(timedOut.result.isError, true);
      assert.doesNotMatch(
        timedOut.result.content[0].text,
        /not reachable|is not reachable/i,
        "a timeout before any headers arrived must not be reported as unreachable",
      );
      assert.match(
        timedOut.result.content[0].text,
        /still be running|do not retry/i,
        "must warn that the operation may still be running even though no headers ever arrived",
      );
      assert.equal(noHeadersTimeoutLaunches.length, 0, "a timeout before any headers arrived must never launch");
    },
  );

  // -- 7w2. N22: a genuine connection-level failure (nothing listening at
  //         all - ECONNREFUSED) is real downtime and must keep working
  //         exactly as before: Down, and still launches. This is the one
  //         case that must NOT become Indeterminate. -------------------
  const refusedLaunches = [];
  const refusedShim = new Shim({
    // Not :1 - Node/undici blocks that port client-side ("bad port", no
    // error code) before ever attempting a connection, so it does not
    // reliably produce a real ECONNREFUSED. A genuinely refused high port
    // does; see PROVEN_UNDELIVERED_CODES.
    url: "http://127.0.0.1:65533/mcp",
    name: "test",
    cachePath: join(cacheDir, "refused.json"),
    timeoutMs: 2_000,
    launchEnabled: true,
    appPath: "/fake/Refused.app",
    launchGraceMs: 150_000,
    launcher: (appPath) => refusedLaunches.push(appPath),
  });
  const refused = await refusedShim.handle({ jsonrpc: "2.0", id: 104, method: "tools/call", params: {} });
  assert.equal(refused.result.isError, true);
  assert.equal(refusedLaunches.length, 1, "a connection-level failure (ECONNREFUSED) must still be classified Down and still launch");

  // -- 7w3. N25: a connection that fails AFTER the request was transmitted
  //         (a reset, EPIPE, or socket hang-up - Node/undici surfaces this
  //         as cause.code UND_ERR_SOCKET) is exactly as Indeterminate as a
  //         timeout - the app may have crashed or restarted mid-operation,
  //         not proof the request was undelivered. fetch() rejects here
  //         without post()'s own controller ever aborting it, which is
  //         exactly the gap N20/N22's abort-only discriminator left open.
  //         Destroy the socket mid-request to reproduce this for real. ---
  const midRequestResetLaunches = [];
  const resetServer = createServer((req) => {
    req.socket.destroy();
  });
  await new Promise((resolvePromise) => resetServer.listen(0, "127.0.0.1", resolvePromise));
  try {
    const { port: resetPort } = resetServer.address();
    const midRequestResetShim = new Shim({
      url: `http://127.0.0.1:${resetPort}/mcp`,
      name: "test",
      cachePath: join(cacheDir, "mid-request-reset.json"),
      timeoutMs: 2_000,
      launchEnabled: true,
      appPath: "/fake/MidRequestReset.app",
      launchGraceMs: 150_000,
      launcher: (appPath) => midRequestResetLaunches.push(appPath),
    });
    const reset = await midRequestResetShim.handle({ jsonrpc: "2.0", id: 108, method: "tools/call", params: {} });
    assert.equal(reset.result.isError, true);
    assert.doesNotMatch(
      reset.result.content[0].text,
      /not reachable|is not reachable/i,
      "a mid-request reset must not be reported as unreachable",
    );
    assert.match(
      reset.result.content[0].text,
      /still be running|do not retry/i,
      "a mid-request reset must warn that the operation may still be running",
    );
    assert.equal(midRequestResetLaunches.length, 0, "a mid-request reset must never launch");
  } finally {
    resetServer.close();
  }

  // -- 7w4. N25: an unrecognized (or synthetic) error code must default to
  //         Indeterminate, not Down - the safe direction is to under-claim
  //         downtime, never to over-claim it. Temporarily replaces global
  //         fetch with one that rejects with a synthetic, deliberately-
  //         unrecognized error code, to test the classifier directly
  //         without depending on a specific real-world failure mode to
  //         reproduce it (unlike 7w3's real socket reset above). --------
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async () => {
      const err = new TypeError("fetch failed");
      err.cause = Object.assign(new Error("synthetic failure"), { code: "ESYNTHETIC_UNKNOWN" });
      throw err;
    };
    const unknownCodeLaunches = [];
    const unknownCodeShim = new Shim({
      url: "http://127.0.0.1:65533/mcp", // never actually contacted - fetch is replaced above
      name: "test",
      cachePath: join(cacheDir, "unknown-code.json"),
      timeoutMs: 2_000,
      launchEnabled: true,
      appPath: "/fake/UnknownCode.app",
      launchGraceMs: 150_000,
      launcher: (appPath) => unknownCodeLaunches.push(appPath),
    });
    const unknownCode = await unknownCodeShim.handle({ jsonrpc: "2.0", id: 109, method: "tools/call", params: {} });
    assert.equal(unknownCode.result.isError, true);
    assert.doesNotMatch(
      unknownCode.result.content[0].text,
      /not reachable|is not reachable/i,
      "an unrecognized error code must not be reported as unreachable",
    );
    assert.match(
      unknownCode.result.content[0].text,
      /still be running|do not retry/i,
      "an unrecognized error code must warn about retrying, matching Indeterminate",
    );
    assert.equal(unknownCodeLaunches.length, 0, "an unrecognized error code must never launch");
  } finally {
    globalThis.fetch = originalFetch;
  }

  // -- 7w5. N30: a URL-parse failure at REQUEST time (not just the
  //         buildShimFromArgs startup check above) must classify as a
  //         configuration error, not Indeterminate - nothing was ever
  //         transmitted, so "the operation may have run" would be
  //         backwards. Constructs a Shim directly with an invalid URL,
  //         bypassing buildShimFromArgs entirely, to reach this route -
  //         the real fetch() genuinely rejects on a malformed URL with no
  //         mocking needed. Never launches either: restarting the app
  //         cannot fix a broken URL. -----------------------------------
  const badUrlLaunches = [];
  const badUrlShim = new Shim({
    url: "127.0.0.1:27182/mcp", // schemeless - fetch() itself rejects this
    name: "test",
    cachePath: join(cacheDir, "bad-url.json"),
    timeoutMs: 2_000,
    launchEnabled: true,
    appPath: "/fake/BadUrl.app",
    launchGraceMs: 150_000,
    launcher: (appPath) => badUrlLaunches.push(appPath),
  });
  const badUrl = await badUrlShim.handle({ jsonrpc: "2.0", id: 110, method: "tools/call", params: {} });
  assert.equal(badUrl.result.isError, true);
  assert.doesNotMatch(
    badUrl.result.content[0].text,
    /not reachable|is not reachable|still be running|do not retry/i,
    "a malformed backend URL must not be reported as downtime or as an indeterminate retry risk",
  );
  assert.match(badUrl.result.content[0].text, /backend-url/i, "must point at the --backend-url configuration");
  assert.equal(badUrlLaunches.length, 0, "a malformed backend URL must never launch - restarting the app cannot fix it");

  // -- 7z. N47: a fetch-forbidden port reaching the REQUEST path (a Shim
  //       built directly, bypassing buildShimFromArgs's own validation
  //       at construction time - the same bypass shape badUrlShim above
  //       exercises for a schemeless URL) must classify as
  //       ConfigurationError, not Indeterminate. Before this fix, undici's
  //       client-side block for this exact port carries no recognized
  //       error code, so post() fell through to "the operation may have
  //       run" when nothing was ever transmitted - independent protection
  //       from the startup-time rejection tested elsewhere. --------------
  const badPortLaunches = [];
  const badPortShim = new Shim({
    url: "http://127.0.0.1:1/mcp", // fetch-forbidden - never reaches the network at all
    name: "test",
    cachePath: join(cacheDir, "bad-port.json"),
    timeoutMs: 2_000,
    launchEnabled: true,
    appPath: "/fake/BadPort.app",
    launchGraceMs: 150_000,
    launcher: (appPath) => badPortLaunches.push(appPath),
  });
  const badPort = await badPortShim.handle({ jsonrpc: "2.0", id: 111, method: "tools/call", params: {} });
  assert.equal(badPort.result.isError, true);
  assert.doesNotMatch(
    badPort.result.content[0].text,
    /not reachable|is not reachable|still be running|do not retry|still starting/i,
    "a fetch-forbidden port must not be reported as downtime, a launch-in-progress, or an indeterminate retry risk",
  );
  assert.match(badPort.result.content[0].text, /backend-url/i, "must point at the --backend-url configuration, same as the ConfigurationError class");
  assert.equal(badPortLaunches.length, 0, "a fetch-forbidden port must never launch - restarting the app cannot fix it");

  // -- 8. process-level: one malformed stdin line must not kill the shim
  const initReply = await runChildAndGetReply(
    MCP_SIDING_PATH,
    ["this is not json at all", JSON.stringify({ jsonrpc: "2.0", id: 99, method: "initialize", params: {} })],
    99,
  );
  assert.equal(initReply.result.serverInfo.name, "test");

  // -- 9. RESOLVER_SH: ordered fallthrough, highest-version-wins, and a
  //       clear non-zero failure when nothing resolves ------------------
  await selftestResolver();

  // -- 10. run from a path containing a space - the exact command
  //        SKILL.md tells users to run must not break on one -------------
  const spaceDir = await mkdtemp(join(tmpdir(), "mcp siding space-"));
  const copiedScript = join(spaceDir, "mcp-siding.mjs");
  await copyFile(MCP_SIDING_PATH, copiedScript);
  const spaceReply = await runChildAndGetReply(
    copiedScript,
    [JSON.stringify({ jsonrpc: "2.0", id: 99, method: "initialize", params: {} })],
    99,
  );
  assert.equal(spaceReply.result.serverInfo.name, "test");

  // -- 11. shQuote / buildShimScript: the injection boundary, exercised
  //        with a hostile --name --------------------------------------
  const hostileName = `a'; touch /tmp/mcp-siding-selftest-pwn; echo 'done`;
  const echoBack = spawnSync("/bin/sh", ["-c", `printf '%s' ${shQuote(hostileName)}`], { encoding: "utf8" });
  assert.equal(echoBack.status, 0);
  assert.equal(echoBack.stdout, hostileName, "shQuote must round-trip a hostile value with no shell interpretation");

  const hostileScript = buildShimScript({
    "backend-url": "http://127.0.0.1:1/mcp",
    name: hostileName,
    app: `/Applications/Weird "App".app`,
  });
  const syntaxCheck = spawnSync("/bin/sh", ["-n", "-c", hostileScript], { encoding: "utf8" });
  assert.equal(syntaxCheck.status, 0, `buildShimScript output must remain valid sh with a hostile --name: ${syntaxCheck.stderr}`);

  process.stdout.write(
    `selftest ok (${listed.result.tools.length} cached tool(s), recovery + stale-session-once + timeout + ` +
      "SSE-multi-event + notification-forwarding + error-cache-preservation + session-less + resolver + " +
      "windows-registration + space-path + injection verified)\n",
  );
}

// -- selftest helpers --------------------------------------------------------

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      try {
        resolve(JSON.parse(raw));
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

function sendJson(res, status, bodyObj, headers = {}) {
  res.writeHead(status, { "Content-Type": "application/json", ...headers });
  res.end(bodyObj === undefined ? undefined : JSON.stringify(bodyObj));
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

// Starts a throwaway HTTP server on a free port, runs `fn(url)` against it,
// and always tears it down afterward - the shape every self-contained
// backend-behavior test below needs (unlike the 7a recovery test, which
// specifically needs a port that starts out *not* listening).
async function withServer(handler, fn) {
  const server = createServer((req, res) => {
    // A shim's shutdown() sends a best-effort session-release DELETE with
    // no body when the client disconnects (see N33) - real MCP backends
    // handle a bodyless DELETE fine; these fixture handlers are shaped
    // around POST-with-a-JSON-body and would otherwise crash trying to
    // parse an empty DELETE body as JSON. Handled once, here, rather than
    // in every individual fixture.
    if (req.method === "DELETE") {
      res.writeHead(204);
      res.end();
      return;
    }
    handler(req, res);
  });
  const port = await new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
  try {
    return await fn(`http://127.0.0.1:${port}/mcp`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

// N1: proves a real spawn() failure inside the launcher does not kill the
// shim process, through the REAL defaultLauncher - deliberately not the
// injected launcher seam every other launch test in this file uses, since
// that seam never touches spawn()'s real async 'error' event and is
// exactly what let this bug hide. spawn() does not throw synchronously for
// a command it can't run; the returned ChildProcess emits 'error'
// asynchronously, and an EventEmitter's unhandled 'error' event kills the
// whole process - which used to take the entire stdio server down on the
// first tools/call that tried to launch a bad --app.
//
// On this platform defaultLauncher always spawns `open -a <path>`
// (process.platform is "darwin" here, unconditionally) - `open` itself
// exists, so a merely-nonexistent --app target would still spawn `open`
// successfully; it would just print its own "app not found" to stderr
// (ignored) and exit nonzero - no crash either way, and not a
// reproduction of the actual bug. Breaking PATH so `open` itself can't be
// resolved reproduces the real failure class instead: spawn() itself
// failing (ENOENT), asynchronously, through the unmodified defaultLauncher.
async function selftestLauncherErrorDoesNotCrash() {
  const child = spawn(
    process.execPath,
    [
      MCP_SIDING_PATH,
      "--backend-url",
      // Not :1 - Node/undici blocks that port client-side ("bad port", no
      // error code) before ever attempting a connection, so it does not
      // reliably classify Down/launch-eligible (see N25). This test needs
      // a real refused port to force downCallResult() to actually launch.
      "http://127.0.0.1:65533/mcp",
      "--name",
      "test",
      "--app",
      "/definitely/does/not/exist/NoSuchApp.app",
      "--launch",
    ],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, PATH: "/definitely/not/a/real/path" } },
  );
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => (out += chunk));
  let err = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => (err += chunk));
  const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

  const waitFor = async (marker, deadlineMs) => {
    const deadline = Date.now() + deadlineMs;
    while (!out.includes(marker) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 25));
    }
    return out.includes(marker);
  };

  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 50, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
  assert.ok(await waitFor('"id":50', 5_000), `child never answered the launch-triggering tools/call (stderr: ${err})`);

  // The launcher's spawn('open', ...) failure, if it fires, does so
  // asynchronously - give it a moment to land, then prove the process is
  // still alive (not just that it answered before the error could fire).
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(child.exitCode, null, `the shim process must not die from a launch failure (stderr: ${err})`);

  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 51, method: "initialize", params: {} })}\n`);
  const answeredAgain = await waitFor('"id":51', 5_000);
  child.stdin.end();
  await Promise.race([exited, new Promise((r) => setTimeout(r, 2_000))]);
  if (child.exitCode == null) child.kill();

  assert.ok(answeredAgain, `child died or stopped answering after the launch attempt (stderr: ${err})`);
}

// The three hardcoded absolute node fallback paths NODE_RESOLVER_SH (and
// SKILL.md's install snippet, which mirrors it) checks are real system
// paths - not overridable via PATH/HOME - so "nothing resolves anywhere"
// and "only a hardcoded fallback resolves" used to be only conditionally
// testable, skipped on any machine that happens to have (or lack) a real
// node at e.g. /opt/homebrew/bin/node. That meant the assertion never ran
// at all on a dev machine with Homebrew's node installed - only in CI,
// where a genuine crash (the EPIPE this whole fix responds to) went
// unnoticed through 20 local passes. Rewriting these three literal paths
// to point inside a test-controlled directory makes both cases
// constructible on ANY machine instead of conditional on it - confirmed
// faithful by a positive-control case (selftestNodeResolver, below) that
// places a real node at one of the rewritten paths and checks it still
// resolves, rather than assumed.
function rewriteHardcodedNodeFallbacks(scriptText, dir) {
  return scriptText
    .replaceAll("/opt/homebrew/bin/node", join(dir, "opt-homebrew-node"))
    .replaceAll("/usr/local/bin/node", join(dir, "usr-local-node"))
    .replaceAll("/usr/bin/node", join(dir, "usr-bin-node"));
}

// Never COPY the real node binary to a synthetic path to stage "a real
// node" somewhere the resolver will find it - a relocated signed binary
// can fail its own signature check on macOS (Abort trap: 6, observed in
// CI), and a Node build can also lose its dylib resolution when moved
// outside its original install layout. Neither is what any test here is
// actually about, and it happens to work or not per-machine depending on
// exactly how that machine's Node was signed/linked - precisely the kind
// of environment difference the fallback-rewrite work this responds to
// exists to stop hiding. A tiny POSIX wrapper that `exec`s the real,
// never-relocated binary by its absolute path satisfies the resolver's
// `-x` check and its capability probe (the probe's `-e` flags forward
// straight through to the genuine runtime via "$@") with no signing or
// linking assumptions at all.
async function stageNodeWrapper(destPath) {
  await writeFile(destPath, `#!/bin/sh\nexec "${process.execPath}" "$@"\n`);
  await chmod(destPath, 0o755);
}

// N21: runs buildShimScript()'s FULL output (RESOLVER_SH + NODE_RESOLVER_SH
// + the exec line) through a real `/bin/sh -c`, exactly the way a
// registration actually invokes it - resolving mcp-siding.mjs itself is not
// enough on its own if there is then no `node` to run it with. $MCP_SIDING_PATH
// pins the script resolution deterministically (RESOLVER_SH is not what
// these tests are about); each case doctors PATH/HOME/$MCP_SIDING_NODE to
// control node resolution specifically. `fallbackDir`, when given, rewrites
// the three hardcoded absolute fallbacks (see rewriteHardcodedNodeFallbacks)
// so a case can control what they resolve to as well.
async function runShimScript(env, timeoutMs = 5_000, fallbackDir) {
  // Not port 1 (N47: a fetch-forbidden port is now rejected by
  // buildShimFromArgs at startup, before the stdio server even opens -
  // exactly the validation this file is elsewhere proving exists, so
  // using one here would make every resolver case in this function fail
  // before ever reaching what it is actually testing). This helper only
  // ever answers a locally-handled `initialize`, never touches the
  // backend, so any syntactically valid, non-forbidden port is fine.
  let script = buildShimScript({ "backend-url": "http://127.0.0.1:65533/mcp", name: "test" });
  if (fallbackDir) script = rewriteHardcodedNodeFallbacks(script, fallbackDir);
  const child = spawn("/bin/sh", ["-c", script], { stdio: ["pipe", "pipe", "pipe"], env });
  // Every fail-closed resolver path this helper exists to test (unusable
  // MCP_SIDING_NODE/MCP_SIDING_PATH, no node anywhere, ...) exits BEFORE
  // ever reading stdin - the write below then hits a closed pipe. That is
  // expected data for this helper ("the child exited before we could
  // write"), not a crash: an unhandled 'error' event on a stream kills
  // the whole process (same class as N1, in this harness instead of
  // production - see the CI incident this comment is responding to).
  // Caught here, once, for every caller of this helper, rather than
  // guarding the write call site by call site.
  child.stdin.on("error", () => {});
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => (out += chunk));
  let err = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => (err += chunk));
  let exitCode;
  let exited = false;
  child.on("exit", (code) => {
    exited = true;
    exitCode = code;
  });
  // initialize is answered locally by the shim regardless of backend
  // reachability - a reply proves the process actually started, without
  // needing a real backend. A working shim never exits on its own (it
  // serves stdin until closed/killed), so success is "the marker showed
  // up," not "the process exited" - only the failure path (no node
  // resolved anywhere) exits quickly on its own, and success there means
  // reaching that exit before the timeout, not a marker. The write itself
  // is also wrapped: a pipe that is already gone by the time write() is
  // called can throw synchronously instead of emitting 'error' async,
  // depending on exactly how far the child got - either way, a child that
  // already exited (checked below via `exited`/`exitCode`) is the real
  // signal this function returns, not whether the write nominally
  // succeeded.
  try {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 60, method: "initialize", params: {} })}\n`);
  } catch {
    // Same as the 'error' handler above - a fail-closed child exiting
    // before this write lands is expected, not a bug.
  }
  const deadline = Date.now() + timeoutMs;
  while (!out.includes('"id":60') && !exited && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 25));
  }
  const timedOut = !out.includes('"id":60') && !exited;
  if (!exited) child.kill();
  return { code: exited ? exitCode : null, out, err, timedOut };
}

async function selftestNodeResolver() {
  const realNode = process.execPath;
  const brokenPath = "/definitely/not/a/real/path";
  const baseEnv = { ...process.env, MCP_SIDING_PATH };

  // -- normal case unchanged: PATH intact, node resolves via `command -v
  //    node` exactly as it always did. --------------------------------
  const normal = await runShimScript(baseEnv);
  assert.ok(!normal.timedOut, `normal-case script hung (stderr: ${normal.err})`);
  assert.ok(normal.out.includes('"id":60'), `normal-case script never answered initialize (stderr: ${normal.err})`);

  // -- node absent from PATH but present via $MCP_SIDING_NODE, the
  //    explicit override - the same kind of pin $MCP_SIDING_PATH is. ----
  const overrideResult = await runShimScript({ ...baseEnv, PATH: brokenPath, MCP_SIDING_NODE: realNode });
  assert.ok(!overrideResult.timedOut, `MCP_SIDING_NODE override script hung (stderr: ${overrideResult.err})`);
  assert.ok(
    overrideResult.out.includes('"id":60'),
    `script did not start with node absent from PATH but present via $MCP_SIDING_NODE (stderr: ${overrideResult.err})`,
  );

  // -- N31: $MCP_SIDING_NODE set but unusable must fail closed, not fall
  //    through to PATH/the fixed fallbacks - same rule as N29's
  //    $MCP_SIDING_PATH, applied here too (a registration could otherwise
  //    quietly run under a different Node than the one being pinned for
  //    testing). PATH is left INTACT with a perfectly good node on it -
  //    that usable alternative is what makes the "does not fall through"
  //    assertion meaningful, same reasoning as N29's own test. -----------
  const n31Home = await mkdtemp(join(tmpdir(), "mcp-siding-node-override-"));
  try {
    const missingNodePath = join(n31Home, "nope-node");
    const missingNodeResult = await runShimScript({ ...baseEnv, MCP_SIDING_NODE: missingNodePath });
    assert.notEqual(missingNodeResult.code, 0, "a nonexistent MCP_SIDING_NODE must fail closed, not exit 0");
    assert.ok(
      !missingNodeResult.out.includes('"id":60'),
      "a nonexistent MCP_SIDING_NODE must not fall through to the real node still on PATH",
    );
    assert.match(missingNodeResult.err, /MCP_SIDING_NODE/, "the diagnostic must name the override");
    assert.ok(missingNodeResult.err.includes(missingNodePath), "the diagnostic must name the missing path itself");

    // A real executable that fails the capability probe (always exits 1,
    // so it never has global fetch/ReadableStream - same stub shape as
    // N24's) must also fail closed, naming the missing capability rather
    // than silently falling through to PATH's perfectly good node.
    const capabilityFailNodePath = join(n31Home, "too-old-node");
    await writeFile(capabilityFailNodePath, "#!/bin/sh\nexit 1\n");
    await chmod(capabilityFailNodePath, 0o755);
    const capabilityFailNodeResult = await runShimScript({ ...baseEnv, MCP_SIDING_NODE: capabilityFailNodePath });
    assert.notEqual(capabilityFailNodeResult.code, 0, "an MCP_SIDING_NODE failing the capability probe must fail closed");
    assert.ok(
      !capabilityFailNodeResult.out.includes('"id":60'),
      "an MCP_SIDING_NODE failing the capability probe must not fall through to the real node still on PATH",
    );
    assert.match(
      capabilityFailNodeResult.err,
      /fetch|ReadableStream/i,
      "the diagnostic must name the missing capability, not just 'unusable'",
    );
  } finally {
    await rm(n31Home, { recursive: true, force: true });
  }

  // -- node absent from PATH but present at a known fallback location -
  //    asdf's default shim path, HOME-relative and so fully controllable
  //    in a test, unlike the Homebrew/system absolute paths below. -----
  const fakeHome = await mkdtemp(join(tmpdir(), "mcp-siding-node-"));
  const asdfShimDir = join(fakeHome, ".asdf", "shims");
  await mkdir(asdfShimDir, { recursive: true });
  const asdfNodePath = join(asdfShimDir, "node");
  await stageNodeWrapper(asdfNodePath);
  try {
    const fallbackResult = await runShimScript({ ...baseEnv, PATH: brokenPath, HOME: fakeHome, MCP_SIDING_NODE: "" });
    assert.ok(!fallbackResult.timedOut, `asdf-fallback script hung (stderr: ${fallbackResult.err})`);
    assert.ok(
      fallbackResult.out.includes('"id":60'),
      `script did not start with node absent from PATH but present at the asdf fallback (stderr: ${fallbackResult.err})`,
    );
  } finally {
    await rm(fakeHome, { recursive: true, force: true });
  }

  // -- positive control for the fallback rewrite itself: place a real,
  //    usable node at the REWRITTEN "/opt/homebrew/bin/node" slot (PATH
  //    broken, HOME empty so nothing else could resolve it) and confirm
  //    it is still found - proves rewriteHardcodedNodeFallbacks produces
  //    a script that behaves like the real one for these paths, before
  //    trusting it for the negative cases right below. -------------------
  const fallbackRewriteHome = await mkdtemp(join(tmpdir(), "mcp-siding-fallback-rewrite-"));
  try {
    const rewrittenDir = join(fallbackRewriteHome, "fallbacks");
    await mkdir(rewrittenDir, { recursive: true });
    await stageNodeWrapper(join(rewrittenDir, "opt-homebrew-node"));
    const positiveControl = await runShimScript(
      { ...baseEnv, PATH: brokenPath, HOME: fallbackRewriteHome, MCP_SIDING_NODE: "" },
      5_000,
      rewrittenDir,
    );
    assert.ok(!positiveControl.timedOut, `fallback-rewrite positive control hung (stderr: ${positiveControl.err})`);
    assert.ok(
      positiveControl.out.includes('"id":60'),
      `a real node at the rewritten /opt/homebrew/bin/node slot must still resolve (stderr: ${positiveControl.err})`,
    );
  } finally {
    await rm(fallbackRewriteHome, { recursive: true, force: true });
  }

  // -- none available anywhere: exits non-zero with a diagnostic rather
  //    than hanging. Constructed on any machine via the fallback rewrite
  //    above (a fresh, guaranteed-empty temp dir), not conditional on
  //    whether this host happens to have a real node at
  //    /opt/homebrew/bin/node or the other hardcoded absolute paths. ----
  const emptyHome = await mkdtemp(join(tmpdir(), "mcp-siding-nonode-"));
  try {
    const emptyFallbackDir = join(emptyHome, "empty-fallbacks");
    await mkdir(emptyFallbackDir, { recursive: true });
    const noneResult = await runShimScript(
      { ...baseEnv, PATH: brokenPath, HOME: emptyHome, MCP_SIDING_NODE: "" },
      3_000,
      emptyFallbackDir,
    );
    assert.ok(!noneResult.timedOut, "a subprocess with no node resolvable anywhere must exit, not hang");
    assert.notEqual(noneResult.code, 0, "must exit non-zero when no node resolves anywhere");
    assert.match(noneResult.err, /no node with global fetch/i, "must name what was tried in the diagnostic");
  } finally {
    await rm(emptyHome, { recursive: true, force: true });
  }

  // -- N24: existence is not enough - a node old enough to lack global
  //    fetch/ReadableStream must be REJECTED, not accepted just because it
  //    exists and is executable (Node 16 starts the server fine and then
  //    throws ReferenceError: fetch is not defined on the first real
  //    request, which reads as Down - silent empty tool listings and a
  //    launch of an already-running app). A stub `node` that always exits
  //    nonzero (simulating the probe failing on an old runtime, whatever
  //    it was actually asked to do) stands in for "found but too old". ---
  const stubNodeHome = await mkdtemp(join(tmpdir(), "mcp-siding-stub-node-"));
  try {
    const stubNodeDir = join(stubNodeHome, "stub-bin");
    await mkdir(stubNodeDir, { recursive: true });
    const stubNodePath = join(stubNodeDir, "node");
    await writeFile(stubNodePath, "#!/bin/sh\nexit 1\n");
    await chmod(stubNodePath, 0o755);

    // -- the stub on PATH, a real node reachable at the asdf fallback: the
    //    stub must be rejected and the next candidate tried, not accepted
    //    just because command -v found something named "node". ----------
    const realFallbackDir = join(stubNodeHome, ".asdf", "shims");
    await mkdir(realFallbackDir, { recursive: true });
    const realFallbackPath = join(realFallbackDir, "node");
    await stageNodeWrapper(realFallbackPath);
    const rejectThenFallback = await runShimScript({
      ...baseEnv,
      PATH: stubNodeDir,
      HOME: stubNodeHome,
      MCP_SIDING_NODE: "",
    });
    assert.ok(!rejectThenFallback.timedOut, `reject-then-fallback script hung (stderr: ${rejectThenFallback.err})`);
    assert.ok(
      rejectThenFallback.out.includes('"id":60'),
      `script did not fall through to a real node after rejecting the stub (stderr: ${rejectThenFallback.err})`,
    );

    // -- only the stub anywhere: must exit non-zero naming the
    //    requirement, not silently start a server doomed to fail on its
    //    first real request. A bare HOME (no asdf fallback populated) and
    //    the hardcoded absolute fallbacks rewritten to an empty temp dir
    //    (same technique as "none available anywhere" above) so the only
    //    candidate PATH or the fixed locations can find is the stub -
    //    constructed on any machine, not conditional on this host lacking
    //    a real node at one of those paths. -----------------------------
    const bareHome = await mkdtemp(join(tmpdir(), "mcp-siding-stub-bare-"));
    try {
      const bareFallbackDir = join(bareHome, "empty-fallbacks");
      await mkdir(bareFallbackDir, { recursive: true });
      const bareResult = await runShimScript(
        { ...baseEnv, PATH: stubNodeDir, HOME: bareHome, MCP_SIDING_NODE: "" },
        3_000,
        bareFallbackDir,
      );
      assert.ok(!bareResult.timedOut, "a subprocess with only a too-old node anywhere must exit, not hang");
      assert.notEqual(bareResult.code, 0, "must exit non-zero when only a too-old node is found");
      assert.match(bareResult.err, /fetch|ReadableStream/i, "the diagnostic must name the requirement that was rejected");
      assert.match(bareResult.err, /rejected/i, "the diagnostic must name what was rejected");
    } finally {
      await rm(bareHome, { recursive: true, force: true });
    }
  } finally {
    await rm(stubNodeHome, { recursive: true, force: true });
  }
}

// N32: extracts the ACTUAL bash snippet documented in SKILL.md's "Install
// a server" section (marked with HTML comments, not a reimplementation of
// it) and runs it for real via /bin/sh, so a future edit that lets the doc
// drift from NODE_RESOLVER_SH's own candidate list fails this test rather
// than surfacing only as an install that silently uses a different node
// than the spawned server will. SKILL_DIR is set the same way the skill
// itself instructs an agent to set it - the real directory containing
// SKILL.md, so "$SKILL_DIR/../../scripts/mcp-siding.mjs" resolves to the
// real mcp-siding.mjs.
async function selftestInstallNodeResolverSnippet() {
  const skillMdPath = join(dirname(MCP_SIDING_PATH), "..", "skills", "mcp-shim", "SKILL.md");
  const skillMd = await readFile(skillMdPath, "utf8");
  const match = skillMd.match(
    /<!-- mcp-siding-selftest: node-resolver-install-snippet:start -->\n```bash\n([\s\S]*?)\n```\n<!-- mcp-siding-selftest: node-resolver-install-snippet:end -->/,
  );
  assert.ok(match, `SKILL.md's node-resolver install snippet marker not found at ${skillMdPath} - did the doc structure change?`);
  const snippet = match[1]
    // Not port 1 - see runShimScript's identical comment (N47).
    .replaceAll("<URL>", "http://127.0.0.1:65533/mcp")
    .replaceAll("<NAME>", "test")
    .replaceAll('"<APP_PATH>"', '""');

  const skillDir = join(dirname(MCP_SIDING_PATH), "..", "skills", "mcp-shim");
  const realNode = process.execPath;
  const brokenPath = "/definitely/not/a/real/path";
  const baseEnv = { ...process.env, SKILL_DIR: skillDir, PATH: brokenPath, MCP_SIDING_NODE: "" };

  // -- node absent from PATH but present at a documented fallback (asdf's
  //    default shim, HOME-relative and so fully controllable in a test) -
  //    the documented install command must still produce a valid script. --
  const fakeHome = await mkdtemp(join(tmpdir(), "mcp-siding-install-node-"));
  try {
    const asdfShimDir = join(fakeHome, ".asdf", "shims");
    await mkdir(asdfShimDir, { recursive: true });
    const asdfNodePath = join(asdfShimDir, "node");
    await stageNodeWrapper(asdfNodePath);
    const withFallback = spawnSync("/bin/sh", ["-c", `${snippet}\nprintf '%s' "$SCRIPT"`], {
      env: { ...baseEnv, HOME: fakeHome },
      encoding: "utf8",
    });
    assert.equal(withFallback.status, 0, `install snippet failed with a usable fallback node (stderr: ${withFallback.stderr})`);
    assert.match(withFallback.stdout, /exec "\$node_bin"/, "the documented install command must still produce a valid registration script");
  } finally {
    await rm(fakeHome, { recursive: true, force: true });
  }

  // -- N34: the install snippet must apply N31's exact rule too - a
  //    nonempty $MCP_SIDING_NODE that is unusable exits non-zero before
  //    any registration happens, distinguishing missing/non-executable
  //    from capability-failing; unset/usable are unchanged. --------------

  // set to a usable node -> wins, unchanged (PATH broken, so this proves
  // the override itself resolves, not a PATH fallback).
  const usableOverride = spawnSync("/bin/sh", ["-c", `${snippet}\nprintf '%s' "$SCRIPT"`], {
    env: { ...baseEnv, MCP_SIDING_NODE: realNode },
    encoding: "utf8",
  });
  assert.equal(usableOverride.status, 0, `install snippet failed with a usable $MCP_SIDING_NODE override (stderr: ${usableOverride.stderr})`);
  assert.match(usableOverride.stdout, /exec "\$node_bin"/, "a usable $MCP_SIDING_NODE override must still produce a valid registration script");

  // set to a nonexistent path while a perfectly good node exists on PATH -
  // must fail closed, not fall through to that usable alternative (the
  // usable alternative is what makes this assertion meaningful, same
  // reasoning as N29/N31's own tests).
  const missingOverridePath = "/definitely/not/a/real/node/binary";
  const missingOverride = spawnSync("/bin/sh", ["-c", snippet], {
    env: { ...process.env, SKILL_DIR: skillDir, MCP_SIDING_NODE: missingOverridePath }, // real PATH left intact
    encoding: "utf8",
  });
  assert.notEqual(missingOverride.status, 0, "the install snippet must fail closed on a nonexistent $MCP_SIDING_NODE, not exit 0");
  assert.match(missingOverride.stderr, /MCP_SIDING_NODE/, "the diagnostic must name the override");
  assert.ok(missingOverride.stderr.includes(missingOverridePath), "the diagnostic must name the missing path itself");

  // set to a real executable that fails the capability probe - must fail
  // closed naming the missing capability, not silently fall through.
  const stubNodeHome = await mkdtemp(join(tmpdir(), "mcp-siding-install-stub-node-"));
  try {
    const stubNodePath = join(stubNodeHome, "too-old-node");
    await writeFile(stubNodePath, "#!/bin/sh\nexit 1\n");
    await chmod(stubNodePath, 0o755);
    const capabilityFailOverride = spawnSync("/bin/sh", ["-c", snippet], {
      env: { ...process.env, SKILL_DIR: skillDir, MCP_SIDING_NODE: stubNodePath }, // real PATH left intact
      encoding: "utf8",
    });
    assert.notEqual(capabilityFailOverride.status, 0, "the install snippet must fail closed on a capability-failing $MCP_SIDING_NODE");
    assert.match(
      capabilityFailOverride.stderr,
      /fetch|ReadableStream/i,
      "the diagnostic must name the missing capability, not just 'unusable'",
    );
  } finally {
    await rm(stubNodeHome, { recursive: true, force: true });
  }

  // -- no usable runtime anywhere: must fail with the same CLASS of
  //    diagnostic as the runtime resolver (naming fetch/ReadableStream),
  //    not a bare "command not found". Constructed via the same fallback
  //    rewrite runShimScript uses (rewriteHardcodedNodeFallbacks) applied
  //    to this snippet's own text, so it runs on any machine rather than
  //    being conditional on this host lacking a real node at one of the
  //    hardcoded absolute paths. A positive control first (a real node
  //    placed at the rewritten /opt/homebrew/bin/node slot must still
  //    resolve) proves the rewrite is faithful before trusting it for the
  //    negative case right after. -------------------------------------
  const fallbackRewriteHome = await mkdtemp(join(tmpdir(), "mcp-siding-install-fallback-rewrite-"));
  try {
    const rewrittenDir = join(fallbackRewriteHome, "fallbacks");
    await mkdir(rewrittenDir, { recursive: true });
    await stageNodeWrapper(join(rewrittenDir, "opt-homebrew-node"));
    const rewrittenSnippet = rewriteHardcodedNodeFallbacks(snippet, rewrittenDir);
    const positiveControl = spawnSync("/bin/sh", ["-c", `${rewrittenSnippet}\nprintf '%s' "$SCRIPT"`], {
      env: { ...baseEnv, HOME: fallbackRewriteHome },
      encoding: "utf8",
    });
    assert.equal(
      positiveControl.status,
      0,
      `a real node at the rewritten /opt/homebrew/bin/node slot must still resolve (stderr: ${positiveControl.stderr})`,
    );
    assert.match(positiveControl.stdout, /exec "\$node_bin"/, "the fallback-rewritten install snippet must still produce a valid script");
  } finally {
    await rm(fallbackRewriteHome, { recursive: true, force: true });
  }

  const emptyHome = await mkdtemp(join(tmpdir(), "mcp-siding-install-nonode-"));
  try {
    const emptyFallbackDir = join(emptyHome, "empty-fallbacks");
    await mkdir(emptyFallbackDir, { recursive: true });
    const noneResult = spawnSync("/bin/sh", ["-c", rewriteHardcodedNodeFallbacks(snippet, emptyFallbackDir)], {
      env: { ...baseEnv, HOME: emptyHome },
      encoding: "utf8",
    });
    assert.notEqual(noneResult.status, 0, "the install snippet must fail closed when no node resolves anywhere");
    assert.match(
      noneResult.stderr,
      /no node with global fetch\/ReadableStream/i,
      "the install snippet must fail with the same class of diagnostic as the runtime resolver, not a bare 'command not found'",
    );
  } finally {
    await rm(emptyHome, { recursive: true, force: true });
  }
}

// N42: SKILL.md's install section must refuse before ever running
// `mcp add` on a native-Windows host (no POSIX shell, so the `/bin/sh -c
// "$SCRIPT"` registration could never spawn) - extracts and runs the
// ACTUAL documented preflight snippet (marked in SKILL.md), the same
// extraction technique selftestInstallNodeResolverSnippet already uses,
// so a drift between the doc and this test fails loudly rather than
// silently. The snippet's only input is `uname -s` - a stub on PATH
// controls that honestly (the real technique this file already uses for
// "no node"/"too-old node"), rather than pretending to actually run on a
// different OS.
async function selftestWindowsPreflightSnippet() {
  const skillMdPath = join(dirname(MCP_SIDING_PATH), "..", "skills", "mcp-shim", "SKILL.md");
  const skillMd = await readFile(skillMdPath, "utf8");
  const match = skillMd.match(
    /<!-- mcp-siding-selftest: windows-preflight-snippet:start -->\n```bash\n([\s\S]*?)\n```\n<!-- mcp-siding-selftest: windows-preflight-snippet:end -->/,
  );
  assert.ok(match, `SKILL.md's Windows preflight snippet marker not found at ${skillMdPath} - did the doc structure change?`);
  const snippet = match[1];

  // This host's own real `uname -s` (macOS or Linux, wherever this
  // selftest runs) must pass - the guard must never reject a genuinely
  // supported platform.
  const realHostResult = spawnSync("/bin/sh", ["-c", `${snippet}\necho PASSED`], { encoding: "utf8" });
  assert.equal(realHostResult.status, 0, `the preflight snippet rejected this test host's own real platform (stderr: ${realHostResult.stderr})`);
  assert.match(realHostResult.stdout, /PASSED/, "the preflight snippet must let a supported host continue past the guard");

  const stubUnameHome = await mkdtemp(join(tmpdir(), "mcp-siding-preflight-uname-"));
  try {
    const stubBinDir = join(stubUnameHome, "bin");
    await mkdir(stubBinDir, { recursive: true });
    const stubUnamePath = join(stubBinDir, "uname");

    // WSL is a real Linux kernel - `uname -s` reports Linux there, and it
    // is the documented supported route onto Windows. Must still pass.
    await writeFile(stubUnamePath, '#!/bin/sh\nprintf "%s\\n" Linux\n');
    await chmod(stubUnamePath, 0o755);
    const wslResult = spawnSync("/bin/sh", ["-c", `${snippet}\necho PASSED`], {
      env: { ...process.env, PATH: `${stubBinDir}:${process.env.PATH}` },
      encoding: "utf8",
    });
    assert.equal(wslResult.status, 0, `the preflight snippet rejected a WSL-reported (Linux) uname (stderr: ${wslResult.stderr})`);
    assert.match(wslResult.stdout, /PASSED/, "WSL (uname -s reporting Linux) must pass the preflight guard - it is the documented supported route");

    // Native Windows via Git-Bash/MSYS reports something like
    // "MINGW64_NT-10.0-19045" - neither Darwin nor Linux. Must refuse
    // before any registration is attempted, naming WSL as the way out.
    await writeFile(stubUnamePath, '#!/bin/sh\nprintf "%s\\n" MINGW64_NT-10.0-19045\n');
    await chmod(stubUnamePath, 0o755);
    const nativeWindowsResult = spawnSync("/bin/sh", ["-c", snippet], {
      env: { ...process.env, PATH: `${stubBinDir}:${process.env.PATH}` },
      encoding: "utf8",
    });
    assert.notEqual(nativeWindowsResult.status, 0, "the preflight snippet must refuse on a native-Windows-reported uname, not exit 0");
    assert.match(
      nativeWindowsResult.stderr,
      /POSIX shell/i,
      "the diagnostic must say the shim needs a POSIX shell",
    );
    assert.match(nativeWindowsResult.stderr, /WSL/, "the diagnostic must name WSL as a supported route");
    // #16: native Windows is supported now, by a different installer - the
    // guard must send the caller THERE, not tell them it cannot be done.
    // Without this the message could quietly rot back into a refusal while
    // a working PowerShell route sits unused two sections below it.
    assert.match(
      nativeWindowsResult.stderr,
      /PowerShell install route/,
      "the diagnostic must point at the native-Windows PowerShell route, not refuse Windows outright",
    );
  } finally {
    await rm(stubUnameHome, { recursive: true, force: true });
  }
}

// #16: the PowerShell registration path, checked for everything that does
// not need a PowerShell interpreter to check. The behavioural half - does
// the resolver pick the newest version, does an override fail closed, does
// the probe reject an old runtime, does the generated text parse - lives in
// mcp-siding-windows.ps1's own -SelfTest, where PowerShell is guaranteed.
// The halves are complementary on purpose: neither one is a weaker copy of
// the other, and this one runs on every host.
async function selftestWindowsRegistration() {
  const ps1Path = join(dirname(MCP_SIDING_PATH), "mcp-siding-windows.ps1");
  const ps1Text = await readFile(ps1Path, "utf8");
  const region = extractWindowsResolver(ps1Text);

  // The region must be self-sufficient: a registration is exactly this
  // text plus one Invoke-McpSidingShim call, so every function that call
  // reaches has to be defined inside it.
  for (const required of [
    "Invoke-McpSidingShim",
    "Resolve-McpSidingScript",
    "Resolve-McpSidingNode",
    "Get-McpSidingCacheRoots",
    "Get-McpSidingNodeCandidates",
    "Test-McpSidingNodeCapability",
    "Compare-McpSidingVersion",
    "ConvertTo-McpSidingArgumentString",
    "Test-McpSidingFile",
  ]) {
    assert.match(region, new RegExp(`^function ${required} \\{$`, "m"), `the marked region must define ${required} - a registration carries nothing else`);
  }
  // ...and must NOT drag the self-test along: that text ships inside every
  // registration on every Windows host, so a leak here is real weight and
  // a real surface, not a tidiness point.
  assert.doesNotMatch(region, /Invoke-McpSidingSelfTest|Assert-McpSidingTest/, "the self-test must stay outside the marked region");
  // Both harness caches, scanned in the same pass - the exact regression
  // the POSIX resolver's comment records (a Codex-updated roundhouse
  // losing to a stale Claude copy).
  assert.match(region, /'\.claude'/, "the resolver must scan the Claude plugin cache");
  assert.match(region, /'\.codex'/, "the resolver must scan the Codex plugin cache");

  // -- generation: the registration body is the region plus one call -----
  const hostileName = `it's a "weird" name`;
  const generated = buildShimScriptPowerShell(
    {
      "backend-url": "http://127.0.0.1:27182/mcp",
      name: hostileName,
      app: "C:\\Program Files\\Autodesk Fusion.app",
      timeout: "5000",
      "no-launch": true,
    },
    region,
  );
  assert.ok(generated.startsWith(region), "the generated registration must start with the resolver region verbatim");
  const invokeLine = generated.trim().split("\n").at(-1);
  assert.equal(
    invokeLine,
    "Invoke-McpSidingShim -ShimArgs @('--backend-url', 'http://127.0.0.1:27182/mcp', '--name', 'it''s a \"weird\" name', " +
      "'--app', 'C:\\Program Files\\Autodesk Fusion.app', '--timeout', '5000', '--no-launch')",
    "every flag must be forwarded, PowerShell-quoted, with the single-quote doubling that makes a hostile value literal",
  );

  // psQuote's whole contract in one place: ' doubles, and nothing else is
  // special inside a PowerShell single-quoted string (notably $ and \,
  // which is why an interpolating "..." would be wrong here).
  assert.equal(psQuote("plain"), "'plain'");
  assert.equal(psQuote("it's"), "'it''s'");
  assert.equal(psQuote('$env:PATH; rm -rf /'), "'$env:PATH; rm -rf /'");
  assert.equal(psQuote("C:\\x\\"), "'C:\\x\\'");

  // -- both builders must agree on WHICH flags a registration carries ----
  // Only the quoting may differ; a flag appearing in one flavour and not
  // the other would be a silently different server on one platform.
  const sameFlags = { "backend-url": "http://127.0.0.1:3845/mcp", name: "figma", app: "/Applications/Figma.app", launch: false };
  const flagNames = (line) => [...line.matchAll(/'(--[a-z-]+)'/g)].map((match) => match[1]);
  const posixFlags = flagNames(buildShimScript(sameFlags).trim().split("\n").at(-1));
  assert.deepEqual(posixFlags, ["--backend-url", "--name", "--app", "--no-launch"], "the POSIX registration's flag set is the reference");
  assert.deepEqual(
    flagNames(buildShimScriptPowerShell(sameFlags, region).trim().split("\n").at(-1)),
    posixFlags,
    "the POSIX and PowerShell registrations must carry the same flags, in the same order",
  );

  // -- a missing/renamed marker region must fail loudly, not emit a
  //    registration whose resolver is silently absent ---------------------
  assert.throws(
    () => extractWindowsResolver("# nothing marked here\n"),
    /windows-resolver marker region was not found/,
    "generation must fail closed when the .ps1's markers are gone",
  );

  // -- --platform is validated at parse time, both spellings, so a typo
  //    cannot quietly produce the POSIX flavour on a Windows host --------
  assert.throws(() => parseArgs(["--platform", "win"]), /invalid value for --platform: win/, "an unknown --platform must be rejected");
  assert.throws(() => parseArgs(["--platform=Windows"]), /invalid value for --platform: Windows/, "--platform is case-sensitive and must reject a near-miss");
  assert.equal(parseArgs(["--platform", "windows"]).platform, "windows");
  assert.equal(parseArgs(["--platform=posix"]).platform, "posix");

  // -- the real CLI must actually emit PowerShell for --platform windows,
  //    not just the builder in-process ------------------------------------
  const printed = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--print-shim-script", "--platform", "windows", "--backend-url", "http://127.0.0.1:27182/mcp", "--name", "fusion"],
    { encoding: "utf8" },
  );
  assert.equal(printed.status, 0, `--print-shim-script --platform windows failed: ${printed.stderr}`);
  assert.ok(printed.stdout.includes("function Invoke-McpSidingShim {"), "the CLI must emit the PowerShell resolver for --platform windows");
  assert.ok(printed.stdout.trim().endsWith("Invoke-McpSidingShim -ShimArgs @('--backend-url', 'http://127.0.0.1:27182/mcp', '--name', 'fusion')"));
  const printedPosix = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--print-shim-script", "--backend-url", "http://127.0.0.1:27182/mcp", "--name", "fusion"],
    { encoding: "utf8" },
  );
  assert.equal(printedPosix.status, 0, `the default (POSIX) registration must still generate: ${printedPosix.stderr}`);
  assert.ok(printedPosix.stdout.includes('exec "$node_bin" "$p"'), "omitting --platform must still emit the POSIX registration unchanged");

  // -- SKILL.md must actually document this route, and document it as
  //    supported - a resolver nothing tells the installer to use is not
  //    Windows support. -----------------------------------------------
  const skillMd = await readFile(join(dirname(MCP_SIDING_PATH), "..", "skills", "mcp-shim", "SKILL.md"), "utf8");
  assert.ok(skillMd.includes("--platform windows"), "SKILL.md must tell the installer to generate the Windows registration");
  assert.ok(skillMd.includes("-EncodedCommand"), "SKILL.md must register the PowerShell body as an encoded command, not as hand-quoted text");
  assert.ok(skillMd.includes("mcp-siding-windows.ps1"), "SKILL.md must name the file the Windows logic lives in, for diagnosis");
}

// #15: end-to-end proof that a server notification emitted mid-call
// reaches the stdio client, in order, without corrupting framing. Runs the
// REAL script as a child process against a real HTTP backend, so the whole
// path is exercised: SSE read loop -> forwardNotification -> emit ->
// stdout, concurrently with an in-flight tools/call whose response goes
// through that same stdout. An in-process Shim with an injected callback
// (1f) cannot show this - it never writes a byte to a real stream.
//
// The backend also emits one event that is NOT a JSON-RPC message, mixed in
// with the real ones: a relayed non-message would be an unrecoverable
// protocol violation at the client, so "dropped, and the response still
// arrives" is asserted here too, over a real socket rather than a fake
// stream.
async function selftestNotificationForwardingEndToEnd() {
  const progress = { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: "t1", progress: 1, total: 2 } };
  const logNote = { jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: "halfway" } };
  const cacheDir = await mkdtemp(join(tmpdir(), "mcp-siding-notify-"));
  try {
    await withServer(
      (req, res) => {
        readJsonBody(req).then((msg) => {
          if (msg.method === "initialize") {
            return sendJson(
              res,
              200,
              {
                jsonrpc: "2.0",
                id: msg.id,
                result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } },
              },
              { "MCP-Session-Id": "notify-session" },
            );
          }
          if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
          if (msg.method === "tools/call") {
            res.writeHead(200, { "Content-Type": "text/event-stream" });
            res.write(`data: ${JSON.stringify(progress)}\n\n`);
            res.write(`data: ${JSON.stringify(logNote)}\n\n`);
            res.write(`data: ${JSON.stringify({ keepalive: true })}\n\n`);
            res.write(
              `data: ${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: "done" }] } })}\n\n`,
            );
            res.end();
            return;
          }
          sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
        });
      },
      async (url) => {
        const child = spawn(
          process.execPath,
          [MCP_SIDING_PATH, "--backend-url", url, "--name", "test", "--cache", join(cacheDir, "tools.json"), "--no-launch"],
          { stdio: ["pipe", "pipe", "pipe"] },
        );
        let out = "";
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (chunk) => (out += chunk));
        let err = "";
        child.stderr.setEncoding("utf8");
        child.stderr.on("data", (chunk) => (err += chunk));
        const exited = new Promise((resolve) => child.on("exit", resolve));

        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })}\n`);
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "slow" } })}\n`);

        const deadline = Date.now() + 10_000;
        while (!out.includes('"id":2') && Date.now() < deadline) {
          await new Promise((r) => setTimeout(r, 25));
        }
        child.stdin.end();
        await Promise.race([exited, new Promise((r) => setTimeout(r, 2_000))]);
        if (child.exitCode == null) child.kill();

        assert.ok(out.includes('"id":2'), `child never answered the tools/call (stderr: ${err})`);
        // Every line must be a complete JSON object on its own - the
        // framing guarantee. A forward written into the middle of a
        // response's line would fail right here, before any ordering
        // assertion gets a chance to look reasonable.
        const lines = out.split("\n").filter((line) => line !== "");
        const messages = lines.map((line, index) => {
          try {
            return JSON.parse(line);
          } catch (parseError) {
            throw new assert.AssertionError({
              message: `stdout line ${index} is not one complete JSON object (${parseError.message}): ${JSON.stringify(line)}`,
            });
          }
        });
        assert.deepEqual(
          messages,
          [
            { jsonrpc: "2.0", id: 1, result: { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: { listChanged: true } }, serverInfo: { name: "test", version: "1.0.0" } } },
            progress,
            logNote,
            { jsonrpc: "2.0", id: 2, result: { content: [{ type: "text", text: "done" }] } },
          ],
          `the client must see both notifications, verbatim, BEFORE the response they belong to, and nothing else (stderr: ${err})`,
        );
      },
    );
  } finally {
    await rm(cacheDir, { recursive: true, force: true });
  }
}

// N30: buildShimFromArgs throwing (asserted directly, unit-level, above)
// only proves the validation rule exists - this proves main() actually
// wires it into "process exits non-zero, and the stdio server never
// opens at all," by spawning the real script with an invalid
// --backend-url, writing a real initialize message regardless, and
// confirming it never gets a reply.
async function selftestInvalidBackendUrlExitsBeforeStdio() {
  const child = spawn(
    process.execPath,
    [MCP_SIDING_PATH, "--backend-url", "127.0.0.1:27182/mcp", "--name", "test"],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => (out += chunk));
  let err = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => (err += chunk));
  const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

  // Sent regardless of whether the process is even listening yet - if the
  // stdio server had opened, this would get a reply. This IS the fail-
  // closed case an invalid --backend-url is supposed to trigger - main()
  // exits via parseArgs/buildShimFromArgs before ever opening readline -
  // so the write below can legitimately hit an already-closed pipe. An
  // unhandled 'error' there would kill the whole selftest process (see
  // runShimScript's identical guard, added for the same reason); the
  // actual assertions below already check that the child exited non-zero
  // with the right diagnostic and never replied, which is the real signal
  // regardless of whether this write nominally landed.
  child.stdin.on("error", () => {});
  try {
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 61, method: "initialize", params: {} })}\n`);
  } catch {
    // Same as the 'error' handler above.
  }

  const exitCode = await Promise.race([exited, new Promise((r) => setTimeout(() => r("timeout"), 5_000))]);
  assert.notEqual(exitCode, "timeout", `child never exited on an invalid --backend-url (stderr: ${err})`);
  assert.notEqual(exitCode, 0, "an invalid --backend-url must exit non-zero");
  assert.match(err, /--backend-url must be a valid URL/, "the diagnostic must name the problem");
  assert.equal(out, "", "no reply may have been sent - the stdio server must never have opened");
  if (child.exitCode == null) child.kill();
}

// N44: an unrecognized flag used to be silently stored by parseArgs and
// then just never read by anything - a misspelling like --no-launh=true
// was accepted, dropped from the generated script (never forwarded) and
// never applied to a real launch, and with --app present, launch-on-
// demand ended up ENABLED, the opposite of what was asked. Proves BOTH
// CLI paths reject it, since run() calls parseArgs exactly once before
// branching to either (same reasoning as N35's own comment above).
function selftestUnknownFlagRejectedOnBothPaths() {
  const realLaunch = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--backend-url", "http://127.0.0.1:27182/mcp", "--name", "test", "--no-launh", "true"],
    { encoding: "utf8" },
  );
  assert.notEqual(realLaunch.status, 0, "a real launch with an unknown flag must exit non-zero, before the stdio server opens");
  assert.match(realLaunch.stderr, /unknown flag: --no-launh/, "the diagnostic must name the offending flag");

  const printShimScript = spawnSync(
    process.execPath,
    [
      MCP_SIDING_PATH,
      "--print-shim-script",
      "--backend-url",
      "http://127.0.0.1:27182/mcp",
      "--name",
      "test",
      "--app",
      "/A.app",
      "--no-launh",
      "true",
    ],
    { encoding: "utf8" },
  );
  assert.notEqual(printShimScript.status, 0, "--print-shim-script with an unknown flag must exit non-zero, not generate a script");
  assert.match(printShimScript.stderr, /unknown flag: --no-launh/, "the diagnostic must name the offending flag here too");
  assert.equal(printShimScript.stdout, "", "no script may be printed when a flag is unrecognized");
}

// N47: a fetch-forbidden port (127.0.0.1:1, say) is a syntactically valid
// http(s) URL, so it used to pass every startup check, open the stdio
// server, and only fail on the first real request - where undici's
// client-side block carries no recognized error code and post()'s catch
// fell through to Indeterminate ("the operation may have run"), when
// nothing was ever transmitted. Must be rejected before the stdio server
// ever opens, same as any other invalid --backend-url (N30).
function selftestForbiddenPortRejectedAtLaunch() {
  const result = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--backend-url", "http://127.0.0.1:1/mcp", "--name", "test"],
    { encoding: "utf8" },
  );
  assert.notEqual(result.status, 0, "a real launch on a fetch-forbidden port must exit non-zero, before the stdio server opens");
  assert.match(result.stderr, /port 1\b/, "the diagnostic must name the offending port");
}

// N35: --print-shim-script used to check only that --backend-url and --name
// were present, then hand flags straight to buildShimScript - so a
// malformed URL or a bad --timeout/--launch-grace generated a script
// happily, `mcp add` registered it, and only the SPAWNED server (running
// buildShimFromArgs for real) ever rejected it, leaving a broken
// registration behind. This proves the CLI's --print-shim-script path now
// runs buildShimFromArgs first and fails with the exact same diagnostic a
// real launch would, before printing anything - and that valid input is
// unaffected.
function selftestPrintShimScriptValidatesLikeBuildShimFromArgs() {
  const badUrl = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--print-shim-script", "--backend-url", "not a url at all", "--name", "test"],
    { encoding: "utf8" },
  );
  assert.notEqual(badUrl.status, 0, "--print-shim-script must exit non-zero on a malformed --backend-url");
  assert.match(
    badUrl.stderr,
    /--backend-url must be a valid URL/,
    "must fail with buildShimFromArgs's own diagnostic, not a generic one",
  );
  assert.equal(badUrl.stdout, "", "no script may be printed for input the runtime would reject");

  const badScheme = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--print-shim-script", "--backend-url", "ftp://127.0.0.1:27182/mcp", "--name", "test"],
    { encoding: "utf8" },
  );
  assert.notEqual(badScheme.status, 0, "--print-shim-script must exit non-zero on a non-http(s) --backend-url");
  assert.match(badScheme.stderr, /must use http: or https:/, "must name the protocol problem, same as buildShimFromArgs");
  assert.equal(badScheme.stdout, "", "no script may be printed for a rejected protocol");

  const badTimeout = spawnSync(
    process.execPath,
    [
      MCP_SIDING_PATH,
      "--print-shim-script",
      "--backend-url",
      "http://127.0.0.1:27182/mcp",
      "--name",
      "test",
      "--timeout",
      "notanumber",
    ],
    { encoding: "utf8" },
  );
  assert.notEqual(badTimeout.status, 0, "--print-shim-script must exit non-zero on a non-numeric --timeout");
  assert.match(badTimeout.stderr, /timeout/i, "must name the flag that failed");
  assert.equal(badTimeout.stdout, "", "no script may be printed for a rejected --timeout");

  // N47: a fetch-forbidden port must be rejected here too, not just at a
  // real launch - same reasoning as every other validation case in this
  // function (this is the whole point of N35's fix: generation and
  // launch must reject exactly the same inputs).
  const badPort = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--print-shim-script", "--backend-url", "http://127.0.0.1:1/mcp", "--name", "test"],
    { encoding: "utf8" },
  );
  assert.notEqual(badPort.status, 0, "--print-shim-script must exit non-zero on a fetch-forbidden --backend-url port");
  assert.match(badPort.stderr, /port 1\b/, "must name the offending port");
  assert.equal(badPort.stdout, "", "no script may be printed for a forbidden port");

  // Valid input must still work exactly as before.
  const valid = spawnSync(
    process.execPath,
    [MCP_SIDING_PATH, "--print-shim-script", "--backend-url", "http://127.0.0.1:27182/mcp", "--name", "test"],
    { encoding: "utf8" },
  );
  assert.equal(valid.status, 0, `valid --print-shim-script input must still succeed (stderr: ${valid.stderr})`);
  assert.match(valid.stdout, /exec "\$node_bin"/, "valid input must still print a real registration script");
}

// N13: `open -a <bad path>` on macOS spawns fine and exits nonzero - unlike
// selftestLauncherErrorDoesNotCrash, PATH is left intact so `open` itself
// resolves and actually runs, reproducing that shape rather than a spawn()
// ENOENT. Two tools/call requests through the REAL defaultLauncher (not the
// injected seam, which never touches the real 'exit' event): the first
// triggers the launch attempt, and once its failure has had time to land,
// the second must report the failure by name rather than "still starting".
async function selftestLaunchFailureReportsAccurately() {
  const child = spawn(
    process.execPath,
    [
      MCP_SIDING_PATH,
      "--backend-url",
      // Not :1 - see selftestLauncherErrorDoesNotCrash's comment on why.
      "http://127.0.0.1:65533/mcp",
      "--name",
      "test",
      "--app",
      "/definitely/does/not/exist/NoSuchApp.app",
      "--launch",
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => (out += chunk));
  let err = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => (err += chunk));
  const exited = new Promise((resolvePromise) => child.on("exit", resolvePromise));

  const waitFor = async (marker, deadlineMs) => {
    const deadline = Date.now() + deadlineMs;
    while (!out.includes(marker) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 25));
    }
    return out.includes(marker);
  };

  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 57, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
  assert.ok(await waitFor('"id":57', 5_000), `child never answered the first launch-triggering tools/call (stderr: ${err})`);

  // `open -a <bad path>` exits nonzero asynchronously - give it real time
  // to land before the second call.
  await new Promise((r) => setTimeout(r, 1_500));

  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 58, method: "tools/call", params: { name: "x", arguments: {} } })}\n`);
  assert.ok(await waitFor('"id":58', 5_000), `child never answered the second tools/call (stderr: ${err})`);

  child.stdin.end();
  await Promise.race([exited, new Promise((r) => setTimeout(r, 2_000))]);
  if (child.exitCode == null) child.kill();

  const lines = out
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
  const second = lines.find((l) => l.id === 58);
  assert.ok(second, `no reply for the second tools/call (stderr: ${err})`);
  assert.equal(second.result.isError, true);
  assert.doesNotMatch(
    second.result.content[0].text,
    /still starting/i,
    `a launch that exited nonzero must not be reported as "still starting" (stderr: ${err})`,
  );
  assert.match(
    second.result.content[0].text,
    /failed to start/i,
    `the second call must name the launch failure (stderr: ${err})`,
  );
}

// Spawns mcp-siding.mjs (at `scriptPath`) as a real child process, writes
// each of `stdinLines` terminated by a newline, waits for a reply carrying
// `matchId`, and returns that reply's parsed JSON-RPC object. Shared by the
// malformed-stdin and space-in-path self-tests, which differ only in what
// they write to stdin and where the script itself lives.
async function runChildAndGetReply(scriptPath, stdinLines, matchId) {
  // Not port 1 - see runShimScript's identical comment (N47). Both
  // callers only ever send initialize (locally answered) and/or a
  // malformed line, never a tools/call, so the backend is never dialed.
  const child = spawn(
    process.execPath,
    [scriptPath, "--backend-url", "http://127.0.0.1:65533/mcp", "--name", "test", "--no-launch"],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => (out += chunk));
  let err = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => (err += chunk));

  const exited = new Promise((resolve) => child.on("exit", resolve));

  for (const line of stdinLines) child.stdin.write(`${line}\n`);

  const marker = `"id":${matchId}`;
  const deadline = Date.now() + 5_000;
  while (!out.includes(marker) && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 25));
  }
  child.stdin.end();
  await Promise.race([exited, new Promise((r) => setTimeout(r, 2_000))]);
  if (child.exitCode == null) child.kill();

  assert.ok(out.includes(marker), `child never answered (script: ${scriptPath}, stderr: ${err})`);
  const lines = out.trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const found = lines.find((l) => l.id === matchId);
  assert.ok(found, `no reply with id ${matchId} (script: ${scriptPath}, stderr: ${err})`);
  return found;
}

// Runs RESOLVER_SH under /bin/sh with a controlled HOME/CLAUDE_PLUGIN_ROOT
// and returns { status, stdout, stderr } - resolved path (or empty) plus
// exit code. Never touches the real ~/.claude or ~/.codex caches.
function runResolver(env) {
  const script = `${RESOLVER_SH}\nprintf '%s' "$p"\n`;
  const res = spawnSync("/bin/sh", ["-c", script], {
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: "", MCP_SIDING_PATH: "", ...env },
    encoding: "utf8",
  });
  return { status: res.status, stdout: res.stdout, stderr: res.stderr };
}

async function selftestResolver() {
  const home = await mkdtemp(join(tmpdir(), "mcp-siding-resolver-"));

  const touch = async (path) => {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, "");
    return path;
  };

  // -- a. nothing anywhere -> non-zero exit, diagnostic on stderr ---------
  const empty = runResolver({ HOME: home });
  assert.notEqual(empty.status, 0, "no candidate must fail closed, not hang node on stdin");
  assert.equal(empty.stdout, "");
  assert.match(empty.stderr, /could not find mcp-siding\.mjs/);

  // -- b. a single Codex versioned cache entry resolves (either harness
  //       works alone; marketplace segment is wildcarded, not hardcoded
  //       "novotnyllc"). -----------------------------------------------
  const codexLow = await touch(
    join(home, ".codex", "plugins", "cache", "some-marketplace", "roundhouse", "0.7.4", "scripts", "mcp-siding.mjs"),
  );
  const b = runResolver({ HOME: home });
  assert.equal(b.status, 0);
  assert.equal(b.stdout, codexLow);

  // -- c. cross-harness selection: a HIGHER Claude version beats a lower
  //       Codex one. Both caches are scanned in one pass, not "check all
  //       of Claude's cache before considering Codex" - the bug that made
  //       a Codex-updated roundhouse lose to a stale Claude copy. --------
  const claudeHigh = await touch(
    join(home, ".claude", "plugins", "cache", "novotnyllc", "roundhouse", "0.8.0", "scripts", "mcp-siding.mjs"),
  );
  const c = runResolver({ HOME: home });
  assert.equal(c.status, 0);
  assert.equal(c.stdout, claudeHigh, "the higher Claude version must beat the lower Codex one");

  // -- d. and the reverse: a Codex version higher than every Claude one
  //       wins too - proving this is a true global max, not harness order. -
  const codexHigh = await touch(
    join(home, ".codex", "plugins", "cache", "some-marketplace", "roundhouse", "0.9.0", "scripts", "mcp-siding.mjs"),
  );
  const d = runResolver({ HOME: home });
  assert.equal(d.status, 0);
  assert.equal(d.stdout, codexHigh, "a higher Codex version must beat every Claude version present");

  // -- e. a version directory that exists but lacks the script itself is
  //       skipped, not treated as a (broken) match. ------------------------
  await mkdir(join(home, ".claude", "plugins", "cache", "novotnyllc", "roundhouse", "9.9.9"), { recursive: true });
  const e = runResolver({ HOME: home });
  assert.equal(e.status, 0);
  assert.equal(e.stdout, codexHigh, "a version directory with no mcp-siding.mjs must be skipped, not win");

  // -- f. among many versions across both caches, the highest wins via the
  //       awk numeric comparison, not a lexical one. Two ordering traps a
  //       lexical sort gets backwards: 0.7.10 must beat 0.7.4 (lexically
  //       "1" < "4"), and 0.10.0 must beat 0.9.0 (lexically "0.1" < "0.9") -
  //       the second is the realistic case a live install eventually hits
  //       crossing a minor version boundary. -----------------------------
  for (const version of ["0.7.2", "0.7.10"]) {
    await touch(
      join(home, ".claude", "plugins", "cache", "novotnyllc", "roundhouse", version, "scripts", "mcp-siding.mjs"),
    );
  }
  const claudeHighest = await touch(
    join(home, ".claude", "plugins", "cache", "novotnyllc", "roundhouse", "0.10.0", "scripts", "mcp-siding.mjs"),
  );
  const f = runResolver({ HOME: home });
  assert.equal(f.status, 0);
  assert.equal(f.stdout, claudeHighest, "0.10.0 must beat every 0.7.x and 0.9.0 present, numerically not lexically");

  // -- g. CLAUDE_PLUGIN_ROOT outranks everything when it points at a real
  //       file, and is skipped (falling through to the cache) when it
  //       doesn't -----------------------------------------------------------
  const pluginRoot = await mkdtemp(join(tmpdir(), "mcp-siding-pluginroot-"));
  const missing = runResolver({ HOME: home, CLAUDE_PLUGIN_ROOT: pluginRoot });
  assert.equal(missing.status, 0);
  assert.notEqual(missing.stdout, join(pluginRoot, "scripts", "mcp-siding.mjs"), "must skip a CLAUDE_PLUGIN_ROOT with no script file");
  const pluginRootScript = await touch(join(pluginRoot, "scripts", "mcp-siding.mjs"));
  const g = runResolver({ HOME: home, CLAUDE_PLUGIN_ROOT: pluginRoot });
  assert.equal(g.status, 0);
  assert.equal(g.stdout, pluginRootScript);

  // -- h. MCP_SIDING_PATH (explicit local-development override) outranks
  //       everything, including a CLAUDE_PLUGIN_ROOT that also points at a
  //       real file - it is branch 0, checked before branch 1. -------------
  const devDir = await mkdtemp(join(tmpdir(), "mcp-siding-dev-"));
  const devScript = await touch(join(devDir, "mcp-siding.mjs"));
  const h = runResolver({ HOME: home, CLAUDE_PLUGIN_ROOT: pluginRoot, MCP_SIDING_PATH: devScript });
  assert.equal(h.status, 0);
  assert.equal(h.stdout, devScript, "MCP_SIDING_PATH must win over CLAUDE_PLUGIN_ROOT");

  // -- i. N29: MCP_SIDING_PATH pointed at a nonexistent file must fail
  //       closed, NOT fall through to the normal branches - an explicit
  //       pin is an assertion of intent, and silently running an installed
  //       build while the user believes they are exercising their working
  //       tree is exactly the misleading result dev mode exists to avoid.
  //       A valid CLAUDE_PLUGIN_ROOT fallback is deliberately present here
  //       (pluginRootScript, from case g/h above) - a fallback that would
  //       otherwise succeed is what makes this assertion meaningful. -----
  const missingPath = join(devDir, "nope.mjs");
  const i = runResolver({ HOME: home, CLAUDE_PLUGIN_ROOT: pluginRoot, MCP_SIDING_PATH: missingPath });
  assert.notEqual(i.status, 0, "a nonexistent MCP_SIDING_PATH must fail closed, not exit 0");
  assert.notEqual(i.stdout, pluginRootScript, "a nonexistent MCP_SIDING_PATH must not fall through to a real fallback");
  assert.match(i.stderr, /MCP_SIDING_PATH/, "the diagnostic must name the override");
  assert.ok(i.stderr.includes(missingPath), "the diagnostic must name the missing path itself");

  // -- j. unset MCP_SIDING_PATH behaves exactly as before this branch
  //       existed - already implicitly proven by every case above (none set
  //       it), asserted directly here too for a case that names it. --------
  const j = runResolver({ HOME: home, CLAUDE_PLUGIN_ROOT: pluginRoot });
  assert.equal(j.status, 0);
  assert.equal(j.stdout, pluginRootScript, "unset MCP_SIDING_PATH must not change branch 1 onward");
}

// ---------------------------------------------------------------------------

// realpathSync(resolve(...)) matters on macOS: /tmp and /var are symlinks
// to /private/tmp and /private/var, and Node's loader resolves symlinks
// when it builds import.meta.url for the entry point, so a plain lexical
// resolve() of argv[1] would never match when this file is invoked
// through either (which os.tmpdir() commonly is).
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(resolve(process.argv[1]))) {
  selftest()
    .then(() => process.exit(0))
    .catch((err) => {
      process.stderr.write(`selftest FAILED: ${err.stack ?? err}\n`);
      process.exit(1);
    });
}

// The defect this covers: the shim used to advertise tools.listChanged:false,
// which entitles a client to call tools/list exactly ONCE and keep the answer
// for the whole session. A client that first asked while the app was closed
// was served the cached fallback - empty on a first run - and there was no
// channel left to ever correct it. It would believe this server exposes no
// tools until the client itself restarted. The backend reports
// listChanged:false while genuinely serving dynamic tools, so it will never
// volunteer the change either; the shim has to notice and say so.
async function selftestReconcileNeverCommitsTruncatedWalk() {
  const dir = await mkdtemp(join(tmpdir(), "siding-truncated-"));
  const cachePath = join(dir, "tools.json");
  const port = await getFreePort();
  const good = [{ name: "a" }, { name: "b" }];
  await writeFile(cachePath, JSON.stringify(good), "utf8");
  const notifications = [];
  const shim = new Shim({
    url: `http://127.0.0.1:${port}/mcp`,
    name: "test",
    cachePath,
    timeoutMs: 500,
    launchEnabled: false,
    appPath: null,
    launchGraceMs: 150_000,
  });
  shim.onNotification = (msg) => notifications.push(msg);
  shim.lastServedToolsDigest = toolsDigest(good);

  // A backend whose cursor never terminates - either genuinely more pages than
  // the cap, or a looping cursor.
  const server = createServer((req, res) => {
    readJsonBody(req).then((msg) => {
      if (msg.method === "initialize") {
        return sendJson(res, 200,
          { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, serverInfo: { name: "fake" } } },
          { "MCP-Session-Id": "s1" });
      }
      if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
      if (msg.method === "tools/list") {
        return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools: [{ name: "partial" }], nextCursor: "always-more" } });
      }
      sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
    });
  });
  await new Promise((r) => server.listen(port, "127.0.0.1", r));
  try {
    assert.equal(await shim.reconcileTools(), null, "a walk that never terminates must report incomplete");
    assert.equal(notifications.length, 0, "must never claim tools vanished from a truncated walk");
    assert.deepEqual(
      JSON.parse(await readFile(cachePath, "utf8")),
      good,
      "a truncated walk must not overwrite a complete cached inventory",
    );
  } finally {
    await new Promise((r) => server.close(r));
    await rm(dir, { recursive: true, force: true });
  }
}

async function selftestToolListReconcileNotifiesClient() {
  const dir = await mkdtemp(join(tmpdir(), "siding-reconcile-"));
  const cachePath = join(dir, "tools.json");
  const port = await getFreePort();
  const notifications = [];
  const shim = new Shim({
    url: `http://127.0.0.1:${port}/mcp`,
    name: "test",
    cachePath,
    timeoutMs: 500,
    launchEnabled: false,
    appPath: null,
    launchGraceMs: 150_000,
  });
  shim.onNotification = (msg) => notifications.push(msg);

  // The shim must promise the client a list that can change, whatever the
  // backend says about its own.
  const init = await shim.handle({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
  assert.equal(init.result.capabilities.tools.listChanged, true, "shim must advertise listChanged:true");

  // Backend down, cache never written: the exact first-run shape.
  const offline = await shim.handle({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  assert.deepEqual(offline.result.tools, [], "app closed, no cache -> empty list");
  assert.equal(offline.result.ttlMs, 0, "a served-from-disk list must be labelled immediately stale");

  // Reconciling against a still-closed app must stay silent and report the
  // unreachable backend so the caller backs off.
  assert.equal(await shim.reconcileTools(), null, "unreachable backend -> null (back off)");
  assert.equal(notifications.length, 0, "must not notify about a backend it never reached");

  let tools = [{ name: "fusion_mcp_execute", description: "live" }];
  const server = createServer((req, res) => {
    readJsonBody(req).then((msg) => {
      if (msg.method === "initialize") {
        return sendJson(res, 200,
          { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: { listChanged: false } }, serverInfo: { name: "fake" } } },
          { "MCP-Session-Id": "s1" });
      }
      if (msg.method === "notifications/initialized") return sendJson(res, 200, undefined);
      if (msg.method === "tools/list") return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { tools } });
      sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: {} });
    });
  });
  await new Promise((r) => server.listen(port, "127.0.0.1", r));
  try {
    // The app opened. The client is idle and still holds the empty list.
    assert.equal(await shim.reconcileTools(), true, "list moved -> notify");
    assert.equal(notifications.length, 1, "exactly one notification");
    assert.equal(notifications[0].method, "notifications/tools/list_changed");

    // The client re-lists on that signal and now sees the live inventory.
    const live = await shim.handle({ jsonrpc: "2.0", id: 3, method: "tools/list", params: {} });
    assert.deepEqual(live.result.tools, tools, "re-list must serve live tools, not the cache");
    assert.equal(live.result.ttlMs, undefined, "a live pass-through must not be labelled stale");

    // Negative control: an unchanged inventory must not wake the client again.
    assert.equal(await shim.reconcileTools(), false, "unchanged list -> no notification");
    assert.equal(notifications.length, 1, "still exactly one notification");

    // Reordering alone is not a change.
    tools = [{ name: "fusion_mcp_execute", description: "live" }, { name: "b" }].reverse();
    await shim.handle({ jsonrpc: "2.0", id: 4, method: "tools/list", params: {} });
    tools = [...tools].reverse();
    assert.equal(await shim.reconcileTools(), false, "same tools in a different order is not a change");
    assert.equal(notifications.length, 1, "reordering must not notify");

    // A genuine dynamic-tool change mid-session does reach the client.
    tools = [{ name: "fusion_mcp_execute", description: "live" }];
    assert.equal(await shim.reconcileTools(), true, "a real inventory change -> notify");
    assert.equal(notifications.length, 2, "second notification for the real change");

    // Metadata-only change: the digest must cover the WHOLE tool object, not
    // a hand-picked subset. A client holding a stale outputSchema/annotations
    // is holding a stale definition just as surely as a renamed tool.
    tools = [{ name: "fusion_mcp_execute", description: "live", outputSchema: { type: "object" } }];
    assert.equal(await shim.reconcileTools(), true, "an outputSchema change must notify");
    assert.equal(notifications.length, 3, "metadata-only change notifies");

    tools = [{ name: "fusion_mcp_execute", description: "live", annotations: { readOnlyHint: true } }];
    assert.equal(await shim.reconcileTools(), true, "an annotations change must notify");
    assert.equal(notifications.length, 4, "annotations change notifies");

    // Key ORDER within a tool object is not a change.
    tools = [{ annotations: { readOnlyHint: true }, description: "live", name: "fusion_mcp_execute" }];
    assert.equal(await shim.reconcileTools(), false, "reordered object keys are not a change");
    assert.equal(notifications.length, 4, "key reordering must not notify");
  } finally {
    await new Promise((r) => server.close(r));
    await rm(dir, { recursive: true, force: true });
  }
}

// MCP 2026-07-28 multi-round-trip requests: an INTERIM result carries
// `resultType: "input_required"` and no content/tools array, because the
// operation is asking for input rather than returning one. The shape checks
// would previously call that malformed and convert a legitimate response into
// an error the moment a backend adopted the newer revision.
async function selftestInterimResultsArePassedThrough() {
  const { validateResultShape } = await import("./mcp-siding.mjs");

  // Interim results of either method pass untouched, missing arrays and all.
  for (const method of ["tools/call", "tools/list"]) {
    validateResultShape(method, { resultType: "input_required", requestState: "abc" });
  }

  // A COMPLETE result is still held to its shape - the relaxation must not
  // become a hole a genuinely malformed response can walk through.
  assert.throws(
    () => validateResultShape("tools/call", { resultType: "complete" }),
    /CallToolResult/,
    "a complete tools/call result still requires a content array",
  );
  assert.throws(
    () => validateResultShape("tools/list", { resultType: "complete" }),
    /ListToolsResult/,
    "a complete tools/list result still requires a tools array",
  );
  // And a legacy backend, which says nothing about resultType, is unaffected.
  assert.throws(
    () => validateResultShape("tools/call", {}),
    /CallToolResult/,
    "a result with no resultType is treated as complete, exactly as before",
  );
  validateResultShape("tools/call", { content: [] });
}

// The shim must be legible to a MODERN client while still serving a legacy one
// and talking to a legacy backend. Per the 2026-07-28 compatibility matrix a
// legacy-only server FAILS a modern client outright, so this is what keeps the
// shim working when the harness moves and the desktop app has not.
async function selftestDualEraServerFace() {
  const dir = await mkdtemp(join(tmpdir(), "siding-dualera-"));
  const shim = new Shim({
    url: "http://127.0.0.1:65533/mcp",
    name: "test",
    cachePath: join(dir, "tools.json"),
    timeoutMs: 500,
    launchEnabled: false,
    appPath: null,
    launchGraceMs: 150_000,
  });
  try {
    // server/discover is a MUST, and is the stdio era probe. Answered locally,
    // so it works with the app closed.
    const disc = await shim.handle({ jsonrpc: "2.0", id: 1, method: "server/discover", params: {} });
    assert.equal(disc.result.resultType, "complete");
    assert.ok(disc.result.supportedVersions.includes("2026-07-28"), "must offer the current revision");
    assert.ok(disc.result.supportedVersions.includes("2025-06-18"), "must still offer the legacy revision");
    // Advertise ONLY what is actually negotiated: initialize answers with the
    // pinned legacy version and never reads the client's request, so listing an
    // intermediate revision would strand a client that selected it.
    assert.deepEqual(disc.result.supportedVersions, ["2026-07-28", "2025-06-18"], "no version may be advertised that initialize cannot negotiate");
    assert.equal(disc.result.capabilities.tools.listChanged, true);
    assert.equal(disc.result.ttlMs, 0, "our tool list genuinely changes; discover must not be cached as fresh");

    // A version we serve is accepted.
    const okVer = await shim.handle({
      jsonrpc: "2.0", id: 2, method: "ping",
      params: { _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" } },
    });
    assert.equal(okVer.result.resultType, "complete", "a modern client's ping must be discriminated too");

    // One we do not serve gets the defined error, listing what we do serve, so
    // the client can retry rather than guess.
    const badVer = await shim.handle({
      jsonrpc: "2.0", id: 3, method: "ping",
      params: { _meta: { "io.modelcontextprotocol/protocolVersion": "1900-01-01" } },
    });
    assert.equal(badVer.error.code, -32022, "UnsupportedProtocolVersionError");
    assert.equal(badVer.error.data.requested, "1900-01-01");
    assert.ok(badVer.error.data.supported.includes("2026-07-28"));

    // A LEGACY request declares no version and must be unaffected.
    const legacy = await shim.handle({ jsonrpc: "2.0", id: 4, method: "ping", params: {} });
    assert.deepEqual(legacy.result, {}, "a request with no declared version stays legacy and is served, byte-identical");

    // The offline fallback is a complete-but-stale result.
    const offline = await shim.handle({ jsonrpc: "2.0", id: 5, method: "tools/list", params: {} });
    assert.equal(offline.result.resultType, "complete");
    assert.equal(offline.result.ttlMs, 0);

    // A client that DECLARED a modern version gets the discriminator on the
    // ordinary paths too, not only on the two results we synthesize - the
    // backend is legacy and supplies none, so without this a modern client
    // would get legacy-shaped results for nearly every real call.
    const modernCall = await shim.handle({
      jsonrpc: "2.0", id: 6, method: "tools/call",
      params: { _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" } },
    });
    assert.equal(modernCall.result.resultType, "complete", "a modern client's tools/call result must be discriminated");

    // ...and a LEGACY client's bytes are unchanged: it never asked to move.
    const legacyCall = await shim.handle({ jsonrpc: "2.0", id: 7, method: "tools/call", params: {} });
    assert.equal(legacyCall.result.resultType, undefined, "a legacy client's result must not gain fields it never asked for");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
