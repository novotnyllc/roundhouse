#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { lstatSync, readdirSync, readFileSync, readlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";

const TIMEOUT_MS = 15_000;
const PLUGIN_ID = /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/;
const CODEX_EXECUTABLE_FLAG = "--codex-executable";

function fail(message, exitCode = 1) {
  const error = new Error(`codex-plugin-hooks: ${message}`);
  error.exitCode = exitCode;
  throw error;
}

function treeEntries(root) {
  // Every regular file (bytes and owner-execute bit) and symlink (target, not
  // followed) under ROOT, by relative path — the same tree, with the same
  // exclusions, that apply-claude.sh's fleet_run_tree_digest hashes: any
  // `.git` is pruned, and Claude's `.in_use` / `.orphaned_at` markers at the
  // root are not plugin content. Throws when the tree cannot be read.
  const entries = new Map();
  const walk = (dir, rel) => {
    for (const name of readdirSync(dir)) {
      if (name === ".git") continue;
      const relPath = rel ? `${rel}/${name}` : name;
      if (!rel && (name === ".in_use" || name === ".orphaned_at")) continue;
      const full = join(dir, name);
      const stat = lstatSync(full);
      if (stat.isSymbolicLink()) entries.set(relPath, `link ${readlinkSync(full)}`);
      else if (stat.isDirectory()) walk(full, relPath);
      else if (stat.isFile()) {
        const digest = createHash("sha256").update(readFileSync(full)).digest("hex");
        entries.set(relPath, `file ${stat.mode & 0o100 ? "x" : "-"} ${digest}`);
      }
    }
  };
  walk(root, "");
  if (!entries.size) throw new Error(`empty tree: ${root}`);
  return entries;
}

function treesIdentical(left, right) {
  try {
    const a = treeEntries(left);
    const b = treeEntries(right);
    return a.size === b.size && [...a].every(([path, value]) => b.get(path) === value);
  } catch {
    return false;
  }
}

function spawnCodex(codexExecutable, args, options) {
  const shell = process.platform === "win32" && /\.(?:cmd|bat)$/i.test(codexExecutable);
  // cmd.exe receives a command string when shell is enabled, so preserve a
  // bundled shim's full path rather than splitting it at a space.
  const command = shell ? `"${codexExecutable}"` : codexExecutable;
  return spawn(command, args, shell ? { ...options, shell: true } : options);
}

function terminateCodexChild(child) {
  if (process.platform !== "win32" || !child.pid) {
    child.kill();
    return;
  }
  // A bundled .cmd starts through cmd.exe. Kill its full tree so a timeout
  // cannot leave the real Codex process mutating state after this helper fails.
  const killer = spawn("taskkill.exe", ["/pid", String(child.pid), "/t", "/f"], {
    stdio: "ignore",
    windowsHide: true,
  });
  killer.once("error", () => child.kill());
}

function hookKeyPath(key) {
  const escaped = key.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  return `hooks.state."${escaped}".trusted_hash`;
}

class AppServer {
  constructor(codexExecutable) {
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = "";
    this.child = spawnCodex(codexExecutable, ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => {
      this.stderr = (this.stderr + chunk).slice(-8192);
    });
    createInterface({ input: this.child.stdout }).on("line", (line) => {
      if (Buffer.byteLength(line) > 1024 * 1024) {
        this.rejectAll(new Error("app-server response exceeded 1 MiB"));
        terminateCodexChild(this.child);
        return;
      }
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.rejectAll(new Error("app-server returned invalid JSON"));
        terminateCodexChild(this.child);
        return;
      }
      if (message.id == null || !this.pending.has(message.id)) return;
      const { resolve, reject, timer } = this.pending.get(message.id);
      clearTimeout(timer);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message || "app-server request failed"));
      else resolve(message.result);
    });
    this.child.on("error", (error) => this.rejectAll(error));
    // Writing to a dead child's stdin emits EPIPE on the stream. Unhandled,
    // that is an uncaught exception that kills the process before the pending
    // request can reject through the intended timeout path.
    this.child.stdin.on("error", (error) => this.rejectAll(error));
    this.child.on("exit", (code) => {
      if (this.pending.size) {
        this.rejectAll(new Error(`app-server exited before responding (${code ?? "signal"})`));
      }
    });
  }

  rejectAll(error) {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    this.pending.clear();
  }

  send(message) {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`app-server ${method} timed out`));
        terminateCodexChild(this.child);
      }, TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ method, id, params });
    });
  }

  async initialize() {
    await this.request("initialize", {
      clientInfo: {
        name: "roundhouse",
        title: "Roundhouse",
        version: "0.2.0",
      },
      capabilities: {},
    });
    this.send({ method: "initialized", params: {} });
  }

  async close() {
    if (this.child.exitCode != null) return;
    this.child.stdin.end();
    const exited = new Promise((resolve) => this.child.once("exit", resolve));
    const timer = setTimeout(() => terminateCodexChild(this.child), 1_000);
    await exited;
    clearTimeout(timer);
  }
}

