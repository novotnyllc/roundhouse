# roundhouse self-check — the npm global-package manager: durable resolution,
# definitions, the desired-state install/update pass, and the sealed-plan
# lifecycle (collect, seal, apply, post-state) with and without a package's
# own updater.
#
# Everything runs against a stub npm inside a fixture fnm tree; the real npm
# on the machine running the suite is never reachable (FNM_DIR points at the
# fixture and the fixed Homebrew/system fallbacks are switched off).
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

printf 'npm: durable npm, definitions, desired-state pass, sealed lifecycle\n'
nfx_root="$tmp/npm-fixture"
nfx_fnm="$nfx_root/fnm"
nfx_install_dir="$nfx_fnm/node-versions/v26.0.0/installation"
nfx_modules="$nfx_install_dir/lib/node_modules"
mkdir -p "$nfx_install_dir/bin" "$nfx_modules/npm" "$nfx_modules/@example/tool/bin" \
  "$nfx_fnm/aliases" "$nfx_root/multishell/fnm_multishells/4242/bin" "$nfx_root/bare-bin"
ln -s "$nfx_install_dir" "$nfx_fnm/aliases/default"
nfx_state="$nfx_root/state.json"
nfx_latest="$nfx_root/latest.json"
nfx_log="$nfx_root/npm.log"
# The prefix npm reports is the physical installation, exactly as under fnm.
nfx_prefix_physical=$(CDPATH='' cd -P -- "$nfx_install_dir" && pwd -P)

cat >"$nfx_install_dir/bin/node" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf 'v26.0.0\n'; exit 0; }
exit 0
SH
# The stub records WHICH node a child would get, because that is the prefix a
# real npm would install into.
cat >"$nfx_install_dir/bin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
state=$NPM_STUB_STATE
latest=$NPM_STUB_LATEST
self_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)
prefix=$(dirname -- "$self_dir")
printf '%s node=%s\n' "$*" "$(command -v node)" >>"$NPM_STUB_LOG"
case "$1 ${2:-}" in
  "prefix --global") printf '%s\n' "$prefix" ;;
  "root --global") printf '%s/lib/node_modules\n' "$prefix" ;;
  "ls --global")
    [ "${NPM_STUB_LS_FAIL:-0}" != 1 ] ||
      { printf '%s\n' '{"error":{"code":"ENOTDIR","summary":"prefix is not a directory"}}'; exit 1; }
    jq -c '{name:"lib",dependencies:(with_entries(.value = {version:.value}))}' "$state" ;;
  "outdated --global")
    [ "${NPM_STUB_OUTDATED_EMPTY:-0}" != 1 ] || exit 0
    [ "${NPM_STUB_OUTDATED_FAIL:-0}" != 1 ] ||
      { printf '%s\n' '{"error":{"code":"E500","summary":"registry"}}'; exit 1; }
    jq -c --slurpfile latest "$latest" '
      to_entries | map(select($latest[0][.key] != null and $latest[0][.key] != .value) |
        {key, value:{current:.value, wanted:$latest[0][.key], latest:$latest[0][.key],
          dependent:"global"}}) | from_entries' "$state"
    [ "$(jq --slurpfile latest "$latest" '[to_entries[] | select($latest[0][.key] != null and $latest[0][.key] != .value)] | length' "$state")" -eq 0 ] || exit 1
    ;;
  "view "*)
    [ "${3:-}" = version ] || exit 64
    if [ -n "${NPM_STUB_VIEW_VERSION:-}" ]; then
      printf '%s\n' "$NPM_STUB_VIEW_VERSION"
    else
      jq -r --arg n "$2" '.[$n]' "$latest"
    fi
    ;;
  "install --global")
    spec=$3
    case $spec in
      @*) name="@${spec#@}"; name="${name%@*}"; version="${spec##*@}" ;;
      *) name="${spec%@*}"; version="${spec##*@}" ;;
    esac
    [ "$version" != latest ] || version=$(jq -r --arg n "$name" '.[$n]' "$latest")
    [ -z "${NPM_STUB_INSTALL_VERSION:-}" ] || version=$NPM_STUB_INSTALL_VERSION
    jq --arg n "$name" --arg v "$version" '.[$n] = $v' "$state" >"$state.next"
    mv "$state.next" "$state"
    ;;
  *) exit 64 ;;
