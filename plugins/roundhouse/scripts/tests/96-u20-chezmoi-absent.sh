# roundhouse self-check — U20's chezmoi-absent invariant across the core path.
#
# Sourced by scripts/test-roundhouse after the real-jj prerequisites; not a
# standalone test file. The PATH scrub is deliberate: the general inventory
# and convergence paths must not discover the test harness's chezmoi stub.
# shellcheck shell=bash

u20_root="$tmp/u20"
mkdir -p "$u20_root"

if [ "$real_jj_ok" != true ]; then
  printf 'NOTICE: U20 chezmoi-absent path skipped without real jj\n'
else
  printf 'U20: chezmoi-absent core path\n'
  (
    set -eu
    u20_bin="$u20_root/bin"
    mkdir -p "$u20_bin"
    for u20_tool in "$tmp/bin"/*; do
      [ "$(basename "$u20_tool")" = chezmoi ] ||
        ln -s "$u20_tool" "$u20_bin/$(basename "$u20_tool")"
    done
    ln -s "$real_jj" "$u20_bin/jj"
    ln -s "$real_yq" "$u20_bin/yq"
    ln -s "$cli" "$u20_bin/roundhouse"
    PATH="$u20_bin:/usr/bin:/bin"
    export PATH

    u20_jj="$u20_root/jj"
    export JJ_CONFIG="$u20_jj/jj-config.toml"
    export XDG_CONFIG_HOME="$u20_jj/xdg"
    export HOME="$tmp/home"
    mkdir -p "$u20_jj" "$HOME"
    export CHEZMOI_SOURCE_DIR="$u20_root/no-source"
    cat >"$JJ_CONFIG" <<'TOML'
[user]
name = "roundhouse U20 self-check"
email = "roundhouse-u20@example.invalid"
[ui]
paginate = "never"
editor = "true"
TOML
    rjj="$u20_jj/real"
    mkdir -p "$rjj"
    rjj_key test-host
    rjj_krl empty.krl
    git init -q --bare -b main "$rjj/remote.git"
    mkdir -p "$rjj/test-host"
    printf 'name: test-host\ndomain: fleet.example.invalid\n' >"$rjj/test-host/identity.yaml"
    export ROUNDHOUSE_CONFIG="$tmp/config.json"
    u20_store="$rjj/test-host/store"
    u20_run() {
      env ROUNDHOUSE_FLEET_STORE="$u20_store" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/test-host-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/test-host" \
        "$@"
    }

    u20_run "$cli" fleet-init >/dev/null
    jj -R "$u20_store" git remote add origin "$rjj/remote.git" >/dev/null
    u20_run "$cli" fleet-enroll >/dev/null
    mkdir -p "$u20_store/hosts"
    cat >"$u20_store/fleet.yaml" <<'YAML'
policy:
  fast_interval_minutes: 20
  fast_jitter_minutes: 5
  cadence_hours: 12
  jitter_minutes: 90
YAML
    printf 'platform: macos\ngroups: [development]\nhostname: vireo.invalid\nuser: claire\n' \
      >"$u20_store/hosts/test-host.yaml"
    ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "Permission denied (publickey)\\n" >&2; exit 128' \
      u20_run "$cli" fleet-verify-remote >/dev/null

    u20_snapshot="$u20_root/inventory.jsonl"
    u20_run "$cli" collect --target test-host --section all --output "$u20_snapshot"
    [ "$(jq -r 'select(.kind == "chezmoi_state" and .id == "live") | .status' \
      "$u20_snapshot")" = absent ] ||
      fail "U20 inventory did not classify absent chezmoi as absent"
    [ "$(jq -r 'select(.kind == "chezmoi_state" and .id == "live") | .data.tool_available' \
      "$u20_snapshot")" = false ] ||
      fail "U20 inventory did not record tool_available:false"
    ! grep -Eiq 'co-ownership|coownership' "$u20_snapshot" ||
      fail "U20 inventory emitted a co-ownership alert without chezmoi"

    u20_run "$cli" fleet-run --fast >/dev/null
    u20_readiness=$(u20_run "$cli" fleet-readiness test-host)
    printf '%s\n' "$u20_readiness" | grep -Fq 'fleet-readiness ready' ||
      fail "U20 readiness changed under the chezmoi-absent PATH"
    ! printf '%s\n' "$u20_readiness" | grep -Eiq chezmoi ||
      fail "U20 readiness acquired a chezmoi prerequisite: $u20_readiness"

    # U22: readiness reports every prerequisite without turning a missing
    # tool into an opaque early exit, and rejects an unsafe machine name.
    u22_bin="$u20_root/no-jj-bin"
    mkdir -p "$u22_bin"
    for u22_tool in "$u20_bin"/*; do
      [ "$(basename "$u22_tool")" = jj ] ||
        ln -s "$u22_tool" "$u22_bin/$(basename "$u22_tool")"
    done
    u22_status=0
    u22_missing=$(PATH="$u22_bin:/usr/bin:/bin" \
      u20_run "$cli" fleet-readiness test-host 2>&1) || u22_status=$?
    [ "$u22_status" -eq 1 ] ||
      fail "U22 missing-jj readiness exited $u22_status"
    printf '%s\n' "$u22_missing" | grep -Fq 'missing:jj' ||
      fail "U22 readiness did not name missing jj: $u22_missing"
    u22_status=0
    u22_invalid=$(u20_run "$cli" fleet-readiness '../unsafe' 2>&1) || u22_status=$?
    [ "$u22_status" -eq 1 ] ||
      fail "U22 invalid-host readiness exited $u22_status"
    printf '%s\n' "$u22_invalid" | grep -Fq 'invalid machine name' ||
      fail "U22 readiness did not name invalid machine identity: $u22_invalid"

    # U22: two explicit host arguments are checked independently — "$*"
    # would join them into one space-separated string and check it as a
    # single (invalid) name instead of two separate hosts.
    u22_multi_status=0
    u22_multi=$(u20_run "$cli" fleet-readiness test-host '../unsafe' 2>&1) ||
      u22_multi_status=$?
    [ "$u22_multi_status" -eq 1 ] ||
      fail "U22 multi-host readiness exited $u22_multi_status"
    printf '%s\n' "$u22_multi" | grep -Fq 'test-host' ||
      fail "U22 multi-host readiness dropped test-host: $u22_multi"
    printf '%s\n' "$u22_multi" | grep -Fq 'invalid machine name' ||
      fail "U22 multi-host readiness did not flag ../unsafe: $u22_multi"
    ! printf '%s\n' "$u22_multi" | grep -Fq 'test-host ../unsafe' ||
      fail "U22 multi-host readiness joined args into one name: $u22_multi"

    u20_doctor_status=0
    u20_doctor=$(u20_run "$cli" fleet-doctor 2>&1) || u20_doctor_status=$?
    [ "$u20_doctor_status" -eq 0 ] || {
      printf '%s\n' "$u20_doctor" >&2
      fail "U20 fleet-doctor did not complete cleanly (exit $u20_doctor_status)"
    }

    u20_present_bin="$u20_root/present-bin"
    mkdir -p "$u20_present_bin"
    cat >"$u20_present_bin/chezmoi" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
  source-path) printf '%s\n' "$HOME/.local/share/chezmoi" ;;
  status) exit 0 ;;
  *) exit 64 ;;
esac
SH
    chmod +x "$u20_present_bin/chezmoi"
    u20_present_snapshot="$u20_root/chezmoi-present-no-source.jsonl"
    PATH="$u20_present_bin:$u20_bin:/usr/bin:/bin" \
      u20_run "$cli" collect --target test-host --section chezmoi \
      --output "$u20_present_snapshot"
    [ "$(jq -r 'select(.kind == "file" and .id == "chezmoi:source") | .status' \
      "$u20_present_snapshot")" = absent ] ||
      fail "U20 present-without-source case was not absent"
    [ "$(jq -r 'select(.kind == "chezmoi_state" and .id == "live") | .data.drift_count' \
      "$u20_present_snapshot")" = 0 ] ||
      fail "U20 present-without-source case did not report zero drift"

    cat >"$u20_root/chezmoi-plan.json" <<'JSON'
{
  "domain": "chezmoi",
  "target": "test-host",
  "operations": [{
    "type": "chezmoi-pull",
    "kind": "file",
    "id": "chezmoi:source",
    "argv": ["chezmoi", "git", "--", "pull", "--ff-only"]
  }]
}
JSON
    u20_plan_status=0
    u20_plan_error=$(u20_run "$cli" seal-plan "$u20_root/chezmoi-plan.json" \
      "$u20_snapshot" "$u20_root/chezmoi-sealed.json" 2>&1) ||
      u20_plan_status=$?
    [ "$u20_plan_status" -ne 0 ] ||
      fail "U20 explicit chezmoi plan succeeded without a source"
    printf '%s\n' "$u20_plan_error" | grep -Eiq chezmoi ||
      fail "U20 explicit chezmoi failure did not name the domain: $u20_plan_error"
  )
fi
