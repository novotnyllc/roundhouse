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
# The store the sealed lane derives the managed npm set from.
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
state=$prefix/globals.json
[ -f "$state" ] || printf '{}\n' >"$state"
printf 'npm %s node=%s prefix=%s\n' "$*" "$(node --version 2>/dev/null || printf none)" "$prefix" >>"$NRT_LOG"
case "$1 ${2:-}" in
  "prefix --global") printf '%s\n' "$prefix" ;;
  "root --global") printf '%s/lib/node_modules\n' "$prefix" ;;
  "ls --global") jq -c '{name:"lib",dependencies:(with_entries(.value = {version:.value}))}' "$state" ;;
  "outdated --global") printf '{}\n' ;;
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
    [ -d "$dest" ] || { mkdir -p "$dest/lib/node_modules"; cp -R "$NRT_TEMPLATE/bin" "$dest/bin"; }
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

nrt_env() {
  env -u XDG_DATA_HOME FNM_DIR="$nrt_fnm" NRT_LOG="$nrt_log" NRT_REMOTE="$nrt_remote" \
    NRT_TEMPLATE="$nrt_template" NRT_CATALOG="$nrt_catalog" NRT_PACKAGE_BIN="$nrt_root/package-bin" \
    ROUNDHOUSE_TEST_NPM_FIXED_DIRS= ROUNDHOUSE_TEST_FNM_FIXED_DIRS= \
    ROUNDHOUSE_FLEET_STORE="${nrt_store_override:-$nrt_store}" PATH="$nrt_bin:$PATH" "$@"
}