esac
SH
cat >"$nfx_modules/@example/tool/bin/tool.js" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'tool %s node=%s\n' "$*" "$(command -v node)" >>"$NPM_STUB_LOG"
[ "${1:-}" = update ] || exit 64
version=$(jq -r '.["@example/tool"]' "$NPM_STUB_LATEST")
jq --arg v "$version" '.["@example/tool"] = $v' "$NPM_STUB_STATE" >"$NPM_STUB_STATE.next"
mv "$NPM_STUB_STATE.next" "$NPM_STUB_STATE"
SH
printf '%s\n' '{"name":"@example/tool","version":"1.0.0","bin":{"tool":"bin/tool.js"}}' \
  >"$nfx_modules/@example/tool/package.json"
printf '%s\n' '{"name":"npm","version":"11.0.0","bin":{"npm":"bin/npm-cli.js"}}' \
  >"$nfx_modules/npm/package.json"
ln -s ../lib/node_modules/@example/tool/bin/tool.js "$nfx_install_dir/bin/tool"
# A same-named bin that does NOT belong to the package: must never run.
cat >"$nfx_install_dir/bin/impostor" <<'SH'
#!/usr/bin/env bash
: >"$NPM_STUB_IMPOSTOR"
SH
chmod 755 "$nfx_install_dir/bin/node" "$nfx_install_dir/bin/npm" \
  "$nfx_modules/@example/tool/bin/tool.js" "$nfx_install_dir/bin/impostor"
cp "$nfx_install_dir/bin/npm" "$nfx_install_dir/bin/node" "$nfx_root/multishell/fnm_multishells/4242/bin/"
cp "$nfx_install_dir/bin/npm" "$nfx_root/bare-bin/npm"
# The collector also reports the fnm runtime under these globals (fnm:node).
# A stub fnm keeps that off the network and off any real fnm on the machine
# running the suite: one published release, the installed default.
mkdir -p "$nfx_root/fnm-bin"
cat >"$nfx_root/fnm-bin/fnm" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-remote ] && { printf 'v26.0.0\n'; exit 0; }
exit 64
SH
chmod 755 "$nfx_root/fnm-bin/fnm"

nfx_reset_state() {
  printf '%s\n' '{"npm":"11.0.0","@example/tool":"1.0.0","current-only":"3.0.0"}' >"$nfx_state"
  printf '%s\n' '{"npm":"12.1.0","@example/tool":"2.0.0","current-only":"3.0.0"}' >"$nfx_latest"
  : >"$nfx_log"
}
nfx_reset_state

