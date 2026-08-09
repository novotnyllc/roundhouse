# roundhouse self-check — U2 — the happy path, collector readiness, the
# journal, upgrade and revocation.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

test_u2_collector_contracts() {
  u2_happy=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)))
  if ! APT_EXEC_MARKER="$apt_marker" ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
      "$broker" <"$u2_happy" >"$tmp/u2-happy"; then
    cat "$tmp/u2-happy" >&2
    fail "U2 valid signed broker fixture was rejected"
  fi
  grep -Fqx 'state|completed' "$tmp/u2-happy" || fail "U2 signed fixture did not complete"
  grep -Fqx 'reason|post_state_verified' "$tmp/u2-happy" ||
    fail "U2 fixture did not verify native post-state"
  grep -Eq '^action-evidence-sha256\|[0-9a-f]{64}$' "$tmp/u2-happy" &&
    grep -Fqx 'effect-phase|verified' "$tmp/u2-happy" ||
    fail "U2 broker omitted fixed action or verified-effect evidence"
  if grep -Eq 'derived-argv|/usr/|https://|BEGIN (SSH|PGP)|\[GNUPG:\]|VALIDSIG' "$tmp/u2-happy"; then
    fail "U2 protected result leaked a path, argv, URL, certificate, signature, or verifier status"
  fi
  grep -Fqx "$u2_root/usr/bin/apt-get|--quiet=2 update" "$apt_marker" ||
    fail "U2 fixture did not execute only the protected fake APT path"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-readiness none >"$tmp/u2-readiness.jsonl"
  u2_readiness=$(jq -c 'select(.kind=="privilege_broker" and .id=="readiness")' "$tmp/u2-readiness.jsonl")
  [ "$(printf '%s' "$u2_readiness" | jq -r '.status+"|"+.data.lifecycle_status')" = 'present|ready' ] ||
    fail "U2 collector did not validate the protected enrollment"
  [ "$(printf '%s' "$u2_readiness" | jq -r '.data.transport_ready')" = false ] ||
    fail "U2 collector promoted a configured route without a U6 transport receipt"
  [ "$(printf '%s' "$u2_readiness" | jq -r '.data.protected_identity.uid')" = "$u2_uid" ] &&
    [ "$(printf '%s' "$u2_readiness" | jq -r '.data.protected_identity.request_principal')" = roundhouse ] ||
    fail "U2 collector omitted the protected UID or request principal"
  [ "$(printf '%s' "$u2_readiness" | jq -r '.data.last_terminal_result.state')" = completed ] ||
    fail "U2 collector did not expose the sanitized last terminal result"
  [ "$(printf '%s' "$u2_readiness" | jq -r \
    '.data.observed_preconditions[] | select(.action_id=="apt.update-metadata.v1") | .digest.value')" = \
    "$u2_precondition_digest" ] || fail "U2 collector omitted fresh action precondition evidence"
  rm -f "$apt_marker"

  u2_canonical="$u2_root/var/lib/roundhouse/replay/request-00000000000000000000000000000001/journal"
  u2_projection="$u2_root/var/lib/roundhouse/journal/request-00000000000000000000000000000001.result"
  grep -Fqx 'journal|2' "$u2_canonical" &&
    grep -Fqx 'effect-phase|verified' "$u2_canonical" ||
    fail "U2 canonical journal did not retain the v2 verified terminal state"
  u2_query=$(u2_make_envelope broker.query-result.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)))
  cp "$u2_query" "$tmp/u2-query-original-envelope"
  u2_query="$tmp/u2-query-original-envelope"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query" >"$tmp/u2-query-v1" ||
    fail "U2 authenticated v1 result query failed"
  grep -Fqx 'state|completed' "$tmp/u2-query-v1" || fail "U2 v1 query lost the terminal result"

  cp -p "$u2_canonical" "$tmp/u2-current-version-journal"
  awk -F '|' -v OFS='|' '$1=="broker-version"{$2="0.9.0"}{print}' \
    "$u2_canonical" >"$tmp/u2-previous-version-journal"
  mv "$tmp/u2-previous-version-journal" "$u2_canonical"
  chmod 600 "$u2_canonical"
  u2_request_broker_version=0.9.0
  u2_query_previous=$(u2_make_envelope broker.query-result.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)))
  unset u2_request_broker_version
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query_previous" \
    >"$tmp/u2-query-previous-version" ||
    fail "U2 immediately previous broker-version result query failed"
  grep -Fqx 'broker-version|0.9.0' "$tmp/u2-query-previous-version" ||
    fail "U2 previous-version query did not return its canonical authority"
  mv "$tmp/u2-current-version-journal" "$u2_canonical"
  cp "$u2_canonical" "$u2_projection"
  chmod 600 "$u2_projection"

  u2_query_peer=$(u2_make_envelope broker.query-result.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)) \
    node-b - not-applicable 1 plan-0123456789abcdef "$tmp/u2-node-b-key-cert.pub")
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query_peer" >"$tmp/u2-query-peer" ||
    fail "U2 enrolled peer could not recover another node's result"
  grep -Fqx 'originating-node-id|node-a' "$tmp/u2-query-peer" ||
    fail "U2 peer query did not preserve the journaled originating identity"

  u2_query_renewed=$(u2_make_envelope broker.query-result.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)) \
    node-a - not-applicable 1 plan-0123456789abcdef "$tmp/u2-node-renewed-key-cert.pub")
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query_renewed" \
    >"$tmp/u2-query-renewed" || fail "U2 renewed node certificate could not recover an old result"

  cp -p "$u2_root/etc/roundhouse/trust/fleet-ca.pub" "$tmp/u2-query-old-ca"
  cp -p "$u2_root/etc/roundhouse/trust/allowed_signers" "$tmp/u2-query-old-signers"
  cp -p "$u2_generation/host.identity" "$tmp/u2-query-old-host-identity"
  u2_rotated_ca_fingerprint=$("$ssh_keygen" -lf "$tmp/u2-rotated-fleet-ca.pub" -E sha256 |
    awk 'NR==1{print $2}')
  cp "$tmp/u2-rotated-fleet-ca.pub" "$u2_root/etc/roundhouse/trust/fleet-ca.pub"
  awk 'NR==1{print "node-a@fleet.example cert-authority "$0}' "$tmp/u2-rotated-fleet-ca.pub" \
    >"$u2_root/etc/roundhouse/trust/allowed_signers"
  awk -F '|' -v OFS='|' -v ca="$u2_rotated_ca_fingerprint" '{$7=ca;$8=2;print}' \
    "$u2_generation/host.identity" >"$tmp/u2-query-rotated-host-identity"
  mv "$tmp/u2-query-rotated-host-identity" "$u2_generation/host.identity"
  chmod 644 "$u2_generation/host.identity" "$u2_root/etc/roundhouse/trust/fleet-ca.pub" \
    "$u2_root/etc/roundhouse/trust/allowed_signers"
  u2_request_ca_fingerprint=$u2_rotated_ca_fingerprint
  u2_request_ca_generation=2
  u2_query_rotated=$(u2_make_envelope broker.query-result.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)) \
    node-a - not-applicable 1 plan-0123456789abcdef "$tmp/u2-rotated-node-key-cert.pub")
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query_rotated" \
    >"$tmp/u2-query-rotated" || fail "U2 rotated-CA certificate could not recover an old result"
  unset u2_request_ca_fingerprint u2_request_ca_generation
  mv "$tmp/u2-query-old-ca" "$u2_root/etc/roundhouse/trust/fleet-ca.pub"
  mv "$tmp/u2-query-old-signers" "$u2_root/etc/roundhouse/trust/allowed_signers"
  mv "$tmp/u2-query-old-host-identity" "$u2_generation/host.identity"

  printf '%s\n' 'forged-result-projection' >"$u2_projection"
  chmod 600 "$u2_projection"
  printf '%s\n' 'forged-public-projection' >"$u2_root/var/lib/roundhouse-public/last"
  chmod 644 "$u2_root/var/lib/roundhouse-public/last"
  u2_terminal_digest=$(u2_sha256 "$u2_canonical")
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query" >"$tmp/u2-query-repair" ||
    fail "U2 query did not repair forged projections"
  [ "$(u2_sha256 "$u2_canonical")" = "$u2_terminal_digest" ] &&
    cmp -s "$u2_canonical" "$u2_projection" &&
    grep -Fqx 'broker-public|1' "$u2_root/var/lib/roundhouse-public/last" &&
    grep -Fqx 'state|completed' "$u2_root/var/lib/roundhouse-public/last" ||
    fail "U2 projection repair changed or failed to reproduce terminal authority"
  if grep -Eq '/usr/|https://|BEGIN (SSH|PGP)|\[GNUPG:\]|VALIDSIG' \
      "$u2_root/var/lib/roundhouse-public/last"; then
    fail "U2 public projection leaked protected execution or authentication material"
  fi

  u2_boot_identity() {
    if [ -r /proc/sys/kernel/random/boot_id ]; then sed -n '1p' /proc/sys/kernel/random/boot_id
    else
      /usr/sbin/sysctl -n kern.boottime | awk '
        NR==1 {
          if ($1!="{" || $2!="sec" || $3!="=" || $5!="usec" || $6!="=" || $8!="}") exit 1
          sec=$4; sub(/,$/,"",sec); usec=$7
          if (sec!~/^(0|[1-9][0-9]*)$/ || length(sec)>20 ||
              usec!~/^(0|[1-9][0-9]*)$/ || length(usec)>6 || usec+0>999999) exit 1
          print "boot|1|sec=" sec "|usec=" usec
          found=1
        }
        END { if (NR!=1 || !found) exit 1 }
      '
    fi | u2_sha256_stream
  }
  u2_process_start_identity() {
    inspected_pid=$1
    if [ -r "/proc/$inspected_pid/stat" ]; then
      sed 's/^.*) //' "/proc/$inspected_pid/stat" | awk '{print $20}'
    else
      TZ=UTC /bin/ps -o lstart= -p "$inspected_pid"
    fi | u2_sha256_stream
  }
  if [ ! -r /proc/sys/kernel/random/boot_id ]; then
    u2_boot_raw_utc=$(TZ=UTC /usr/sbin/sysctl -n kern.boottime)
    u2_boot_raw_local=$(TZ=America/New_York /usr/sbin/sysctl -n kern.boottime)
    [ "$u2_boot_raw_utc" != "$u2_boot_raw_local" ] ||
      fail "U2 boot-identity fixture did not exercise timezone-dependent sysctl output"
    [ "$(TZ=UTC u2_boot_identity)" = "$(TZ=America/New_York u2_boot_identity)" ] ||
      fail "U2 canonical boot identity depended on the sysctl timezone suffix"
  fi
  mkdir "$u2_root/var/lib/roundhouse/lock/active"
  chmod 700 "$u2_root/var/lib/roundhouse/lock/active"
  /bin/sleep 300 &
  u2_live_admission_pid=$!
  u2_terminal_launch=$(awk -F '|' '$1=="launch-record-sha256"{print $2}' "$u2_canonical")
  u2_live_admission_start=$(u2_process_start_identity "$u2_live_admission_pid")
  [ "$(TZ=UTC u2_process_start_identity "$u2_live_admission_pid")" = \
    "$(TZ=America/New_York u2_process_start_identity "$u2_live_admission_pid")" ] ||
    fail "U2 process-start identity depended on the caller timezone"
  printf 'admission|2|%s|%s|%s|%s|%s|%s|%s|verifying|verified|1|%s\n' \
    request-00000000000000000000000000000001 "$u2_live_admission_pid" \
    "$u2_live_admission_start" "$u2_live_admission_pid" "$u2_live_admission_pid" \
    "$u2_live_admission_start" \
    "$(u2_boot_identity)" "$u2_terminal_launch" \
    >"$u2_root/var/lib/roundhouse/lock/active/admission"
  chmod 600 "$u2_root/var/lib/roundhouse/lock/active/admission"
  kill -0 "$u2_live_admission_pid" 2>/dev/null ||
    fail "U2 live-admission fixture child was not live immediately before query"
  [ "$(u2_process_start_identity "$u2_live_admission_pid")" = "$u2_live_admission_start" ] ||
    fail "U2 live-admission fixture process-start identity changed before query"
  cp "$u2_root/var/lib/roundhouse/lock/active/admission" "$tmp/u2-live-admission.before"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    "$broker" <"$u2_query" >"$tmp/u2-query-live-terminal" ||
    fail "U2 query rejected completed authority during the release window"
  [ "$(u2_sha256 "$u2_canonical")" = "$u2_terminal_digest" ] ||
    fail "U2 live-admission reconciliation rewrote terminal authority"
  grep -Fqx 'state|completed' "$tmp/u2-query-live-terminal" ||
    fail "U2 live-admission query did not return completed authority"
  if [ ! -f "$u2_root/var/lib/roundhouse/lock/active/admission" ]; then
    cat "$tmp/u2-live-admission.before" >&2
    fail "U2 live-admission query removed a proven-live admission"
  fi
  kill "$u2_live_admission_pid" 2>/dev/null || true
  wait "$u2_live_admission_pid" 2>/dev/null || true
  rm -f "$u2_root/var/lib/roundhouse/lock/active/admission"
  [ ! -d "$u2_root/var/lib/roundhouse/lock/active" ] ||
    rmdir "$u2_root/var/lib/roundhouse/lock/active"

  mkdir "$u2_root/var/lib/roundhouse/lock/active"
  chmod 700 "$u2_root/var/lib/roundhouse/lock/active"
  /bin/sleep 300 &
  u2_reused_group_pid=$!
  u2_wrong_start=$(printf '%064d' 0)
  printf 'admission|2|%s|%s|%s|%s|%s|%s|%s|verifying|verified|1|%s\n' \
    request-00000000000000000000000000000001 "$u2_reused_group_pid" "$u2_wrong_start" \
    "$u2_reused_group_pid" "$u2_reused_group_pid" "$u2_wrong_start" \
    "$(u2_boot_identity)" "$u2_terminal_launch" \
    >"$u2_root/var/lib/roundhouse/lock/active/admission"
  chmod 600 "$u2_root/var/lib/roundhouse/lock/active/admission"
  printf 'emergency|1|%s|%s|%s\n' request-00000000000000000000000000000001 \
    "$u2_reused_group_pid" "$(u2_boot_identity)" \
    >"$u2_root/var/lib/roundhouse/emergency-terminate"
  chmod 600 "$u2_root/var/lib/roundhouse/emergency-terminate"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query" \
    >"$tmp/u2-query-reused-group" || fail "U2 reused-group reconciliation rejected the canonical result"
  kill -0 "$u2_reused_group_pid" 2>/dev/null ||
    fail "U2 emergency reconciliation signaled a process with mismatched leader start identity"
  [ ! -e "$u2_root/var/lib/roundhouse/emergency-terminate" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/lock/active" ] ||
    fail "U2 mismatched leader identity remained live in admission state"
  kill "$u2_reused_group_pid" 2>/dev/null || true
  wait "$u2_reused_group_pid" 2>/dev/null || true

  u2_query_v0=$(u2_make_envelope broker.query-result.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)) \
    node-a - not-applicable 0)
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_query_v0" >"$tmp/u2-query-v0" ||
    fail "U2 protocol-0 compatibility query failed"
  grep -Fqx 'state|completed' "$tmp/u2-query-v0" || fail "U2 protocol-0 query lost canonical state"
  u2_query_wrong_plan=$(u2_make_envelope broker.query-result.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)) \
    node-a - not-applicable 1 plan-fedcba9876543210)
  u2_expect_rejected result_binding_mismatch "$u2_query_wrong_plan" "$tmp/u2-query-wrong-plan"

  u2_v0_mutation=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000009 "$u2_now" $((u2_now + 300)) \
    node-a - not-applicable 0)
  u2_expect_rejected unsupported_broker_protocol "$u2_v0_mutation" "$tmp/u2-v0-mutation"
  [ ! -e "$apt_marker" ] || fail "U2 protocol-0 mutation reached native APT"

  u2_host_certificate=$(u2_make_envelope apt.update-metadata.v1 \
    request-0000000000000000000000000000000a "$u2_now" $((u2_now + 300)) \
    node-a - not-applicable 1 plan-0123456789abcdef "$tmp/u2-host-node-key-cert.pub")
  u2_host_certificate_type=$(/usr/bin/ssh-keygen -Lf "$tmp/u2-host-node-key-cert.pub" |
    awk '/^[[:space:]]*Type:/ {sub(/^[[:space:]]*/,"");print;count++}
      END{if(count!=1)exit 1}')
  [ "$u2_host_certificate_type" = 'Type: ssh-ed25519-cert-v01@openssh.com host certificate' ] ||
    fail "U2 host-certificate fixture did not prove its certificate type"
  u2_expect_rejected signature_verification_failed "$u2_host_certificate" "$tmp/u2-host-certificate"
  [ ! -e "$apt_marker" ] || fail "U2 host certificate reached native APT"

  printf '%s\n' 'torn-audit-fragment' >>"$u2_root/var/lib/roundhouse/audit/events.log"
  u2_audit_repair=$(u2_make_envelope apt.update-metadata.v1 \
    request-0000000000000000000000000000000b "$u2_now" $((u2_now + 300)))
  APT_EXEC_MARKER="$apt_marker" ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    "$broker" <"$u2_audit_repair" >"$tmp/u2-audit-repair" ||
    fail "U2 immutable audit projection repair rejected valid work"
  ! grep -Fq 'torn-audit-fragment' "$u2_root/var/lib/roundhouse/audit/events.log" &&
    grep -Fqx 'state|completed' "$tmp/u2-audit-repair" ||
    fail "U2 audit projection retained a torn append or lost terminal state"
  rm -f "$apt_marker"

  u2_capacity=$(u2_make_envelope apt.update-metadata.v1 \
    request-0000000000000000000000000000000c "$u2_now" $((u2_now + 300)))
  if ROUNDHOUSE_U2_CLAIM_CAPACITY=1 ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
      "$broker" <"$u2_capacity" >"$tmp/u2-capacity" 2>/dev/null; then
    fail "U2 bounded replay capacity admitted work without a claim slot"
  fi
  grep -Fqx 'reason|claim_capacity_exhausted' "$tmp/u2-capacity" ||
    fail "U2 claim-capacity exhaustion was not explicit"
  [ ! -e "$apt_marker" ] || fail "U2 capacity exhaustion reached native APT"

  u2_audit_capacity=$(u2_make_envelope apt.update-metadata.v1 \
    request-0000000000000000000000000000000d "$u2_now" $((u2_now + 300)))
  if ROUNDHOUSE_U2_AUDIT_CAPACITY_BYTES=1 ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
      "$broker" <"$u2_audit_capacity" >"$tmp/u2-audit-capacity" 2>/dev/null; then
    fail "U2 bounded audit capacity admitted work without projection space"
  fi
  grep -Fqx 'reason|audit_capacity_exhausted' "$tmp/u2-audit-capacity" ||
    fail "U2 audit-capacity exhaustion was not explicit"
  grep -Fqx 'state|rejected' "$tmp/u2-audit-capacity" && [ ! -e "$apt_marker" ] ||
    fail "U2 audit-capacity exhaustion lacked a pre-effect terminal record"
  if find "$u2_root/var/lib/roundhouse/audit" -mindepth 1 -maxdepth 1 \
      -name '.events.*' -print | grep -q .; then
    fail "U2 audit-capacity exhaustion left a projection temporary"
  fi

  u2_claim_fail_index=0
  for u2_claim_failpoint in before-mkdir after-mkdir after-copy after-reserve before-rename; do
    u2_claim_fail_index=$((u2_claim_fail_index + 1))
    u2_claim_request=$(printf 'request-f%031x' "$u2_claim_fail_index")
    u2_claim_envelope=$(u2_make_envelope apt.update-metadata.v1 "$u2_claim_request" \
      "$u2_now" $((u2_now + 300)))
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
        ROUNDHOUSE_U2_CLAIM_FAIL_AT="$u2_claim_failpoint" \
        "$broker" <"$u2_claim_envelope" >"$tmp/u2-claim-$u2_claim_failpoint" 2>/dev/null; then
      fail "U2 injected claim failure completed: $u2_claim_failpoint"
    fi
    grep -Fqx 'reason|claim_reservation_failed' "$tmp/u2-claim-$u2_claim_failpoint" &&
      [ ! -e "$u2_root/var/lib/roundhouse/replay/$u2_claim_request" ] &&
      [ ! -e "$u2_root/var/lib/roundhouse/lock/active" ] ||
      fail "U2 claim failure did not release its admission: $u2_claim_failpoint"
    if find "$u2_root/var/lib/roundhouse/replay" -mindepth 1 -maxdepth 1 \
        -name '.claim-*' -print | grep -q .; then
      fail "U2 claim failure left pre-rename staging: $u2_claim_failpoint"
    fi
  done
  [ ! -e "$apt_marker" ] || fail "U2 injected claim failure reached native APT"

  u2_term_request=request-000000000000000000000000000000e5
  u2_term_envelope=$(u2_make_envelope apt.update-metadata.v1 "$u2_term_request" \
    "$u2_now" $((u2_now + 300)))
  u2_pause_marker="$tmp/u2-broker-parent-term"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=launch-blocked \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$broker" <"$u2_term_envelope" >"$tmp/u2-broker-parent-term-result" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job" "$tmp/u2-broker-parent-term-result"
  u2_gate_child=$(awk -F '|' 'NR==1&&$1=="admission"&&$2=="2"{print $6}' \
    "$u2_root/var/lib/roundhouse/lock/active/admission")
  kill -TERM "$u2_pause_job"
  if wait "$u2_pause_job"; then fail "U2 TERM-interrupted broker reported success"; fi
  kill -0 "$u2_gate_child" 2>/dev/null && fail "U2 TERM-interrupted broker stranded its gate child"
  u2_term_claim="$u2_root/var/lib/roundhouse/replay/$u2_term_request"
  grep -Fqx 'reason|parent_interrupted_before_native_effect' "$tmp/u2-broker-parent-term-result" &&
    [ ! -e "$u2_term_claim/launch.gate" ] && [ ! -e "$u2_term_claim/terminal.reserve" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/lock/active" ] ||
    fail "U2 TERM interruption left a gate, reserve, or admission"
  rm -f "$u2_pause_marker" "$u2_pause_marker.continue" "$u2_pause_marker.kill"

  u2_kill_request=request-000000000000000000000000000000e6
  u2_kill_envelope=$(u2_make_envelope apt.update-metadata.v1 "$u2_kill_request" \
    "$u2_now" $((u2_now + 300)))
  u2_pause_marker="$tmp/u2-broker-parent-kill"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=launch-blocked \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$broker" <"$u2_kill_envelope" >"$tmp/u2-broker-parent-kill-result" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job" "$tmp/u2-broker-parent-kill-result"
  u2_gate_child=$(awk -F '|' 'NR==1&&$1=="admission"&&$2=="2"{print $6}' \
    "$u2_root/var/lib/roundhouse/lock/active/admission")
  kill -KILL "$u2_pause_job"
  wait "$u2_pause_job" 2>/dev/null || true
  u2_gate_wait=0
  while kill -0 "$u2_gate_child" 2>/dev/null && [ "$u2_gate_wait" -lt 50 ]; do
    sleep 0.1
    u2_gate_wait=$((u2_gate_wait + 1))
  done
  kill -0 "$u2_gate_child" 2>/dev/null && fail "U2 killed parent stranded a self-writing gate child"
  rm -f "$u2_pause_marker" "$u2_pause_marker.continue" "$u2_pause_marker.kill"
  u2_kill_query=$(u2_make_envelope broker.query-result.v1 "$u2_kill_request" \
    "$u2_now" $((u2_now + 300)))
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$u2_kill_query" \
    >"$tmp/u2-broker-parent-kill-query" || fail "U2 query could not recover a killed pre-effect parent"
  u2_kill_claim="$u2_root/var/lib/roundhouse/replay/$u2_kill_request"
  grep -Fqx 'state|stale' "$tmp/u2-broker-parent-kill-query" &&
    [ ! -e "$u2_kill_claim/launch.gate" ] && [ ! -e "$u2_kill_claim/terminal.reserve" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/lock/active" ] ||
    fail "U2 killed-parent recovery left a gate, reserve, or admission"

  u2_policy_active="$u2_generation/policy.actions"
  u2_constraints_active="$u2_generation/policy.constraints"
  cp -p "$u2_policy_active" "$tmp/u2-autoremove-policy"
  cp -p "$u2_constraints_active" "$tmp/u2-autoremove-constraints"
  u2_saved_policy_digest=$u2_policy_digest
  u2_saved_constraints_digest=$u2_constraints_digest
  u2_saved_precondition_digest=$u2_precondition_digest
  sed 's/^action|apt\.autoremove\.v1|posix-root-v1|disabled|none|-$/action|apt.autoremove.v1|posix-root-v1|enabled|none|-/' \
    "$u2_policy_active" >"$tmp/u2-autoremove-enabled"
  mv "$tmp/u2-autoremove-enabled" "$u2_policy_active"
  chmod 644 "$u2_policy_active"
  u2_policy_digest=$(u2_sha256 "$u2_policy_active")
  awk -F '|' -v OFS='|' -v digest="$u2_policy_digest" 'NR==1{$4="policy-sha256=" digest}{print}' \
    "$u2_constraints_active" >"$tmp/u2-autoremove-bound-constraints"
  mv "$tmp/u2-autoremove-bound-constraints" "$u2_constraints_active"
  chmod 644 "$u2_constraints_active"
  u2_constraints_digest=$(u2_sha256 "$u2_constraints_active")
  u2_autoremove_pre_digest=$(printf '%s\n' 'Remv fixture-unused [1.0]' | u2_sha256_stream)
  u2_autoremove_state_digest=$(printf '%s\n' 'base-files|1.0|ii ' | u2_sha256_stream)
  u2_precondition_digest=$(printf 'autoremove|%s|%s\n' "$u2_autoremove_pre_digest" \
    "$u2_autoremove_state_digest" | u2_sha256_stream)
  rm -f "$apt_marker" "$apt_marker.autoremove-done"
  u2_autoremove=$(u2_make_envelope apt.autoremove.v1 \
    request-000000000000000000000000000000e7 "$u2_now" $((u2_now + 300)))
  APT_EXEC_MARKER="$apt_marker" ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    "$broker" <"$u2_autoremove" >"$tmp/u2-autoremove" || {
      cat "$tmp/u2-autoremove" >&2
      fail "U2 enabled autoremove did not complete"
    }
  grep -Fqx "$u2_root/usr/bin/apt-get|--quiet=2 --yes autoremove" "$apt_marker" &&
    ! grep -Fq -- '--no-remove autoremove' "$apt_marker" &&
    grep -Fqx 'state|completed' "$tmp/u2-autoremove" ||
    fail "U2 autoremove retained the contradictory --no-remove option"
  mv "$tmp/u2-autoremove-policy" "$u2_policy_active"
  mv "$tmp/u2-autoremove-constraints" "$u2_constraints_active"
  u2_policy_digest=$u2_saved_policy_digest
  u2_constraints_digest=$u2_saved_constraints_digest
  u2_precondition_digest=$u2_saved_precondition_digest
  rm -f "$apt_marker" "$apt_marker.autoremove-done"

  u2_replay_envelope=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000001 "$u2_now" $((u2_now + 300)))
  u2_expect_rejected replayed_request "$u2_replay_envelope" "$tmp/u2-replay"
  u2_unknown=$(u2_make_envelope apt.unknown.v1 request-00000000000000000000000000000002 \
    "$u2_now" $((u2_now + 300)))
  u2_expect_rejected unknown_action "$u2_unknown" "$tmp/u2-unknown-action"
  u2_expired=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000003 $((u2_now - 600)) $((u2_now - 300)))
  u2_expect_rejected expired_request "$u2_expired" "$tmp/u2-expired"
  u2_wrong_node=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000004 "$u2_now" $((u2_now + 300)) node-b)
  u2_expect_rejected signature_verification_failed "$u2_wrong_node" "$tmp/u2-wrong-node"

  u2_changed=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000005 "$u2_now" $((u2_now + 300)))
  sed 's/target-host-id|test-apt/target-host-id|other-host/' "$u2_changed" >"$tmp/u2-changed-bytes"
  u2_expect_rejected host_identity_mismatch "$tmp/u2-changed-bytes" "$tmp/u2-changed-result"

  u2_policy_active="$u2_root/etc/roundhouse/generations/1/policy.actions"
  u2_policy_active_mode=$(test_file_mode "$u2_policy_active")
  cp -p "$u2_policy_active" "$tmp/u2-policy-backup"
  printf '%s\n' '# drift' >>"$u2_policy_active"
  u2_policy_drift=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000006 "$u2_now" $((u2_now + 300)))
  u2_expect_rejected policy_or_context_drift "$u2_policy_drift" "$tmp/u2-policy-drift"
  mv "$tmp/u2-policy-backup" "$u2_policy_active"
  [ "$(test_file_mode "$u2_policy_active")" = "$u2_policy_active_mode" ] ||
    fail "U2 policy-drift fixture did not restore exact metadata"

  u2_apt_active="$u2_root/etc/roundhouse/generations/1/apt.conf"
  u2_apt_active_mode=$(test_file_mode "$u2_apt_active")
  cp -p "$u2_apt_active" "$tmp/u2-apt-backup"
  printf '%s\n' 'APT::Update::Pre-Invoke { "touch /tmp/forbidden"; };' >>"$u2_apt_active"
  u2_hook=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000007 "$u2_now" $((u2_now + 300)))
  u2_expect_rejected apt_configuration_hook_drift "$u2_hook" "$tmp/u2-hook-drift"
  mv "$tmp/u2-apt-backup" "$u2_apt_active"
  [ "$(test_file_mode "$u2_apt_active")" = "$u2_apt_active_mode" ] ||
    fail "U2 APT-hook fixture did not restore exact metadata"

  mv "$u2_root/var/lib/roundhouse/audit/events.log" "$tmp/u2-audit-log"
  mkdir "$u2_root/var/lib/roundhouse/audit/events.log"
  u2_audit=$(u2_make_envelope apt.update-metadata.v1 \
    request-00000000000000000000000000000008 "$u2_now" $((u2_now + 300)))
  u2_expect_rejected audit_write_failed "$u2_audit" "$tmp/u2-audit-failure"
  mv "$u2_root/var/lib/roundhouse/audit/events.log" "$tmp/u2-blocked-audit"
  mv "$tmp/u2-audit-log" "$u2_root/var/lib/roundhouse/audit/events.log"
  if find "$u2_root/var/lib/roundhouse/audit" -mindepth 1 -maxdepth 1 \
      -name '.events.*' -print | grep -q .; then
    fail "U2 failed audit projection left a temporary"
  fi

  u2_build2="$tmp/u2-bundle-2"
  u2_generation2="$u2_root/etc/roundhouse/generations/2"
  cp -Rp "$u2_bundle" "$u2_build2"
  rm -f "$u2_build2/bootstrap.manifest" "$u2_build2/bootstrap.manifest.sig"
  printf 'constraints|1|generation=2|policy-sha256=%s\n' "$u2_policy_digest" \
    >"$u2_build2/policy.constraints"
  sed "s#/generations/1/#/generations/2/#g" "$u2_build2/apt.conf" >"$tmp/u2-apt2.conf"
  mv "$tmp/u2-apt2.conf" "$u2_build2/apt.conf"
  sed "s#/generations/1/#/generations/2/#g" \
    "$u2_build2/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-sources2"
  mv "$tmp/u2-sources2" "$u2_build2/apt/sources.list.d/roundhouse.sources"
  chmod 644 "$u2_build2/apt/sources.list.d/roundhouse.sources"
  cp "$u2_build2/apt.conf" "$u2_build2/apt/effective.dump"
  u2_apt_config2_digest=$(u2_sha256 "$u2_build2/apt.conf")
  u2_effective_config2_digest=$(u2_sha256 "$u2_build2/apt/effective.dump")
  u2_sources2_digest=$(u2_path_set_digest source-main "$u2_build2/apt/sources.list" \
    source-parts "$u2_build2/apt/sources.list.d")
  awk -F '|' -v OFS='|' -v config_digest="$u2_apt_config2_digest" \
      -v effective_digest="$u2_effective_config2_digest" -v sources_digest="$u2_sources2_digest" '
    $1=="config-file-sha256"{$2=config_digest}
    $1=="effective-config-sha256"{$2=effective_digest}
    $1=="sources-sha256"{$2=sources_digest}
    {print}
  ' "$u2_build2/apt.context" >"$tmp/u2-apt2.context"
  mv "$tmp/u2-apt2.context" "$u2_build2/apt.context"
  : >"$u2_build2/bootstrap.manifest"
  for u2_relative in allowed_signers apt.conf apt.context apt/effective.dump apt/preferences \
    apt/metadata/Release apt/metadata/Release.gpg apt/preferences.d/00-roundhouse \
    apt/source-authority apt/source-identities apt/sources.list \
    apt/sources.list.d/roundhouse.sources apt/trusted.gpg.d/fleet.gpg \
    context.canary enroll-privilege-posix fleet-ca.pub \
    host.identity policy.actions policy.constraints privilege-broker-posix revoked.krl; do
    printf 'file|%s|%s\n' "$u2_relative" "$(u2_sha256 "$u2_build2/$u2_relative")"
  done | LC_ALL=C sort -t '|' -k2,2 >"$u2_build2/bootstrap.manifest"
  u2_manifest2_digest=$(u2_sha256 "$u2_build2/bootstrap.manifest")
  "$ssh_keygen" -Y sign -f "$tmp/u2-release-key" -n roundhouse-release \
    "$u2_build2/bootstrap.manifest" >/dev/null
  u2_bundle2="$u2_bootstrap/staged/$u2_manifest2_digest"
  mv "$u2_build2" "$u2_bundle2"
  printf 'bootstrap|1|manifest-sha256=%s|release-principal=roundhouse-release\n' \
    "$u2_manifest2_digest" >"$u2_bootstrap/receipts/$u2_manifest2_digest"
  chmod -R go-w "$u2_root"
  printf '%064d\n' 0 >"$u2_generation/ssh-keygen.sha256"
  if ! ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_bundle2" \
      >"$tmp/u2-preview2"; then
    cat "$tmp/u2-preview2" >&2
    fail "U2 generation-2 upgrade preview was rejected"
  fi
  grep -Fqx 'from-epoch|1' "$tmp/u2-preview2" && grep -Fqx 'to-epoch|2' "$tmp/u2-preview2" ||
    fail "U2 upgrade preview did not describe the generation transition"
  u2_confirmation2_digest=$(awk -F '|' '$1=="confirmation-sha256"{print $2}' "$tmp/u2-preview2")

  u2_under_lock_before=$(u2_enrollment_state_digest)
  u2_candidate_policy_mode=$(test_file_mode "$u2_bundle2/policy.actions")
  cp -p "$u2_bundle2/policy.actions" "$tmp/u2-candidate-policy-before-lock-race"
  u2_pause_marker="$tmp/u2-candidate-lock-race"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=lifecycle-lock-held \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle2" "$u2_manifest2_digest" "$u2_confirmation2_digest" \
    >"$tmp/u2-candidate-lock-race-result" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  printf '%s\n' '# authenticated bytes changed after the pre-lock check' >>"$u2_bundle2/policy.actions"
  touch "$u2_pause_marker.continue"
  if wait "$u2_pause_job"; then
    fail "U2 install accepted candidate bytes changed while waiting under lock"
  fi
  mv "$tmp/u2-candidate-policy-before-lock-race" "$u2_bundle2/policy.actions"
  [ "$(test_file_mode "$u2_bundle2/policy.actions")" = "$u2_candidate_policy_mode" ] ||
    fail "U2 candidate race fixture did not restore exact metadata"
  grep -Fqx 'reason|under_lock_authenticated_bootstrap_failed' "$tmp/u2-candidate-lock-race-result" &&
    [ "$(u2_enrollment_state_digest)" = "$u2_under_lock_before" ] ||
    fail "U2 under-lock candidate revalidation mutated enrolled state"

  u2_live_policy_mode=$(test_file_mode "$u2_generation/policy.actions")
  cp -p "$u2_generation/policy.actions" "$tmp/u2-live-policy-before-lock-race"
  u2_pause_marker="$tmp/u2-live-lock-race"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=lifecycle-lock-held \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle2" "$u2_manifest2_digest" "$u2_confirmation2_digest" \
    >"$tmp/u2-live-lock-race-result" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  printf '%s\n' '# live state changed after human confirmation' >>"$u2_generation/policy.actions"
  touch "$u2_pause_marker.continue"
  if wait "$u2_pause_job"; then
    fail "U2 install accepted live state changed after confirmation"
  fi
  grep -Fqx 'reason|under_lock_confirmation_digest_mismatch' "$tmp/u2-live-lock-race-result" &&
    [ ! -e "$u2_root/var/lib/roundhouse/draining" ] ||
    fail "U2 under-lock confirmation recompute did not fail before mutation"
  mv "$tmp/u2-live-policy-before-lock-race" "$u2_generation/policy.actions"
  [ "$(test_file_mode "$u2_generation/policy.actions")" = "$u2_live_policy_mode" ] ||
    fail "U2 live-state race fixture did not restore exact metadata"
  [ "$(u2_enrollment_state_digest)" = "$u2_under_lock_before" ] ||
    fail "U2 under-lock current-state race was not exactly recoverable"

  u2_reboot_before=$(u2_enrollment_state_digest)
  mkdir "$u2_root/var/lib/roundhouse-lifecycle.lock"
  chmod 700 "$u2_root/var/lib/roundhouse-lifecycle.lock"
  cat >"$u2_root/var/lib/roundhouse-lifecycle.lock/owner" <<'EOF'
