# roundhouse self-check — the collection configuration and the fake home tree.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

test_file_mode() {
  t_mode "$1" 2>/dev/null || printf 'unknown\n'
}

cat >"$tmp/config.json" <<'JSON'
{
  "version": 1,
  "machines": {
    "test-host": {
      "platform": "macos",
      "transport": "local",
      "codex_host": "test-codex-host",
      "expected_hostname": "fixture-hostname",
      "expected_user": "fixture-user",
      "groups": ["development"],
      "package_managers": ["homebrew"],
      "dev_root": "~/dev"
    },
    "test-apt": {
      "platform": "linux",
      "transport": "local",
      "expected_hostname": "fixture-hostname",
      "expected_user": "fixture-user",
      "groups": ["development"],
      "package_managers": ["apt"],
      "dev_root": "~/dev"
    },
    "test-windows": {
      "platform": "windows",
      "transport": "codex-remote-control",
      "codex_host": "test-windows-host",
      "codex_control_project": "example",
      "expected_hostname": "test-windows-hostname",
      "expected_user": "test-windows-user",
      "groups": ["development"],
      "package_managers": ["winget"],
      "dev_root": "~/dev"
    },
    "test-ssh": {
      "platform": "macos",
      "transport": "ssh",
      "ssh_alias": "fake-host",
      "expected_hostname": "fixture-hostname",
      "expected_user": "fixture-user",
      "groups": ["development"],
      "package_managers": [],
      "dev_root": "~/dev"
    }
  },
  "projects": {
    "example": {
      "source": "git@github.com:owner/example.git",
      "path": "example",
      "groups": ["development"],
      "codex": true
    },
    "clone-example": {
      "source": "owner/clone-example",
      "path": "nested/clone-example",
      "groups": ["development"],
      "codex": false
    }
  },
  "handoff_project": "example",
  "capabilities": {
    "example-research": {
      "groups": ["development"],
      "requires_auth": ["test-auth", "native-test-auth"],
      "requires_artifacts": ["shared-agent-definition", "paths-only-agent-definition"],
      "codex": {"provider": "plugin", "source": "example"},
      "claude": {"provider": "skills-cli", "source": "example-source", "skill": "capability-example"}
    },
    "shared-example": {
      "groups": ["development"],
      "agents": ["codex", "claude"],
      "provider": "manual",
      "source": "manual",
      "name": "manual-example"
    },
    "other-group": {
      "groups": ["other"],
      "codex": {"provider": "plugin", "source": "must-not-appear"}
    }
  },
  "skill_roots": [
    {
      "id": "manual",
      "path": "~/.agents/skills",
      "agents": ["codex", "claude"],
      "groups": ["development"]
    }
  ],
  "agent_artifacts": [
    {
      "id": "shared-agent-definition",
      "path": "~/.agents/agents/example.md",
      "kind": "agent-definition",
      "agents": ["codex", "claude"],
      "groups": ["development"]
    },
    {
      "id": "empty-agent-definitions",
      "path": "~/.agents/empty-agents",
      "kind": "agent-definition",
      "agents": ["codex", "claude"],
      "groups": ["development"]
    },
    {
      "id": "paths-only-agent-definition",
      "paths": {
        "test-host": "~/.agents/agents/example.md",
        "test-apt": "~/.agents/agents/example.md",
        "test-windows": "~/.agents/agents/example.md",
        "test-ssh": "~/.agents/agents/example.md"
      },
      "kind": "agent-definition",
      "agents": ["codex", "claude"],
      "groups": ["development"]
    },
    {
      "id": "claude-settings",
      "path": "~/.claude/settings.json",
      "kind": "config",
      "format": "json",
      "settings": {
        "remoteControlAtStartup": true,
        "switchModelsOnFlag": false,
        "fallbackModel": null,
        "model": "fixture-model",
        "availableModels": ["fixture-model"]
      },
      "agents": ["claude"],
      "groups": ["development"]
    },
    {
      "id": "codex-settings",
      "path": "~/.codex/config.toml",
      "paths": {
        "test-host": "~/.codex/config.toml",
        "test-windows": "~/.codex/config.toml"
      },
      "kind": "config",
      "format": "toml",
      "settings": {
        "model": "fixture#model",
        "check_for_update_on_startup": true,
        "service_tier": null
      },
      "agents": ["codex"],
      "groups": ["development"]
    }
  ],
  "auth_artifacts": {
    "test-auth": {
      "path": "~/.test-auth",
      "strategy": "encrypted-install",
      "secret_ref": "op://test/item/value",
      "verify": ["auth-check", "login", "status"]
    },
    "native-test-auth": {
      "strategy": "reauth",
      "portability": "native-store",
      "verify": ["auth-check", "login", "status"],
      "reauth": ["auth-check", "login"]
    }
  }
}
JSON
jq --arg hostname "$(hostname)" --arg user "$(id -un)" '
  .machines["test-host"].expected_hostname = $hostname |
  .machines["test-host"].expected_user = $user |
  .machines["test-apt"].expected_hostname = $hostname |
  .machines["test-apt"].expected_user = $user |
  .machines["test-windows"].expected_hostname = $hostname |
  .machines["test-windows"].expected_user = $user |
  .machines["test-ssh"].expected_hostname = $hostname |
  .machines["test-ssh"].expected_user = $user