function validateHooks(result, cwd, pluginId) {
  const row = result?.data?.find((entry) => entry?.cwd === cwd);
  if (!row || !Array.isArray(row.hooks)) fail("hooks/list returned an invalid result");
  if (row.errors?.length) fail("hook discovery returned errors");
  // Warnings are scoped to the target plugin: another installed plugin's
  // warning (e.g. a timeout clamp in its hooks.json) must not block this
  // approval. Warning strings carry the offending hooks.json path.
  const [name, marketplace] = String(pluginId).split("@");
  const mine = (row.warnings ?? []).filter((w) =>
    String(w).includes(`${marketplace}/${name}/`) ||
    String(w).includes(`${marketplace}\\${name}\\`),
  );
  if (mine.length) fail(`hook discovery returned warnings for ${pluginId}: ${mine.join("; ")}`);
  return row.hooks;
}

function matchingPluginHooks(hooks, pluginId) {
  const matching = hooks.filter((hook) => hook?.pluginId === pluginId);
  for (const hook of matching) {
    if (
      typeof hook.key !== "string" ||
      !hook.key.length ||
      hook.key.length > 8192 ||
      /[\u0000-\u001f\u007f]/.test(hook.key) ||
      typeof hook.currentHash !== "string" ||
      !hook.currentHash.startsWith("sha256:") ||
      hook.currentHash.length > 128 ||
      !["managed", "modified", "trusted", "untrusted"].includes(hook.trustStatus)
    ) {
      fail("hooks/list returned invalid hook metadata");
    }
  }
  if (new Set(matching.map((hook) => hook.key)).size !== matching.length) {
    fail("hooks/list returned duplicate hook keys");
  }
  return matching.filter((hook) => hook.isManaged !== true);
}

async function withAppServer(action, codexExecutable) {
  const server = new AppServer(codexExecutable);
  try {
    await server.initialize();
    return await action(server);
  } finally {
    await server.close();
  }
}

async function listHooks(pluginId, cwd, codexExecutable) {
  return withAppServer(async (server) => {
    const hooks = validateHooks(await server.request("hooks/list", { cwds: [cwd] }), cwd, pluginId);
    return matchingPluginHooks(hooks, pluginId);
  }, codexExecutable);
}

async function writeTrust(pluginId, cwd, wanted, codexExecutable) {
  if (!wanted.length) return;
  await withAppServer(async (server) => {
    const hooks = validateHooks(await server.request("hooks/list", { cwds: [cwd] }), cwd, pluginId);
    const current = new Map(matchingPluginHooks(hooks, pluginId).map((hook) => [hook.key, hook]));
    const edits = wanted.flatMap((key) => {
      const hook = current.get(key);
      return hook
        ? [{ keyPath: hookKeyPath(key), value: hook.currentHash, mergeStrategy: "replace" }]
        : [];
    });
    if (edits.length) {
      await server.request("config/batchWrite", {
        edits,
        filePath: null,
        expectedVersion: null,
        reloadUserConfig: true,
      });
    }
  }, codexExecutable);
}

async function verifyTrust(pluginId, cwd, wanted, rejectNewTrusted, requireAllPresent, codexExecutable) {
  const hooks = await listHooks(pluginId, cwd, codexExecutable);
  const byKey = new Map(hooks.map((hook) => [hook.key, hook]));
  for (const key of wanted) {
    const hook = byKey.get(key);
    // A key that vanished between write and verify was silently treated as
    // success while `approved` still counted it as trusted. On approve that is
    // a false report; on update a hook the new version dropped is expected, and
    // the refreshed count already excludes it.
    if (!hook) {
      if (requireAllPresent) fail(`hook disappeared before verification: ${key}`);
      continue;
    }
    if (hook.trustStatus !== "trusted") fail(`hook did not become trusted: ${key}`);
  }
  if (rejectNewTrusted) {
    const wantedSet = new Set(wanted);
    if (hooks.some((hook) => !wantedSet.has(hook.key) && hook.trustStatus === "trusted")) {
      fail("plugin update unexpectedly trusted a new or previously untrusted hook");
    }
  }
  return hooks;
}

