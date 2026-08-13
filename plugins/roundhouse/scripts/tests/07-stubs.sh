# roundhouse self-check — the stub PATH binaries, the exported fixture
# environment and the plugin cache.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

cat >"$tmp/bin/brew" <<'SH'
#!/usr/bin/env bash
[ "${BREW_FAIL:-0}" != 1 ] || exit 1
installed_version=2.50.0
[ -z "${BREW_STATE_FILE:-}" ] || [ ! -f "$BREW_STATE_FILE" ] ||
  installed_version=$(cat "$BREW_STATE_FILE")
if [ "${1:-}" = outdated ] && [ "${2:-}" = --json=v2 ]; then
  if [ "$installed_version" = 2.51.0 ]; then
    printf '%s\n' '{"formulae":[],"casks":[{"name":"visual-tool","current_version":"1.1.0"}]}'
  else
    printf '%s\n' '{"formulae":[{"name":"git","current_version":"2.51.0"}],"casks":[{"name":"visual-tool","current_version":"1.1.0"}]}'
  fi
  exit 0
fi
if [ "${1:-}" = upgrade ] && [ "${2:-}" = git ]; then
  [ -z "${BREW_EXEC_MARKER:-}" ] || : >"$BREW_EXEC_MARKER"
  printf '%s\n' "${BREW_UPGRADE_VERSION:-2.51.0}" >"$BREW_STATE_FILE"
  exit 0
fi
if [ "${1:-}" = list ] && [ "${2:-}" = --cask ] && [ "${3:-}" = --versions ]; then
  [ "${BREW_CASK_FAIL:-0}" != 1 ] || exit 1
  printf 'visual-tool 1.0.0\n'
  exit 0
fi
if [ "${1:-}" = list ] && [ "${2:-}" = --versions ]; then
  printf 'git %s\njq 1.7.1\n' "$installed_version"
  exit 0
fi
exit 1
SH
chmod +x "$tmp/bin/brew"

cat >"$tmp/bin/apt" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list ] && [ "${2:-}" = --upgradable ] || exit 64
[ "${APT_LIST_FAIL:-0}" != 1 ] || exit 1
printf '%s\n' \
  'Listing...' \
  'example/stable 2.0.0 amd64 [upgradable from: 1.0.0]' \
  'native-qualified/stable 2.0.0 amd64 [upgradable from: 1.0.0]' \
  'foreign-unqualified/stable 9.0.0 amd64 [upgradable from: 1.0.0]' \
  'foreign-explicit:i386/stable 3.0.0 i386 [upgradable from: 1.0.0]'
SH
chmod +x "$tmp/bin/apt"

cat >"$tmp/bin/dpkg" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --print-architecture ] || exit 64
printf '%s\n' amd64
SH
chmod +x "$tmp/bin/dpkg"

cat >"$tmp/bin/dpkg-query" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -W ] || exit 64
printf '%s\n' \
  'example	1.0.0' \
  'native-qualified:amd64	1.0.0' \
  'foreign-unqualified:i386	1.0.0' \
  'foreign-explicit:i386	1.0.0'
SH
chmod +x "$tmp/bin/dpkg-query"

cat >"$tmp/bin/jsm" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != upgrade ] || {
  [ -z "${AGENT_EXEC_MARKER:-}" ] || : >"$AGENT_EXEC_MARKER"
  exit 64
}
[ "${JSM_INVALID:-0}" != 1 ] || { printf '{invalid\n'; exit 0; }
[ "${JSM_INVALID_SHAPE:-0}" != 1 ] || { printf '%s\n' '{"skills":{"name":"bogus"}}'; exit 0; }
if [ "${JSM_OPTION_NAME:-0}" = 1 ]; then
  name=--danger
else
  name=example-jsm
fi
printf '%s\n' "{\"workspace\":\"default\",\"skills\":[{\"name\":\"$name\",\"version\":2,\"installed_at\":\"2026-01-02\",\"pinned\":false,\"update_available\":false,\"latest_version\":null,\"tags\":[\"ctx-testing\"],\"is_jeffreys\":true,\"is_saved\":true}]}"
SH
chmod +x "$tmp/bin/jsm"

cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
version=1.2.3
[ -z "${CODEX_STATE_FILE:-}" ] || [ ! -f "$CODEX_STATE_FILE" ] ||
  version=$(cat "$CODEX_STATE_FILE")
