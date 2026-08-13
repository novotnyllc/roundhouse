# roundhouse — operation execution: path expansion, auth artifacts, chezmoi
# targets, profile authorization, and the per-operation executor.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

expand_user_path() {
  case $1 in
    "~") printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

ensure_project_parent() {
  dev_root=$1
  project_relative=$2
  create_missing=${3:-true}
  [ -d "$dev_root" ] && [ ! -L "$dev_root" ] || {
    printf 'roundhouse: project dev root must be a non-symlink directory\n' >&2
    return 64
  }
  parent_relative=$(dirname -- "$project_relative")
  [ "$parent_relative" != . ] || return 0
  current=$dev_root
  IFS=/ read -r -a components <<<"$parent_relative"
  for component in "${components[@]}"; do
    [ -n "$component" ] && [ "$component" != . ] || continue
    current=${current%/}/$component
    [ ! -L "$current" ] || {
      printf 'roundhouse: refusing symlinked project parent: %s\n' "$current" >&2
      return 64
    }
    if [ -e "$current" ]; then
      [ -d "$current" ] || {
        printf 'roundhouse: project parent is not a directory: %s\n' "$current" >&2
        return 64
      }
    else
      [ "$create_missing" = true ] || {
        printf 'roundhouse: project parent does not exist: %s\n' "$current" >&2
        return 64
      }
      mkdir -- "$current" || return
    fi
  done
}

install_auth_artifact() (
  operation=$1
  config=$2
  target=$3
  id=$(jq -r '.id' "$operation")
  secret_ref=$(jq -r --arg id "$id" '.auth_artifacts[$id].secret_ref // empty' "$config")
  destination=$(jq -r --arg id "$id" --arg target "$target" \
    '.auth_artifacts[$id].paths[$target] // .auth_artifacts[$id].path // empty' "$config")
  destination=$(expand_user_path "$destination")
  mode=$(jq -r --arg id "$id" '.auth_artifacts[$id].mode // "0600"' "$config")
  max_bytes=$(jq -r --arg id "$id" '.auth_artifacts[$id].max_bytes // 10485760' "$config")
  jq -e --arg id "$id" --arg secret_ref "$secret_ref" --slurpfile operation "$operation" '
    .auth_artifacts[$id].strategy == "encrypted-install" and
    $secret_ref != "" and
    $operation[0].argv == ["op","read",$secret_ref]
  ' "$config" >/dev/null || {
    printf 'roundhouse: encrypted auth install does not match configured 1Password reference\n' >&2
    return 64
  }
  case $mode in
    600|0600) ;;
    *)
      printf 'roundhouse: encrypted auth install requires mode 0600\n' >&2
      return 64
      ;;
  esac
  command -v op >/dev/null 2>&1 || {
    printf 'roundhouse: 1Password CLI is unavailable\n' >&2
    return 69
  }
  parent=$(dirname -- "$destination")
  [ -d "$parent" ] && [ ! -L "$parent" ] || {
    printf 'roundhouse: auth destination parent is not a regular directory\n' >&2
    return 64
  }
  [ "$(file_owner "$parent")" = "$(id -un)" ] || {
    printf 'roundhouse: auth destination parent is not owned by the current user\n' >&2
    return 64
  }
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    check_private_owned_file "$destination" "existing auth destination"
  fi

  temporary=$(mktemp "$parent/.roundhouse-auth.XXXXXX")
  backup=
  installed=0
  # shellcheck disable=SC2329 # invoked by EXIT and signal traps
  cleanup_auth_install() {
    [ -z "$temporary" ] || rm -f "$temporary"
    temporary=
    if [ "$installed" -eq 1 ]; then
      if [ -n "$backup" ]; then
        if mv -f "$backup" "$destination"; then
          backup=
          installed=0
        else
          printf 'roundhouse: failed to restore prior auth artifact; backup retained at %s\n' "$backup" >&2
        fi
      else
        rm -f "$destination"
        installed=0
      fi
    elif [ -n "$backup" ]; then
      rm -f "$backup"
      backup=
    fi
  }
  trap cleanup_auth_install EXIT
  trap 'cleanup_auth_install; exit 70' HUP INT TERM
  chmod 600 "$temporary"
  if ! op read "$secret_ref" >"$temporary"; then
    printf 'roundhouse: secret retrieval failed\n' >&2
    return 70
  fi
  size=$(wc -c <"$temporary" | tr -d ' ')
  [ "$size" -gt 0 ] && [ "$size" -le "$max_bytes" ] || {
    printf 'roundhouse: retrieved auth artifact has an invalid size\n' >&2
    return 70
  }
  chmod "$mode" "$temporary"
  if [ -f "$destination" ]; then
    backup=$(mktemp "$parent/.roundhouse-auth-backup.XXXXXX")
    chmod 600 "$backup"
    cp -p "$destination" "$backup"
  fi
  mv -f "$temporary" "$destination"
  temporary=
  installed=1

  verify_count=$(jq -r --arg id "$id" '.auth_artifacts[$id].verify // [] | length' "$config")
  [ "$verify_count" -gt 0 ] || {
    printf 'roundhouse: encrypted auth install requires native verification\n' >&2
    return 64
  }
  set --
  while IFS= read -r argument; do
    set -- "$@" "$argument"
  done <<EOF
