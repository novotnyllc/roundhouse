#!/usr/bin/env node
// mcp-lazy.mjs - lazy front for a rarely used LOCAL stdio MCP server.
//
// Clients (Codex, Claude Code) start every configured stdio server eagerly
// and keep it alive for the whole session, even if no tool is ever called.
// A heavy, rarely used server (rea: ~470 MB, 170 tools) costs that memory
// in every session. This wrapper answers the startup handshake (initialize,
// ping, and the tools/prompts/resources list calls) from a disk cache and
// starts the real server only on the first other request - in practice the
// first tools/call. The model sees the same tool list either way.
//
//   mcp-lazy.mjs --name NAME [--cache-dir DIR] [--allow-unpinned] -- CMD [ARGS...]
//   mcp-lazy.mjs --refresh --name NAME -- CMD [ARGS...]   delete that cache entry
//   mcp-lazy.mjs --selftest
// Also reachable as `mcp-siding --lazy-stdio ...` through the installed
// launcher, so registrations never name a versioned plugin path.
//
// Cache key = name + exact argv (+ realpath/size/mtime of a non-launcher
// command), so pinning a new version (rea-agents@6.4.0 -> @6.5.0) is a new
// key: the next session runs the real server once, transparently, and
// re-records. Unpinned launcher specs (npx pkg, pkg@latest, ^ranges) are
// never cached - the wrapper becomes a plain pass-through and says so on
// stderr - unless --allow-unpinned. After a lazy start the wrapper also
// re-reads the lists from the live server and rewrites the cache if they
// changed, so a drift heals on the next session.
//
// Zero dependencies, newline-delimited JSON-RPC over stdio, no daemon: the
// real server is this process's child and exits with it.

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createInterface } from "node:readline";
import { mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync, realpathSync } from "node:fs";
import { delimiter, isAbsolute, join, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

export const CACHE_SCHEMA = 1;
export const LIST_METHODS = ["tools/list", "prompts/list", "resources/list", "resources/templates/list"];
const CAPABILITY_FOR = { "tools/list": "tools", "prompts/list": "prompts", "resources/list": "resources", "resources/templates/list": "resources" };
const LAUNCHERS = new Set(["npx", "bunx", "uvx", "pipx", "pnpx"]);
const INTERNAL = "__mcp_lazy_";
const log = (msg) => process.stderr.write(`mcp-lazy: ${msg}\n`);

export function parseArgs(argv) {
  const flags = { cmd: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") { flags.cmd = argv.slice(i + 1); break; }
    if (a === "--name" || a === "--cache-dir") {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      flags[a.slice(2)] = argv[++i];
    } else if (a === "--allow-unpinned" || a === "--refresh" || a === "--selftest" || a === "--help") {
      flags[a.slice(2)] = true;
    } else throw new Error(`unknown flag ${a}`);
  }
  if (!flags.selftest && !flags.help) {
    if (!flags.name) throw new Error("--name is required");
    if (!flags.cmd.length) throw new Error("the real server command goes after --");
  }
  return flags;
}

// Is the package a launcher would fetch pinned to one exact version?
export function isPinned(cmd) {
  const base = cmd[0].split(/[\\/]/).pop().replace(/\.(cmd|exe)$/i, "");
  let rest = cmd.slice(1);
  if (base === "pipx" && rest[0] === "run") rest = rest.slice(1);
  if (!LAUNCHERS.has(base)) return true; // a binary: its identity goes into the key instead
  const spec = rest.find((a) => !a.startsWith("-"));
  if (!spec) return false;
  if (base === "uvx" || base === "pipx") return /^[A-Za-z0-9_.\-[\]]+(==|@)\d[^,<>~^*]*$/.test(spec);
  const m = spec.match(/^((?:@[^/@]+\/)?[^@]+)@(.+)$/);
  return Boolean(m && /^v?\d+\.\d+\.\d+[0-9A-Za-z.+-]*$/.test(m[2]));
}

function binaryIdentity(cmd) {
  const base = cmd[0].split(/[\\/]/).pop().replace(/\.(cmd|exe)$/i, "");
  if (LAUNCHERS.has(base)) return null;
  const dirs = isAbsolute(cmd[0]) || cmd[0].includes("/") ? [""] : (process.env.PATH || "").split(delimiter);
  for (const d of dirs) {
    try {
      const p = realpathSync(d ? join(d, cmd[0]) : resolve(cmd[0]));
      const s = statSync(p);
      if (s.isFile()) return `${p}:${s.size}:${s.mtimeMs}`;
    } catch { /* next */ }
  }
  return null;
}

export function cachePathFor(name, cmd, cacheDir) {
  const dir = cacheDir || join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "mcp-lazy");
  const key = createHash("sha256").update(JSON.stringify({ name, cmd, bin: binaryIdentity(cmd) })).digest("hex").slice(0, 16);
  return join(dir, `${name.replace(/[^A-Za-z0-9_.-]/g, "_")}-${key}.json`);
}

