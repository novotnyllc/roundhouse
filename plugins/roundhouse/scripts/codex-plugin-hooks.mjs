#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, lstatSync, readdirSync, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { createInterface } from "node:readline";

const TIMEOUT_MS = 15_000;
// Marketplace clones can keep Codex busy during sync listings and startup.
const SYNC_TIMEOUT_MS = 60_000;
const PLUGIN_ID = /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/;
const CODEX_EXECUTABLE_FLAG = "--codex-executable";

function fail(message, exitCode = 1) {
  const error = new Error(`codex-plugin-hooks: ${message}`);
  error.exitCode = exitCode;
  throw error;
}

function treeEntries(root, { rejectEscapingLinks = false } = {}) {
  // Every regular file (bytes and owner-execute bit) and symlink (target, not
  // followed) under ROOT, by relative path — the same tree, with the same
  // exclusions, that apply-claude.sh's fleet_run_tree_digest hashes: any
  // `.git` is pruned, and the managers' markers at the root are not plugin
  // content: Claude's `.in_use` (file or per-session directory) and
  // `.orphaned_at`, and Codex's `.codex-marketplace-install.json`. Throws when
  // the tree cannot be read.
  const entries = new Map();
  const walk = (dir, rel) => {
    for (const name of readdirSync(dir)) {
      if (name === ".git") continue;
      const relPath = rel ? `${rel}/${name}` : name;
      if (!rel && (name === ".in_use" || name === ".orphaned_at" ||
        name === ".codex-marketplace-install.json")) continue;
      const full = join(dir, name);
      const stat = lstatSync(full);
      if (stat.isSymbolicLink()) {
        const target = readlinkSync(full);
        // Two installs can hold the same escaping link text and still resolve
        // it to different bytes, so carrying trust refuses any link whose
        // WHOLE chain does not end inside the root, on content the tree
        // compares (not under an excluded marker such as `.in_use`).
        if (rejectEscapingLinks) {
          const base = realpathSync(root);
          let to;
          try {
            to = realpathSync(full);
          } catch {
            throw new Error(`symlink does not resolve: ${relPath}`);
          }
          const inside = to.startsWith(base + sep) ? to.slice(base.length + 1) : null;
          const parts = inside === null ? [] : inside.split(sep);
          if (inside === null || parts.includes(".git") || [".in_use", ".orphaned_at",
            ".codex-marketplace-install.json"].includes(parts[0])) {
            throw new Error(`symlink escapes the compared plugin tree: ${relPath}`);
          }
        }
        entries.set(relPath, `link ${target}`);
      }
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

function treesIdentical(left, right, options = {}) {
  try {
    const a = treeEntries(left, options);
    const b = treeEntries(right, options);
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

function hookKeyPath(key, field = "trusted_hash") {
  const escaped = key.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  return `hooks.state."${escaped}".${field}`;
}

// Codex stores a compound hash `sha256:<command>/sha256:<script>` as two
// fields, trusted_hash and trusted_content_hash (what its own approval
// writes). The whole string in trusted_hash reads back as `modified`.
function trustEdits(hook) {
  const [command, content] = hook.currentHash.split("/");
  const edits = [{ keyPath: hookKeyPath(hook.key), value: command, mergeStrategy: "replace" }];
  if (content) edits.push({ keyPath: hookKeyPath(hook.key, "trusted_content_hash"), value: content, mergeStrategy: "replace" });
  return edits;
}

class AppServer {
  constructor(codexExecutable, timeoutMs = TIMEOUT_MS, onWarning) {
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = "";
    this.warnings = [];
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
      if (message.method === "warning" && typeof message.params?.message === "string") {
        onWarning?.(message.params.message);
        this.warnings.push(message.params.message.slice(0, 500));
        this.warnings = this.warnings.slice(-20);
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
      }, this.timeoutMs);
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

// A hook's hash is `sha256:...`, or, for a command hook that runs a script
// from its plugin, Codex's compound `sha256:<command>/sha256:<script>` (0.171
// and 0.172 both report impeccable's hooks that way). Each part is bounded,
// and only the two-part shape Codex stores (trustEdits) is accepted.
function validHookHash(hash) {
  if (typeof hash !== "string") return false;
  const parts = hash.split("/");
  return parts.length <= 2 && parts.every((part) => part.startsWith("sha256:") && part.length > 7 && part.length <= 128);
}

function matchingPluginHooks(hooks, pluginId) {
  const matching = hooks.filter((hook) => hook?.pluginId === pluginId);
  for (const hook of matching) {
    if (
      typeof hook.key !== "string" ||
      !hook.key.length ||
      hook.key.length > 8192 ||
      /[\u0000-\u001f\u007f]/.test(hook.key) ||
      !validHookHash(hook.currentHash) ||
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

async function withAppServer(action, codexExecutable, timeoutMs = TIMEOUT_MS, onWarning) {
  const server = new AppServer(codexExecutable, timeoutMs, onWarning);
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
      return hook ? trustEdits(hook) : [];
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

async function installedRecord(pluginId, codexExecutable) {
  // The CLI listing reads the installed copy without running startup sync.
  const installed = (await codexPluginList(codexExecutable, pluginId.split("@").at(-1)))?.installed;
  if (!Array.isArray(installed)) throw new Error("codex plugin list returned invalid JSON");
  const record = installed.find((p) => p?.pluginId === pluginId && p?.installed !== false);
  return record
    ? JSON.stringify({
        version: record.version ?? null,
        sha: record.source?.sha ?? null,
        kind: record.source?.source ?? null,
        path: record.source?.path ?? null,
      })
    : null;
}

function marketplaceRevision(root) {
  try {
    const revision = JSON.parse(readFileSync(join(root, ".codex-marketplace-install.json"), "utf8"))?.revision;
    return typeof revision === "string" ? revision : null;
  } catch {
    return null;
  }
}

function codexJson(codexExecutable, args, timeoutMs = TIMEOUT_MS) {
  // A CLI listing (`codex plugin list`, `codex plugin marketplace list`):
  // neither starts an app server, so neither runs Codex's sync.
  return new Promise((resolve, reject) => {
    const child = spawnCodex(codexExecutable, args, { stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    let out = "";
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr = (stderr + chunk).slice(-8192); });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      out += chunk;
      if (out.length > 4 * 1024 * 1024) terminateCodexChild(child);
    });
    const timer = setTimeout(() => {
      terminateCodexChild(child);
      reject(new Error(`codex ${args.join(" ")} timed out`));
    }, timeoutMs);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        const error = new Error(`codex ${args.join(" ")} failed (${code ?? "signal"})`);
        error.stderr = stderr;
        return reject(error);
      }
      try {
        resolve(JSON.parse(out));
      } catch {
        reject(new Error(`codex ${args.join(" ")} returned invalid JSON`));
      }
    });
  });
}

function marketplaceFilterUnsupported(error) {
  return /(?:unexpected|unrecognized|unknown|invalid)\s+(?:argument|option)[^\n]*(?:-m|--marketplace)/i.test(error.stderr || "");
}

async function codexPluginList(codexExecutable, marketplace) {
  try {
    return await codexJson(codexExecutable, ["plugin", "list", "--json", "-m", marketplace]);
  } catch (error) {
    if (!marketplaceFilterUnsupported(error)) throw error;
    return codexJson(codexExecutable, ["plugin", "list", "--json"]);
  }
}

// The catalog layouts Codex reads from a marketplace root, in its order.
const CATALOG_PATHS = [
  [".agents", "plugins", "marketplace.json"],
  [".agents", "plugins", "api_marketplace.json"],
  [".claude-plugin", "marketplace.json"],
  [".cursor-plugin", "marketplace.json"],
];

function readCatalog(root) {
  for (const parts of CATALOG_PATHS) {
    try {
      return JSON.parse(readFileSync(join(root, ...parts), "utf8"));
    } catch {
      // Absent or unreadable: try the next layout.
    }
  }
  return null;
}

function catalogPluginsCurrent(root, marketplaceName, installed) {
  // Every ENABLED installed plugin from this marketplace is at the identity
  // the catalog at ROOT names for it: a pinned entry's `source.sha`, or, for
  // an in-repo entry, an installed tree byte-identical to the clone's plugin
  // tree (the same comparison approval uses — contents can change without a
  // version bump). An unpinned remote entry names no identity to wait for:
  // it makes the root UNCONFIRMED rather than current. Returns "current",
  // "unconfirmed", or "pending".
  const catalog = readCatalog(root);
  if (catalog === null) return "pending";
  let unconfirmed = false;
  const entries = new Map((Array.isArray(catalog?.plugins) ? catalog.plugins : []).map((entry) => [entry?.name, entry]));
  for (const record of installed) {
    if (record?.marketplaceName !== marketplaceName || record?.installed === false || record?.enabled !== true) continue;
    const entry = entries.get(record.name);
    // Removed or renamed upstream: no identity to wait for, and nothing to
    // say the install is current either.
    if (!entry) {
      unconfirmed = true;
      continue;
    }
    const source = entry.source;
    if (source && typeof source === "object" && typeof source.sha === "string") {
      if (record.source?.sha !== source.sha) return "pending";
      continue;
    }
    const relative = typeof source === "string" ? source : source?.source === "local" ? source.path : null;
    if (typeof relative !== "string") {
      unconfirmed = true;
      continue;
    }
    if (
      typeof record.version !== "string" ||
      [marketplaceName, record.name, record.version].some((part) => !part || part === "." || part === ".." || /[\\/]/.test(part))
    ) {
      return "pending";
    }
    const installedTree = join(process.env.CODEX_HOME || join(homedir(), ".codex"), "plugins", "cache", marketplaceName, record.name, record.version);
    if (!treesIdentical(installedTree, join(root, relative))) return "pending";
  }
  return unconfirmed ? "unconfirmed" : "current";
}

// How long the server stays open for an unconfirmed root's reinstalls once
// everything confirmable is current: they cannot be awaited, only given time.
const UNCONFIRMED_GRACE_MS = Number(process.env.ROUNDHOUSE_CODEX_UNCONFIRMED_GRACE_MS || 10_000);

async function syncMarketplaces(targets, waitMs, codexExecutable) {
  // Codex syncs its Git marketplaces — and reinstalls the plugins installed
  // from them — in the background when an app server starts, and announces
  // nothing when it is done. It records the marketplace revision BEFORE it
  // reinstalls, so a root at its revision is not yet done: hold the server
  // open until each root records its revision AND every enabled plugin
  // installed from it is at that revision's catalog identity, or the
  // deadline passes. Read-only on our side: no request here changes anything.
  let names = new Map();
  let listingFailed = false;
  try {
    const listed = await codexJson(codexExecutable, ["plugin", "marketplace", "list", "--json"], SYNC_TIMEOUT_MS);
    const markets = Array.isArray(listed) ? listed : listed?.marketplaces ?? [];
    names = new Map(markets.map((market) => [market?.root, market?.name]));
  } catch {
    // Codex 0.17x fails the WHOLE listing when any configured marketplace has
    // no loadable snapshot (a clone it gave up on). Its Git snapshots live at
    // CODEX_HOME/.tmp/marketplaces/NAME, so name only roots in that layout;
    // the scoped plugin listing below still has to accept NAME. Anything
    // else stays unnamed, and missing.
    listingFailed = true;
    const store = join(process.env.CODEX_HOME || join(homedir(), ".codex"), ".tmp", "marketplaces");
    const canonical = (path) => {
      try { return realpathSync(path); } catch { return resolve(path); }
    };
    for (const [root] of targets) {
      const name = root.split(/[\\/]/).pop();
      if (/^[A-Za-z0-9._-]+$/.test(name) && !/^\.+$/.test(name) &&
        canonical(join(root, "..")) === canonical(store)) names.set(root, name);
    }
  }
  let scopedListing = true;
  const targetNames = new Set(targets.map(([root]) => names.get(root)).filter(Boolean));
  const failedNames = new Set();
  return withAppServer(async (server) => {
    const deadline = Date.now() + waitMs;
    let graceDeadline;
    const abandoned = (name) => failedNames.has(name);
    for (;;) {
      const listings = new Map();
      const listingDeadline = Date.now() + SYNC_TIMEOUT_MS;
      let wholeListing;
      const listWhole = () => {
        wholeListing ??= codexJson(codexExecutable, ["plugin", "list", "--json"],
          Math.max(1, listingDeadline - Date.now()));
        return wholeListing;
      };
      const useScopedListing = scopedListing;
      const wantedNames = new Set(targets.filter(([root, revision]) =>
        names.get(root) && !abandoned(names.get(root)) && marketplaceRevision(root) === revision)
        .map(([root]) => names.get(root)));
      // Independent snapshots share one polling budget; a slow marketplace
      // must not consume the outer bound before the others can be recorded.
      await Promise.all([...wantedNames].map(async (name) => {
        try {
          let listing;
          if (useScopedListing) {
            try {
              listing = await codexJson(codexExecutable, ["plugin", "list", "--json", "-m", name], SYNC_TIMEOUT_MS);
            } catch (error) {
              // Only an older CLI rejecting the filter gets the global
              // fallback. A broken snapshot must stay marketplace-local.
              if (!marketplaceFilterUnsupported(error)) throw error;
              scopedListing = false;
              listing = await listWhole();
            }
          } else listing = await listWhole();
          listings.set(name, listing?.installed);
        } catch {
          listings.set(name, undefined);
        }
      }));
      const missing = [];
      const unconfirmed = [];
      const reasons = new Map();
      for (const [root, revision] of targets) {
        const name = names.get(root);
        let reason;
        if (!name) reason = listingFailed ? "listing failed" : "not listed";
        else if (abandoned(name)) reason = "listing failed (Codex gave up updating the marketplace)";
        else if (marketplaceRevision(root) !== revision) reason = "revision mismatch";
        if (reason) {
          missing.push(root);
          reasons.set(root, reason);
          continue;
        }
        const installed = listings.get(name);
        const state = Array.isArray(installed) ? catalogPluginsCurrent(root, name, installed) : "pending";
        if (state === "pending" || abandoned(name)) {
          missing.push(root);
          reasons.set(root, Array.isArray(installed) ? "plugins pending" : "listing failed");
        }
        else if (state === "unconfirmed") unconfirmed.push(root);
      }
      const waiting = missing.some((root) => !abandoned(names.get(root)));
      if (!waiting && unconfirmed.length) {
        graceDeadline ??= Math.min(Date.now() + UNCONFIRMED_GRACE_MS, deadline);
        if (Date.now() < graceDeadline) {
          await new Promise((resolve) => setTimeout(resolve, Math.min(500, graceDeadline - Date.now())));
          continue;
        }
      }
      if (!waiting || Date.now() >= deadline) {
        for (const warning of server.warnings) process.stderr.write(`warning: ${warning.replaceAll(/[\r\n]/g, " ")}\n`);
        // One line per root, so a pass log says what happened to each.
        for (const [root, revision] of targets) {
          const status = missing.includes(root) ? `missing (${reasons.get(root)})`
            : unconfirmed.includes(root) ? "unconfirmed (synced; an enabled plugin has no pinned identity to wait for)"
            : "synced";
          process.stderr.write(`${root}: ${status}; revision seen ${marketplaceRevision(root) ?? "none"}, wanted ${revision}\n`);
        }
        return { missing, unconfirmed };
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }, codexExecutable, SYNC_TIMEOUT_MS, (warning) => {
    // Remember target failures independently of the bounded diagnostic tail.
    for (const name of targetNames) {
      if (warning.includes(`could not update marketplace \`${name}\``)) failedNames.add(name);
    }
  });
}

async function pluginInstalled(pluginId, codexExecutable) {
  const installed = (await codexPluginList(codexExecutable, pluginId.split("@").at(-1)))?.installed;
  return Array.isArray(installed) &&
    installed.some((p) => p?.pluginId === pluginId && p?.installed !== false);
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

// `codex plugin add` writes the cache under its caller's umask, and 002 (the
// WSL default) leaves it group-writable. Seal it BEFORE any hook is listed
// for trust or trust is written, or a group member could swap a hook in
// between and have its hash trusted: clear group/other write on every entry
// (a directory before its listing, so nothing new lands in it), and refuse
// (75) an entry another user owns, a cache root that is a symlink or not a
// directory, and a symlink whose whole chain does not end inside the sealed
// tree — a link is never followed by the seal, so its target could be bytes
// that stay mutable. The directories above it, up to CODEX_HOME, are sealed
// too: through a writable parent a peer could rename the sealed plugin
// directory and put another in its place. An absent cache is nothing to seal.
function sealPluginCache(pluginId) {
  if (process.platform === "win32") return;
  const [name, marketplace] = pluginId.split("@");
  const codexHome = process.env.CODEX_HOME || join(homedir(), ".codex");
  const uid = process.getuid();
  const refuse = (message) => fail(message, 75);
  const root = join(codexHome, "plugins", "cache", marketplace, name);
  let rootStat;
  try {
    rootStat = lstatSync(root);
  } catch (error) {
    if (error.code === "ENOENT") return;
    refuse(`plugin cache cannot be read: ${root}`);
  }
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory() || rootStat.uid !== uid) {
    refuse(`plugin cache is a symlink, not a directory, or owned by another user: ${root}`);
  }
  // Ancestors, top-down: CODEX_HOME itself may be reached through a symlink;
  // nothing below it may be one.
  const ancestors = [codexHome, join(codexHome, "plugins"), join(codexHome, "plugins", "cache"),
    join(codexHome, "plugins", "cache", marketplace)];
  for (const [index, dir] of ancestors.entries()) {
    let stat;
    try {
      stat = index === 0 ? statSync(dir) : lstatSync(dir);
    } catch {
      refuse(`a directory above the plugin cache cannot be read: ${dir}`);
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) refuse(`not a plain directory above the plugin cache: ${dir}`);
    if (stat.uid !== uid && stat.uid !== 0) refuse(`a directory above the plugin cache is owned by another user: ${dir}`);
    if (stat.mode & 0o022) {
      if (stat.uid === uid) {
        try {
          chmodSync(dir, stat.mode & 0o7755);
        } catch {
          // Checked below.
        }
      }
      if (statSync(dir).mode & 0o022) refuse(`a directory above the plugin cache is writable by others: ${dir}`);
    }
  }
  const base = realpathSync(root);
  const walk = (path) => {
    let stat;
    try {
      stat = lstatSync(path);
    } catch (error) {
      if (error.code === "ENOENT") return;
      refuse(`plugin cache entry cannot be read: ${path}`);
    }
    if (stat.isSymbolicLink()) {
      let to;
      try {
        to = realpathSync(path);
      } catch {
        refuse(`plugin cache symlink does not resolve: ${path}`);
      }
      if (!to.startsWith(base + sep)) refuse(`plugin cache symlink leaves the plugin tree: ${path}`);
      return;
    }
    if (stat.uid !== uid) refuse(`plugin cache entry is owned by another user: ${path}`);
    if (stat.mode & 0o022) {
      // An entry chmod cannot tighten (immutable, read-only mount) will not
      // tighten on a retry either: a standing refusal, not a transient one.
      try {
        chmodSync(path, stat.mode & 0o7755);
      } catch {
        refuse(`plugin cache entry is writable by others and cannot be sealed: ${path}`);
      }
    }
    if (stat.isDirectory()) {
      let names;
      try {
        names = readdirSync(path);
      } catch {
        refuse(`plugin cache directory cannot be listed: ${path}`);
      }
      for (const entry of names) walk(join(path, entry));
    }
  };
  walk(root);
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
    const requestedWait = Number(process.env.ROUNDHOUSE_CODEX_SYNC_WAIT_MS || 180_000);
    const waitMs = Number.isFinite(requestedWait) && requestedWait >= 0 ? requestedWait : 180_000;
    const { missing, unconfirmed } = await syncMarketplaces(targets, waitMs, syncExecutable);
    process.stdout.write(`${JSON.stringify({ synced: targets.length - missing.length, missing, unconfirmed })}\n`);
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
  if (command === "enabled" || command === "disabled") {
    await withAppServer((server) => server.request("config/batchWrite", {
      edits: [{ keyPath: `plugins."${pluginId}".enabled`, value: command === "enabled", mergeStrategy: "replace" }],
      filePath: null,
      expectedVersion: null,
      reloadUserConfig: true,
    }), codexExecutable);
    return;
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
    // Sealed before the first listing: a hook a peer could still swap
    // between this listing and the trust write is not the hook listed.
    sealPluginCache(pluginId);
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
        // Sealed first (umask 002 leaves it group-writable): bytes a group
        // member could still change after this check are not verified bytes.
        sealPluginCache(pluginId);
        if (!treesIdentical(codexTree, verifiedTree, { rejectEscapingLinks: true })) {
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
        edits: hooks.flatMap(trustEdits),
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
    sealPluginCache(pluginId);
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
    sealPluginCache(pluginId);
    await writeTrust(pluginId, cwd, keys, codexExecutable);
    const after = await verifyTrust(pluginId, cwd, keys, true, false, codexExecutable);
    process.stdout.write(
      `${JSON.stringify({ pluginId, refreshed: keys.filter((key) => after.some((hook) => hook.key === key)).length })}\n`,
    );
    return;
  }
  fail("usage: codex-plugin-hooks.mjs approve|update|status|enabled|disabled PLUGIN@MARKETPLACE | sync ROOT REVISION...");
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = error.exitCode ?? 1;
});
