# roundhouse — inventory collection, stream validation, rendering, comparison,
# and recorded Codex readiness.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

collect_command() {
  target=
  sections=
  output=-
  native_target=false
  while [ $# -gt 0 ]; do
    case $1 in
      --target) [ $# -ge 2 ] || usage; target=$2; shift 2 ;;
      --native-target) native_target=true; shift ;;
      --section)
        [ $# -ge 2 ] || usage
        case $2 in
          all|host|packages|agents|auth|projects|startup|chezmoi) ;;
          *) printf 'roundhouse: unsupported section: %s\n' "$2" >&2; exit 64 ;;
        esac
        if [ -n "$sections" ]; then sections="$sections,$2"; else sections=$2; fi
        shift 2
        ;;
      --output) [ $# -ge 2 ] || usage; output=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$sections" ] || sections=all

  if ! command -v jq >/dev/null 2>&1; then
    make_error_record_without_jq
    return 2
  fi
  validate_config_file
  config=$(config_path)
  check_private_owned_file "$config" "collection configuration"
  if [ -z "$target" ]; then
    target=$(jq -r '.machines | to_entries[] | select(.value.transport == "local") | .key' "$config" | head -1)
  fi
  if [ -z "$target" ] || ! jq -e --arg host "$target" '.machines[$host] != null' "$config" >/dev/null; then
    printf 'roundhouse: unknown target: %s\n' "${target:-<none>}" >&2
    exit 64
  fi

  transport=$(jq -r --arg host "$target" '.machines[$host].transport' "$config")
  platform=$(jq -r --arg host "$target" '.machines[$host].platform' "$config")
  broker_route=$(jq -r --arg host "$target" \
    '.machines[$host].privilege_broker.automation_transport.mode // empty' "$config")
  if [ "$native_target" = true ]; then
    [ "$transport" = ssh ] || {
      printf 'roundhouse: --native-target requires an SSH-configured host\n' >&2
      exit 64
    }
    expected_hostname=$(jq -r --arg target "$target" '.machines[$target].expected_hostname // empty' "$config")
    expected_user=$(jq -r --arg target "$target" '.machines[$target].expected_user // empty' "$config")
    [ -n "$expected_hostname" ] && [ -n "$expected_user" ] &&
      [ "$(hostname)" = "$expected_hostname" ] && [ "$(id -un)" = "$expected_user" ] || {
      printf 'roundhouse: native target identity does not match configured hostname/user\n' >&2
      exit 65
    }
  fi
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  snapshot_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  config_digest=$(sha256_file "$config")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  records="$tmp/records.jsonl"
  jq -cn \
    --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" \
    --arg observed_at "$observed" --arg config_digest "$config_digest" \
    --arg sections "$sections" \
    '{schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,kind:"snapshot",id:"snapshot",observed_at:$observed_at,status:"present",confidence:"high",data:{configuration_digest:{algorithm:"sha256",value:$config_digest,scope:"raw-bytes"},sections:($sections|split(","))},evidence:[],errors:[]}' \
    >"$records"

  rc=0
  operation_status=completed
  operation_envelope_status=present
  case $transport in
    local)
      ROUNDHOUSE_OBSERVED_AT="$observed" "$script_dir/collect-posix" "$config" "$target" "$snapshot_id" "$sections" >>"$records" || {
        rc=2
        operation_status=partial
        operation_envelope_status=partial
      }
      ;;
    ssh)
      if [ "$native_target" = true ]; then
        ROUNDHOUSE_OBSERVED_AT="$observed" "$script_dir/collect-posix" \
          "$config" "$target" "$snapshot_id" "$sections" >>"$records" || {
            rc=2
            operation_status=partial
            operation_envelope_status=partial
          }
      else
        alias=$(jq -r --arg host "$target" '.machines[$host].ssh_alias // empty' "$config")
        [ -n "$alias" ] || {
          printf 'roundhouse: ssh target %s has no ssh_alias\n' "$target" >&2
          exit 64
        }
        worker_config_command "$target" inventory "$tmp/config.json"
        executor_status_command "$tmp/executor.json"
        remote_dir=$(ssh_run "$alias" \
          'umask 077; mktemp -d /tmp/roundhouse.XXXXXX') || {
            rc=2
            operation_status=partial
            operation_envelope_status=partial
          }
        if [ "$rc" -ne 0 ] || [ -z "${remote_dir:-}" ]; then
          jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
            --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed" \
            '{schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,kind:"error",id:"transport:ssh",observed_at:$observed_at,status:"unavailable",confidence:"high",data:{transport:"ssh"},evidence:[],errors:[{code:"ssh_unreachable",severity:"error",retryable:true,message:"SSH target did not create a remote workspace"}]}' >>"$records"
        else
          printf '%s\n' "$remote_dir" |
            LC_ALL=C grep -Eq '^(/private)?/tmp/roundhouse\.[A-Za-z0-9]{6,64}$' || {
              printf 'roundhouse: unsafe remote temporary path\n' >&2
              exit 70
            }
          if ! scp_run "$tmp/config.json" "$alias:$remote_dir/config.json" ||
            ! scp_run "$tmp/executor.json" "$alias:$remote_dir/executor.json"; then
              rc=2
              operation_status=partial
              operation_envelope_status=partial
          fi
          if [ "$rc" -eq 0 ]; then
            marketplace=$(jq -r '.marketplace' "$tmp/executor.json")
            version=$(jq -r '.version' "$tmp/executor.json")
            if ! ssh_run "$alias" \
              sh -s -- "$remote_dir" "$marketplace" "$version" "$target" "$snapshot_id" "$sections" \
              >>"$records" <<'REMOTE_COLLECTOR'
