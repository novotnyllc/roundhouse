# roundhouse — the Node runtime under the managed npm globals: fnm on POSIX.
#
# Sourced by scripts/roundhouse and scripts/collect-posix after lib/npm.sh;
# carries definitions only.
#
# This is a narrow exception to the storage design's "no language version
# managers" rule (§5.1.2 amendment): Roundhouse owns exactly ONE runtime, the
# host-default Node that runs the managed npm globals, and only through fnm's
# `default` alias. Per-project and per-shell selection stay out of scope.
#
# The facts the code rests on:
#
#   * fnm keeps one prefix per Node version
#     (`$FNM_DIR/node-versions/vX/installation`). A switch therefore starts
#     with an EMPTY global set, and the managed globals have to be carried to
#     the new prefix explicitly.
#   * fnm never upgrades within a major on its own. Something has to move the
#     default, or it stays wherever it was installed.
#   * a service a global package installed (opencodex's, for one) may embed
#     the absolute path of the OLD prefix, so the old version is never removed
#     here: it is reported, and removal stays a separate decision. A package
#     can declare a post-switch hook (one of its own bins) to move such a
#     service; the hook runs only when this host's config.json declares it.
#
# Every helper is a subshell function, for the same reason as lib/npm.sh.
# shellcheck shell=bash

node_version_valid() (
  # fnm's own spelling, `v` included: `v26.7.0`.
  [[ $1 =~ ^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}$ ]]
)

node_version_normalize() (
  # `26.7.0` or `v26.7.0` -> `v26.7.0`; anything else fails.
  case $1 in
    v*) node_normalized=$1 ;;
    *) node_normalized=v$1 ;;
  esac
  node_version_valid "$node_normalized" || return 1
  printf '%s\n' "$node_normalized"
)

