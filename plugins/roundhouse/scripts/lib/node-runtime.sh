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
#     with an EMPTY global set, and every installed global has to be carried
#     to the new prefix explicitly.
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
  # Bounded like every manager call (lib/timeout.sh, where loaded): `install`
  # downloads a runtime and gets the install ceiling, the rest the listing one.
  node_run_root=$1
  shift
  FNM_DIR=$node_run_root
  export FNM_DIR
  command -v run_bounded >/dev/null 2>&1 || exec "$node_fnm" "$@" </dev/null
  case ${1:-} in
    install) node_run_kind=install ;;
    *) node_run_kind=list ;;
  esac
  run_bounded "$(run_bounded_seconds "$node_run_kind")" "$node_fnm" "$@" </dev/null
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

node_runtime_spec() (
  # `node_runtime_spec VALUE` — the folded `runtimes.node` value, as JSON, to
  # `{"major":N,"version":"vX.Y.Z"|null}`. `major:` is the normal form: the
  # newest release in that line. `version:` is the exact pin, the same opt-out
  # `version:` is for a package. Both at once must agree. A value with neither
  # is not a runtime anybody asked for, and is refused.
  printf '%s\n' "$1" | jq -ce "$npm_jq_grammar"'
    def major_of: ltrimstr("v") | split(".")[0] | tonumber;
    if type != "object" then error("runtime needs major or version") else . end |
    (.major // null) as $m | (.version // null) as $v |
    ($m | if . == null then null
      elif type == "number" and . == floor and . >= 1 and . <= 999 then .
      elif type == "string" and test("^[1-9][0-9]{0,2}$") then tonumber
      else error("invalid major") end) as $major |
    ($v | if . == null then null
      elif type == "string" and (if startswith("v") then . else "v" + . end | node_version_ok) then
        (if startswith("v") then . else "v" + . end)
      else error("invalid version") end) as $version |
    if $major == null and $version == null then error("runtime needs major or version")
    elif $major != null and $version != null and ($version | major_of) != $major then
      error("version is outside the declared major")
    else {major: ($major // ($version | major_of)), version: $version} end' 2>/dev/null
)

node_target_bundled() (
  # `node_target_bundled VERSION` — the globals that Node release ships itself,
  # as a JSON array: npm always, corepack on Node 24 and older. The single
  # source for what a switch leaves to the target instead of carrying.
  printf '%s\n' "$1" | jq -Rc '(ltrimstr("v") | split(".")[0] | tonumber? // 0) as $major |
    ["npm"] + (if $major < 25 then ["corepack"] else [] end)'
)

node_globals_split() (
  # `node_globals_split DETAIL` — npm_*_list_detail's answer in the shape of
  # the `fnm:node` inventory record, which is the shape node_switch_plan
  # reads: `globals` ({name: version} for every global with a version) and
  # `globals_unpinnable` (the names that cannot be reinstalled by exact
  # registry version).
  printf '%s\n' "$1" | jq -ce '
    {globals: (with_entries(select(.value.version | type == "string") | .value = .value.version)),
     globals_unpinnable: ([to_entries[] | select(.value.pinnable != true) | .key] | sort)}' 2>/dev/null
)

node_switch_plan() (
  # `node_switch_plan RECORD TARGET DEFS HOOKS` — THE carry rule, one pure
  # function every lane asks (the scheduled cadences, seal-plan, and the
  # executor's verify-preconditions):
  #
  #   The carry is every global installed under the current default, at its
  #   exact installed version. Nothing is added, and nothing installed is
  #   left behind.
  #
  # RECORD is `{globals, globals_unpinnable}` (the `fnm:node` record's data,
  # or node_globals_split). The rule depends on nothing but what is
  # installed: not desired state, not definitions, not holds. (An earlier
  # rule derived the carry from desired state, and every refinement found
  # another way to strand a package that was held, renamed or
  # disabled-but-held.) Two things are not carried:
  #
  #   excluded    what TARGET ships itself (node_target_bundled): npm, and
  #               corepack only on 24 and older. Moving off a bundling release
  #               carries the installed corepack from the registry at its
  #               version; dropping it would remove corepack and its shims.
  #   unpinnable  a global that cannot be reinstalled by exact registry
  #               version (`file:`, `link:`, git, no version). The switch
  #               HOLDS naming it rather than strand it. A `globals_unpinnable`
  #               that is not a list (null: the detail query failed) is
  #               unknown, and unknown holds too.
  #
  # Hooks keep their trust model. `required` is every `node_switch` hook a
  # definition (DEFS) requires for a CARRIED package; `hooks` is what this
  # host's config.json (HOOKS, `node_switch_hooks`) declares for the carried
  # packages, in carry order, and is what runs. A required hook that is not
  # declared, or a malformed `node_switch` on a carried package, holds.
  jq -cn --argjson record "$1" --argjson bundled "$(node_target_bundled "$2")" \
    --argjson defs "$3" --argjson local "$4" "$npm_jq_grammar"'
    ($record.globals // {}) as $globals |
    ($record.globals_unpinnable | type == "array") as $detail_known |
    (if $detail_known then $record.globals_unpinnable else [] end) as $unpinnable |
    def provided($n): any($bundled[]; . == $n);
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
      all(.[]; npm_argv_ok)) | not)] as $malformed |
    [$carried[] | . as $n | $wants[] | select(.name == $n) |
      select(.hooks | type == "array" and all(.[]; npm_argv_ok)) |
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

node_switch_plan_from_snapshot() (
  # `node_switch_plan_from_snapshot SNAPSHOT TARGET DEFS HOOKS` — the one
  # snapshot -> plan path seal-plan and the executor share. Exit 65 when the
  # snapshot has no usable `fnm:node` record. An interrupted switch recorded
  # in it (`switch_inflight`) holds whatever the plan would otherwise say.
  node_snapshot_record=$(jq -cs 'first(.[] | select(.kind == "package" and .id == "fnm:node" and
    .status == "present") | .data) // null' "$1") || exit 65
  printf '%s\n' "$node_snapshot_record" | jq -e '(.globals | type == "object") and
    (.installed_version | type == "string")' >/dev/null 2>&1 || exit 65
  node_snapshot_plan=$(node_switch_plan "$node_snapshot_record" "$2" "$3" "$4") || exit 65
  printf '%s\n' "$node_snapshot_plan" | jq -c --argjson record "$node_snapshot_record" '
    if ($record.switch_inflight // null) != null then
      .held = "an interrupted Node switch (\($record.switch_inflight.old // "?") -> \($record.switch_inflight.target // "?")) is pending recovery on this host"
    else . end'
)

node_switch_operations_valid() (
  # `node_switch_operations_valid PLAN_OR_DRAFT` — the shape of every Node
  # switch operation, for seal-plan and verify-preconditions alike: at most
  # one, `fnm:node` only, the fixed marker argv, and `carry`, `hooks` and
  # `required` in the npm grammar. `carry`, `hooks` and `required` appear on
  # no other operation.
  jq -e "$npm_jq_grammar"'
    def hook_list_ok: type == "array" and length <= 64 and
      all(.[]; type == "object" and (keys == ["argv","package"]) and
        (.package | npm_id_ok) and (.argv | npm_argv_ok));
    ([.operations[] | select(.id == "fnm:node")] | length) <= 1 and
    all(.operations[];
      if (.id | startswith("fnm:")) then
        .id == "fnm:node" and .type == "package-upgrade" and
        (.candidate_version | node_version_ok) and
        .argv == ["fnm","default",.candidate_version] and
        (.carry | type == "array" and length <= 256 and ((map(.name) | unique | length) == length) and
          all(.[]; type == "object" and (keys == ["name","version"]) and
            (.name | npm_name_ok) and (.version | npm_version_ok))) and
        (.hooks | hook_list_ok) and (.required | hook_list_ok)
      else (has("carry") or has("hooks") or has("required")) | not end)
  ' "$1" >/dev/null 2>&1
)

node_switch_verify_snapshot() (
  # `node_switch_verify_snapshot PLAN SNAPSHOT CONFIG` — the Node switch check
  # every executing host runs at apply: the carry rule over the fresh
  # snapshot must hold nothing (no unpinnable global, no interrupted switch)
  # and give exactly the sealed carry and hooks, and every sealed `required`
  # hook must be among the hooks. It needs no store: the carry is the
  # installed set, and `required` is bound by the plan digest.
  node_verify_target=$(jq -r 'first(.operations[] | select(.type == "package-upgrade" and
    .id == "fnm:node")) | .candidate_version' "$1") || exit 1
  node_verify_plan=$(node_switch_plan_from_snapshot "$2" "$node_verify_target" '{}' \
    "$(jq -c '.node_switch_hooks // {}' "$3")") || exit 1
  jq -e --argjson current "$node_verify_plan" '
    $current.held == null and
    all(.operations[] | select(.type == "package-upgrade" and .id == "fnm:node");
      . as $op | $op.carry == $current.carry and $op.hooks == $current.hooks and
      all($op.required[]; . as $r | any($op.hooks[]; . == $r)))
  ' "$1" >/dev/null
)

# --- host-local switch state: the lock, the in-flight record, the backoff -------
#
# A switch flips the live default only after the target prefix holds exactly
# the carry, so the window in which the host runs a default its globals were
# not verified for is: the flip, the hooks, and clearing the in-flight
# record. The record is written just before the flip and removed only on
# verified success or a verified restore. While it exists, `runtimes.node`
# holds (and alerts), every npm mutation stays off the runtime, nothing seals
# a new switch, and each run tries a verified restore of the old default.
#
# One lock covers a whole switch and a whole recovery, in every lane (the
# scheduled run, `fleet-apply`, a sealed local or SSH apply), so a recovery
# can never roll back a switch that is still running. The record names its
# writer by PID and start time for the same reason.
#
# All of it lives at one fixed path under $HOME, never under
# XDG_STATE_HOME: launchd, an SSH worker and an interactive shell disagree on
# that variable, and every lane must see the same record. The runtime it
# guards is the account's own fnm default, under the same $HOME.

node_switch_state_dir() (
  printf '%s/.local/state/roundhouse\n' "$HOME"
)

node_switch_marker_path() (
  printf '%s/node-switch-inflight.json\n' "$(node_switch_state_dir)"
)

node_switch_lock_path() (
  printf '%s/node-switch.lock\n' "$(node_switch_state_dir)"
)

node_switch_backoff_path() (
  printf '%s/node-switch-backoff.json\n' "$(node_switch_state_dir)"
)

node_process_start() (
  # `node_process_start PID` — when PID started, as ps prints it, or nothing.
  # PID and start time together name one process: a recycled PID starts
  # at another time. Always in UTC and the C locale: ps prints local time,
  # and lanes whose TZ differs (launchd, an SSH worker, a shell) must read
  # the same holder the same way.
  TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//' | head -1
)

node_process_live() (
  # `node_process_live PID START` — that exact process is still running.
  [[ ${1:-} =~ ^[1-9][0-9]{0,9}$ ]] && [ -n "${2:-}" ] || exit 1
  kill -0 "$1" 2>/dev/null || exit 1
  [ "$(node_process_start "$1")" = "$2" ]
)

node_switch_lock_owner() (
  # The lock's owner file as written (PID, then start time), or nothing.
  cat "$(node_switch_lock_path)/owner" 2>/dev/null || :
)

node_switch_lock_stale() (
  # `node_switch_lock_stale OWNER` — OWNER (node_switch_lock_owner's text)
  # no longer holds the lock: its process is gone, or, with no owner
  # written, the lock directory is over a minute old (a taker killed between
  # its mkdir and its owner write). A young owner-less lock is a taker
  # mid-write, and live.
  node_stale_pid=$(printf '%s\n' "$1" | sed -n 1p)
  node_stale_start=$(printf '%s\n' "$1" | sed -n 2p)
  if [ -z "$node_stale_pid" ]; then
    [ -n "$(find "$(node_switch_lock_path)" -maxdepth 0 -mmin +1 2>/dev/null)" ]
    exit
  fi
  ! node_process_live "$node_stale_pid" "$node_stale_start"
)

node_switch_lock_take() (
  # `node_switch_lock_take PID` — take the host's one Node switch lock for
  # process PID (the caller's own subshell). mkdir is the atomic step; the
  # owner file names the holder by PID and start time. Exit 0 taken, 75 held
  # by a live process, 1 when the state directory is unusable.
  #
  # A lock whose holder is gone (killed mid-switch) is stale and is taken
  # over, but only under a second mutex (`.break`), re-checking under it
  # that the lock still has the owner judged stale. Without that, two
  # contenders that both judged it stale could both take it: the second
  # would remove the lock the first had just created. The in-flight record,
  # not the lock, says whether anything needs rolling back.
  node_lock=$(node_switch_lock_path)
  (umask 077 && mkdir -p "${node_lock%/*}") || exit 1
  node_lock_start=$(node_process_start "$1")
  [ -n "$node_lock_start" ] || exit 1
  node_lock_try=0
  while [ "$node_lock_try" -lt 50 ]; do
    node_lock_try=$((node_lock_try + 1))
    if mkdir "$node_lock" 2>/dev/null; then
      printf '%s\n%s\n' "$1" "$node_lock_start" >"$node_lock/owner" || {
        rm -rf "$node_lock"
        exit 1
      }
      exit 0
    fi
    node_lock_seen=$(node_switch_lock_owner)
    [ -d "$node_lock" ] || continue
    node_switch_lock_stale "$node_lock_seen" || exit 75
    # Test-only, inert outside the self-check: widens the window between
    # judging the lock stale and breaking it.
    if [ "${ROUNDHOUSE_SELFTEST:-0}" = 1 ] && [ -n "${ROUNDHOUSE_TEST_NODE_LOCK_DELAY:-}" ]; then
      sleep "$ROUNDHOUSE_TEST_NODE_LOCK_DELAY"
    fi
    if mkdir "$node_lock.break" 2>/dev/null; then
      if [ -d "$node_lock" ] && [ "$(node_switch_lock_owner)" = "$node_lock_seen" ]; then
        rm -rf "$node_lock"
        if mkdir "$node_lock" 2>/dev/null; then
          printf '%s\n%s\n' "$1" "$node_lock_start" >"$node_lock/owner" || {
            rm -rf "$node_lock"
            rmdir "$node_lock.break" 2>/dev/null || :
            exit 1
          }
          rmdir "$node_lock.break" 2>/dev/null || :
          exit 0
        fi
      fi
      rmdir "$node_lock.break" 2>/dev/null || :
    else
      # Another contender is breaking it. A break mutex its breaker was
      # killed holding is abandoned after a minute.
      if [ -n "$(find "$node_lock.break" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$node_lock.break" 2>/dev/null || :
      fi
      sleep 0.1
    fi
  done
  exit 75
)

node_switch_lock_release() (
  # `node_switch_lock_release PID` — only the holder releases.
  node_lock=$(node_switch_lock_path)
  [ "$(sed -n 1p "$node_lock/owner" 2>/dev/null)" = "$1" ] || exit 0
  rm -rf "$node_lock"
)

node_switch_marker_read() (
  # The record as compact JSON, or nothing when no switch is in flight. An
  # unreadable record still reads as in flight, with nothing to restore to.
  node_marker=$(node_switch_marker_path)
  [ -e "$node_marker" ] || exit 0
  jq -ce 'select(type == "object")' "$node_marker" 2>/dev/null ||
    printf '%s\n' '{"old":null,"target":null,"unreadable":true}'
)

node_switch_marker_write() (
  # `node_switch_marker_write OLD TARGET CARRY PID START`
  node_marker=$(node_switch_marker_path)
  umask 077
  mkdir -p "${node_marker%/*}" || exit 1
  jq -cn --arg old "$1" --arg target "$2" --argjson carry "$3" --arg pid "${4:-}" --arg start "${5:-}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{old:$old,target:$target,carry:$carry,writer:{pid:$pid,start:$start},at:$at}' \
    >"$node_marker.$$" && mv -f "$node_marker.$$" "$node_marker"
)

node_switch_marker_clear() (
  rm -f "$(node_switch_marker_path)"
)

node_switch_writer_live() (
  # `node_switch_writer_live RECORD` — the process that wrote the record is
  # still running: the switch is in progress, not interrupted.
  node_writer_pid=$(printf '%s\n' "$1" | jq -r '.writer.pid // empty' 2>/dev/null) || exit 1
  node_writer_start=$(printf '%s\n' "$1" | jq -r '.writer.start // empty' 2>/dev/null) || exit 1
  node_process_live "$node_writer_pid" "$node_writer_start"
)

# A post-switch hook that always fails would otherwise flip the live default
# and restore it on every fast pass. After a hook failure the attempt
# (target, carry, hooks) is recorded; the reviewed apply holds that exact
# attempt, and only the full cadence, or a change to any of the three,
# retries it. A successful switch clears it.

node_switch_backoff_write() (
  # `node_switch_backoff_write TARGET CARRY HOOKS`
  node_backoff=$(node_switch_backoff_path)
  umask 077
  mkdir -p "${node_backoff%/*}" || exit 1
  jq -cn --arg target "$1" --argjson carry "$2" --argjson hooks "$3" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{target:$target,carry:$carry,hooks:$hooks,at:$at}' \
    >"$node_backoff.$$" && mv -f "$node_backoff.$$" "$node_backoff"
)

node_switch_backoff_matches() (
  # `node_switch_backoff_matches TARGET CARRY HOOKS` — exactly this attempt
  # failed its hooks before.
  node_backoff=$(node_switch_backoff_path)
  [ -f "$node_backoff" ] || exit 1
  jq -e --arg target "$1" --argjson carry "$2" --argjson hooks "$3" \
    '.target == $target and .carry == $carry and .hooks == $hooks' "$node_backoff" >/dev/null 2>&1
)

node_switch_backoff_clear() (
  rm -f "$(node_switch_backoff_path)"
)

# The PID of the calling subshell, for the lock and the record's writer.
# BASHPID where bash has it; bash 3.2 does not, and there a command
# substitution forks a child of the caller and `exec` turns that child into
# sh, so sh's parent is the caller. Always written inline, never wrapped in
# a function (a wrapper would add a process of its own).
# shellcheck disable=SC2016 # $PPID is sh's own
node_self_pid_sh='printf "%s\n" "$PPID"'

node_default_verified() (
  # `node_default_verified ROOT VERSION` — the fnm default is VERSION,
  # provably: the alias names it, the durable npm resolves through the
  # alias, and that npm's node is VERSION. The one check behind a restore, a
  # flip and the end of a switch.
  [ "$(node_fnm_default "$1" 2>/dev/null)" = "$2" ] || exit 1
  node_verified_bin=$(npm_global_bin_dir 2>/dev/null) || exit 1
  [ "$node_verified_bin" = "$1/aliases/default/bin" ] || exit 1
  [ "$(PATH="$node_verified_bin:$PATH" "$node_verified_bin/node" --version 2>/dev/null </dev/null |
    head -1)" = "$2" ]
)

node_switch_restore() (
  # `node_switch_restore ROOT OLD` — point the default back at OLD and prove
  # it. OLD's prefix is never touched by a switch, so its globals are as they
  # were.
  node_fnm_run "$1" default "$2" >/dev/null 2>&1 || :
  node_default_verified "$1" "$2" || exit 70
)

node_switch_lock_enter() {
  # Brace function, on purpose: it runs in the CALLER's subshell, so the
  # PID it records is the caller's and the release trap is the caller's
  # EXIT trap. Sets node_self. Returns 0 holding the lock, 75 when a live
  # process holds it, 69 when it cannot be taken. The one way into the lock
  # for a switch, a recovery and node-switch-clear.
  node_self=${BASHPID:-$(exec sh -c "$node_self_pid_sh")}
  node_lock_status=0
  node_switch_lock_take "$node_self" || node_lock_status=$?
  case $node_lock_status in
    0)
      trap 'node_switch_lock_release "$node_self"' EXIT
      return 0
      ;;
    75) return 75 ;;
    *) return 69 ;;
  esac
}

