# roundhouse — the npm global-package manager: one durable npm per host.
#
# Sourced by scripts/roundhouse and scripts/collect-posix; carries definitions
# only.
#
# npm is a manager with a moving floor. Its global packages live under the
# prefix of the Node that runs it, so "which npm" and "which node" are one
# question and must get one answer:
#
#   * fnm keeps a prefix PER NODE VERSION
#     (`$FNM_DIR/node-versions/vX/installation`), and its per-shell
#     `fnm_multishells/<pid>/bin` links are deleted when that shell's session
#     ends. A scheduler or SSH worker that finds npm through such a link either
#     fails later or acts on a Node nobody selected. The durable answer is
#     fnm's `default` alias, which is what every new login shell gets.
#   * npm is a `#!/usr/bin/env node` script, so running a durable npm under
#     whatever `node` the scheduler PATH happens to offer (Homebrew's, say)
#     installs the package into THAT node's prefix. Every invocation below
#     therefore puts npm's own directory first on PATH, and a candidate
#     directory counts only when it carries both `npm` and `node`.
#
# A login shell (`$SHELL -lc npm ...`) would also find npm, but under fnm it
# does so by minting a fresh multishell directory per call; the alias path is
# the same Node without the churn.
#
# Every helper is a subshell function: the collector, the sealed executor and
# the desired-state run all source this unit next to their own npm_* state,
# and none of it may be clobbered by a lookup.
# shellcheck shell=bash

npm_package_name_valid() (
  # npm's registry grammar, optionally scoped. Bash's own regex, never grep:
  # a name must be one line, and grep matches any line of a multi-line value.
  [ "${#1}" -le 214 ] &&
    [[ $1 =~ ^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*$ ]]
)

