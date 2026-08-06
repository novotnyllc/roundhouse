# Configuration reference

One JSON file describes your fleet: every machine, every project, every
capability, every credential, and — if you've opted in —
[fleet sync](skills/fleet-agents.md)'s own settings. `roundhouse
validate-config` checks it against a strict JSON Schema before anything
reads it, and that schema is stricter than "well-formed JSON": several
blocks reject *any* key they don't recognize, on top of checking the keys
they do.

## File location and resolution order

```
${ROUNDHOUSE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json}
```

1. If `ROUNDHOUSE_CONFIG` is set, that exact path is used — no XDG
   fallback, no further search.
2. Otherwise: `$XDG_CONFIG_HOME/roundhouse/config.json`.
3. If `XDG_CONFIG_HOME` isn't set either: `$HOME/.config/roundhouse/config.json`.

A sibling file, resolved the same way via `ROUNDHOUSE_IDENTITY` (falling
back to `.../roundhouse/identity.json`), holds this node's own signed
identity — separate from the fleet config, and validated separately when it
exists.

Every skill that touches config reads it through this same resolution —
there's no per-skill override. Scaffold a new one from the plugin's
`config.example.json`, or let `railyard:setup` interview you and write it.

## machines

`machines` is a required object, keyed by machine name (each key must
match `^[A-Za-z0-9._-]+$`), and it must have at least one entry.

| Field | Required | Shape |
| --- | --- | --- |
| `platform` | yes | one of `macos`, `linux`, `wsl`, `windows` |
| `transport` | yes | one of `local`, `ssh`, `codex-remote-control` |
| `ssh_alias` | when `transport: ssh` | string, `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` |
| `codex_host` | when `transport: codex-remote-control` | non-empty string |
| `codex_control_project` | no | non-empty id string that must name a real key in `projects` |
| `expected_hostname` | no | string, `^[A-Za-z0-9._-]+$` |
| `expected_user` | no | string, `^[A-Za-z0-9._@-]+$` |
| `groups` | no | array of id-pattern strings |
| `package_managers` | no | array of `homebrew`, `linuxbrew`, `apt`, `winget` |
| `dev_root` | — | free-form (not schema-validated; conventional value, e.g. `~/dev`) |
| `sync` | no | per-machine sync override, see below |
| `privilege_broker` | no | broker enrollment block, see below |
| `wsl_interop_via` | no | free-form (not schema-validated — see note) |
| `physical_host` | no | free-form (not schema-validated — see note) |

Cross-field rules the validator actually enforces:

- If `platform` is `windows`, `transport` **must** be
  `codex-remote-control` — there's no `local`/`ssh` path for native
  Windows.
- If `transport` is `codex-remote-control`, `platform` **must** be
  `windows` and `codex_host` is required.
- If `transport` is `ssh`, `ssh_alias` is required.
- If any `package_managers` entry is `winget`, `platform` must be
  `windows`. If any entry is `apt`, `platform` must be `linux` or `wsl`.

**`wsl_interop_via` and `physical_host` are real, documented fields —
[`fleet-hosts`](skills/fleet-hosts.md) and
[`fleet-inventory`](skills/fleet-inventory.md) both read and act on
them — but `validate-config`'s JSON Schema doesn't constrain either one.**
They pass through unvalidated: any string (or other JSON value) is
accepted. By convention, a Windows machine that shares hardware with a WSL
environment sets `wsl_interop_via` to the name of that WSL machine entry,
and both entries share the same `physical_host` string so tooling can
group them under one hardware heading. `config.example.json`'s `windows`
entry shows the shape:

```json
"wsl_interop_via": "<name-of-the-wsl-machine-on-the-same-host>",
"physical_host": "<shared-hardware-name>"
```

### Per-machine `sync` override

Optional, and — unlike most of this schema — an **exact-key-set** block:
only `enabled`, `store_path`, and `store_url` are allowed; anything else
fails validation. All three are individually optional:

- `enabled`: boolean.
- `store_path`: non-empty string.
- `store_url`: must pass the [sync URL predicate](#the-sync-url-predicate).

This lets one machine point at a different store or opt out of sync
without touching the top-level [`sync`](#sync) block.

### `privilege_broker`

Optional; also an **exact-key-set** block — only `automation_transport`
and `policy_proposal` are allowed.

- **`policy_proposal`** (optional): an array of *exactly* 12 strings, each
  1–512 printable-ASCII characters. Requires `platform` to be `linux`,
  `macos`, or `windows`.
- **`automation_transport`** (optional): requires `platform` is not
  `wsl`. Fields:
  - `host` — string, ≤255 chars, `^[A-Za-z0-9][A-Za-z0-9.:-]{0,254}$`
  - `port` — integer, 1–65535
  - `request_user` — string, `^[A-Za-z0-9._-]{1,128}$`
  - `pinned_host_key_fingerprint` — string, `^SHA256:[A-Za-z0-9+/]{43}=?$`
  - `management_networks` — array of 1–32 unique CIDR strings (IPv4 with a
    /0–/32 prefix and valid octets, or IPv6 with a /0–/128 prefix)
  - **On Windows**, `mode` must be `windows-sftp`, `port` must be `22`,
    `request_user` must be `RoundhouseRequest`, and the key set must
    additionally include `request_sid` (a Windows SID string) — *unless*
    the top-level [`worker`](#advanced-worker) block is present, in which
    case `request_sid` is dropped from the required set instead.
  - **On macOS/Linux**, `mode` must be `posix-ssh`, and the key set is
    exactly `host`, `management_networks`, `mode`,
    `pinned_host_key_fingerprint`, `port`, `request_user` — no
    `request_sid`.

  In every case the key set is checked exactly — an extra key here fails
  the same way an unknown key in `sync` does.

`config.example.json`'s `linux` and `windows` entries show both shapes.

## projects

`projects` is an object keyed by project name (`^[A-Za-z0-9._-]+$`). For
each entry, the schema validates only two fields:

- `source` — required, non-empty string, no `?`, and no URL userinfo
  unless it's exactly a `git@` prefix (so `owner/repo` and
  `git@host:owner/repo` pass; `https://user@host/...` doesn't).