function installedRecord(pluginId, codexExecutable) {
  // The CLI listing does not run Codex's marketplace startup sync (an app
  // server start does), so it reads the installed copy as it stands.
  return new Promise((resolve, reject) => {
    const child = spawnCodex(codexExecutable, ["plugin", "list", "--json"], {
      stdio: ["ignore", "pipe", "inherit"],
      windowsHide: true,
    });
    let out = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      out += chunk;
      if (out.length > 4 * 1024 * 1024) {
        terminateCodexChild(child);
        reject(new Error("codex plugin list output exceeded 4 MiB"));
      }
    });
    const timer = setTimeout(() => {
      terminateCodexChild(child);
      reject(new Error("codex plugin list timed out"));
    }, TIMEOUT_MS);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(`codex plugin list failed (${code ?? "signal"})`));
      try {
        const installed = JSON.parse(out)?.installed;
        if (!Array.isArray(installed)) throw new Error("shape");
        const record = installed.find((p) => p?.pluginId === pluginId && p?.installed !== false);
        resolve(
          record
            ? JSON.stringify({
                version: record.version ?? null,
                sha: record.source?.sha ?? null,
                kind: record.source?.source ?? null,
                path: record.source?.path ?? null,
              })
            : null,
        );
      } catch {
        reject(new Error("codex plugin list returned invalid JSON"));
      }
    });
  });
}

function marketplaceRevision(root) {
  try {
    const revision = JSON.parse(readFileSync(join(root, ".codex-marketplace-install.json"), "utf8"))?.revision;
    return typeof revision === "string" ? revision : null;
  } catch {
    return null;
  }
}

function codexJson(codexExecutable, args) {
  // A CLI listing (`codex plugin list`, `codex plugin marketplace list`):
  // neither starts an app server, so neither runs Codex's sync.
  return new Promise((resolve, reject) => {
    const child = spawnCodex(codexExecutable, args, { stdio: ["ignore", "pipe", "ignore"], windowsHide: true });
    let out = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      out += chunk;
      if (out.length > 4 * 1024 * 1024) terminateCodexChild(child);
    });
    const timer = setTimeout(() => {
      terminateCodexChild(child);
      reject(new Error(`codex ${args.join(" ")} timed out`));
    }, TIMEOUT_MS);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(`codex ${args.join(" ")} failed (${code ?? "signal"})`));
      try {
        resolve(JSON.parse(out));
      } catch {
        reject(new Error(`codex ${args.join(" ")} returned invalid JSON`));
      }
    });
  });
}

function catalogPluginsCurrent(root, marketplaceName, installed) {
  // Every ENABLED installed plugin from this marketplace is at the identity
  // the catalog at ROOT names for it: a pinned entry's `source.sha`, or, for
  // an in-repo entry, an installed tree byte-identical to the clone's plugin
  // tree (the same comparison approval uses — contents can change without a
  // version bump). An unpinned remote entry names no identity to wait for,
  // and is not waited on.
  let catalog;
  try {
    catalog = JSON.parse(readFileSync(join(root, ".agents", "plugins", "marketplace.json"), "utf8"));
  } catch {
    return false;
  }
  const entries = new Map((Array.isArray(catalog?.plugins) ? catalog.plugins : []).map((entry) => [entry?.name, entry]));
  for (const record of installed) {
    if (record?.marketplaceName !== marketplaceName || record?.installed === false || record?.enabled !== true) continue;
    const entry = entries.get(record.name);
    if (!entry) continue;
    const source = entry.source;
    if (source && typeof source === "object" && typeof source.sha === "string") {
      if (record.source?.sha !== source.sha) return false;
      continue;
    }
    const relative = typeof source === "string" ? source : source?.source === "local" ? source.path : null;
    if (typeof relative !== "string") continue;
    if (
      typeof record.version !== "string" ||
      [marketplaceName, record.name, record.version].some((part) => !part || part === "." || part === ".." || /[\\/]/.test(part))
    ) {
      return false;
    }
    const installedTree = join(process.env.CODEX_HOME || join(homedir(), ".codex"), "plugins", "cache", marketplaceName, record.name, record.version);
    if (!treesIdentical(installedTree, join(root, relative))) return false;
  }
  return true;
}