if [ "${1:-}" = app-server ] && [ "${2:-}" = --stdio ]; then
  while IFS= read -r request; do
    method=$(printf '%s\n' "$request" | jq -r '.method // empty')
    id=$(printf '%s\n' "$request" | jq -r '.id // empty')
    case $method in
      initialize)
        jq -cn --argjson id "$id" '{id:$id,result:{codexHome:"fixture"}}'
        ;;
      initialized) ;;
      hooks/list)
        cwd=$(printf '%s\n' "$request" | jq -r '.params.cwds[0]')
        scenario=${CODEX_HOOK_SCENARIO:-update}
        writes=${CODEX_HOOK_WRITES_FILE:-/nonexistent}
        if [ "$scenario" = warning ] || [ "$scenario" = error ] ||
          [ "$scenario" = unrelated-warning ] || [ "$scenario" = hookless ] ||
          [ "$scenario" = not-installed ]; then
          # Real discovery warnings name the offending hooks.json path; the
          # validator only treats warnings mentioning the target plugin as
          # fatal, so an unrelated plugin's warning must not block approval.
          jq -cn --argjson id "$id" --arg cwd "$cwd" \
            --arg scenario "$scenario" \
            '{id:$id,result:{data:[{cwd:$cwd,hooks:[],
              warnings:(if $scenario == "warning" then ["clamping hook timeout in cache/test-market/example/hooks.json"]
                elif $scenario == "unrelated-warning" then ["clamping hook timeout in cache/test-market/other/hooks.json"]
                else [] end),
              errors:(if $scenario == "error" then [{message:"fixture error"}] else [] end)}]}}'
          continue
        fi
        trusted_status=trusted
        modified_status=modified
        removed_status=trusted
        untrusted_status=untrusted
        if [ "$scenario" = approve ]; then
          trusted_status=untrusted
          modified_status=modified
          removed_status=untrusted
          [ ! -f "$writes" ] || {
            trusted_status=trusted
            modified_status=trusted
            removed_status=trusted
            untrusted_status=trusted
          }
        elif [ "$version" = 1.3.0 ] && [ -f "$writes" ]; then
          grep -q 'stable-trusted' "$writes" && trusted_status=trusted
          grep -q 'stable-modified' "$writes" && modified_status=trusted
        fi
        if [ "$version" = 1.3.0 ]; then
          stop_status=untrusted
          [ "$scenario" != approve ] || [ ! -f "$writes" ] || stop_status=trusted
          hooks=$(jq -cn \
            --arg trusted "$trusted_status" --arg modified "$modified_status" \
            --arg untrusted "$untrusted_status" --arg stop "$stop_status" '[
              {key:"example@test-market:hooks/hooks.json:session_start:0:0",pluginId:"example@test-market",currentHash:"sha256:stable-trusted-new",trustStatus:$trusted,enabled:false},
              {key:"example@test-market:hooks/hooks.json:post_tool_use:0:0",pluginId:"example@test-market",currentHash:"sha256:stable-modified-new",trustStatus:$modified,enabled:true},
              {key:"example@test-market:hooks/hooks.json:pre_tool_use:0:0",pluginId:"example@test-market",currentHash:"sha256:untrusted",trustStatus:$untrusted,enabled:true},
              {key:"example@test-market:hooks/hooks.json:stop:0:0",pluginId:"example@test-market",currentHash:"sha256:new",trustStatus:$stop,enabled:true},
              {key:"other@test-market:hooks/hooks.json:stop:0:0",pluginId:"other@test-market",currentHash:"sha256:other",trustStatus:"trusted",enabled:false}
            ]')
        else
          hooks=$(jq -cn \
            --arg trusted "$trusted_status" --arg modified "$modified_status" \
            --arg removed "$removed_status" --arg untrusted "$untrusted_status" '[
              {key:"example@test-market:hooks/hooks.json:session_start:0:0",pluginId:"example@test-market",currentHash:"sha256:stable-trusted-old",trustStatus:$trusted,enabled:false},
              {key:"example@test-market:hooks/hooks.json:post_tool_use:0:0",pluginId:"example@test-market",currentHash:"sha256:stable-modified-old",trustStatus:$modified,enabled:true},
              {key:"example@test-market:hooks/hooks.json:session_end:0:0",pluginId:"example@test-market",currentHash:"sha256:removed",trustStatus:$removed,enabled:true},
              {key:"example@test-market:hooks/hooks.json:pre_tool_use:0:0",pluginId:"example@test-market",currentHash:"sha256:untrusted",trustStatus:$untrusted,enabled:true},
              {key:"other@test-market:hooks/hooks.json:stop:0:0",pluginId:"other@test-market",currentHash:"sha256:other",trustStatus:"trusted",enabled:false}
            ]')
        fi
        jq -cn --argjson id "$id" --arg cwd "$cwd" --argjson hooks "$hooks" \
          '{id:$id,result:{data:[{cwd:$cwd,hooks:$hooks,warnings:[],errors:[]}]}}'
        ;;
      config/batchWrite)
        printf '%s\n' "$request" | jq -c '.params' >>"$CODEX_HOOK_WRITES_FILE"
        [ -z "${CODEX_HOOK_ORDER_FILE:-}" ] || printf '%s\n' approve >>"$CODEX_HOOK_ORDER_FILE"
        jq -cn --argjson id "$id" '{id:$id,result:{}}'
        ;;
      *) exit 64 ;;
    esac
  done
  exit 0
fi
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'codex fixture'
  exit 0
fi
if [ "${1:-}" = update ] && [ "$#" -eq 1 ]; then
  [ -z "${RUNTIME_UPDATE_MARKER:-}" ] || printf '%s\n' codex >"$RUNTIME_UPDATE_MARKER"
  exit 0
fi
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ] && [ "${3:-}" = --json ]; then
  [ "${CODEX_HOOK_SCENARIO:-}" != not-installed ] || { printf '%s\n' '{"installed":[]}'; exit 0; }
  [ "${CODEX_PLUGIN_LIST_INVALID:-0}" != 1 ] || { printf '{invalid\n'; exit 0; }
  [ "${CODEX_PLUGIN_LIST_INVALID_SHAPE:-0}" != 1 ] || {
    printf '%s\n' '{"installed":[{"pluginId":"broken@test-market","name":"broken","marketplaceName":"test-market","version":7,"installed":true,"enabled":"yes"}]}'
    exit 0
  }
  printf '{"installed":[{"pluginId":"example@test-market","name":"example","marketplaceName":"test-market","version":"%s","installed":true,"enabled":true,"source":{"source":"local","path":"fixture-codex-active"}},{"pluginId":"disabled-example@test-market","name":"disabled-example","marketplaceName":"test-market","version":"3.0.0","installed":true,"enabled":false,"source":{"source":"local","path":"fixture-codex-disabled"}}]}\n' "$version"
  exit 0
