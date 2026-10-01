# roundhouse self-check — the Node runtime under the managed npm globals: fnm
# default convergence with global carry-over and post-switch hooks, the
# `runtimes.node` desired state (fast and full cadence), the sealed `fnm:node`
# lifecycle, and the Windows machine-scope hold.
#
# Everything runs against a stub fnm and a per-prefix stub npm inside a fixture
# fnm tree; neither the real fnm nor the real npm on the machine running the
# suite is reachable (FNM_DIR points at the fixture and the fixed
# Homebrew/system fallbacks are switched off).
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

printf 'node runtime: fnm default, carry-over, hooks, desired state, sealed switch\n'
nrt_root="$tmp/node-runtime-fixture"
nrt_fnm="$nrt_root/fnm"
nrt_bin="$nrt_root/bin"
nrt_template="$nrt_root/template"
nrt_log="$nrt_root/calls.log"
nrt_remote="$nrt_root/remote.txt"
nrt_catalog="$nrt_root/catalog.json"
# The store whose definitions state the hooks a sealed switch requires.
nrt_store="$nrt_root/sealed-store"
mkdir -p "$nrt_bin" "$nrt_template/bin" "$nrt_fnm/aliases" "$nrt_fnm/node-versions"

# node reports the version of the installation it physically lives in, so a
# child run under the wrong node is visible in every log line.
cat >"$nrt_template/bin/node" <<'SH'
#!/usr/bin/env bash
self=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)
[ "${1:-}" = --version ] && { basename -- "$(dirname -- "$(dirname -- "$self")")"; exit 0; }
exit 0
SH
# npm keeps its globals per PREFIX, exactly the fnm property the carry-over
# exists for: a new version starts empty.
cat >"$nrt_template/bin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
self_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)
prefix=$(dirname -- "$self_dir")
# `--prefix P` anywhere selects P, as real npm does.
args=()
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) prefix=$(CDPATH='' cd -P -- "$2" && pwd -P); shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
state=$prefix/globals.json
[ -f "$state" ] || printf '{}\n' >"$state"
printf 'npm %s node=%s prefix=%s\n' "$*" "$(node --version 2>/dev/null || printf none)" "$prefix" >>"$NRT_LOG"
case "$1 ${2:-}" in
  "prefix --global") printf '%s\n' "$prefix" ;;
  "root --global") printf '%s/lib/node_modules\n' "$prefix" ;;
  "ls --global")
    [ "${NRT_NPM_LS_FAIL:-0}" != 1 ] ||
      { printf '%s\n' '{"error":{"code":"ENOTDIR","summary":"prefix is not a directory"}}'; exit 1; }
    # NRT_NPM_LINKED adds an `npm link`ed global: file:-resolved, not
    # reinstallable by registry version.
    jq -c --arg linked "${NRT_NPM_LINKED:-}" '{name:"lib",dependencies:(with_entries(.value = {version:.value}) +
      (if $linked == "" then {} else {($linked): {version:"0.0.1",resolved:"file:../../dev/devtool"}} end))}' "$state" ;;
  "outdated --global")
    if [ -n "${NRT_NPM_OUTDATED:-}" ]; then printf '%s\n' "$NRT_NPM_OUTDATED"; else printf '{}\n'; fi
    ;;
  "uninstall --global")
    [ "${NRT_NPM_FAIL_UNINSTALL:-0}" != 1 ] || exit 1
    shift 2
    for name in "$@"; do
      jq --arg n "$name" 'del(.[$n])' "$state" >"$state.next"
      mv "$state.next" "$state"
      for bin in $(jq -r --arg n "$name" '(.[$n] // {}) | keys[]' "$NRT_CATALOG"); do
        rm -f "$prefix/bin/$bin"
      done
      rm -rf "${prefix:?}/lib/node_modules/$name"
    done
    ;;
  "install --global")
    [ "${NRT_NPM_FAIL_INSTALL:-0}" != 1 ] || exit 1
    shift 2
    for spec in "$@"; do
      case $spec in
        @*) name="@${spec#@}"; name="${name%@*}"; version="${spec##*@}" ;;
        *) name="${spec%@*}"; version="${spec##*@}" ;;
      esac
      jq --arg n "$name" --arg v "$version" '.[$n] = $v' "$state" >"$state.next"
      mv "$state.next" "$state"
      mkdir -p "$prefix/lib/node_modules/$name/bin" "$prefix/bin"
      jq -n --arg n "$name" --arg v "$version" --argjson bins \
        "$(jq -c --arg n "$name" '.[$n] // {}' "$NRT_CATALOG")" \
        '{name:$n,version:$v,bin:$bins}' >"$prefix/lib/node_modules/$name/package.json"
      cp "$NRT_PACKAGE_BIN" "$prefix/lib/node_modules/$name/bin/cli.js"
      chmod 755 "$prefix/lib/node_modules/$name/bin/cli.js"
      for bin in $(jq -r --arg n "$name" '(.[$n] // {}) | keys[]' "$NRT_CATALOG"); do
        ln -sfn "../lib/node_modules/$name/bin/cli.js" "$prefix/bin/$bin"
      done
    done
    ;;
  *) exit 64 ;;
esac
SH
# Every package bin is the same script: it records who ran it, under which
# node, and fails on request.
cat >"$nrt_root/package-bin" <<'SH'
#!/usr/bin/env bash
printf 'bin %s %s node=%s\n' "$(basename -- "$0")" "$*" "$(node --version)" >>"$NRT_LOG"
[ "${NRT_HOOK_FAIL:-0}" != 1 ] || exit 1
# A service repair that starts a daemon, which keeps the hook's stdout and
# stderr open long after the hook returns.
if [ -n "${NRT_HOOK_DAEMON:-}" ]; then
  sleep 600 &
  printf '%s\n' "$!" >"$NRT_HOOK_DAEMON"
fi
# A hook still running when another run looks: it waits for a release file.
if [ -n "${NRT_HOOK_WAIT:-}" ]; then
  printf 'waiting\n' >"$NRT_HOOK_WAIT.started"
  waited=0
  until [ -e "$NRT_HOOK_WAIT" ] || [ "$waited" -ge 600 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
fi
exit 0
SH
cat >"$nrt_bin/fnm" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'fnm %s dir=%s\n' "$*" "${FNM_DIR:-}" >>"$NRT_LOG"
case ${1:-} in
  --version) printf 'fnm 1.39.0\n' ;;
  list-remote)
    [ "${NRT_REMOTE_FAIL:-0}" != 1 ] || exit 1
    cat "$NRT_REMOTE"
    ;;
  install)
    [ "${NRT_FNM_FAIL_INSTALL:-0}" != 1 ] || exit 1
    dest=$FNM_DIR/node-versions/$2/installation
    if [ ! -d "$dest" ]; then
      mkdir -p "$dest/lib/node_modules/npm"
      cp -R "$NRT_TEMPLATE/bin" "$dest/bin"
      # The npm this release bundles (not a global the stub lists).
      printf '{"name":"npm","version":"%s"}\n' "${NRT_BUNDLED_NPM:-11.0.0}" \
        >"$dest/lib/node_modules/npm/package.json"
    fi
    ;;
  default)
    [ -d "$FNM_DIR/node-versions/$2/installation" ] || exit 1
    # Lets a fixture make the restore after a failed switch fail too.
    [ -z "${NRT_FNM_DEFAULT_ONLY:-}" ] || [ "$2" = "$NRT_FNM_DEFAULT_ONLY" ] || exit 1
    ln -sfn "$FNM_DIR/node-versions/$2/installation" "$FNM_DIR/aliases/default"
    ;;
  *) exit 64 ;;
esac
SH
chmod 755 "$nrt_template/bin/node" "$nrt_template/bin/npm" "$nrt_root/package-bin" "$nrt_bin/fnm"
printf '%s\n' '{"@example/svc":{"svc":"bin/cli.js"},"plain":{"plain":"bin/cli.js"},"unmanaged":{},"npm":{}}' \
  >"$nrt_catalog"
printf '%s\n' v24.1.0 'v24.2.0   (Krypton)' v25.0.0 v26.0.0 v26.2.0 v26.10.0 v27.0.0 'not-a-version' >"$nrt_remote"

# One fixture environment, for child commands (nrt_env) and for the lib-only
# subshell below (exported), so the two can never drift.
nrt_vars=(FNM_DIR="$nrt_fnm" NRT_LOG="$nrt_log" NRT_REMOTE="$nrt_remote"
  NRT_TEMPLATE="$nrt_template" NRT_CATALOG="$nrt_catalog" NRT_PACKAGE_BIN="$nrt_root/package-bin"
  XDG_STATE_HOME="$nrt_root/xdg-state" ROUNDHOUSE_TEST_NPM_FIXED_DIRS= ROUNDHOUSE_TEST_FNM_FIXED_DIRS=)
nrt_env() {
  env -u XDG_DATA_HOME "${nrt_vars[@]}" \
    ROUNDHOUSE_FLEET_STORE="${nrt_store_override:-$nrt_store}" PATH="$nrt_bin:$PATH" "$@"
}
# The switch state is at one fixed path under $HOME in every lane, never
# under XDG_STATE_HOME (set above to a directory that must stay unused).
nrt_state="$HOME/.local/state/roundhouse"
nrt_marker="$nrt_state/node-switch-inflight.json"
nrt_backoff="$nrt_state/node-switch-backoff.json"
nrt_lock="$nrt_state/node-switch.lock"

nrt_reset() {
  # One installed version, v26.0.0, as the default, carrying a managed
  # service package with a hook bin, a managed plain package, an unmanaged
  # global and npm itself.
  rm -rf "$nrt_fnm" "$nrt_marker" "$nrt_backoff" "$nrt_lock"
  mkdir -p "$nrt_fnm/aliases" "$nrt_fnm/node-versions"
  : >"$nrt_log"
  nrt_env "$nrt_bin/fnm" install v26.0.0
  nrt_env "$nrt_bin/fnm" default v26.0.0
  nrt_env PATH="$nrt_fnm/aliases/default/bin:$PATH" "$nrt_fnm/aliases/default/bin/npm" install --global \
    @example/svc@1.0.0 plain@2.0.0 unmanaged@0.1.0 npm@11.0.0
  : >"$nrt_log"
}
nrt_globals() {
  jq -c . "$nrt_fnm/node-versions/$1/installation/globals.json"
}
nrt_default() {
  basename -- "$(dirname -- "$(CDPATH='' cd -P -- "$nrt_fnm/aliases/default" && pwd -P)")"
}
nrt_reset

