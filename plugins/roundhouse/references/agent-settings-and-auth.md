# Agent settings and authentication

Inventory only the configured semantic allowlist. Never synchronize complete
Claude or Codex state directories: they mix portable preferences with machine
trust, project state, caches, MCP configuration, and credentials.

## Claude Code and Desktop

Claude Code CLI and the Claude Desktop Code surface share
`~/.claude/settings.json`. Configure these keys when desired:

- `remoteControlAtStartup: true` enables Remote Control for new Code sessions.
- `switchModelsOnFlag: false` disables the current client's safety-flag switch;
  it is a compatibility preference, not managed model enforcement.
- `fallbackModel: null` means the fallback key must be absent.
- `model` selects the initial model; explicit launch/user choices and service
  fallback can still override it. Avoid `opusplan`, which intentionally switches.
- `autoUpdatesChannel` selects `latest` or `stable`.

Do not copy `~/.claude.json` or Claude Desktop's internal application data.
Desktop and CLI authentication are distinct. Remote Control requires a full
interactive `claude auth login` on every host; setup tokens cannot enroll it.
Verify CLI login with `claude auth status --json`; the invoking agent must check
and report Desktop login manually because it is not in structured inventory.

Native Claude installations update automatically. `claude update` is the exact
manual updater. If the runtime is absent, use the current official installer or
the host's configured package manager; do not execute a downloaded installer
through a sealed fleet plan.

## Codex CLI and Desktop

Codex CLI, IDE, app server, and Desktop share `$CODEX_HOME/config.toml` (normally
`~/.codex/config.toml`). Safe documented inventory keys include `model`,
`model_reasoning_effort`, `service_tier`, `check_for_update_on_startup`, and
`cli_auth_credentials_store`. Do not inventory the entire TOML file because MCP
sections may contain secrets.

Codex stores unmanaged hook decisions under `[hooks.state]`. Treat that table as
machine-local trust state, not as an `agent_artifacts.settings` value and never
copy the whole table between machines. An explicit approval for an exact
`PLUGIN@MARKETPLACE` may be applied on each selected host with
`machine-utilities approve-codex-plugin-hooks PLUGIN@MARKETPLACE`. It uses a
fresh `codex app-server --stdio` session to discover the target's current hook
hashes, updates only matching `trusted_hash` leaves through `config/batchWrite`,
and verifies the result without changing `enabled` or unrelated entries.

Codex plugin updates preserve approval only for hook keys that were already
`trusted` or `modified` before the update. The wrapper runs the exact native
plugin add, refreshes only those same stable keys to their new current hashes,
and fails if a new or previously untrusted hook becomes trusted. New hook keys
always require a separate explicit approval.

There is no documented persistent setting that forces Codex Desktop Remote on.
Check and report Desktop host enablement and device pairing manually.
Signing out disables Remote until the user turns it on again. The experimental
`codex remote-control start|stop|pair --json` commands manage an app-server
daemon; they do not replace the Desktop host enrollment UI.

Use `codex update` for an installed CLI and the official installer or configured
package manager when it is absent. Verify login with `codex login status` and
reauthenticate with `codex login` or `codex login --device-auth` on a headless
host. File-backed `$CODEX_HOME/auth.json` may be provisioned only through an
approved encrypted secret channel and must be treated like a password; native
credential stores remain per-machine.

A pathless auth definition is status-only machine-local session inventory. It
does not prove that the tool uses an OS-native credential store.

Official references:

- <https://code.claude.com/docs/en/desktop#shared-configuration>
- <https://code.claude.com/docs/en/remote-control#enable-remote-control-for-all-sessions>
- <https://code.claude.com/docs/en/settings#available-settings>
- <https://code.claude.com/docs/en/model-config>
- <https://code.claude.com/docs/en/authentication>
- <https://code.claude.com/docs/en/installation>
- <https://learn.chatgpt.com/docs/config-file/config-reference>
- <https://learn.chatgpt.com/docs/auth>
- <https://learn.chatgpt.com/docs/remote-connections>
- <https://learn.chatgpt.com/docs/developer-commands?surface=cli>