fi
if [ "${1:-}" = plugin ] && [ "${2:-}" = add ] &&
  [ "${3:-}" = example@test-market ] && [ "${4:-}" = --json ]; then
  [ -z "${AGENT_EXEC_MARKER:-}" ] || : >"$AGENT_EXEC_MARKER"
  printf '%s\n' 1.3.0 >"$CODEX_STATE_FILE"
  exit 0
fi
exit 64
SH
chmod +x "$tmp/bin/codex"
ln -s "$real_node" "$tmp/bin/node"

cat >"$tmp/bin/claude" <<SH
#!/usr/bin/env bash
version=2.0.0
[ -z "\${CLAUDE_STATE_FILE:-}" ] || [ ! -f "\$CLAUDE_STATE_FILE" ] ||
  version=\$(cat "\$CLAUDE_STATE_FILE")
if [ "\${1:-}" = --version ]; then
  printf '%s\n' 'claude fixture'
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\$#" -eq 1 ]; then
  [ -z "\${RUNTIME_UPDATE_MARKER:-}" ] || printf '%s\n' claude >"\$RUNTIME_UPDATE_MARKER"
  exit 0
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = marketplace ] &&
  [ "\${3:-}" = list ] && [ "\${4:-}" = --json ]; then
  [ -z "\${CLAUDE_PLUGIN_MARKETPLACE_FILE:-}" ] ||
    cat "\$CLAUDE_PLUGIN_MARKETPLACE_FILE"
  [ -n "\${CLAUDE_PLUGIN_MARKETPLACE_FILE:-}" ] || printf '%s\n' '[]'
  exit 0
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = marketplace ] &&
  [ "\${3:-}" = update ]; then
  [ -z "\${CLAUDE_MARKETPLACE_UPDATE_MARKER:-}" ] ||
    printf '%s\n' "\$4" >>"\$CLAUDE_MARKETPLACE_UPDATE_MARKER"
  exit 0
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = list ] &&
  { [ "\${3:-}" = --json ] ||
    { [ "\${3:-}" = --available ] && [ "\${4:-}" = --json ]; }; }; then
  [ "\${3:-}" != --available ] || [ "\${CLAUDE_PLUGIN_LIST_FAIL:-0}" != 1 ] || exit 75
  [ "\${3:-}" != --available ] || {
    [ -z "\${CLAUDE_PLUGIN_CATALOG_FILE:-}" ] || {
      cat "\$CLAUDE_PLUGIN_CATALOG_FILE"
      exit 0
    }
  }
  # Keep one canonical row per plugin: state mutations must be visible through
  # the same manager list the production code re-reads.
  enabled_file=\${CLAUDE_PLUGIN_ENABLED_FILE:-$tmp/plugin-enabled.json}
  enabled_file_set=\${CLAUDE_PLUGIN_ENABLED_FILE+x}
  fixed_id=claude-example@test-market
  fixed_enabled=true
  extra='[]'
  if [ -f "\$enabled_file" ]; then
    enabled_ledger=\$(jq -e -c 'if type == "object" then . else error("ledger") end' \
      "\$enabled_file") || { printf '%s\n' '[]'; exit 0; }
    fixed_enabled=\$(printf '%s\n' "\$enabled_ledger" | jq -r --arg id "\$fixed_id" \
      'if has(\$id) then .[\$id] else true end')
    extra=\$(printf '%s\n' "\$enabled_ledger" | jq -c --arg id "\$fixed_id" \
      'to_entries | map(select(.key != \$id) |
        {id: .key, version: "1.0.0", scope: "user", enabled: .value})')
  elif [ -n "\$enabled_file_set" ]; then
    printf '%s\n' '[]'
    exit 0
  fi
  printf '%s\n' "[{\"id\":\"claude-example@test-market\",\"version\":\"\$version\",\"scope\":\"user\",\"enabled\":true,\"installPath\":\"$tmp/home/.claude/plugins/cache/test-market/claude-example/\$version\",\"installedAt\":\"2026-01-03T04:05:06.000Z\",\"lastUpdated\":\"2026-01-04T05:06:07.000Z\"}]" |
    jq -c --argjson enabled "\$fixed_enabled" --argjson extra "\$extra" \
      '.[0].enabled = \$enabled | . + \$extra'
  exit 0
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = install ]; then
  [ -z "\${CLAUDE_INSTALL_MARKER:-}" ] || printf '%s\n' "\$3" >>"\$CLAUDE_INSTALL_MARKER"
  [ -z "\${CLAUDE_PLUGIN_ACTION_LOG:-}" ] || printf '%s %s\n' install "\$3" >>"\$CLAUDE_PLUGIN_ACTION_LOG"
  # A real install replaces the installed-plugin record with the catalog's
  # resolved identity. Simulate that here so a caller that re-reads
  # installed_plugins.json after installing sees a genuine post-install
  # state, not a stale fixture — CLAUDE_INSTALL_SKIP_RECORD opts a specific
  # scenario out, to prove that same re-read catches a no-op install.
  if [ -z "\${CLAUDE_INSTALL_SKIP_RECORD:-}" ] &&
    [ -n "\${CLAUDE_CONFIG_DIR:-}" ] &&
    [ -n "\${CLAUDE_PLUGIN_CATALOG_FILE:-}" ] && [ -f "\${CLAUDE_PLUGIN_CATALOG_FILE}" ]; then
    installed_file="\$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    mkdir -p "\$(dirname "\$installed_file")"
    [ -f "\$installed_file" ] || printf '{"version":2,"plugins":{}}\n' >"\$installed_file"
    resolved=\$(jq -c --arg id "\$3" '.available[] | select(.pluginId == \$id)' \
      "\$CLAUDE_PLUGIN_CATALOG_FILE")
    if [ -n "\$resolved" ]; then
      record=\$(printf '%s\n' "\$resolved" |
        jq -c '{scope:"user", version: .version, gitCommitSha: .source.sha}')
      jq -c --arg id "\$3" --argjson rec "\$record" \
        '.plugins[\$id] = ((.plugins[\$id] // []) | map(select(.scope != "user")) + [\$rec])' \
        "\$installed_file" >"\$installed_file.tmp" && mv "\$installed_file.tmp" "\$installed_file"
    fi
  fi
  exit 0