async function syncMarketplaces(targets, waitMs, codexExecutable) {
  // Codex syncs its Git marketplaces — and reinstalls the plugins installed
  // from them — in the background when an app server starts, and announces
  // nothing when it is done. It records the marketplace revision BEFORE it
  // reinstalls, so a root at its revision is not yet done: hold the server
  // open until each root records its revision AND every enabled plugin
  // installed from it is at that revision's catalog identity, or the
  // deadline passes. Read-only on our side: no request here changes anything.
  let names = new Map();
  try {
    const listed = await codexJson(codexExecutable, ["plugin", "marketplace", "list", "--json"]);
    const markets = Array.isArray(listed) ? listed : listed?.marketplaces ?? [];
    names = new Map(markets.map((market) => [market?.root, market?.name]));
  } catch {
    // An unreadable listing names no marketplace: every target stays missing.
  }
  return withAppServer(async () => {
    const deadline = Date.now() + waitMs;
    for (;;) {
      let installed = null;
      const missing = [];
      for (const [root, revision] of targets) {
        if (marketplaceRevision(root) !== revision || !names.get(root)) {
          missing.push(root);
          continue;
        }
        if (installed === null) {
          try {
            installed = (await codexJson(codexExecutable, ["plugin", "list", "--json"]))?.installed;
          } catch {
            installed = undefined;
          }
        }
        if (!Array.isArray(installed) || !catalogPluginsCurrent(root, names.get(root), installed)) missing.push(root);
      }
      if (!missing.length || Date.now() >= deadline) return missing;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }, codexExecutable);
}

function pluginInstalled(pluginId, codexExecutable) {
  return new Promise((resolve, reject) => {
    const child = spawnCodex(codexExecutable, ["plugin", "list", "--json"], {
      stdio: ["ignore", "pipe", "inherit"],
      windowsHide: true,
    });
    let out = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      out += chunk;
      if (out.length > 4 * 1024 * 1024) {
        terminateCodexChild(child);
        reject(new Error("codex plugin list output exceeded 4 MiB"));
      }
    });
    const timer = setTimeout(() => {
      terminateCodexChild(child);
      reject(new Error("codex plugin list timed out"));
    }, TIMEOUT_MS);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(`codex plugin list failed (${code ?? "signal"})`));
      try {
        const installed = JSON.parse(out)?.installed;
        resolve(Array.isArray(installed) &&
          installed.some((p) => p?.pluginId === pluginId && p?.installed !== false));
      } catch {
        reject(new Error("codex plugin list returned invalid JSON"));
      }
    });
  });
}

function runCodexPluginAdd(pluginId, codexExecutable) {
  return new Promise((resolve, reject) => {
    const child = spawnCodex(codexExecutable, ["plugin", "add", pluginId, "--json"], {
      stdio: ["ignore", "ignore", "inherit"],
      windowsHide: true,
    });
    const timer = setTimeout(() => {
      terminateCodexChild(child);
      reject(new Error("codex plugin add timed out"));
    }, 120_000);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`codex plugin add failed (${code ?? "signal"})`));
    });
  });
}