nrt_reset() {
  # One installed version, v26.0.0, as the default, carrying a managed
  # service package with a hook bin, a managed plain package, an unmanaged
  # global and npm itself.
  rm -rf "$nrt_fnm"
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
  FNM_DIR=$nrt_fnm
  NRT_LOG=$nrt_log
  NRT_REMOTE=$nrt_remote
  NRT_TEMPLATE=$nrt_template
  NRT_CATALOG=$nrt_catalog
  NRT_PACKAGE_BIN=$nrt_root/package-bin
  ROUNDHOUSE_TEST_NPM_FIXED_DIRS=
  ROUNDHOUSE_TEST_FNM_FIXED_DIRS=
  export FNM_DIR NRT_LOG NRT_REMOTE NRT_TEMPLATE NRT_CATALOG NRT_PACKAGE_BIN \
    ROUNDHOUSE_TEST_NPM_FIXED_DIRS ROUNDHOUSE_TEST_FNM_FIXED_DIRS
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
  node_version_newer v26.10.0 v26.2.0 || fail "Node versions compared as strings"
  if node_version_newer v26.2.0 v26.10.0 || node_version_newer v26.2.0 v26.2.0; then
    fail "an older or equal Node version read as newer"
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

  # --- the switch: failures after the default moved restore it --------------
  nrt_status=0
  NRT_NPM_FAIL_INSTALL=1 node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 1 ] && [ "$(nrt_default)" = v26.0.0 ] ||
    fail "a failed carry did not restore the previous fnm default"
  ! grep -Fq 'bin svc' "$nrt_log" || fail "a hook ran after the carry failed"
  nrt_reset
  nrt_status=0
  NRT_HOOK_FAIL=1 node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 1 ] && [ "$(nrt_default)" = v26.0.0 ] ||
    fail "a failed post-switch hook did not restore the previous fnm default"
  nrt_status=0
  NRT_FNM_FAIL_INSTALL=1 node_runtime_switch v26.2.0 "$nrt_carry" "$nrt_hooks" 2>/dev/null ||
    nrt_status=$?
  [ "$nrt_status" -eq 1 ] && [ "$(nrt_default)" = v26.0.0 ] ||
    fail "a failed fnm install moved the default"

  # --- the switch: success --------------------------------------------------
  nrt_reset
  node_runtime_switch v26.10.0 "$nrt_carry" "$nrt_hooks" ||
    fail "a valid Node switch failed"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the switch did not move the fnm default"
  [ "$(nrt_globals v26.10.0)" = '{"@example/svc":"1.0.0","plain":"2.0.0"}' ] ||
    fail "the switch did not carry exactly the managed globals at their versions"
  grep -Fq "npm install --global @example/svc@1.0.0 plain@2.0.0 node=v26.10.0" "$nrt_log" ||
    fail "the carry was not one exact install under the new node"
  grep -Fq 'bin svc service node=v26.10.0' "$nrt_log" ||
    fail "the post-switch hook did not run under the new node"
  [ -x "$nrt_fnm/node-versions/v26.0.0/installation/bin/node" ] &&
    [ "$(jq -r '.unmanaged' "$nrt_fnm/node-versions/v26.0.0/installation/globals.json")" = 0.1.0 ] ||
    fail "the switch removed the old version or its globals"

  # --- the desired-state plan: what to carry, which hooks, when to hold ------
  nrt_reset
  nrt_defs='{"packages":{
    "svc":{"npm":{"name":"@example/svc","node_switch":[["svc","service"]]}},
    "plain":{"npm":"plain"},
    "absent":{"npm":"absent-pkg"},
    "brewonly":{"homebrew":"brewonly"},
    "npm-off":{"npm":"unavailable","homebrew":"unmanaged"},
    "bad-name":{"npm":"../escape"},
    "bad-hook":{"npm":{"name":"plain","node_switch":["svc service"]}}}}'
  # npm-off is enabled and installed as a global, but its definition says npm
  # is unavailable: deliberately not an npm global, never carried, never a hold.
  nrt_fold='{"packages":{"svc":"enabled","plain":{"state":"enabled"},"absent":"enabled","brewonly":"enabled","npm-off":"enabled","off":"disabled"},"runtimes":{"node":{"major":26}}}'
  nrt_globals_now=$(npm_global_list)
  [ "$(fleet_resolve_package "$nrt_defs" svc homebrew npm | jq -c '.attributes.node_switch')" = \
    '[["svc","service"]]' ] || fail "a declared node_switch hook did not ride through the resolver"
  nrt_status=0
  fleet_resolve_package "$nrt_defs" bad-hook npm >/dev/null || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "a node_switch that is not a list of argv resolved"
  printf '%s\n' '{"version":1,"node_switch_hooks":{"npm:@example/svc":[["svc","service"],["svc","shim"]]}}' \
    >"$nrt_root/local-declared.json"
  printf '%s\n' '{"version":1}' >"$nrt_root/local-undeclared.json"
  printf '%s\n' '{"version":1,"node_switch_hooks":{"npm:@example/svc":[["svc","restart"]]}}' \
    >"$nrt_root/local-mismatched.json"
  nrt_plan=$(ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_node_plan "$nrt_fold" "$nrt_defs" "homebrew npm" "$nrt_globals_now")
  [ "$(printf '%s\n' "$nrt_plan" | jq -c '.carry')" = \
    '[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"}]' ] ||
    fail "the carry was not exactly the enabled, installed npm packages of the fold"
  # Local configuration may add host-only hooks; the definition's are a floor.
  [ "$(printf '%s\n' "$nrt_plan" | jq -c '[.hooks[].argv]')" = '[["svc","service"],["svc","shim"]]' ] &&
    [ "$(printf '%s\n' "$nrt_plan" | jq -r '.held')" = null ] ||
    fail "the locally declared post-switch hooks were not planned"
  [ "$(printf '%s\n' "$nrt_plan" | jq -c '.unmanaged')" = '["npm","unmanaged"]' ] ||
    fail "unmanaged globals were not reported"
  for nrt_local in local-undeclared local-mismatched; do
    ROUNDHOUSE_CONFIG=$nrt_root/$nrt_local.json \
      fleet_run_node_plan "$nrt_fold" "$nrt_defs" "homebrew npm" "$nrt_globals_now" |
      jq -e '.held | contains("packages.svc requires node_switch hook")' >/dev/null ||
      fail "a store-only post-switch hook did not hold the switch ($nrt_local)"
  done
  # An enabled package declared as an npm global that does not resolve (a
  # malformed name or node_switch) cannot be carried: it holds the switch
  # rather than being silently left behind in the old prefix. On a host that
  # does not manage npm it is not a carry candidate at all.
  for nrt_bad_item in bad-name bad-hook; do
    nrt_bad_fold=$(printf '%s\n' "$nrt_fold" | jq -c --arg p "$nrt_bad_item" '.packages[$p] = "enabled"')
    ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
      fleet_run_node_plan "$nrt_bad_fold" "$nrt_defs" "homebrew npm" "$nrt_globals_now" |
      jq -e --arg p "$nrt_bad_item" '.held | startswith("packages.\($p) is declared as an npm global but does not resolve to npm on this host")' \
      >/dev/null || fail "an unresolvable npm global did not hold the switch ($nrt_bad_item)"
    ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
      fleet_run_node_plan "$nrt_bad_fold" "$nrt_defs" "homebrew" "$nrt_globals_now" |
      jq -e '.held == null and .carry == []' >/dev/null ||
      fail "a host without npm held the switch on an npm definition ($nrt_bad_item)"
  done
  # The managed set must be CERTAIN: a held definition or package (signature,
  # review, canary or apply hold, the same hold file the package pass reads)
  # holds the switch, naming the item.
  mkdir -p "$nrt_root/plan-holds"
  : >"$nrt_root/plan-holds/verdicts"
  for nrt_hold_line in 'definitions.packages.svc signature from an unverifiable commit' \
    'packages.plain canary evidence unavailable' 'packages.svc held by review'; do
    printf '%s\n' "$nrt_hold_line" >"$nrt_root/plan-holds/sigholds"
    ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
      fleet_run_node_plan "$nrt_fold" "$nrt_defs" "homebrew npm" "$nrt_globals_now" '{}' \
        "$nrt_root/plan-holds" |
      jq -e --arg item "${nrt_hold_line%% *}" '.held | startswith("\($item) is held this run")' >/dev/null ||
      fail "a held managed-set item did not hold the switch: $nrt_hold_line"
  done
  printf 'packages.brewonly canary evidence unavailable\n' >"$nrt_root/plan-holds/sigholds"
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_node_plan "$nrt_fold" "$nrt_defs" "homebrew npm" "$nrt_globals_now" '{}' \
      "$nrt_root/plan-holds" | jq -e '.held == null' >/dev/null ||
    fail "a held package outside the managed npm set held the switch"
  # A global applied/ records as installed for a package (the npm annotation)
  # that is still installed but would no longer be carried holds the switch;
  # a deliberately disabled package, or an annotated global no longer
  # installed, does not.
  nrt_prev_fold=$(printf '%s\n' "$nrt_fold" | jq -c '.packages["old-tool"] = "enabled"')
  nrt_prev_applied='{"items":{"packages.old-tool":{"digest":"d","at":"t","npm":["unmanaged"]}}}'
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_node_plan "$nrt_prev_fold" "$nrt_defs" "homebrew npm" "$nrt_globals_now" \
      "$nrt_prev_applied" | jq -e '.held | startswith("packages.old-tool was installed as the npm global unmanaged")' \
      >/dev/null || fail "a previously managed global that would not be carried did not hold the switch"
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_node_plan "$(printf '%s\n' "$nrt_fold" | jq -c '.packages["old-tool"] = "disabled"')" \
      "$nrt_defs" "homebrew npm" "$nrt_globals_now" "$nrt_prev_applied" | jq -e '.held == null' >/dev/null ||
    fail "a disabled previously managed package held the switch"
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_node_plan "$nrt_prev_fold" "$nrt_defs" "homebrew npm" \
      "$(printf '%s\n' "$nrt_globals_now" | jq -c 'del(.unmanaged)')" "$nrt_prev_applied" |
    jq -e '.held == null' >/dev/null ||
    fail "an annotated global that is no longer installed held the switch"
  # The annotation is written with the applied record and survives a re-record.
  mkdir -p "$nrt_root/annotate-store/applied"
  fleet_applied_record "$nrt_root/annotate-store" nrt-host packages.svc d1 t1
  fleet_run_annotate_npm "$nrt_root/annotate-store" nrt-host packages.svc "$nrt_defs" "homebrew npm"
  fleet_run_annotate_npm "$nrt_root/annotate-store" nrt-host packages.brewonly "$nrt_defs" "homebrew npm"
  fleet_applied_record "$nrt_root/annotate-store" nrt-host packages.svc d2 t2
  [ "$(fleet_record_read "$(fleet_applied_path "$nrt_root/annotate-store" nrt-host)" '{}' |
    jq -c '.items["packages.svc"] | [.digest,.npm]')" = '["d2",["@example/svc"]]' ] ||
    fail "the applied record did not keep which npm global a package was installed as"

  # --- desired-state convergence ----------------------------------------------
  nrt_converge() {
    ROUNDHOUSE_CONFIG=$nrt_root/$1.json fleet_run_node_converge "$2" "$nrt_defs" "$nrt_fold" \
      "homebrew npm" "$3" >"$nrt_root/converge-out" 2>&1
  }
  # A default already inside the declared major is the desired state on the
  # reviewed apply; nothing is fetched or switched.
  nrt_converge local-declared '{"major":26}' apply || fail "an in-line default did not converge"
  ! grep -Eq 'fnm (install|default|list-remote)' "$nrt_log" ||
    fail "the reviewed apply touched fnm for a default already in its major"
  # A malformed npm global in the fold holds the switch before anything moves.
  nrt_status=0
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json fleet_run_node_converge '{"major":26}' \
    "$nrt_defs" "$(printf '%s\n' "$nrt_fold" | jq -c '.packages["bad-name"] = "enabled"')" \
    "homebrew npm" full >"$nrt_root/converge-out" 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq '  hold  runtimes.node — packages.bad-name is declared as an npm global but does not resolve' \
      "$nrt_root/converge-out" ||
    fail "a switch ran while an enabled npm global could not be resolved"
  ! grep -Eq 'fnm (install|default) |npm install' "$nrt_log" ||
    fail "a switch held for an unresolvable npm global still installed something"
  # A held managed-set definition holds a scheduled switch before anything moves.
  mkdir -p "$nrt_root/converge-holds"
  printf 'definitions.packages.svc signature from an unverifiable commit\n' >"$nrt_root/converge-holds/sigholds"
  : >"$nrt_root/converge-holds/verdicts"
  nrt_status=0
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json fleet_run_node_converge '{"major":26}' \
    "$nrt_defs" "$nrt_fold" "homebrew npm" full "" "" "$nrt_root/converge-holds" \
    >"$nrt_root/converge-out" 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq '  hold  runtimes.node — definitions.packages.svc is held this run' "$nrt_root/converge-out" &&
    ! grep -Eq 'fnm (install|default) |npm install' "$nrt_log" ||
    fail "a scheduled switch ran while a managed definition was held"
  # A store-only hook holds the switch and changes nothing.
  nrt_status=0
  nrt_converge local-undeclared '{"major":26}' full || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq '  hold  runtimes.node — packages.svc requires node_switch hook' "$nrt_root/converge-out" ||
    fail "the full cadence switched without the host declaring the required hook"
  ! grep -Eq 'fnm (install|default) ' "$nrt_log" || fail "a held switch still ran fnm"
  # The full cadence moves to the newest release in the line.
  nrt_converge local-declared '{"major":26}' full || fail "the full cadence did not converge the line"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the full cadence did not move to the newest in-line release"
  grep -Fq '  switch runtimes.node v26.0.0 -> v26.10.0 (carrying @example/svc@1.0.0 plain@2.0.0)' \
    "$nrt_root/converge-out" || fail "the switch was not reported with its carry"
  grep -Fq 'bin svc shim node=v26.10.0' "$nrt_log" || fail "a host-only hook did not run"
  grep -Fq '  note  runtimes.node — unmanaged npm globals stay under v26.0.0: npm unmanaged' \
    "$nrt_root/converge-out" || fail "unmanaged globals left behind were not reported"
  grep -Fq '  note  runtimes.node — older Node versions remain installed (never removed here): v26.0.0' \
    "$nrt_root/converge-out" || fail "the old Node version was not reported as left installed"
  : >"$nrt_log"
  nrt_converge local-declared '{"major":26}' full || fail "a converged line did not stay converged"
  ! grep -Eq 'fnm (install|default) ' "$nrt_log" || fail "a converged line switched again"
  # An exact pin wins over the newest release, in both directions.
  nrt_converge local-declared '{"version":"26.2.0"}' apply || fail "an exact pin did not converge"
  [ "$(nrt_default)" = v26.2.0 ] || fail "the fnm default did not move to the pinned version"
  [ "$(nrt_globals v26.2.0)" = '{"@example/svc":"1.0.0","plain":"2.0.0"}' ] ||
    fail "the pinned switch did not carry the managed globals"
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
  ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json fleet_run_node_converge '{"major":25}' \
    "$nrt_defs" '' "homebrew npm" apply >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] && [ "$(nrt_default)" = v27.0.0 ] ||
    fail "a switch without the fold ran (it would strand every managed global)"
  nrt_status=0
  nrt_converge local-declared '"enabled"' apply || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "a runtimes.node without major or version did not hold"
  nrt_status=0
  (FNM_DIR=$nrt_root/no-fnm HOME=$nrt_root/no-home \
    nrt_converge local-declared '{"major":26}' apply) || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "a host without an fnm default did not hold"

  # --- the category arm --------------------------------------------------------
  nrt_status=0
  fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.python '{"major":3}' \
    "homebrew npm" "$nrt_fold" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 75 ] || fail "an unmanaged runtime name did not hold"
  nrt_status=0
  fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '"disabled"' \
    "homebrew npm" "$nrt_fold" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 70 ] || fail "a disabled runtimes.node was not satisfied"
  [ -z "$(fleet_unknown_categories '{"runtimes":{"node":{"major":26}}}')" ] ||
    fail "runtimes is not a known category"

  # --- the full cadence runs the runtime before the npm pass --------------------
  nrt_reset
  nrt_run_full() {
    (
      fleet_trust_prune_expired() { :; }
      fleet_trust_age_evidence() { :; }
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

  # --- an unverified default keeps npm off it, and only npm ---------------------
  nrt_mixed_fold='{"packages":{"svc":"enabled","plain":"enabled","brewonly":"enabled"},"package_managers":["homebrew","npm"],"runtimes":{"node":{"major":26}}}'
  # An ordinary hold (the store requires a hook this host does not declare)
  # leaves the default untouched: the npm pass still runs.
  nrt_reset
  : >"$nrt_root/full-tmp/sigholds"
  nrt_run_full "$nrt_mixed_fold" local-undeclared
  [ "$(nrt_default)" = v26.0.0 ] &&
    grep -Fq 'npm outdated --global --json node=v26.0.0' "$nrt_log" &&
    ! grep -Fq 'npm globals skipped this pass' "$nrt_root/full-out" ||
    fail "an ordinary runtime hold skipped the npm pass"
  # A failed switch whose restore also fails (exit 70) leaves the default
  # unverified: no npm operation runs under it, brew still does, and the
  # state is reported and alerted.
  nrt_reset
  NRT_NPM_FAIL_INSTALL=1 NRT_FNM_DEFAULT_ONLY=v26.10.0 nrt_run_full "$nrt_mixed_fold"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the unrestorable-switch fixture did not leave the default moved"
  grep -Fq '  hold  runtimes.node — switch to v26.10.0 failed and the fnm default (v26.10.0) is unverified' \
    "$nrt_root/full-out" &&
    grep -Fq '  hold  packages (npm) — Node default is unverified after a failed runtime switch; npm globals skipped this pass' \
      "$nrt_root/full-out" ||
    fail "an unverified default was not reported"
  ! grep -Eq 'npm (outdated|view)|bin (svc|plain)' "$nrt_log" &&
    [ "$(grep -c 'npm install' "$nrt_log")" -eq 1 ] ||
    fail "an npm operation ran under an unverified default"
  grep -Fq 'brew upgrade brewonly' "$nrt_log" ||
    fail "an unverified Node default stopped the non-npm package pass"
  ls "$nrt_root/store/alerts/nrt-host/"*node-runtime-unverified* >/dev/null 2>&1 ||
    fail "an unverified Node default raised no alert"
  # The same state reached through this run's reviewed apply (exit 76 into the
  # run's hold file) skips npm too, and the apply arm passes 76 through.
  nrt_reset
  nrt_status=0
  NRT_NPM_FAIL_INSTALL=1 NRT_FNM_DEFAULT_ONLY=v27.0.0 ROUNDHOUSE_CONFIG=$nrt_root/local-declared.json \
    fleet_run_apply_item "$nrt_root/store" nrt-host "$nrt_defs" runtimes.node '{"major":27}' \
    "homebrew npm" "$nrt_mixed_fold" >/dev/null 2>&1 || nrt_status=$?
  [ "$nrt_status" -eq 76 ] || fail "the runtime apply arm did not report an unverified default (got $nrt_status)"
  nrt_reset
  printf 'runtimes.node apply status 76\n' >"$nrt_root/full-tmp/sigholds"
  nrt_run_full "$nrt_mixed_fold"
  ! grep -Fq 'npm outdated' "$nrt_log" && grep -Fq 'brew upgrade brewonly' "$nrt_log" &&
    grep -Fq 'npm globals skipped this pass' "$nrt_root/full-out" ||
    fail "an unverified default from the apply loop did not keep the npm pass off it"
  : >"$nrt_root/full-tmp/sigholds"
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
# The target's desired state: two managed npm globals (one requiring a hook)
# and nothing else. The sealed lane derives the managed set from it.
mkdir -p "$nrt_store/hosts" "$nrt_store/applied"
printf '%s\n' 'packages:' '  svc: enabled' '  plain: enabled' '  brewonly: enabled' \
  >"$nrt_store/hosts/test-host.yaml"
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
  printf 'NOTICE: the sealed Node switch derives its managed set from a store and needs yq; skipped\n'
else
  nrt_cli collect --target test-host --section host --section packages --output "$tmp/node-snapshot.jsonl"
  "$cli" validate "$tmp/node-snapshot.jsonl"
  [ "$(jq -c 'select(.kind == "package" and .id == "fnm:node") | .data |
    [.installed_version,.candidate_version,.update_available,.line,.installed_versions,.stale_versions,
     .globals["@example/svc"],.switch_hooks_unproven]' "$tmp/node-snapshot.jsonl")" = \
    '["v26.0.0","v26.10.0",true,"26",["v26.0.0"],[],"1.0.0",[]]' ] ||
    fail "the POSIX collector did not report the fnm runtime with its line candidate and globals"

  nrt_managed='[{"package":"plain","name":"plain","required":[]},{"package":"svc","name":"@example/svc","required":[["svc","service"]]}]'
  nrt_draft() {
    # nrt_draft CANDIDATE CARRY HOOKS ARGV... (the managed set is $nrt_managed)
    jq -n --arg candidate "$1" --argjson carry "$2" --argjson hooks "$3" \
      --argjson managed "$nrt_managed" --args \
      '{domain:"updates",target:"test-host",operations:[{type:"package-upgrade",kind:"package",
        id:"fnm:node",candidate_version:$candidate,argv:$ARGS.positional,carry:$carry,hooks:$hooks,
        managed:$managed}]}' \
      -- "${@:4}"
  }
  nrt_carry='[{"name":"@example/svc","version":"1.0.0"},{"name":"plain","version":"2.0.0"}]'
  nrt_hooks='[{"package":"npm:@example/svc","argv":["svc","service"]}]'
  nrt_seal_refused() {
    # nrt_seal_refused LABEL DRAFT-FILE
    if nrt_cli seal-plan "$2" "$tmp/node-snapshot.jsonl" "$tmp/node-refused-plan.json" >/dev/null 2>&1; then
      fail "a Node switch sealed with $1"
    fi
  }
  nrt_draft v26.10.0 "$nrt_carry" '[]' fnm default v26.10.0 >"$tmp/node-draft-nohooks.json"
  nrt_seal_refused 'its configured post-switch hook omitted' "$tmp/node-draft-nohooks.json"
  nrt_draft v26.10.0 "$nrt_carry" \
    '[{"package":"npm:@example/svc","argv":["svc","service"]},{"package":"npm:plain","argv":["plain","x"]}]' \
    fnm default v26.10.0 >"$tmp/node-draft-extrahook.json"
  nrt_seal_refused 'a post-switch hook the configuration does not declare' "$tmp/node-draft-extrahook.json"
  nrt_draft v26.10.0 '[{"name":"plain","version":"9.9.9"}]' '[]' fnm default v26.10.0 \
    >"$tmp/node-draft-wrongcarry.json"
  nrt_seal_refused 'a carried version that is not installed' "$tmp/node-draft-wrongcarry.json"
  nrt_draft v26.10.0 "$nrt_carry" "$nrt_hooks" fnm install v26.10.0 >"$tmp/node-draft-argv.json"
  nrt_seal_refused 'an argv other than the fixed marker' "$tmp/node-draft-argv.json"
  nrt_draft v26.2.0 "$nrt_carry" "$nrt_hooks" fnm default v26.2.0 >"$tmp/node-draft-notcandidate.json"
  nrt_seal_refused 'a version that is not the observed candidate' "$tmp/node-draft-notcandidate.json"
  jq '.operations[0].id = "fnm:python"' "$tmp/node-draft-nohooks.json" >"$tmp/node-draft-otherid.json"
  nrt_seal_refused 'a runtime other than node' "$tmp/node-draft-otherid.json"
  # The carry must be the COMPLETE managed set that is installed, with the
  # managed set the store states: empty, partial and misstated all refused.
  nrt_draft v26.10.0 '[]' '[]' fnm default v26.10.0 >"$tmp/node-draft-empty.json"
  nrt_seal_refused 'an empty carry' "$tmp/node-draft-empty.json"
  nrt_draft v26.10.0 '[{"name":"@example/svc","version":"1.0.0"}]' "$nrt_hooks" fnm default v26.10.0 \
    >"$tmp/node-draft-partial.json"
  nrt_seal_refused 'a partial carry' "$tmp/node-draft-partial.json"
  (nrt_managed='[{"package":"svc","name":"@example/svc","required":[["svc","service"]]}]'
    nrt_draft v26.10.0 '[{"name":"@example/svc","version":"1.0.0"}]' "$nrt_hooks" fnm default v26.10.0) \
    >"$tmp/node-draft-short-managed.json"
  nrt_seal_refused 'a managed set the store does not state' "$tmp/node-draft-short-managed.json"
  nrt_draft v26.10.0 "$nrt_carry" "$nrt_hooks" fnm default v26.10.0 >"$tmp/node-draft.json"
  if nrt_store_override="$nrt_root/no-store" nrt_cli seal-plan "$tmp/node-draft.json" \
    "$tmp/node-snapshot.jsonl" "$tmp/node-refused-plan.json" >/dev/null 2>&1; then
    fail "a Node switch sealed without the store desired state"
  fi
  jq -c 'if .kind == "package" and .id == "fnm:node" then .data.switch_hooks_unproven = ["npm:@example/svc"] else . end' \
    "$tmp/node-snapshot.jsonl" >"$tmp/node-unproven-snapshot.jsonl"
  nrt_draft v26.10.0 "$nrt_carry" "$nrt_hooks" fnm default v26.10.0 >"$tmp/node-draft.json"
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
  # Apply re-derives the managed set from the store as it is now: a package
  # that became a managed npm global after sealing refuses the plan.
  cp "$nrt_store/hosts/test-host.yaml" "$nrt_root/host.yaml.sealed"
  printf '%s\n' '  unmanaged-now-managed: enabled' >>"$nrt_store/hosts/test-host.yaml"
  printf '%s\n' '  unmanaged-now-managed: {npm: unmanaged}' >>"$nrt_store/definitions.yaml"
  if nrt_cli apply-plan "$tmp/node-plan-2.json" "$nrt_plan_id" "$tmp/node-changed-apply.jsonl" \
    >"$nrt_root/changed-apply.log" 2>&1; then
    fail "a Node switch applied although its managed set changed after sealing"
  fi
  grep -Fq 'the managed npm globals changed since planning' "$nrt_root/changed-apply.log" &&
    [ "$(nrt_default)" = v26.0.0 ] ||
    fail "a changed managed set was not refused before the switch"
  cp "$nrt_root/host.yaml.sealed" "$nrt_store/hosts/test-host.yaml"
  sed -i.bak '/unmanaged-now-managed/d' "$nrt_store/definitions.yaml"

  : >"$nrt_log"
  nrt_cli apply-plan "$tmp/node-plan-2.json" "$nrt_plan_id" "$tmp/node-apply.jsonl"
  [ "$(nrt_default)" = v26.10.0 ] || fail "the sealed switch did not move the fnm default"
  [ "$(jq -c 'select(.kind == "package" and .id == "fnm:node") | [.data.installed_version,.data.globals]' \
    "$tmp/node-apply.jsonl")" = '["v26.10.0",{"@example/svc":"1.0.0","plain":"2.0.0"}]' ] ||
    fail "the sealed switch post-inventory did not show the carried globals under the new default"
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

  # --- the SSH lane: store check on the controller, snapshot checks on the worker
  # The worker's own store is never consulted for a remote plan: here it is
  # absent on the target side (the ssh wrapper points the remote environment
  # at no store), and a plan the controller's store still vouches for applies.
  nrt_reset
  jq '.machines["test-ssh"].package_managers = ["homebrew","npm"] |
    .node_switch_hooks = {"npm:@example/svc":[["svc","service"]]}' \
    "$tmp/config.json" >"$tmp/node-ssh-config.json"
  chmod 600 "$tmp/node-ssh-config.json"
  cp "$nrt_store/hosts/test-host.yaml" "$nrt_store/hosts/test-ssh.yaml"
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
  # The controller's store no longer vouches for the plan: refused on the
  # controller, before any worker input (plan, worker config) is transferred.
  # The only transfers are the controller's own read-only inventory.
  cp "$nrt_store/hosts/test-ssh.yaml" "$nrt_root/ssh-host.yaml.sealed"
  printf '%s\n' '  unmanaged-now-managed: enabled' >>"$nrt_store/hosts/test-ssh.yaml"
  printf '%s\n' '  unmanaged-now-managed: {npm: unmanaged}' >>"$nrt_store/definitions.yaml"
  : >"$SCP_COMMAND_LOG"
  if nrt_ssh_cli apply-ssh-plan "$tmp/node-ssh-plan.json" "$nrt_ssh_plan_id" \
    "$tmp/node-ssh-refused.jsonl" >"$nrt_root/ssh-refused.log" 2>&1; then
    fail "an SSH Node switch applied although the controller store no longer vouches for it"
  fi
  grep -Fq 'the managed npm globals changed since planning' "$nrt_root/ssh-refused.log" &&
    ! grep -Eq 'plan\.json|roundhouse-apply\.' "$SCP_COMMAND_LOG" && [ "$(nrt_default)" = v26.0.0 ] ||
    fail "a controller-side Node check mismatch was not refused before any transfer"
  cp "$nrt_root/ssh-host.yaml.sealed" "$nrt_store/hosts/test-ssh.yaml"
  sed -i.bak '/unmanaged-now-managed/d' "$nrt_store/definitions.yaml"
  : >"$nrt_log"
  nrt_ssh_cli apply-ssh-plan "$tmp/node-ssh-plan.json" "$nrt_ssh_plan_id" "$tmp/node-ssh-apply.jsonl" ||
    fail "an SSH Node switch refused because the target has no store"
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
    fleet_node_snapshot_verify "$tmp/node-ssh-plan.json" "$tmp/node-ssh-snapshot.jsonl" \
      "$tmp/node-ssh-config.json" || fail "the worker rejected a carry its snapshot proves"
    if fleet_node_snapshot_verify "$tmp/node-ssh-plan.json" "$tmp/node-ssh-uninstalled.jsonl" \
      "$tmp/node-ssh-config.json"; then
      fail "the worker accepted a carry its snapshot does not prove"
    fi
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
