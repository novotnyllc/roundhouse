// Self-test for mcp-lazy.mjs: a fake stdio MCP server in a temp dir, real
// child processes, no network and no real caches. Run via
// `node mcp-lazy.mjs --selftest` (or scripts/test-roundhouse, section 76).

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { isPinned, cachePathFor, parseArgs } from "./mcp-lazy.mjs";

const LAZY = fileURLToPath(new URL("./mcp-lazy.mjs", import.meta.url));

// Fake server: records each start and each method it sees in $FAKE_LOG.
const FAKE = `
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
const log = (s) => appendFileSync(process.env.FAKE_LOG, s + "\\n");
log("start");
const tools = (process.env.FAKE_TOOLS || "a,b,c").split(",").map((n) => ({ name: n, inputSchema: { type: "object" } }));
const out = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
let initialized = false;
createInterface({ input: process.stdin }).on("line", (l) => {
  const m = JSON.parse(l);
  log(m.method || "response");
  if (m.method === "initialize") return out({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: m.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "fake", version: process.env.FAKE_VERSION || "1" } } });
  if (m.method === "notifications/initialized") { initialized = true; return; }
  if (m.id === undefined) return;
  if (!initialized) return out({ jsonrpc: "2.0", id: m.id, error: { code: -32002, message: "not initialized" } });
  if (m.method === "tools/list") {
    const cursor = m.params?.cursor;
    return out({ jsonrpc: "2.0", id: m.id, result: cursor ? { tools: tools.slice(2) } : { tools: tools.slice(0, 2), nextCursor: "p2" } });
  }
  if (m.method === "tools/call") return out({ jsonrpc: "2.0", id: m.id, result: { content: [{ type: "text", text: "echo:" + m.params.arguments.x }] } });
  if (m.method === "ping") return out({ jsonrpc: "2.0", id: m.id, result: {} });
  out({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "nope" } });
});
`;

function session(dir, env, extraArgs = []) {
  const child = spawn(process.execPath, [LAZY, "--name", "fake", "--cache-dir", join(dir, "cache"), ...extraArgs, "--", process.execPath, join(dir, "fake.mjs")], {
    stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, FAKE_LOG: join(dir, "fake.log"), ...env },
  });
  const waiters = new Map();
  let stderr = "";
  child.stderr.on("data", (d) => { stderr += d; });
  createInterface({ input: child.stdout }).on("line", (l) => {
    const m = JSON.parse(l);
    const w = waiters.get(m.id);
    if (w) { waiters.delete(m.id); w(m); }
  });
  let id = 0;
  const exited = new Promise((r) => child.on("exit", r));
  return {
    request(method, params = {}) {
      const myId = ++id;
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: myId, method, params }) + "\n");
      return new Promise((res, rej) => {
        const t = setTimeout(() => rej(new Error(`timeout waiting for ${method}; stderr: ${stderr}`)), 10000);
        waiters.set(myId, (m) => { clearTimeout(t); res(m); });
      });
    },
    notify(method) { child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n"); },
    async end() { child.stdin.end(); await exited; return stderr; },
  };
}

const INIT = { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "selftest", version: "0" } };
const starts = (dir) => (existsSync(join(dir, "fake.log")) ? readFileSync(join(dir, "fake.log"), "utf8").split("\n").filter((l) => l === "start").length : 0);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function handshake(s) {
  const init = await s.request("initialize", INIT);
  s.notify("notifications/initialized");
  const p1 = await s.request("tools/list");
  const p2 = await s.request("tools/list", { cursor: p1.result.nextCursor });
  return { init, tools: [...p1.result.tools, ...p2.result.tools].map((t) => t.name) };
}