(
  set -eu
  unset XDG_DATA_HOME
  FNM_DIR=$nfx_fnm
  NPM_STUB_STATE=$nfx_state
  NPM_STUB_LATEST=$nfx_latest
  NPM_STUB_LOG=$nfx_log
  NPM_STUB_IMPOSTOR=$nfx_root/impostor-ran
  ROUNDHOUSE_TEST_NPM_FIXED_DIRS=
  ROUNDHOUSE_TEST_FNM_FIXED_DIRS=
  export FNM_DIR NPM_STUB_STATE NPM_STUB_LATEST NPM_STUB_LOG NPM_STUB_IMPOSTOR \
    ROUNDHOUSE_TEST_NPM_FIXED_DIRS ROUNDHOUSE_TEST_FNM_FIXED_DIRS
  [ -z "$fleet_fixture_yq" ] || PATH=$fleet_fixture_path
  PATH=$nfx_root/fnm-bin:$PATH
  export PATH
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # --- grammar --------------------------------------------------------------
  npm_package_name_valid @bitkyc08/opencodex && npm_package_name_valid npm ||
    fail "a valid npm registry name was refused"
  for nfx_bad in '../x' 'a b' '-rf' '@scope/' "x"$'\n'"y" ''; do
    if npm_package_name_valid "$nfx_bad"; then
      fail "an invalid npm name was accepted: $nfx_bad"
    fi
  done
  npm_updater_argv_valid ocx update || fail "a plain updater argv was refused"
  for nfx_bad_argv in 'ocx;rm' '../ocx' '$(x)' ''; do
    if npm_updater_argv_valid "$nfx_bad_argv" update; then
      fail "an unsafe updater argv[0] was accepted: $nfx_bad_argv"
    fi
  done
  if npm_updater_argv_valid ocx 'update; rm -rf ~'; then
    fail "an updater argument containing shell syntax was accepted"
  fi

  # --- durable resolution -----------------------------------------------------
  # fnm's `default` alias wins over PATH, and npm runs under ITS OWN node.
  [ "$(npm_global_bin_dir)" = "$nfx_fnm/aliases/default/bin" ] ||
    fail "the fnm default alias was not the durable npm"
  npm_global_run prefix --global >/dev/null
  grep -Fq "node=$nfx_fnm/aliases/default/bin/node" "$nfx_log" ||
    fail "npm did not run under the node that owns its prefix"
  # A per-shell multishell path is never durable, even when it is on PATH.
  if (FNM_DIR=$nfx_root/no-fnm HOME=$nfx_root/no-home \
    PATH="$nfx_root/multishell/fnm_multishells/4242/bin:$PATH" npm_global_bin_dir) >/dev/null; then
    fail "an fnm_multishells npm was accepted as durable"
  fi
  # An npm with no node beside it would run under whatever node PATH offers.
  if (FNM_DIR=$nfx_root/no-fnm HOME=$nfx_root/no-home \
    PATH="$nfx_root/bare-bin:$PATH" npm_global_bin_dir) >/dev/null; then
    fail "an npm without its own node was accepted"
  fi
  [ "$(ROUNDHOUSE_SELFTEST=0 FNM_DIR=$nfx_root/no-fnm HOME=$nfx_root/no-home \
    ROUNDHOUSE_TEST_NPM_FIXED_DIRS="$nfx_install_dir/bin" npm_global_bin_dir || true)" != \
    "$nfx_install_dir/bin" ] ||
    fail "the fixed-directory test hook was honoured outside the self-check"
  [ "$(npm_global_list | jq -r '.["@example/tool"]')" = 1.0.0 ] ||
    fail "npm global inventory did not parse npm ls"
  # A fatal npm ls prints only an `error` object; that is a failed query, not
  # an empty global tree.
  if NPM_STUB_LS_FAIL=1 npm_global_list >/dev/null; then
    fail "an npm ls error object read as 'no global packages'"
  fi
  [ "$(npm_global_outdated | jq -c .)" = '{"npm":"12.1.0","@example/tool":"2.0.0"}' ] ||
    fail "npm outdated parsing did not tolerate its exit status 1"
  # npm prints `{}` itself when nothing is outdated; EMPTY output is a failed
  # query and must never read as "all current".
  if NPM_STUB_OUTDATED_EMPTY=1 npm_global_outdated >/dev/null; then
    fail "empty npm outdated output read as 'nothing outdated'"
  fi
  [ "$(npm_registry_latest @example/tool)" = 2.0.0 ] ||
    fail "the registry latest query did not read npm view"
  if NPM_STUB_VIEW_VERSION='2.0.0 extra' npm_registry_latest @example/tool >/dev/null; then
    fail "a malformed npm view answer was accepted as a version"
  fi
  if NPM_STUB_OUTDATED_FAIL=1 npm_global_outdated >/dev/null; then
    fail "an npm outdated error object read as 'nothing outdated'"
  fi

  # The updater must be a bin of THIS package, linked into its directory.
  [ "$(npm_updater_path @example/tool tool)" = "$nfx_prefix_physical/bin/tool" ] ||
    fail "the package's own bin was not proven as its updater"
  if npm_updater_path @example/tool impostor >/dev/null 2>&1; then
    fail "a bin the package does not declare was accepted as its updater"
  fi
  jq '.bin.impostor = "bin/tool.js"' "$nfx_modules/@example/tool/package.json" \
    >"$nfx_root/package.json.next"
  cp "$nfx_modules/@example/tool/package.json" "$nfx_root/package.json.orig"
  mv "$nfx_root/package.json.next" "$nfx_modules/@example/tool/package.json"
  if npm_updater_path @example/tool impostor >/dev/null 2>&1; then
    fail "a declared bin whose link leaves the package directory was accepted"
  fi
  mv "$nfx_root/package.json.orig" "$nfx_modules/@example/tool/package.json"
  if npm_global_run_updater @example/tool impostor >/dev/null 2>&1 ||
    [ -e "$NPM_STUB_IMPOSTOR" ]; then
    fail "a non-package bin ran as an updater"
  fi

  # --- definitions ------------------------------------------------------------
  nfx_defs='{"packages":{
    "opencodex":{"npm":{"name":"@bitkyc08/opencodex","update":["ocx","update"]}},
    "npm":{"npm":"npm"},
    "pinned-tool":{"version":"2.0.0","npm":{"name":"@example/tool"}},
    "bad-updater":{"npm":{"name":"@example/tool","update":["ocx; rm -rf ~"]}},
    "bad-name":{"npm":"../escape"}}}'
  nfx_resolved=$(fleet_resolve_package "$nfx_defs" opencodex homebrew npm)
  [ "$(printf '%s\n' "$nfx_resolved" | jq -r '[.manager,.name] | join(" ")')" = \
    'npm @bitkyc08/opencodex' ] ||
    fail "a declared npm global did not resolve to npm ahead of the system manager"
  [ "$(printf '%s\n' "$nfx_resolved" | jq -c '.attributes.update')" = '["ocx","update"]' ] ||
    fail "the declared updater did not ride through as argv"
  nfx_status=0
  nfx_held=$(fleet_resolve_package "$nfx_defs" opencodex homebrew) || nfx_status=$?
  [ "$nfx_status" -eq 75 ] &&
    printf '%s\n' "$nfx_held" | jq -e '.detail | contains("npm global")' >/dev/null ||
    fail "an npm global was guessed as a system package on a host without npm"
  [ "$(fleet_resolve_package '{}' jq npm homebrew | jq -r '.manager')" = homebrew ] ||
    fail "npm applied the default rule to an undeclared package"
  nfx_status=0
  fleet_resolve_package '{}' jq npm >/dev/null || nfx_status=$?
  [ "$nfx_status" -eq 75 ] || fail "an npm-only host guessed an undeclared package"
  [ "$(fleet_resolve_package "$nfx_defs" pinned-tool npm | jq -r '[.pin,.version] | join(" ")')" = \
    'flag 2.0.0' ] || fail "an npm version pin did not resolve as an install-time flag"
  for nfx_bad_item in bad-updater bad-name; do
    nfx_status=0
    fleet_resolve_package "$nfx_defs" "$nfx_bad_item" npm >/dev/null || nfx_status=$?
    [ "$nfx_status" -eq 75 ] || fail "a malformed npm definition resolved: $nfx_bad_item"
  done

  # --- desired-state install -------------------------------------------------
  nfx_reset_state
  fleet_install_package npm @example/tool false 2.0.0 ||
    fail "the desired-state npm install did not converge a pin"
  [ "$(jq -r '.["@example/tool"]' "$nfx_state")" = 2.0.0 ] ||
    fail "the pinned npm install did not install the pinned version"
  nfx_reset_state
  nfx_status=0
  NPM_STUB_INSTALL_VERSION=1.5.0 fleet_install_package npm @example/tool false 2.0.0 ||
    nfx_status=$?
  [ "$nfx_status" -ne 0 ] || fail "an npm install that missed its pin was reported applied"
  nfx_status=0
  (FNM_DIR=$nfx_root/no-fnm HOME=$nfx_root/no-home PATH=/usr/bin:/bin \
    fleet_install_package npm @example/tool false '') || nfx_status=$?
  [ "$nfx_status" -eq 75 ] || fail "a host without npm did not hold the install (got $nfx_status)"

  # --- full cadence ------------------------------------------------------------
  nfx_run_full() {
    (
      fleet_trust_prune_expired() { :; }
      fleet_trust_age_evidence() { :; }
      fleet_enroll_process_joins() { :; }
      fleet_seed_command() { :; }
      fleet_run_proposals() { :; }
      fleet_doctor_command() { :; }
      ROUNDHOUSE_CONFIG=$3
      export ROUNDHOUSE_CONFIG
      fleet_run_full_pass "$nfx_root/store" npm-host "$1" "$2" \
        "$nfx_root/layers" "$nfx_root/full-tmp" >"$nfx_root/full-out" 2>&1
    )
  }
  mkdir -p "$nfx_root/store" "$nfx_root/layers" "$nfx_root/full-tmp"
  # The scheduled pass runs a definition's updater only when THIS host's own
  # config.json declares the identical argv: store content, which every
  # synced host can write, must never introduce a command on its own.
  printf '%s\n' '{"version":1,"package_updaters":{"npm:@example/tool":["tool","update"]}}' \
    >"$nfx_root/local-declared.json"
  printf '%s\n' '{"version":1}' >"$nfx_root/local-undeclared.json"
  printf '%s\n' '{"version":1,"package_updaters":{"npm:@example/tool":["tool","upgrade"]}}' \
    >"$nfx_root/local-mismatched.json"
  nfx_full_fold='{"packages":{"opencodex-fixture":"enabled","npm":"enabled","current-only":"enabled"},"package_managers":["homebrew","npm"]}'
  nfx_full_defs='{"packages":{"opencodex-fixture":{"npm":{"name":"@example/tool","update":["tool","update"]}},"npm":{"npm":"npm"},"current-only":{"npm":"current-only"}}}'
  for nfx_local in local-undeclared local-mismatched; do
    nfx_reset_state
    nfx_run_full "$nfx_full_fold" "$nfx_full_defs" "$nfx_root/$nfx_local.json"
    ! grep -Fq 'tool update' "$nfx_log" && ! grep -Fq 'install --global @example/tool' "$nfx_log" ||
      fail "the full cadence ran something for a store-only updater ($nfx_local)"
    grep -Fq '  hold  packages.opencodex-fixture — npm updater ["tool","update"] is not declared identically' \
      "$nfx_root/full-out" || fail "a store-only updater was not reported as held ($nfx_local)"
    [ "$(jq -r '.["@example/tool"]' "$nfx_state")" = 1.0.0 ] ||
      fail "a held store-only updater still changed the package ($nfx_local)"
    grep -Fq 'install --global npm@12.1.0' "$nfx_log" ||
      fail "one held updater stopped the rest of the npm pass ($nfx_local)"
  done
  # A failed outdated query skips the npm globals but says so, once.
  nfx_reset_state
  NPM_STUB_OUTDATED_FAIL=1 nfx_run_full "$nfx_full_fold" "$nfx_full_defs" \
    "$nfx_root/local-declared.json"
  [ "$(grep -c 'npm outdated query failed; npm globals are skipped this pass' \
    "$nfx_root/full-out")" -eq 1 ] ||
    fail "a failed npm outdated query was not reported exactly once"
  ! grep -Fq 'install --global' "$nfx_log" ||
    fail "the full cadence installed an npm global after its outdated query failed"
  nfx_reset_state
  nfx_run_full "$nfx_full_fold" "$nfx_full_defs" "$nfx_root/local-declared.json"
  grep -Fq 'tool update node=' "$nfx_log" ||
    fail "the full cadence did not use the package's own updater"
  ! grep -Fq 'install --global @example/tool' "$nfx_log" ||
    fail "the full cadence reinstalled a package that declares its own updater"
  grep -Fq 'install --global npm@12.1.0' "$nfx_log" ||
    fail "the full cadence did not upgrade an outdated npm global to its exact candidate"
  ! grep -Fq 'install --global current-only' "$nfx_log" ||
    fail "the full cadence reinstalled an npm global that was already current"
  [ "$(jq -r '.npm + " " + .["@example/tool"]' "$nfx_state")" = '12.1.0 2.0.0' ] ||
    fail "the full cadence did not converge npm globals"
)