node_switch_recover() (
  # For a run that finds a switch in flight: restore the recorded old
  # default, verified, and clear the record, under the switch lock. Exit 0
  # when nothing is in flight, 74 when a switch is in progress (the lock or
  # the record's writer is a live process: not interrupted, left alone), 75
  # when a switch was rolled back (the run holds; the switch is retried
  # later), 76 when it could not be (the default stays unverified).
  [ -n "$(node_switch_marker_read)" ] || exit 0
  node_recover_lock=0
  node_switch_lock_enter || node_recover_lock=$?
  case $node_recover_lock in
    0) ;;
    75) exit 74 ;;
    *) exit 76 ;;
  esac
  node_marker=$(node_switch_marker_read)
  [ -n "$node_marker" ] || exit 0
  ! node_switch_writer_live "$node_marker" || exit 74
  node_recover_old=$(printf '%s\n' "$node_marker" | jq -r '.old // empty')
  node_version_valid "$node_recover_old" || exit 76
  node_recover_root=$(node_fnm_root 2>/dev/null) || exit 76
  [ -x "$node_recover_root/node-versions/$node_recover_old/installation/bin/node" ] || exit 76
  node_switch_restore "$node_recover_root" "$node_recover_old" || exit 76
  node_switch_marker_clear
  exit 75
)