export async function selftest() {
  // Pinning rules.
  assert.equal(isPinned(["npx", "-y", "rea-agents@6.4.0", "mcp"]), true);
  assert.equal(isPinned(["npx", "-y", "@scope/pkg@1.2.3-beta.1"]), true);
  assert.equal(isPinned(["npx", "-y", "rea-agents", "mcp"]), false);
  assert.equal(isPinned(["npx", "-y", "rea-agents@latest"]), false);
  assert.equal(isPinned(["npx", "-y", "@scope/pkg"]), false);
  assert.equal(isPinned(["npx", "pkg@^1.2.0"]), false);
  assert.equal(isPinned(["uvx", "tool==0.4.1"]), true);
  assert.equal(isPinned(["uvx", "tool"]), false);
  assert.equal(isPinned(["/usr/local/bin/some-server", "--stdio"]), true);
  assert.throws(() => parseArgs(["--name", "x"]), /after --/);
  // A version bump is a different cache key.
  assert.notEqual(cachePathFor("rea", ["npx", "-y", "rea-agents@6.4.0", "mcp"], "/c"), cachePathFor("rea", ["npx", "-y", "rea-agents@6.5.0", "mcp"], "/c"));

  const dir = mkdtempSync(join(tmpdir(), "mcp-lazy-selftest-"));
  try {
    writeFileSync(join(dir, "fake.mjs"), FAKE);

    // 1. No cache: real server starts at once, behaves transparently, cache recorded.
    let s = session(dir, {});
    let h = await handshake(s);
    assert.deepEqual(h.tools, ["a", "b", "c"]);
    assert.equal(h.init.result.serverInfo.name, "fake");
    await wait(300);
    await s.end();
    assert.equal(starts(dir), 1, "cold session starts the real server once");
    assert.equal(readdirSync(join(dir, "cache")).filter((f) => f.endsWith(".json")).length, 1, "cache recorded");

    // 2. Warm: initialize + paged tools/list + ping from cache, real server never started.
    s = session(dir, {});
    h = await handshake(s);
    assert.deepEqual(h.tools, ["a", "b", "c"]);
    assert.deepEqual((await s.request("ping")).result, {});
    await s.end();
    assert.equal(starts(dir), 1, "warm session must not start the real server");

    // 3. First tools/call starts it, replays initialize, and returns the real result.
    s = session(dir, {});
    await handshake(s);
    const call = await s.request("tools/call", { name: "a", arguments: { x: 42 } });
    assert.equal(call.result.content[0].text, "echo:42");
    const call2 = await s.request("tools/call", { name: "a", arguments: { x: 7 } });
    assert.equal(call2.result.content[0].text, "echo:7");
    await s.end();
    assert.equal(starts(dir), 2, "tools/call starts the real server exactly once");
    const seen = readFileSync(join(dir, "fake.log"), "utf8").split("\n");
    const lastStart = seen.lastIndexOf("start");
    assert.deepEqual(seen.slice(lastStart + 1, lastStart + 4), ["initialize", "notifications/initialized", "tools/call"], "handshake replayed before the call");

    // 4. Drift: the live server's tool list changed -> cache refreshed after a lazy start.
    s = session(dir, { FAKE_TOOLS: "a,b,c,d" });
    await handshake(s);
    await s.request("tools/call", { name: "a", arguments: { x: 1 } });
    await wait(500);
    let stderr = await s.end();
    assert.match(stderr, /cache refreshed/);
    s = session(dir, { FAKE_TOOLS: "a,b,c,d" });
    h = await handshake(s);
    await s.end();
    assert.deepEqual(h.tools, ["a", "b", "c", "d"], "next session serves the refreshed list");
    const startsBefore = starts(dir);

    // 5. Protocol mismatch: never answer a version the cache was not recorded with.
    s = session(dir, {});
    const init = await s.request("initialize", { ...INIT, protocolVersion: "2099-01-01" });
    assert.equal(init.result.protocolVersion, "2099-01-01", "answered by the real server");
    await s.end();
    assert.equal(starts(dir), startsBefore + 1);

    // 6. --refresh removes exactly that entry.
    const refreshed = spawn(process.execPath, [LAZY, "--refresh", "--name", "fake", "--cache-dir", join(dir, "cache"), "--", process.execPath, join(dir, "fake.mjs")]);
    await new Promise((r) => refreshed.on("exit", r));
    assert.equal(readdirSync(join(dir, "cache")).filter((f) => f.endsWith(".json")).length, 0, "--refresh deleted the cache");

    // 7. Client EOF with a running real server: both exit, nothing left behind.
    s = session(dir, {});
    await handshake(s);
    await s.request("tools/call", { name: "a", arguments: { x: 2 } });
    const t0 = Date.now();
    await s.end();
    assert.ok(Date.now() - t0 < 5000, "wrapper exits promptly on client EOF");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  process.stdout.write("mcp-lazy selftest ok\n");
}