- `path` — required, non-empty string; must not start with `/`, contain
  `\`, look like a Windows drive (`C:`), or contain a `..` path segment.

`groups` and `codex` (both present in `config.example.json`) are read by
skills but **not schema-validated** — any JSON value passes.

`handoff_project`, if present, must be a project-id string that names a
key that actually exists in `projects`.

## capabilities

`capabilities` is an object keyed by capability name
(`^[A-Za-z0-9._-]+$`). Each entry supports:

- `groups` — optional array of id-pattern strings.
- `requires_auth` — optional array of unique strings, each of which must
  name a key that exists in [`auth_artifacts`](#auth_artifacts).
- `requires_artifacts` — optional array of unique strings, each of which
  must name an `id` that exists somewhere in [`agent_artifacts`](#agent_artifacts).

Then one of two shapes for how the capability is provided:

**Shared across agents** — a top-level `agents` array (non-empty, unique,
each `"codex"` or `"claude"`) plus provider fields *directly on the
capability object*, and no `codex`/`claude` keys alongside it:

```json
"last30days": {
  "groups": ["development"],
  "requires_auth": ["xurl"],
  "agents": ["codex", "claude"],
  "provider": "skills-cli",
  "source": "mvanhorn/last30days-skill"
}
```

**Per-agent** — no top-level `agents`; instead a `codex` and/or `claude`
key, each an object with its own provider fields, and at least one of the
two present:

```json
"some-capability": {
  "codex": { "provider": "plugin", "source": "some-plugin" },
  "claude": { "provider": "plugin-source", "source": "some-repo" }
}
```

Either shape's provider object must satisfy the same rule:

- `provider` — one of `plugin`, `skills-cli`, `jsm`, `manual`,
  `plugin-source`.
- `source` — non-empty string, no `?`, no URL userinfo except a `git@`
  prefix; when `provider` is `plugin`, additionally must match
  `^[A-Za-z0-9][A-Za-z0-9._-]*$` and can't be `.` or `..`.
- `skill` and `name` — optional; if present, non-empty id-pattern strings.

## agent_artifacts

`agent_artifacts` is an array; every entry's `id` must be unique
(`^[A-Za-z0-9._-]+$`).

| Field | Required | Notes |
| --- | --- | --- |
| `id` | yes | unique across the array |
| `path` | see below | non-empty string |
| `paths` | see below | object; each key must name a real machine, each value a non-empty per-machine path |
| `kind` | yes | `agent-definition`, `instruction`, or `config` |
| `agents` | no | array of `codex`/`claude` |
| `groups` | no | array of id-pattern strings |
| `settings` | no | object; see the allowlist shape below |

An entry needs *one* of: a non-empty `path`, a non-empty `paths` map, or a
top-level [`worker`](#advanced-worker) block present in the config (worker
rendering supplies its own path).

### The `settings` allowlist shape

`settings` defaults to `{}`. If it's non-empty, the entry becomes a
strictly-checked config artifact:

- `kind` must be `config`, and `format` is required — `json` or `toml`.
- The artifact must be single-agent, and the pairing is fixed: `format:
  json` requires `agents == ["claude"]`; `format: toml` requires `agents
  == ["codex"]`. You can't mix Claude with `toml` or Codex with `json`.
- Every key in `settings` must come from the allowlist for that format —
  anything else fails:

  | Format | Allowed keys |
  | --- | --- |
  | `json` (Claude) | `remoteControlAtStartup`, `switchModelsOnFlag`, `model`, `effortLevel`, `availableModels`, `fallbackModel`, `autoUpdatesChannel`, `agentPushNotifEnabled` |
  | `toml` (Codex) | `model`, `model_reasoning_effort`, `service_tier`, `check_for_update_on_startup`, `cli_auth_credentials_store` |

- Each value's JSON encoding must be ≤8192 bytes.
- `null` is always valid for any key. Otherwise:
  - `remoteControlAtStartup`, `switchModelsOnFlag`, `agentPushNotifEnabled`,
    `check_for_update_on_startup` — boolean.
  - `availableModels` — array of non-empty strings.
  - `autoUpdatesChannel` — `"latest"` or `"stable"`.
  - `cli_auth_credentials_store` — `"file"`, `"keyring"`, or `"auto"`.
  - Everything else (`model`, `effortLevel`, `fallbackModel`,
    `model_reasoning_effort`, `service_tier`) — non-empty string.

`config.example.json`'s `codex-settings` and `claude-code-settings`
entries are the reference shapes for this — see the plugin's
`references/agent-settings-and-auth.md` for what each key actually does
at runtime. If `settings` is empty,
`format` is optional, and if present just has to be `json` or `toml` — none
of the pairing or allowlist rules apply.

## auth_artifacts

`auth_artifacts` is an object keyed by artifact id (`^[A-Za-z0-9._-]+$`).
Consumed by [`fleet-auth`](skills/fleet-auth.md).

| Field | Default | Notes |
| --- | --- | --- |
| `path` | — | non-empty string; entry needs this, a non-empty `paths`, or the pathless shape below |
| `paths` | `{}` | object; each key must name a real machine |
| `strategy` | `ignore` | `chezmoi`, `encrypted-install`, `reauth`, `ignore` |
| `portability` | `per-machine` | `declarative`, `secret-reference`, `portable-session`, `native-store`, `per-machine`, `regenerable-cache` |
| `mode` | `0600` | string matching `^0?[0-7]{3}$` |
| `max_bytes` | `10485760` (10 MiB) | number, `0 < n ≤ 104857600` (100 MiB) |
| `verify` | `[]` | array of ≤32 strings; if non-empty, element 0 must be a bare command name (`^[A-Za-z0-9._+-]+$`) |
| `reauth` | `[]` | array of ≤32 strings; same element-0 rule when non-empty |
| `secret_ref` | — | required when `strategy: encrypted-install` |

Rules the schema enforces beyond individual field shapes:

- **Pathless entries** (no `path`, no non-empty `paths`) are only valid
  when `portability` is `native-store` or `per-machine`, `strategy` is
  `reauth` or `ignore`, and `verify` is non-empty — this is the shape
  Codex and Claude Code's own session auth use in
  `config.example.json`, since neither has a config-managed file path.
- If `strategy` is `encrypted-install`: `secret_ref` is required and must
  start with `op://` and be longer than 5 characters; `mode` must be
  `"600"` or `"0600"`; `verify` must be non-empty.