$(jq -r --arg id "$id" '.auth_artifacts[$id].verify[]' "$config")
EOF
  if ! "$@" >/dev/null 2>&1; then
    printf 'roundhouse: auth verification failed; restoring prior state\n' >&2
    return 70
  fi
  installed=0
  [ -z "$backup" ] || rm -f "$backup"
  backup=
  trap - EXIT HUP INT TERM
)

validate_chezmoi_targets() {
  [ "$#" -gt 0 ] && [ "$#" -le 16 ] || {
    printf 'roundhouse: chezmoi target list must contain 1-16 paths\n' >&2
    return 64
  }
  target_home=$(cd -- "$HOME" && pwd -P) || {
    printf 'roundhouse: current home directory is unavailable\n' >&2
    return 65
  }
  targets_json=$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')
  printf '%s\n' "$targets_json" | jq -e '
    type == "array" and length > 0 and length <= 16 and
    (unique | length) == length and
    ([.[] | type == "string" and length > 0 and length <= 512 and
      startswith("/") and (contains("\\") | not) and
      (test("(^|/)\\.\\.?($|/)") | not)] | all)
  ' >/dev/null || {
    printf 'roundhouse: unsafe chezmoi target path\n' >&2
    return 64
  }
  for target_path in "$@"; do
    [ ! -L "$target_path" ] || {
      printf 'roundhouse: chezmoi target is a symbolic link\n' >&2
      return 64
    }
    target_parent=$(dirname -- "$target_path")
    target_parent=$(cd -P -- "$target_parent" && pwd) || {
      printf 'roundhouse: chezmoi target parent is unavailable\n' >&2
      return 64
    }
    target_physical=$target_parent/$(basename -- "$target_path")
    case $target_physical in
      "$target_home"/*) ;;
      *)
        printf 'roundhouse: chezmoi target escapes the current home directory\n' >&2
        return 64
        ;;
    esac
  done
}

check_chezmoi_targets() {
  expected=$1
  shift
  validate_chezmoi_targets "$@" || return
  status=$(mktemp "${TMPDIR:-/tmp}/roundhouse-chezmoi-status.XXXXXX")
  if ! chezmoi status -- "$@" >"$status"; then
    rm -f "$status"
    printf 'roundhouse: chezmoi target status failed\n' >&2
    return 70
  fi
  case $expected in
    drifted) if [ -s "$status" ]; then result=0; else result=1; fi ;;
    clean) if [ ! -s "$status" ]; then result=0; else result=1; fi ;;
    *) rm -f "$status"; return 64 ;;
  esac
  rm -f "$status"
  [ "$result" -eq 0 ] || {
    printf 'roundhouse: chezmoi targets are not %s\n' "$expected" >&2
    return 65
  }
}

check_chezmoi_target_postconditions() {
  plan=$1
  index=0
  operation_count=$(jq '.operations | length' "$plan")
  while [ "$index" -lt "$operation_count" ]; do
    jq ".operations[$index]" "$plan" >"$work/operation.json"
    if jq -e '.type == "chezmoi-apply" and has("targets")' "$work/operation.json" >/dev/null; then
      targets=()
      while IFS= read -r target_path; do
        targets+=("$target_path")
      done < <(jq -r '.targets[]' "$work/operation.json")
      check_chezmoi_targets clean "${targets[@]}" || {
        failed_index=$index
        return 1
      }
    fi
    index=$((index + 1))
  done
}

execute_plan_operation() {
  operation=$1
  config=$2
  target=$3
  type=$(jq -r '.type' "$operation")
  kind=$(jq -r '.kind' "$operation")
  id=$(jq -r '.id' "$operation")
  set --
  while IFS= read -r argument; do
    set -- "$@" "$argument"
  done <<EOF
$(jq -r '.argv[]' "$operation")
EOF
  [ $# -gt 0 ] || return 64
  case $type in
    package-metadata-refresh|package-upgrade|package-cleanup)
      for argument in "$@"; do
        case ${argument##*/} in
          sudo|apt-get)
            printf 'roundhouse: direct APT or sudo execution is forbidden; use a sealed broker action\n' >&2
            return 69
            ;;
        esac
      done
      ;;
  esac

  case $type in
    package-metadata-refresh)
      if ! { [ $# -eq 2 ] && [ "$1" = brew ] && [ "$2" = update ]; }; then
        printf 'roundhouse: unsafe package metadata argv\n' >&2
        return 64
      fi
      ;;
    package-upgrade)
      package_name=${id#*:}
      candidate=$(jq -r '.candidate_version' "$operation")
      case $id in
        homebrew:*|linuxbrew:*)
          if ! { [ $# -eq 5 ] && [ "$1" = env ] &&
            [ "$2" = HOMEBREW_NO_AUTO_UPDATE=1 ] && [ "$3" = brew ] &&
            [ "$4" = upgrade ] && [ "$5" = "$package_name" ]; }; then
            printf 'roundhouse: unsafe Homebrew upgrade argv\n' >&2
            return 64
          fi
          ;;
        homebrew-cask:*|linuxbrew-cask:*)
          if ! { [ $# -eq 6 ] && [ "$1" = env ] &&
            [ "$2" = HOMEBREW_NO_AUTO_UPDATE=1 ] && [ "$3" = brew ] &&
            [ "$4" = upgrade ] && [ "$5" = --cask ] &&
            [ "$6" = "$package_name" ]; }; then
            printf 'roundhouse: unsafe Homebrew cask upgrade argv\n' >&2
            return 64
          fi
          if [ "${id%%:*}" = homebrew-cask ]; then
            homebrew_app_broker=/usr/local/libexec/roundhouse/posix-broker
            if [ -x "$homebrew_app_broker" ]; then
              if homebrew_prepare_output=$(/usr/bin/sudo -n -- "$homebrew_app_broker" \
                  --homebrew-bridge-v1 prepare-app "$package_name" 2>&1); then
                :
              else
                homebrew_prepare_status=$?
                case $homebrew_prepare_output in
                  'roundhouse: unsupported_homebrew_cask_privilege_boundary: app_target_not_enrolled'|\
                  'roundhouse: unsupported_homebrew_cask_privilege_boundary: action_not_enabled'|sudo:*) ;;
                  *)
                    printf '%s\n' "$homebrew_prepare_output" >&2
                    return "$homebrew_prepare_status"
                    ;;
                esac
              fi
            fi
            homebrew_bridge_hook=$plugin_root/scripts/homebrew-bridge.rb
            [ -f "$homebrew_bridge_hook" ] && [ ! -L "$homebrew_bridge_hook" ] || {
              printf 'roundhouse: Homebrew cask privilege bridge hook is unavailable\n' >&2
              return 69
            }
            homebrew_repository=$(brew --repository 2>/dev/null) || {
              printf 'roundhouse: Homebrew repository is unavailable\n' >&2
              return 69
            }
            case $homebrew_repository in /*) ;; *) return 69 ;; esac
            homebrew_entrypoint=$homebrew_repository/Library/Homebrew/brew.rb
            [ -f "$homebrew_entrypoint" ] && [ ! -L "$homebrew_entrypoint" ] || {
              printf 'roundhouse: Homebrew Ruby entrypoint is unavailable\n' >&2
              return 69
            }
            set -- env HOMEBREW_NO_AUTO_UPDATE=1 brew ruby "-r$homebrew_bridge_hook" \
              "$homebrew_entrypoint" -- upgrade --cask "$package_name"
          fi
          ;;
        apt:*)
          printf 'roundhouse: direct APT execution is forbidden; use a sealed broker action\n' >&2
          return 69
          ;;
        *)
          printf 'roundhouse: package manager requires target-native apply\n' >&2
          return 64
          ;;
      esac
      ;;
    package-cleanup)
      if ! { [ $# -eq 2 ] && [ "$1" = brew ] && [ "$2" = cleanup ]; }; then
        printf 'roundhouse: unsafe package cleanup argv\n' >&2
        return 64
      fi
      ;;
    agent-update)
      case $id in
        codex|claude)
          { [ "$kind" = agent_runtime ] && [ $# -eq 2 ] &&
            [ "$1" = "$id" ] && [ "$2" = update ]; } || {
            printf 'roundhouse: unsafe agent runtime update argv\n' >&2
            return 64
          }
          ;;
        skills-cli:*)
          agent_name=${id#skills-cli:}
          case $agent_name in
            ''|-*|*[!A-Za-z0-9@._/-]*)
              printf 'roundhouse: unsafe skills-cli entity name\n' >&2
              return 64
              ;;
          esac
          { [ $# -eq 6 ] && [ "$1" = npx ] && [ "$2" = skills ] &&
            [ "$3" = update ] && [ "$4" = "$agent_name" ] &&
            [ "$5" = -g ] && [ "$6" = -y ]; } || {
            printf 'roundhouse: unsafe skills-cli update argv\n' >&2
            return 64
          }
          ;;
        jsm:*)
          agent_name=${id#jsm:}
          case $agent_name in
            ''|-*|*[!A-Za-z0-9._/-]*)
              printf 'roundhouse: unsafe JSM entity name\n' >&2
              return 64
              ;;
          esac
          { [ $# -eq 3 ] && [ "$1" = jsm ] && [ "$2" = upgrade ] &&
            [ "$3" = "$agent_name" ]; } || {
            printf 'roundhouse: unsafe JSM update argv\n' >&2
            return 64
          }
          ;;
        codex:*)
          printf '%s\n' "$id" |
            jq -eR 'test("^codex:[A-Za-z0-9._-]+:[A-Za-z0-9._-]+:[^:]+$")' >/dev/null || {
              printf 'roundhouse: unsafe Codex plugin ID\n' >&2
              return 64
            }
          plugin_tail=${id#codex:}
          marketplace=${plugin_tail%%:*}
          plugin_tail=${plugin_tail#*:}
          plugin_name=${plugin_tail%%:*}
          plugin_id=$plugin_name@$marketplace
          { [ $# -eq 5 ] && [ "$1" = codex ] && [ "$2" = plugin ] &&
            [ "$3" = add ] && [ "$4" = "$plugin_id" ] &&
            [ "$5" = --json ]; } || {
            printf 'roundhouse: unsafe Codex plugin update argv\n' >&2
            return 64
          }
          plan_node=$(fleet_node_path) || {
            printf 'roundhouse: Node.js is required for Codex plugin hook refresh\n' >&2
            return 69
          }
          "$plan_node" "$script_dir/codex-plugin-hooks.mjs" update "$plugin_id" >/dev/null
          return
          ;;
        claude:*)
          plugin_tail=${id#claude:}
          marketplace=${plugin_tail%%:*}
          plugin_tail=${plugin_tail#*:}
          plugin_name=${plugin_tail%%:*}
          plugin_id=$plugin_name@$marketplace
          { [ $# -eq 6 ] && [ "$1" = claude ] && [ "$2" = plugin ] &&
            [ "$3" = update ] && [ "$4" = "$plugin_id" ] &&
            [ "$5" = --scope ] && [ "$6" = user ]; } || {
            printf 'roundhouse: unsafe Claude plugin update argv\n' >&2
            return 64
          }
          ;;
        *)
          printf 'roundhouse: this agent manager has no safe native update command\n' >&2
          return 69
          ;;
      esac
      ;;
    auth-reauth)
      jq -e --arg id "$id" --slurpfile operation "$operation" '
        .auth_artifacts[$id] != null and
        (.auth_artifacts[$id].strategy == "reauth") and
        (.auth_artifacts[$id].reauth == $operation[0].argv)
      ' "$config" >/dev/null || {
        printf 'roundhouse: auth reauthentication argv is not configured\n' >&2
        return 64
      }
      ;;
    auth-install)
      install_auth_artifact "$operation" "$config" "$target"
      return
      ;;
    chezmoi-pull)
      { [ $# -eq 5 ] && [ "$1" = chezmoi ] && [ "$2" = git ] &&
        [ "$3" = -- ] && [ "$4" = pull ] && [ "$5" = --ff-only ]; } || {
        printf 'roundhouse: unsafe chezmoi pull argv\n' >&2
        return 64
      }
      ;;
    chezmoi-apply)
      if jq -e 'has("targets")' "$operation" >/dev/null; then
        { [ $# -ge 5 ] && [ "$1" = chezmoi ] && [ "$2" = --no-tty ] &&
          [ "$3" = apply ] && [ "$4" = -- ]; } || {
          printf 'roundhouse: unsafe targeted chezmoi apply argv\n' >&2
          return 64
        }
        shift 4
        validate_chezmoi_targets "$@" || return
        jq -e --args '.targets == $ARGS.positional' -- "$@" <"$operation" >/dev/null || {
          printf 'roundhouse: targeted chezmoi argv does not match the sealed targets\n' >&2
          return 64
        }
        check_chezmoi_targets drifted "$@" || return
        set -- chezmoi --no-tty apply -- "$@"
      else
        { [ $# -eq 3 ] && [ "$1" = chezmoi ] && [ "$2" = --no-tty ] &&
          [ "$3" = apply ]; } || {
          printf 'roundhouse: unsafe chezmoi apply argv\n' >&2
          return 64
        }
      fi
      ;;
    project-clone|project-update)
      project_source=$(jq -r --arg id "$id" '.projects[$id].source // empty' "$config")
      clone_source=$(printf '%s\n' "$project_source" | jq -Rr '
        if test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") then
          "https://github.com/" + . + ".git"
        else .
        end')
      project_relative=$(jq -r --arg id "$id" '.projects[$id].path // empty' "$config")
      dev_root=$(expand_user_path "$(jq -r --arg target "$target" '.machines[$target].dev_root // empty' "$config")")
      project_path=$dev_root/$project_relative
      if [ "$type" = project-clone ]; then
        { [ $# -eq 5 ] && [ "$1" = git ] && [ "$2" = clone ] &&
          [ "$3" = -- ] && [ "$4" = "$clone_source" ] &&
          [ "$5" = "$project_path" ]; } || {
          printf 'roundhouse: project clone argv does not match configured source/path\n' >&2
          return 64
        }
        ensure_project_parent "$dev_root" "$project_relative" || return
      else
        { [ $# -eq 5 ] && [ "$1" = git ] && [ "$2" = -C ] &&
          [ "$3" = "$project_path" ] && [ "$4" = pull ] &&
          [ "$5" = --ff-only ]; } || {
          printf 'roundhouse: project update argv does not match configured path\n' >&2
          return 64
        }
        ensure_project_parent "$dev_root" "$project_relative" false || return
        [ -d "$project_path" ] && [ ! -L "$project_path" ] || {
          printf 'roundhouse: project checkout must be a non-symlink directory\n' >&2
          return 64
        }
      fi
      ;;
    *)
      printf 'roundhouse: unsupported apply operation: %s\n' "$type" >&2
      return 64
      ;;
  esac

  "$@"
}

read_u64_be_file() {
  file=$1
  offset=$2
  od -An -t u1 -j "$offset" -N 8 "$file" | awk '
    { for (i=1; i<=NF; i++) { value=(value * 256) + $i; count++ } }
    END { if (count != 8 || value > 1077936128) exit 1; printf "%.0f\n", value }
  '
}

profile_authorization_from_snapshot() {
  snapshot=$1
  operation=$2
  output=$3
  trusted_projection=${4:-false}
  validate_file "$snapshot"
  jq -e -s --argjson trusted_projection "$trusted_projection" --slurpfile operation "$operation" '
    def exact($expected): (keys | sort) == ($expected | sort);
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def profile_constraint:
      type == "object" and
      (if $trusted_projection then exact(["delete_mode","entry_map_digest","marketplace_set_digest",
        "max_bytes","max_entries","observed_precondition_sha256","policy_token","profile_root_id","target_sid"])
       else exact(["delete_mode","entry_map_digest","marketplace_set_digest",
        "max_bytes","max_entries","policy_token","profile_root_id","target_sid"]) end) and
      (.policy_token | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
      (.target_sid | type == "string" and test("^S-[0-9]+(?:-[0-9]+){1,14}$")) and
      (.profile_root_id | digest) and (.entry_map_digest | digest) and
      (.marketplace_set_digest | digest) and
      (if $trusted_projection then (.observed_precondition_sha256 | digest) else true end) and
      (.delete_mode | IN("managed-only","managed-and-prune")) and
      (.max_entries | type == "number" and floor == . and . >= 1 and . <= 100000) and
      (.max_bytes | type == "number" and floor == . and . >= 1 and . <= 1073741824);
    $operation[0] as $operation |
    [.[] | select(.kind == "privilege_broker" and .id == "readiness" and
      .status == "present" and .data.lifecycle_status == "ready")] as $readiness |
    ($readiness | length) == 1 and
    ($readiness[0].data as $r |
      $r.observed_policy_digest == $operation.privilege.policy.digest and
      $r.observed_constraints_digest == $operation.privilege.policy.constraints_digest and
      $r.constraint_generation == $operation.privilege.policy.constraint_generation and
      $r.enrollment_epoch == $operation.privilege.enrollment.epoch and
      $r.protected_identity.sid == $operation.privilege.request.request_sid and
      ([ $r.observed_action_contexts[] | select(
        .action_id == $operation.id and .context_id == "windows-user-s4u-v1" and
        .constraint_kind == "profile-bundle-set-sha256" and
        (if $trusted_projection then .constraint_digest == null
         else .constraint_digest == $operation.privilege.policy.constraint_digest end) and
        .constraint_generation == $operation.privilege.policy.constraint_generation)
      ] as $contexts |
      ($contexts | length) == 1 and
      ($contexts[0] as $context |
        ($context.profile_constraints | type == "array" and length >= 1 and length <= 100000 and
          all(.[]; profile_constraint) and
          (map(.policy_token) | unique | length) == length) and
        ($context.policy_tokens | type == "array" and
          all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
          unique == . and
          (sort == ($context.profile_constraints | map(.policy_token) | sort))) and
        ([ $context.profile_constraints[] | select(
          .policy_token == $operation.privilege.action.policy_token and
          .target_sid != $operation.privilege.request.request_sid and
          .entry_map_digest == $operation.privilege.context.manager_source_identity and
          (if $trusted_projection then
             .observed_precondition_sha256 == first($r.observed_preconditions[] | select(
               .action_id == $operation.id and
               .policy_token == $operation.privilege.action.policy_token)).digest.value
           else true end))
        ] | length) == 1)))
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: active profile authorization does not match the sealed request\n' >&2
    return 65
  }
  jq -e -s --argjson trusted_projection "$trusted_projection" --slurpfile operation "$operation" '
    def exact($expected): (keys | sort) == ($expected | sort);
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def profile_constraint:
      type == "object" and
      (if $trusted_projection then exact(["delete_mode","entry_map_digest","marketplace_set_digest",
        "max_bytes","max_entries","observed_precondition_sha256","policy_token","profile_root_id","target_sid"])
       else exact(["delete_mode","entry_map_digest","marketplace_set_digest",
        "max_bytes","max_entries","policy_token","profile_root_id","target_sid"]) end) and
      (.profile_root_id | digest) and (.entry_map_digest | digest) and
      (.marketplace_set_digest | digest) and
      (if $trusted_projection then (.observed_precondition_sha256 | digest) else true end);
    $operation[0] as $operation |
    first(.[] | select(.kind == "privilege_broker" and .id == "readiness")).data as $r |
    first($r.observed_action_contexts[] | select(
      .action_id == $operation.id and .context_id == "windows-user-s4u-v1") |
      .profile_constraints[] | select(profile_constraint and
      .policy_token == $operation.privilege.action.policy_token and
      .target_sid != $operation.privilege.request.request_sid and
      .entry_map_digest == $operation.privilege.context.manager_source_identity)) |
    if $trusted_projection then del(.observed_precondition_sha256) else . end
  ' "$snapshot" >"$output"
}

validate_profile_bundle_for_operation() (
  bundle=$1
  operation=$2
  authorization=$3
  manifest_length=$(read_u64_be_file "$bundle" 0) || exit 64
  payload_length=$(read_u64_be_file "$bundle" 8) || exit 64
  total_length=$(wc -c <"$bundle" | tr -d ' ')
  [ "$manifest_length" -ge 1 ] && [ "$manifest_length" -le 4194304 ] &&
    [ "$payload_length" -le 1073741824 ] &&
    [ $((16 + manifest_length + payload_length)) -eq "$total_length" ] || exit 64
  assert_windows_broker_payload_length "$total_length" || exit $?
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-profile-verify.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  dd if="$bundle" of="$tmp/manifest" bs=1 skip=16 count="$manifest_length" 2>/dev/null
  dd if="$bundle" of="$tmp/payload" bs=1 skip=$((16 + manifest_length)) \
    count="$payload_length" 2>/dev/null
  expected_request=$(jq -r '.privilege.request.id' "$operation")
  expected_action=$(jq -r '.id' "$operation")
  expected_token=$(jq -r '.privilege.action.policy_token' "$operation")
  expected_sid=$(jq -r '.target_sid' "$authorization")
  expected_root=$(jq -r '.profile_root_id' "$authorization")
  expected_entry_map=$(jq -r '.entry_map_digest' "$authorization")
  expected_manager=$(jq -r '.privilege.context.manager_source_identity' "$operation")
  max_entries=$(jq -r '.max_entries' "$authorization")
  max_bytes=$(jq -r '.max_bytes' "$authorization")
  [ "$expected_entry_map" = "$expected_manager" ] &&
    [ "$total_length" -le "$max_bytes" ] || exit 64
  expected_payload_digest=$(sha256_file "$tmp/payload")
  LC_ALL=C awk -F '|' -v request="$expected_request" -v action="$expected_action" \
    -v token="$expected_token" -v sid="$expected_sid" -v root="$expected_root" \
    -v max_entries="$max_entries" -v payload_length="$payload_length" \
    -v payload_digest="$expected_payload_digest" '
    function digest(value) { return value ~ /^[0-9a-f]{64}$/ }
    function uint(value) { return value ~ /^(0|[1-9][0-9]*)$/ }
    $0 !~ /^[ -~]*$/ || length($0) > 8192 { exit 1 }
    NR == 1 { if ($0 != "profile-bundle|1") exit 1; next }
    NR == 2 { if ($1 != "request-id" || $2 != request) exit 1; next }
    NR == 3 { if ($1 != "action-id" || $2 != action) exit 1; next }
    NR == 4 { if ($1 != "policy-token" || $2 != token) exit 1; next }
    NR == 5 { if ($1 != "target-sid" || $2 != sid) exit 1; next }
    NR == 6 { if ($1 != "profile-root-id" || $2 != root) exit 1; next }
    NR == 7 { if ($1 != "entry-count" || !uint($2) || ($2 + 0) > max_entries) exit 1; entries=$2; next }
    NR == 8 { if ($1 != "payload-length" || $2 != payload_length) exit 1; next }
    NR == 9 { if ($1 != "payload-sha256" || $2 != payload_digest) exit 1; next }
    NR >= 10 && NR < 10 + entries {
      if ($1 != "entry" || NF != 14 || $2 != (NR - 10) ||
          (previous != "" && previous >= $3) ||
          $8 !~ /^(delete|observe|write)$/ || !uint($9) || !uint($10) || !digest($11) ||
          $12 !~ /^(present|absent)$/ ||
          ($12 == "present" && (!digest($13) || $14 == "-")) ||
          ($12 == "absent" && ($13 != "-" || $14 != "-")) ||
          (($8 == "delete" || $8 == "observe") && ($10 != 0 || $11 != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")) ||
          ($9 + 0) != next_offset || ($9 + $10) > payload_length) exit 1
      previous=$3; next_offset += ($10 + 0)
      next
    }
    NR == 10 + entries { if ($0 != "end-bundle|") exit 1; ended=1; next }
    { exit 1 }
    END { exit !(ended && NR == 10 + entries && next_offset == payload_length) }
  ' "$tmp/manifest" || exit 64
  index=0
  sed -n '10,$p' "$tmp/manifest" | while IFS='|' read -r kind entry_index path handler artifact manager \
      logical_identity operation offset length content_digest expected_presence expected_digest entry_expected_manager; do
    [ "$kind" = entry ] || break
    contract=$(profile_destination_contract "$path" "$handler") || exit 64
    tab=$(printf '\t')
    IFS="$tab" read -r compiled_artifact compiled_manager compiled_identity <<EOF
$contract
EOF
    [ "$entry_index" -eq "$index" ] && [ "$artifact" = "$compiled_artifact" ] &&
      [ "$manager" = "$compiled_manager" ] && [ "$logical_identity" = "$compiled_identity" ] || exit 64
    if [ "$expected_presence" = present ]; then
      [ "$entry_expected_manager" = "$compiled_manager" ] || exit 64
    fi
    dd if="$tmp/payload" of="$tmp/entry-$index" bs=1 skip="$offset" count="$length" 2>/dev/null
    [ "$(sha256_file "$tmp/entry-$index")" = "$content_digest" ] || exit 64
    if [ "$operation" = write ]; then
      validate_profile_handler_content "$handler" "$manager" "$tmp/entry-$index" || exit 64
    fi
    index=$((index + 1))
  done
)
