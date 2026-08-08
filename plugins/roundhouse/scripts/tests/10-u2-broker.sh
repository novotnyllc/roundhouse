# roundhouse self-check — U2: the protected POSIX broker — envelopes,
# signatures and rejection paths.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

test_u2_broker_contracts() {
  broker="$script_dir/privilege-broker-posix"
  enrollment="$script_dir/enroll-privilege-posix"
  collector="$script_dir/collect-posix"
  [ -x "$broker" ] || fail "U2 POSIX broker is missing or not executable"
  [ -x "$enrollment" ] || fail "U2 POSIX enrollment entrypoint is missing or not executable"

  apt_marker="$tmp/u2-apt-executed"
  if APT_EXEC_MARKER="$apt_marker" "$broker" unexpected </dev/null >/dev/null 2>&1; then
    fail "U2 broker accepted an argument"
  fi
  [ ! -e "$apt_marker" ] || fail "U2 argument rejection reached APT"

  if printf '%s\n' 'request|2' | APT_EXEC_MARKER="$apt_marker" \
      "$broker" >/dev/null 2>&1; then
    fail "U2 broker accepted an unknown request version"
  fi
  [ ! -e "$apt_marker" ] || fail "U2 malformed request reached APT"

  u2_root="$tmp/u2-root"
  u2_bootstrap="$u2_root/var/lib/roundhouse-bootstrap"
  u2_build="$tmp/u2-bundle"
  u2_generation="$u2_root/etc/roundhouse/generations/1"
  mkdir -p "$u2_bootstrap/staged" "$u2_bootstrap/receipts" "$u2_build/apt/sources.list.d" \
    "$u2_build/apt/trusted.gpg.d" "$u2_build/apt/preferences.d" "$u2_build/apt/metadata" \
    "$u2_root/usr/bin" \
    "$u2_root/usr/lib/apt/methods" "$u2_root/usr/lib/apt/solvers" \
    "$u2_root/usr/lib/apt/planners" "$u2_root/etc/sudoers.d" "$u2_root/usr/libexec" \
    "$u2_root/etc/roundhouse/generations" "$u2_root/etc/roundhouse/trust" \
    "$u2_root/var/lib/roundhouse"
  chmod 755 "$u2_root" "$u2_root/etc" "$u2_root/etc/sudoers.d" \
    "$u2_root/etc/roundhouse" "$u2_root/etc/roundhouse/generations" \
    "$u2_root/etc/roundhouse/trust" "$u2_root/usr" "$u2_root/usr/bin" \
    "$u2_root/usr/lib" "$u2_root/usr/lib/apt" "$u2_root/usr/lib/apt/methods" \
    "$u2_root/usr/lib/apt/solvers" "$u2_root/usr/lib/apt/planners" "$u2_root/usr/libexec" \
    "$u2_root/var" "$u2_root/var/lib"
  chmod 700 "$u2_bootstrap" "$u2_bootstrap/staged" "$u2_bootstrap/receipts" \
    "$u2_root/var/lib/roundhouse"
  chmod -R go-w "$u2_root" "$u2_build"

  u2_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
  }
  u2_tree_digest() {
    tree=$1
    tree_listing="$tmp/u2-tree-listing"
    : >"$tree_listing"
    find "$tree" -mindepth 1 -type d -print | LC_ALL=C sort | while IFS= read -r tree_file; do
      printf '%s|directory|%s\n' "${tree_file#"$tree"/}" "$(test_file_mode "$tree_file")"
    done >>"$tree_listing"
    find "$tree" -type l -print | LC_ALL=C sort | while IFS= read -r tree_file; do
      printf '%s|symlink|%s\n' "${tree_file#"$tree"/}" "$(readlink "$tree_file")"
    done >>"$tree_listing"
    find "$tree" -type f -print | LC_ALL=C sort | while IFS= read -r tree_file; do
      printf '%s|file|%s|%s\n' "${tree_file#"$tree"/}" "$(test_file_mode "$tree_file")" \
        "$(u2_sha256 "$tree_file")"
    done >>"$tree_listing"
    u2_sha256 "$tree_listing"
  }
  u2_sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'; fi
  }
  u2_path_set_digest() {
    path_listing="$tmp/u2-path-listing"
    path_owner=$(id -un)
    : >"$path_listing"
    while [ "$#" -gt 0 ]; do
      path_label=$1
      path_candidate=$2
      shift 2
      if [ -f "$path_candidate" ]; then
        printf '%s|file|owner=%s|mode=%s|sha256=%s\n' "$path_label" "$path_owner" \
          "$(test_file_mode "$path_candidate")" "$(u2_sha256 "$path_candidate")" >>"$path_listing"
      elif [ -d "$path_candidate" ]; then
        printf '%s|directory|owner=%s|mode=%s\n' "$path_label" "$path_owner" \
          "$(test_file_mode "$path_candidate")" >>"$path_listing"
        find "$path_candidate" -mindepth 1 -type d -print | LC_ALL=C sort | \
          while IFS= read -r path_member; do
            printf '%s/%s|directory|owner=%s|mode=%s\n' "$path_label" \
              "${path_member#"$path_candidate"/}" "$path_owner" "$(test_file_mode "$path_member")"
          done >>"$path_listing"
        find "$path_candidate" -type f -print | LC_ALL=C sort | while IFS= read -r path_member; do
          printf '%s/%s|file|owner=%s|mode=%s|sha256=%s\n' "$path_label" \
            "${path_member#"$path_candidate"/}" "$path_owner" \
            "$(test_file_mode "$path_member")" "$(u2_sha256 "$path_member")"
        done >>"$path_listing"
      else
        printf '%s|absent\n' "$path_label" >>"$path_listing"
      fi
    done
    u2_sha256 "$path_listing"
  }
  u2_expect_rejected() {
    expected_reason=$1
    input=$2
    output=$3
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$broker" <"$input" >"$output" 2>/dev/null; then
      fail "U2 broker accepted fixture expected to fail: $expected_reason"
    fi
    grep -Fqx "reason|$expected_reason" "$output" ||
      fail "U2 broker rejection was not $expected_reason"
    [ ! -e "$apt_marker" ] || fail "U2 rejection reached APT: $expected_reason"
  }
  u2_enrollment_state_digest() {
    u2_state_listing="$tmp/u2-enrollment-state"
    : >"$u2_state_listing"
    for u2_state_path in \
      "$u2_root/usr/libexec/roundhouse/posix-broker" \
      "$u2_root/etc/sudoers.d/roundhouse-posix-broker" \
      "$u2_root/etc/roundhouse/trust/fleet-ca.pub" \
      "$u2_root/etc/roundhouse/trust/allowed_signers" \
      "$u2_root/etc/roundhouse/trust/revoked.krl" \
      "$u2_root/var/lib/roundhouse-public/enrollment" \
      "$u2_root/var/lib/roundhouse-public/canary" \
      "$u2_root/var/lib/roundhouse-public/active" \
      "$u2_root/var/lib/roundhouse-public/last" \
      "$u2_root/etc/roundhouse/generations" \
      "$u2_root/var/lib/roundhouse/revocation.reserve" \
      "$u2_root/var/lib/roundhouse/draining" \
      "$u2_root/var/lib/roundhouse/rollback" \
      "$u2_root/var/lib/roundhouse/quarantine" \
      "$u2_root/var/lib/roundhouse-lifecycle.lock" \
      "$u2_root/var/lib/roundhouse-lifecycle.recovery"; do
      if [ -L "$u2_state_path" ]; then
        printf '%s|symlink|%s\n' "$u2_state_path" "$(readlink "$u2_state_path")" >>"$u2_state_listing"
      elif [ -f "$u2_state_path" ]; then
        printf '%s|file|%s|%s\n' "$u2_state_path" "$(test_file_mode "$u2_state_path")" \
          "$(u2_sha256 "$u2_state_path")" >>"$u2_state_listing"
      elif [ -d "$u2_state_path" ]; then
        printf '%s|directory|%s|%s\n' "$u2_state_path" "$(test_file_mode "$u2_state_path")" \
          "$(u2_tree_digest "$u2_state_path")" >>"$u2_state_listing"
      else
        printf '%s|absent\n' "$u2_state_path" >>"$u2_state_listing"
      fi
    done
    if [ -L "$u2_root/etc/roundhouse/active" ]; then
      printf 'active|%s\n' "$(readlink "$u2_root/etc/roundhouse/active")" >>"$u2_state_listing"
    else
      printf '%s\n' 'active|absent' >>"$u2_state_listing"
    fi
    u2_sha256 "$u2_state_listing"
  }

  u2_wait_for_pause() {
    pause_marker=$1
    pause_job=$2
    pause_output=${3:-}
    pause_count=0
    while [ "$pause_count" -lt 45 ]; do
      if [ -f "$pause_marker" ]; then
        pause_pid=$(awk -F '[|=]' 'NR==1&&$1=="pause"&&$2=="1"&&$3=="point"&&$5=="pid"{print $6}' \
          "$pause_marker")
        printf '%s' "$pause_pid" | grep -Eq '^[1-9][0-9]{0,9}$' && kill -0 "$pause_pid" 2>/dev/null ||
          fail "U2 pause marker did not bind a live process"
        return 0
      fi
      if ! kill -0 "$pause_job" 2>/dev/null; then
        [ -z "$pause_output" ] || cat "$pause_output" >&2
        fail "U2 paused lifecycle process exited before its marker"
      fi
      sleep 1
      pause_count=$((pause_count + 1))
    done
    fail "U2 lifecycle pause marker timed out"
  }

  u2_kill_paused() {
    pause_marker=$1
    pause_job=$2
    pause_pid=$(awk -F '[|=]' 'NR==1&&$1=="pause"&&$2=="1"&&$3=="point"&&$5=="pid"{print $6}' \
      "$pause_marker")
    pause_processes=" $pause_job $pause_pid "
    pause_depth=0
    while [ "$pause_depth" -lt 5 ]; do
      pause_children=$(ps -axo pid=,ppid= | awk -v parents="$pause_processes" \
        'index(parents," "$2" "){printf "%s ",$1}')
      [ -n "$pause_children" ] || break
      pause_processes="$pause_processes$pause_children"
      pause_depth=$((pause_depth + 1))
    done
    touch "$pause_marker.kill"
    pause_wait=0
    while [ "$pause_wait" -lt 5 ]; do
      pause_survivor=false
      for pause_process in $pause_processes; do
        if kill -0 "$pause_process" 2>/dev/null; then pause_survivor=true; fi
      done
      [ "$pause_survivor" = false ] && break
      sleep 1
      pause_wait=$((pause_wait + 1))
    done
    if [ "$pause_survivor" = true ]; then
      for pause_process in $pause_processes; do kill -9 "$pause_process" 2>/dev/null || true; done
      sleep 1
    fi
    wait "$pause_job" 2>/dev/null || true
    pause_survivor=false
    for pause_process in $pause_processes; do
      if kill -0 "$pause_process" 2>/dev/null; then pause_survivor=true; fi
    done
    [ "$pause_survivor" = false ] || fail "U2 paused fixture process tree survived SIGKILL"
    pause_fixture_survivor=false
    while IFS= read -r pause_process_line; do
      case $pause_process_line in
        *enroll-privilege-posix*"$u2_root"*|*privilege-broker-posix*"$u2_root"*)
          pause_fixture_survivor=true
          ;;
      esac
    done < <(ps -axo pid=,command=)
    [ "$pause_fixture_survivor" = false ] ||
      fail "U2 paused lifecycle process survived for the fixture root"
    rm -f "$pause_marker" "$pause_marker.continue" "$pause_marker.kill"
  }

  ssh_keygen=/usr/bin/ssh-keygen
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-release-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-fleet-ca"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-node-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-node-b-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-node-renewed-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-rotated-fleet-ca"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-rotated-node-key"
  "$ssh_keygen" -q -t ed25519 -N '' -f "$tmp/u2-host-node-key"
  "$ssh_keygen" -q -s "$tmp/u2-fleet-ca" -I 'node-a@fleet.example' -z 41 \
    -n 'node-a@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    -O no-agent-forwarding -O no-port-forwarding -O no-pty -O no-user-rc -O no-X11-forwarding \
    "$tmp/u2-node-key.pub"
  "$ssh_keygen" -q -s "$tmp/u2-fleet-ca" -I 'node-b@fleet.example' -z 43 \
    -n 'node-b@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    -O no-agent-forwarding -O no-port-forwarding -O no-pty -O no-user-rc -O no-X11-forwarding \
    "$tmp/u2-node-b-key.pub"
  "$ssh_keygen" -q -s "$tmp/u2-fleet-ca" -I 'node-a@fleet.example' -z 44 \
    -n 'node-a@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    -O no-agent-forwarding -O no-port-forwarding -O no-pty -O no-user-rc -O no-X11-forwarding \
    "$tmp/u2-node-renewed-key.pub"
  "$ssh_keygen" -q -s "$tmp/u2-rotated-fleet-ca" -I 'node-a@fleet.example' -z 45 \
    -n 'node-a@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    -O no-agent-forwarding -O no-port-forwarding -O no-pty -O no-user-rc -O no-X11-forwarding \
    "$tmp/u2-rotated-node-key.pub"
  "$ssh_keygen" -q -s "$tmp/u2-fleet-ca" -h -I 'node-a@fleet.example' -z 42 \
    -n 'node-a@fleet.example,roundhouse-posix,roundhouse-windows' -V '-5m:+2h' \
    "$tmp/u2-host-node-key.pub"
  awk 'NR==1{print "roundhouse-release "$0}' "$tmp/u2-release-key.pub" \
    >"$u2_bootstrap/release-allowed-signers"
  {
    awk 'NR==1{print "node-a@fleet.example cert-authority "$0}' "$tmp/u2-fleet-ca.pub"
    awk 'NR==1{print "node-b@fleet.example cert-authority "$0}' "$tmp/u2-fleet-ca.pub"
  } >"$u2_build/allowed_signers"
  cp "$tmp/u2-fleet-ca.pub" "$u2_build/fleet-ca.pub"
  : >"$u2_build/revoked.krl"

  cat >"$u2_root/usr/bin/apt-get" <<SH