# --- sealed-plan lifecycle -----------------------------------------------------
nfx_reset_state
jq '.machines["test-host"].package_managers = ["homebrew","npm"] |
  .package_updaters = {"npm:@example/tool":["tool","update"],"npm:current-only":["tool","update"]}' \
  "$tmp/config.json" >"$tmp/npm-config.json"
chmod 600 "$tmp/npm-config.json"
nfx_cli() {
  env -u XDG_DATA_HOME PATH="$nfx_root/fnm-bin:$PATH" ROUNDHOUSE_CONFIG="$tmp/npm-config.json" FNM_DIR="$nfx_fnm" \
    NPM_STUB_STATE="$nfx_state" NPM_STUB_LATEST="$nfx_latest" NPM_STUB_LOG="$nfx_log" \
    NPM_STUB_IMPOSTOR="$nfx_root/impostor-ran" ROUNDHOUSE_TEST_NPM_FIXED_DIRS= \
    ROUNDHOUSE_TEST_FNM_FIXED_DIRS= "$cli" "$@"
}
# Config validation: npm is accepted everywhere; an updater must be argv.
for nfx_bad_config in \
  '.package_updaters = {"npm:@example/tool":"tool update"}' \
  '.package_updaters = {"npm:@example/tool":["tool; rm"]}' \
  '.package_updaters = {"homebrew:git":["git","update"]}' \
  '.machines["test-host"].package_managers = ["pip"]'; do
  jq "$nfx_bad_config" "$tmp/npm-config.json" >"$tmp/npm-bad-config.json"
  chmod 600 "$tmp/npm-bad-config.json"
  if ROUNDHOUSE_CONFIG="$tmp/npm-bad-config.json" "$cli" worker-config test-host updates \
    "$tmp/npm-bad-worker.json" >/dev/null 2>&1; then
    fail "configuration validation accepted: $nfx_bad_config"
  fi