(
  set -eu
  unset XDG_DATA_HOME
  export "${nrt_vars[@]}"
  [ -z "$fleet_fixture_yq" ] || PATH=$fleet_fixture_path
  PATH=$nrt_bin:$PATH
  export PATH
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # --- versions and the desired-state grammar -------------------------------
  node_version_valid v26.10.0 || fail "a valid fnm version was refused"
  for nrt_bad in 26.10.0 v26 'v26.1.0 ' 'v26.1.0;x' v26.1.0-rc.1 ''; do
    if node_version_valid "$nrt_bad"; then fail "an invalid Node version was accepted: $nrt_bad"; fi
  done
  [ "$(node_version_normalize 26.7.0)" = v26.7.0 ] || fail "a bare Node version was not normalized"
  # One release comparison for Node and npm versions alike.
  release_newer v26.10.0 v26.2.0 || fail "Node versions compared as strings"
  release_newer 12.0.0 11.10.3 || fail "npm versions compared as strings"
  if release_newer v26.2.0 v26.10.0 || release_newer v26.2.0 v26.2.0 ||
    release_newer 12.0.0-rc.1 11.0.0 || release_newer 12.0.0 ''; then
    fail "an older, equal, prerelease or missing version read as newer"
  fi
  [ "$(node_runtime_spec '{"major":26}')" = '{"major":26,"version":null}' ] ||
    fail "a major line did not parse"
  [ "$(node_runtime_spec '{"major":"24"}')" = '{"major":24,"version":null}' ] ||
    fail "a quoted major line did not parse"
  [ "$(node_runtime_spec '{"version":"26.7.0"}')" = '{"major":26,"version":"v26.7.0"}' ] ||
    fail "an exact version pin did not parse into its major"
  [ "$(node_runtime_spec '{"major":26,"version":"v26.7.0","state":"enabled"}')" = \
    '{"major":26,"version":"v26.7.0"}' ] || fail "a consistent major and pin did not parse"
  for nrt_bad_spec in '"enabled"' '{}' '{"major":0}' '{"major":26.5}' '{"major":"26.x"}' \
    '{"version":"26"}' '{"major":24,"version":"26.7.0"}' '{"version":"latest"}'; do
    if node_runtime_spec "$nrt_bad_spec" >/dev/null; then
      fail "an unusable runtimes.node value was accepted: $nrt_bad_spec"
    fi
  done

  # --- fnm observation ------------------------------------------------------
  [ "$(node_fnm_root)" = "$nrt_fnm" ] || fail "the fnm root was not the durable npm's root"
  [ "$(node_fnm_default "$nrt_fnm")" = v26.0.0 ] || fail "the fnm default was not read from its alias"
  [ "$(node_fnm_remote_latest "$nrt_fnm" 26)" = v26.10.0 ] ||
    fail "the newest release in a major was not selected numerically"
  [ "$(node_fnm_remote_latest "$nrt_fnm" 24)" = v24.2.0 ] ||
    fail "an LTS line with a codename was not read"
  if NRT_REMOTE_FAIL=1 node_fnm_remote_latest "$nrt_fnm" 26 >/dev/null; then
    fail "a failed fnm list-remote read as a release"
  fi
  if node_fnm_remote_latest "$nrt_fnm" 99 >/dev/null; then
    fail "an unpublished major produced a release"
  fi
  if (FNM_DIR=$nrt_root/no-fnm HOME=$nrt_root/no-home node_fnm_root) >/dev/null; then
    fail "an fnm root without a default alias was accepted"
  fi

  # --- the switch: refusals change nothing ----------------------------------
  nrt_carry='[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"}]'
  nrt_hooks='[{"package":"npm:@example/svc","argv":["svc","service"]}]'
  nrt_status=0
  node_runtime_switch v26.10.0 '[{"name":"plain","version":"9.9.9"}]' '[]' 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 65 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    ! grep -Fq 'fnm install' "$nrt_log" ||
    fail "a carry of a version that is not installed was not refused before any change"
  nrt_status=0
  node_runtime_switch v26.10.0 "$nrt_carry" \
    '[{"package":"npm:plain","argv":["svc","service"]}]' 2>/dev/null || nrt_status=$?
  [ "$nrt_status" -eq 65 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    ! grep -Fq 'fnm install' "$nrt_log" ||
    fail "a hook that is not a bin of its package was not refused before any change"
  nrt_status=0
  node_runtime_switch v26.10.0 '[{"name":"plain","version":"2.0.0"}]' "$nrt_hooks" 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 65 ] || fail "a hook for a package that is not carried was not refused"
  nrt_status=0
  node_runtime_switch v26.10.0 "$nrt_carry" \
    '[{"package":"npm:@example/svc","argv":["svc","service; rm -rf ~"]}]' 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 64 ] || fail "a hook argument with shell syntax was not refused"

  # --- the switch: staging failures never move the default -------------------
  # The default moves only after the target is staged, so a failure before
  # that leaves it as it was: `fnm default` never ran, nothing was recorded.
  nrt_never_moved() {
    [ "$(nrt_default)" = v26.0.0 ] && ! grep -Fq 'fnm default ' "$nrt_log" && [ ! -e "$nrt_marker" ]
  }
  : >"$nrt_log"
  nrt_status=0
  NRT_NPM_FAIL_INSTALL=1 node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 1 ] && nrt_never_moved || fail "a failed carry moved the default (never moved)"
  ! grep -Fq 'bin svc' "$nrt_log" || fail "a hook ran after the carry failed"
  : >"$nrt_log"
  nrt_status=0
  NRT_FNM_FAIL_INSTALL=1 node_runtime_switch v26.2.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 1 ] && nrt_never_moved || fail "a failed fnm install moved the default (never moved)"
  # A failure after the flip (a hook) restores the old default, with proof,
  # and records the attempt so the reviewed apply does not repeat it.
  nrt_reset
  nrt_status=0
  NRT_HOOK_FAIL=1 node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 1 ] && [ "$(nrt_default)" = v26.0.0 ] && [ ! -e "$nrt_marker" ] ||
    fail "a failed post-switch hook did not restore the previous fnm default"
  node_switch_backoff_matches v26.10.0 "$nrt_carry" "$nrt_hooks" ||
    fail "a failed post-switch hook did not record its attempt for backoff"
  nrt_reset

  # --- the switch: a retained target is reconciled to exactly the carry ------
  # Old versions are kept, so a switch can land on a version used before. A
  # global still in that prefix but not carried (removed or disabled since)
  # is uninstalled; a rollback must not resurrect it.
  nrt_carry_all='[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"},{"name":"unmanaged","version":"0.1.0"}]'
  nrt_retain_target() {
    nrt_env "$nrt_bin/fnm" install v26.10.0
    nrt_env PATH="$nrt_fnm/node-versions/v26.10.0/installation/bin:$PATH" \
      "$nrt_fnm/node-versions/v26.10.0/installation/bin/npm" install --global stale-cli@9.0.0 plain@1.0.0
  }
  nrt_reset
  nrt_retain_target
  : >"$nrt_log"
  NRT_NPM_FAIL_UNINSTALL=1 node_runtime_switch v26.10.0 "$nrt_carry_all" "$nrt_hooks" 2>/dev/null &&
    fail "a switch that could not remove a stale global succeeded"
  nrt_never_moved || fail "a failed reconcile moved the default (never moved)"
  node_runtime_switch v26.10.0 "$nrt_carry_all" "$nrt_hooks" ||
    fail "a switch to a retained version failed"
  [ "$(nrt_default)" = v26.10.0 ] &&
    [ "$(nrt_globals v26.10.0)" = '{"plain":"2.0.0","@example/svc":"1.0.0","unmanaged":"0.1.0"}' ] ||
    fail "a retained target was not reconciled to exactly the carry"
  grep -Fq 'npm uninstall --global stale-cli' "$nrt_log" || fail "the stale global was not uninstalled"

  # --- the switch: success --------------------------------------------------
  nrt_reset
  node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" ||
    fail "a valid Node switch failed"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the switch did not move the fnm default"
  [ "$(nrt_globals v26.10.0)" = '{"@example/svc":"1.0.0","plain":"2.0.0"}' ] ||
    fail "the switch did not carry exactly the installed globals at their versions"
  grep -Fq "npm install --global @example/svc@1.0.0 plain@2.0.0 node=v26.10.0" "$nrt_log" ||
    fail "the carry was not one exact install under the new node"
  grep -Fq 'bin svc service node=v26.10.0' "$nrt_log" ||
    fail "the post-switch hook did not run under the new node"
  [ -x "$nrt_fnm/node-versions/v26.0.0/installation/bin/node" ] &&
    [ "$(jq -r '.unmanaged' "$nrt_fnm/node-versions/v26.0.0/installation/globals.json")" = 0.1.0 ] ||
    fail "the switch removed the old version or its globals"

  # --- the carry rule: every installed global, hooks by local trust ---------
  nrt_reset
  nrt_defs='{"packages":{
    "svc":{"npm":{"name":"@example/svc","node_switch":[["svc","service"]]}},
    "plain":{"npm":"plain"},
    "brewonly":{"homebrew":"brewonly"},
    "npm-off":{"npm":"unavailable","homebrew":"unmanaged"}}}'
  nrt_fold='{"packages":{"svc":"enabled","plain":{"state":"enabled"},"brewonly":"enabled","npm-off":"enabled","off":"disabled"},"runtimes":{"node":{"major":26}}}'
  nrt_globals_now=$(npm_global_list)
  [ "$(fleet_resolve_package "$nrt_defs" svc homebrew npm | jq -c '.attributes.node_switch')" = \
    '[["svc","service"]]' ] || fail "a declared node_switch hook did not ride through the resolver"
  nrt_status=0
  fleet_resolve_package '{"packages":{"bad-hook":{"npm":{"name":"plain","node_switch":["svc service"]}}}}' \
    bad-hook npm >/dev/null || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "a node_switch that is not a list of argv resolved"
  printf '%s\n' '{"version":1,"node_switch_hooks":{"npm:@example/svc":[["svc","service"],["svc","shim"]]}}' \
    >"$nrt_root/local-declared.json"
  printf '%s\n' '{"version":1}' >"$nrt_root/local-undeclared.json"
  printf '%s\n' '{"version":1,"node_switch_hooks":{"npm:@example/svc":[["svc","restart"]]}}' \
    >"$nrt_root/local-mismatched.json"
  nrt_plan_for() {
    # nrt_plan_for CONFIG [GLOBALS] [UNPINNABLE] [TARGET] [DEFS]
    node_switch_plan "$(jq -cn --argjson globals "${2:-$nrt_globals_now}" --argjson unpinnable "${3:-[]}" \
      '{globals: $globals, globals_unpinnable: $unpinnable}')" "${4:-v26.10.0}" "${5:-$nrt_defs}" \
      "$(jq -c '.node_switch_hooks // {}' "$nrt_root/$1.json")"
  }
  nrt_plan=$(nrt_plan_for local-declared)
  # Every installed global is carried, at its installed version, whatever the
  # desired state says about it (unmanaged, npm unavailable, disabled): only
  # npm itself is left to the new Node.
  [ "$(printf '%s\n' "$nrt_plan" | jq -c '.carry')" = \
    '[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"},{"name":"unmanaged","version":"0.1.0"}]' ] &&
    [ "$(printf '%s\n' "$nrt_plan" | jq -c '.excluded')" = '["npm"]' ] ||
    fail "the carry was not every installed global less what the new Node provides"
  # Local configuration may add host-only hooks; the definition's are a floor.
  [ "$(printf '%s\n' "$nrt_plan" | jq -c '[.hooks[].argv]')" = '[["svc","service"],["svc","shim"]]' ] &&
    [ "$(printf '%s\n' "$nrt_plan" | jq -c '.required')" = \
      '[{"package":"npm:@example/svc","argv":["svc","service"]}]' ] &&
    [ "$(printf '%s\n' "$nrt_plan" | jq -r '.held')" = null ] ||
    fail "the locally declared post-switch hooks were not planned"
  for nrt_local in local-undeclared local-mismatched; do
    nrt_plan_for "$nrt_local" |
      jq -e '.held | startswith("npm:@example/svc requires node_switch hook [\"svc\",\"service\"]")' >/dev/null ||
      fail "a store-only post-switch hook did not hold the switch ($nrt_local)"
  done
  # A malformed node_switch on a carried package holds; one on a package that
  # is not installed changes nothing.
  nrt_plan_for local-declared "$nrt_globals_now" '[]' v26.0.0 \
    '{"packages":{"bad-hook":{"npm":{"name":"plain","node_switch":["svc service"]}}}}' |
    jq -e '.held == "definitions.packages.bad-hook declares a malformed node_switch for the carried npm global plain"' \
    >/dev/null || fail "a malformed node_switch on a carried global did not hold the switch"
  nrt_plan_for local-declared "$nrt_globals_now" '[]' v26.0.0 \
    '{"packages":{"bad-hook":{"npm":{"name":"not-installed","node_switch":["svc service"]}}}}' |
    jq -e '.held == null' >/dev/null || fail "a malformed node_switch on an absent global held the switch"
  # What the TARGET provides is not carried; anything else is. corepack is
  # bundled with Node 24 and older only: a switch within 24 leaves it to the
  # new Node, a switch from 24 to 26 carries it (26 would not provide one),
  # and on 26 a corepack global was installed by someone and is carried.
  nrt_with_corepack=$(printf '%s\n' "$nrt_globals_now" | jq -c '. + {corepack:"0.30.0"}')
  nrt_plan_for local-declared "$nrt_with_corepack" '[]' v24.2.0 |
    jq -e '.excluded == ["corepack","npm"] and all(.carry[]; .name != "corepack")' >/dev/null ||
    fail "a switch to a corepack-bundling Node carried corepack"
  nrt_plan_for local-declared "$nrt_with_corepack" '[]' v26.10.0 |
    jq -e '.excluded == ["npm"] and any(.carry[]; . == {name:"corepack",version:"0.30.0"})' >/dev/null ||
    fail "a switch to a Node that does not bundle corepack dropped the installed corepack"
  # A global that cannot be reinstalled by exact registry version holds the
  # switch by name; it is never silently left behind.
  [ "$(NRT_NPM_LINKED=devtool node_globals_split "$(NRT_NPM_LINKED=devtool npm_global_list_detail)" |
    jq -c '.globals_unpinnable')" = '["devtool"]' ] ||
    fail "a file:/link global was not reported unpinnable"
  # A failed detail query is UNKNOWN, never "nothing unpinnable": it holds.
  nrt_plan_for local-declared "$nrt_globals_now" null |
    jq -e '.held | startswith("which npm globals cannot be reinstalled by exact registry version is unknown")' \
    >/dev/null || fail "an unknown unpinnable set did not hold the switch"
  nrt_plan_for local-declared "$nrt_globals_now" '["devtool"]' |
    jq -e '.held | startswith("npm globals devtool cannot be reinstalled by exact registry version")' \
    >/dev/null || fail "an unpinnable global did not hold the switch"

  # --- desired-state convergence ----------------------------------------------
  nrt_converge() {
    ROUNDHOUSE_CONFIG=$nrt_root/$1.json fleet_run_node_converge "$2" "$nrt_defs" "$3" \
      >"$nrt_root/converge-out" 2>&1
  }
  # A default already inside the declared major is the desired state on the
  # reviewed apply; nothing is fetched or switched.
  nrt_converge local-declared '{"major":26}' apply || fail "an in-line default did not converge"
  ! grep -Eq 'fnm (install|default|list-remote)' "$nrt_log" ||
    fail "the reviewed apply touched fnm for a default already in its major"
  # A linked global holds the switch before anything moves.
  nrt_status=0
  NRT_NPM_LINKED=devtool nrt_converge local-declared '{"major":26}' full || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq '  hold  runtimes.node — npm globals devtool cannot be reinstalled' "$nrt_root/converge-out" &&
    ! grep -Eq 'fnm (install|default) |npm install' "$nrt_log" ||
    fail "a switch ran while a linked global could not be carried"
  # A failed global inventory holds the switch before anything moves.
  nrt_status=0
  NRT_NPM_LS_FAIL=1 nrt_converge local-declared '{"major":26}' full || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq '  hold  runtimes.node — the npm global inventory under v26.0.0 failed' "$nrt_root/converge-out" &&
    ! grep -Eq 'fnm (install|default) |npm install' "$nrt_log" ||
    fail "a switch ran while the global inventory was unknown"
  # A store-only hook holds the switch and changes nothing.
  nrt_status=0
  nrt_converge local-undeclared '{"major":26}' full || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq '  hold  runtimes.node — npm:@example/svc requires node_switch hook' "$nrt_root/converge-out" ||
    fail "the full cadence switched without the host declaring the required hook"
  ! grep -Eq 'fnm (install|default) ' "$nrt_log" || fail "a held switch still ran fnm"
  # The full cadence moves to the newest release in the line.
  nrt_converge local-declared '{"major":26}' full || fail "the full cadence did not converge the line"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the full cadence did not move to the newest in-line release"
  grep -Fq '  switch runtimes.node v26.0.0 -> v26.10.0 (carrying @example/svc@1.0.0 plain@2.0.0 unmanaged@0.1.0)' \
    "$nrt_root/converge-out" || fail "the switch was not reported with its carry"
  grep -Fq 'bin svc shim node=v26.10.0' "$nrt_log" || fail "a host-only hook did not run"
  grep -Fq '  note  runtimes.node — not carried, provided by v26.10.0 itself: npm' \
    "$nrt_root/converge-out" || fail "what the new Node provides was not reported"
  grep -Fq '  note  runtimes.node — older Node versions remain installed (never removed here): v26.0.0' \
    "$nrt_root/converge-out" || fail "the old Node version was not reported as left installed"
  : >"$nrt_log"
  nrt_converge local-declared '{"major":26}' full || fail "a converged line did not stay converged"
  ! grep -Eq 'fnm (install|default) ' "$nrt_log" || fail "a converged line switched again"
  # An exact pin wins over the newest release, in both directions.
  nrt_converge local-declared '{"version":"26.2.0"}' apply || fail "an exact pin did not converge"
  [ "$(nrt_default)" = v26.2.0 ] || fail "the fnm default did not move to the pinned version"
  [ "$(nrt_globals v26.2.0)" = '{"@example/svc":"1.0.0","plain":"2.0.0","unmanaged":"0.1.0"}' ] ||
    fail "the pinned switch did not carry every installed global"
  : >"$nrt_log"
  nrt_converge local-declared '{"version":"26.2.0"}' full || fail "a satisfied pin did not converge"
  ! grep -Eq 'fnm (install|default|list-remote)' "$nrt_log" || fail "the full cadence moved a pinned runtime"
  # A new major, and an unreachable release list, and an unusable value.
  nrt_converge local-declared '{"major":27}' apply || fail "a major change did not converge"
  [ "$(nrt_default)" = v27.0.0 ] || fail "a major change did not switch to that line"
  nrt_status=0
  NRT_REMOTE_FAIL=1 nrt_converge local-declared '{"major":24}' apply || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v27.0.0 ] ||
    fail "an unreachable release list did not hold the switch"
  nrt_status=0
  nrt_converge local-declared '"enabled"' apply || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "a runtimes.node without major or version did not hold"
  nrt_status=0
  (FNM_DIR=$nrt_root/no-fnm HOME=$nrt_root/no-home \
    nrt_converge local-declared '{"major":26}' apply) || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "a host without an fnm default did not hold"

  # A corepack installed on 26 is carried to 26.x at its version.
  nrt_reset
  nrt_env PATH="$nrt_fnm/aliases/default/bin:$PATH" "$nrt_fnm/aliases/default/bin/npm" \
    install --global corepack@0.30.0
  nrt_converge local-declared '{"major":26}' full || fail "a switch with corepack installed did not converge"
  [ "$(jq -r '.corepack' "$nrt_fnm/node-versions/v26.10.0/installation/globals.json")" = 0.30.0 ] ||
    fail "an installed corepack was not carried to a Node that does not bundle it"
  # From a corepack-bundling 24 to 26, which bundles none: the installed
  # corepack is carried from the registry at its version, not dropped.
  nrt_reset
  nrt_env "$nrt_bin/fnm" install v24.1.0
  nrt_env "$nrt_bin/fnm" default v24.1.0
  nrt_env PATH="$nrt_fnm/aliases/default/bin:$PATH" "$nrt_fnm/aliases/default/bin/npm" \
    install --global corepack@0.30.0 npm@10.9.0
  nrt_converge local-declared '{"major":26}' apply || fail "a 24 to 26 switch did not converge"
  [ "$(nrt_default)" = v26.10.0 ] &&
    [ "$(nrt_globals v26.10.0)" = '{"corepack":"0.30.0"}' ] ||
    fail "a switch off a corepack-bundling Node dropped the installed corepack"

  # --- the category arm, and the manual fleet-apply path ------------------------
  nrt_status=0
  fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.python '{"major":3}' \
    "homebrew npm" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "an unmanaged runtime name did not hold"
  nrt_status=0
  fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '"disabled"' \
    "homebrew npm" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 70 ] || fail "a disabled runtimes.node was not satisfied"
  [ -z "$(fleet_unknown_categories '{"runtimes":{"node":{"major":26}}}')" ] ||
    fail "runtimes is not a known category"
  # `fleet-apply runtimes.node` has no fold and no run holds, and needs
  # neither: it carries everything installed.
  nrt_reset
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '{"major":27}' \
    "homebrew npm" >/dev/null 2>&1 || fail "the manual runtimes.node apply did not converge"
  [ "$(nrt_default)" = v27.0.0 ] &&
    [ "$(nrt_globals v27.0.0)" = '{"@example/svc":"1.0.0","plain":"2.0.0","unmanaged":"0.1.0"}' ] ||
    fail "the manual runtimes.node apply did not carry everything installed"

  # --- the full cadence runs the runtime before the npm pass --------------------
  nrt_reset
  nrt_run_full() {
    (
      fleet_trust_prune_expired() { :; }
      fleet_records_age() { :; }
      fleet_enroll_process_joins() { :; }
      fleet_seed_command() { :; }
      fleet_run_proposals() { :; }
      fleet_doctor_command() { :; }
      fleet_run_plugin_marketplaces() { :; }
      brew() { printf 'brew %s\n' "$*" >>"$NRT_LOG"; }
      ROUNDHOUSE_CONFIG=$nrt_root/${2:-local-declared}.json
      export ROUNDHOUSE_CONFIG
      fleet_run_full_pass "$nrt_root/store" nrt-host "$1" "$nrt_defs" \
        "$nrt_root/layers" "$nrt_root/full-tmp" >"$nrt_root/full-out" 2>&1
    )
  }
  mkdir -p "$nrt_root/store" "$nrt_root/layers" "$nrt_root/full-tmp"
  nrt_full_fold='{"packages":{"svc":"enabled","plain":"enabled"},"package_managers":["homebrew","npm"],"runtimes":{"node":{"major":26}}}'
  printf 'runtimes.node canary evidence unavailable\n' >"$nrt_root/full-tmp/sigholds"
  : >"$nrt_root/full-tmp/verdicts"
  nrt_run_full "$nrt_full_fold"
  [ "$(nrt_default)" = v26.0.0 ] || fail "the full cadence moved a runtime its apply gate held"
  : >"$nrt_root/full-tmp/sigholds"
  nrt_run_full "$nrt_full_fold"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the full cadence did not converge runtimes.node"
  nrt_switch_line=$(grep -n 'fnm default v26.10.0' "$nrt_log" | head -1 | cut -d: -f1)
  nrt_outdated_line=$(grep -n 'npm outdated --global' "$nrt_log" | tail -1 | cut -d: -f1)
  [ -n "$nrt_switch_line" ] && [ -n "$nrt_outdated_line" ] &&
    [ "$nrt_switch_line" -lt "$nrt_outdated_line" ] &&
    grep -Fq 'npm outdated --global --json node=v26.10.0' "$nrt_log" ||
    fail "the npm pass did not run after the runtime switch, under the new node"
  # A package just changed to `disabled` while that change (and its
  # definition) is held is still installed, so it is carried: the carry reads
  # what is installed, never desired state or holds.
  nrt_reset
  printf '%s\n' 'packages.svc canary evidence unavailable' \
    'definitions.packages.svc signature from an unverifiable commit' >"$nrt_root/full-tmp/sigholds"
  nrt_run_full '{"packages":{"svc":"disabled","plain":"enabled"},"package_managers":["homebrew","npm"],"runtimes":{"node":{"major":26}}}'
  [ "$(nrt_default)" = v26.10.0 ] &&
    [ "$(nrt_globals v26.10.0)" = '{"@example/svc":"1.0.0","plain":"2.0.0","unmanaged":"0.1.0"}' ] &&
    grep -Fq 'bin svc service node=v26.10.0' "$nrt_log" ||
    fail "a disabled-and-held installed package was not carried with its hook"
  : >"$nrt_root/full-tmp/sigholds"

  # --- an unverified default keeps npm off it, and only npm ---------------------
  nrt_mixed_fold='{"packages":{"svc":"enabled","plain":"enabled","brewonly":"enabled"},"package_managers":["homebrew","npm"],"runtimes":{"node":{"major":26}}}'
  # An ordinary hold (the store requires a hook this host does not declare)
  # leaves the default untouched: the npm pass still runs, and the hold is
  # alerted (a host silently off Node releases is visible).
  nrt_reset
  : >"$nrt_root/full-tmp/sigholds"
  rm -rf "$nrt_root/store/alerts"
  nrt_run_full "$nrt_mixed_fold" local-undeclared
  [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq 'npm outdated --global --json node=v26.0.0' "$nrt_log" &&
    ! grep -Fq 'npm globals skipped this pass' "$nrt_root/full-out" ||
    fail "an ordinary runtime hold skipped the npm pass"
  [ -f "$nrt_root/store/alerts/nrt-host/runtime-hold--runtimes.node.yaml" ] ||
    fail "a held runtimes.node raised no alert"
  # A condition alert: the end-of-pass sweep clears it once a pass checks the
  # runtime and converges it.
  nrt_reset
  : >"$nrt_root/full-tmp/alert-ledger"
  nrt_run_full "$nrt_mixed_fold"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the clean fixture did not converge runtimes.node"
  fleet_alert_sweep "$nrt_root/store" nrt-host "$nrt_root/full-tmp/alert-ledger"
  [ ! -e "$nrt_root/store/alerts/nrt-host/runtime-hold--runtimes.node.yaml" ] ||
    fail "a converged runtimes.node kept its runtime-hold alert"
  # A carry that fails never touches the live default: it fails while the
  # target is staged, so nothing flips and nothing needs restoring.
  nrt_reset
  NRT_NPM_FAIL_INSTALL=1 nrt_run_full "$nrt_mixed_fold"
  [ "$(nrt_default)" = v26.0.0 ] && ! grep -Fq 'fnm default v26.10.0' "$nrt_log" &&
    [ ! -e "$nrt_marker" ] && grep -Fq 'npm outdated --global --json node=v26.0.0' "$nrt_log" ||
    fail "a failed carry flipped the default or blocked the npm pass"
  # A switch that fails after the flip AND cannot restore with proof stays
  # recorded in flight: no npm operation runs under it, brew still does, and
  # it is reported and alerted.
  nrt_reset
  rm -rf "$nrt_root/store/alerts"
  NRT_HOOK_FAIL=1 NRT_FNM_DEFAULT_ONLY=v26.10.0 nrt_run_full "$nrt_mixed_fold"
  [ "$(nrt_default)" = v26.10.0 ] && [ -e "$nrt_marker" ] ||
    fail "the unrestorable-switch fixture did not leave the switch recorded in flight"
  grep -Fq '  hold  runtimes.node — switch to v26.10.0 failed and the fnm default (v26.10.0) is unverified' \
    "$nrt_root/full-out" &&
    grep -Fq '  hold  packages (npm) — Node default is unverified after a failed runtime switch; npm globals skipped this pass' \
      "$nrt_root/full-out" ||
    fail "an unverified default was not reported"
  ! grep -Eq 'npm (outdated|view)' "$nrt_log" ||
    fail "an npm operation ran under an unverified default"
  grep -Fq 'brew upgrade brewonly' "$nrt_log" ||
    fail "an unverified Node default stopped the non-npm package pass"
  [ -f "$nrt_root/store/alerts/nrt-host/node-runtime-unverified--runtimes.node.yaml" ] ||
    fail "an unverified Node default raised no alert"
  # The next run still cannot restore: the record stays, npm stays off.
  : >"$nrt_log"
  NRT_FNM_DEFAULT_ONLY=v26.10.0 nrt_run_full "$nrt_mixed_fold"
  [ -e "$nrt_marker" ] && ! grep -Fq 'npm outdated' "$nrt_log" ||
    fail "an unrecovered switch let the next run's npm pass through"
  # Once a restore can be proven, the next run rolls the switch back, holds,
  # clears the record, and only then lets npm run again.
  : >"$nrt_log"
  nrt_run_full "$nrt_mixed_fold"
  [ "$(nrt_default)" = v26.0.0 ] && [ ! -e "$nrt_marker" ] &&
    grep -Fq '  hold  runtimes.node — an interrupted switch was rolled back to its old default (verified)' \
      "$nrt_root/full-out" &&
    grep -Fq 'npm outdated --global --json node=v26.0.0' "$nrt_log" ||
    fail "a recoverable in-flight switch was not rolled back with proof"
  # An interrupted switch (killed between the flip and its verification) is
  # never mistaken for a converged one: the default is already in its major,
  # yet the reviewed apply holds, rolls it back, and does not report applied.
  nrt_reset
  nrt_env "$nrt_bin/fnm" install v26.10.0
  nrt_env "$nrt_bin/fnm" default v26.10.0
  node_switch_marker_write v26.0.0 v26.10.0 "$nrt_carry_all"
  nrt_status=0
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '{"major":26}' \
    "homebrew npm" >"$nrt_root/interrupted-out" 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] && [ ! -e "$nrt_marker" ] ||
    fail "an interrupted switch was reported converged (status $nrt_status)"
  # Unrecoverable on the reviewed apply: 76 passes through.
  nrt_reset
  nrt_env "$nrt_bin/fnm" install v27.0.0
  node_switch_marker_write v99.0.0 v27.0.0 '[]'
  nrt_status=0
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '{"major":27}' \
    "homebrew npm" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 76 ] && [ "$(nrt_default)" = v26.0.0 ] ||
    fail "the runtime apply arm did not report an unrecoverable in-flight switch (got $nrt_status)"
  # The way out of a record no run can roll back: node-switch-clear clears
  # it only when no switch is running and the CURRENT default is
  # self-consistent with listable globals.
  nrt_status=0
  node_switch_clear >"$nrt_root/clear-out" 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 0 ] && [ ! -e "$nrt_marker" ] &&
    grep -Fq 'cleared the in-flight Node switch v99.0.0 -> v27.0.0; the fnm default is v26.0.0 (verified)' \
      "$nrt_root/clear-out" ||
    fail "node-switch-clear did not clear an unrecoverable record over a verified default (status $nrt_status)"
  node_switch_marker_write v99.0.0 v27.0.0 '[]'
  mv "$nrt_fnm/aliases/default" "$nrt_root/default-aside"
  nrt_status=0
  node_switch_clear >/dev/null 2>&1 || nrt_status=$?
  mv "$nrt_root/default-aside" "$nrt_fnm/aliases/default"
  [ "$nrt_status" -eq 65 ] && [ -e "$nrt_marker" ] ||
    fail "node-switch-clear cleared a record without a verified default (status $nrt_status)"
  rm -f "$nrt_marker"
  : >"$nrt_root/full-tmp/sigholds"

  # --- one lock covers a whole switch and a whole recovery ---------------------
  # A switch still running its hooks is NOT interrupted: a recovery (from a
  # scheduled run) leaves it alone, a second switch refuses, and the running
  # switch then finishes with its default verified.
  nrt_reset
  rm -f "$nrt_root/hook-release" "$nrt_root/hook-release.started"
  NRT_HOOK_WAIT=$nrt_root/hook-release node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" \
    >"$nrt_root/live-switch-out" 2>&1 &
  nrt_live_pid=$!
  nrt_waited=0
  until [ -e "$nrt_root/hook-release.started" ] || [ "$nrt_waited" -ge 3000 ]; do
    sleep 0.1
    nrt_waited=$((nrt_waited + 1))
  done
  [ -e "$nrt_marker" ] && [ -d "$nrt_lock" ] ||
    fail "a running switch held neither its in-flight record nor its lock"
  nrt_status=0
  node_switch_recover || nrt_status=$?
  [ "$nrt_status" -eq 74 ] && [ "$(nrt_default)" = v26.10.0 ] && [ -e "$nrt_marker" ] ||
    fail "a recovery rolled back a switch that was still running (status $nrt_status)"
  nrt_status=0
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '{"major":26}' \
    "homebrew npm" >"$nrt_root/live-apply-out" 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.10.0 ] &&
    grep -Fq 'a Node switch is in progress on this host' "$nrt_root/live-apply-out" ||
    fail "a scheduled apply did not leave a running switch alone (status $nrt_status)"
  nrt_status=0
  node_runtime_switch v26.2.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "a second switch ran while another held the lock (status $nrt_status)"
  nrt_status=0
  node_switch_clear >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ -e "$nrt_marker" ] ||
    fail "node-switch-clear cleared the record of a running switch (status $nrt_status)"
  : >"$nrt_root/hook-release"
  nrt_status=0
  wait "$nrt_live_pid" || nrt_status=$?
  [ "$nrt_status" -eq 0 ] && [ "$(nrt_default)" = v26.10.0 ] && [ ! -e "$nrt_marker" ] &&
    [ ! -e "$nrt_lock" ] ||
    fail "a switch a recovery looked at did not finish verified (status $nrt_status)"
  # A lock whose holder is gone is stale and is taken over.
  nrt_reset
  sh -c 'exit 0' &
  nrt_dead_pid=$!
  wait "$nrt_dead_pid" || :
  mkdir -p "$nrt_lock"
  printf '%s\n%s\n' "$nrt_dead_pid" 'Thu Jan  1 00:00:00 1970' >"$nrt_lock/owner"
  node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" >/dev/null 2>&1 &&
    [ "$(nrt_default)" = v26.10.0 ] && [ ! -e "$nrt_lock" ] ||
    fail "a stale Node switch lock was not taken over"
  # The holder's start time reads the same in every lane, whatever its TZ.
  sleep 600 &
  nrt_tz_pid=$!
  [ -n "$(TZ=America/Los_Angeles node_process_start "$nrt_tz_pid")" ] &&
    [ "$(TZ=America/Los_Angeles node_process_start "$nrt_tz_pid")" = \
      "$(TZ=Asia/Kolkata node_process_start "$nrt_tz_pid")" ] &&
    TZ=Asia/Kolkata node_process_live "$nrt_tz_pid" \
      "$(TZ=America/Los_Angeles node_process_start "$nrt_tz_pid")" ||
    fail "a lock holder's start time depended on the reader's TZ"
  kill "$nrt_tz_pid" 2>/dev/null || :
  wait "$nrt_tz_pid" 2>/dev/null || :
  # Two contenders that both judge the same lock stale cannot both take it:
  # the takeover re-checks the owner under its own mutex. The second one
  # acts only after the first has taken the lock, the window in which a
  # takeover without that re-check removes a live lock.
  nrt_reset
  sh -c 'exit 0' &
  nrt_dead_pid=$!
  wait "$nrt_dead_pid" || :
  mkdir -p "$nrt_lock"
  printf '%s\n%s\n' "$nrt_dead_pid" 'Thu Jan  1 00:00:00 1970' >"$nrt_lock/owner"
  nrt_contend() {
    (
      nrt_contender=${BASHPID:-$(exec sh -c "$node_self_pid_sh")}
      nrt_contend_status=0
      ROUNDHOUSE_TEST_NODE_LOCK_DELAY=$3 node_switch_lock_take "$nrt_contender" ||
        nrt_contend_status=$?
      printf '%s\n' "$nrt_contend_status" >"$1"
      # Stay alive, holding whatever was taken, until both have answered.
      nrt_contend_wait=0
      until [ -s "$2" ] || [ "$nrt_contend_wait" -ge 300 ]; do
        sleep 0.1
        nrt_contend_wait=$((nrt_contend_wait + 1))
      done
    ) &
  }
  rm -f "$nrt_root/contend-a" "$nrt_root/contend-b"
  nrt_contend "$nrt_root/contend-a" "$nrt_root/contend-b" 0.5
  nrt_contend_a=$!
  nrt_contend "$nrt_root/contend-b" "$nrt_root/contend-a" 2
  nrt_contend_b=$!
  wait "$nrt_contend_a" || :
  wait "$nrt_contend_b" || :
  [ "$(sort "$nrt_root/contend-a" "$nrt_root/contend-b" | tr '\n' ' ')" = '0 75 ' ] ||
    fail "two contenders both took a stale Node switch lock ($(cat "$nrt_root/contend-a" "$nrt_root/contend-b" | tr '\n' ' '))"
  rm -rf "$nrt_lock" "$nrt_lock.break"
  # A lock held by a live process refuses a switch and defers a recovery;
  # so does a record whose own writer is still running.
  nrt_reset
  sleep 600 &
  nrt_holder=$!
  mkdir -p "$nrt_lock"
  printf '%s\n%s\n' "$nrt_holder" "$(node_process_start "$nrt_holder")" >"$nrt_lock/owner"
  nrt_status=0
  node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] ||
    fail "a switch ran under a lock a live process holds (status $nrt_status)"
  node_switch_marker_write v26.0.0 v26.10.0 '[]'
  nrt_status=0
  node_switch_recover || nrt_status=$?
  [ "$nrt_status" -eq 74 ] && [ -e "$nrt_marker" ] ||
    fail "a recovery ran under a lock a live process holds (status $nrt_status)"
  rm -rf "$nrt_lock"
  node_switch_marker_write v26.0.0 v26.10.0 '[]' "$nrt_holder" "$(node_process_start "$nrt_holder")"
  nrt_status=0
  node_switch_recover || nrt_status=$?
  [ "$nrt_status" -eq 74 ] && [ -e "$nrt_marker" ] ||
    fail "a recovery rolled back a record whose writer is still running (status $nrt_status)"
  kill "$nrt_holder" 2>/dev/null || :
  wait "$nrt_holder" 2>/dev/null || :
  nrt_status=0
  node_switch_recover || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ ! -e "$nrt_marker" ] && [ ! -e "$nrt_lock" ] ||
    fail "a record whose writer is gone was not rolled back (status $nrt_status)"

  # --- an in-flight record blocks every npm mutation ----------------------------
  nrt_reset
  node_switch_marker_write v26.0.0 v26.10.0 '[]'
  : >"$nrt_log"
  nrt_status=0
  fleet_install_package npm plain false 3.0.0 || nrt_status=$?
  [ "$nrt_status" -eq 73 ] && ! grep -Fq 'npm install' "$nrt_log" ||
    fail "a fast-pass npm install ran while a Node switch was in flight (status $nrt_status)"
  # The run names it as a deferral, not as a package no manager provides.
  rm -rf "$nrt_root/store/alerts"
  : >"$nrt_root/full-tmp/sigholds"
  fleet_run_apply_held "$nrt_root/store" nrt-host "$nrt_defs" packages.plain packages d0 73 \
    "$nrt_root/full-tmp" 2026-10-01T00:00:00Z >"$nrt_root/deferred-out"
  grep -Fq '  held    packages.plain (deferred: a Node runtime switch is in flight' "$nrt_root/deferred-out" &&
    [ -f "$nrt_root/store/alerts/nrt-host/package-deferred--packages.plain.yaml" ] &&
    ! ls "$nrt_root/store/alerts/nrt-host/"*package-hold* >/dev/null 2>&1 ||
    fail "an npm install deferred by a Node switch was reported as an unprovidable package"
  : >"$nrt_root/full-tmp/sigholds"
  rm -f "$nrt_marker"

  # --- a hook that keeps failing is not flipped on every fast pass ------------
  # The reviewed apply flips once, restores, and then holds that exact
  # attempt; the full cadence retries it, and a success clears the backoff.
  nrt_reset
  nrt_status=0
  NRT_HOOK_FAIL=1 nrt_converge local-declared '{"major":27}' apply || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] && [ -e "$nrt_backoff" ] ||
    fail "a failed post-switch hook did not restore and back off (status $nrt_status)"
  : >"$nrt_log"
  nrt_status=0
  NRT_HOOK_FAIL=1 nrt_converge local-declared '{"major":27}' apply || nrt_status=$?
  [ "$nrt_status" -eq 73 ] && ! grep -Fq 'fnm default' "$nrt_log" &&
    grep -Fq 'the post-switch hooks failed for this exact switch to v27.0.0' "$nrt_root/converge-out" ||
    fail "the reviewed apply flipped the default again for a switch whose hooks keep failing"
  nrt_converge local-declared '{"major":27}' full ||
    fail "the full cadence did not retry a backed-off switch"
  [ "$(nrt_default)" = v27.0.0 ] && [ ! -e "$nrt_backoff" ] ||
    fail "a successful retry did not clear the backoff"
  # Through the run loop itself: the apply loop DEFERS the backed-off
  # switch (73) and records that with the loop's own hold code
  # (fleet_run_apply_held); the full pass of the same run must still make
  # the retry the backoff promises. A plain hold would have stopped it, and
  # the switch would never be retried.
  nrt_reset
  : >"$nrt_root/full-tmp/sigholds"
  : >"$nrt_root/full-tmp/verdicts"
  nrt_status=0
  NRT_HOOK_FAIL=1 ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '{"major":27}' \
    "homebrew npm" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] && [ -e "$nrt_backoff" ] ||
    fail "the reviewed apply of a failing switch did not restore and back off (status $nrt_status)"
  nrt_status=0
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '{"major":27}' \
    "homebrew npm" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 73 ] && [ "$(nrt_default)" = v26.0.0 ] ||
    fail "the reviewed apply did not defer a backed-off switch (status $nrt_status)"
  fleet_run_apply_held "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node runtimes d0 "$nrt_status" \
    "$nrt_root/full-tmp" 2026-10-01T00:00:00Z >/dev/null
  grep -Fqx 'runtimes.node apply status 73' "$nrt_root/full-tmp/sigholds" ||
    fail "the run loop did not record the deferral"
  nrt_run_full '{"packages":{"svc":"enabled","plain":"enabled"},"package_managers":["homebrew","npm"],"runtimes":{"node":{"major":27}}}'
  [ "$(nrt_default)" = v27.0.0 ] && [ ! -e "$nrt_backoff" ] ||
    fail "the full pass did not retry a switch the run loop had deferred"
  # Any other hold of the item still stops the full pass.
  nrt_reset
  printf '%s\n' 'runtimes.node apply status 75' >"$nrt_root/full-tmp/sigholds"
  nrt_run_full '{"packages":{"svc":"enabled","plain":"enabled"},"package_managers":["homebrew","npm"],"runtimes":{"node":{"major":27}}}'
  [ "$(nrt_default)" = v26.0.0 ] || fail "the full pass switched a runtime the run loop held"
  : >"$nrt_root/full-tmp/sigholds"
  # node-switch-clear also clears a backoff.
  node_switch_backoff_write v27.0.0 '[]' '[]'
  node_switch_clear >/dev/null 2>&1 && [ ! -e "$nrt_backoff" ] ||
    fail "node-switch-clear did not clear the post-switch hook backoff"

  # --- the carry runs under an npm no older than the host's -------------------
  # npm 12 honours allow-scripts; a target that bundles npm 11 is brought up to
  # the installed npm 12 before the carry, which then runs under it.
  nrt_reset
  nrt_env PATH="$nrt_fnm/aliases/default/bin:$PATH" "$nrt_fnm/aliases/default/bin/npm" \
    install --global npm@12.0.0
  : >"$nrt_log"
  NRT_BUNDLED_NPM=11.0.0 node_runtime_switch v26.10.0 "$nrt_carry_all" "$nrt_hooks" ||
    fail "a switch to a target that bundles an older npm failed"
  nrt_npm_line=$(grep -n 'npm install --global npm@12.0.0 node=v26.10.0' "$nrt_log" | head -1 | cut -d: -f1)
  nrt_carry_line=$(grep -n 'npm install --global @example/svc@1.0.0' "$nrt_log" | head -1 | cut -d: -f1)
  [ -n "$nrt_npm_line" ] && [ -n "$nrt_carry_line" ] && [ "$nrt_npm_line" -lt "$nrt_carry_line" ] ||
    fail "the target's older bundled npm was not upgraded before the carry"
  [ "$(jq -r '.version' "$nrt_fnm/node-versions/v26.10.0/installation/lib/node_modules/npm/package.json")" = 12.0.0 ] ||
    fail "the target prefix did not end on the host's npm"
  # Not when the target's own npm is already as new.
  nrt_reset
  : >"$nrt_log"
  NRT_BUNDLED_NPM=12.1.0 node_runtime_switch v26.10.0 "$nrt_carry_all" "$nrt_hooks" ||
    fail "a switch to a target with a newer bundled npm failed"
  ! grep -Fq 'install --global npm@' "$nrt_log" ||
    fail "a target whose npm is newer was downgraded"

  # --- a hook that starts a daemon does not hold the run ------------------------
  # The daemon lives far longer than any run; the switch returning while it
  # is still alive is the proof, whatever the load on the machine.
  nrt_reset
  rm -f "$nrt_root/daemon.pid"
  NRT_HOOK_DAEMON=$nrt_root/daemon.pid nrt_converge local-declared '{"major":26}' full ||
    fail "a switch whose hook started a daemon did not converge"
  [ -s "$nrt_root/daemon.pid" ] && kill -0 "$(cat "$nrt_root/daemon.pid")" 2>/dev/null ||
    fail "a hook's daemon held the switch's output open (the switch returned only after it ended)"
  kill "$(cat "$nrt_root/daemon.pid")" 2>/dev/null || :

  # Every lane sees one record: the path ignores XDG_STATE_HOME, which
  # launchd, SSH and an interactive shell set differently.
  [ "$(XDG_STATE_HOME=/elsewhere node_switch_marker_path)" = "$nrt_marker" ] &&
    [ ! -e "$nrt_root/xdg-state" ] ||
    fail "the Node switch state followed XDG_STATE_HOME"
)