#!/bin/sh
printf '%s|%s\n' "\$0" "\$*" >>'$apt_marker'
case "\$*" in
  '--quiet=2 --simulate autoremove')
    [ -e '$apt_marker.autoremove-done' ] || printf '%s\n' 'Remv fixture-unused [1.0]' ;;
  '--quiet=2 --yes autoremove') : >'$apt_marker.autoremove-done' ;;
  *'--simulate'*) printf '%s\n' 'Inst fixture-package (1.2.3 fixture [fixture])' 'Conf fixture-package (1.2.3 fixture [fixture])' ;;
esac
exit 0
SH
  cat >"$u2_root/usr/bin/apt-config" <<'SH'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = dump ] || exit 64
generation=${APT_CONFIG%/apt.conf}
/bin/cat "$generation/apt/effective.dump"
SH
  cat >"$u2_root/usr/bin/apt-cache" <<'SH'
#!/bin/sh
[ "${1:-}" = policy ] || exit 64
if [ "$#" -eq 1 ]; then
  printf '%s\n' 'metadata|1'
  exit 0
fi
printf '%s\n' "$2:" '  Installed: (none)' '  Candidate: 1.2.3' \
  '  Version table:' '     1.2.3 500' '        500 https://packages.example.invalid stable/main fixture Packages'