done
nfx_cli worker-config test-host updates "$tmp/npm-worker-config.json"
[ "$(jq -c '.package_updaters["npm:@example/tool"]' "$tmp/npm-worker-config.json")" = '["tool","update"]' ] ||
  fail "the bounded worker configuration dropped the package updaters"

nfx_cli collect --target test-host --section host --section packages --output "$tmp/npm-snapshot.jsonl"
"$cli" validate "$tmp/npm-snapshot.jsonl"
[ "$(jq -r 'select(.kind == "package" and .id == "npm:npm") |
  [.data.installed_version,.data.candidate_version,.data.update_available,.data.node_version] | map(tostring) | join(" ")' \
  "$tmp/npm-snapshot.jsonl")" = '11.0.0 12.1.0 true v26.0.0' ] ||
  fail "the POSIX collector did not report an npm global with its candidate"
[ "$(jq -r 'select(.kind == "package" and .id == "npm:npm") | .data.prefix' "$tmp/npm-snapshot.jsonl")" = \
  "$nfx_prefix_physical" ] || fail "the npm record did not bind the global prefix"
[ "$(jq -c 'select(.kind == "package" and .id == "npm:@example/tool") | .data.updater' "$tmp/npm-snapshot.jsonl")" = \
  '["tool","update"]' ] || fail "a proven package updater was not reported"
[ "$(jq -r 'select(.kind == "package" and .id == "npm:current-only") |
  [.data.update_available,.data.updater,.data.updater_status] | map(tostring) | join(" ")' \
  "$tmp/npm-snapshot.jsonl")" = 'false null unproven' ] ||
  fail "an unproven updater or a current package was misreported"

nfx_draft() {
  jq -n --arg id "$1" --arg candidate "$2" --args \
    '{domain:"updates",target:"test-host",operations:[{type:"package-upgrade",kind:"package",
      id:$id,candidate_version:$candidate,argv:$ARGS.positional}]}' -- "${@:3}"
}
nfx_draft npm:npm 12.1.0 npm install --global npm@latest >"$tmp/npm-latest-draft.json"
if nfx_cli seal-plan "$tmp/npm-latest-draft.json" "$tmp/npm-snapshot.jsonl" \
  "$tmp/npm-latest-plan.json" >/dev/null 2>&1; then
  fail "an npm upgrade sealed without its exact candidate version"