' "$tmp/config.json" >"$tmp/config.native.json"
mv "$tmp/config.native.json" "$tmp/config.json"
chmod 600 "$tmp/config.json"
config_hash=$(shasum -a 256 "$tmp/config.json" | awk '{print $1}')
printf 'super-secret-value\n' >"$tmp/home/.test-auth"
chmod 600 "$tmp/home/.test-auth"
mkdir -p "$tmp/home/.codex/plugins/cache/test-market/example/1.2.3/.codex-plugin" \
  "$tmp/home/.codex/plugins/cache/test-market/example/1.2.3/.claude-plugin" \
  "$tmp/home/.codex/plugins/cache/test-market/example/1.2.3/nested-fixture/.codex-plugin" \
  "$tmp/home/.codex/plugins/cache/test-market/example/0.9.0/.codex-plugin" \
  "$tmp/home/.codex/plugins/cache/plugin-eval/2f1a8948/fixtures/.codex-plugin" \
  "$tmp/home/.claude/plugins/cache/test-market/claude-example/2.0.0/.claude-plugin" \
  "$tmp/home/.claude/plugins/cache/test-market/claude-example/1.0.0/.claude-plugin" \
  "$tmp/home/.claude/plugins/cache/plugin-eval/fixture/ignored/1.0.0/.claude-plugin" \
  "$tmp/home/.agents/skills/manual-example" "$tmp/home/.agents/agents" "$tmp/home/.agents/empty-agents"
printf '%s\n' \
  '{"remoteControlAtStartup":false,"switchModelsOnFlag":false,"model":"fixture-model","unlistedSecret":"must-not-leak"}' \
  >"$tmp/home/.claude/settings.json"
printf '%s\n' "\"model\" = 'fixture#model' # quoted TOML key and literal string" \
  "'check_for_update_on_startup' = true" '[profile.fixture]' \
  'service_tier = "must-not-leak"' \
  >"$tmp/home/.codex/config.toml"
printf '{}\n' >"$tmp/home/.codex/plugins/cache/test-market/example/1.2.3/.codex-plugin/plugin.json"
printf '{}\n' >"$tmp/home/.codex/plugins/cache/test-market/example/1.2.3/.claude-plugin/plugin.json"
printf '{}\n' >"$tmp/home/.codex/plugins/cache/test-market/example/1.2.3/nested-fixture/.codex-plugin/plugin.json"
printf '{}\n' >"$tmp/home/.codex/plugins/cache/test-market/example/0.9.0/.codex-plugin/plugin.json"
printf '{}\n' >"$tmp/home/.codex/plugins/cache/plugin-eval/2f1a8948/fixtures/.codex-plugin/plugin.json"
printf '{}\n' >"$tmp/home/.claude/plugins/cache/test-market/claude-example/2.0.0/.claude-plugin/plugin.json"
printf '{}\n' >"$tmp/home/.claude/plugins/cache/test-market/claude-example/1.0.0/.claude-plugin/plugin.json"
printf '{}\n' >"$tmp/home/.claude/plugins/cache/plugin-eval/fixture/ignored/1.0.0/.claude-plugin/plugin.json"
printf '%s\n' '---' 'name: manual-example' 'description: Manual skill fixture.' '---' >"$tmp/home/.agents/skills/manual-example/SKILL.md"
printf '%s\n' '# Example agent' >"$tmp/home/.agents/agents/example.md"
printf '%s\n' '{"skills":{"locked-example":{"source":"https://user:lock-secret@example.invalid/repo","sourceUrl":"https://user:lock-secret@example.invalid/repo","skillPath":"skills/example","skillFolderHash":"abc","installedAt":"2026-01-01","updatedAt":"2026-01-02"},"capability-example":{"source":"example-source","sourceUrl":"example-source","skillPath":"skills/example","skillFolderHash":"def","installedAt":"2026-01-01","updatedAt":"2026-01-02"}}}' \
  >"$tmp/home/.agents/.skill-lock.json"
cp "$tmp/home/.agents/.skill-lock.json" "$tmp/skill-lock-fixture.json"