node_version_major() (
  node_major=${1#v}
  printf '%s\n' "${node_major%%.*}"
)

node_version_newer() (
  # `node_version_newer A B` — A is strictly newer than B, numerically.
  node_version_valid "$1" && node_version_valid "$2" || return 2
  IFS=. read -r node_a1 node_a2 node_a3 <<EOF
${1#v}
EOF
  IFS=. read -r node_b1 node_b2 node_b3 <<EOF
${2#v}
EOF
  [ $((10#$node_a1)) -ne $((10#$node_b1)) ] && { [ $((10#$node_a1)) -gt $((10#$node_b1)) ]; return; }
  [ $((10#$node_a2)) -ne $((10#$node_b2)) ] && { [ $((10#$node_a2)) -gt $((10#$node_b2)) ]; return; }
  [ $((10#$node_a3)) -gt $((10#$node_b3)) ]
)

node_fnm_root() (
  # The fnm directory whose `default` alias is the durable npm lib/npm.sh
  # resolves: the same roots in the same order, under the same predicate, so
  # the runtime being switched is always the one that owns the globals.
  for node_root in ${FNM_DIR:+"$FNM_DIR"} \
    "${XDG_DATA_HOME:-$HOME/.local/share}/fnm" \
    "$HOME/Library/Application Support/fnm" "$HOME/.fnm"; do
    npm_durable_bin_dir "$node_root/aliases/default/bin" >/dev/null || continue
    printf '%s\n' "$node_root"
    return 0
  done
  return 69
)

node_fnm_bin() (
  # fnm itself: PATH outside fnm_multishells, then the fixed Homebrew and
  # Linuxbrew prefixes a minimal scheduler PATH omits (fnm is a formula there).
  node_fnm_candidate=$(command -v fnm 2>/dev/null || true)
  case $node_fnm_candidate in
    *fnm_multishells*) ;;
    /*)
      if [ -x "$node_fnm_candidate" ] && [ ! -d "$node_fnm_candidate" ]; then
        printf '%s\n' "$node_fnm_candidate"
        return 0
      fi
      ;;
  esac
  node_fnm_dirs='/opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin'
  # Test-only, inert outside the self-check (the lib/npm.sh precedent): a
  # developer machine running the suite must not reach its real fnm.
  if [ "${ROUNDHOUSE_SELFTEST:-0}" = 1 ] && [ -n "${ROUNDHOUSE_TEST_FNM_FIXED_DIRS+x}" ]; then
    node_fnm_dirs=$ROUNDHOUSE_TEST_FNM_FIXED_DIRS
  fi
  for node_fnm_dir in $node_fnm_dirs; do
    if [ -x "$node_fnm_dir/fnm" ] && [ ! -d "$node_fnm_dir/fnm" ]; then
      printf '%s\n' "$node_fnm_dir/fnm"
      return 0
    fi
  done
  return 69
)

node_fnm_run() (
  # `node_fnm_run ROOT ARG...` — fnm pinned to the root the globals live in,
  # stdin closed (these run inside `while read` loops).
  node_fnm=$(node_fnm_bin) || exit 69
  node_run_root=$1
  shift
  FNM_DIR=$node_run_root exec "$node_fnm" "$@" </dev/null
)

node_fnm_default() (
  # The version fnm's `default` alias points at, read from the link itself:
  # `aliases/default -> …/node-versions/vX.Y.Z/installation`.
  node_default_dir=$(CDPATH='' cd -P -- "$1/aliases/default" 2>/dev/null && pwd -P) || return 69
  case $node_default_dir in
    */node-versions/v*/installation) ;;
    *) return 69 ;;
  esac
  node_default_version=${node_default_dir%/installation}
  node_default_version=${node_default_version##*/}
  node_version_valid "$node_default_version" || return 69
  printf '%s\n' "$node_default_version"
)

node_fnm_prefix() (
  # The physical installation directory of one installed version.
  CDPATH='' cd -P -- "$1/node-versions/$2/installation" 2>/dev/null && pwd -P
)

node_fnm_installed() (
  # Every installed version that carries a node binary, oldest first.
  for node_installed_dir in "$1"/node-versions/v*/installation; do
    [ -x "$node_installed_dir/bin/node" ] || continue
    node_installed_version=${node_installed_dir%/installation}
    node_installed_version=${node_installed_version##*/}
    node_version_valid "$node_installed_version" || continue
    printf '%s\n' "$node_installed_version"
  done | LC_ALL=C sort -t. -k1.2,1n -k2,2n -k3,3n
)

node_fnm_remote_latest() (
  # `node_fnm_remote_latest ROOT MAJOR` — the newest published release in one
  # major line. fnm's `list-remote` prints one version per line (LTS lines
  # carry a codename after it); only the first token is read, and any line
  # that is not exactly a version is ignored. No reliance on `--filter` or
  # `--sort`, which older fnm releases lack.
  [[ $2 =~ ^[1-9][0-9]{0,2}$ ]] || return 64
  node_remote=$(node_fnm_run "$1" list-remote 2>/dev/null) || return 69
  node_remote_latest=$(printf '%s\n' "$node_remote" | awk -v major="$2" '
    $1 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
      split(substr($1, 2), p, ".")
      if (p[1] + 0 != major + 0) next
      if (!found || p[1] + 0 > b1 || (p[1] + 0 == b1 && (p[2] + 0 > b2 ||
          (p[2] + 0 == b2 && p[3] + 0 > b3)))) {
        found = 1; b1 = p[1] + 0; b2 = p[2] + 0; b3 = p[3] + 0; best = $1
      }
    }
    END { if (found) print best }')
  node_version_valid "$node_remote_latest" || return 69
  printf '%s\n' "$node_remote_latest"
)

node_switch_hook_valid() (
  # A post-switch hook is exactly the grammar of a package updater: a bin the
  # package itself installs, then literal arguments. Never a shell string.
  npm_updater_argv_valid "$@"
)

node_runtime_spec() (
  # `node_runtime_spec VALUE` — the folded `runtimes.node` value, as JSON, to
  # `{"major":N,"version":"vX.Y.Z"|null}`. `major:` is the normal form: the
  # newest release in that line. `version:` is the exact pin, the same opt-out
  # `version:` is for a package. Both at once must agree. A value with neither
  # is not a runtime anybody asked for, and is refused.
  printf '%s\n' "$1" | jq -ce '
    def major_of: ltrimstr("v") | split(".")[0] | tonumber;
    if type != "object" then error("runtime needs major or version") else . end |
    (.major // null) as $m | (.version // null) as $v |
    ($m | if . == null then null
      elif type == "number" and . == floor and . >= 1 and . <= 999 then .
      elif type == "string" and test("^[1-9][0-9]{0,2}$") then tonumber
      else error("invalid major") end) as $major |
    ($v | if . == null then null
      elif type == "string" and test("^v?[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,6}$") then
        (if startswith("v") then . else "v" + . end)
      else error("invalid version") end) as $version |
    if $major == null and $version == null then error("runtime needs major or version")
    elif $major != null and $version != null and ($version | major_of) != $major then
      error("version is outside the declared major")
    else {major: ($major // ($version | major_of)), version: $version} end' 2>/dev/null
)

node_runtime_switch() (
  # `node_runtime_switch TARGET CARRY HOOKS` — make TARGET the fnm default and
  # carry the managed globals to it. Shared by the sealed executor and the
  # desired-state run, so both lanes switch the same way.
  #
  #   CARRY  JSON array of {name, version}: globals installed under the
  #          CURRENT default that must exist, at exactly those versions,
  #          under TARGET afterwards
  #   HOOKS  JSON array of {package: "npm:<name>", argv}: post-switch hooks,
  #          each a bin of a carried package, already trust-checked by the
  #          caller against this host's config.json
  #
  # Order: validate everything and prove every hook bin under the CURRENT
  # prefix (nothing mutated yet, exit 65 on refusal); `fnm install`;
  # `fnm default`; one exact `npm install --global a@x b@y …` through the
  # durable npm, which now resolves to the new prefix; verify every carried
  # version; run each hook by absolute path under the new node. Any failure
  # after the default moved points it back at the old version (never
  # uninstalled here) and exits 1. Exit 70 only when even that restore failed.
  node_target=$1
  node_carry=$2
  node_hooks=$3
  node_version_valid "$node_target" || {
    printf 'roundhouse: invalid Node target version %s\n' "$node_target" >&2
    exit 64
  }
  printf '%s\n' "$node_carry" | jq -e '
    type == "array" and length <= 256 and
    all(.[]; type == "object" and (.name | type == "string") and (.version | type == "string")) and
    ((map(.name) | unique | length) == length)' >/dev/null 2>&1 || {
    printf 'roundhouse: invalid Node switch carry list\n' >&2
    exit 64
  }
  printf '%s\n' "$node_hooks" | jq -e '
    type == "array" and length <= 64 and
    all(.[]; type == "object" and (.package | type == "string" and startswith("npm:")) and
      (.argv | type == "array" and all(.[]; type == "string")))' >/dev/null 2>&1 || {
    printf 'roundhouse: invalid Node switch hook list\n' >&2
    exit 64
  }
  node_root=$(node_fnm_root) || {
    printf 'roundhouse: no fnm default Node on this host\n' >&2
    exit 69
  }
  node_fnm_bin >/dev/null || {
    printf 'roundhouse: fnm is not installed\n' >&2
    exit 69
  }
  node_old=$(node_fnm_default "$node_root") || {
    printf 'roundhouse: the fnm default alias does not name an installed version\n' >&2
    exit 69
  }
  node_before=$(npm_global_list) || {
    printf 'roundhouse: npm global inventory under %s failed\n' "$node_old" >&2
    exit 69
  }
  # Every carried package must be installed NOW, at the stated version: the
  # carry reproduces what exists, it never introduces a package.
  node_specs=()
  while IFS= read -r node_entry; do
    [ -n "$node_entry" ] || continue
    node_name=$(printf '%s\n' "$node_entry" | jq -r '.name')
    node_version=$(printf '%s\n' "$node_entry" | jq -r '.version')
    { npm_package_name_valid "$node_name" && npm_version_valid "$node_version"; } || {
      printf 'roundhouse: invalid carried npm global %s@%s\n' "$node_name" "$node_version" >&2
      exit 64
    }
    [ "$(printf '%s\n' "$node_before" | jq -r --arg n "$node_name" '.[$n] // empty')" = "$node_version" ] || {
      printf 'roundhouse: %s@%s is not installed under %s; refusing the switch\n' \
        "$node_name" "$node_version" "$node_old" >&2
      exit 65
    }
    node_specs+=("$node_name@$node_version")
  done <<EOF
$(printf '%s\n' "$node_carry" | jq -c '.[]')
EOF
  # Every hook must be a bin of a carried package, provable under the current
  # prefix before anything moves. The same proof runs again under the new
  # prefix right before the hook executes.
  while IFS= read -r node_hook; do
    [ -n "$node_hook" ] || continue
    node_hook_name=$(printf '%s\n' "$node_hook" | jq -r '.package | ltrimstr("npm:")')
    printf '%s\n' "$node_carry" | jq -e --arg n "$node_hook_name" 'any(.[]; .name == $n)' \
      >/dev/null || {
      printf 'roundhouse: a post-switch hook names %s, which is not carried\n' "$node_hook_name" >&2
      exit 65
    }
    node_hook_argv=()
    while IFS= read -r node_hook_arg; do
      node_hook_argv+=("$node_hook_arg")
    done < <(printf '%s\n' "$node_hook" | jq -r '.argv[]')
    [ "$(printf '%s\n' "$node_hook" | jq '.argv | length')" -eq "${#node_hook_argv[@]}" ] &&
      node_switch_hook_valid "${node_hook_argv[@]}" || {
      printf 'roundhouse: a post-switch hook for %s is not argv\n' "$node_hook_name" >&2
      exit 64
    }
    npm_updater_path "$node_hook_name" "${node_hook_argv[0]}" >/dev/null 2>&1 || {
      printf 'roundhouse: post-switch hook %s is not a bin of the installed %s; refusing the switch\n' \
        "${node_hook_argv[0]}" "$node_hook_name" >&2
      exit 65
    }
  done <<EOF
$(printf '%s\n' "$node_hooks" | jq -c '.[]')
EOF

  node_restore() {
    [ "$node_old" != "$node_target" ] || return 0
    if node_fnm_run "$node_root" default "$node_old" >/dev/null 2>&1 &&
      [ "$(node_fnm_default "$node_root" 2>/dev/null)" = "$node_old" ]; then
      printf 'roundhouse: fnm default restored to %s (%s stays installed)\n' \
        "$node_old" "$node_target" >&2
      return 0
    fi
    printf 'roundhouse: could not restore the fnm default to %s; the host is on %s without its carried globals\n' \
      "$node_old" "$node_target" >&2
    return 70
  }

  node_fnm_run "$node_root" install "$node_target" >/dev/null 2>&1 &&
    [ -x "$node_root/node-versions/$node_target/installation/bin/node" ] || {
    printf 'roundhouse: fnm install %s failed; nothing switched\n' "$node_target" >&2
    exit 1
  }
  if [ "$node_old" != "$node_target" ]; then
    node_fnm_run "$node_root" default "$node_target" >/dev/null 2>&1 || {
      printf 'roundhouse: fnm default %s failed\n' "$node_target" >&2
      node_restore || exit 70
      exit 1
    }
  fi
  # The durable npm must now be the new default's own npm, running under the
  # new node; otherwise the carry would land in some other prefix.
  node_new_bin=$(npm_global_bin_dir 2>/dev/null) || node_new_bin=
  node_new_node=
  [ -z "$node_new_bin" ] ||
    node_new_node=$(PATH="$node_new_bin:$PATH" "$node_new_bin/node" --version 2>/dev/null </dev/null | head -1)
  [ "$(node_fnm_default "$node_root" 2>/dev/null)" = "$node_target" ] &&
    [ "$node_new_bin" = "$node_root/aliases/default/bin" ] &&
    [ "$node_new_node" = "$node_target" ] || {
    printf 'roundhouse: the durable npm does not run under %s after the switch\n' "$node_target" >&2
    node_restore || exit 70
    exit 1
  }
  if [ "${#node_specs[@]}" -gt 0 ]; then
    npm_global_run install --global "${node_specs[@]}" >/dev/null 2>&1 || {
      printf 'roundhouse: carrying the npm globals to %s failed\n' "$node_target" >&2
      node_restore || exit 70
      exit 1
    }
  fi
  node_after=$(npm_global_list) || node_after='{}'
  printf '%s\n' "$node_after" | jq -e --argjson carry "$node_carry" '
    . as $after | all($carry[]; $after[.name] == .version)' >/dev/null || {
    printf 'roundhouse: carried npm globals are not all present under %s at their versions\n' \
      "$node_target" >&2
    node_restore || exit 70
    exit 1
  }
  while IFS= read -r node_hook; do
    [ -n "$node_hook" ] || continue
    node_hook_name=$(printf '%s\n' "$node_hook" | jq -r '.package | ltrimstr("npm:")')
    node_hook_argv=()
    while IFS= read -r node_hook_arg; do
      node_hook_argv+=("$node_hook_arg")
    done < <(printf '%s\n' "$node_hook" | jq -r '.argv[]')
    # npm_global_run_updater re-proves the bin under the NEW prefix and runs
    # it by absolute path with the new node first on PATH.
    npm_global_run_updater "$node_hook_name" "${node_hook_argv[@]}" >&2 || {
      printf 'roundhouse: post-switch hook %s for %s failed\n' \
        "$(printf '%s\n' "$node_hook" | jq -c '.argv')" "$node_hook_name" >&2
      node_restore || exit 70
      exit 1
    }
  done <<EOF
$(printf '%s\n' "$node_hooks" | jq -c '.[]')
EOF
  exit 0
)

node_globals_split() (
  # `node_globals_split DETAIL` — npm_global_list_detail's answer as the two
  # facts a switch plan reads: `globals` ({name: version} for every global
  # with a version, as npm_global_list reports them) and `unpinnable` (the
  # names that cannot be reinstalled by exact registry version).
  printf '%s\n' "$1" | jq -ce '
    {globals: (with_entries(select(.value.version | type == "string") | .value = .value.version)),
     unpinnable: ([to_entries[] | select(.value.pinnable != true) | .key] | sort)}' 2>/dev/null
)

node_switch_plan() (
  # `node_switch_plan GLOBALS UNPINNABLE TARGET DEFS HOOKS` — THE carry rule, one
  # pure function every lane asks (the scheduled cadences, seal-plan, and the
  # executor's verify-preconditions):
  #
  #   The carry is every global installed under the current default, at its
  #   exact installed version. Nothing is added, and nothing installed is
  #   left behind.
  #
  # It depends on nothing but what is installed: not desired state, not
  # definitions, not holds. (An earlier rule derived the carry from desired
  # state, and every refinement found another way to strand a package that
  # was held, renamed or disabled-but-held.) Two things are not carried:
  #
  #   excluded    what the TARGET Node provides itself: `npm` (every release
  #               bundles it), and `corepack` only when TARGET bundles it
  #               (Node 24 and older). Moving off a bundling release carries
  #               the installed corepack from the registry at its version:
  #               the target would not provide one, and dropping it would
  #               remove corepack and its shims.
  #   unpinnable  a global that cannot be reinstalled by exact registry
  #               version (`file:`, `link:`, git, no version). The switch
  #               HOLDS naming it rather than strand it.
  #
  # Hooks keep their trust model. `required` is every `node_switch` hook a
  # definition (DEFS) requires for a CARRIED package; `hooks` is what this
  # host's config.json (HOOKS, `node_switch_hooks`) declares for the carried
  # packages, in carry order, and is what runs. A required hook that is not
  # declared, or a malformed `node_switch` on a carried package, holds.
  #
  # UNPINNABLE that is not a list (null: the detail query failed) is unknown,
  # and unknown holds: carrying a linked global by version would fetch a
  # same-named registry package instead of the linked copy.
  jq -cn --argjson globals "$1" --argjson unpinnable "$2" --arg target "$3" \
    --argjson defs "$4" --argjson local "$5" '
    ($unpinnable | type == "array") as $detail_known |
    (if $detail_known then $unpinnable else [] end) as $unpinnable |
    def argv_ok: type == "array" and length >= 1 and length <= 8 and
      all(.[]; type == "string") and
      (.[0] | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
      all(.[1:][]; length <= 128 and test("^[A-Za-z0-9@=:,._/+-]+$"));
    ((($target | ltrimstr("v") | split(".")[0] | tonumber?) // 0) as $major |
      ["npm"] + (if $major < 25 then ["corepack"] else [] end)) as $provided |
    def provided($n): any($provided[]; . == $n);
    ([$globals | keys[]] + $unpinnable | unique) as $installed |
    [$globals | to_entries[] | .key as $n |
      select((provided($n) | not) and (any($unpinnable[]; . == $n) | not)) |
      {name: $n, version: .value}] | sort_by(.name) | . as $carry |
    [$carry[].name] as $carried |
    [($defs.packages // {}) | to_entries[] | .key as $logical | .value |
      select(type == "object") | .npm as $npm |
      (if ($npm | type) == "string" and $npm != "unavailable" then $npm
       elif ($npm | type) == "object" then ($npm.name // $logical) else null end) as $name |
      select($name != null and any($carried[]; . == $name)) |
      {logical: $logical, name: $name,
       hooks: (if ($npm | type) == "object" then ($npm.node_switch // null) else null end)} |
      select(.hooks != null)] as $wants |
    [$wants[] | select((.hooks | type == "array" and length >= 1 and length <= 4 and
      all(.[]; argv_ok)) | not)] as $malformed |
    [$carried[] | . as $n | $wants[] | select(.name == $n) |
      select(.hooks | type == "array" and all(.[]; argv_ok)) |
      .hooks[] | {package: ("npm:" + $n), argv: .}] as $required |
    [$carried[] | . as $n | ($local["npm:" + $n] // [])[] |
      {package: ("npm:" + $n), argv: .}] as $hooks |
    {
      carry: $carry,
      excluded: [$installed[] | select(provided(.))],
      unpinnable: [$unpinnable[] | select(provided(.) | not)] | unique,
      required: $required,
      hooks: $hooks,
      held: (first(
        (if $detail_known then empty else
          "which npm globals cannot be reinstalled by exact registry version is unknown (the global inventory detail is unavailable); a switch could carry a linked global as a registry package" end),
        ([$unpinnable[] | select(provided(.) | not)] | unique |
          select(length > 0) |
          "npm globals \(join(" ")) cannot be reinstalled by exact registry version (file:, link:, git or no version); a switch would strand them: reinstall them from the registry or remove them"),
        ($malformed[] |
          "definitions.packages.\(.logical) declares a malformed node_switch for the carried npm global \(.name)"),
        ($required[] | . as $r | select(any($hooks[]; . == $r) | not) |
          "\($r.package) requires node_switch hook \($r.argv | tojson) that this host'"'"'s config.json node_switch_hooks does not declare")
      ) // null)
    }'
)