fi
if [ "\${1:-}" = plugin ] && { [ "\${2:-}" = enable ] || [ "\${2:-}" = disable ]; }; then
  [ -n "\${CLAUDE_INSTALL_MARKER:-}" ] || exit 64
  want=true
  [ "\$2" = enable ] || want=false
  [ -z "\${CLAUDE_PLUGIN_ACTION_LOG:-}" ] || printf '%s %s\n' "\$2" "\$3" >>"\$CLAUDE_PLUGIN_ACTION_LOG"
  enabled_file=\${CLAUDE_PLUGIN_ENABLED_FILE:-$tmp/plugin-enabled.json}
  fixed_id=claude-example@test-market
  ledger_id=\$3
  [ "\$ledger_id" != "\${fixed_id%@*}" ] || ledger_id=\$fixed_id
  [ -f "\$enabled_file" ] || printf '{}\n' >"\$enabled_file" 2>/dev/null || exit 1
  jq -e 'type == "object"' "\$enabled_file" >/dev/null 2>&1 || exit 1
  current=\$(jq -r --arg id "\$ledger_id" --arg fixed "\$fixed_id" '
    if has(\$id) then .[\$id]
    elif \$id == \$fixed then true
    else false
    end | tostring' "\$enabled_file") || exit 1
  [ "\$current" != "\$want" ] || exit 1
  jq -c --arg id "\$ledger_id" --argjson v "\$want" '.[\$id] = \$v' "\$enabled_file" \
    >"\$enabled_file.tmp" 2>/dev/null && mv "\$enabled_file.tmp" "\$enabled_file" || exit 1
  exit 0
fi
if [ "\${1:-}" = plugin ] && [ "\${2:-}" = update ] &&
  [ "\${4:-}" = --scope ] && [ "\${5:-}" = user ]; then
  if [ "\${3:-}" = claude-example@test-market ]; then
    [ -z "\${AGENT_EXEC_MARKER:-}" ] || : >"\$AGENT_EXEC_MARKER"
    printf '%s\n' 3.0.0 >"\$CLAUDE_STATE_FILE"
    [ "\${CLAUDE_MANAGER_STDOUT:-0}" != 1 ] ||
      printf '%s\n' 'manager progress must not enter JSONL'
  fi
  # Same post-install record simulation as the install stub above, keyed off
  # \$3 rather than the marketplace-refresh test's fixed ID: fleet-run's
  # existing-record path calls update, not install, and expects the same
  # catalog-resolved identity to land in installed_plugins.json.
  [ -z "\${CLAUDE_INSTALL_MARKER:-}" ] || printf '%s\n' "\$3" >>"\$CLAUDE_INSTALL_MARKER"
  [ -z "\${CLAUDE_PLUGIN_ACTION_LOG:-}" ] || printf '%s %s\n' update "\$3" >>"\$CLAUDE_PLUGIN_ACTION_LOG"
  if [ -z "\${CLAUDE_INSTALL_SKIP_RECORD:-}" ] &&
    [ -n "\${CLAUDE_CONFIG_DIR:-}" ] &&
    [ -n "\${CLAUDE_PLUGIN_CATALOG_FILE:-}" ] && [ -f "\${CLAUDE_PLUGIN_CATALOG_FILE}" ]; then
    installed_file="\$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    mkdir -p "\$(dirname "\$installed_file")"
    [ -f "\$installed_file" ] || printf '{"version":2,"plugins":{}}\n' >"\$installed_file"
    resolved=\$(jq -c --arg id "\$3" '.available[] | select(.pluginId == \$id)' \
      "\$CLAUDE_PLUGIN_CATALOG_FILE")
    if [ -n "\$resolved" ]; then
      record=\$(printf '%s\n' "\$resolved" |
        jq -c '{scope:"user", version: .version, gitCommitSha: .source.sha}')
      jq -c --arg id "\$3" --argjson rec "\$record" \
        '.plugins[\$id] = ((.plugins[\$id] // []) | map(select(.scope != "user")) + [\$rec])' \
        "\$installed_file" >"\$installed_file.tmp" && mv "\$installed_file.tmp" "\$installed_file"
    fi
  fi
  exit 0
fi
exit 64
SH
chmod +x "$tmp/bin/claude"

cat >"$tmp/bin/auth-check" <<'SH'
#!/usr/bin/env bash
[ "${AUTH_CHECK_SIGNAL_PARENT:-0}" != 1 ] || {
  [ -z "${AUTH_CHECK_SIGNAL_MARKER:-}" ] || : >"$AUTH_CHECK_SIGNAL_MARKER"
  kill -TERM "$PPID"
  sleep 1
  exit 143
}
[ "${AUTH_CHECK_FAIL:-0}" != 1 ] || exit 1
[ "${1:-}" = login ] && [ "${2:-}" = status ]
SH
chmod +x "$tmp/bin/auth-check"

cat >"$tmp/bin/op" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = read ] && [ "${2:-}" = "op://test/item/value" ] || exit 64
cat "$OP_SECRET_FILE"
SH
chmod +x "$tmp/bin/op"