node_switch_clear() (
  # `roundhouse node-switch-clear` — the way out of a record no run can roll
  # back (its old version was uninstalled, or the record is unreadable). It
  # never clears blindly: no switch may be running, and the CURRENT default
  # must be self-consistent (node_default_verified) with its npm globals
  # listable. The next run then converges `runtimes.node` from that default.
  # It also clears the post-switch hook backoff.
  node_marker=$(node_switch_marker_read)
  [ -n "$node_marker" ] || {
    if [ -e "$(node_switch_backoff_path)" ]; then
      node_switch_backoff_clear
      printf 'roundhouse: no Node switch is recorded in flight; cleared the post-switch hook backoff\n'
    else
      printf 'roundhouse: no Node switch is recorded in flight; nothing to clear\n'
    fi
    exit 0
  }
  node_clear_lock=0
  node_switch_lock_enter || node_clear_lock=$?
  case $node_clear_lock in
    0) ;;
    75)
      printf 'roundhouse: a Node switch is in progress on this host; nothing cleared\n' >&2
      exit 75
      ;;
    *)
      printf 'roundhouse: cannot take the Node switch lock %s\n' "$(node_switch_lock_path)" >&2
      exit 69
      ;;
  esac
  node_marker=$(node_switch_marker_read)
  [ -n "$node_marker" ] || exit 0
  ! node_switch_writer_live "$node_marker" || {
    printf 'roundhouse: the process that recorded the Node switch is still running; nothing cleared\n' >&2
    exit 75
  }
  node_clear_root=$(node_fnm_root) || {
    printf 'roundhouse: no fnm default Node on this host; set one (fnm default <version>) and rerun\n' >&2
    exit 65
  }
  node_clear_current=$(node_fnm_default "$node_clear_root") || {
    printf 'roundhouse: the fnm default alias does not name an installed version; set one (fnm default <version>) and rerun\n' >&2
    exit 65
  }
  node_default_verified "$node_clear_root" "$node_clear_current" || {
    printf 'roundhouse: the fnm default %s is not self-consistent (alias, durable npm and node disagree); repair it (fnm default <version>) and rerun\n' \
      "$node_clear_current" >&2
    exit 65
  }
  npm_global_list_detail >/dev/null || {
    printf 'roundhouse: the npm globals under %s cannot be listed; nothing cleared\n' "$node_clear_current" >&2
    exit 65
  }
  node_switch_marker_clear
  # Its backoff goes with it: the next run starts from the verified default.
  node_switch_backoff_clear
  printf 'roundhouse: cleared the in-flight Node switch %s -> %s; the fnm default is %s (verified). Hooks that switch did not finish are not rerun: run them by hand if needed.\n' \
    "$(printf '%s\n' "$node_marker" | jq -r '.old // "?"')" \
    "$(printf '%s\n' "$node_marker" | jq -r '.target // "?"')" "$node_clear_current"
)

