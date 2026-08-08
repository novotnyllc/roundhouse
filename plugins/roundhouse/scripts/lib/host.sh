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

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    printf 'roundhouse: yq is required; the fleet store is YAML\n' >&2
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

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print tolower($1)}'
  else
    openssl dgst -sha256 | awk '{print tolower($NF)}'
  fi
}

check_safe_owned_directory() {
  check_safe_owned_path "$1" "$2" directory
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
  done <<EOF
$(jq -r '.files[] | [.path,.sha256] | @tsv' "$integrity")
EOF

  # Hashing what the manifest lists proves nothing about what the manifest
  # OMITS: an unlisted file under scripts/ would ship unhashed and unverified.
  # Enumerate the shipped set (same exclusions update-integrity applies) and
  # fail closed on anything the manifest does not cover.
  (cd "$plugin_root" && find scripts ! -type d -print) |
    grep -Ev "^$integrity_excluded_scripts\$" |
    LC_ALL=C sort >"$tmp/present"
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
  if command -v git >/dev/null 2>&1 &&
    git -C "$plugin_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