cat >"$tmp/bin/winget" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
  upgrade)
    if [ "${WINGET_MODE:-valid}" = invalid ]; then
      printf '%s\n' 'Nom  Identifiant  Version  Disponible  Source' 'malformed row'
    else
      printf '%s\n' \
        'Name  Id  Version  Available  Source' \
        '----  --  -------  ---------  ------' \
        'Example  Example.Package  1.0.0  2.0.0  winget'
    fi
    ;;
  export)
    shift
    while [ $# -gt 0 ]; do
      case $1 in
        --output) output=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' \
      '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Example.Package","Version":"1.0.0"}]}]}' \
      >"$output"
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$tmp/bin/winget"

cat >"$tmp/bin/chezmoi" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
  source-path) printf '%s\n' "$HOME/.local/share/chezmoi" ;;
  status)
    if [ "${2:-}" = -- ]; then
      [ "$#" -gt 2 ] || exit 64
      if [ "${CHEZMOI_TARGET_STATUS_DRIFT:-0}" = 1 ] &&
        [ ! -e "${CHEZMOI_TARGET_APPLY_MARKER:-}" ]; then
        printf ' M %s\n' "$3"
      fi
    else
      [ "${CHEZMOI_STATUS_DRIFT:-0}" != 1 ] || printf ' M .zshrc\n'
    fi
    ;;
  --no-tty)
    [ "${2:-}" = apply ] || exit 64
    : >"$CHEZMOI_APPLY_MARKER"
    if [ "$#" -gt 2 ]; then
      [ "${3:-}" = -- ] && [ "$#" -gt 3 ] || exit 64
      : >"$CHEZMOI_TARGET_APPLY_MARKER"
    fi
    ;;
  git)
    [ "$#" -eq 4 ] && [ "${2:-}" = -- ] && [ "${3:-}" = pull ] &&
      [ "${4:-}" = --ff-only ] || exit 64
    # A successful pull fixture materializes the source tree just as the real
    # chezmoi command does. Earlier partial-inventory coverage removes it.
    source_path="$HOME/.local/share/chezmoi"
    mkdir -p "$(dirname "$source_path")"
    [ -d "$source_path/.git" ] ||
      "$REAL_GIT" clone -q -- "$GIT_CLONE_FIXTURE" "$source_path" || exit
    : >"$CHEZMOI_PULL_MARKER"
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$tmp/bin/chezmoi"

cat >"$tmp/bin/npx" <<'SH'
#!/usr/bin/env bash
[ -z "${AGENT_EXEC_MARKER:-}" ] || : >"$AGENT_EXEC_MARKER"
[ "$#" -eq 5 ] && [ "$1" = skills ] && [ "$2" = update ] &&
  [ "$3" = capability-example ] && [ "$4" = -g ] && [ "$5" = -y ] || exit 64
if [ "${SKILLS_UPDATE_TIMESTAMP_ONLY:-0}" = 1 ]; then
  jq '.skills."capability-example".updatedAt = "2026-02-03"' \
    "$HOME/.agents/.skill-lock.json" >"$HOME/.agents/.skill-lock.json.new"
  mv "$HOME/.agents/.skill-lock.json.new" "$HOME/.agents/.skill-lock.json"
elif [ "${SKILLS_UPDATE_NOOP:-0}" != 1 ]; then
  jq '.skills."capability-example".skillFolderHash = "updated-hash"' \
    "$HOME/.agents/.skill-lock.json" >"$HOME/.agents/.skill-lock.json.new"
  mv "$HOME/.agents/.skill-lock.json.new" "$HOME/.agents/.skill-lock.json"
fi
: >"$SKILLS_UPDATE_MARKER"
SH
chmod +x "$tmp/bin/npx"

cat >"$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" list-unit-files "*) printf 'fixture.service enabled\n' ;;
  *" is-active "*) printf 'inactive\n'; exit 3 ;;
  *" -p ExecStart "*) printf '{ path=/usr/bin/true ; argv[]=/usr/bin/true ; }\n' ;;
  *" -p Restart "*) printf 'no\n' ;;
  *" show "*) printf '\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/systemctl"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
original=$*
batch=false
tty=false
remote_command=false
connect=false
interval=false
count=false
stdin_null=false
while [ $# -gt 0 ]; do
  case $1 in
    -n) stdin_null=true; shift ;;
    -o)
      case $2 in
        BatchMode=yes) batch=true ;;
        RequestTTY=no) tty=true ;;
        RemoteCommand=none) remote_command=true ;;
        ConnectTimeout=10) connect=true ;;
        ServerAliveInterval=15) interval=true ;;
        ServerAliveCountMax=2) count=true ;;
      esac
      shift 2
      ;;
    *) shift; break ;;
  esac
done
[ "$batch" = true ] && [ "$tty" = true ] && [ "$remote_command" = true ] &&
  [ "$connect" = true ] && [ "$interval" = true ] && [ "$count" = true ] || exit 64
[ -z "${SSH_COMMAND_LOG:-}" ] || printf '%s\n' "$original" >>"$SSH_COMMAND_LOG"
[ $# -gt 0 ] || exit 64
[ "$stdin_null" = true ] && exec </dev/null
if [ "$1" = sh ]; then
  [ "${2:-}" = -s ] && [ "${3:-}" = -- ] || exit 64
  case ${4:-} in
    /tmp/roundhouse.*|/tmp/roundhouse-apply.*) ;;
    *) exit 64 ;;
  esac
  TMPDIR=/tmp "$@"