- If `strategy` is `reauth`: `reauth` must be non-empty.

`xurl` in `config.example.json` is the `encrypted-install` reference
shape; `github-cli`, `codex`, and `claude-code` show `reauth`, including
`github-cli`'s Windows-specific `paths` override.

## policy

`policy` is copied through as-is — **it is not validated by
`validate-config`'s schema at all**, and no shipped skill references a
`policy.*` key by name in this codebase. `config.example.json` carries an
illustrative shape:

```json
"policy": {
  "updates": { "cleanup": false, "autoremove": false },
  "projects": { "update": "ff-only" }
}
```

Treat this as a forward-looking convention, not an enforced or currently
wired-up contract — flag any change to its meaning against the actual
skill behavior at the time, rather than assuming these keys already gate
something.

## sync

The top-level `sync` block turns on [fleet-wide desired-state
sync](skills/fleet-agents.md#desired-state-sync). It's optional — omit it
entirely and nothing about sync activates — but when present it is an
**exact-key-set** block: only `cadence_hours`, `canary_group`,
`canary_wait_hours`, `enabled`, `remote`, and `store_path` are allowed.

| Key | Required when `sync` present | Shape |
| --- | --- | --- |
| `enabled` | yes | boolean |
| `remote` | yes | object with *exactly* the key `url` |
| `remote.url` | yes | passes the [sync URL predicate](#the-sync-url-predicate) |
| `cadence_hours` | yes | number, `0 < n ≤ 8760` (one year) |
| `store_path` | no | non-empty string |
| `canary_group` | no | id-pattern string — registry group whose members are canary hosts for this fleet |
| `canary_wait_hours` | no | integer, `0 ≤ n ≤ 8760`; default `24` — how long a canary's healthy run must have stood before non-canary hosts adopt |

`enabled`, `remote`, and `cadence_hours` are unconditionally required the
moment the `sync` object exists at all — there's no "present but off"
shape beyond `enabled: false` itself. `config.example.json` ships exactly
that: `sync.enabled` is `false`, but `remote.url` and `cadence_hours` are
still filled in, because the schema requires them regardless.

### The sync URL predicate

Because `remote.url` (and a machine's `sync.store_url`) travels directly
into `git fetch` / `git remote add` as an argument, the schema accepts
only the forms it can fully reason about — no query strings, no whitespace,
and exactly three URL shapes:

- `https://` or `ssh://` **without embedded userinfo** — `https://github.com/owner/repo.git` passes; `ssh://git@host/path` does **not**, because the scheme form rejects any `@` in the remainder.
- **scp-like** `user@host:path` — this is where the SSH+userinfo case
  actually goes: `git@configured-git-host:owner/private-fleet-store.git`,
  exactly as `config.example.json` uses it.
- **A local path**, optionally prefixed `file://` — `/abs/path` or
  `file:///abs/path`.

Anything else — `ext::`, other custom transports, credential-bearing
URLs, or a string with a space or a `?` in it — is refused at config-load
time, before it ever reaches `git`.

## Other top-level keys

- **`version`** — required, must be exactly `1`.
- **`skill_roots`** — optional array (default `[]`) of skill-search
  locations. Each `id` must be unique; `path` is required non-empty;
  `manager` (default `manual`) is one of `manual`, `mixed`, `skills-cli`,
  `jsm`, `plugin-source`; `agents` and `groups` are optional arrays.
- **`handoff_project`** — see [projects](#projects) above.

### Advanced: `worker`

An optional object used by the Windows privileged-worker rendering
pathway (`roundhouse worker-config`) — it's machine-generated, not
something you hand-author alongside the rest of the file, and its
presence changes a couple of the `privilege_broker.automation_transport`
requirements noted above (dropping `request_sid`, and requiring
`.machines` to contain exactly the worker's own `target`). If you're
looking at a config with a `worker` block, treat it as generated output
tied to a specific broker rendering, not a template to copy by hand.

## A worked example

Trimmed from `config.example.json` — a two-machine fleet, one project, one
capability, sync turned on:

```json
{
  "version": 1,
  "machines": {
    "local": {
      "platform": "macos",
      "transport": "local",
      "groups": ["development"],
      "package_managers": ["homebrew"],
      "dev_root": "~/dev"
    },
    "remote-mac": {
      "platform": "macos",
      "transport": "ssh",
      "ssh_alias": "configured-ssh-alias",
      "expected_hostname": "configured-hostname",
      "expected_user": "configured-user",
      "groups": ["development"],
      "package_managers": ["homebrew"],
      "dev_root": "~/dev"
    }
  },
  "projects": {
    "example": {
      "source": "owner/example",
      "path": "example",
      "groups": ["development"],
      "codex": true
    }
  },
  "sync": {
    "enabled": true,
    "store_path": "~/.config/roundhouse/store",
    "remote": { "url": "git@configured-git-host:owner/private-fleet-store.git" },
    "cadence_hours": 24,
    "canary_group": "development"
  },
  "capabilities": {
    "roundhouse": {
      "groups": ["development"],
      "agents": ["codex", "claude"],
      "provider": "plugin",
      "source": "roundhouse"
    }
  },
  "agent_artifacts": [
    {
      "id": "claude-code-settings",
      "path": "~/.claude/settings.json",
      "kind": "config",
      "format": "json",
      "settings": { "remoteControlAtStartup": true, "fallbackModel": null },
      "agents": ["claude"],
      "groups": ["development"]
    }
  ],
  "auth_artifacts": {
    "github-cli": {
      "path": "~/.config/gh/hosts.yml",
      "strategy": "reauth",
      "portability": "per-machine",
      "mode": "0600",
      "verify": ["gh", "auth", "status"],
      "reauth": ["gh", "auth", "login"]
    }
  }
}
```

The full file — every machine shape, every capability shape, `windows`'s
`codex-remote-control` transport and `privilege_broker`, and the complete
`agent_artifacts`/`auth_artifacts` sets — is
`plugins/roundhouse/config.example.json` in the repository.

## Validation

```sh
roundhouse validate-config
```

reads the resolved config path, runs it through the full `jq` schema
described above, and exits non-zero with `roundhouse: invalid version 1
configuration: PATH` if anything fails — the failure message doesn't (by
design) say which clause; narrow it down by checking the block you just
edited against this page. Validation also checks the packaged privilege
policy file and every machine's `policy_proposal`, and — if an identity
file exists at the resolved identity path — validates that separately too.

**The exact-key-set philosophy.** Most of this schema is additive: unknown
keys on a `machine`, a `project`, or an `auth_artifact` entry are
ignored (which is how `dev_root`, `groups`, `codex`, `wsl_interop_via`,
and `physical_host` all pass through unvalidated in the blocks above).
Three parts of the schema are deliberately the opposite — the top-level
[`sync`](#sync) block, a machine's [`sync`](#per-machine-sync-override)
override, and [`privilege_broker.automation_transport`](#privilege_broker)
— checking `keys == [...]` (or `keys | sort == [...] | sort`) exactly.
Get one of those three blocks even slightly wrong — a typo'd key, an extra
field copied from a different example, a leftover key from a prior
version — and validation fails loudly at config-load time instead of the
extra key being silently ignored somewhere downstream. That's deliberate:
these three blocks gate either fleet-wide replication or a network
transport that reaches a privilege broker, and a silently-ignored unknown
key in either place is exactly the kind of drift this validator exists to
catch before it reaches a live host.

Every string anywhere in the document, at any depth, is also capped at
8192 characters and rejected if it contains a control character — a
blanket backstop, not specific to any one block.

## Where each block is consumed

| Block | Consuming skill |
| --- | --- |
| `machines` | every skill in this plugin |
| `projects`, `handoff_project` | [`fleet-projects`](skills/fleet-projects.md) |
| `capabilities`, `skill_roots`, `agent_artifacts` | [`fleet-agents`](skills/fleet-agents.md) |
| `auth_artifacts` | [`fleet-auth`](skills/fleet-auth.md) |
| top-level `sync`, machine `sync` | [`fleet-agents`](skills/fleet-agents.md)'s desired-state sync |
| `privilege_broker` | [`fleet-hosts`](skills/fleet-hosts.md) enrollment, consumed at apply time across `fleet-auth`, `fleet-chezmoi`, and `fleet-update` |
| `package_managers`, `policy` | [`fleet-update`](skills/fleet-update.md) |