set -eu
remote_dir=$1
marketplace=$2
version=$3
target=$4
snapshot_id=$5
sections=$6
trap 'rm -rf "$remote_dir"' EXIT HUP INT TERM
codex_cli=$HOME/.codex/plugins/cache/$marketplace/roundhouse/$version/scripts/roundhouse
claude_cli=$HOME/.claude/plugins/cache/$marketplace/roundhouse/$version/scripts/roundhouse
if [ -x "$codex_cli" ]; then cli=$codex_cli
elif [ -x "$claude_cli" ]; then cli=$claude_cli
else
  printf 'roundhouse: exact executor is not installed on target\n' >&2
  exit 69
fi
export ROUNDHOUSE_CONFIG=$remote_dir/config.json
"$cli" verify-executor "$remote_dir/executor.json" >/dev/null
expected_hostname=$(jq -r --arg target "$target" '.machines[$target].expected_hostname // empty' "$remote_dir/config.json")
expected_user=$(jq -r --arg target "$target" '.machines[$target].expected_user // empty' "$remote_dir/config.json")
[ -n "$expected_hostname" ] && [ -n "$expected_user" ] &&
  [ "$(hostname)" = "$expected_hostname" ] && [ "$(id -un)" = "$expected_user" ] || {
    printf 'roundhouse: SSH target identity does not match bounded configuration\n' >&2
    exit 65
  }
