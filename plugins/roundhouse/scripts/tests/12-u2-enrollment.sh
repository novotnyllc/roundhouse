# roundhouse self-check — U2 — enrollment: bootstrap preview, install
# collisions and rollback.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

test_u2_enrollment_contracts() {
  if ! ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_bundle" \
      >"$tmp/u2-preview"; then
    cat "$tmp/u2-preview" >&2
    fail "U2 authenticated bootstrap preview failed"
  fi
  grep -Fqx "change|policy|absent|$u2_policy_digest" "$tmp/u2-preview" ||
    fail "U2 enrollment preview omitted the semantic policy change"
  grep -Fqx "apt-source|uri=https://packages.example.invalid/debian|suite=stable|component=main|publisher-primary-fingerprint=$u2_publisher_fingerprint" \
    "$tmp/u2-preview" || fail "U2 enrollment preview omitted bound APT source authority"
  u2_confirmation_digest=$(awk -F '|' '$1=="confirmation-sha256"{print $2}' "$tmp/u2-preview")
  [ "${#u2_confirmation_digest}" -eq 64 ] || fail "U2 enrollment preview omitted its confirmation digest"
  for u2_preview_binding in uri suite component publisher; do
    u2_attack_build="$tmp/u2-preview-binding-$u2_preview_binding"
    cp -R "$u2_bundle" "$u2_attack_build"
    case $u2_preview_binding in
      uri)
        sed 's#^URIs: .*$#URIs: https://packages.example.invalid/debian-updates#' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-preview-source"
        mv "$tmp/u2-preview-source" "$u2_attack_build/apt/sources.list.d/roundhouse.sources"
        ;;
      suite)
        sed 's/^Suites: stable$/Suites: testing/' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-preview-source"
        mv "$tmp/u2-preview-source" "$u2_attack_build/apt/sources.list.d/roundhouse.sources"
        sed 's/^Suite: stable$/Suite: testing/' "$u2_attack_build/apt/metadata/Release" \
          >"$tmp/u2-preview-release"
        mv "$tmp/u2-preview-release" "$u2_attack_build/apt/metadata/Release"
        ;;
      component)
        sed 's/^Components: main$/Components: contrib/' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-preview-source"
        mv "$tmp/u2-preview-source" "$u2_attack_build/apt/sources.list.d/roundhouse.sources"
        ;;
      publisher)
        sed 's/[0-9A-F]\{40\}$/FEDCBA9876543210FEDCBA9876543210FEDCBA98/' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-preview-source"
        mv "$tmp/u2-preview-source" "$u2_attack_build/apt/sources.list.d/roundhouse.sources"
        awk -F '|' -v OFS='|' '$1=="primary-fingerprint"{$2="FEDCBA9876543210FEDCBA9876543210FEDCBA98"}{print}' \
          "$u2_attack_build/apt/metadata/Release.gpg" >"$tmp/u2-preview-signature"
        mv "$tmp/u2-preview-signature" "$u2_attack_build/apt/metadata/Release.gpg"
        ;;
    esac
    chmod 644 "$u2_attack_build/apt/sources.list.d/roundhouse.sources" \
      "$u2_attack_build/apt/metadata/Release" "$u2_attack_build/apt/metadata/Release.gpg"
    u2_rebind_apt_authority "$u2_attack_build"
    u2_stage_candidate "$u2_attack_build"
    ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_staged_candidate" \
      >"$tmp/u2-preview-binding-$u2_preview_binding-result" ||
      fail "U2 valid APT preview binding failed: $u2_preview_binding"
    u2_binding_confirmation=$(awk -F '|' '$1=="confirmation-sha256"{print $2}' \
      "$tmp/u2-preview-binding-$u2_preview_binding-result")
    [ "$u2_binding_confirmation" != "$u2_confirmation_digest" ] ||
      fail "U2 APT preview binding did not alter confirmation: $u2_preview_binding"
  done
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle" \
      "$u2_manifest_digest" "$(printf '0%.0s' {1..64})" >"$tmp/u2-wrong-confirmation" 2>/dev/null; then
    fail "U2 enrollment accepted an unconfirmed policy digest"
  fi
  [ ! -e "$u2_root/etc/roundhouse/active" ] ||
    fail "U2 failed confirmation changed active state"

  mkdir -p "$u2_root/var/lib/roundhouse"
  printf '%s\n' unrelated-survives >"$u2_root/var/lib/roundhouse/unrelated-lifecycle-sentinel"
  chmod 600 "$u2_root/var/lib/roundhouse/unrelated-lifecycle-sentinel"
  for u2_collision_kind in final staging staging-prepare backup backup-prepare; do
    case $u2_collision_kind in
      final)
        u2_collision_path="$u2_root/etc/roundhouse/generations/1"
        u2_collision_mode=755
        ;;
      staging)
        u2_collision_path="$u2_root/etc/roundhouse/generations/.staging-1-$u2_manifest_digest"
        u2_collision_mode=755
        ;;
      staging-prepare)
        u2_collision_path="$u2_root/etc/roundhouse/generations/.staging-1-$u2_manifest_digest.prepare"
        u2_collision_mode=755
        ;;
      backup)
        u2_collision_path="$u2_root/var/lib/roundhouse/rollback/install-0-1-$u2_manifest_digest"
        u2_collision_mode=700
        ;;
      backup-prepare)
        u2_collision_path="$u2_root/var/lib/roundhouse/rollback/install-0-1-$u2_manifest_digest.prepare"
        u2_collision_mode=700
        ;;
    esac
    mkdir -p "$u2_collision_path"
    chmod "$u2_collision_mode" "$u2_collision_path"
    printf 'collision|%s\n' "$u2_collision_kind" >"$u2_collision_path/unrelated"
    chmod 600 "$u2_collision_path/unrelated"
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle" \
        "$u2_manifest_digest" "$u2_confirmation_digest" \
        >"$tmp/u2-collision-$u2_collision_kind" 2>/dev/null; then
      fail "U2 install accepted pre-intent artifact collision: $u2_collision_kind"
    else
      u2_collision_rc=$?
    fi
    [ "$u2_collision_rc" -eq 74 ] &&
      grep -Fqx 'reason|transaction_artifact_collision' "$tmp/u2-collision-$u2_collision_kind" &&
      grep -Fqx "collision|$u2_collision_kind" "$u2_collision_path/unrelated" &&
      grep -Fqx unrelated-survives "$u2_root/var/lib/roundhouse/unrelated-lifecycle-sentinel" ||
      fail "U2 collision handling was not deterministic and non-destructive: $u2_collision_kind"
    rm -rf "$u2_collision_path"
  done

  u2_restore_collision="$u2_root/usr/libexec/roundhouse/posix-broker.rollback.install-0-1-$u2_manifest_digest"
  printf '%s\n' rollback-temp-collision-survives >"$u2_restore_collision"
  chmod 600 "$u2_restore_collision"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle" \
      "$u2_manifest_digest" "$u2_confirmation_digest" >"$tmp/u2-rollback-temp-collision" 2>/dev/null; then
    fail "U2 install accepted a pre-intent rollback-temp collision"
  else
    u2_restore_collision_rc=$?
  fi
  [ "$u2_restore_collision_rc" -eq 74 ] &&
    grep -Fqx 'reason|transaction_artifact_collision' "$tmp/u2-rollback-temp-collision" &&
    grep -Fqx rollback-temp-collision-survives "$u2_restore_collision" ||
    fail "U2 rollback-temp collision was not deterministic and non-destructive"
  rm "$u2_restore_collision"

  u2_pause_marker="$tmp/u2-prepare-before-owner-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=lifecycle-prepare-before-owner \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-prepare-before-owner" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  [ -d "$u2_root/var/lib/.roundhouse-lifecycle.lock.prepare" ] &&
    [ ! -e "$u2_root/var/lib/.roundhouse-lifecycle.lock.prepare/owner" ] ||
    fail "U2 prepare crash seam was not ownerless and bounded"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"
  printf '%s\n' partial-owner-record > \
    "$u2_root/var/lib/.roundhouse-lifecycle.lock.prepare/.owner.424242"
  chmod 600 "$u2_root/var/lib/.roundhouse-lifecycle.lock.prepare/.owner.424242"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
      >"$tmp/u2-prepare-recovered" 2>/dev/null; then
    fail "U2 prepare recovery unexpectedly passed its failpoint"
  fi
  if [ -e "$u2_root/var/lib/.roundhouse-lifecycle.lock.prepare" ] ||
    [ -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ]; then
    cat "$tmp/u2-prepare-recovered" >&2
    find "$u2_root/var/lib" -maxdepth 3 -name '*lifecycle*' -print >&2
    fail "U2 prepare-before-owner SIGKILL did not recover narrowly"
  fi

  u2_pause_marker="$tmp/u2-backup-prepare-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=backup-prepare-before-marker \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-backup-prepare" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  u2_backup_prepare="$u2_root/var/lib/roundhouse/rollback/install-0-1-$u2_manifest_digest.prepare"
  [ -d "$u2_backup_prepare" ] &&
    [ -z "$(find "$u2_backup_prepare" -mindepth 1 -maxdepth 1 -print)" ] ||
    fail "U2 backup prepare seam was not empty before marker publication"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
      >"$tmp/u2-backup-prepare-recovered" 2>/dev/null; then
    fail "U2 backup prepare recovery unexpectedly passed its failpoint"
  fi
  [ ! -e "$u2_backup_prepare" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/rollback/install-0-1-$u2_manifest_digest" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] ||
    fail "U2 backup prepare SIGKILL did not recover narrowly"

  u2_pause_marker="$tmp/u2-lock-retirement-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
    ROUNDHOUSE_U2_PAUSE_AT=lifecycle-lock-retired \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-lock-retirement" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  [ -d "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] ||
    fail "U2 lock retirement was not atomic before deletion"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
      >"$tmp/u2-lock-retirement-recovered" 2>/dev/null; then
    fail "U2 lock retirement retry unexpectedly passed its failpoint"
  fi
  [ ! -e "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired" ] ||
    fail "U2 orphan lock retirement was not finished idempotently"

  u2_pause_marker="$tmp/u2-retirement-failure-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=lifecycle-lock-held \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" revoke "$u2_bundle" "$u2_manifest_digest" 1 \
    >"$tmp/u2-retirement-failure" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  mkdir "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired"
  chmod 700 "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired"
  printf '%s\n' retirement-collision-survives \
    >"$u2_root/var/lib/.roundhouse-lifecycle.lock.retired/unexpected"
  chmod 600 "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired/unexpected"
  touch "$u2_pause_marker.continue"
  if wait "$u2_pause_job"; then
    fail "U2 successful unenrolled revoke ignored lifecycle retirement failure"
  else
    u2_retirement_failure_rc=$?
  fi
  [ "$u2_retirement_failure_rc" -eq 74 ] &&
    grep -Fqx 'reason|lifecycle_lock_retirement_failed' "$tmp/u2-retirement-failure" &&
    ! grep -Fqx 'state|revoked' "$tmp/u2-retirement-failure" &&
    grep -Fqx retirement-collision-survives \
      "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired/unexpected" &&
    [ -d "$u2_root/var/lib/roundhouse-lifecycle.lock" ] ||
    fail "U2 retirement failure emitted success or destroyed unrelated state"
  rm "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired/unexpected"
  if ! ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
      "$enrollment" revoke "$u2_bundle" "$u2_manifest_digest" 1 \
      >"$tmp/u2-retirement-failure-retry" 2>/dev/null; then
    fail "U2 exact-empty retirement retry did not recover"
  fi
  grep -Fqx 'state|revoked' "$tmp/u2-retirement-failure-retry" &&
    grep -Fqx 'reason|already_not_enrolled' "$tmp/u2-retirement-failure-retry" &&
    [ ! -e "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] ||
    fail "U2 retirement failure retry did not clean exact bounded artifacts"

  u2_pause_marker="$tmp/u2-retirement-member-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=lifecycle-lock-held \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" revoke "$u2_bundle" "$u2_manifest_digest" 1 \
    >"$tmp/u2-retirement-member" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  printf '%s\n' canonical-retirement-member-survives \
    >"$u2_root/var/lib/roundhouse-lifecycle.lock/unexpected"
  chmod 600 "$u2_root/var/lib/roundhouse-lifecycle.lock/unexpected"
  touch "$u2_pause_marker.continue"
  if wait "$u2_pause_job"; then
    fail "U2 retirement accepted a canonical lifecycle sibling"
  else
    u2_retirement_member_rc=$?
  fi
  [ "$u2_retirement_member_rc" -eq 74 ] &&
    grep -Fqx 'reason|lifecycle_lock_retirement_failed' "$tmp/u2-retirement-member" &&
    ! grep -Fqx 'state|revoked' "$tmp/u2-retirement-member" &&
    grep -Fqx canonical-retirement-member-survives \
      "$u2_root/var/lib/roundhouse-lifecycle.lock/unexpected" &&
    [ ! -e "$u2_root/var/lib/.roundhouse-lifecycle.lock.retired" ] ||
    fail "U2 retirement moved or destroyed an invalid canonical lifecycle directory"
  rm "$u2_root/var/lib/roundhouse-lifecycle.lock/unexpected"
  if ! ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
      "$enrollment" revoke "$u2_bundle" "$u2_manifest_digest" 1 \
      >"$tmp/u2-retirement-member-retry" 2>/dev/null; then
    fail "U2 canonical retirement-member retry did not recover"
  fi
  grep -Fqx 'state|revoked' "$tmp/u2-retirement-member-retry" &&
    grep -Fqx 'reason|already_not_enrolled' "$tmp/u2-retirement-member-retry" &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] ||
    fail "U2 canonical retirement-member retry left lifecycle artifacts"

  mkdir -p "$u2_root/var/lib/roundhouse/lock/active"
  chmod 700 "$u2_root/var/lib/roundhouse/lock/active"
  u2_pause_marker="$tmp/u2-parked-drain-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=lifecycle-parked \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-parked-drain-owner" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  [ -f "$u2_root/var/lib/roundhouse-lifecycle.recovery/transaction" ] &&
    [ "$(awk -F '|' '$1=="phase"{print $2}' "$u2_root/var/lib/roundhouse-lifecycle.recovery/transaction")" = waiting ] &&
    [ -f "$u2_root/var/lib/roundhouse/draining" ] ||
    fail "U2 parked drain lost durable transaction authority"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-parked-readiness none >"$tmp/u2-parked-readiness.jsonl"
  [ "$(jq -r 'select(.kind=="privilege_broker") | [.data.lifecycle_status,.data.lifecycle_activity.phase,.data.broker_ready,.data.protected_artifacts_ready] | @tsv' \
    "$tmp/u2-parked-readiness.jsonl")" = "$(printf 'draining\twaiting\tfalse\tfalse')" ] ||
    fail "U2 collector overclaimed readiness during a parked drain"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle" \
      "$u2_manifest_digest" "$u2_confirmation_digest" >"$tmp/u2-parked-still-active" 2>/dev/null; then
    fail "U2 parked drain proceeded while the active request remained"
  else
    u2_parked_rc=$?
  fi
  [ "$u2_parked_rc" -eq 75 ] &&
    grep -Fqx 'reason|active_request_must_settle' "$tmp/u2-parked-still-active" &&
    [ -f "$u2_root/var/lib/roundhouse-lifecycle.recovery/transaction" ] ||
    fail "U2 parked drain retry did not preserve authority"
  rmdir "$u2_root/var/lib/roundhouse/lock/active"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
      >"$tmp/u2-parked-settled" 2>/dev/null; then
    fail "U2 settled parked drain unexpectedly passed its failpoint"
  fi
  [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/draining" ] ||
    fail "U2 settled parked drain did not finalize idempotently"

  for u2_failpoint in after-drain after-generation after-broker after-trust after-sudoers \
    after-active after-public-receipt; do
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT="$u2_failpoint" \
        "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
        >"$tmp/u2-first-install-$u2_failpoint" 2>/dev/null; then
      fail "U2 first-install failpoint completed: $u2_failpoint"
    fi
    [ ! -e "$u2_root/etc/roundhouse/active" ] &&
      [ ! -e "$u2_root/etc/roundhouse/generations/1" ] &&
      [ ! -e "$u2_root/usr/libexec/roundhouse/posix-broker" ] &&
      [ ! -e "$u2_root/etc/sudoers.d/roundhouse-posix-broker" ] &&
      [ ! -e "$u2_root/var/lib/roundhouse/draining" ] &&
      [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] ||
      fail "U2 first-install rollback was incomplete at $u2_failpoint"
  done

  u2_pause_marker="$tmp/u2-install-lock-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=lifecycle-lock-held \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-install-lock-owner" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  u2_contention_before=$(u2_enrollment_state_digest)
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle" \
      "$u2_manifest_digest" "$u2_confirmation_digest" >"$tmp/u2-install-contention" 2>/dev/null; then
    fail "U2 concurrent install acquired the live lifecycle lock"
  else
    u2_contention_rc=$?
  fi
  u2_contention_after=$(u2_enrollment_state_digest)
  if [ "$u2_contention_rc" -ne 75 ] ||
    ! grep -Fqx 'reason|lifecycle_operation_in_progress' "$tmp/u2-install-contention" ||
    [ "$u2_contention_after" != "$u2_contention_before" ]; then
    cat "$tmp/u2-install-contention" >&2
    printf 'U2 contention rc=%s before=%s after=%s\n' "$u2_contention_rc" \
      "$u2_contention_before" "$u2_contention_after" >&2
    fail "U2 live install contention did not return 75 with exact unchanged state"
  fi
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"
  [ -f "$u2_root/var/lib/roundhouse-lifecycle.lock/owner" ] ||
    fail "U2 SIGKILL did not leave recoverable lifecycle ownership evidence"

  u2_pause_marker="$tmp/u2-install-mutation-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=install-after-sudoers \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-install-killed" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  [ -f "$u2_root/var/lib/roundhouse-lifecycle.lock/transaction" ] &&
    [ -f "$u2_root/var/lib/roundhouse/draining" ] &&
    [ -d "$u2_root/var/lib/roundhouse/rollback/install-0-1-$u2_manifest_digest" ] ||
    fail "U2 install mutation pause lacked durable transaction evidence"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"

  printf '%s\n' unexpected-member-survives \
    >"$u2_root/var/lib/roundhouse-lifecycle.lock/unexpected-member"
  chmod 600 "$u2_root/var/lib/roundhouse-lifecycle.lock/unexpected-member"
  printf '%s\n' partial-transaction-record \
    >"$u2_root/var/lib/roundhouse-lifecycle.lock/.transaction.424242"
  chmod 600 "$u2_root/var/lib/roundhouse-lifecycle.lock/.transaction.424242"
  u2_invalid_lifecycle_before=$(u2_tree_digest \
    "$u2_root/var/lib/roundhouse-lifecycle.lock")
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle" \
      "$u2_manifest_digest" "$u2_confirmation_digest" >"$tmp/u2-unexpected-lifecycle-member" 2>/dev/null; then
    fail "U2 recovery accepted an unexpected lifecycle member"
  fi
  grep -Fqx 'reason|lifecycle_recovery_failed' "$tmp/u2-unexpected-lifecycle-member" &&
    grep -Fqx unexpected-member-survives \
      "$u2_root/var/lib/roundhouse-lifecycle.recovery/unexpected-member" &&
    [ -f "$u2_root/var/lib/roundhouse-lifecycle.recovery/.transaction.424242" ] &&
    [ "$(u2_tree_digest "$u2_root/var/lib/roundhouse-lifecycle.recovery")" = \
      "$u2_invalid_lifecycle_before" ] ||
    fail "U2 unexpected lifecycle member mutated recovery state before rejection"
  rm "$u2_root/var/lib/roundhouse-lifecycle.recovery/unexpected-member"
  rm "$u2_root/var/lib/roundhouse-lifecycle.recovery/.transaction.424242"

  u2_pause_marker="$tmp/u2-install-recovery-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
    ROUNDHOUSE_U2_PAUSE_AT=recovery-claimed \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-install-recovery-killed" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  [ -f "$u2_root/var/lib/roundhouse-lifecycle.recovery/transaction" ] &&
    [ -f "$u2_root/var/lib/roundhouse-lifecycle.recovery/owner" ] ||
    fail "U2 recovery pause lacked guarded durable recovery authority"
  u2_recovery_contender_before=$(u2_enrollment_state_digest)
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" install "$u2_bundle" \
      "$u2_manifest_digest" "$u2_confirmation_digest" >"$tmp/u2-recovery-contender" 2>/dev/null; then
    fail "U2 simultaneous stale-recovery contender acquired the OS guard"
  else
    u2_recovery_contender_rc=$?
  fi
  u2_recovery_contender_after=$(u2_enrollment_state_digest)
  [ "$u2_recovery_contender_rc" -eq 75 ] &&
    grep -Fqx 'reason|lifecycle_operation_in_progress' "$tmp/u2-recovery-contender" &&
    [ "$u2_recovery_contender_before" = "$u2_recovery_contender_after" ] ||
    fail "U2 stale-recovery contenders did not serialize exactly one mutator"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"

  u2_pause_marker="$tmp/u2-install-rolled-back-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=recovery-rolled-back \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-install-rolled-back-killed" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job"
  [ "$(awk -F '|' '$1=="phase"{print $2}' "$u2_root/var/lib/roundhouse-lifecycle.recovery/transaction")" = rolled-back ] ||
    fail "U2 rollback state was not durable before finalization cleanup"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"

  u2_pause_marker="$tmp/u2-recovery-retirement-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=recovery-retired \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-recovery-retirement-killed" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job" "$tmp/u2-recovery-retirement-killed"
  [ -d "$u2_root/var/lib/.roundhouse-lifecycle.recovery.retired" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] ||
    fail "U2 recovery retirement was not atomic before deletion"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"

  u2_pause_marker="$tmp/u2-install-committed-pause"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_PAUSE_AT=install-after-committed \
    ROUNDHOUSE_U2_PAUSE_MARKER="$u2_pause_marker" \
    "$enrollment" install "$u2_bundle" "$u2_manifest_digest" "$u2_confirmation_digest" \
    >"$tmp/u2-install-committed-killed" 2>&1 &
  u2_pause_job=$!
  u2_wait_for_pause "$u2_pause_marker" "$u2_pause_job" "$tmp/u2-install-committed-killed"
  [ "$(awk -F '|' '$1=="phase"{print $2}' "$u2_root/var/lib/roundhouse-lifecycle.lock/transaction")" = committed ] &&
    [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/1 ] ||
    fail "U2 committed phase was not durable before finalization"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-committed-readiness none >"$tmp/u2-committed-readiness.jsonl"
  [ "$(jq -r 'select(.kind=="privilege_broker") | [.data.lifecycle_status,.data.lifecycle_activity.phase,.data.broker_ready] | @tsv' \
    "$tmp/u2-committed-readiness.jsonl")" = "$(printf 'draining\tcommitted\tfalse')" ] ||
    fail "U2 collector overclaimed readiness during commit finalization"
  u2_kill_paused "$u2_pause_marker" "$u2_pause_job"
  u2_quarantine_collision="$u2_root/var/lib/roundhouse/quarantine/revoked-1-$u2_manifest_digest"
  mkdir "$u2_quarantine_collision"
  chmod 700 "$u2_quarantine_collision"
  printf '%s\n' quarantine-collision-survives >"$u2_quarantine_collision/unrelated"
  chmod 600 "$u2_quarantine_collision/unrelated"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" \
      "$enrollment" revoke "$u2_bundle" "$u2_manifest_digest" 1 \
      >"$tmp/u2-quarantine-collision" 2>/dev/null; then
    fail "U2 revoke accepted a pre-intent quarantine collision"
  else
    u2_quarantine_collision_rc=$?
  fi
  [ "$u2_quarantine_collision_rc" -eq 74 ] &&
    grep -Fqx 'reason|transaction_artifact_collision' "$tmp/u2-quarantine-collision" &&
    grep -Fqx quarantine-collision-survives "$u2_quarantine_collision/unrelated" &&
    [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/1 ] ||
    fail "U2 quarantine collision was not deterministic and non-destructive"
  rm -rf "$u2_quarantine_collision"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_U2_FAILPOINT=after-drain \
      "$enrollment" revoke "$u2_bundle" "$u2_manifest_digest" 1 \
      >"$tmp/u2-commit-finalization-retry" 2>/dev/null; then
    fail "U2 commit-finalization recovery unexpectedly passed the revoke failpoint"
  fi
  [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/1 ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/draining" ] &&
    grep -Fqx unrelated-survives "$u2_root/var/lib/roundhouse/unrelated-lifecycle-sentinel" ||
    fail "U2 committed retry rolled back new state or left lifecycle debris"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" status >"$tmp/u2-enrolled"
  grep -Fqx 'state|enrolled' "$tmp/u2-enrolled" || fail "U2 fixture enrollment did not activate"
  grep -Fqx 'scope|fixture' "$u2_root/var/lib/roundhouse-public/canary" ||
    fail "U2 fixture canary was not labeled"
  grep -Fqx 'positive-no-argument|fixture-simulated-broker-reached' \
    "$u2_root/var/lib/roundhouse-public/canary" ||
    fail "U2 fixture positive canary was not explicit"
  grep -Fqx 'negative-with-argument|fixture-passed' "$u2_root/var/lib/roundhouse-public/canary" ||
    fail "U2 fixture negative argument canary did not pass"
  grep -Fqx 'complete-sudoers|fixture-not-run' "$u2_root/var/lib/roundhouse-public/canary" ||
    fail "U2 fixture claimed complete native sudoers validation"
  [ "$(readlink "$u2_root/etc/roundhouse/active")" = generations/1 ] ||
    fail "U2 enrollment did not atomically select generation 1"
  [ -x "$u2_root/usr/libexec/roundhouse/posix-broker" ] ||
    fail "U2 enrollment did not install the protected broker"
  grep -Fqx 'roundhouse ALL=(root) NOPASSWD:NOSETENV: /usr/libexec/roundhouse/posix-broker ""' \
    "$u2_root/etc/sudoers.d/roundhouse-posix-broker" ||
    fail "U2 sudoers fixture was not the fixed no-argument broker grant"
  [ -f "$u2_root/var/lib/roundhouse-public/enrollment" ] &&
    [ -f "$u2_root/var/lib/roundhouse-public/canary" ] ||
    fail "U2 enrollment did not create public status before the first request"
  u2_revocation_reserve="$u2_root/var/lib/roundhouse/revocation.reserve"
  u2_reserve_size=$(stat -f %z "$u2_revocation_reserve" 2>/dev/null || stat -c %s "$u2_revocation_reserve")
  u2_reserve_blocks=$(stat -f %b "$u2_revocation_reserve" 2>/dev/null || stat -c %b "$u2_revocation_reserve")
  u2_reserve_device=$(stat -f %d "$u2_revocation_reserve" 2>/dev/null || stat -c %d "$u2_revocation_reserve")
  u2_state_device=$(stat -f %d "$u2_root/var/lib/roundhouse" 2>/dev/null || \
    stat -c %d "$u2_root/var/lib/roundhouse")
  [ "$u2_reserve_size" -eq 4194304 ] && [ $((u2_reserve_blocks * 512)) -ge 1048576 ] &&
    [ "$u2_reserve_device" = "$u2_state_device" ] ||
    fail "U2 enrollment did not allocate a real same-filesystem revocation reserve"
  [ "$(sed -n '1p' "$u2_generation/ssh-keygen.sha256")" = "$(u2_sha256 /usr/bin/ssh-keygen)" ] &&
    [ "$(wc -l <"$u2_generation/ssh-keygen.sha256" | tr -d ' ')" = 1 ] ||
    fail "U2 enrollment did not bind the absolute system ssh-keygen into the generation"
  [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.lock" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse-lifecycle.recovery" ] &&
  [ ! -e "$u2_root/var/lib/roundhouse/draining" ] &&
    [ ! -e "$u2_root/var/lib/roundhouse/rollback/install-0-1-$u2_manifest_digest" ] ||
    fail "U2 repeated SIGKILL recovery left lifecycle transaction artifacts"

  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-pre-broker-ready none \
    >"$tmp/u2-pre-broker-ready.jsonl"
  [ "$(jq -r 'select(.kind=="privilege_broker") | [.data.lifecycle_status,.data.broker_ready,.data.protected_artifacts_ready] | @tsv' \
    "$tmp/u2-pre-broker-ready.jsonl")" = "$(printf 'ready\ttrue\ttrue')" ] ||
    fail "U2 collector did not validate the clean pre-broker enrollment"
  u2_live_release="$u2_root/etc/roundhouse/generations/1/apt/metadata/Release"
  cp -p "$u2_live_release" "$tmp/u2-live-release"
  printf '%s\n' 'Unexpected: live-drift' >>"$u2_live_release"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-live-apt-drift none \
    >"$tmp/u2-live-apt-drift.jsonl"
  [ "$(jq -r 'select(.kind=="privilege_broker") | [.data.lifecycle_status,.data.broker_ready,.data.protected_artifacts_ready] | @tsv' \
    "$tmp/u2-live-apt-drift.jsonl")" = "$(printf 'drifted\tfalse\tfalse')" ] ||
    fail "U2 collector overclaimed readiness after live APT authority drift"
  mv "$tmp/u2-live-release" "$u2_live_release"
  ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" ROUNDHOUSE_IDENTITY="$tmp/u2-no-identity" \
    "$collector" "$tmp/config.json" test-apt u2-live-apt-restored none \
    >"$tmp/u2-live-apt-restored.jsonl"
  [ "$(jq -r 'select(.kind=="privilege_broker") | [.data.lifecycle_status,.data.broker_ready] | @tsv' \
    "$tmp/u2-live-apt-restored.jsonl")" = "$(printf 'ready\ttrue')" ] ||
    fail "U2 collector did not recover after restoring live APT authority"

  u2_broker_digest=$(u2_sha256 "$broker")
  u2_constraints_digest=$(u2_sha256 "$u2_root/etc/roundhouse/generations/1/policy.constraints")
  u2_context_digest=$(u2_sha256 "$u2_root/etc/roundhouse/generations/1/context.canary")
  u2_metadata_digest=$(printf '%s\n' 'metadata|1' | u2_sha256_stream)
  u2_precondition_digest=$(printf 'metadata|%s\n' "$u2_metadata_digest" | u2_sha256_stream)
  u2_make_envelope() {
    envelope_action=$1
    envelope_request_id=$2
    envelope_created=$3
    envelope_expiry=$4
    envelope_node=${5:-node-a}
    envelope_token=${6:--}
    envelope_manager=${7:-not-applicable}
    envelope_protocol=${8:-1}
    envelope_plan=${9:-plan-0123456789abcdef}
    envelope_certificate=${10:-$tmp/u2-node-key-cert.pub}
    envelope_precondition=${11:-$u2_precondition_digest}
    envelope_epoch=${12:-1}
    envelope_ca_fingerprint=${13:-${u2_request_ca_fingerprint:-$u2_ca_fingerprint}}
    envelope_ca_generation=${14:-${u2_request_ca_generation:-1}}
    envelope_node_fingerprint=$("$ssh_keygen" -lf "$envelope_certificate" -E sha256 | awk 'NR==1{print $2}')
    envelope_serial=$(TZ=UTC "$ssh_keygen" -Lf "$envelope_certificate" | awk '/Serial:/{print $2;exit}')
    envelope_valid_after=$(TZ=UTC "$ssh_keygen" -Lf "$envelope_certificate" |
      awk '/Valid: from/{gsub(/[-:]/,"",$3);print $3"Z"}')
    envelope_valid_before=$(TZ=UTC "$ssh_keygen" -Lf "$envelope_certificate" |
      awk '/Valid: from/{gsub(/[-:]/,"",$5);print $5"Z"}')
    request_suffix=${envelope_request_id#request-}
    request_file="$tmp/u2-request-$request_suffix"
    signature_file="$request_file.sig"
    envelope_file="$tmp/u2-envelope-$request_suffix"
    rm -f "$signature_file"
    [ ! -e "$signature_file" ] || fail "U2 signature output collision could not be removed"
    envelope_private=${envelope_certificate%-cert.pub}
    [ "$envelope_private" != "$envelope_certificate" ] && [ -f "$envelope_private" ] ||
      fail "U2 certificate did not resolve to its fixture-private sibling"
    cat >"$request_file" <<EOF
request|1
target-host-id|test-apt
target-uid|$u2_uid
plan-id|$envelope_plan
request-id|$envelope_request_id
action-id|$envelope_action
policy-token|$envelope_token
broker-protocol|$envelope_protocol
broker-version|${u2_request_broker_version:-1.0.0}
broker-sha256|$u2_broker_digest
policy-sha256|$u2_policy_digest
constraints-sha256|$u2_constraints_digest
precondition-sha256|$envelope_precondition
created-at|$envelope_created
expires-at|$envelope_expiry
transport|posix-ssh
request-principal|roundhouse
required-context|posix-root-v1
observed-execution-principal|root
console-session-state|none
platform-boundary|linux
enrollment-epoch|$envelope_epoch
context-canary-sha256|$u2_context_digest
pinned-host-key-fingerprint|$u2_host_fingerprint
node-id|$envelope_node
fleet-domain|fleet.example
fleet-ca-fingerprint|$envelope_ca_fingerprint
ca-generation|$envelope_ca_generation
node-key-fingerprint|$envelope_node_fingerprint
certificate-serial|$envelope_serial
certificate-valid-after|$envelope_valid_after
certificate-valid-before|$envelope_valid_before
certificate-source-addresses|-
manager-source-identity|$envelope_manager
end-request|
EOF
    SSH_AUTH_SOCK='' "$ssh_keygen" -Y sign -f "$envelope_certificate" -n roundhouse-request \
      "$request_file" >/dev/null
    {
      cat "$request_file"
      printf 'certificate|%s\nsignature-begin\n' "$(sed -n '1p' "$envelope_certificate")"
      cat "$signature_file"
      printf 'end-envelope\n'
    } >"$envelope_file"
    printf '%s\n' "$envelope_file"
  }

  u2_now=$(date -u +%s)
  cp -p "$u2_revocation_reserve" "$tmp/u2-revocation-reserve-real"
  rm -f "$u2_revocation_reserve"
  /bin/dd if=/dev/zero of="$u2_revocation_reserve" bs=1048576 count=0 seek=4 \
    >/dev/null 2>&1
  chmod 600 "$u2_revocation_reserve"
  u2_sparse_blocks=$(stat -f %b "$u2_revocation_reserve" 2>/dev/null || \
    stat -c %b "$u2_revocation_reserve")
  [ $((u2_sparse_blocks * 512)) -lt 1048576 ] || fail "U2 sparse reserve fixture was physically allocated"
  u2_sparse_reserve=$(u2_make_envelope apt.update-metadata.v1 \
    request-000000000000000000000000000000f1 "$u2_now" $((u2_now + 300)))
  u2_expect_rejected revocation_reserve_drift "$u2_sparse_reserve" "$tmp/u2-sparse-reserve"
  mv "$tmp/u2-revocation-reserve-real" "$u2_revocation_reserve"
  [ ! -e "$apt_marker" ] || fail "U2 sparse emergency reserve reached native APT"

  u2_ssh_attestation=$(u2_make_envelope apt.update-metadata.v1 \
    request-000000000000000000000000000000f0 "$u2_now" $((u2_now + 300)))
  cp -p "$u2_generation/ssh-keygen.sha256" "$tmp/u2-ssh-keygen-attestation"
  printf '%064d\n' 0 >"$u2_generation/ssh-keygen.sha256"
  u2_expect_rejected openssh_attestation_drift "$u2_ssh_attestation" "$tmp/u2-ssh-attestation-drift"
  mv "$tmp/u2-ssh-keygen-attestation" "$u2_generation/ssh-keygen.sha256"
  [ ! -e "$apt_marker" ] || fail "U2 ssh-keygen attestation drift reached native APT"
}