else
  [ $# -eq 1 ] || exit 64
  case $1 in
    *'mktemp -d /tmp/roundhouse-'*)
      remote_dir=$(TMPDIR=/tmp sh -c "$1")
      [ -z "${SSH_REMOTE_DIR_LOG:-}" ] || printf '%s\n' "$remote_dir" >"$SSH_REMOTE_DIR_LOG"
      printf '%s\n' "$remote_dir"
      ;;
    *) TMPDIR=/tmp sh -c "$1" ;;
  esac
fi
SH
chmod +x "$tmp/bin/ssh"

cat >"$tmp/bin/login-shell" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -lc ] && [ "$#" -eq 2 ] || exit 64
[ -z "${SSH_LOGIN_SHELL_LOG:-}" ] || printf '%s\n' "$2" >>"$SSH_LOGIN_SHELL_LOG"
exec sh -c "$2"
SH
chmod +x "$tmp/bin/login-shell"

cat >"$tmp/bin/scp" <<'SH'
#!/usr/bin/env bash
original=$*
batch=false
connect=false
interval=false
count=false
while [ $# -gt 0 ]; do
  case $1 in
    -q) shift ;;
    -o)
      case $2 in
        BatchMode=yes) batch=true ;;
        ConnectTimeout=10) connect=true ;;
        ServerAliveInterval=15) interval=true ;;
        ServerAliveCountMax=2) count=true ;;
      esac
      shift 2
      ;;
    *) break ;;
  esac
done
[ "$batch" = true ] && [ "$connect" = true ] &&
  [ "$interval" = true ] && [ "$count" = true ] || exit 64
[ -z "${SCP_COMMAND_LOG:-}" ] || printf '%s\n' "$original" >>"$SCP_COMMAND_LOG"
[ $# -eq 2 ] || exit 64
destination=${2#*:}
case $destination in
  /tmp/roundhouse.*/*|/tmp/roundhouse-apply.*/*) ;;
  *) exit 64 ;;
esac
cp "$1" "$destination"
SH
chmod +x "$tmp/bin/scp"

git -C "$tmp/home/dev/example" init -q
git -C "$tmp/home/dev/example" config user.email test@example.invalid
git -C "$tmp/home/dev/example" config user.name Test
printf 'ok\n' >"$tmp/home/dev/example/file.txt"
git -C "$tmp/home/dev/example" add file.txt
git -C "$tmp/home/dev/example" -c commit.gpgsign=false commit -qm initial
git -C "$tmp/home/dev/example" remote add origin ssh://user:secret@github.com/owner/example.git
git clone -q --bare "$tmp/home/dev/example" "$tmp/clone-example.git"
mkdir -p "$tmp/home/.local/share/chezmoi"
git -C "$tmp/home/.local/share/chezmoi" init -q
git -C "$tmp/home/.local/share/chezmoi" config user.email test@example.invalid
git -C "$tmp/home/.local/share/chezmoi" config user.name Test
printf 'managed\n' >"$tmp/home/.local/share/chezmoi/README.md"
git -C "$tmp/home/.local/share/chezmoi" add README.md
git -C "$tmp/home/.local/share/chezmoi" -c commit.gpgsign=false commit -qm initial