node_switch_npm_blocked() (
  # `node_switch_npm_blocked PLAN SNAPSHOT` — PLAN upgrades an npm global
  # while SNAPSHOT records a Node switch in flight on its host. seal-plan and
  # verify-preconditions refuse such a plan; the executor re-checks its own
  # record.
  jq -e 'any(.operations[]?; .type == "package-upgrade" and (.id | startswith("npm:")))' \
    "$1" >/dev/null 2>&1 || exit 1
  jq -se 'any(.[]; .kind == "package" and .id == "fnm:node" and
    ((.data.switch_inflight // null) != null))' "$2" >/dev/null 2>&1
)

# --- the switch ------------------------------------------------------------------
#
# node_runtime_switch takes the lock and runs three phases. The phase
# functions are brace functions on purpose: they run only inside
# node_runtime_switch's subshell, share its node_* variables, and `exit` it.

node_runtime_switch() (
  # `node_runtime_switch TARGET CARRY HOOKS` — make TARGET the fnm default with
  # exactly CARRY in its prefix, then run HOOKS. Shared by the sealed
  # executor and the desired-state run, so both lanes switch the same way.
  #
  #   CARRY  JSON array of {name, version}: globals installed under the
  #          CURRENT default that must exist, at exactly those versions,
  #          under TARGET afterwards
  #   HOOKS  JSON array of {package: "npm:<name>", argv}: post-switch hooks,
  #          each a bin of a carried package, already trust-checked by the
  #          caller against this host's config.json
  #
  # Exit 0 switched and verified; 64 invalid input; 65 refused, nothing
  # changed; 69 no fnm/npm here; 75 another switch holds the lock; 1 failed
  # and the old default is live (never moved, or restored and verified); 70
  # failed and the restore could not be verified (the record stays).
  node_target=$1
  node_carry=$2
  node_hooks=$3
  node_switch_args_valid
  node_switch_lock=0
  node_switch_lock_enter || node_switch_lock=$?
  case $node_switch_lock in
    0) ;;
    75)
      printf 'roundhouse: another Node switch is in progress on this host; not switching\n' >&2
      exit 75
      ;;
    *)
      printf 'roundhouse: cannot take the Node switch lock %s\n' "$(node_switch_lock_path)" >&2
      exit 69
      ;;
  esac
  node_switch_preflight
  node_switch_stage
  node_switch_flip
)

