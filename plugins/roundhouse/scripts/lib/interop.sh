# roundhouse — the WSL interop lane to native Windows: transport resolution,
# the bounded request, the launch through the WSL sibling, and the result
# envelope.
#
# A `platform: windows` machine whose `wsl_interop_via` names a configured
# `platform: wsl` + `transport: ssh` sibling is reachable over this lane. The
# controller SSHes to the sibling, changes to the Windows drive, and starts
# full-path PowerShell 7 with a fixed `-EncodedCommand` bootstrap. Everything
# else travels on standard input: the integrity-verified
# `scripts/interop-windows.ps1` launcher and one bounded request. The Windows
# process runs natively as the logged-in user, so its records are native
# evidence; the WSL side only launches it and never produces evidence.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

interop_result_marker='roundhouse-interop-result '

# The fixed bootstrap passed as -EncodedCommand. It only reads standard input
# and runs the launcher bytes it carries; it never takes arguments, so nothing
# crosses the ssh -> login shell -> Windows command-line quoting chain except
# this constant.
interop_bootstrap_text() {
  printf '%s' '$ErrorActionPreference="Stop";$i=[IO.MemoryStream]::new();[Console]::OpenStandardInput().CopyTo($i);$j=[Text.Encoding]::UTF8.GetString($i.ToArray())|ConvertFrom-Json;& ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$j.driver)))) -Request $j.request'
}

interop_bootstrap_encoded() {
  interop_bootstrap_text | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
}

# wsl_interop_alias CONFIG TARGET -> the SSH alias of TARGET's interop sibling.
# Fails (status 1, no output) when TARGET is not reachable over the lane.
wsl_interop_alias() {
  jq -er --arg target "$2" '
    .machines[$target] as $machine |
    ($machine.wsl_interop_via // null) as $via |
    select($machine.platform == "windows" and ($via | type == "string")) |
    .machines[$via] as $sibling |
    select($sibling != null and $sibling.platform == "wsl" and $sibling.transport == "ssh" and
      ($sibling.ssh_alias | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))) |
    $sibling.ssh_alias
  ' "$1" 2>/dev/null
}

# The Windows-side PowerShell 7 and drive root, as seen from WSL. Only the
# self-check may relocate them; a stray variable on a real controller is inert.
interop_pwsh_path() {
  if fleet_test_hook "${ROUNDHOUSE_INTEROP_PWSH:-}"; then
    printf '%s\n' "$ROUNDHOUSE_INTEROP_PWSH"
  else
    printf '%s\n' '/mnt/c/Program Files/PowerShell/7/pwsh.exe'
  fi
}

interop_drive_root() {
  if fleet_test_hook "${ROUNDHOUSE_INTEROP_ROOT:-}"; then
    printf '%s\n' "$ROUNDHOUSE_INTEROP_ROOT"
  else
    printf '%s\n' /mnt/c
  fi
}

# interop_executor_requirement OUTPUT: the controller's executor requirement,
# built from its own verified integrity manifest exactly as the Windows CI job
# builds it. executor_status_command fails closed unless every shipped file,
# including the launcher, matches that manifest.
interop_executor_requirement() (
  output=$1
  requirement_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-interop-executor.XXXXXX")
  trap 'rm -rf "$requirement_tmp"' EXIT HUP INT TERM
  executor_status_command "$requirement_tmp/status.json"
  jq -S '{schema,schema_version,plugin,marketplace,version,integrity_manifest_sha256,files}' \
    "$requirement_tmp/status.json" >"$requirement_tmp/requirement.json"
  safe_output "$requirement_tmp/requirement.json" "$output"
  trap - EXIT HUP INT TERM
  rm -rf "$requirement_tmp"
)

interop_base64_file() {
  base64 <"$1" | tr -d '\n'
}

# interop_build_input WORK MODE HOST CONTROLLER-DIGEST EXTRA-JSON OUTPUT
# WORK holds config.json, executor.json and, for apply, plan.json. EXTRA-JSON
# carries the mode-specific request fields. The launcher re-checks every
# field and every file digest before it stages anything.
interop_build_input() {
  build_work=$1
  build_mode=$2
  build_host=$3
  build_digest=$4
  build_extra=$5
  build_output=$6
  interop_base64_file "$script_dir/interop-windows.ps1" >"$build_work/driver.b64"
  set -- config executor
  [ "$build_mode" != apply ] || set -- "$@" plan
  printf '{}\n' >"$build_work/files.json"
  for build_name in "$@"; do
    interop_base64_file "$build_work/$build_name.json" >"$build_work/$build_name.b64"
    jq -c --arg name "$build_name" --arg sha256 "$(sha256_file "$build_work/$build_name.json")" \
      --rawfile base64 "$build_work/$build_name.b64" \
      '.[$name] = {sha256:$sha256,base64:$base64}' "$build_work/files.json" >"$build_work/files.next"
    mv "$build_work/files.next" "$build_work/files.json"
  done
  jq -c -n --rawfile driver "$build_work/driver.b64" --slurpfile files "$build_work/files.json" \
    --arg mode "$build_mode" --arg host "$build_host" --arg digest "$build_digest" \
    --argjson extra "$build_extra" '
    {driver:$driver,
     request:({schema:"roundhouse.interop-request",schema_version:1,mode:$mode,host_id:$host,
       controller_configuration_digest:$digest,files:$files[0]} + $extra)}
  ' >"$build_output"
}