npm_version_valid() (
  [ "${#1}" -le 128 ] && [[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]
)

npm_updater_argv_valid() (
  # A declared updater is exact argv, never a shell string: a bin the package
  # itself installs, then at most seven literal arguments.
  [ $# -ge 1 ] && [ $# -le 8 ] || return 1
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 1
  shift
  for npm_updater_argument in "$@"; do
    [ "${#npm_updater_argument}" -le 128 ] &&
      [[ $npm_updater_argument =~ ^[A-Za-z0-9@=:,._/+-]+$ ]] || return 1
  done
)

npm_durable_bin_dir() (
  # Durable means: not per-shell state, and npm travels with its own node.
  case $1 in *fnm_multishells*) return 1 ;; esac
  [ -x "$1/npm" ] && [ ! -d "$1/npm" ] && [ -x "$1/node" ] && [ ! -d "$1/node" ] ||
    return 1
  printf '%s\n' "$1"
)

npm_global_bin_dir() (
  # The directory holding the durable npm (and the node it must run under).
  # Order: fnm's `default` alias, then PATH, then the fixed Homebrew, Linuxbrew
  # and system prefixes a minimal scheduler PATH omits. Exit 69 when none.
  for npm_fnm_root in ${FNM_DIR:+"$FNM_DIR"} \
    "${XDG_DATA_HOME:-$HOME/.local/share}/fnm" \
    "$HOME/Library/Application Support/fnm" "$HOME/.fnm"; do
    npm_durable_bin_dir "$npm_fnm_root/aliases/default/bin" && return 0
  done
  npm_path_candidate=$(command -v npm 2>/dev/null || true)
  case $npm_path_candidate in
    /*) npm_durable_bin_dir "${npm_path_candidate%/*}" && return 0 ;;
  esac
  npm_fixed_dirs='/opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin /usr/bin'
  # Test-only, and inert unless the self-check turned it on: a developer
  # machine running the suite must not fall through to its real Node.
  if [ "${ROUNDHOUSE_SELFTEST:-0}" = 1 ] && [ -n "${ROUNDHOUSE_TEST_NPM_FIXED_DIRS+x}" ]; then
    npm_fixed_dirs=$ROUNDHOUSE_TEST_NPM_FIXED_DIRS
  fi
  for npm_fixed_dir in $npm_fixed_dirs; do
    npm_durable_bin_dir "$npm_fixed_dir" && return 0
  done
  return 69
)

npm_global_run() (
  # npm with its own node first on PATH, no stdin (these run inside `while
  # read` loops), and none of npm's interactive or advisory chatter.
  npm_bin=$(npm_global_bin_dir) || exit 69
  PATH="$npm_bin:$PATH" NO_UPDATE_NOTIFIER=1 npm_config_update_notifier=false \
    npm_config_fund=false npm_config_audit=false \
    exec "$npm_bin/npm" "$@" </dev/null
)

npm_global_list() (
  # `{name: installed_version}` for every top-level global package. `npm ls`
  # exits non-zero for extraneous or invalid trees while still printing the
  # tree, so the JSON shape, not the status, is what is trusted. A fatal error
  # prints an object with only `error`; that is a failed query, never an empty
  # tree.
  npm_list_json=$(npm_global_run ls --global --json --depth=0 2>/dev/null) || :
  printf '%s\n' "$npm_list_json" | jq -ce '
    if type == "object" and (has("error") | not) and
      ((.dependencies // {}) | type == "object") then
      (.dependencies // {}) | with_entries(
        select(.value | type == "object" and (.version | type == "string")) |
        .value = .value.version)
    else error("invalid npm ls output") end' 2>/dev/null
)

npm_global_outdated() (
  # `{name: latest}` for every global package with a newer registry release.
  # `npm outdated` exits 1 exactly when it has something to report, so again
  # only the shape decides; an `error` object is a failed query, not "current".
  # npm prints `{}` itself when nothing is outdated, so EMPTY output is a
  # failed query too: reading it as "all current" would mask the failure.
  npm_outdated_json=$(npm_global_run outdated --global --json 2>/dev/null) || :
  [ -n "$npm_outdated_json" ] || return 1
  printf '%s\n' "$npm_outdated_json" | jq -ce '
    if type == "object" and (has("error") | not) then
      with_entries(select(.value | type == "object" and
        (.latest | type == "string") and (.current | type == "string")) |
        .value = .value.latest)
    else error("invalid npm outdated output") end' 2>/dev/null
)

npm_registry_latest() (
  # The registry's current `latest` for one package, through the durable npm.
  # Exactly one valid version line, or failure.
  npm_package_name_valid "$1" || return 64
  npm_latest_version=$(npm_global_run view "$1" version 2>/dev/null) || return 69
  npm_version_valid "$npm_latest_version" || return 69
  printf '%s\n' "$npm_latest_version"
)

npm_global_prefix() (
  npm_global_run prefix --global 2>/dev/null | head -1
)

npm_resolve_link() (
  # Follow symlinks to a physical path without GNU readlink -f.
  npm_link=$1
  npm_hops=0
  while [ -L "$npm_link" ]; do
    npm_hops=$((npm_hops + 1))
    [ "$npm_hops" -le 16 ] || return 1
    npm_target=$(readlink -- "$npm_link") || return 1
    case $npm_target in
      /*) npm_link=$npm_target ;;
      *) npm_link=$(dirname -- "$npm_link")/$npm_target ;;
    esac
  done
  npm_parent=$(CDPATH='' cd -P -- "$(dirname -- "$npm_link")" 2>/dev/null && pwd -P) ||
    return 1
  printf '%s/%s\n' "$npm_parent" "$(basename -- "$npm_link")"
)

npm_package_bins() (
  # The bin names a globally installed package declares, one per line. A
  # string `bin` is named after the unscoped package; `directories.bin` is not
  # read, so such a package simply declares no updater-eligible bin.
  npm_package_name_valid "$1" || return 64
  npm_root=$(npm_global_run root --global 2>/dev/null | head -1) || return 69
  case $npm_root in /*) ;; *) return 69 ;; esac
  [ -f "$npm_root/$1/package.json" ] || return 66
  jq -r --arg name "$1" '
    if (.bin | type) == "string" then ($name | split("/") | last)
    elif (.bin | type) == "object" then (.bin | keys[])
    else empty end' "$npm_root/$1/package.json" 2>/dev/null
)

npm_updater_path() (
  # `npm_updater_path NAME BIN` — the absolute path of BIN only when the
  # package NAME declares it AND the global bin link resolves inside that
  # package's own directory. A bin by the same name from another package, or a
  # hand-placed file, is not this package's updater.
  npm_package_bins "$1" | grep -Fqx -- "$2" || return 65
  npm_prefix=$(npm_global_prefix) || return 69
  case $npm_prefix in /*) ;; *) return 69 ;; esac
  npm_root=$(npm_global_run root --global 2>/dev/null | head -1) || return 69
  npm_package_dir=$(CDPATH='' cd -P -- "$npm_root/$1" 2>/dev/null && pwd -P) || return 66
  npm_bin_target=$(npm_resolve_link "$npm_prefix/bin/$2") || return 66
  case $npm_bin_target in
    "$npm_package_dir"/*) ;;
    *) return 65 ;;
  esac
  [ -x "$npm_prefix/bin/$2" ] || return 66
  printf '%s\n' "$npm_prefix/bin/$2"
)

npm_global_install() (
  # `npm_global_install NAME VERSION` — exact when VERSION is given, `latest`
  # otherwise. Silent; the caller verifies the resulting state.
  npm_package_name_valid "$1" || return 64
  if [ -n "${2:-}" ]; then
    npm_version_valid "$2" || return 64
    npm_global_run install --global "$1@$2" >/dev/null 2>&1
  else
    npm_global_run install --global "$1@latest" >/dev/null 2>&1
  fi
)

npm_global_run_updater() (
  # `npm_global_run_updater NAME BIN [ARG...]` — the package's own updater,
  # by absolute path, under the same node as npm. Exact argv, no shell.
  npm_name=$1
  shift
  npm_package_name_valid "$npm_name" || exit 64
  npm_updater_argv_valid "$@" || exit 64
  npm_bin=$(npm_global_bin_dir) || exit 69
  npm_updater=$(npm_updater_path "$npm_name" "$1") || exit 65
  shift
  PATH="$npm_bin:$PATH" NO_UPDATE_NOTIFIER=1 exec "$npm_updater" "$@" </dev/null
)

npm_global_installed_version() (
  npm_global_list | jq -r --arg name "$1" '.[$name] // empty'
)

npm_global_list_detail() (
  # `{name: {version, pinnable}}` for every top-level global, including the
  # ones npm_global_list drops: a global without a version, or one sourced
  # from `file:`, `link:` or git (an `npm link`, a local tarball), cannot be
  # reinstalled by exact registry version and is reported unpinnable, never
  # silently left out. Same failure rules as npm_global_list.
  npm_detail_json=$(npm_global_run ls --global --json --depth=0 2>/dev/null) || :
  printf '%s\n' "$npm_detail_json" | jq -ce '
    if type == "object" and (has("error") | not) and
      ((.dependencies // {}) | type == "object") then
      (.dependencies // {}) | with_entries(
        select(.value | type == "object") |
        .value = {
          version: (if (.value.version | type) == "string" then .value.version else null end),
          pinnable: ((.value.version | type) == "string" and
            (.value.version | test("^[0-9A-Za-z][0-9A-Za-z.+-]*$")) and
            (.key | test("^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*$")) and
            ((.value.resolved // "") | test("^(file:|link:|git[+:]|github:|gitlab:|bitbucket:)") | not) and
            (.value.link // false) != true)
        })
    else error("invalid npm ls output") end' 2>/dev/null
)