# --- the sealed lifecycle: collect, seal, apply, post-state ---------------------
nrt_reset
jq '.machines["test-host"].package_managers = ["homebrew","npm"] |
  .node_switch_hooks = {"npm:@example/svc":[["svc","service"]]}' \
  "$tmp/config.json" >"$tmp/node-config.json"
chmod 600 "$tmp/node-config.json"
nrt_cli() {
  nrt_env ROUNDHOUSE_CONFIG="$tmp/node-config.json" "$cli" "$@"
}
# The store's definitions: the only store input a sealed switch reads, for
# the node_switch hooks they require of carried packages.
mkdir -p "$nrt_store"
printf '%s\n' 'packages:' \
  '  svc: {npm: {name: "@example/svc", node_switch: [[svc, service]]}}' \
  '  plain: {npm: plain}' '  brewonly: {homebrew: brewonly}' >"$nrt_store/definitions.yaml"
[ -z "$fleet_fixture_yq" ] || ln -sfn "$fleet_fixture_yq" "$nrt_bin/yq"
# Configuration: hooks are argv lists; the worker projection carries them to
# POSIX targets only.
for nrt_bad_config in \
  '.node_switch_hooks = {"npm:@example/svc":["svc","service"]}' \
  '.node_switch_hooks = {"npm:@example/svc":[["svc; rm"]]}' \
  '.node_switch_hooks = {"npm:@example/svc":[]}' \
  '.node_switch_hooks = {"homebrew:git":[["git","gc"]]}'; do
  jq "$nrt_bad_config" "$tmp/node-config.json" >"$tmp/node-bad-config.json"
  chmod 600 "$tmp/node-bad-config.json"
  if ROUNDHOUSE_CONFIG="$tmp/node-bad-config.json" "$cli" worker-config test-host updates \
    "$tmp/node-bad-worker.json" >/dev/null 2>&1; then
    fail "configuration validation accepted: $nrt_bad_config"
  fi