lifecycle-owner|2
boot-id|0000000000000000000000000000000000000000000000000000000000000000
pid|1
process-start|0000000000000000000000000000000000000000000000000000000000000000
operation|install
EOF
  chmod 600 "$u2_root/var/lib/roundhouse-lifecycle.lock/owner"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" install "$u2_bundle2" "$u2_manifest2_digest" "$u2_confirmation2_digest" \
      >"$tmp/u2-reboot-recovery" 2>/dev/null; then
    fail "U2 simulated reboot recovery passed its forced failpoint"
  fi
  [ "$(u2_enrollment_state_digest)" = "$u2_reboot_before" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] ||
    fail "U2 boot-bound stale owner recovery did not restore exact state"
  u2_upgrade_before=$(u2_enrollment_state_digest)
  for u2_failpoint in after-drain after-generation after-broker after-trust after-sudoers \
    after-active after-public-receipt; do
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT="$u2_failpoint" \
        "$enrollment" install "$u2_bundle2" "$u2_manifest2_digest" "$u2_confirmation2_digest" \
        >"$tmp/u2-upgrade-$u2_failpoint" 2>/dev/null; then
      fail "U2 upgrade failpoint completed: $u2_failpoint"
    fi
    [ "$(u2_enrollment_state_digest)" = "$u2_upgrade_before" ] &&
      [ ! -e "$u2_root/var/lib/roundhouse/draining" ] &&
      [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] ||
      fail "U2 upgrade rollback changed the previous generation at $u2_failpoint"
  done

  mkdir "$u2_root/var/lib/roundhouse/lock/active"
  chmod 700 "$u2_root/var/lib/roundhouse/lock/active"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle2" \
      "$u2_manifest2_digest" "$u2_confirmation2_digest" >"$tmp/u2-upgrade-draining" 2>/dev/null; then
    fail "U2 upgrade ignored an active admission"
  fi
  grep -Fqx 'state|draining' "$tmp/u2-upgrade-draining" &&
    [ -f "$u2_root/var/lib/roundhouse/draining" ] ||
    fail "U2 upgrade did not preserve its exact resumable drain"
  [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/1 ] ||
    fail "U2 draining upgrade changed the active generation"
  rmdir "$u2_root/var/lib/roundhouse/lock/active"
  if ! ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle2" \
      "$u2_manifest2_digest" "$u2_confirmation2_digest" >"$tmp/u2-upgraded"; then
    cat "$tmp/u2-upgraded" >&2
    fail "U2 resumable upgrade was rejected"
  fi
  [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/2 ] &&
    [ -d "$u2_generation2" ] && [ ! -e "$u2_root/var/lib/roundhouse/draining" ] ||
    fail "U2 resumable upgrade did not activate generation 2"
  [ "$(sed -n '1p' "$u2_generation2/ssh-keygen.sha256")" = "$(u2_sha256 /usr/bin/ssh-keygen)" ] ||
    fail "U2 authenticated upgrade did not repair the OpenSSH attestation"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-upgraded-readiness none >"$tmp/u2-upgraded-readiness.jsonl"
  [ "$(jq -r 'select(.kind=="privilege_broker") | [.data.lifecycle_status,.data.enrollment_epoch] | @tsv' \
    "$tmp/u2-upgraded-readiness.jsonl")" = "$(printf 'ready\t2')" ] ||
    fail "U2 collector did not validate the upgraded generation"

  printf '%064d\n' 0 >"$u2_generation2/ssh-keygen.sha256"
  u2_pause_marker="$tmp/u2-revocation-reserve-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=revocation-reserve-released \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
    >"$tmp/u2-revocation-reserve-result" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job" "$tmp/u2-revocation-reserve-result"
  [ ! -e "$u2_revocation_reserve" ] &&
    [ "$(awk -F '|' '$1=="operation"{print $2}' \
      "$u2_root/var/lib/roundhouse-lifecycle.lock/owner")" = revoke ] ||
    fail "U2 revocation did not release its same-filesystem reserve under the lifecycle lock"
  u2_pause_owner=$(awk -F '[|=]' 'NR==1&&$1=="pause"&&$2=="1"&&$3=="point"&&$5=="pid"{print $6}' \
    "$u2_pause_marker")
  kill -TERM "$u2_pause_owner"
  wait "$u2_pause_job" 2>/dev/null || true
  rm -f "$u2_pause_marker" "$u2_pause_marker.continue" "$u2_pause_marker.kill"
  [ "$(stat -c %s "$u2_revocation_reserve" 2>/dev/null || stat -f %z "$u2_revocation_reserve")" -eq 4194304 ] &&
    [ $((($(stat -c %b "$u2_revocation_reserve" 2>/dev/null || stat -f %b "$u2_revocation_reserve")) * 512)) -ge 1048576 ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/2 ] ||
    fail "U2 interrupted pre-intent revocation did not restore its emergency reserve and enrollment"

  u2_pause_marker="$tmp/u2-revocation-reserve-prepared-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_FAILPOINT=after-drain \
    ROUNDHOUSE_U2_PAUSE_AT=revocation-reserve-prepared \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
    >"$tmp/u2-revocation-reserve-prepared-result" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job" \
    "$tmp/u2-revocation-reserve-prepared-result"
  [ -f "$u2_root/var/lib/roundhouse/.revocation.reserve.pending" ] &&
    [ ! -e "$u2_revocation_reserve" ] ||
    fail "U2 reserve restoration did not stage before its atomic rename"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
      >"$tmp/u2-revocation-reserve-prepared-recovery" 2>/dev/null; then
    fail "U2 reserve-temp recovery unexpectedly passed its forced failpoint"
  fi
  [ ! -e "$u2_root/var/lib/roundhouse/.revocation.reserve.pending" ] &&
    [ "$(stat -c %s "$u2_revocation_reserve" 2>/dev/null || stat -f %z "$u2_revocation_reserve")" -eq 4194304 ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/draining" ] &&
    [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/2 ] ||
    fail "U2 killed reserve-temp restoration did not recover atomically"

  u2_revoke_crash_before=$(u2_enrollment_state_digest)
  u2_pause_marker="$tmp/u2-revoke-lock-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=lifecycle-lock-held \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
    >"$tmp/u2-revoke-lock-owner" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  u2_revoke_contention_before=$(u2_enrollment_state_digest)
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" revoke "$u2_bundle2" \
      "$u2_manifest2_digest" 2 >"$tmp/u2-revoke-contention" 2>/dev/null; then
    fail "U2 concurrent revoke acquired the live lifecycle lock"
  else
    u2_revoke_contention_rc=$?
  fi
  u2_revoke_contention_after=$(u2_enrollment_state_digest)
  if [ "$u2_revoke_contention_rc" -ne 75 ] ||
    ! grep -Fqx 'reason|lifecycle_operation_in_progress' "$tmp/u2-revoke-contention" ||
    [ "$u2_revoke_contention_after" != "$u2_revoke_contention_before" ]; then
    cat "$tmp/u2-revoke-contention" >&2
    printf 'U2 revoke contention rc=%s before=%s after=%s\n' "$u2_revoke_contention_rc" \
      "$u2_revoke_contention_before" "$u2_revoke_contention_after" >&2
    fail "U2 live revoke contention did not return 75 with exact unchanged state"
  fi
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"

  u2_pause_marker="$tmp/u2-revoke-mutation-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=revoke-after-quarantine \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
    >"$tmp/u2-revoke-killed" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  [ -f "$u2_root/var/lib/roundhouse-lifecycle.lock/transaction" ] &&
    [ -d "$u2_root/var/lib/roundhouse/quarantine/revoked-2-$u2_manifest2_digest" ] &&
    [ ! -e "$u2_root/etc/roundhouse/active" ] ||
    fail "U2 revoke mutation pause lacked durable quarantined transaction evidence"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"

  u2_pause_marker="$tmp/u2-revoke-recovery-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=recovery-claimed \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
    >"$tmp/u2-revoke-recovery-killed" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"

  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
      >"$tmp/u2-revoke-recovered" 2>/dev/null; then
    fail "U2 recovered revoke unexpectedly passed its after-drain failpoint"
  fi
  [ "$(u2_enrollment_state_digest)" = "$u2_revoke_crash_before" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/draining" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/quarantine/revoked-2-$u2_manifest2_digest" ] ||
    fail "U2 repeated revoke SIGKILL recovery did not restore exact enrolled state"

  u2_revoke_before=$(u2_enrollment_state_digest)
  cp "$tmp/u2-enrollment-state" "$tmp/u2-revoke-before-state"
  for u2_failpoint in revoke-after-sudoers revoke-after-quarantine revoke-after-public-status; do
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT="$u2_failpoint" \
        "$enrollment" revoke "$u2_bundle2" "$u2_manifest2_digest" 2 \
        >"$tmp/u2-revoke-$u2_failpoint" 2>/dev/null; then
      fail "U2 revoke failpoint completed: $u2_failpoint"
    fi
    u2_revoke_after=$(u2_enrollment_state_digest)
    if [ "$u2_revoke_after" != "$u2_revoke_before" ] ||
      [ -e "$u2_root/var/lib/roundhouse/draining" ] ||
      [ -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ]; then
      diff -u "$tmp/u2-revoke-before-state" "$tmp/u2-enrollment-state" >&2 || true
      fail "U2 revoke rollback did not restore the enrollment at $u2_failpoint"
    fi
  done

  mkdir "$u2_root/var/lib/roundhouse/lock/active"
  chmod 700 "$u2_root/var/lib/roundhouse/lock/active"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" revoke "$u2_bundle2" \
      "$u2_manifest2_digest" 2 >"$tmp/u2-revoke-draining" 2>/dev/null; then
    fail "U2 revocation ignored active work"
  fi
  grep -Fqx 'state|draining' "$tmp/u2-revoke-draining" ||
    fail "U2 revocation did not report draining"
  [ -x "$u2_root/usr/libexec/roundhouse/posix-broker" ] ||
    fail "U2 draining revocation removed the active broker"
  rmdir "$u2_root/var/lib/roundhouse/lock/active"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" revoke "$u2_bundle2" \
    "$u2_manifest2_digest" 2 >"$tmp/u2-revoked"
  grep -Fqx 'state|revoked' "$tmp/u2-revoked" || fail "U2 revocation did not complete"
  [ ! -e "$u2_root/usr/libexec/roundhouse/posix-broker" ] &&
    [ ! -e "$u2_root/etc/sudoers.d/roundhouse-posix-broker" ] &&
    [ ! -e "$u2_root/etc/roundhouse/active" ] &&
    [ ! -e "$u2_root/etc/roundhouse/generations/2" ] &&
    [ ! -e "$u2_root/etc/roundhouse/trust/fleet-ca.pub" ] ||
    fail "U2 revocation left a privileged grant, generation, or trust root"
  [ -d "$u2_root/var/lib/roundhouse/quarantine/revoked-2-$u2_manifest2_digest" ] ||
    fail "U2 revocation did not retain its protected quarantine"
  [ ! -e "$u2_revocation_reserve" ] || fail "U2 completed revocation retained its emergency reserve"
  [ -f "$u2_root/var/lib/roundhouse/journal/request-00000000000000000000000000000001.result" ] ||
    fail "U2 revocation discarded protected result evidence"
  if find "$u2_root/var/lib/roundhouse" \
      \( -name '.claim-*' -o -name '.revocation.reserve.*' -o -name 'launch.gate' -o -name 'terminal.reserve' \) \
      -print | grep -q .; then
    fail "U2 final residue scan found claim staging, reserve staging, launch gates, or terminal reserves"
  fi
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-revoked-readiness none >"$tmp/u2-revoked-readiness.jsonl"
  [ "$(jq -r 'select(.kind=="privilege_broker") | .data.lifecycle_status' \
    "$tmp/u2-revoked-readiness.jsonl")" = needs_enrollment ] &&
    [ "$(jq -r 'select(.kind=="privilege_broker") | .data.transport_ready' \
    "$tmp/u2-revoked-readiness.jsonl")" = false ] ||
    fail "U2 collector overclaimed readiness after transactional revocation"
  ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-host u2-macos-readiness none >"$tmp/u2-macos-readiness.jsonl"
  jq -e 'select(.kind=="privilege_broker") |
    .data.lifecycle_status == "needs_enrollment" and
    .data.platform_adapter == "posix-sudo-v1" and
    .data.broker_ready == false and .data.action_context_ready == false and
    .data.observed_action_contexts == []' "$tmp/u2-macos-readiness.jsonl" >/dev/null ||
    fail "U2 collector did not keep unenrolled macOS actions inactive"
}

# One 2,150-line function until this split. The three parts run in order
# and share the globals the first one sets, so the sequence a scoped run
# sees is unchanged.
test_u2_contracts() {
  test_u2_broker_contracts
  test_u2_enrollment_contracts
  test_u2_collector_contracts
}

[ "${ROUNDHOUSE_TEST_SCOPE:-}" != u2-contracts ] || {
  test_u2_contracts
  printf 'PASS: U2 contracts\n'
  exit 0
}
