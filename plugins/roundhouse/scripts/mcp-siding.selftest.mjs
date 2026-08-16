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
import { mkdtemp, mkdir, writeFile, copyFile, chmod, rm } from "node:fs/promises";
import { realpathSync, accessSync, constants as fsConstants } from "node:fs";
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
  shQuote,
  PROTOCOL_VERSION,
  parseArgs,
  buildShimFromArgs,
  defaultCachePath,
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

  // -- 1b. CLI parsing (C7/C8/C9 regressions) ------------------------------
  // --no-launch=false / --launch=false must be real booleans, not truthy
  // strings - the concrete bug: --no-launch=false used to disable launch
  // (the string "false" is truthy), the exact opposite of what it reads as.
  assert.equal(parseArgs(["--no-launch=false"])["no-launch"], false);
  assert.equal(parseArgs(["--launch=false"]).launch, false);
  assert.equal(parseArgs(["--launch=true"]).launch, true);
  assert.throws(() => parseArgs(["--launch=maybe"]), /invalid value for --launch/, "a non-boolean =value on a bool flag must be rejected");
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

  // -- 7e4. N3/N19: pagination must not corrupt the offline cache. An
  //         uncursored (first-page) request REPLACES the cache; a cursored
  //         (later-page) request APPENDS to it - fetching page two must
  //         not overwrite page one's entries, and once the client has
  //         walked the whole sequence and the backend goes away, the
  //         offline tools/list must serve BOTH pages' tools (not just
  //         page one - N3's fix stopped a middle page from standing in as
  //         the complete set, but replaced it with page one alone always
  //         doing that instead), and must not claim more pages are
  //         fetchable (no stale nextCursor). ------------------------------
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
  //         technique that made the N1 launcher test above real. See
  //         selftestNodeResolver for why "none available anywhere" is only
  //         assertable when this machine has no real node at the
  //         hardcoded fallback paths. -------------------------------------
  await selftestNodeResolver();

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

      await new Promise((r) => setTimeout(r, 100)); // the forward to the backend is fire-and-forget
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
        assert.equal(reply.result.isError, true, `id ${id} must be a cancelled result`);
        assert.match(reply.result.content[0].text, /cancel/i, `id ${id} must say cancelled`);
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
      assert.equal(replyA.result.isError, true);
      assert.match(replyA.result.content[0].text, /cancel/i);
      assert.equal(replyB.result.isError, true, "B must return a cancelled result");
      assert.match(replyB.result.content[0].text, /cancel/i);
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
          const response = JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { held: true } });
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
      assert.deepEqual(held.result, { held: true });
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
          const response = JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { crlf: true } });
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
        { crlf: true },
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
          const response = JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { mixedCase: true } });
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
      assert.deepEqual(mixedCaseReply.result, { mixedCase: true }, "a mixed-case Content-Type must still resolve with the real result");
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
        sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: msg.method === "tools/call" ? { ok: true } : {} });
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
      assert.deepEqual(matched.result, { ok: true }, "a matching-id JSON response must still work");
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
          // Call B - answer normally, correlated by its OWN id.
          return sendJson(res, 200, { jsonrpc: "2.0", id: msg.id, result: { callB: true } });
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
      assert.deepEqual(resultB.result, { callB: true }, "call B must complete normally with its own result");

      await new Promise((r) => setTimeout(r, 100)); // the forward to the backend is fire-and-forget
      assert.equal(idRaceToolCallIds.length, 2, "both calls must have reached the backend");
      assert.notEqual(
        idRaceToolCallIds[0],
        idRaceToolCallIds[1],
        "call A and call B must use different backend request ids, not a shared hardcoded one",
      );
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
      "SSE-multi-event + error-cache-preservation + session-less + resolver + space-path + injection verified)\n",
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
  const server = createServer(handler);
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