# interop_invoke ALIAS INPUT OUTPUT: launch the bootstrap through the WSL
# sibling with INPUT on stdin. OUTPUT receives the CR-stripped stdout. The
# return status is the transport's; only the envelope decides the outcome.
interop_invoke() {
  invoke_alias=$1
  invoke_input=$2
  invoke_output=$3
  invoke_rc=0
  # cd first: without it Windows processes start in C:\Windows.
  # shellcheck disable=SC2016 # expanded by the remote sh, not here
  ssh_run "$invoke_alias" sh -c '
cd -- "$1" || { printf "roundhouse: WSL interop drive root is unavailable: %s\n" "$1" >&2; exit 69; }
[ -x "$2" ] || { printf "roundhouse: PowerShell 7 is not reachable through WSL interop: %s\n" "$2" >&2; exit 69; }
exec "$2" -NoLogo -NoProfile -NonInteractive -EncodedCommand "$3"
' roundhouse-interop "$(interop_drive_root)" "$(interop_pwsh_path)" "$(interop_bootstrap_encoded)" \
    <"$invoke_input" >"$invoke_output.raw" || invoke_rc=$?
  tr -d '\r' <"$invoke_output.raw" >"$invoke_output"
  rm -f "$invoke_output.raw"
  return "$invoke_rc"
}

# interop_read_envelope RAW ENVELOPE JSONL: accept exactly one well-formed
# result envelope, then write its JSONL payload separately. Fails closed on
# anything else, including stray or duplicated markers.
interop_read_envelope() {
  read_raw=$1
  read_envelope=$2
  read_jsonl=$3
  jq -R -r --arg marker "$interop_result_marker" \
    'select(startswith($marker)) | ltrimstr($marker)' "$read_raw" >"$read_envelope.b64" 2>/dev/null ||
    return 1
  [ "$(wc -l <"$read_envelope.b64" | tr -d ' ')" -eq 1 ] || { rm -f "$read_envelope.b64"; return 1; }
  jq -R -r '@base64d' "$read_envelope.b64" >"$read_envelope.json" 2>/dev/null || {
    rm -f "$read_envelope.b64"
    return 1
  }
  rm -f "$read_envelope.b64"
  jq -e '
    type == "object" and
    (keys == ["installed_versions","jsonl","message","schema","schema_version","stage_removed","state"]) and
    .schema == "roundhouse.interop-result" and .schema_version == 1 and
    (.state | IN("completed","partial","executor_update_required","failed")) and
    (.message | type == "string" and length <= 4096) and
    (.installed_versions | type == "array" and length <= 64 and
      all(.[]; type == "string" and test("^[0-9A-Za-z.+-]{1,64}$"))) and
    (.stage_removed | type == "boolean") and
    (.jsonl | type == "string")
  ' "$read_envelope.json" >/dev/null 2>&1 || return 1
  mv "$read_envelope.json" "$read_envelope"
  jq -j '.jsonl' "$read_envelope" >"$read_jsonl"
}

interop_envelope_field() {
  jq -r "$2 | if type == \"array\" then join(\", \") else tostring end | gsub(\"[[:cntrl:]]\"; \" \")" "$1"
}

interop_report_stage() {
  if [ "$(jq -r '.stage_removed' "$1")" != true ]; then
    printf 'roundhouse: warning: the Windows interop staging directory could not be removed\n' >&2
  fi
}

interop_executor_update_message() {
  report_host=$1
  report_envelope=$2
  report_version=$3
  report_installed=$(interop_envelope_field "$report_envelope" '.installed_versions')
  printf 'roundhouse: executor_update_required: %s has no verified roundhouse %s executor (%s; installed: %s); update the Windows plugin first; no collector or mutation ran\n' \
    "$report_host" "$report_version" "$(interop_envelope_field "$report_envelope" '.message')" \
    "${report_installed:-none}" >&2
}

interop_error_record() {
  # interop_error_record RECORDS TARGET SNAPSHOT-ID OBSERVED ID CODE MESSAGE
  jq -cn --arg schema "$schema" --argjson schema_version "$schema_version" \
    --arg snapshot_id "$3" --arg host_id "$2" --arg observed_at "$4" \
    --arg id "$5" --arg code "$6" --arg message "$7" '
    {schema:$schema,schema_version:$schema_version,snapshot_id:$snapshot_id,host_id:$host_id,
      kind:"error",id:$id,observed_at:$observed_at,status:"unavailable",confidence:"high",
      data:{transport:"wsl-interop"},evidence:[],
      errors:[{code:$code,severity:"error",retryable:true,message:$message}]}' >>"$1"
}