node_switch_args_valid() {
  node_version_valid "$node_target" || {
    printf 'roundhouse: invalid Node target version %s\n' "$node_target" >&2
    exit 64
  }
  printf '%s\n' "$node_carry" | jq -e "$npm_jq_grammar"'
    type == "array" and length <= 256 and
    all(.[]; type == "object" and (.name | npm_name_ok) and (.version | npm_version_ok)) and
    ((map(.name) | unique | length) == length)' >/dev/null 2>&1 || {
    printf 'roundhouse: invalid Node switch carry list\n' >&2
    exit 64
  }
  printf '%s\n' "$node_hooks" | jq -e "$npm_jq_grammar"'
    type == "array" and length <= 64 and
    all(.[]; type == "object" and (.package | npm_id_ok) and (.argv | npm_argv_ok))' \
    >/dev/null 2>&1 || {
    printf 'roundhouse: invalid Node switch hook list\n' >&2
    exit 64
  }
}

node_switch_preflight() {
  # PREFLIGHT mutates nothing (exit 65/69).
  [ -z "$(node_switch_marker_read)" ] || {
    printf 'roundhouse: an interrupted Node switch is pending recovery; refusing another\n' >&2
    exit 65
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
  # The carry reproduces what is installed now, at the stated versions; it
  # never introduces a package.
  printf '%s\n' "$node_before" | jq -e --argjson carry "$node_carry" '
    . as $before | all($carry[]; $before[.name] == .version)' >/dev/null || {
    printf 'roundhouse: the carry is not what is installed under %s; refusing the switch\n' \
      "$node_old" >&2
    exit 65
  }
  # Every hook names a carried package and is provable, under the current
  # prefix, as one of its bins. The proof runs again under the new prefix
  # right before the hook executes.
  node_hook_bad=$(printf '%s\n' "$node_hooks" | jq -r --argjson carry "$node_carry" '
    first(.[] | .package | ltrimstr("npm:") as $n | select(any($carry[]; .name == $n) | not) | $n) // empty')
  [ -z "$node_hook_bad" ] || {
    printf 'roundhouse: a post-switch hook names %s, which is not carried\n' "$node_hook_bad" >&2
    exit 65
  }
  while IFS=$(printf '\t') read -r node_hook_name node_hook_bin; do
    [ -n "$node_hook_name" ] || continue
    npm_updater_path "$node_hook_name" "$node_hook_bin" >/dev/null 2>&1 || {
      printf 'roundhouse: post-switch hook %s is not a bin of the installed %s; refusing the switch\n' \
        "$node_hook_bin" "$node_hook_name" >&2
      exit 65
    }
  done <<EOF
$(printf '%s\n' "$node_hooks" | jq -r '.[] | [(.package | ltrimstr("npm:")), .argv[0]] | @tsv')
EOF
}

node_stage_fail() {
  printf 'roundhouse: %s; nothing switched (%s stays the default)\n' "$1" "$node_old" >&2
  exit 1
}

node_switch_stage() {
  # STAGING installs TARGET and makes its prefix exactly the carry, through
  # TARGET's own node and npm, while the old default stays live (exit 1 on
  # failure, nothing switched, nothing recorded).
  node_fnm_run "$node_root" install "$node_target" >/dev/null 2>&1 &&
    [ -x "$node_root/node-versions/$node_target/installation/bin/node" ] || {
    printf 'roundhouse: fnm install %s failed; nothing switched\n' "$node_target" >&2
    exit 1
  }
  node_target_prefix=$(node_fnm_prefix "$node_root" "$node_target") || exit 1
  node_target_bin=$node_target_prefix/bin
  node_bundled=$(node_target_bundled "$node_target")
  # The npm that installs the carry must not be older than the one the host
  # runs now: npm 12 honours `allow-scripts` in ~/.npmrc and an older
  # bundled npm would run every dependency install script. Bring the
  # target's npm up to the installed one first.
  node_old_npm=$(printf '%s\n' "$node_before" | jq -r '.npm // empty')
  node_target_npm=$(jq -r '.version // empty' "$node_target_prefix/lib/node_modules/npm/package.json" \
    2>/dev/null) || node_target_npm=
  if release_newer "$node_old_npm" "$node_target_npm"; then
    npm_prefix_run "$node_target_bin" "$node_target_prefix" install --global "npm@$node_old_npm" \
      >/dev/null 2>&1 || node_stage_fail "upgrading the npm of $node_target to $node_old_npm failed"
  fi
  node_specs=$(printf '%s\n' "$node_carry" | jq -r '.[] | "\(.name)@\(.version)"')
  if [ -n "$node_specs" ]; then
    # shellcheck disable=SC2086 # one validated name@version per word
    npm_prefix_run "$node_target_bin" "$node_target_prefix" install --global $node_specs \
      >/dev/null 2>&1 || node_stage_fail "carrying the npm globals to $node_target failed"
  fi
  # Exactly the carry: old versions are kept, so TARGET may be a version used
  # before, whose prefix still holds globals removed or disabled since. Left
  # there, a rollback would resurrect them.
  node_present=$(npm_prefix_list_detail "$node_target_bin" "$node_target_prefix") ||
    node_stage_fail "the npm globals under $node_target cannot be listed"
  while IFS= read -r node_extra; do
    [ -n "$node_extra" ] || continue
    npm_prefix_run "$node_target_bin" "$node_target_prefix" uninstall --global "$node_extra" \
      >/dev/null 2>&1 ||
      node_stage_fail "could not remove $node_extra, left in $node_target by an earlier use"
  done <<EOF
$(printf '%s\n' "$node_present" | jq -r --argjson carry "$node_carry" --argjson bundled "$node_bundled" '
  keys[] | . as $n | select((any($carry[]; .name == $n) | not) and (any($bundled[]; . == $n) | not))')
EOF
  node_after=$(npm_prefix_list_detail "$node_target_bin" "$node_target_prefix") || node_after=null
  printf '%s\n' "$node_after" | jq -e --argjson carry "$node_carry" --argjson bundled "$node_bundled" '
    . as $after | type == "object" and
    ([$after | keys[] | . as $n | select(any($bundled[]; . == $n) | not)] | sort) ==
      ([$carry[].name] | sort) and
    all($carry[]; $after[.name].version == .version)' >/dev/null ||
    node_stage_fail "the npm globals under $node_target are not exactly the carry at its versions"
}

node_switch_fail() {
  # After the flip: restore the old default, verified, and clear the record
  # (exit 1), or leave the record when the restore cannot be verified (70).
  printf 'roundhouse: %s\n' "$1" >&2
  if node_switch_restore "$node_root" "$node_old"; then
    node_switch_marker_clear
    printf 'roundhouse: fnm default restored to %s (%s stays installed)\n' \
      "$node_old" "$node_target" >&2
    exit 1
  fi
  printf 'roundhouse: could not restore the fnm default to %s; the switch stays recorded as in flight\n' \
    "$node_old" >&2
  exit 70
}

node_switch_flip() {
  # THE FLIP: record the switch in flight (with this process as its writer),
  # move the default, prove it, run the hooks, prove the default again, and
  # only then clear the record.
  if [ "$node_old" != "$node_target" ]; then
    node_switch_marker_write "$node_old" "$node_target" "$node_carry" \
      "$node_self" "$(node_process_start "$node_self")" ||
      node_stage_fail "could not record the switch as in flight"
    node_fnm_run "$node_root" default "$node_target" >/dev/null 2>&1 ||
      node_switch_fail "fnm default $node_target failed"
  fi
  node_default_verified "$node_root" "$node_target" ||
    node_switch_fail "the durable npm does not run under $node_target after the switch"
  # Hooks write to a file, never to this function's output: a hook that
  # starts a daemon (a service repair does) must not hold the caller's
  # capture or an SSH session open.
  node_hook_log=$(mktemp "${TMPDIR:-/tmp}/roundhouse-node-hook.XXXXXX") ||
    node_switch_fail "could not create the post-switch hook log"
  while IFS= read -r node_hook; do
    [ -n "$node_hook" ] || continue
    node_hook_name=$(printf '%s\n' "$node_hook" | jq -r '.package | ltrimstr("npm:")')
    node_hook_argv=()
    while IFS= read -r node_hook_arg; do
      node_hook_argv+=("$node_hook_arg")
    done < <(printf '%s\n' "$node_hook" | jq -r '.argv[]')
    # npm_global_run_updater re-proves the bin under the NEW prefix and runs
    # it by absolute path with the new node first on PATH.
    npm_global_run_updater "$node_hook_name" "${node_hook_argv[@]}" >"$node_hook_log" 2>&1 || {
      tail -n 20 "$node_hook_log" >&2 2>/dev/null || :
      rm -f "$node_hook_log"
      # This exact attempt is not retried by the reviewed apply (backoff).
      node_switch_backoff_write "$node_target" "$node_carry" "$node_hooks" || :
      node_switch_fail "post-switch hook $(printf '%s\n' "$node_hook" | jq -c '.argv') for $node_hook_name failed"
    }
  done <<EOF
$(printf '%s\n' "$node_hooks" | jq -c '.[]')
EOF
  rm -f "$node_hook_log"
  # Nothing may have moved the default while the hooks ran.
  node_default_verified "$node_root" "$node_target" ||
    node_switch_fail "the fnm default moved off $node_target while the switch ran"
  node_switch_marker_clear
  node_switch_backoff_clear
  exit 0
}