SH
  cat >"$u2_root/usr/bin/dpkg" <<'SH'
#!/bin/sh
case "${1:-}" in
  --print-architecture) printf '%s\n' fixture ;;
  --compare-versions) exit 0 ;;
  *) exit 64 ;;
esac
SH
  cat >"$u2_root/usr/bin/dpkg-query" <<'SH'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -W ] && {
  printf '%s\n' 'base-files|1.0|ii '
  exit 0
}
exit 1
SH
  cat >"$u2_root/usr/bin/dpkg-deb" <<'SH'
#!/bin/sh
exit 64
SH
  cat >"$u2_root/usr/bin/setsid" <<'SH'
#!/bin/sh
exec "$@"
SH
  for fake_binary in apt-get apt-config apt-cache dpkg dpkg-query dpkg-deb setsid; do
    chmod 755 "$u2_root/usr/bin/$fake_binary"
  done
  cat >"$u2_root/usr/lib/apt/apt-helper" <<'SH'
#!/bin/sh
exit 64
SH
  chmod 755 "$u2_root/usr/lib/apt/apt-helper"
  u2_publisher_fingerprint=0123456789ABCDEF0123456789ABCDEF01234567
  u2_signer_fingerprint=89ABCDEF0123456789ABCDEF0123456789ABCDEF
  cat >"$u2_root/usr/bin/gpgv" <<'SH'
