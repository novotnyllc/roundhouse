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
import { mkdtemp, mkdir, writeFile, copyFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import assert from "node:assert/strict";
import {
  Shim,
  parseBody,
  writeCache,
  readCache,
  RESOLVER_SH,
  buildShimScript,
  shQuote,
  PROTOCOL_VERSION,
  parseArgs,
  buildShimFromArgs,
} from "./mcp-siding.mjs";

// Resolved relative to *this file*, not CWD or a hardcoded repo path - so
// the pair keeps working after both files are copied somewhere else
// entirely (verified as part of this self-test's own release-gate run).
const MCP_SIDING_PATH = fileURLToPath(new URL("./mcp-siding.mjs", import.meta.url));

export async function selftest() {
  // -- 1. body parsing, including multi-event SSE selection by id --------
  assert.deepEqual(parseBody('data: {"a":1,"id":5}\n', "text/event-stream", 5), { a: 1, id: 5 });
  assert.deepEqual(parseBody('{"a":2}', "application/json", 7), { a: 2 });
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

  // -- 2. initialize always answered locally, even pointed at nothing ---
  const tmpRoot = await mkdtemp(join(tmpdir(), "mcp-siding-"));
  const deadShim = new Shim({
    url: "http://127.0.0.1:1/mcp", // nothing listens here
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
    url: "http://127.0.0.1:1/mcp",
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

  // -- 7e4. N3: pagination must not corrupt the offline cache. Only the
  //         first (uncursored) page is cached - fetching page two must not
  //         overwrite it, and once the backend is gone, the offline
  //         tools/list must serve the coherent first page, never page
  //         two's slice masquerading as the complete set, and must not
  //         claim more pages are fetchable (no stale nextCursor). ---------
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
      assert.deepEqual(readCache(paginationCachePath), page1Tools, "cache must hold the first page, not the last-fetched page");
    },
  );
  // The backend is gone now (withServer tore it down on return).
  const offlineListing = await paginationShim.handle({ jsonrpc: "2.0", id: 42, method: "tools/list", params: {} });
  assert.deepEqual(offlineListing.result.tools, page1Tools, "offline tools/list must serve the coherent first page, never page two's slice");
  assert.equal(offlineListing.result.nextCursor, undefined, "offline listing must not claim more pages are fetchable");

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
      "http://127.0.0.1:1/mcp", // unreachable - forces downCallResult() to actually launch
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