done
nrt_cli worker-config test-host updates "$tmp/node-worker-config.json"
[ "$(jq -c '.node_switch_hooks["npm:@example/svc"]' "$tmp/node-worker-config.json")" = '[["svc","service"]]' ] ||
  fail "the bounded worker configuration dropped the post-switch hooks"
nrt_cli worker-config test-windows updates "$tmp/node-windows-worker-config.json"
[ "$(jq -c '.node_switch_hooks' "$tmp/node-windows-worker-config.json")" = '{}' ] ||
  fail "post-switch hooks were projected to a Windows target"

if [ -z "$fleet_fixture_yq" ]; then
  printf 'NOTICE: the sealed Node switch reads store definitions and needs yq; skipped\n'
else
  nrt_cli collect --target test-host --section host --section packages --output "$tmp/node-snapshot.jsonl"
  "$cli" validate "$tmp/node-snapshot.jsonl"
  [ "$(jq -c 'select(.kind == "package" and .id == "fnm:node") | .data |
    [.installed_version,.candidate_version,.update_available,.line,.installed_versions,.stale_versions,
     .globals["@example/svc"],.globals_unpinnable,.switch_hooks_unproven]' "$tmp/node-snapshot.jsonl")" = \
    '["v26.0.0","v26.10.0",true,"26",["v26.0.0"],[],"1.0.0",[],[]]' ] ||
    fail "the POSIX collector did not report the fnm runtime with its line candidate and globals"
  NRT_NPM_LINKED=devtool nrt_cli collect --target test-host --section host --section packages \
    --output "$tmp/node-linked-snapshot.jsonl"
  [ "$(jq -c 'select(.kind == "package" and .id == "fnm:node") | .data.globals_unpinnable' \
    "$tmp/node-linked-snapshot.jsonl")" = '["devtool"]' ] ||
    fail "the POSIX collector did not report an unpinnable global"

  nrt_required='[{"package":"npm:@example/svc","argv":["svc","service"]}]'
  nrt_draft() {
    # nrt_draft CANDIDATE CARRY HOOKS ARGV... (required hooks: $nrt_required)
    jq -n --arg candidate "$1" --argjson carry "$2" --argjson hooks "$3" \
      --argjson required "$nrt_required" --args \
      '{domain:"updates",target:"test-host",operations:[{type:"package-upgrade",kind:"package",
        id:"fnm:node",candidate_version:$candidate,argv:$ARGS.positional,carry:$carry,hooks:$hooks,
        required:$required}]}' \
      -- "${@:4}"
  }
  nrt_carry='[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"},{"name":"unmanaged","version":"0.1.0"}]'
  nrt_hooks='[{"package":"npm:@example/svc","argv":["svc","service"]}]'
  nrt_seal_refused() {
    # nrt_seal_refused LABEL DRAFT-FILE [SNAPSHOT]
    if nrt_cli seal-plan "$2" "${3:-$tmp/node-snapshot.jsonl}" "$tmp/node-refused-plan.json" \
      >"$nrt_root/seal-refused.log" 2>&1; then
      fail "a Node switch sealed with $1"
    fi
  }
  nrt_draft v26.10.0 "$nrt_carry" '[]' fnm default v26.10.0 >"$tmp/node-draft-nohooks.json"
  nrt_seal_refused 'its configured post-switch hook omitted' "$tmp/node-draft-nohooks.json"
  nrt_draft v26.10.0 "$nrt_carry" \
    '[{"package":"npm:@example/svc","argv":["svc","service"]},{"package":"npm:plain","argv":["plain","x"]}]' \
    fnm default v26.10.0 >"$tmp/node-draft-extrahook.json"
  nrt_seal_refused 'a post-switch hook the configuration does not declare' "$tmp/node-draft-extrahook.json"
  (nrt_required='[]'; nrt_draft v26.10.0 "$nrt_carry" "$nrt_hooks" fnm default v26.10.0) \
    >"$tmp/node-draft-norequired.json"
  nrt_seal_refused 'the required hooks the definitions state omitted' "$tmp/node-draft-norequired.json"
  nrt_draft v26.10.0 '[{"name":"plain","version":"9.9.9"}]' '[]' fnm default v26.10.0 \
    >"$tmp/node-draft-wrongcarry.json"
  nrt_seal_refused 'a carried version that is not installed' "$tmp/node-draft-wrongcarry.json"
  nrt_draft v26.10.0 "$nrt_carry" "$nrt_hooks" fnm install v26.10.0 >"$tmp/node-draft-argv.json"
  nrt_seal_refused 'an argv other than the fixed marker' "$tmp/node-draft-argv.json"
  nrt_draft v26.2.0 "$nrt_carry" "$nrt_hooks" fnm default v26.2.0 >"$tmp/node-draft-notcandidate.json"
  nrt_seal_refused 'a version that is not the observed candidate' "$tmp/node-draft-notcandidate.json"
  jq '.operations[0].id = "fnm:python"' "$tmp/node-draft-nohooks.json" >"$tmp/node-draft-otherid.json"
  nrt_seal_refused 'a runtime other than node' "$tmp/node-draft-otherid.json"
  # The carry is every installed global: empty and partial are refused, and a
  # linked global holds the switch outright.
  nrt_draft v26.10.0 '[]' '[]' fnm default v26.10.0 >"$tmp/node-draft-empty.json"
  nrt_seal_refused 'an empty carry' "$tmp/node-draft-empty.json"
  nrt_draft v26.10.0 '[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"}]' \
    "$nrt_hooks" fnm default v26.10.0 >"$tmp/node-draft-partial.json"
  nrt_seal_refused 'a partial carry' "$tmp/node-draft-partial.json"
  nrt_draft v26.10.0 "$nrt_carry" "$nrt_hooks" fnm default v26.10.0 >"$tmp/node-draft.json"
  nrt_seal_refused 'an unpinnable global installed' "$tmp/node-draft.json" "$tmp/node-linked-snapshot.jsonl"
  assert_contains "$(cat "$nrt_root/seal-refused.log")" 'npm globals devtool cannot be reinstalled'
  # A collector whose global inventory failed records the set as unknown
  # (null), never as empty; a snapshot that knows the globals but not which
  # are unpinnable neither seals nor verifies.
  NRT_NPM_LS_FAIL=1 nrt_cli collect --target test-host --section host --section packages \
    --output "$tmp/node-lsfail-snapshot.jsonl" >/dev/null 2>&1 || :
  [ ! -s "$tmp/node-lsfail-snapshot.jsonl" ] ||
    [ "$(jq -c 'select(.kind == "package" and .id == "fnm:node") | [.data.globals,.data.globals_unpinnable]' \
      "$tmp/node-lsfail-snapshot.jsonl")" = '[null,null]' ] ||
    fail "a failed global inventory was recorded as known"
  jq -c 'if .kind == "package" and .id == "fnm:node" then .data.globals_unpinnable = null else . end' \
    "$tmp/node-snapshot.jsonl" >"$tmp/node-unknown-snapshot.jsonl"
  nrt_seal_refused 'an unknown unpinnable set' "$tmp/node-draft.json" "$tmp/node-unknown-snapshot.jsonl"
  assert_contains "$(cat "$nrt_root/seal-refused.log")" 'which npm globals cannot be reinstalled by exact registry version is unknown'
  # The switch runs before any npm upgrade in the same plan: an upgrade first
  # would change a version the carry names.
  jq '.operations = [{type:"package-upgrade",kind:"package",id:"npm:plain",candidate_version:"3.0.0",
    argv:["npm","install","--global","plain@3.0.0"]}] + .operations' "$tmp/node-draft.json" \
    >"$tmp/node-draft-npm-first.json"
  nrt_seal_refused 'an npm upgrade ordered before it' "$tmp/node-draft-npm-first.json"
  assert_contains "$(cat "$nrt_root/seal-refused.log")" 'the Node switch must precede every npm upgrade'
  jq '.operations += [{type:"package-upgrade",kind:"package",id:"npm:plain",candidate_version:"3.0.0",
    argv:["npm","install","--global","plain@3.0.0"]}]' "$tmp/node-draft.json" >"$tmp/node-draft-npm-after.json"
  nrt_cli seal-plan "$tmp/node-draft-npm-after.json" "$tmp/node-snapshot.jsonl" \
    "$tmp/node-after-plan.json" >"$nrt_root/seal-after.log" 2>&1 || :
  ! grep -Fq 'must precede every npm upgrade' "$nrt_root/seal-after.log" ||
    fail "a Node switch ordered before an npm upgrade was refused for its order"
  # A second switch after an npm upgrade would carry the pre-upgrade version.
  jq '.operations as $sw | .operations = $sw + [{type:"package-upgrade",kind:"package",id:"npm:plain",
    candidate_version:"3.0.0",argv:["npm","install","--global","plain@3.0.0"]}] + $sw' \
    "$tmp/node-draft.json" >"$tmp/node-draft-two-switches.json"
  nrt_seal_refused 'a second Node switch' "$tmp/node-draft-two-switches.json"
  assert_contains "$(cat "$nrt_root/seal-refused.log")" 'a plan may contain at most one Node switch'
  if nrt_store_override="$nrt_root/no-store" nrt_cli seal-plan "$tmp/node-draft.json" \
    "$tmp/node-snapshot.jsonl" "$tmp/node-refused-plan.json" >/dev/null 2>&1; then
    fail "a Node switch sealed without the store definitions"
  fi
  jq -c 'if .kind == "package" and .id == "fnm:node" then .data.switch_hooks_unproven = ["npm:@example/svc"] else . end' \
    "$tmp/node-snapshot.jsonl" >"$tmp/node-unproven-snapshot.jsonl"
  if nrt_cli seal-plan "$tmp/node-draft.json" "$tmp/node-unproven-snapshot.jsonl" \
    "$tmp/node-unproven-plan.json" >/dev/null 2>&1; then
    fail "a Node switch sealed while a carried package's hook was unproven"
  fi
  nrt_cli seal-plan "$tmp/node-draft.json" "$tmp/node-snapshot.jsonl" "$tmp/node-plan.json"
  nrt_plan_id=$(jq -r '.plan_id' "$tmp/node-plan.json")

  # A hook failure after the default moved: the default is restored and the apply
  # reports partial.
  : >"$nrt_log"
  if nrt_env NRT_HOOK_FAIL=1 ROUNDHOUSE_CONFIG="$tmp/node-config.json" "$cli" apply-plan \
    "$tmp/node-plan.json" "$nrt_plan_id" "$tmp/node-failed-apply.jsonl" >/dev/null 2>&1; then
    fail "a Node switch whose post-switch hook failed was reported complete"
  fi
  [ "$(nrt_default)" = v26.0.0 ] || fail "a failed sealed switch left the new default in place"
  [ "$(jq -r 'select(.kind == "operation" and (.id | startswith("apply:"))) | .data.operation_status' \
    "$tmp/node-failed-apply.jsonl")" = partial ] || fail "a failed sealed switch was not partial"
  # The failed attempt left v26.10.0 installed, which the fnm:node record binds:
  # the old plan no longer verifies, and a fresh one is sealed.
  if nrt_cli apply-plan "$tmp/node-plan.json" "$nrt_plan_id" "$tmp/node-stale-apply.jsonl" \
    >/dev/null 2>&1; then
    fail "a Node switch plan verified after the installed versions changed"
  fi
  nrt_cli collect --target test-host --section host --section packages --output "$tmp/node-snapshot-2.jsonl"
  [ "$(jq -c 'select(.kind == "package" and .id == "fnm:node") | .data.stale_versions' \
    "$tmp/node-snapshot-2.jsonl")" = '["v26.10.0"]' ] ||
    fail "an installed, non-default Node version was not reported as stale"
  nrt_cli seal-plan "$tmp/node-draft.json" "$tmp/node-snapshot-2.jsonl" "$tmp/node-plan-2.json"
  nrt_plan_id=$(jq -r '.plan_id' "$tmp/node-plan-2.json")

  # The failed attempt left v26.10.0 installed with globals in its prefix;
  # one more that is not carried must be gone after the sealed switch.
  nrt_env PATH="$nrt_fnm/node-versions/v26.10.0/installation/bin:$PATH" \
    "$nrt_fnm/node-versions/v26.10.0/installation/bin/npm" install --global stale-cli@9.0.0
  : >"$nrt_log"
  nrt_cli apply-plan "$tmp/node-plan-2.json" "$nrt_plan_id" "$tmp/node-apply.jsonl"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the sealed switch did not move the fnm default"
  [ "$(jq -r '."stale-cli" // "gone"' "$nrt_fnm/node-versions/v26.10.0/installation/globals.json")" = gone ] ||
    fail "the sealed switch left a stale global in a retained target"
  [ "$(jq -c 'select(.kind == "package" and .id == "fnm:node") | [.data.installed_version,.data.globals]' \
    "$tmp/node-apply.jsonl")" = '["v26.10.0",{"@example/svc":"1.0.0","plain":"2.0.0","unmanaged":"0.1.0"}]' ] ||
    fail "the sealed switch post-inventory did not show every carried global under the new default"
  [ "$(jq -r 'select(.kind == "operation" and (.id | startswith("apply:"))) | .data.operation_status' \
    "$tmp/node-apply.jsonl")" = completed ] || fail "the sealed switch did not complete"
  grep -Fq 'bin svc service node=v26.10.0' "$nrt_log" ||
    fail "the sealed switch did not run its hook under the new node"
  # Most POSIX hosts are reached over SSH, whose plan classifier admits exact
  # operation shapes only: a Node switch passes with its carry and hooks, and a
  # carry on any other operation does not.
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    validate_legacy_ssh_plan_file "$tmp/node-plan-2.json" ||
      fail "the SSH plan classifier refused a sealed Node switch"
    jq '.operations[0].id = "npm:plain"' "$tmp/node-plan-2.json" >"$tmp/node-ssh-other.json"
    if validate_legacy_ssh_plan_file "$tmp/node-ssh-other.json" 2>/dev/null; then
      fail "the SSH plan classifier admitted a carry on a non-runtime operation"
    fi
  )
  # The npm records moved with the runtime: a plan sealed before the switch
  # would no longer verify.
  [ "$(jq -r 'select(.kind == "package" and .id == "npm:plain") | .data.node_version' "$tmp/node-apply.jsonl")" = \
    v26.10.0 ] || fail "the npm records did not move to the new runtime"

  # A later npm upgrade of a carried global in the same plan: the switch
  # carries it at its installed version, the upgrade then moves it, and the
  # plan completes with the upgraded version rather than reading partial.
  nrt_reset
  nrt_outdated='{"plain":{"current":"2.0.0","wanted":"3.0.0","latest":"3.0.0","dependent":"global"}}'
  nrt_up_cli() {
    nrt_env NRT_NPM_OUTDATED="$nrt_outdated" ROUNDHOUSE_CONFIG="$tmp/node-config.json" "$cli" "$@"
  }
  nrt_up_cli collect --target test-host --section host --section packages \
    --output "$tmp/node-upgrade-snapshot.jsonl"
  nrt_up_cli seal-plan "$tmp/node-draft-npm-after.json" "$tmp/node-upgrade-snapshot.jsonl" \
    "$tmp/node-upgrade-plan.json"
  nrt_up_cli apply-plan "$tmp/node-upgrade-plan.json" "$(jq -r '.plan_id' "$tmp/node-upgrade-plan.json")" \
    "$tmp/node-upgrade-apply.jsonl" ||
    fail "a Node switch followed by an npm upgrade of a carried global did not complete"
  [ "$(nrt_default)" = v26.10.0 ] &&
    [ "$(jq -r 'select(.kind == "operation" and (.id | startswith("apply:"))) | .data.operation_status' \
      "$tmp/node-upgrade-apply.jsonl")" = completed ] &&
    [ "$(jq -r '.plain' "$nrt_fnm/node-versions/v26.10.0/installation/globals.json")" = 3.0.0 ] ||
    fail "the later npm upgrade was not what the switch post-check expected"

  # An npm upgrade neither applies nor seals while a Node switch is recorded
  # in flight on its target.
  nrt_reset
  jq '.operations = [.operations[] | select(.id != "fnm:node")]' "$tmp/node-draft-npm-after.json" \
    >"$tmp/node-draft-npm-only.json"
  nrt_up_cli collect --target test-host --section host --section packages \
    --output "$tmp/node-npm-only-snapshot.jsonl"
  nrt_up_cli seal-plan "$tmp/node-draft-npm-only.json" "$tmp/node-npm-only-snapshot.jsonl" \
    "$tmp/node-npm-only-plan.json" || fail "an npm-only upgrade plan did not seal"
  mkdir -p "$nrt_state"
  printf '%s\n' '{"old":"v26.0.0","target":"v26.10.0","carry":[]}' >"$nrt_marker"
  : >"$nrt_log"
  if nrt_up_cli apply-plan "$tmp/node-npm-only-plan.json" "$(jq -r '.plan_id' "$tmp/node-npm-only-plan.json")" \
    "$tmp/node-npm-inflight-apply.jsonl" >"$nrt_root/npm-inflight-apply.log" 2>&1; then
    fail "a sealed npm upgrade applied while a Node switch was in flight"
  fi
  grep -Fq 'a Node switch is recorded in flight on' "$nrt_root/npm-inflight-apply.log" &&
    ! grep -Fq 'npm install --global plain@3.0.0' "$nrt_log" ||
    fail "a sealed npm upgrade was not refused for a Node switch in flight"
  nrt_up_cli collect --target test-host --section host --section packages \
    --output "$tmp/node-inflight-snapshot.jsonl"
  if nrt_up_cli seal-plan "$tmp/node-draft-npm-only.json" "$tmp/node-inflight-snapshot.jsonl" \
    "$tmp/node-npm-inflight-plan.json" >"$nrt_root/npm-inflight-seal.log" 2>&1; then
    fail "an npm upgrade sealed for a host with a Node switch in flight"
  fi
  assert_contains "$(cat "$nrt_root/npm-inflight-seal.log")" \
    'a Node switch is recorded in flight on the target; npm upgrades are refused'
  rm -f "$nrt_marker"

  # --- the SSH lane: the worker needs no store ---------------------------------
  # The carry is proven from the worker's own fresh snapshot, and the required
  # hooks are bound into the plan, so a target without a store applies.
  nrt_reset
  jq '.machines["test-ssh"].package_managers = ["homebrew","npm"] |
    .node_switch_hooks = {"npm:@example/svc":[["svc","service"]]}' \
    "$tmp/config.json" >"$tmp/node-ssh-config.json"
  chmod 600 "$tmp/node-ssh-config.json"
  mkdir -p "$nrt_root/nostore-bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'ROUNDHOUSE_FLEET_STORE=$NRT_REMOTE_STORE exec "$NRT_REAL_SSH" "$@"' >"$nrt_root/nostore-bin/ssh"
  chmod 755 "$nrt_root/nostore-bin/ssh"
  nrt_ssh_cli() {
    nrt_env PATH="$nrt_root/nostore-bin:$nrt_bin:$PATH" NRT_REAL_SSH="$tmp/bin/ssh" \
      NRT_REMOTE_STORE="$nrt_root/no-store" ROUNDHOUSE_CONFIG="$tmp/node-ssh-config.json" "$cli" "$@"
  }
  nrt_ssh_cli collect --target test-ssh --section host --section packages \
    --output "$tmp/node-ssh-snapshot.jsonl"
  jq '.target = "test-ssh"' "$tmp/node-draft.json" >"$tmp/node-ssh-draft.json"
  nrt_ssh_cli seal-plan "$tmp/node-ssh-draft.json" "$tmp/node-ssh-snapshot.jsonl" "$tmp/node-ssh-plan.json"
  nrt_ssh_plan_id=$(jq -r '.plan_id' "$tmp/node-ssh-plan.json")
  : >"$nrt_log"
  # The hook starts a long-lived daemon: the SSH session must still end with
  # the switch, while the daemon runs on.
  rm -f "$nrt_root/ssh-daemon.pid"
  NRT_HOOK_DAEMON=$nrt_root/ssh-daemon.pid \
    nrt_ssh_cli apply-ssh-plan "$tmp/node-ssh-plan.json" "$nrt_ssh_plan_id" "$tmp/node-ssh-apply.jsonl" ||
    fail "an SSH Node switch refused because the target has no store"
  [ -s "$nrt_root/ssh-daemon.pid" ] && kill -0 "$(cat "$nrt_root/ssh-daemon.pid")" 2>/dev/null ||
    fail "a hook's daemon held the SSH session open (the apply returned only after it ended)"
  kill "$(cat "$nrt_root/ssh-daemon.pid")" 2>/dev/null || :
  [ "$(nrt_default)" = v26.10.0 ] &&
    [ "$(jq -r 'select(.kind == "operation" and (.id | startswith("apply:"))) | .data.operation_status' \
      "$tmp/node-ssh-apply.jsonl")" = completed ] &&
    grep -Fq 'bin svc service node=v26.10.0' "$nrt_log" ||
    fail "the SSH Node switch did not complete on the worker"
  # The worker still proves the carry against its own fresh snapshot.
  (
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    jq -c 'if .kind == "package" and .id == "fnm:node" then .data.globals |= del(.plain) else . end' \
      "$tmp/node-ssh-snapshot.jsonl" >"$tmp/node-ssh-uninstalled.jsonl"
    jq -c 'if .kind == "package" and .id == "fnm:node" then .data.globals.extra = "1.0.0" else . end' \
      "$tmp/node-ssh-snapshot.jsonl" >"$tmp/node-ssh-extra.jsonl"
    node_switch_verify_snapshot "$tmp/node-ssh-plan.json" "$tmp/node-ssh-snapshot.jsonl" \
      "$tmp/node-ssh-config.json" || fail "the worker rejected a carry its snapshot proves"
    jq -c 'if .kind == "package" and .id == "fnm:node" then .data.globals_unpinnable = null else . end' \
      "$tmp/node-ssh-snapshot.jsonl" >"$tmp/node-ssh-unknown.jsonl"
    for nrt_bad_snapshot in uninstalled extra unknown; do
      if node_switch_verify_snapshot "$tmp/node-ssh-plan.json" "$tmp/node-ssh-$nrt_bad_snapshot.jsonl" \
        "$tmp/node-ssh-config.json"; then
        fail "the worker accepted a carry that is not the installed set ($nrt_bad_snapshot)"
      fi
    done
  )