#!/bin/sh
set -eu
[ "$#" -eq 6 ] && [ "$1" = --status-fd ] && [ "$2" = 3 ] && [ "$3" = --keyring ] || exit 64
keyring=$4
signature=$5
release=$6
[ "$(sed -n '1p' "$keyring")" = 'roundhouse-test-keyring|1' ] || exit 65
[ "$(sed -n '1p' "$signature")" = 'roundhouse-test-signature|1' ] || exit 65
sha256_file() {
  if [ -x /usr/bin/sha256sum ]; then /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  else /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  fi
}
expected_release=$(awk -F '|' '$1=="release-sha256"{print $2;exit}' "$signature")
expected_keyring=$(awk -F '|' '$1=="keyring-sha256"{print $2;exit}' "$signature")
[ "$expected_release" = "$(sha256_file "$release")" ] &&
  [ "$expected_keyring" = "$(sha256_file "$keyring")" ] || exit 65
status_mode=$(awk -F '|' '$1=="status-mode"{print $2;exit}' "$signature")
signer=$(awk -F '|' '$1=="signer-fingerprint"{print $2;exit}' "$signature")
primary=$(awk -F '|' '$1=="primary-fingerprint"{print $2;exit}' "$signature")
emit_validsig() {
  if [ "$primary" = - ]; then
    printf '[GNUPG:] VALIDSIG %s 20260803 0 0 4 0 1 10 00\n' "$signer" >&3
  else
    printf '[GNUPG:] VALIDSIG %s 20260803 0 0 4 0 1 10 00 %s\n' "$signer" "$primary" >&3
  fi
}
case $status_mode in
  valid) emit_validsig ;;
  duplicate) emit_validsig; emit_validsig ;;
  missing) : ;;
  *) exit 65 ;;
esac
SH
  chmod 755 "$u2_root/usr/bin/gpgv"
  cat >"$u2_root/usr/lib/apt/methods/https" <<'SH'
#!/bin/sh
exit 99
SH
  chmod 755 "$u2_root/usr/lib/apt/methods/https"
  : >"$u2_build/apt/sources.list"
  cat >"$u2_build/apt/sources.list.d/roundhouse.sources" <<EOF
Types: deb
URIs: https://packages.example.invalid/debian
Suites: stable
Components: main
Signed-By: $u2_generation/apt/trusted.gpg.d/fleet.gpg $u2_publisher_fingerprint
Trusted: no
EOF
  cat >"$u2_build/apt/trusted.gpg.d/fleet.gpg" <<'EOF'
roundhouse-test-keyring|1
fingerprint|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
EOF
  cat >"$u2_build/apt/metadata/Release" <<'EOF'
Origin: roundhouse-fixture
Suite: stable
Codename: bookworm
Components: main contrib
SHA256:
 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef 0 Packages
EOF
  u2_release_digest=$(u2_sha256 "$u2_build/apt/metadata/Release")
  u2_test_keyring_digest=$(u2_sha256 "$u2_build/apt/trusted.gpg.d/fleet.gpg")
  cat >"$u2_build/apt/metadata/Release.gpg" <<EOF
roundhouse-test-signature|1
release-sha256|$u2_release_digest
keyring-sha256|$u2_test_keyring_digest
status-mode|valid
signer-fingerprint|$u2_signer_fingerprint
primary-fingerprint|$u2_publisher_fingerprint
EOF
  cat >"$u2_build/apt/source-authority" <<EOF