async function main() {
  if (process.argv[2] === "sync") {
    // sync [--codex-executable PATH] ROOT REVISION [ROOT REVISION ...]:
    // trigger Codex's own marketplace sync and report which roots reached
    // their revision. Exit non-zero when any did not, so nobody records a
    // revision Codex never reached.
    let pairs = process.argv.slice(3);
    let syncExecutable = "codex";
    if (pairs[0] === CODEX_EXECUTABLE_FLAG) {
      if (!pairs[1]) fail("usage: codex-plugin-hooks.mjs sync [--codex-executable PATH] ROOT REVISION ...");
      syncExecutable = pairs[1];
      pairs = pairs.slice(2);
    }
    if (!pairs.length || pairs.length % 2 || pairs.some((value) => !value)) {
      fail("usage: codex-plugin-hooks.mjs sync [--codex-executable PATH] ROOT REVISION [ROOT REVISION ...]");
    }
    const targets = [];
    for (let index = 0; index < pairs.length; index += 2) targets.push([pairs[index], pairs[index + 1]]);
    const waitMs = Number(process.env.ROUNDHOUSE_CODEX_SYNC_WAIT_MS || 30_000);
    const missing = await syncMarketplaces(targets, waitMs, syncExecutable);
    process.stdout.write(`${JSON.stringify({ synced: targets.length - missing.length, missing })}\n`);
    if (missing.length) process.exitCode = 75;
    return;
  }
  const [command, pluginId, ...rest] = process.argv.slice(2);
  let codexExecutable = "codex";
  if (rest.length === 2 && rest[0] === CODEX_EXECUTABLE_FLAG && rest[1]) {
    codexExecutable = rest[1];
  } else if (rest.length) {
    fail("usage: codex-plugin-hooks.mjs approve|update PLUGIN@MARKETPLACE");
  }
  if (!PLUGIN_ID.test(pluginId ?? "")) {
    fail("usage: codex-plugin-hooks.mjs approve|update PLUGIN@MARKETPLACE");
  }
  const cwd = process.cwd();
  if (command === "status") {
    // Read-only: how many of the plugin's hooks are trusted, modified (trusted
    // once, bytes since changed) and never trusted. Writes nothing.
    const hooks = await listHooks(pluginId, cwd, codexExecutable);
    const count = (status) => hooks.filter((hook) => hook.trustStatus === status).length;
    process.stdout.write(
      `${JSON.stringify({ pluginId, hooks: hooks.length, trusted: count("trusted"), modified: count("modified"), untrusted: count("untrusted") })}\n`,
    );
    return;
  }
  if (command === "approve" && process.env.ROUNDHOUSE_AUTOMATIC_HOOK_APPROVAL === "1") {
    // Automatic approval CARRIES EXISTING TRUST; it never grants new trust,
    // and it writes only hashes it verified. A hook never trusted before is
    // refused, always. A `modified` hook (trusted once, its bytes since
    // changed) is carried to its new hash only for the identity the caller
    // verified: ROUNDHOUSE_VERIFIED_SHA, and the Codex copy byte-identical to
    // ROUNDHOUSE_VERIFIED_TREE. Everything is decided in ONE app server
    // session, immediately before the write: the record's SHA, the two
    // trees, and a re-listing whose every hash must equal the snapshot's —
    // Codex may advance the copy at any moment, and the write records the
    // snapshot's hashes, never whatever is current. Any mismatch is 75 with
    // nothing written.
    const outcome = await withAppServer(async (server) => {
      const listNow = async () =>
        matchingPluginHooks(validateHooks(await server.request("hooks/list", { cwds: [cwd] }), cwd, pluginId), pluginId);
      const hooks = await listNow();
      if (hooks.some((hook) => hook.trustStatus === "untrusted")) {
        fail(`automatic approval refuses a hook that was never trusted: ${pluginId}`, 75);
      }
      const carrying = hooks.some((hook) => hook.trustStatus === "modified");
      const sha = process.env.ROUNDHOUSE_VERIFIED_SHA;
      const verifiedTree = process.env.ROUNDHOUSE_VERIFIED_TREE;
      const codexTree = process.env.ROUNDHOUSE_CODEX_TREE;
      if (carrying && (!sha || !verifiedTree || !codexTree)) {
        fail(`automatic approval refuses a locally modified hook: ${pluginId}`, 75);
      }
      const verifyIdentity = async () => {
        // Still the verified copy: the record at the verified SHA, its active
        // cache path the verified one, and its tree byte-identical.
        const record = await installedRecord(pluginId, codexExecutable);
        const parsed = record ? JSON.parse(record) : null;
        const [name, marketplace] = pluginId.split("@");
        const active = parsed && typeof parsed.version === "string"
          ? join(process.env.CODEX_HOME || join(homedir(), ".codex"), "plugins", "cache", marketplace, name, parsed.version)
          : null;
        // A git-sourced record names its SHA. A local (in-marketplace) one
        // names none: it must still be the source path the caller verified
        // inside the marketplace root, and the tree check below is its proof.
        const sourcePath = process.env.ROUNDHOUSE_CODEX_SOURCE_PATH;
        const atVerified = parsed && (parsed.sha === sha ||
          (parsed.kind === "local" && !parsed.sha && sourcePath && typeof parsed.path === "string" &&
            resolve(parsed.path) === resolve(sourcePath)));
        if (!atVerified || !active || resolve(active) !== resolve(codexTree)) {
          fail(`automatic approval refuses: ${pluginId} is no longer at the verified ${sha}`, 75);
        }
        if (!treesIdentical(codexTree, verifiedTree)) {
          fail(`automatic approval refuses: ${pluginId}'s Codex copy is not byte-identical to the verified tree`, 75);
        }
      };
      if (carrying) await verifyIdentity();
      if (!hooks.length) return { hooks };
      const again = await listNow();
      const snapshot = new Map(hooks.map((hook) => [hook.key, hook.currentHash]));
      if (again.length !== hooks.length || again.some((hook) => snapshot.get(hook.key) !== hook.currentHash)) {
        fail(`automatic approval refuses: ${pluginId}'s hooks changed under the trust check`, 75);
      }
      if (carrying) await verifyIdentity();
      // A sub-second window remains between this last check and the write;
      // closing it would need a lock on Codex itself, which no Codex API offers.
      await server.request("config/batchWrite", {
        edits: hooks.map((hook) => ({ keyPath: hookKeyPath(hook.key), value: hook.currentHash, mergeStrategy: "replace" })),
        filePath: null,
        expectedVersion: null,
        reloadUserConfig: true,
      });
      return { hooks };
    }, codexExecutable);
    if (!outcome.hooks.length) {
      if (!(await pluginInstalled(pluginId, codexExecutable))) fail(`plugin not installed: ${pluginId}`);
      process.stdout.write(`${JSON.stringify({ pluginId, approved: 0 })}\n`);
      return;
    }
    const keys = outcome.hooks.map((hook) => hook.key);
    await verifyTrust(pluginId, cwd, keys, false, true, codexExecutable);
    process.stdout.write(`${JSON.stringify({ pluginId, approved: keys.length })}\n`);
    return;
  }
  if (command === "approve") {
    const hooks = await listHooks(pluginId, cwd, codexExecutable);
    if (!hooks.length) {
      // A hookless plugin is the normal case, not an error: approve means
      // "trust whatever hooks this plugin currently ships", and zero is a
      // valid answer. Automation runs approve after every install/update
      // without knowing the hook count in advance. But zero hooks also
      // looks identical to "plugin not installed at all" (observed live:
      // a codex plugin remove/add cycle dropped a sibling plugin's
      // registration), so verify registration before calling it benign.
      if (!(await pluginInstalled(pluginId, codexExecutable))) fail(`plugin not installed: ${pluginId}`);
      process.stdout.write(`${JSON.stringify({ pluginId, approved: 0 })}\n`);
      return;
    }
    const keys = hooks.map((hook) => hook.key);
    await writeTrust(pluginId, cwd, keys, codexExecutable);
    await verifyTrust(pluginId, cwd, keys, false, true, codexExecutable);
    process.stdout.write(`${JSON.stringify({ pluginId, approved: keys.length })}\n`);
    return;
  }
  if (command === "update") {
    // The trust snapshot is taken through an app server, and starting one
    // runs Codex's marketplace sync, which may reinstall this plugin at new
    // bytes before the snapshot is read: its trusted hooks then read as
    // modified, and there is nothing honest left to carry over. Detect it
    // and say so rather than report a refresh that preserved nothing.
    const recordBefore = await installedRecord(pluginId, codexExecutable);
    const before = await listHooks(pluginId, cwd, codexExecutable);
    const recordAfter = await installedRecord(pluginId, codexExecutable);
    if (recordBefore !== recordAfter) {
      fail(
        `Codex advanced ${pluginId} before the trust snapshot (${recordBefore} -> ${recordAfter}); ` +
          "no hook trust was carried over — approve its hooks explicitly",
      );
    }
    // Only hooks this host had already trusted get re-trusted at their new
    // hashes. "modified" is the tampered-drift state — the content no longer
    // matches the trusted hash — and writeTrust stamps whatever hash is on disk
    // with no content comparison, so including it laundered a locally edited
    // hook into trusted whenever `codex plugin add` was a no-op. Drift is
    // resolved by an explicit `approve`, which is what "trust what it currently
    // ships" means.
    const keys = before
      .filter((hook) => hook.trustStatus === "trusted")
      .map((hook) => hook.key);
    await runCodexPluginAdd(pluginId, codexExecutable);
    await writeTrust(pluginId, cwd, keys, codexExecutable);
    const after = await verifyTrust(pluginId, cwd, keys, true, false, codexExecutable);
    process.stdout.write(
      `${JSON.stringify({ pluginId, refreshed: keys.filter((key) => after.some((hook) => hook.key === key)).length })}\n`,
    );
    return;
  }
  fail("usage: codex-plugin-hooks.mjs approve|update|status PLUGIN@MARKETPLACE | sync ROOT REVISION...");
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = error.exitCode ?? 1;
});