fi

# --- Windows: machine-scope Node holds instead of prompting UAC ---------------
if [ -n "$pwsh_command" ]; then
  mkdir -p "$nrt_root/winget-bin"
  cat >"$nrt_root/winget-bin/winget" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pin list")
    printf '%s\n' 'Name    Id            Version Source Pin type Pinned version' \
      '-------------------------------------------------------------' \
      'Node.js OpenJS.NodeJS 26.7.0  winget Gating   26.*'
    ;;
  "upgrade --accept-source-agreements") printf '%s\n' 'No installed package found matching input criteria.' ;;
  "export --output")
    printf '%s\n' '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"OpenJS.NodeJS","Version":"26.7.0"}]}]}' >"$3"
    ;;
  *) exit 64 ;;
esac
SH
  chmod 755 "$nrt_root/winget-bin/winget"
  "$cli" worker-config test-windows inventory "$tmp/node-windows-inventory.json"
  HOME="$tmp/home" PATH="$nrt_root/winget-bin:$PATH" "$pwsh_command" -NoLogo -NoProfile \
    -File "$script_dir/collect-windows.ps1" -ConfigPath "$tmp/node-windows-inventory.json" \
    -HostId test-windows \
    -ControllerConfigDigest "$(shasum -a 256 "$tmp/config.json" | awk '{print $1}')" \
    -Sections packages >"$tmp/node-windows.jsonl"
  "$cli" validate "$tmp/node-windows.jsonl"
  [ "$(jq -c 'select(.kind == "package" and .id == "winget:OpenJS.NodeJS") | .data |
    [.installed_version,.line,.pin,.pin_query,.install_scope]' "$tmp/node-windows.jsonl")" = \
    '["26.7.0","26",{"type":"Gating","version":"26.*"},"ok",null]' ] ||
    fail "the Windows collector did not report the Node runtime pin and scope"
  jq -c 'if .kind == "package" and .id == "winget:OpenJS.NodeJS" then
    .data.candidate_version = "26.8.0" | .data.update_available = true else . end' \
    "$tmp/node-windows.jsonl" >"$tmp/node-windows-candidate.jsonl"
  printf '%s\n' '{"domain":"updates","target":"test-windows","operations":[{"type":"package-upgrade","kind":"package","id":"winget:OpenJS.NodeJS","candidate_version":"26.8.0","argv":["winget","upgrade","--id","OpenJS.NodeJS","--exact","--version","26.8.0","--accept-package-agreements","--accept-source-agreements","--disable-interactivity"]}]}' \
    >"$tmp/node-windows-draft.json"
  if "$cli" seal-plan "$tmp/node-windows-draft.json" "$tmp/node-windows-candidate.jsonl" \
    "$tmp/node-windows-plan.json" >"$tmp/node-windows-seal.log" 2>&1; then
    fail "a machine-scope Windows Node upgrade sealed on the ordinary lane"
  fi
  assert_contains "$(cat "$tmp/node-windows-seal.log")" 'hold: Node.js (winget OpenJS.NodeJS) is installed machine-wide'
  jq -c 'if .kind == "package" and .id == "winget:OpenJS.NodeJS" then .data.install_scope = "user" else . end' \
    "$tmp/node-windows-candidate.jsonl" >"$tmp/node-windows-user.jsonl"
  "$cli" seal-plan "$tmp/node-windows-draft.json" "$tmp/node-windows-user.jsonl" \
    "$tmp/node-windows-user-plan.json" >/dev/null ||
    fail "a user-scope Windows Node upgrade did not seal on the ordinary lane"
fi