apt-source-authority|2
source-uri|https://packages.example.invalid/debian
source-suite|stable
source-component|main
publisher-primary-fingerprint|$u2_publisher_fingerprint
keyring-sha256|$u2_test_keyring_digest
release-sha256|$u2_release_digest
signature-sha256|$(u2_sha256 "$u2_build/apt/metadata/Release.gpg")
EOF
  : >"$u2_build/apt/preferences"
  : >"$u2_build/apt/preferences.d/00-roundhouse"
  printf '%s\n' 'source-identities|1' >"$u2_build/apt/source-identities"
  find "$u2_build/apt" -type d -exec chmod 755 {} +
  find "$u2_build/apt" -type f -exec chmod 644 {} +

  u2_policy="$u2_build/policy.actions"
  cp "$script_dir/../references/privilege-policy.default" "$u2_policy"
  u2_policy_digest=$(u2_sha256 "$u2_policy")
  printf 'constraints|1|generation=1|policy-sha256=%s\n' "$u2_policy_digest" \
    >"$u2_build/policy.constraints"
  u2_uid=$(id -u)
  u2_ca_fingerprint=$("$ssh_keygen" -lf "$tmp/u2-fleet-ca.pub" -E sha256 | awk 'NR==1{print $2}')
  u2_host_fingerprint=$("$ssh_keygen" -lf "$tmp/u2-node-key.pub" -E sha256 | awk 'NR==1{print $2}')
  printf 'identity|1|test-apt|%s|roundhouse|fleet.example|%s|1|%s|roundhouse-posix,roundhouse-windows\n' \
    "$u2_uid" "$u2_ca_fingerprint" "$u2_host_fingerprint" >"$u2_build/host.identity"
  printf '%s\n' 'context|1|platform=linux|required=posix-root-v1|principal=root|console-session=none' \
    >"$u2_build/context.canary"
  cat >"$u2_build/apt.conf" <<EOF
Dir::Etc::main "/dev/null";
Dir::Etc::parts "/dev/null";
Dir::Etc::sourcelist "$u2_generation/apt/sources.list";
Dir::Etc::sourceparts "$u2_generation/apt/sources.list.d";
Dir::Etc::trusted "$u2_generation/apt/trusted.gpg";
Dir::Etc::trustedparts "$u2_generation/apt/trusted.gpg.d";
Dir::Etc::preferences "$u2_generation/apt/preferences";
Dir::Etc::preferencesparts "$u2_generation/apt/preferences.d";
Dir::Bin::methods "$u2_root/usr/lib/apt/methods";
Dir::Bin::dpkg "$u2_root/usr/bin/dpkg";
APT::Architecture "fixture";
Acquire::AllowInsecureRepositories "false";
APT::Get::AllowUnauthenticated "false";
EOF
  cp "$u2_build/apt.conf" "$u2_build/apt/effective.dump"
  u2_apt_config_digest=$(u2_sha256 "$u2_build/apt.conf")
  u2_effective_config_digest=$(u2_sha256 "$u2_build/apt/effective.dump")
  u2_sources_digest=$(u2_path_set_digest source-main "$u2_build/apt/sources.list" \
    source-parts "$u2_build/apt/sources.list.d")
  u2_keyrings_digest=$(u2_path_set_digest trusted-main "$u2_build/apt/trusted.gpg" \
    trusted-parts "$u2_build/apt/trusted.gpg.d")
  u2_preferences_digest=$(u2_path_set_digest preferences-main "$u2_build/apt/preferences" \
    preferences-parts "$u2_build/apt/preferences.d")
  u2_methods_digest=$(u2_path_set_digest methods "$u2_root/usr/lib/apt/methods")
  u2_compressors_digest=$(u2_path_set_digest gzip "$u2_root/usr/bin/gzip" \
    xz "$u2_root/usr/bin/xz" bzip2 "$u2_root/usr/bin/bzip2" \
    lz4 "$u2_root/usr/bin/lz4" zstd "$u2_root/usr/bin/zstd")
  u2_helpers_digest=$(u2_path_set_digest apt-helper "$u2_root/usr/lib/apt/apt-helper" \
    apt-solvers "$u2_root/usr/lib/apt/solvers" apt-planners "$u2_root/usr/lib/apt/planners" \
    gpgv "$u2_root/usr/bin/gpgv")
  cat >"$u2_build/apt.context" <<EOF