# interop_collect ALIAS TARGET SNAPSHOT-ID SECTIONS CONTROLLER-DIGEST OBSERVED
#   WORK RECORDS
# Collect over the interop lane. On success RECORDS is replaced by the native
# collector's validated records, which carry their own snapshot and collect
# records exactly as the Codex task lane returns them. On any failure an
# error record is appended to RECORDS and interop_collect_ok stays false;
# nothing that failed validation is ever merged. It reports through that
# variable rather than its status so that it is never called in an AND-OR
# context, where errexit would silently stop applying to its setup steps.
interop_collect() {
  collect_alias=$1
  collect_target=$2
  collect_snapshot_id=$3
  collect_sections=$4
  collect_digest=$5
  collect_observed=$6
  collect_work=$7/interop
  collect_records=$8
  interop_collect_ok=false
  mkdir -m 700 "$collect_work"
  worker_config_command "$collect_target" inventory "$collect_work/config.json"
  interop_executor_requirement "$collect_work/executor.json"
  collect_version=$(jq -r '.version' "$collect_work/executor.json")
  # Auth verification probes run only for an explicitly requested auth
  # inventory, as in the Codex protocol.
  collect_allow_auth=false
  case ",$collect_sections," in *,auth,*) collect_allow_auth=true ;; esac
  collect_extra=$(jq -cn --arg snapshot_id "$collect_snapshot_id" --arg sections "$collect_sections" \
    --argjson allow "$collect_allow_auth" \
    '{snapshot_id:$snapshot_id,sections:($sections | split(",")),allow_auth_verify:$allow}')
  interop_build_input "$collect_work" collect "$collect_target" "$collect_digest" \
    "$collect_extra" "$collect_work/input.json"
  collect_transport_rc=0
  interop_invoke "$collect_alias" "$collect_work/input.json" "$collect_work/output" ||
    collect_transport_rc=$?
  if ! interop_read_envelope "$collect_work/output" "$collect_work/envelope.json" \
      "$collect_work/worker.jsonl"; then
    printf 'roundhouse: WSL interop sibling %s returned no native Windows result (status %s); the visible Codex task remains the fallback\n' \
      "$collect_alias" "$collect_transport_rc" >&2
    interop_error_record "$collect_records" "$collect_target" "$collect_snapshot_id" \
      "$collect_observed" transport:wsl-interop wsl_interop_unavailable \
      "WSL interop sibling did not return a native Windows result envelope"
    return 0
  fi
  interop_report_stage "$collect_work/envelope.json"
  case $(jq -r '.state' "$collect_work/envelope.json") in
    completed) ;;
    executor_update_required)
      interop_executor_update_message "$collect_target" "$collect_work/envelope.json" "$collect_version"
      interop_error_record "$collect_records" "$collect_target" "$collect_snapshot_id" \
        "$collect_observed" executor:wsl-interop executor_update_required \
        "Exact Roundhouse executor is missing, stale, or failed integrity verification"
      return 0
      ;;
    *)
      printf 'roundhouse: native Windows collector failed over WSL interop: %s\n' \
        "$(interop_envelope_field "$collect_work/envelope.json" '.message')" >&2
      interop_error_record "$collect_records" "$collect_target" "$collect_snapshot_id" \
        "$collect_observed" transport:wsl-interop native_worker_failed \
        "Native Windows collector failed over WSL interop"
      return 0
      ;;
  esac
  if ! ( validate_file "$collect_work/worker.jsonl" ) >/dev/null 2>&1 ||
    ! jq -e -s --arg target "$collect_target" --arg snapshot_id "$collect_snapshot_id" \
      --arg digest "$collect_digest" --arg worker_digest "$(sha256_file "$collect_work/config.json")" \
      --arg sections "$collect_sections" '
      ($sections | split(",") | sort) as $wanted |
      all(.[]; .host_id == $target and .snapshot_id == $snapshot_id) and
      ([.[] | select(.kind == "snapshot")] |
        length == 1 and .[0].id == "snapshot" and
        (.[0].data.configuration_digest | .algorithm == "sha256" and .value == $digest and
          .scope == "controller-raw-bytes") and
        (.[0].data.worker_configuration_digest | .algorithm == "sha256" and .value == $worker_digest) and
        ((.[0].data.sections | sort) == $wanted)) and
      ([.[] | select(.kind == "operation")] |
        length == 1 and .[0].id == "collect" and .[0].data.host_id == $target and
        .[0].data.phase == "collect")
    ' "$collect_work/worker.jsonl" >/dev/null 2>&1; then
    printf 'roundhouse: native Windows collector returned records that failed validation\n' >&2
    interop_error_record "$collect_records" "$collect_target" "$collect_snapshot_id" \
      "$collect_observed" transport:wsl-interop invalid_worker_result \
      "Native Windows collector records failed controller validation"
    return 0
  fi
  cp "$collect_work/worker.jsonl" "$collect_records"
  interop_collect_ok=true
}