export function readCache(path) {
  try {
    const c = JSON.parse(readFileSync(path, "utf8"));
    if (c.schema === CACHE_SCHEMA && c.initialize && c.lists && c.lists["tools/list"]) return c;
  } catch { /* missing or corrupt: treated as no cache */ }
  return null;
}

function writeCache(path, cache) {
  mkdirSync(resolve(path, ".."), { recursive: true, mode: 0o700 });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(cache), { mode: 0o600 });
  renameSync(tmp, path);
}

export class LazyServer {
  constructor({ name, cmd, cachePath, cacheable, write = (m) => process.stdout.write(`${JSON.stringify(m)}\n`), spawnFn = spawn }) {
    Object.assign(this, { name, cmd, cachePath, cacheable, write, spawnFn });
    this.cache = cacheable ? readCache(cachePath) : null;
    this.child = null;      // real server process once started
    this.ready = false;     // real server handshake done; pipe freely
    this.queue = [];        // client messages held while the real server starts
    this.clientInit = null; // client's initialize params, replayed to the real server
    this.pendingInternal = new Map();
    this.seq = 0;
    this.onExit = (code) => process.exit(code ?? 0);
  }

  // One message from the MCP client.
  fromClient(msg) {
    if (this.ready) return this.send(msg);
    if (this.child) return void this.queue.push(msg);
    if (msg.method === "initialize") {
      this.clientInit = msg.params || {};
      const c = this.cache;
      if (c && c.protocolVersion === this.clientInit.protocolVersion) return this.write({ jsonrpc: "2.0", id: msg.id, result: c.initialize });
      if (c) log(`client asked protocol ${this.clientInit.protocolVersion}, cache has ${c.protocolVersion}; starting ${this.name} now`);
      return this.start(msg, true);
    }
    if (this.cache && msg.id === undefined) return; // notifications before start (initialized, cancelled...) are moot
    if (this.cache && msg.method === "ping") return this.write({ jsonrpc: "2.0", id: msg.id, result: {} });
    if (this.cache && LIST_METHODS.includes(msg.method)) {
      const pages = this.cache.lists[msg.method];
      const page = pages && pages[msg.params?.cursor ?? ""];
      if (page) return this.write({ jsonrpc: "2.0", id: msg.id, result: page });
      if (!pages && !this.cache.initialize.capabilities?.[CAPABILITY_FOR[msg.method]]) {
        return this.write({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: `Method not found: ${msg.method}` } });
      }
    }
    this.start(msg, false);
  }

  // Start the real server. passthroughInit: the client's own initialize goes
  // straight through (no cache or protocol mismatch); otherwise replay it.
  start(trigger, passthroughInit) {
    log(`starting ${this.name} (${passthroughInit ? "no usable cache" : `trigger ${trigger.method}`})`);
    const child = this.spawnFn(this.cmd[0], this.cmd.slice(1), { stdio: ["pipe", "pipe", "inherit"] });
    this.child = child;
    child.on("error", (err) => { log(`cannot start ${this.cmd[0]}: ${err.message}`); this.failAll(err.message); });
    child.on("exit", (code, sig) => { log(`${this.name} exited (${sig || code})`); this.onExit(code ?? 1); });
    createInterface({ input: child.stdout }).on("line", (line) => this.fromServer(line));
    if (passthroughInit) {
      this.ready = true;
      this.recordAfterInit = trigger.id;
      this.send(trigger);
    } else {
      this.queue.push(trigger);
      this.internal("initialize", this.clientInit).then(() => {
        this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
        this.ready = true;
        for (const m of this.queue.splice(0)) this.send(m);
        this.record(); // refresh the cache from the live server
      }, (err) => this.failAll(`initialize failed: ${err.message}`));
    }
  }

  fromServer(line) {
    let msg;
    try { msg = JSON.parse(line); } catch { return void (line.trim() && log(`dropping non-JSON line from ${this.name}`)); }
    if (typeof msg.id === "string" && msg.id.startsWith(INTERNAL) && msg.method === undefined) {
      const p = this.pendingInternal.get(msg.id);
      this.pendingInternal.delete(msg.id);
      if (p) (msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result));
      return;
    }
    this.write(msg);
    if (this.recordAfterInit !== undefined && msg.id === this.recordAfterInit && msg.result) {
      this.recordAfterInit = undefined;
      this.liveInit = msg.result;
      this.waitInitialized = true;
    }
  }

  send(msg) {
    this.child.stdin.write(`${JSON.stringify(msg)}\n`);
    if (this.waitInitialized && msg.method === "notifications/initialized") {
      this.waitInitialized = false;
      this.record(this.liveInit);
    }
  }

  internal(method, params) {
    const id = `${INTERNAL}${++this.seq}`;
    return new Promise((res, rej) => {
      this.pendingInternal.set(id, { resolve: res, reject: rej });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  // Read every list (all pages) from the live server and write the cache.
  async record(initResult) {
    if (!this.cacheable) return;
    try {
      const init = initResult || this.cache.initialize;
      const lists = {};
      for (const method of LIST_METHODS) {
        if (!init.capabilities?.[CAPABILITY_FOR[method]]) continue;
        const pages = {};
        let cursor = "";
        for (let n = 0; n < 50; n++) {
          const r = await this.internal(method, cursor ? { cursor } : {}).catch(() => null);
          if (!r) break;
          pages[cursor] = r;
          if (!r.nextCursor) break;
          cursor = r.nextCursor;
        }
        if (Object.keys(pages).length) lists[method] = pages;
      }
      if (!lists["tools/list"]) return log("server returned no tools/list; not caching");
      const next = { schema: CACHE_SCHEMA, name: this.name, cmd: this.cmd, protocolVersion: this.clientInit.protocolVersion, initialize: init, lists };
      const same = this.cache && JSON.stringify(this.cache.lists) === JSON.stringify(lists) && JSON.stringify(this.cache.initialize) === JSON.stringify(init);
      if (same) return;
      writeCache(this.cachePath, { ...next, recordedAt: new Date().toISOString() });
      log(`${this.cache ? "tool list changed; cache refreshed" : "cache recorded"} for next session: ${this.cachePath}`);
    } catch (err) { log(`could not record cache: ${err.message}`); }
  }

  failAll(message) {
    for (const m of this.queue.splice(0)) if (m.id !== undefined) this.write({ jsonrpc: "2.0", id: m.id, error: { code: -32603, message: `mcp-lazy: ${this.name}: ${message}` } });
  }

  // Client went away: close the real server's stdin and give it a moment.
  close() {
    if (!this.child || this.child.exitCode !== null) return process.exit(0);
    this.child.stdin.end();
    setTimeout(() => { try { this.child.kill("SIGTERM"); } catch { /* gone */ } }, 2000).unref();
    setTimeout(() => process.exit(0), 4000).unref();
  }
}

export function cli(argv) {
  let flags;
  try { flags = parseArgs(argv); } catch (err) {
    process.stderr.write(`mcp-lazy: ${err.message}\nusage: mcp-lazy.mjs --name NAME [--cache-dir DIR] [--allow-unpinned] [--refresh] -- CMD [ARGS...]\n`);
    process.exit(2);
  }
  if (flags.help) return void process.stdout.write("usage: mcp-lazy.mjs --name NAME [--cache-dir DIR] [--allow-unpinned] [--refresh] -- CMD [ARGS...]\n       mcp-lazy.mjs --selftest\n");
  if (flags.selftest) {
    return void import("./mcp-lazy.selftest.mjs").then((m) => m.selftest()).then(() => process.exit(0), (err) => {
      process.stderr.write(`selftest FAILED: ${err.stack ?? err}\n`);
      process.exit(1);
    });
  }
  const cachePath = cachePathFor(flags.name, flags.cmd, flags["cache-dir"]);
  if (flags.refresh) {
    try { unlinkSync(cachePath); process.stdout.write(`removed ${cachePath}\n`); } catch { process.stdout.write(`no cache at ${cachePath}\n`); }
    return;
  }
  const cacheable = flags["allow-unpinned"] || isPinned(flags.cmd);
  if (!cacheable) log(`${flags.cmd.join(" ")} is not pinned to an exact version; running it eagerly with no cache (pin it, or pass --allow-unpinned)`);
  const server = new LazyServer({ name: flags.name, cmd: flags.cmd, cachePath, cacheable });
  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return log("ignoring non-JSON input line"); }
    server.fromClient(msg);
  });
  rl.on("close", () => server.close());
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(resolve(process.argv[1]))) cli(process.argv.slice(2));