apt-context|2
architecture|fixture
config-file-sha256|$u2_apt_config_digest
effective-config-sha256|$u2_effective_config_digest
sources-sha256|$u2_sources_digest
keyrings-sha256|$u2_keyrings_digest
preferences-sha256|$u2_preferences_digest
source-identities-sha256|$(u2_sha256 "$u2_build/apt/source-identities")
methods-sha256|$u2_methods_digest
compressors-sha256|$u2_compressors_digest
helpers-sha256|$u2_helpers_digest
binary|apt-get|$(u2_sha256 "$u2_root/usr/bin/apt-get")
binary|apt-config|$(u2_sha256 "$u2_root/usr/bin/apt-config")
binary|apt-cache|$(u2_sha256 "$u2_root/usr/bin/apt-cache")
binary|dpkg|$(u2_sha256 "$u2_root/usr/bin/dpkg")
binary|dpkg-query|$(u2_sha256 "$u2_root/usr/bin/dpkg-query")
binary|dpkg-deb|$(u2_sha256 "$u2_root/usr/bin/dpkg-deb")
binary|setsid|$(u2_sha256 "$u2_root/usr/bin/setsid")
EOF
  cp "$broker" "$u2_build/privilege-broker-posix"
  cp "$enrollment" "$u2_build/enroll-privilege-posix"

  : >"$u2_build/bootstrap.manifest"
  for u2_relative in allowed_signers apt.conf apt.context apt/effective.dump apt/preferences \
    apt/metadata/Release apt/metadata/Release.gpg apt/preferences.d/00-roundhouse \
    apt/source-authority apt/source-identities apt/sources.list \
    apt/sources.list.d/roundhouse.sources apt/trusted.gpg.d/fleet.gpg \
    context.canary enroll-privilege-posix fleet-ca.pub \
    host.identity policy.actions policy.constraints privilege-broker-posix revoked.krl; do
    printf 'file|%s|%s\n' "$u2_relative" "$(u2_sha256 "$u2_build/$u2_relative")"
  done | LC_ALL=C sort -t '|' -k2,2 >"$u2_build/bootstrap.manifest"
  u2_manifest_digest=$(u2_sha256 "$u2_build/bootstrap.manifest")
  "$ssh_keygen" -Y sign -f "$tmp/u2-release-key" -n roundhouse-release \
    "$u2_build/bootstrap.manifest" >/dev/null
  u2_bundle="$u2_bootstrap/staged/$u2_manifest_digest"
  mv "$u2_build" "$u2_bundle"
  printf 'bootstrap|1|manifest-sha256=%s|release-principal=roundhouse-release\n' \
    "$u2_manifest_digest" >"$u2_bootstrap/receipts/$u2_manifest_digest"
  chmod -R go-w "$u2_root"
  "$ssh_keygen" -Y verify -f "$u2_bootstrap/release-allowed-signers" \
    -I roundhouse-release -n roundhouse-release \
    -s "$u2_bundle/bootstrap.manifest.sig" <"$u2_bundle/bootstrap.manifest" >/dev/null 2>&1 ||
    fail "U2 release signature fixture was invalid"

  u2_rebind_apt_authority() {
    rebind_build=$1
    find "$rebind_build/apt" -type d -exec chmod 755 {} +
    find "$rebind_build/apt" -type f -exec chmod 644 {} +
    rebind_source=$rebind_build/apt/sources.list.d/roundhouse.sources
    rebind_signature=$rebind_build/apt/metadata/Release.gpg
    rebind_release_digest=$(u2_sha256 "$rebind_build/apt/metadata/Release")
    rebind_keyring_digest=$(u2_sha256 "$rebind_build/apt/trusted.gpg.d/fleet.gpg")
    rebind_status_mode=$(awk -F '|' '$1=="status-mode"{print $2;exit}' "$rebind_signature")
    rebind_signer=$(awk -F '|' '$1=="signer-fingerprint"{print $2;exit}' "$rebind_signature")
    rebind_primary=$(awk -F '|' '$1=="primary-fingerprint"{print $2;exit}' "$rebind_signature")
    {
      printf '%s\n' 'roundhouse-test-signature|1'
      printf 'release-sha256|%s\nkeyring-sha256|%s\n' "$rebind_release_digest" "$rebind_keyring_digest"
      printf 'status-mode|%s\nsigner-fingerprint|%s\nprimary-fingerprint|%s\n' \
        "$rebind_status_mode" "$rebind_signer" "$rebind_primary"
    } >"$rebind_signature"
    rebind_uri=$(sed -n '2s/^URIs: //p' "$rebind_source")
    rebind_suite=$(sed -n '3s/^Suites: //p' "$rebind_source")
    rebind_component=$(sed -n '4s/^Components: //p' "$rebind_source")
    rebind_publisher=$(awk 'NR==5{print $NF}' "$rebind_source")
    {
      printf '%s\n' 'apt-source-authority|2'
      printf 'source-uri|%s\nsource-suite|%s\nsource-component|%s\n' \
        "$rebind_uri" "$rebind_suite" "$rebind_component"
      printf 'publisher-primary-fingerprint|%s\n' "$rebind_publisher"
      printf 'keyring-sha256|%s\nrelease-sha256|%s\nsignature-sha256|%s\n' \
        "$rebind_keyring_digest" "$rebind_release_digest" "$(u2_sha256 "$rebind_signature")"
    } >"$rebind_build/apt/source-authority"
    rebind_sources_digest=$(u2_path_set_digest source-main "$rebind_build/apt/sources.list" \
      source-parts "$rebind_build/apt/sources.list.d")
    awk -F '|' -v OFS='|' -v digest="$rebind_sources_digest" \
      '$1=="sources-sha256"{$2=digest}{print}' "$rebind_build/apt.context" >"$tmp/u2-rebound-context"
    mv "$tmp/u2-rebound-context" "$rebind_build/apt.context"
    chmod 644 "$rebind_signature" "$rebind_build/apt/source-authority" "$rebind_build/apt.context"
  }

  u2_stage_candidate() {
    stage_build=$1
    rm -f "$stage_build/bootstrap.manifest" "$stage_build/bootstrap.manifest.sig"
    find "$stage_build" -type f ! -name bootstrap.manifest ! -name bootstrap.manifest.sig -print | \
      LC_ALL=C sort | while IFS= read -r stage_file; do
      stage_relative=${stage_file#"$stage_build"/}
      printf 'file|%s|%s\n' "$stage_relative" "$(u2_sha256 "$stage_file")"
    done | LC_ALL=C sort -t '|' -k2,2 >"$stage_build/bootstrap.manifest"
    "$ssh_keygen" -Y sign -f "$tmp/u2-release-key" -n roundhouse-release \
      "$stage_build/bootstrap.manifest" >/dev/null
    stage_digest=$(u2_sha256 "$stage_build/bootstrap.manifest")
    u2_staged_candidate=$u2_bootstrap/staged/$stage_digest
    mv "$stage_build" "$u2_staged_candidate"
    printf 'bootstrap|1|manifest-sha256=%s|release-principal=roundhouse-release\n' \
      "$stage_digest" >"$u2_bootstrap/receipts/$stage_digest"
    chmod -R go-w "$u2_staged_candidate" "$u2_bootstrap/receipts/$stage_digest"
  }

  chmod 777 "$u2_bundle/apt/sources.list.d"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_bundle" \
      >"$tmp/u2-writable-source-directory" 2>/dev/null; then
    fail "U2 enrollment accepted a writable nested APT source directory"
  fi
  grep -Fqx 'reason|candidate_validation_failed' "$tmp/u2-writable-source-directory" ||
    fail "U2 writable nested APT directory did not fail candidate validation"
  chmod 755 "$u2_bundle/apt/sources.list.d"

  mv "$u2_bundle/apt/sources.list.d/roundhouse.sources" "$tmp/u2-source-before-symlink"
  ln -s "$tmp/u2-source-before-symlink" "$u2_bundle/apt/sources.list.d/roundhouse.sources"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_bundle" \
      >"$tmp/u2-symlink-source" 2>/dev/null; then
    fail "U2 enrollment accepted a symlinked APT source"
  fi
  grep -Fqx 'reason|authenticated_bootstrap_failed' "$tmp/u2-symlink-source" ||
    fail "U2 symlinked APT source did not fail authenticated bootstrap"
  rm "$u2_bundle/apt/sources.list.d/roundhouse.sources"
  mv "$tmp/u2-source-before-symlink" "$u2_bundle/apt/sources.list.d/roundhouse.sources"

  for u2_source_attack in trusted relative missing-fingerprint wrong-fingerprint \
    uri-userinfo uri-query uri-traversal uri-fragment; do
    u2_attack_build="$tmp/u2-source-attack-$u2_source_attack"
    cp -R "$u2_bundle" "$u2_attack_build"
    case $u2_source_attack in
      trusted)
        sed 's/^Trusted: no$/Trusted: yes/' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
      relative)
        sed 's#^Signed-By: .*/apt/trusted.gpg.d/fleet.gpg #Signed-By: trusted.gpg.d/fleet.gpg #' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
      missing-fingerprint)
        sed 's/ [0-9A-F]\{40\}$//' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
      wrong-fingerprint)
        sed 's/[0-9A-F]\{40\}$/FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF/' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
      uri-userinfo)
        sed 's#^URIs: .*$#URIs: https://attacker@packages.example.invalid/debian#' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
      uri-query)
        sed 's#^URIs: .*$#URIs: https://packages.example.invalid/debian?channel=stable#' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
      uri-traversal)
        sed 's#^URIs: .*$#URIs: https://packages.example.invalid/debian/../private#' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
      uri-fragment)
        sed 's|^URIs: .*$|URIs: https://packages.example.invalid/debian#fragment|' \
          "$u2_attack_build/apt/sources.list.d/roundhouse.sources" >"$tmp/u2-attacked-source"
        ;;
    esac
    mv "$tmp/u2-attacked-source" "$u2_attack_build/apt/sources.list.d/roundhouse.sources"
    chmod 644 "$u2_attack_build/apt/sources.list.d/roundhouse.sources"
    u2_rebind_apt_authority "$u2_attack_build"
    u2_stage_candidate "$u2_attack_build"
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_staged_candidate" \
        >"$tmp/u2-source-attack-$u2_source_attack-result" 2>/dev/null; then
      fail "U2 accepted authenticated APT source attack: $u2_source_attack"
    fi
    grep -Fqx 'reason|candidate_validation_failed' "$tmp/u2-source-attack-$u2_source_attack-result" ||
      fail "U2 authenticated source attack did not fail candidate validation: $u2_source_attack"
  done

  u2_attack_build="$tmp/u2-source-attack-ssh-keyring"
  cp -R "$u2_bundle" "$u2_attack_build"
  cp "$tmp/u2-fleet-ca.pub" "$u2_attack_build/apt/trusted.gpg.d/fleet.gpg"
  chmod 644 "$u2_attack_build/apt/trusted.gpg.d/fleet.gpg"
  u2_attack_keyring_digest=$(u2_sha256 "$u2_attack_build/apt/trusted.gpg.d/fleet.gpg")
  awk -F '|' -v OFS='|' -v digest="$u2_attack_keyring_digest" \
    '$1=="keyring-sha256"{$2=digest}{print}' "$u2_attack_build/apt/metadata/Release.gpg" \
    >"$tmp/u2-attacked-signature"
  mv "$tmp/u2-attacked-signature" "$u2_attack_build/apt/metadata/Release.gpg"
  u2_attack_signature_digest=$(u2_sha256 "$u2_attack_build/apt/metadata/Release.gpg")
  awk -F '|' -v OFS='|' -v keyring="$u2_attack_keyring_digest" -v signature="$u2_attack_signature_digest" '
    $1=="keyring-sha256"{$2=keyring}$1=="signature-sha256"{$2=signature}{print}
  ' "$u2_attack_build/apt/source-authority" >"$tmp/u2-attacked-authority"
  mv "$tmp/u2-attacked-authority" "$u2_attack_build/apt/source-authority"
  u2_attack_keyrings_digest=$(u2_path_set_digest trusted-main "$u2_attack_build/apt/trusted.gpg" \
    trusted-parts "$u2_attack_build/apt/trusted.gpg.d")
  awk -F '|' -v OFS='|' -v keyrings_digest="$u2_attack_keyrings_digest" \
    '$1=="keyrings-sha256"{$2=keyrings_digest}{print}' "$u2_attack_build/apt.context" \
    >"$tmp/u2-attacked-context"
  mv "$tmp/u2-attacked-context" "$u2_attack_build/apt.context"
  chmod 644 "$u2_attack_build/apt/metadata/Release.gpg" "$u2_attack_build/apt/source-authority" \
    "$u2_attack_build/apt.context"
  u2_stage_candidate "$u2_attack_build"
  if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_staged_candidate" \
      >"$tmp/u2-source-attack-ssh-keyring-result" 2>/dev/null; then
    fail "U2 accepted an authenticated SSH public key as an APT keyring"
  fi
  grep -Fqx 'reason|candidate_validation_failed' "$tmp/u2-source-attack-ssh-keyring-result" ||
    fail "U2 authenticated SSH-key keyring did not fail candidate validation"

  for u2_signature_attack in wrong-primary wrong-fallback missing-status duplicate-status; do
    u2_attack_build="$tmp/u2-signature-attack-$u2_signature_attack"
    cp -R "$u2_bundle" "$u2_attack_build"
    case $u2_signature_attack in
      wrong-primary)
        awk -F '|' -v OFS='|' '$1=="primary-fingerprint"{$2="FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"}{print}' \
          "$u2_attack_build/apt/metadata/Release.gpg" >"$tmp/u2-attacked-signature"
        ;;
      wrong-fallback)
        awk -F '|' -v OFS='|' \
          '$1=="signer-fingerprint"{$2="FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"}
           $1=="primary-fingerprint"{$2="-"}{print}' \
          "$u2_attack_build/apt/metadata/Release.gpg" >"$tmp/u2-attacked-signature"
        ;;
      missing-status)
        awk -F '|' -v OFS='|' '$1=="status-mode"{$2="missing"}{print}' \
          "$u2_attack_build/apt/metadata/Release.gpg" >"$tmp/u2-attacked-signature"
        ;;
      duplicate-status)
        awk -F '|' -v OFS='|' '$1=="status-mode"{$2="duplicate"}{print}' \
          "$u2_attack_build/apt/metadata/Release.gpg" >"$tmp/u2-attacked-signature"
        ;;
    esac
    mv "$tmp/u2-attacked-signature" "$u2_attack_build/apt/metadata/Release.gpg"
    u2_rebind_apt_authority "$u2_attack_build"
    u2_stage_candidate "$u2_attack_build"
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_staged_candidate" \
        >"$tmp/u2-signature-attack-$u2_signature_attack-result" 2>/dev/null; then
      fail "U2 accepted authenticated gpgv status attack: $u2_signature_attack"
    fi
    grep -Fqx 'reason|candidate_validation_failed' "$tmp/u2-signature-attack-$u2_signature_attack-result" ||
      fail "U2 gpgv status attack did not fail candidate validation: $u2_signature_attack"
  done

  for u2_release_attack in suite-mismatch duplicate-suite duplicate-codename \
    component-missing component-duplicate; do
    u2_attack_build="$tmp/u2-release-attack-$u2_release_attack"
    cp -R "$u2_bundle" "$u2_attack_build"
    case $u2_release_attack in
      suite-mismatch)
        sed 's/^Suite: stable$/Suite: testing/' "$u2_attack_build/apt/metadata/Release" \
          >"$tmp/u2-attacked-release"
        ;;
      duplicate-suite)
        awk '{print} /^Suite:/{print "Suite: testing"}' "$u2_attack_build/apt/metadata/Release" \
          >"$tmp/u2-attacked-release"
        ;;
      duplicate-codename)
        awk '{print} /^Codename:/{print "Codename: testing"}' "$u2_attack_build/apt/metadata/Release" \
          >"$tmp/u2-attacked-release"
        ;;
      component-missing)
        sed 's/^Components: .*$/Components: contrib/' "$u2_attack_build/apt/metadata/Release" \
          >"$tmp/u2-attacked-release"
        ;;
      component-duplicate)
        sed 's/^Components: .*$/Components: main contrib main/' "$u2_attack_build/apt/metadata/Release" \
          >"$tmp/u2-attacked-release"
        ;;
    esac
    mv "$tmp/u2-attacked-release" "$u2_attack_build/apt/metadata/Release"
    chmod 644 "$u2_attack_build/apt/metadata/Release"
    u2_rebind_apt_authority "$u2_attack_build"
    u2_stage_candidate "$u2_attack_build"
    if ROUNDHOUSE_U2_FIXTURE_ROOT="$u2_root" "$enrollment" preview "$u2_staged_candidate" \
        >"$tmp/u2-release-attack-$u2_release_attack-result" 2>/dev/null; then
      fail "U2 accepted authenticated Release metadata attack: $u2_release_attack"
    fi
    grep -Fqx 'reason|candidate_validation_failed' "$tmp/u2-release-attack-$u2_release_attack-result" ||
      fail "U2 Release metadata attack did not fail candidate validation: $u2_release_attack"
  done
}