collector=$(dirname "$cli")/collect-posix
ROUNDHOUSE_OBSERVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  "$collector" "$remote_dir/config.json" "$target" "$snapshot_id" "$sections"
REMOTE_COLLECTOR
            then
              rc=2
              operation_status=partial
              operation_envelope_status=partial
              jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
                --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed" \
                '{schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,kind:"error",id:"executor:ssh",observed_at:$observed_at,status:"unavailable",confidence:"high",data:{transport:"ssh"},evidence:[],errors:[{code:"executor_update_required",severity:"error",retryable:true,message:"Exact Roundhouse executor is missing, stale, or failed integrity verification"}]}' >>"$records"
            fi
          fi
          ssh_run "$alias" \
            "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || true
        fi
      fi
      ;;
    codex-remote-control)
      error=$(jq -cn '[{code:"codex_task_required",severity:"warning",retryable:true,message:"Use the fleet skill to create a visible task on the saved Codex Desktop project"}]')
      jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
        --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed" \
        --argjson errors "$error" \
        '{schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,kind:"error",id:"transport:codex-remote-control",observed_at:$observed_at,status:"unavailable",confidence:"high",data:{transport:"codex-remote-control"},evidence:[],errors:$errors}' >>"$records"
      rc=2
      operation_status=blocked
      operation_envelope_status=unavailable
      ;;
    *)
      printf 'roundhouse: transport not supported by this command: %s\n' "$transport" >&2
      exit 69
      ;;
  esac

  # Ordinary inventory can use the configured SSH lane, but a protected POSIX
  # readiness record is accepted only after the separate forced dispatcher
  # round-trip. Drop the ordinary-lane projection even when that round-trip
  # fails, so it can never authorize a broker request.
  if { [ "$platform" = linux ] || [ "$platform" = macos ]; } &&
    [ "$transport:$broker_route" = ssh:posix-ssh ]; then
    jq -c 'select(.kind != "privilege_broker" or .id != "readiness")' "$records" \
      >"$tmp/without-posix-readiness.jsonl"
    if posix_dispatch_readiness_records "$target" "$tmp/posix-readiness.jsonl" \
        "$snapshot_id" "$observed"; then
      cat "$tmp/without-posix-readiness.jsonl" "$tmp/posix-readiness.jsonl" >"$tmp/records-with-readiness.jsonl"
      mv "$tmp/records-with-readiness.jsonl" "$records"
    else
      rc=2
      operation_status=partial
      operation_envelope_status=partial
      cat "$tmp/without-posix-readiness.jsonl" >"$records"
      jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
        --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed" \
        '{schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
          kind:"error",id:"transport:posix-ssh",observed_at:$observed_at,status:"unavailable",confidence:"high",
          data:{transport:"posix-ssh"},evidence:[],errors:[{code:"protected_dispatcher_unavailable",severity:"error",retryable:true,message:"Pinned forced POSIX dispatcher did not return a verified readiness projection"}]}' \
        >>"$records"
    fi
  fi

  if [ "$rc" -eq 0 ] &&
    jq -e 'select(.kind != "privilege_broker" and
      (.status == "partial" or .status == "unavailable" or .status == "error"))' "$records" >/dev/null; then
    rc=2
    operation_status=partial
    operation_envelope_status=partial
  fi

  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$snapshot_id" --arg host_id "$target" --arg observed_at "$observed" \
    --arg transport "$transport" --arg sections "$sections" \
    --arg status "$operation_envelope_status" --arg operation_status "$operation_status" \
    '{schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,kind:"operation",id:"collect",observed_at:$observed_at,status:$status,confidence:"high",data:{run_id:$snapshot_id,host_id:$host_id,scope:($sections|split(",")),phase:"collect",operation_status:$operation_status,transport:$transport,task_id:null,correlation_id:null},evidence:[],errors:[]}' \
    >>"$records"

  jq -sc 'sort_by(.host_id,.kind,.id)[]' "$records" >"$tmp/sorted.jsonl"
  validate_file "$tmp/sorted.jsonl"
  safe_output "$tmp/sorted.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
  return "$rc"
}