fi
nfx_draft npm:npm 12.1.0 tool update >"$tmp/npm-unconfigured-updater-draft.json"
if nfx_cli seal-plan "$tmp/npm-unconfigured-updater-draft.json" "$tmp/npm-snapshot.jsonl" \
  "$tmp/npm-unconfigured-updater-plan.json" >/dev/null 2>&1; then
  fail "an npm upgrade sealed an updater the configuration does not declare"
fi
nfx_draft npm:npm 12.1.0 npm install --global npm@12.1.0 >"$tmp/npm-draft.json"
nfx_cli seal-plan "$tmp/npm-draft.json" "$tmp/npm-snapshot.jsonl" "$tmp/npm-plan.json"
nfx_plan_id=$(jq -r '.plan_id' "$tmp/npm-plan.json")
: >"$nfx_log"
if NPM_STUB_INSTALL_VERSION=12.0.0 nfx_cli apply-plan "$tmp/npm-plan.json" "$nfx_plan_id" \
  "$tmp/npm-wrong-apply.jsonl" >/dev/null 2>&1; then
  fail "an npm apply that missed the sealed candidate was reported complete"
fi
nfx_reset_state
nfx_cli apply-plan "$tmp/npm-plan.json" "$nfx_plan_id" "$tmp/npm-apply.jsonl"
[ "$(jq -r 'select(.kind == "package" and .id == "npm:npm") | .data.installed_version' "$tmp/npm-apply.jsonl")" = \
  12.1.0 ] || fail "the npm apply did not verify the upgraded version"
grep -Fq "install --global npm@12.1.0 node=$nfx_fnm/aliases/default/bin/node" "$nfx_log" ||
  fail "the sealed npm install did not run the exact argv under the durable node"