cat >"$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 4 ] && [ "$1" = clone ] && [ "$2" = -- ] &&
  [ "$3" = https://github.com/owner/clone-example.git ]; then
  "$REAL_GIT" clone -q -- "$GIT_CLONE_FIXTURE" "$4" &&
    "$REAL_GIT" -C "$4" remote set-url origin "$3"
  exit
fi
if [ "$#" -eq 4 ] && [ "$1" = -C ] && [ "$3" = pull ] && [ "$4" = --ff-only ]; then
  [ -z "${GIT_PULL_MARKER:-}" ] || : >"$GIT_PULL_MARKER"
  [ "${GIT_PULL_NOOP:-0}" != 1 ] || exit 0
  branch=$("$REAL_GIT" -C "$2" symbolic-ref --short HEAD)
  exec "$REAL_GIT" -C "$2" merge --ff-only "refs/remotes/origin/$branch"
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$tmp/bin/git"

export HOME="$tmp/home"
export PATH="$tmp/bin:/usr/bin:/bin"
export COMPUTERNAME
COMPUTERNAME=$(hostname)
export ROUNDHOUSE_CONFIG="$tmp/config.json"
# Every sync test hook (signature bypass, visibility probe, approval command)
# is inert without this; the suite is the only thing allowed to set it.
export ROUNDHOUSE_SELFTEST=1
export BREW_STATE_FILE="$tmp/brew-state"
export BREW_EXEC_MARKER="$tmp/brew-executed"
export OP_SECRET_FILE="$tmp/op-secret"
export CHEZMOI_APPLY_MARKER="$tmp/chezmoi-applied"
export CHEZMOI_PULL_MARKER="$tmp/chezmoi-pulled"
export CHEZMOI_TARGET_APPLY_MARKER="$tmp/chezmoi-target-applied"
export SKILLS_UPDATE_MARKER="$tmp/skills-updated"
export AGENT_EXEC_MARKER="$tmp/agent-executed"
export RUNTIME_UPDATE_MARKER="$tmp/runtime-updated"
export CODEX_STATE_FILE="$tmp/codex-state"
export CODEX_HOOK_WRITES_FILE="$tmp/codex-hook-writes.jsonl"
export CLAUDE_STATE_FILE="$tmp/claude-state"
export SSH_COMMAND_LOG="$tmp/ssh-commands"
export SCP_COMMAND_LOG="$tmp/scp-commands"
export SSH_REMOTE_DIR_LOG="$tmp/ssh-remote-dir"
export SSH_LOGIN_SHELL_LOG="$tmp/ssh-login-shell"
export SHELL="$tmp/bin/login-shell"
export REAL_GIT="$real_git"
export GIT_CLONE_FIXTURE="$tmp/clone-example.git"
export GIT_PULL_MARKER="$tmp/git-pull-executed"

printf '%s\n' 1.2.3 >"$CODEX_STATE_FILE"
approve_result=$(CODEX_HOOK_SCENARIO=approve \
  "$cli" approve-codex-plugin-hooks example@test-market)
[ "$(printf '%s\n' "$approve_result" | jq -r '.approved')" -eq 4 ] ||
  fail "explicit Codex plugin hook approval did not approve every current matching hook"
jq -e -s '
  length == 1 and
  (.[0].edits | length) == 4 and
  all(.[0].edits[];
    .mergeStrategy == "replace" and
    (.keyPath | startswith("hooks.state.\"example@test-market:")) and
    (.keyPath | endswith(".trusted_hash"))) and
  ([.[0].edits[].keyPath | select(contains("other@test-market") or endswith(".enabled"))] | length) == 0
' "$CODEX_HOOK_WRITES_FILE" >/dev/null ||
  fail "explicit Codex hook approval changed unrelated or non-trust state"

for hook_discovery_failure in warning error; do
  rm -f "$CODEX_HOOK_WRITES_FILE"
  if CODEX_HOOK_SCENARIO=$hook_discovery_failure \
    "$cli" approve-codex-plugin-hooks example@test-market >/dev/null 2>&1; then
    fail "Codex hook approval ignored hooks/list $hook_discovery_failure"
  fi
  [ ! -e "$CODEX_HOOK_WRITES_FILE" ] ||
    fail "Codex hook approval wrote trust after discovery $hook_discovery_failure"
done

for benign_scenario in unrelated-warning hookless; do
  rm -f "$CODEX_HOOK_WRITES_FILE"
  benign_result=$(CODEX_HOOK_SCENARIO=$benign_scenario \
    "$cli" approve-codex-plugin-hooks example@test-market) ||
    fail "Codex hook approval failed on benign $benign_scenario"
  [ "$(printf '%s\n' "$benign_result" | jq -r '.approved')" -eq 0 ] ||
    fail "Codex hook approval on $benign_scenario did not report approved:0"
  [ ! -e "$CODEX_HOOK_WRITES_FILE" ] ||
    fail "Codex hook approval wrote trust during benign $benign_scenario"
done

rm -f "$CODEX_HOOK_WRITES_FILE"
if CODEX_HOOK_SCENARIO=not-installed \
  "$cli" approve-codex-plugin-hooks example@test-market >/dev/null 2>&1; then
  fail "Codex hook approval reported success for an uninstalled plugin"
fi

rm -f "$CODEX_HOOK_WRITES_FILE"
printf '%s\n' 1.2.3 >"$CODEX_STATE_FILE"
update_result=$(CODEX_HOOK_SCENARIO=update \
  node "$script_dir/codex-plugin-hooks.mjs" update example@test-market)
[ "$(printf '%s\n' "$update_result" | jq -r '.refreshed')" -eq 1 ] ||
  fail "Codex plugin update did not refresh exactly the retained trusted hook"
[ "$(cat "$CODEX_STATE_FILE")" = 1.3.0 ] ||
  fail "Codex hook wrapper did not run the exact native plugin add"
jq -e -s '
  length == 1 and
  (.[0].edits | length) == 1 and
  any(.[0].edits[]; .keyPath | contains("session_start")) and
  ([.[0].edits[].keyPath |
    select(contains("session_end") or contains("pre_tool_use") or
      contains(":stop:") or contains("other@test-market") or endswith(".enabled"))] | length) == 0
' "$CODEX_HOOK_WRITES_FILE" >/dev/null ||
  fail "Codex plugin update trusted a removed, new, untrusted, unrelated, or enabled entry"
# "modified" is drift from the trusted hash, and writeTrust stamps whatever
# hash is on disk. Re-trusting it during update laundered a locally edited
# hook into trusted; only an explicit approve may do that.
jq -e -s '[.[0].edits[].keyPath | select(contains("post_tool_use"))] | length == 0' \
  "$CODEX_HOOK_WRITES_FILE" >/dev/null ||
  fail "Codex plugin update re-trusted a locally modified hook"

rm -f "$CODEX_HOOK_WRITES_FILE"
printf '%s\n' 1.2.3 >"$CODEX_STATE_FILE"

fake_darwin_bin="$tmp/fake-darwin-bin"
fake_darwin_home="$tmp/fake-darwin-home"
fake_darwin_jsonl="$tmp/fake-darwin.jsonl"
mkdir -p "$fake_darwin_bin" "$fake_darwin_home/Library/LaunchAgents"
: >"$fake_darwin_home/Library/LaunchAgents/01-broken.plist"
: >"$fake_darwin_home/Library/LaunchAgents/02-plutil-status.plist"
: >"$fake_darwin_home/Library/LaunchAgents/03-hash-failed.plist"
: >"$fake_darwin_home/Library/LaunchAgents/04-good.plist"
cat >"$fake_darwin_bin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
cat >"$fake_darwin_bin/plutil" <<'SH'
#!/usr/bin/env bash
case "${5:-}" in
  *01-broken.plist) exit 1 ;;
  *02-plutil-status.plist)
    printf '%s\n' '{"Label":"com.example.plutil-status","Program":"/usr/bin/example","RunAtLoad":true}'
    exit 1
    ;;
  *03-hash-failed.plist)
    printf '%s\n' '{"Label":"com.example.hash-failed","Program":"/usr/bin/example","RunAtLoad":true}'
    ;;
  *04-good.plist)
    printf '%s\n' '{"Label":"com.example.good","Program":"/usr/bin/example","RunAtLoad":true}'
    ;;
