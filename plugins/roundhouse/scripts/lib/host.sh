# roundhouse — host and transport primitives: filesystem ownership and mode
# checks, digests, guarded output, ssh/scp invocation, executor integrity.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'roundhouse: jq is required; inventory unavailable\n' >&2
    exit 69
  fi
}

yq_is_mikefarah() {
  "$1" --version 2>/dev/null | grep -qi mikefarah
}

roundhouse_is_root() {
  # Absolute id, never $EUID: bash takes EUID from the environment when it is
  # set there. Without a usable id, `-O /` asks the kernel's effective uid
  # (whether it owns /) and is just as deaf to the environment.
  rir_uid=$(/usr/bin/id -u 2>/dev/null) || rir_uid=
  case $rir_uid in
    0) return 0 ;;
    '' | *[!0-9]*) [ -O / ] ;;
    *) return 1 ;;
  esac
}

root_node_ok() {
  # root_node_ok PATH — PATH itself (no ancestors) is owned by uid 0 and carries
  # no group or other write bit and no ACL. The twin of roundhouse-trustd's
  # trustd_node_ok; keep them in step. file_owner/file_mode do not serve: they
  # find stat on PATH and answer names. stat and ls are absolute so a caller's
  # PATH cannot answer for them. BSD or GNU stat is picked by OSTYPE (GNU
  # `stat -f` reads a file system, not a format). Darwin's ls prints `@`, not
  # `+`, when a node has both xattrs and an ACL, so there `ls -lde` lists it.
  case ${OSTYPE:-} in
    darwin*)
      rtp_stat=$(/usr/bin/stat -f '%u %Lp' "$1" 2>/dev/null) || return 1
      rtp_ls=$(/bin/ls -lde "$1" 2>/dev/null) || return 1
      case $rtp_ls in *$'\n'*) return 1 ;; esac
      ;;
    *bsd*)
      rtp_stat=$(/usr/bin/stat -f '%u %Lp' "$1" 2>/dev/null) || return 1
      rtp_ls=$(/bin/ls -ld "$1" 2>/dev/null) || return 1
      ;;
    *)
      rtp_stat=$(/usr/bin/stat -c '%u %a' "$1" 2>/dev/null) || return 1
      rtp_ls=$(/bin/ls -ld "$1" 2>/dev/null) || return 1
      ;;
  esac
  case ${rtp_ls%% *} in *+*) return 1 ;; esac
  [ "${rtp_stat%% *}" = 0 ] || return 1
  rtp_mode=${rtp_stat##* }
  while [ "${#rtp_mode}" -gt 3 ]; do rtp_mode=${rtp_mode#?}; done
  case ${rtp_mode#?} in *[2367]*) return 1 ;; esac
}

root_trusted_path() {
  # root_trusted_path PATH -> its physical path, printed only when root may run
  # it: an absolute non-symlink that passes root_node_ok, as does every
  # directory up to / along its physical path. The physical path is what the
  # caller must exec: a symlinked ancestor cannot be swapped between this check
  # and the exec. Nothing here runs the file. The twin of roundhouse-trustd's
  # trustd_trusted_path, which must check this library before sourcing it.
  case $1 in /*) ;; *) return 1 ;; esac
  [ -e "$1" ] && [ ! -L "$1" ] || return 1
  rtp_dir=${1%/*}
  rtp_dir=$(CDPATH='' cd -P -- "${rtp_dir:-/}" 2>/dev/null && pwd -P) || return 1
  rtp_physical=${rtp_dir%/}/${1##*/}
  rtp_node=$rtp_physical
  while :; do
    root_node_ok "$rtp_node" || return 1
    [ "$rtp_node" != / ] || break
    rtp_node=${rtp_node%/*}
    [ -n "$rtp_node" ] || rtp_node=/
  done
  printf '%s\n' "$rtp_physical"
}

yq_known_locations() {
  # Where mikefarah yq lives when PATH does not lead to it.
  printf '%s\n' "${HOMEBREW_PREFIX:-/nonexistent}/bin/yq" \
    /home/linuxbrew/.linuxbrew/bin/yq /opt/homebrew/bin/yq /usr/local/bin/yq
}

select_mikefarah_yq() {
  # The fleet store needs mikefarah yq v4. Some hosts (Debian/Ubuntu under WSL)
  # put the unrelated Python `yq` first on PATH, so when the first `yq` is not
  # mikefarah's, find one that is and route `yq` to it through an exported
  # function. The choice lives only in this process and its bash children:
  # nothing is written, and every other tool keeps its PATH position. A command
  # that EXECS yq rather than calling it (xargs, env, find -exec) bypasses the
  # function and must name "${ROUNDHOUSE_YQ:-yq}" instead: a bare `xargs yq`
  # ran Python yq on iris-wsl and sent every fast pass down the per-item path.
  #
  # Choosing means running `--version`, so as root it is its own branch: see
  # select_mikefarah_yq_root.
  if roundhouse_is_root; then
    select_mikefarah_yq_root
    return 0
  fi
  selected_yq=$(command -v yq 2>/dev/null || true)
  if [ -n "$selected_yq" ] && yq_is_mikefarah "$selected_yq"; then
    # PATH's own yq: an inherited ROUNDHOUSE_YQ without its function is stale.
    [ "$(type -t yq)" != file ] || unset ROUNDHOUSE_YQ
    return 0
  fi
  for yq_candidate in $(which -a yq 2>/dev/null) $(yq_known_locations); do
    if ! { [ -x "$yq_candidate" ] && yq_is_mikefarah "$yq_candidate"; }; then continue; fi
    ROUNDHOUSE_YQ=$yq_candidate
    export ROUNDHOUSE_YQ
    yq() { command "$ROUNDHOUSE_YQ" "$@"; }
    export -f yq
    return 0
  done
}

select_mikefarah_yq_root() {
  # As root, a `--version` probe of a yq the user can replace is root running the
  # user's code (#62): Homebrew and Linuxbrew prefixes are user-owned, and so is
  # anything a user PATH puts first. So root considers ONLY candidates that
  # root_trusted_path accepts, runs only those, and runs them by their physical
  # path. A pin the caller already made (roundhouse-trustd's toolchain, in
  # ROUNDHOUSE_YQ) is first and wins when it is trusted. With no trusted
  # mikefarah yq, `yq` becomes a function that refuses: no later bare `yq` can
  # fall through to a PATH lookup, and require_yq names the reason.
  unset -f yq
  for yq_candidate in ${ROUNDHOUSE_YQ:+"$ROUNDHOUSE_YQ"} $(type -aP yq 2>/dev/null) \
    $(yq_known_locations); do
    yq_trusted=$(root_trusted_path "$yq_candidate") || continue
    [ -x "$yq_trusted" ] || continue
    if [ "$yq_candidate" != "${ROUNDHOUSE_YQ:-}" ] && ! yq_is_mikefarah "$yq_trusted"; then
      continue
    fi
    ROUNDHOUSE_YQ=$yq_trusted
    export ROUNDHOUSE_YQ
    yq() { command "$ROUNDHOUSE_YQ" "$@"; }
    export -f yq
    return 0
  done
  unset ROUNDHOUSE_YQ
  yq() {
    printf 'roundhouse: no root-owned mikefarah yq; refusing to run a yq the user can replace as root\n' >&2
    return 69
  }
}

require_yq() {
  if roundhouse_is_root; then
    # Never `command -v` + `--version` here: as root that is the probe #62 is
    # about. select_mikefarah_yq_root left either a trusted ROUNDHOUSE_YQ or a
    # refusing `yq`; check the path again rather than trust the variable.
    if [ -z "${ROUNDHOUSE_YQ:-}" ] || ! root_trusted_path "$ROUNDHOUSE_YQ" >/dev/null ||
      ! yq_is_mikefarah "$ROUNDHOUSE_YQ"; then
      printf 'roundhouse: no root-owned mikefarah yq v4; refusing to run a yq the user can replace as root\n' >&2
      exit 69
    fi
    return 0
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'roundhouse: yq is required; the fleet store is YAML\n' >&2
    exit 69
  fi
  if ! yq_is_mikefarah "$(command -v yq)"; then
    printf 'roundhouse: mikefarah yq v4 is required; %s is a different yq\n' "$(command -v yq)" >&2
    exit 69
  fi
}

system_ssh_keygen_path() {
  case $(uname -s) in
    Darwin|Linux) ssh_keygen=/usr/bin/ssh-keygen ;;
    *)
      printf 'roundhouse: node identity validation is unsupported on this platform\n' >&2
      return 69
      ;;
  esac
  [ -x "$ssh_keygen" ] || {
    printf 'roundhouse: absolute system ssh-keygen is unavailable: %s\n' "$ssh_keygen" >&2
    return 69
  }
  printf '%s\n' "$ssh_keygen"
}

system_ssh_path() {
  case $(uname -s) in
    Darwin|Linux) ssh_client=/usr/bin/ssh ;;
    *)
      printf 'roundhouse: protected POSIX SSH is unsupported on this platform\n' >&2
      return 69
      ;;
  esac
  [ -x "$ssh_client" ] || {
    printf 'roundhouse: absolute system ssh is unavailable: %s\n' "$ssh_client" >&2
    return 69
  }
  printf '%s\n' "$ssh_client"
}

ssh_run() {
  host=$1
  shift
  [ "$#" -gt 0 ] || {
    printf 'roundhouse: SSH command is required\n' >&2
    return 64
  }
  if [ "$#" -eq 1 ]; then
    remote_command=$1
  else
    remote_command=
    for arg in "$@"; do
      quoted=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
      remote_command="${remote_command}${remote_command:+ }'$quoted'"
    done
  fi
  quoted_command=$(printf '%s' "$remote_command" | sed "s/'/'\\\\''/g")
  ssh -o BatchMode=yes -o RequestTTY=no -o RemoteCommand=none \
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    "$host" "if [ -z \"\${SHELL:-}\" ] || [ ! -x \"\$SHELL\" ]; then printf 'roundhouse: configured login shell is unavailable\\n' >&2; exit 69; fi; exec \"\$SHELL\" -lc '$quoted_command'"
}

fleet_ssh_destination() {
  # fleet_ssh_destination NAME -> the SSH destination for a fleet machine.
  #
  # A machine's ROSTER IDENTITY and its TRANSPORT ADDRESS are two different
  # facts, and the enrollment path conflated them: `fleet-add mac-mini` used
  # `mac-mini` as both, so a machine whose ssh alias is `claires-mac-mini` did
  # not connect until somebody hand-added a `Host mac-mini` block to
  # ~/.ssh/config. config.json already carries the mapping and lib/inventory.sh
  # already reads it — this is that read, in one place, so the roster keeps the
  # config machine name and the transport follows the alias.
  #
  # An unlisted name falls back to itself rather than refusing: a scratch host
  # or a fixture that is not in config.json keeps working exactly as before.
  ssh_destination=$(jq -r --arg host "$1" '.machines[$host].ssh_alias // empty' \
    "$(config_path)" 2>/dev/null) || ssh_destination=
  [ -n "$ssh_destination" ] || ssh_destination=$1
  # The value comes out of a file this code did not write and reaches ssh as
  # argv, so it passes the same allowlist every other destination passes: an
  # option-shaped alias is refused here rather than becoming an ssh flag.
  fleet_host_name_ok "$ssh_destination" || return 64
  printf '%s\n' "$ssh_destination"
}

scp_run() {
  scp -q -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "$@"
}

file_mode() {
  mode=$(stat -f %Lp "$1" 2>/dev/null) ||
    mode=$(stat -c %a "$1" 2>/dev/null) ||
    mode=unknown
  printf '%s\n' "$mode"
}

file_owner() {
  owner=$(stat -f %Su "$1" 2>/dev/null) ||
    owner=$(stat -c %U "$1" 2>/dev/null) ||
    owner=unknown
  printf '%s\n' "$owner"
}

check_safe_owned_path() (
  path=$1
  label=$2
  kind=$3
  # Optional second acceptable owner, for trust material a privileged
  # enrollment installs (root-owned on a real host, self-owned in fixtures).
  also_owned_by=${4:-}
  case $kind in
    file)
      [ -f "$path" ] && [ ! -L "$path" ] || {
        printf 'roundhouse: %s must be a regular non-symlink file\n' "$label" >&2
        exit 64
      }
      ;;
    directory)
      [ -d "$path" ] && [ ! -L "$path" ] || {
        printf 'roundhouse: %s must be a non-symlink directory\n' "$label" >&2
        exit 64
      }
      ;;
    *) printf 'roundhouse: invalid safe-path kind\n' >&2; exit 64 ;;
  esac
  path_owner=$(file_owner "$path")
  [ "$path_owner" = "$(id -un)" ] ||
    { [ -n "$also_owned_by" ] && [ "$path_owner" = "$also_owned_by" ]; } || {
    printf 'roundhouse: %s is not owned by the current user\n' "$label" >&2
    exit 64
  }
  mode=$(file_mode "$path")
  permissions=$(printf '%s' "$mode" | sed 's/.*\(...\)$/\1/')
  group=$(printf '%s' "$permissions" | cut -c 2)
  world=$(printf '%s' "$permissions" | cut -c 3)
  case $group$world in
    *2*|*3*|*6*|*7*)
      printf 'roundhouse: %s is group/world writable\n' "$label" >&2
      exit 64
      ;;
  esac
)

check_private_owned_file() {
  check_safe_owned_path "$1" "$2" file
}

check_owner_only_file() {
  check_private_owned_file "$1" "$2"
  mode=$(file_mode "$1")
  permissions=$(printf '%s' "$mode" | sed 's/.*\(...\)$/\1/')
  [ "$(printf '%s' "$permissions" | cut -c 2-3)" = 00 ] || {
    printf 'roundhouse: %s must not be group/world readable or writable\n' "$2" >&2
    return 64
  }
}

# --- errexit, where callers depend on it -----------------------------------------
#
# bash IGNORES `set -e` inside anything run as part of `… || …`, `… && …`,
# `if …`, `while …` or `! …` — and inside every function and subshell that runs
# there, even one that says `set -e` itself. Code that stops on its first
# failed check through errexit (seal-plan, apply-plan, a converge pass) then
# carries on past the failure. These two make that a refusal, not a surprise.

errexit_require() {
  # errexit_require WHAT — exit 70 when called where errexit is suppressed.
  # Probe: a subshell that turns errexit on and fails; it stops at `false`
  # only where errexit can take effect. (bash 3.2 and 5.x alike.)
  errexit_require_was=$-
  set +e
  ( set -e; false; true )
  errexit_require_status=$?
  case $errexit_require_was in *e*) set -e ;; esac
  [ "$errexit_require_status" -ne 0 ] || {
    printf 'roundhouse: internal error: %s ran where errexit is suppressed (an `|| …`, `&& …`, `if` or `!` caller); refusing rather than running on past a failed check\n' \
      "$1" >&2
    exit 70
  }
}

errexit_capture() {
  # errexit_capture VAR COMMAND [ARG...] — run COMMAND in a subshell with
  # errexit LIVE inside it and its exit status in VAR: the one way to keep
  # errexit for COMMAND while taking its status. The caller's errexit setting
  # is restored as it was. COMMAND's variable assignments stay in its subshell.
  errexit_capture_var=$1
  shift
  errexit_capture_was=$-
  set +e
  ( set -e; "$@" )
  errexit_capture_status=$?
  case $errexit_capture_was in *e*) set -e ;; esac
  printf -v "$errexit_capture_var" '%s' "$errexit_capture_status"
}

check_mutation_config() {
  validate_config_file
  check_private_owned_file "$(config_path)" "mutation configuration"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    openssl dgst -sha256 "$1" | awk '{print tolower($NF)}'
  fi
}

sha256_file_list() {
  # `… -print0 | sha256_file_list` — stdin: NUL-separated file paths; stdout:
  # one `<sha256> <path>` line per file, through the same tool fallback as
  # sha256_file. BATCH-SAFE: the paths go through `xargs -0`, never one
  # argument list, so a large tree cannot hit "Argument list too long" — and
  # xargs' own status (123 when any batch fails) is this function's, so a
  # hashing failure is never silent. An EMPTY list hashes nothing: GNU xargs
  # would otherwise run the hasher once on stdin, and `-r` is not portable to
  # every BSD xargs, so the list is buffered and an empty one returns here.
  sha_list=$(mktemp "${TMPDIR:-/tmp}/roundhouse-sha-list.XXXXXX") || return 1
  cat >"$sha_list" || { rm -f "$sha_list"; return 1; }
  if [ ! -s "$sha_list" ]; then
    rm -f "$sha_list"
    return 0
  fi
  sha_rc=0
  if command -v sha256sum >/dev/null 2>&1; then
    xargs -0 sha256sum -- <"$sha_list" || sha_rc=$?
  elif command -v shasum >/dev/null 2>&1; then
    xargs -0 shasum -a 256 -- <"$sha_list" || sha_rc=$?
  else
    # `-r`: the coreutils `<hash> *<path>` form, one line per file.
    xargs -0 openssl dgst -sha256 -r <"$sha_list" || sha_rc=$?
  fi
  rm -f "$sha_list"
  return "$sha_rc"
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print tolower($1)}'
  else
    openssl dgst -sha256 | awk '{print tolower($NF)}'
  fi
}

# executor_files_fast_verify <manifest.tsv> <records.jsonl>
# Succeeds only when EVERY listed file passes what check_private_owned_file and
# the digest comparison in executor_status_command check one file at a time:
# a regular non-symlink file, owned by the current user, not group/world
# writable, hashing to its listed digest. Only then does it write the same
# {path,sha256} records. Any other outcome returns nonzero and the caller runs
# the per-file loop, so this can only ever save time, never change a verdict.
executor_files_fast_verify() (
  manifest=$1
  records=$2
  fast_user=$(id -un) || exit 1
  fast_paths=
  fast_count=0
  while IFS="$(printf '\t')" read -r relative expected; do
    # The manifest grammar (validated before this runs) is [A-Za-z0-9._/-],
    # so a plain word list is exact; "./" keeps a leading '-' from reading as
    # an option to stat or the hash tool.
    case $relative in ''|*[!A-Za-z0-9._/-]*) exit 1 ;; esac
    [ -f "$plugin_root/$relative" ] && [ ! -L "$plugin_root/$relative" ] || exit 1
    fast_paths="$fast_paths ./$relative"
    fast_count=$((fast_count + 1))
  done <"$manifest"
  [ "$fast_count" -gt 0 ] || exit 1
  cd "$plugin_root" || exit 1
  # GNU first: BSD stat rejects -c outright, while GNU `stat -f` is a
  # FILESYSTEM report that must never be read as file metadata.
  # shellcheck disable=SC2086 # deliberate: the validated word list above
  fast_stat=$(stat -c '%a %U' $fast_paths 2>/dev/null) ||
    fast_stat=$(stat -f '%Lp %Su' $fast_paths 2>/dev/null) || exit 1
  printf '%s\n' "$fast_stat" | awk -v user="$fast_user" -v want="$fast_count" '
    {
      mode = $1
      owner = $0
      sub(/^[^ ]* /, "", owner)
      if (owner != user || length(mode) < 3) { bad = 1; exit }
      permissions = substr(mode, length(mode) - 2)
      if (substr(permissions, 2, 2) ~ /[2367]/) { bad = 1; exit }
      seen++
    }
    END { if (bad || seen != want) exit 1 }
  ' || exit 1
  # sha256_file_list keeps manifest order; a short or failed listing cannot
  # equal the expected column, so it falls back like any other anomaly.
  fast_actual=$(cut -f 1 "$manifest" | awk '{ printf "./%s%c", $0, 0 }' |
    sha256_file_list 2>/dev/null | awk '{ print tolower($1) }') || exit 1
  [ "$fast_actual" = "$(cut -f 2 "$manifest")" ] || exit 1
  awk -F '\t' '{ printf "{\"path\":\"%s\",\"sha256\":\"%s\"}\n", $1, $2 }' \
    "$manifest" >"$records"
)

check_safe_owned_directory() {
  check_safe_owned_path "$1" "$2" directory
}

plugin_seal_link_target() {
  # plugin_seal_link_target LINK -> the physical path LINK's whole chain ends
  # at; 1 when it does not resolve (dangling, a loop, or over 40 links).
  seal_link=$1
  seal_hops=0
  while [ -L "$seal_link" ]; do
    seal_hops=$((seal_hops + 1))
    [ "$seal_hops" -le 40 ] || return 1
    seal_target=$(readlink -- "$seal_link") || return 1
    case $seal_target in
      /*) seal_link=$seal_target ;;
      *) seal_link=${seal_link%/*}/$seal_target ;;
    esac
  done
  [ -e "$seal_link" ] || return 1
  if [ -d "$seal_link" ]; then
    (CDPATH='' cd -P -- "$seal_link" 2>/dev/null && pwd -P)
  else
    seal_link_dir=$(CDPATH='' cd -P -- "${seal_link%/*}/" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "${seal_link_dir%/}" "${seal_link##*/}"
  fi
}

plugin_root_seal_permissions() {
  # plugin_root_seal_permissions DIR — remove group and other write bits from
  # a plugin tree before roundhouse trusts it, then refuse (1) if anything in
  # it is still writable by others or owned by another user, if a symlink in
  # it does not resolve to an entry inside it, or if the tree cannot be
  # scanned at all. A plugin manager
  # running under umask 002 (the WSL default) leaves a fresh cache
  # group-writable, and check_safe_owned_path then refuses it. This only
  # tightens modes and runs before any check, so the checks stay strict, and
  # the closing scan covers every entry, not only the files the manifest
  # lists: a writable or foreign-owned directory could swap a verified file
  # after the check. A link is never followed by `chmod -R`, so one that
  # leaves the tree would point at bytes this seal never touched (and a peer
  # could have planted it while the tree was writable): only a link whose
  # whole chain ends inside the sealed tree is accepted. It applies to an
  # absolute, non-symlink directory owned by the current user (anything else
  # is the verifier's to refuse; plugin_cache_seal_permissions, which has no
  # verifier after it, refuses it itself). A change is named on stderr, so a
  # tree that really was writable by others does not go unnoticed.
  case $1 in /*) ;; *) return 0 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] || return 0
  seal_user=$(id -un)
  [ "$(file_owner "$1")" = "$seal_user" ] || return 0
  if [ -n "$(find "$1" ! -type l \( -perm -020 -o -perm -002 \) -print 2>/dev/null |
    head -n 1)" ]; then
    printf 'roundhouse: removing group/world write permission under %s\n' "$1" >&2
    chmod -R go-w "$1" 2>/dev/null || :
  fi
  # The closing scan fails closed: a traversal error (an unreadable
  # directory) is a tree it cannot vouch for, not an empty answer.
  seal_unsafe=$(find "$1" ! -type l \( -perm -020 -o -perm -002 -o ! -user "$seal_user" \) \
    -print 2>/dev/null) || {
    printf 'roundhouse: %s cannot be scanned to seal it\n' "$1" >&2
    return 1
  }
  [ -z "$seal_unsafe" ] || {
    printf 'roundhouse: %s holds entries writable or owned by another user\n' "$1" >&2
    return 1
  }
  seal_base=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
  seal_list=$(mktemp "${TMPDIR:-/tmp}/roundhouse-seal.XXXXXX") || return 1
  find "$1" -type l -print0 >"$seal_list" 2>/dev/null || {
    rm -f "$seal_list"
    printf 'roundhouse: %s cannot be scanned to seal it\n' "$1" >&2
    return 1
  }
  seal_status=0
  while IFS= read -r -d '' seal_entry; do
    seal_to=$(plugin_seal_link_target "$seal_entry") || seal_to=
    case $seal_to in
      "$seal_base"/*) ;;
      *)
        printf 'roundhouse: %s holds a symlink that does not resolve inside it: %s\n' \
          "$1" "$seal_entry" >&2
        seal_status=1
        break
        ;;
    esac
  done <"$seal_list"
  rm -f "$seal_list"
  return "$seal_status"
}

plugin_seal_ancestors() {
  # plugin_seal_ancestors HOME DIR — seal and check every directory above DIR
  # up to the harness home HOME: through a writable parent a group member
  # could rename a sealed plugin directory and put another in its place
  # after the seal. Each must be a directory (the harness home may be reached
  # through a symlink; nothing below it may be one) owned by this user or
  # root; group/other write is removed from this user's own, and 1 when any
  # is still writable by others afterwards. DIR must lie under HOME.
  seal_anc_home=${1%/}
  seal_anc_dir=${2%/}
  case $seal_anc_dir in "$seal_anc_home"/?*) ;; *) return 1 ;; esac
  seal_anc_user=$(id -un)
  seal_anc_dir=${seal_anc_dir%/*}
  while :; do
    if [ "$seal_anc_dir" = "$seal_anc_home" ]; then
      seal_anc_check=$(CDPATH='' cd -P -- "$seal_anc_dir" 2>/dev/null && pwd -P) || seal_anc_check=
    else
      seal_anc_check=$seal_anc_dir
      [ ! -L "$seal_anc_check" ] || seal_anc_check=
    fi
    [ -n "$seal_anc_check" ] && [ -d "$seal_anc_check" ] || {
      printf 'roundhouse: %s is not a plain directory above a plugin cache\n' "$seal_anc_dir" >&2
      return 1
    }
    seal_anc_owner=$(file_owner "$seal_anc_check")
    [ "$seal_anc_owner" = "$seal_anc_user" ] || [ "$seal_anc_owner" = root ] || {
      printf 'roundhouse: %s, above a plugin cache, is owned by another user\n' "$seal_anc_dir" >&2
      return 1
    }
    if [ "$seal_anc_owner" = "$seal_anc_user" ] &&
      [ -n "$(find "$seal_anc_check" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>/dev/null)" ]; then
      printf 'roundhouse: removing group/world write permission from %s\n' "$seal_anc_dir" >&2
      chmod go-w "$seal_anc_check" 2>/dev/null || :
    fi
    seal_anc_open=$(find "$seal_anc_check" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>/dev/null) ||
      seal_anc_open=unscanned
    [ -z "$seal_anc_open" ] || {
      printf 'roundhouse: %s, above a plugin cache, is writable by others\n' "$seal_anc_dir" >&2
      return 1
    }
    [ "$seal_anc_dir" != "$seal_anc_home" ] || return 0
    seal_anc_dir=${seal_anc_dir%/*}
  done
}

plugin_cache_seal_permissions() {
  # plugin_cache_seal_permissions NAME[@MARKETPLACE] — seal a plugin's Claude
  # cache right after roundhouse installed or updated it (or found it already
  # current); 1 when it cannot be sealed. For roundhouse itself this is the
  # tree executor_status_command will trust; for any other plugin it is code
  # (hooks, MCP servers) that the harness runs as this user, which a group
  # member must not be able to edit. Nothing verifies the tree after this, so
  # an existing root it cannot seal — a symlink, not a directory, owned by
  # another user — refuses here; an absent one is nothing to seal. The
  # directories above it, up to the harness home, are sealed too
  # (plugin_seal_ancestors). The zero-config form, with no marketplace, seals
  # every marketplace's copy of NAME, since sealing only tightens. (Codex's
  # cache is sealed inside codex-plugin-hooks.mjs, before any hook trust is
  # read or written.)
  seal_home=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  seal_cache=$seal_home/plugins/cache
  seal_name=${1%%@*}
  case $seal_name in ''|.|..|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case $1 in
    *@*)
      seal_market=${1#*@}
      case $seal_market in ''|.|..|*[!A-Za-z0-9._-]*) return 0 ;; esac
      plugin_cache_seal_root "$seal_home" "$seal_cache/$seal_market/$seal_name"
      ;;
    *)
      for seal_dir in "$seal_cache"/*/"$seal_name"; do
        plugin_cache_seal_root "$seal_home" "$seal_dir" || return 1
      done
      ;;
  esac
}

plugin_cache_seal_root() {
  # plugin_cache_seal_root HOME ROOT — plugin_cache_seal_permissions' one
  # cache root: absent is 0, anything it cannot seal is 1.
  [ -e "$2" ] || [ -L "$2" ] || return 0
  case $2 in
    /*) ;;
    *)
      printf 'roundhouse: plugin cache %s is not an absolute path\n' "$2" >&2
      return 1
      ;;
  esac
  [ -d "$2" ] && [ ! -L "$2" ] && [ "$(file_owner "$2")" = "$(id -un)" ] || {
    printf 'roundhouse: plugin cache %s is a symlink, not a directory, or owned by another user\n' \
      "$2" >&2
    return 1
  }
  plugin_seal_ancestors "$1" "$2" && plugin_root_seal_permissions "$2"
}

check_enrolled_trust_file() {
  # Trust material the CA enrollment installs (the fleet CA public key, the
  # KRL): root-owned under /etc on a real host, self-owned in fixtures. Every
  # other trust-consuming path checks its input before believing it, and these
  # decide who may sign the fleet's state — so check the containing directory
  # too, or a writable parent lets anyone swap the file.
  check_safe_owned_path "$(dirname "$1")" "$2 directory" directory root &&
    check_safe_owned_path "$1" "$2" file root
}

executor_status_command() (
  output=${1:--}
  require_jq
  integrity=$plugin_root/integrity.json
  # Seal first, then verify: a manager update under umask 002 must not leave
  # this host refusing every sealed install until someone runs chmod by hand.
  plugin_root_seal_permissions "$plugin_root" || exit 64
  # An installed copy also needs the directories above it sealed, up to the
  # harness home: a writable parent lets a group member swap the whole tree
  # after it was verified (plugin_seal_ancestors). A source checkout is not
  # under a harness cache, and has none to check.
  # The home is compared as `pwd` spells it, the way plugin_root was found.
  for executor_home in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${CODEX_HOME:-$HOME/.codex}"; do
    executor_home=$(CDPATH='' cd -- "$executor_home" 2>/dev/null && pwd) || continue
    case $plugin_root in
      "${executor_home%/}"/plugins/cache/?*/?*)
        plugin_seal_ancestors "$executor_home" "$plugin_root" || exit 64
        ;;
    esac
  done
  check_safe_owned_directory "$plugin_root" "plugin root"
  check_private_owned_file "$integrity" "executor integrity manifest"
  jq -e '
    .schema == "roundhouse.integrity" and
    .schema_version == 1 and
    .plugin == "roundhouse" and
    (.marketplace | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.files | type == "array" and length > 0) and
    ((.files | map(.path) | unique | length) == (.files | length)) and
    ([.files[] |
      (.path | type == "string" and
        test("^[A-Za-z0-9._/-]+$") and
        startswith("/") | not) and
      (.path | test("(^|/)\\.\\.(/|$)") | not) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ] | all)
  ' "$integrity" >/dev/null || {
    printf 'roundhouse: invalid executor integrity manifest\n' >&2
    exit 65
  }
  codex_version=$(jq -r '.version' "$plugin_root/.codex-plugin/plugin.json")
  claude_version=$(jq -r '.version' "$plugin_root/.claude-plugin/plugin.json")
  integrity_version=$(jq -r '.version' "$integrity")
  integrity_marketplace=$(jq -r '.marketplace' "$integrity")
  [ "$codex_version" = "$integrity_version" ] && [ "$claude_version" = "$integrity_version" ] || {
    printf 'roundhouse: executor manifest versions do not match\n' >&2
    exit 65
  }

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-executor.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  : >"$tmp/files.jsonl"
  jq -r '.files[] | [.path,.sha256] | @tsv' "$integrity" >"$tmp/manifest.tsv"
  # Fast path: the per-file loop below forks ~15 processes per shipped file
  # (owner, mode, hash, record), which made every seal, apply and verify pay
  # seconds of pure process startup. Batch the same three checks into one
  # owner/mode stat and one hash pass. It may only ever ACCEPT: any anomaly at
  # all - a missing or non-regular file, a stat or hash failure, an unexpected
  # owner or mode, a digest mismatch - falls through to the original loop,
  # which re-checks every file in manifest order and reports exactly what it
  # always did.
  if ! executor_files_fast_verify "$tmp/manifest.tsv" "$tmp/files.jsonl"; then
    : >"$tmp/files.jsonl"
    while IFS="$(printf '\t')" read -r relative expected; do
      path=$plugin_root/$relative
      check_private_owned_file "$path" "executor file $relative"
      actual=$(sha256_file "$path")
      [ "$actual" = "$expected" ] || {
        printf 'roundhouse: executor integrity mismatch: %s\n' "$relative" >&2
        exit 65
      }
      jq -cn --arg path "$relative" --arg sha256 "$actual" \
        '{path:$path,sha256:$sha256}' >>"$tmp/files.jsonl"
    done <"$tmp/manifest.tsv"
  fi

  # Hashing what the manifest lists proves nothing about what the manifest
  # OMITS: an unlisted file under scripts/ would ship unhashed and unverified.
  # Enumerate the shipped set (same exclusions update-integrity applies) and
  # fail closed on anything the manifest does not cover.
  (cd "$plugin_root" && find scripts ! -type d -print) |
    grep -Ev "^$integrity_excluded_scripts\$" |
    LC_ALL=C sort >"$tmp/present"
  # A gitignored file under scripts/ (e.g. a local tool's cache) can never be
  # release content: update-integrity's own git-ls-files enumeration never
  # produces one either, so the manifest can never cover it and this check
  # would fail forever on a clean dev checkout. Only applies to a real
  # roundhouse SOURCE checkout - the real installed-plugin case (a version
  # directory in the plugin cache) has no .git to consult and keeps the
  # unfiltered scan, exactly as before.
  #
  # `rev-parse --is-inside-work-tree` alone is NOT enough to tell those two
  # cases apart, and using it alone was a real security regression: if
  # $HOME is itself a git repo (a dotfiles repo - common, and likely across
  # a fleet given roundhouse's own chezmoi tooling) and its .gitignore
  # excludes .claude/ or .codex/, an INSTALLED plugin cache under
  # ~/.claude/plugins/cache/... sits inside that work tree too. check-ignore
  # would then match every scripts/* path in the cache, filtering the
  # `present` list down to nothing and letting an unlisted, unmanifested
  # executable bypass the manifest-coverage check entirely - exactly the
  # case this check exists to catch. Do not go back to the weaker
  # rev-parse-only test.
  #
  # The discriminator: the plugin manifest is a TRACKED file in a real
  # source checkout, and is untracked (or itself ignored) in an installed
  # cache nested under some unrelated repo. A real git failure here (not
  # "no matches") also keeps the unfiltered scan rather than silently
  # narrowing what this check defends.
  #
  # Also require plugin_root to sit at the expected path within that
  # repository (plugins/roundhouse under the repo toplevel) - a repo that
  # deliberately tracks an installed cache's manifest (e.g. a backup repo
  # that commits everything) would otherwise still pass the tracked-file
  # test above. This is defense in depth, not a boundary: someone who can
  # already write into the plugin cache and commit its manifest there can
  # edit integrity.json directly and make this check moot regardless - so
  # this stays a cheap path comparison, not anything cryptographic.
  is_source_checkout=false
  if command -v git >/dev/null 2>&1 &&
    git -C "$plugin_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    git -C "$plugin_root" ls-files --error-unmatch .claude-plugin/plugin.json >/dev/null 2>&1; then
    toplevel=$(git -C "$plugin_root" rev-parse --show-toplevel 2>/dev/null) || toplevel=
    # plugin_root (scripts/roundhouse's `cd -- ... && pwd`, logical - see
    # there) can retain a symlinked path, while `git rev-parse
    # --show-toplevel` always resolves through symlinks to the physical
    # repo root - a straight string-prefix comparison between the two then
    # never matches for a symlinked checkout, and a real source checkout
    # gets misdetected as an installed cache: no gitignore filtering above
    # (a real ignored artifact under scripts/ then fails the manifest-
    # coverage check outright), and source provenance silently omitted
    # below. Canonicalize BOTH sides with this codebase's existing
    # `cd -P && pwd -P` idiom (plan-apply.sh, identity.sh,
    # certify-ssh-node, prepare-ssh-identity already use it) rather than a
    # second resolution mechanism. Fail closed: if either side cannot be
    # resolved, is_source_checkout stays false - the unfiltered scan,
    # never a filtered one built on a guess.
    plugin_root_physical=$( (CDPATH='' cd -P -- "$plugin_root" 2>/dev/null && pwd -P) ) || plugin_root_physical=
    toplevel_physical=
    if [ -n "$toplevel" ]; then
      toplevel_physical=$( (CDPATH='' cd -P -- "$toplevel" 2>/dev/null && pwd -P) ) || toplevel_physical=
    fi
    if [ -n "$plugin_root_physical" ] && [ -n "$toplevel_physical" ]; then
      relative_root=${plugin_root_physical#"$toplevel_physical"/}
      if [ "$relative_root" = "plugins/roundhouse" ]; then
        is_source_checkout=true
      fi
    fi
  fi
  if [ "$is_source_checkout" = true ]; then
    ignore_status=0
    ignored=$( (cd "$plugin_root" && git check-ignore --stdin) <"$tmp/present" 2>/dev/null) ||
      ignore_status=$?
    # 0: at least one path is ignored. 1: git ran fine, none are ignored.
    # Anything higher is a real git error - leave $tmp/present untouched.
    if [ "$ignore_status" -le 1 ] && [ -n "$ignored" ]; then
      comm -23 "$tmp/present" <(printf '%s\n' "$ignored" | LC_ALL=C sort) >"$tmp/present.filtered"
      mv "$tmp/present.filtered" "$tmp/present"
    fi
  fi
  jq -r '.files[].path | select(startswith("scripts/"))' "$integrity" |
    LC_ALL=C sort >"$tmp/listed"
  uncovered=$(comm -23 "$tmp/present" "$tmp/listed")
  [ -z "$uncovered" ] || {
    printf 'roundhouse: executor file is not covered by the integrity manifest: %s\n' \
      "$(printf '%s' "$uncovered" | tr '\n' ' ')" >&2
    exit 65
  }

  source_commit=
  source_tree=
  source_dirty=false
  # Same discriminator as above, reused rather than a second rev-parse-only
  # check - an installed cache nested under an unrelated repo (the dotfiles
  # case above) must not report THAT repo's commit/tree/dirty state as if
  # it were roundhouse's own provenance.
  if [ "$is_source_checkout" = true ]; then
    source_commit=$(git -C "$plugin_root" rev-parse HEAD 2>/dev/null || true)
    source_tree=$(git -C "$plugin_root" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
    [ -z "$(git -C "$plugin_root" status --porcelain --untracked-files=no -- "$plugin_root" 2>/dev/null)" ] ||
      source_dirty=true
  fi
  jq -S -n \
    --arg plugin roundhouse \
    --arg marketplace "$integrity_marketplace" \
    --arg version "$integrity_version" \
    --arg manifest_sha256 "$(sha256_file "$integrity")" \
    --slurpfile files "$tmp/files.jsonl" \
    --arg commit "$source_commit" \
    --arg tree "$source_tree" \
    --argjson dirty "$source_dirty" \
    '{
      schema:"roundhouse.executor",
      schema_version:1,
      plugin:$plugin,
      marketplace:$marketplace,
      version:$version,
      integrity_manifest_sha256:$manifest_sha256,
      files:($files | sort_by(.path)),
      source:{
        commit:(if $commit == "" then null else $commit end),
        tree:(if $tree == "" then null else $tree end),
        dirty:(if $commit == "" then null else $dirty end)
      },
      verified:true
    }' >"$tmp/status.json"
  safe_output "$tmp/status.json" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

verify_executor_requirement() (
  requirement=$1
  require_jq
  [ -f "$requirement" ] && [ ! -L "$requirement" ] || {
    printf 'roundhouse: executor requirement must be a regular non-symlink file\n' >&2
    exit 64
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-executor-verify.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  executor_status_command "$tmp/status.json"
  jq -e -n --slurpfile required "$requirement" --slurpfile actual "$tmp/status.json" '
    ($required[0].required_executor // $required[0]) as $r |
    $actual[0] as $a |
    $r.plugin == $a.plugin and
    $r.marketplace == $a.marketplace and
    $r.version == $a.version and
    $r.integrity_manifest_sha256 == $a.integrity_manifest_sha256 and
    ($r.files | sort_by(.path)) == ($a.files | sort_by(.path))
  ' >/dev/null || {
    printf 'roundhouse: installed executor does not match the sealed requirement\n' >&2
    exit 65
  }
  cat "$tmp/status.json"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
)

sanitize_remote() {
  sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#; s#^[^/@]+@([^:]+:.*)$#\1#; s#[?].*$##'
}

safe_output() {
  source_file=$1
  destination=$2
  if [ "$destination" = - ]; then
    cat "$source_file"
    return
  fi
  [ ! -L "$destination" ] || {
    printf 'roundhouse: refusing symlink output: %s\n' "$destination" >&2
    exit 64
  }
  directory=$(dirname "$destination")
  [ -d "$directory" ] || {
    printf 'roundhouse: output directory does not exist: %s\n' "$directory" >&2
    exit 64
  }
  temporary=$(mktemp "$directory/.roundhouse.XXXXXX")
  (
    trap 'rm -f "$temporary"' EXIT HUP INT TERM
    chmod 600 "$temporary"
    cp "$source_file" "$temporary"
    mv -f "$temporary" "$destination"
    trap - EXIT HUP INT TERM
  )
}

make_error_record_without_jq() {
  printf '%s\n' '{"schema":"roundhouse.inventory","schema_version":1,"snapshot_id":"unavailable","host_id":"unknown","kind":"error","id":"prerequisite:jq","observed_at":null,"status":"unavailable","confidence":"high","data":{},"evidence":[],"errors":[{"code":"jq_missing","severity":"error","retryable":false,"message":"jq is required on the selected POSIX host"}]}'
}