# The package's own updater: sealed only because the configuration declares
# it AND the collector proved it; run by absolute path; verified afterwards.
nfx_cli collect --target test-host --section host --section packages --output "$tmp/npm-snapshot-2.jsonl"
nfx_draft npm:@example/tool 2.0.0 tool update >"$tmp/npm-updater-draft.json"
nfx_cli seal-plan "$tmp/npm-updater-draft.json" "$tmp/npm-snapshot-2.jsonl" "$tmp/npm-updater-plan.json"
nfx_updater_plan_id=$(jq -r '.plan_id' "$tmp/npm-updater-plan.json")
jq -c 'if .kind == "package" and .id == "npm:@example/tool" then .data.updater = null else . end' \
  "$tmp/npm-snapshot-2.jsonl" >"$tmp/npm-unproven-snapshot.jsonl"
if nfx_cli seal-plan "$tmp/npm-updater-draft.json" "$tmp/npm-unproven-snapshot.jsonl" \
  "$tmp/npm-unproven-plan.json" >/dev/null 2>&1; then
  fail "an updater sealed without collect-time proof that it is the package's own bin"
fi
: >"$nfx_log"
# The updater takes no version, so the registry must still name the sealed
# candidate as latest right before it runs; otherwise nothing runs.
if NPM_STUB_VIEW_VERSION=2.1.0 nfx_cli apply-plan "$tmp/npm-updater-plan.json" \
  "$nfx_updater_plan_id" "$tmp/npm-updater-moved-apply.jsonl" >/dev/null 2>&1; then
  fail "a sealed updater ran after the registry latest moved past the candidate"
fi
! grep -Fq 'tool update' "$nfx_log" ||
  fail "the updater executed although the registry latest no longer matched the candidate"
[ "$(jq -r '.["@example/tool"]' "$nfx_state")" = 1.0.0 ] ||
  fail "a refused sealed updater changed the package"
: >"$nfx_log"
nfx_cli apply-plan "$tmp/npm-updater-plan.json" "$nfx_updater_plan_id" "$tmp/npm-updater-apply.jsonl"
grep -Fq "tool update node=$nfx_fnm/aliases/default/bin/node" "$nfx_log" ||
  fail "the sealed updater did not run under the durable node"
! grep -Fq 'install --global @example/tool' "$nfx_log" ||
  fail "the sealed updater plan ran npm install instead"
[ "$(jq -r 'select(.kind == "operation" and (.id | startswith("apply:"))) | .data.operation_status' \
  "$tmp/npm-updater-apply.jsonl")" = completed ] || fail "the sealed updater apply did not complete"

# The native Windows collector reports npm globals the same way.
if [ -n "$pwsh_command" ]; then
  nfx_reset_state
  jq '.machines["test-windows"].package_managers = ["winget","npm"] |
    .package_updaters = {"npm:@example/tool":["tool","update"]}' \
    "$tmp/config.json" >"$tmp/npm-windows-controller.json"
  chmod 600 "$tmp/npm-windows-controller.json"
  ROUNDHOUSE_CONFIG="$tmp/npm-windows-controller.json" \
    "$cli" worker-config test-windows inventory "$tmp/npm-windows-worker.json"
  env NPM_STUB_STATE="$nfx_state" NPM_STUB_LATEST="$nfx_latest" NPM_STUB_LOG="$nfx_log" \
    HOME="$tmp/home" PATH="$nfx_install_dir/bin:$PATH" "$pwsh_command" -NoLogo -NoProfile \
    -File "$script_dir/collect-windows.ps1" -ConfigPath "$tmp/npm-windows-worker.json" \
    -HostId test-windows \
    -ControllerConfigDigest "$(shasum -a 256 "$tmp/npm-windows-controller.json" | awk '{print $1}')" \
    -Sections packages >"$tmp/npm-windows.jsonl"
  "$cli" validate "$tmp/npm-windows.jsonl"
  [ "$(jq -r 'select(.kind == "package" and .id == "npm:npm") | [.data.installed_version,.data.candidate_version] | join(" ")' \
    "$tmp/npm-windows.jsonl")" = '11.0.0 12.1.0' ] ||
    fail "the Windows collector did not report an npm global with its candidate"
  [ "$(jq -c 'select(.kind == "package" and .id == "npm:@example/tool") | .data.updater' "$tmp/npm-windows.jsonl")" = \
    '["tool","update"]' ] || fail "the Windows collector did not prove the package updater"
fi