esac
SH
cat >"$fake_darwin_bin/launchctl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = print ] && printf 'last exit code = 7\n'
SH
real_sha256sum=$(command -v sha256sum || true)
if [ -n "$real_sha256sum" ]; then
  cat >"$fake_darwin_bin/sha256sum" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$FAKE_DARWIN_HOME/Library/LaunchAgents/03-hash-failed.plist" ]; then
  exit 1
fi
exec "$REAL_SHA256SUM" "$@"
SH
  export REAL_SHA256SUM="$real_sha256sum"
else
  real_shasum=$(command -v shasum)
  cat >"$fake_darwin_bin/shasum" <<'SH'
#!/usr/bin/env bash
if [ "${3:-}" = "$FAKE_DARWIN_HOME/Library/LaunchAgents/03-hash-failed.plist" ]; then
  exit 1
fi
exec "$REAL_SHASUM" "$@"
SH
  export REAL_SHASUM="$real_shasum"
fi
cat >"$fake_darwin_bin/crontab" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -l ] && printf '0 * * * * echo later\n'
SH
cat >"$fake_darwin_bin/find" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$FAKE_DARWIN_HOME/Library/LaunchAgents" ]; then
  printf '%s\n' "$FAKE_DARWIN_HOME/Library/LaunchAgents/01-broken.plist"
  printf '%s\n' "$FAKE_DARWIN_HOME/Library/LaunchAgents/02-plutil-status.plist"
  printf '%s\n' "$FAKE_DARWIN_HOME/Library/LaunchAgents/03-hash-failed.plist"
  printf '%s\n' "$FAKE_DARWIN_HOME/Library/LaunchAgents/04-good.plist"
fi
SH
chmod +x "$fake_darwin_bin"/*
if ! HOME="$fake_darwin_home" FAKE_DARWIN_HOME="$fake_darwin_home" \
  PATH="$fake_darwin_bin:$PATH" \
  ROUNDHOUSE_OBSERVED_AT=2026-01-01T00:00:00Z \
  "$script_dir/collect-posix" "$tmp/config.json" test-host fake-darwin startup \
  >"$fake_darwin_jsonl"; then
  fail "fake-Darwin launchd collection did not exit zero"
fi
PATH="$fake_darwin_bin:$PATH" "$cli" validate "$fake_darwin_jsonl"
jq -e -s '
  [ .[] | select(.kind == "startup_task") ] as $tasks |
  ($tasks | length) == 5 and
  ($tasks[0] | .status == "partial" and .id == "launchd-user:01-broken" and
    .data.label == "01-broken" and .data.definition_digest == null and
    (.data | has("program") | not) and .data.active == true and
    .data.last_result == 7 and .errors[0].code == "launchd_definition_parse_failed") and
  ($tasks[1] | .status == "partial" and .id == "launchd-user:02-plutil-status" and
    .data.label == "02-plutil-status" and .data.definition_digest == null and
    (.data | has("program") | not) and .errors[0].code == "launchd_definition_parse_failed") and
  ($tasks[2] | .status == "partial" and .id == "launchd-user:03-hash-failed" and
    .data.label == "03-hash-failed" and .data.definition_digest == null and
    (.data | has("program") | not) and .errors[0].code == "launchd_definition_parse_failed") and
  ($tasks[3] | .status == "present" and .id == "launchd-user:com.example.good" and
    .data.program == "/usr/bin/example" and .data.run_at_load == true and
    (.data.definition_digest.value | test("^[0-9a-f]{64}$"))) and
  ($tasks[4] | .status == "present" and .id == "cron:user" and
    .data.entry_count == 1)
' "$fake_darwin_jsonl" >/dev/null || fail "fake-Darwin launchd regression failed"
plugin_cache="$tmp/home/.codex/plugins/cache/novotnyllc/roundhouse/$plugin_version"
mkdir -p "$plugin_cache"
cp -R "$script_dir/../." "$plugin_cache/"
chmod -R go-w "$plugin_cache"
case ${ROUNDHOUSE_TEST_SCOPE:-} in
  u1-characterization|u1-contracts|u4-contracts|u5-contracts|macos-privilege-contracts)
    "$plugin_cache/scripts/update-integrity"
    cli="$plugin_cache/scripts/roundhouse"
    ;;
esac
printf '%s\n' 2.50.0 >"$BREW_STATE_FILE"
printf '%s\n' 1.2.3 >"$CODEX_STATE_FILE"
printf '%s\n' 2.0.0 >"$CLAUDE_STATE_FILE"
printf '%s\n' '{"portable":"session"}' >"$OP_SECRET_FILE"

[ "${ROUNDHOUSE_TEST_SCOPE:-}" != chezmoi-fixture ] || {
  rm -rf "$HOME/.local/share/chezmoi"
  "$tmp/bin/chezmoi" git -- pull --ff-only
  "$REAL_GIT" -C "$HOME/.local/share/chezmoi" rev-parse --verify HEAD >/dev/null &&
    [ -e "$CHEZMOI_PULL_MARKER" ] ||
    fail "successful chezmoi pull fixture did not materialize its source state"
  printf 'PASS: chezmoi pull fixture\n'
  exit 0
}