validate_file() {
  input=$1
  require_jq
  [ -f "$input" ] || { printf 'roundhouse: snapshot not found: %s\n' "$input" >&2; exit 64; }
  LC_ALL=C awk 'length($0) > 65536 { exit 1 }' "$input" || {
    printf 'roundhouse: record exceeds 65536 bytes\n' >&2
    exit 70
  }
  jq -e -s --arg schema "$schema" --argjson version "$schema_version" '
    length > 0 and
    (map(.snapshot_id) | unique | length == 1) and
    ((map([.host_id,.kind,.id] | @json) | unique | length) == length) and
    (map(
      type == "object" and
      .schema == $schema and
      .schema_version == $version and
      (.snapshot_id | type == "string" and length > 0) and
      (.host_id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
      (.kind | type == "string" and length > 0) and
      (.id | type == "string" and length > 0) and
      (.status | IN("present","absent","partial","unavailable","error")) and
      (.confidence | IN("high","medium","low","unknown")) and
      (.data | type == "object") and
      (.evidence | type == "array") and
      (.errors | type == "array") and
      (if .kind == "operation" then
        (.data.run_id | type == "string" and length > 0) and
        (.data.host_id == .host_id) and
        (.data.scope | type == "array") and
        (.data.phase | type == "string" and length > 0) and
        (.data.operation_status | IN("queued","running","partial","blocked","failed","skipped","completed")) and
        (.data.transport | type == "string" and length > 0)
      else true end) and
      ([.. | strings |
        length <= 8192 and (test("[[:cntrl:]]") | not)
      ] | all)
    ) | all)
  ' "$input" >/dev/null
}

materialize_input() {
  requested_input=$1
  input_tmp=
  if [ "$requested_input" = - ]; then
    input_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-input.XXXXXX")
    trap 'rm -f "$input_tmp"' EXIT HUP INT TERM
    cat >"$input_tmp"
    resolved_input=$input_tmp
  else
    resolved_input=$requested_input
  fi
}

cleanup_input() {
  if [ -n "${input_tmp:-}" ]; then
    rm -f "$input_tmp"
    input_tmp=
    trap - EXIT HUP INT TERM
  fi
}

validate_stream() {
  materialize_input "$1"
  validate_file "$resolved_input"
  cleanup_input
}

render_command() {
  format=human
  input=
  while [ $# -gt 0 ]; do
    case $1 in
      --format) [ $# -ge 2 ] || usage; format=$2; shift 2 ;;
      *) [ -z "$input" ] || usage; input=$1; shift ;;
    esac
  done
  input=${input:--}
  materialize_input "$input"
  validate_file "$resolved_input"
  case $format in
    jsonl) cat "$resolved_input" ;;
    json) jq -sc '{schema:"roundhouse.inventory",schema_version:1,snapshot_id:.[0].snapshot_id,records:.}' "$resolved_input" ;;
    human)
      jq -rs '
        (["HOST","KIND","ID","STATUS","SUMMARY"] | @tsv),
        (.[] | [
          .host_id,
          .kind,
          .id,
          .status,
          (if .kind == "agent_setting" and .status != "present" then
             (.errors[0].code // .status)
           elif .kind == "agent_setting" then
             ((.data.observed | tojson) + " -> " + (.data.desired | tojson) +
              (if .data.in_sync then "" else " (drift)" end))
           elif .kind == "auth_artifact" then
             (.data.health // .data.path // "")
           else
             (.data.installed_version // .data.version // .data.path // .data.hostname // .data.manager // "")
           end)
        ] | @tsv)
      ' "$resolved_input"
      ;;
    *) usage ;;
  esac
  cleanup_input
}

compare_command() {
  left=$1
  right=$2
  validate_stream "$left"
  validate_stream "$right"
  jq -n --slurpfile left "$left" --slurpfile right "$right" '
    def stable: select(.kind != "operation") | del(.snapshot_id,.observed_at,.data.codex_checked_at);
    def keyed($rows): reduce ($rows[] | stable) as $r ({}; .[([$r.host_id,$r.kind,$r.id] | @json)] = $r);
    (keyed($left)) as $l | (keyed($right)) as $r |
    (($l|keys) + ($r|keys) | unique) |
    map(select(($l[.] // null) != ($r[.] // null)) | {key:.,left:($l[.]//null),right:($r[.]//null)})
  '
}

record_codex_readiness_command() {
  snapshot=$1
  metadata=$2
  output=$3
  validate_file "$snapshot"
  [ -f "$metadata" ] && [ ! -L "$metadata" ] || {
    printf 'roundhouse: Codex readiness metadata must be a regular non-symlink file\n' >&2
    exit 64
  }
  check_private_owned_file "$metadata" "Codex readiness metadata"
  metadata_mode=$(file_mode "$metadata")
  [ "$(printf '%s' "$metadata_mode" | sed 's/.*\(...\)$/\1/')" = 600 ] || {
    printf 'roundhouse: Codex readiness metadata must have mode 0600\n' >&2
    exit 64
  }
  jq -e '
    type == "object" and
    (.host_id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.project | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.status | IN("available","missing","unreachable")) and
    (.codex_host | type == "string" and length > 0) and
    (.native_path | type == "string" and length > 0) and
    (.expected_source | type == "string" and length > 0) and
    ((.codex_project_id // null) == null or (.codex_project_id | type == "string" and length > 0)) and
    ((.task_id // null) == null or (.task_id | type == "string" and length > 0)) and
    ((.correlation_id // null) == null or (.correlation_id | type == "string" and length > 0)) and
    (if .status == "available" then (.codex_project_id | type == "string" and length > 0) else true end) and
    ([.. | strings |
      length <= 8192 and (test("[[:cntrl:]]") | not)
    ] | all)
  ' "$metadata" >/dev/null || {
    printf 'roundhouse: invalid Codex readiness metadata\n' >&2
    exit 64
  }
  project=$(jq -r '.project' "$metadata")
  jq -e --arg project "$project" 'select(.kind == "project" and .id == $project)' "$snapshot" >/dev/null || {
    printf 'roundhouse: snapshot has no configured project record: %s\n' "$project" >&2
    exit 65
  }
  target=$(jq -r 'select(.kind == "snapshot") | .host_id' "$snapshot")
  config=$(config_path)
  validate_config_file
  check_private_owned_file "$config" "collection configuration"
  snapshot_config_digest=$(jq -r 'select(.kind == "snapshot") | .data.configuration_digest.value' "$snapshot")
  [ "$snapshot_config_digest" = "$(sha256_file "$config")" ] || {
    printf 'roundhouse: snapshot configuration digest does not match the current controller config\n' >&2
    exit 65
  }
  jq -e --arg target "$target" --slurpfile metadata "$metadata" '
    $metadata[0] as $m |
    $m.host_id == $target and
    .machines[$target] != null and
    (.machines[$target].codex_host // $target) == $m.codex_host
  ' "$config" >/dev/null || {
    printf 'roundhouse: Codex readiness metadata does not match configured host/project identity\n' >&2
    exit 65
  }
  configured_source=$(jq -r --arg project "$project" '.projects[$project].source // empty' "$config" | sanitize_remote)
  [ -n "$configured_source" ] && [ "$configured_source" = "$(jq -r '.expected_source' "$metadata")" ] || {
    printf 'roundhouse: Codex readiness metadata does not match configured project source\n' >&2
    exit 65
  }
  jq -e --arg project "$project" --slurpfile metadata "$metadata" '
    $metadata[0] as $m |
    select(.kind == "project" and .id == $project) |
    .data.path == $m.native_path and .data.expected_source == $m.expected_source
  ' "$snapshot" >/dev/null || {
    printf 'roundhouse: Codex readiness metadata does not match the observed native checkout\n' >&2
    exit 65
  }
  checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-codex-readiness.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  jq -cS --slurpfile metadata "$metadata" --arg checked_at "$checked_at" '
    $metadata[0] as $m |
    if .kind == "project" and .id == $m.project then
      .data += {
        codex_saved_project_status:$m.status,
        codex_host:$m.codex_host,
        codex_host_reachable:($m.status != "unreachable"),
        codex_project_id:($m.codex_project_id // null),
        codex_checked_at:$checked_at
      }
    elif .kind == "operation" then
      .data.task_id = ($m.task_id // .data.task_id) |
      .data.correlation_id = ($m.correlation_id // .data.correlation_id)
    else . end
  ' "$snapshot" | jq -sc 'sort_by(.host_id,.kind,.id)[]' >"$tmp/enriched.jsonl"
  validate_file "$tmp/enriched.jsonl"
  safe_output "$tmp/enriched.jsonl" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$tmp"
}