// N21: runs buildShimScript()'s FULL output (RESOLVER_SH + NODE_RESOLVER_SH
// + the exec line) through a real `/bin/sh -c`, exactly the way a
// registration actually invokes it - resolving mcp-siding.mjs itself is not
// enough on its own if there is then no `node` to run it with. $MCP_SIDING_PATH
// pins the script resolution deterministically (RESOLVER_SH is not what
// these tests are about); each case doctors PATH/HOME/$MCP_SIDING_NODE to
// control node resolution specifically.
async function runShimScript(env, timeoutMs = 5_000) {
  const script = buildShimScript({ "backend-url": "http://127.0.0.1:1/mcp", name: "test" });
  const child = spawn("/bin/sh", ["-c", script], { stdio: ["pipe", "pipe", "pipe"], env });
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
  // reaching that exit before the timeout, not a marker.
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 60, method: "initialize", params: {} })}\n`);
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

  // -- node absent from PATH but present at a known fallback location -
  //    asdf's default shim path, HOME-relative and so fully controllable
  //    in a test, unlike the Homebrew/system absolute paths below. -----
  const fakeHome = await mkdtemp(join(tmpdir(), "mcp-siding-node-"));
  const asdfShimDir = join(fakeHome, ".asdf", "shims");
  await mkdir(asdfShimDir, { recursive: true });
  const asdfNodePath = join(asdfShimDir, "node");
  await copyFile(realNode, asdfNodePath);
  await chmod(asdfNodePath, 0o755);
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

  // -- none available anywhere: exits non-zero with a diagnostic rather
  //    than hanging. Only assertable when this machine genuinely has no
  //    node at any of the hardcoded absolute fallback paths - those are
  //    real system paths, not overridable via env, so on a machine that
  //    happens to have e.g. Homebrew's /opt/homebrew/bin/node, resolving
  //    it there is CORRECT behavior, not something this test can turn
  //    into a failure case without touching real system state.
  const hardcodedFallbacks = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"];
  const anyHardcodedFallbackExists = hardcodedFallbacks.some((p) => {
    try {
      accessSync(p, fsConstants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
  if (anyHardcodedFallbackExists) {
    process.stderr.write(
      "  (skipping N21 'no node anywhere' assertion - this machine has a real node at one of the hardcoded fallback paths)\n",
    );
  } else {
    const emptyHome = await mkdtemp(join(tmpdir(), "mcp-siding-nonode-"));
    try {
      const noneResult = await runShimScript({ ...baseEnv, PATH: brokenPath, HOME: emptyHome, MCP_SIDING_NODE: "" }, 3_000);
      assert.ok(!noneResult.timedOut, "a subprocess with no node resolvable anywhere must exit, not hang");
      assert.notEqual(noneResult.code, 0, "must exit non-zero when no node resolves anywhere");
      assert.match(noneResult.err, /no node with global fetch/i, "must name what was tried in the diagnostic");
    } finally {
      await rm(emptyHome, { recursive: true, force: true });
    }
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
    await copyFile(realNode, realFallbackPath);
    await chmod(realFallbackPath, 0o755);
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
    //    first real request. A bare HOME (no asdf fallback populated) so
    //    the only candidate PATH or the fixed locations can find is the
    //    stub. Same real-system-path caveat as the "none available" case
    //    above. -----------------------------------------------------
    if (anyHardcodedFallbackExists) {
      process.stderr.write(
        "  (skipping N24 'only a too-old node' assertion - this machine has a real node at one of the hardcoded fallback paths)\n",
      );
    } else {
      const bareHome = await mkdtemp(join(tmpdir(), "mcp-siding-stub-bare-"));
      try {
        const bareResult = await runShimScript({ ...baseEnv, PATH: stubNodeDir, HOME: bareHome, MCP_SIDING_NODE: "" }, 3_000);
        assert.ok(!bareResult.timedOut, "a subprocess with only a too-old node anywhere must exit, not hang");
        assert.notEqual(bareResult.code, 0, "must exit non-zero when only a too-old node is found");
        assert.match(bareResult.err, /fetch|ReadableStream/i, "the diagnostic must name the requirement that was rejected");
        assert.match(bareResult.err, /rejected/i, "the diagnostic must name what was rejected");
      } finally {
        await rm(bareHome, { recursive: true, force: true });
      }
    }
  } finally {
    await rm(stubNodeHome, { recursive: true, force: true });
  }
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
  const child = spawn(
    process.execPath,
    [scriptPath, "--backend-url", "http://127.0.0.1:1/mcp", "--name", "test", "--no-launch"],
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

  // -- i. MCP_SIDING_PATH pointed at a nonexistent file falls through to the
  //       normal branches rather than failing closed - only an *existing*
  //       file is honored as the override. ---------------------------------
  const i = runResolver({ HOME: home, CLAUDE_PLUGIN_ROOT: pluginRoot, MCP_SIDING_PATH: join(devDir, "nope.mjs") });
  assert.equal(i.status, 0);
  assert.equal(i.stdout, pluginRootScript, "a missing MCP_SIDING_PATH must fall through, not fail");

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
