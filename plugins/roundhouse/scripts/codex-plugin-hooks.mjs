#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const TIMEOUT_MS = 15_000;
const PLUGIN_ID = /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/;

function fail(message) {
  throw new Error(`codex-plugin-hooks: ${message}`);
}

function hookKeyPath(key) {
  const escaped = key.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  return `hooks.state."${escaped}".trusted_hash`;
}

class AppServer {
  constructor() {
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = "";
    this.child = spawn("codex", ["app-server", "--stdio"], {
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
        this.child.kill();
        return;
      }
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.rejectAll(new Error("app-server returned invalid JSON"));
        this.child.kill();
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
        this.child.kill();
      }, TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ method, id, params });
    });
  }

  async initialize() {
    await this.request("initialize", {
      clientInfo: {
        name: "machine_utilities",
        title: "Machine Utilities",
        version: "0.2.20",
      },
      capabilities: {},
    });
    this.send({ method: "initialized", params: {} });
  }

  async close() {
    if (this.child.exitCode != null) return;
    this.child.stdin.end();
    const exited = new Promise((resolve) => this.child.once("exit", resolve));
    const timer = setTimeout(() => this.child.kill(), 1_000);
    await exited;
    clearTimeout(timer);
  }
}

function validateHooks(result, cwd) {
  const row = result?.data?.find((entry) => entry?.cwd === cwd);
  if (!row || !Array.isArray(row.hooks)) fail("hooks/list returned an invalid result");
  if ((row.errors?.length ?? 0) || (row.warnings?.length ?? 0)) {
    fail("hook discovery returned warnings or errors");
  }
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

async function withAppServer(action) {
  const server = new AppServer();
  try {
    await server.initialize();
    return await action(server);
  } finally {
    await server.close();
  }
}

async function listHooks(pluginId, cwd) {
  return withAppServer(async (server) => {
    const hooks = validateHooks(await server.request("hooks/list", { cwds: [cwd] }), cwd);
    return matchingPluginHooks(hooks, pluginId);
  });
}

async function writeTrust(pluginId, cwd, wanted) {
  if (!wanted.length) return;
  await withAppServer(async (server) => {
    const hooks = validateHooks(await server.request("hooks/list", { cwds: [cwd] }), cwd);
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
  });
}

async function verifyTrust(pluginId, cwd, wanted, rejectNewTrusted) {
  const hooks = await listHooks(pluginId, cwd);
  const byKey = new Map(hooks.map((hook) => [hook.key, hook]));
  for (const key of wanted) {
    const hook = byKey.get(key);
    if (hook && hook.trustStatus !== "trusted") fail(`hook did not become trusted: ${key}`);
  }
  if (rejectNewTrusted) {
    const wantedSet = new Set(wanted);
    if (hooks.some((hook) => !wantedSet.has(hook.key) && hook.trustStatus === "trusted")) {
      fail("plugin update unexpectedly trusted a new or previously untrusted hook");
    }
  }
  return hooks;
}

function runCodexPluginAdd(pluginId) {
  return new Promise((resolve, reject) => {
    const child = spawn("codex", ["plugin", "add", pluginId, "--json"], {
      stdio: ["ignore", "ignore", "inherit"],
      windowsHide: true,
    });
    const timer = setTimeout(() => {
      child.kill();
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
  const [command, pluginId, ...rest] = process.argv.slice(2);
  if (!PLUGIN_ID.test(pluginId ?? "") || rest.length) {
    fail("usage: codex-plugin-hooks.mjs approve|update PLUGIN@MARKETPLACE");
  }
  const cwd = process.cwd();
  if (command === "approve") {
    const hooks = await listHooks(pluginId, cwd);
    if (!hooks.length) fail(`no hooks found for ${pluginId}`);
    const keys = hooks.map((hook) => hook.key);
    await writeTrust(pluginId, cwd, keys);
    await verifyTrust(pluginId, cwd, keys, false);
    process.stdout.write(`${JSON.stringify({ pluginId, approved: keys.length })}\n`);
    return;
  }
  if (command === "update") {
    const before = await listHooks(pluginId, cwd);
    const keys = before
      .filter((hook) => hook.trustStatus === "trusted" || hook.trustStatus === "modified")
      .map((hook) => hook.key);
    await runCodexPluginAdd(pluginId);
    await writeTrust(pluginId, cwd, keys);
    const after = await verifyTrust(pluginId, cwd, keys, true);
    process.stdout.write(
      `${JSON.stringify({ pluginId, refreshed: keys.filter((key) => after.some((hook) => hook.key === key)).length })}\n`,
    );
    return;
  }
  fail("usage: codex-plugin-hooks.mjs approve|update PLUGIN@MARKETPLACE");
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
