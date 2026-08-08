# roundhouse self-check — §7.9: roundhouse-trustd, the root-owned materializer.
#
# The suite runs UNPRIVILEGED — there is no root in CI — so trustd's actual
# root-owned write cannot be exercised here. What IS exercised without root:
# the derivation (trustd re-derives the same roster the read path does), the
# input validation and fail-closed behaviour, the generation-monotonicity
# refusal, the degrade path (trustd absent -> same-user, the current behaviour),
# and — as source-asserts — that fleet_trust_materialize invokes trustd when it
# is present and that the doctor rows key on root ownership. The only
# actual-root behaviour lives behind trustd_own, gated on `id -u` and the
# ROUNDHOUSE_TRUSTD_FIXTURE hook, and its inertness off-root is asserted below.
#
# Sourced by scripts/test-roundhouse in a fixed order, after
# tests/94-jj-doctor.sh; reuses tests/90-jj-bootstrap.sh's real-jj gate. Not a
# standalone test file.
# shellcheck shell=bash

trustd_root="$tmp/fleet-trustd"
mkdir -p "$trustd_root"
trustd_bin="$script_dir/roundhouse-trustd"
enroll_bin="$script_dir/enroll-privilege-posix"

# --- source-asserts and the off-root ownership gate: no store required --------
(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # (e) fleet_trust_materialize invokes trustd on the privileged lane, and the
  # degrade branch it falls back to is UNCHANGED.
  cli_function_body fleet_trust_materialize | grep -Fq '"$fleet_trust_mhelper" apply' ||
    fail "§7.9: fleet_trust_materialize no longer invokes trustd on the privileged lane"
  cli_function_body fleet_trust_materialize |
    grep -Fq 'safe_output "$fleet_trust_mtmp/roster" "$(fleet_trust_materialized_path)"' ||
    fail "§7.9: the degrade-to-same-user materialize path was regressed"

  # (P0) THE ROOT INVOCATION IS HERMETIC: env -i with an explicit environment and
  # sudo -n, never the caller's inherited env reaching the root process.
  cli_function_body fleet_trust_materialize | grep -Fq 'env -i' ||
    fail "§7.9 P0: the privileged trustd invocation is not env -i hermetic"
  cli_function_body fleet_trust_materialize | grep -Fq 'sudo -n' ||
    fail "§7.9 P0: the privileged trustd invocation does not reach root via sudo -n"

  # (P0) trustd itself trusts none of its same-user-influenceable environment:
  # ROUNDHOUSE_TRUSTD_HOME is SELFTEST-gated (never honoured in production or as
  # root), the sourced library is verified root-owned before sourcing, the
  # toolchain is pinned to verified absolute paths, and PATH is replaced not
  # appended when root.
  grep -Fq 'ROUNDHOUSE_SELFTEST' "$trustd_bin" && grep -Fq 'trustd_is_root' "$trustd_bin" ||
    fail "§7.9 P0: trustd does not gate ROUNDHOUSE_TRUSTD_HOME behind the self-check"
  grep -q 'refusing to source a non-root-owned library' "$trustd_bin" ||
    fail "§7.9 P0: trustd does not verify its sourced library is root-owned"
  grep -Fq 'trustd_pin_toolchain' "$trustd_bin" ||
    fail "§7.9 P0: trustd does not pin its jj/yq/jq toolchain to verified paths"
  grep -q 'refusing a symlinked path' "$trustd_bin" ||
    fail "§7.9 P3: trustd does not reject symlinked store/\$TRUST paths"
  grep -q 'residual 2' "$trustd_bin" ||
    fail "§7.9 P2: trustd has no KRL first-run trusted-origin custody"
  grep -Fq '/privileged' "$trustd_bin" ||
    fail "§7.9 P2: trustd writes no was-privileged marker"

  # (P2) the install lane exists and roots the binary, the library, the toolchain
  # and the sudo lane.
  grep -q 'install_trustd' "$enroll_bin" ||
    fail "§7.9: enroll-privilege-posix has no install-trustd lane"
  grep -q 'NOPASSWD:NOSETENV' "$enroll_bin" ||
    fail "§7.9: the trustd install lane installs no hermetic sudoers entry"

  # (e) the doctor keys the privileged-lane row on ROOT OWNERSHIP, asserts the
  # co-located tree, and distinguishes OK-degraded from a forced degrade.
  cli_program_contains 'doctor_root_owned' ||
    fail "§7.9: the doctor no longer keys the privileged-lane row on root ownership"
  cli_program_contains 'trustd-binary' ||
    fail "§7.9: the doctor has no trustd-binary ownership row"
  cli_program_contains 'root-owned tree' ||
    fail "§7.9: the doctor does not assert the co-located trustd tree"
  cli_program_contains 'residual 7' ||
    fail "§7.9: the doctor does not distinguish a forced degrade from OK-degraded"

  # trustd carries its threat-model header where the code that enforces it lives.
  grep -q 'PERSISTENCE PAST REVOCATION' "$trustd_bin" ||
    fail "§7.9: roundhouse-trustd carries no threat-model header"
  grep -q 'WHAT THIS DOES NOT DEFEND' "$trustd_bin" ||
    fail "§7.9: the trustd threat model does not state what it does NOT defend"

  # The ownership gate is a NO-OP off-root: the selftest-own hook chowns nothing
  # when `id -u` is not 0, so the file keeps its current owner. This is what lets
  # the whole suite run without root.
  trustd_own_probe="$trustd_root/own-probe"
  : >"$trustd_own_probe"
  trustd_own_out=$(ROUNDHOUSE_TRUSTD_HOME="$script_dir" \
    "$trustd_bin" selftest-own "$trustd_own_probe")
  if [ "$(id -u)" -ne 0 ]; then
    [ "$trustd_own_out" = "$(id -un)" ] ||
      fail "§7.9: the trustd ownership gate is not inert off-root (got owner '$trustd_own_out')"
  fi
)

# --- derivation, validation, monotonicity, degrade: real jj required ----------
if [ "$real_jj_ok" != true ]; then
  printf 'real-jj: trustd materialization block skipped (jj/yq unavailable)\n'
else
  printf 'real-jj: trustd materialization, validation, monotonicity (jj %s)\n' \
    "$real_jj_version"
  (
    set -eu
    fail() {
      printf 'FAIL: real-jj trustd: %s\n' "$*" >&2
      exit 1
    }
    PATH="$(dirname "$real_jj"):$(dirname "$real_yq"):$PATH"
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    tr="$trustd_root/real"
    mkdir -p "$tr"
    cat >"$tr/jj-config.toml" <<'TOML'
[user]
name = "roundhouse selfcheck"
email = "roundhouse-selfcheck@example.invalid"
[ui]
paginate = "never"
TOML
    export JJ_CONFIG="$tr/jj-config.toml"
    export XDG_CONFIG_HOME="$tr/xdg"

    tr_run() {
      tr_instance=$1
      shift
      mkdir -p "$tr/$tr_instance"
      [ -f "$tr/$tr_instance/identity.yaml" ] ||
        printf 'name: %s\ndomain: fleet.example.invalid\n' "$tr_instance" \
          >"$tr/$tr_instance/identity.yaml"
      env ROUNDHOUSE_FLEET_STORE="$tr/$tr_instance/store" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$tr/$tr_instance-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$tr/$tr_instance" \
        "$@"
    }

    tr_run vireo "$cli" fleet-init >/dev/null 2>&1 ||
      fail "fleet-init failed while setting up the trustd fixture"
    tr_run vireo "$cli" fleet-enroll >/dev/null 2>&1 ||
      fail "fleet-enroll failed while setting up the trustd fixture"
    store="$tr/vireo/store"
    trust="$tr/vireo"
    head=$(jj -R "$store" log -r 'heads(bookmarks(exact:"main"))' --no-graph \
      -T 'commit_id ++ "\n"' | head -1)
    [ -n "$head" ] || fail "no main head after enroll"

    # The ratchet is read fresh from this instance's $TRUST, never repo config.
    export ROUNDHOUSE_SELFTEST=1
    export ROUNDHOUSE_TRUST_ROOT="$trust"

    tr_apply() {
      # Mirrors the real invocation: fleet_trust_materialize runs trustd as a
      # child, so trustd inherits the run's ROUNDHOUSE_FLEET_STORE (the host's
      # own identity.yaml, carrying the genesis pin) and $TRUST.
      env ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$trust" \
        ROUNDHOUSE_FLEET_STORE="$store" \
        ROUNDHOUSE_TRUSTD_FIXTURE=1 ROUNDHOUSE_TRUSTD_HOME="$script_dir" \
        "$trustd_bin" "$@"
    }
    tr_reject() {
      # expect a nonzero exit (fail closed)
      if tr_apply "$@" >/dev/null 2>&1; then
        fail "trustd accepted bad input: $*"
      fi
    }

    # (a) DERIVATION — trustd writes the SAME roster the read path derives.
    tr_apply apply "$store" "$head" ||
      fail "trustd apply failed on a freshly enrolled store"
    [ "$(cat "$trust/reviewed-ref")" = "$head" ] ||
      fail "trustd did not record the reviewed ref"
    [ -f "$trust/materialized-at" ] ||
      fail "trustd did not record the materialization instant"
    # Rendered at the instant trustd recorded, so the equality is exact even if a
    # TTL boundary would otherwise fall between two wall-clock reads.
    fleet_trust_roster_at_head "$store" "$head" "$tr/oracle" \
      "$(cat "$trust/materialized-at")"
    cmp -s "$trust/allowed_signers" "$tr/oracle" ||
      fail "trustd's materialized roster differs from the roster the read path derives"
    [ -z "$(fleet_trust_materialization_drift "$store")" ] ||
      fail "a trustd-materialized roster already disagrees with the ratchet (§7.9)"
    # The KRL is taken under custody too, so an unresolvable path can never make
    # every signature read bad.
    [ -f "$trust/krl" ] || fail "trustd left no KRL under \$TRUST"

    # (b) INPUT VALIDATION / fail-closed on every bad argument.
    tr_reject apply                          # too few args
    tr_reject apply "$store"                  # missing rev
    tr_reject apply "$store" "$head" extra    # too many args
    tr_reject apply /nonexistent "$head"      # store absent
    tr_reject apply relative/store "$head"    # store not absolute
    tr_reject apply "$store" 'all()'          # a revset function, not a bare token
    tr_reject apply "$store" 'x y'            # whitespace in the token
    tr_reject apply "$store" 'no-such-commit' # unresolvable revision
    tr_reject unknown-subcommand              # unknown verb
    # A revision that does not descend from the genesis pin is refused: the
    # store's virtual root is an ANCESTOR of the genesis, never a descendant.
    tr_root=$(jj -R "$store" log -r 'root()' --no-graph -T 'commit_id ++ "\n"' | head -1)
    [ -z "$tr_root" ] || tr_reject apply "$store" "$tr_root"

    # (c) GENERATION MONOTONICITY — a high-water mark above the store's
    # generation makes trustd refuse rather than roll back (§7.12.3).
    printf '%s\n' "$head" >"$trust/reviewed-ref"
    printf '99\n' >"$trust/generation"
    tr_reject apply "$store" "$head"
    # And with the high-water restored, the same apply is accepted again — the
    # refusal was the generation, not a wedged fixture.
    rm -f "$trust/generation"
    tr_apply apply "$store" "$head" ||
      fail "trustd refused a legitimate re-apply after the generation was reset"

    # (d) DEGRADE PATH — with no privileged lane, fleet_trust_materialize writes
    # the roster SAME-USER (the current behaviour, reported by the doctor's
    # privileged-lane row, which tests/94-jj-doctor.sh asserts stays OK-DEGRADED).
    rm -f "$trust/allowed_signers" "$trust/reviewed-ref" "$trust/generation" \
      "$trust/materialized-at"
    (
      unset ROUNDHOUSE_TRUSTD
      fleet_trust_materialize "$store" "$head"
    ) || fail "the degrade-to-same-user materialize path failed"
    [ -f "$trust/allowed_signers" ] && [ -f "$trust/reviewed-ref" ] ||
      fail "the degrade path wrote no same-user roster"
    [ "$(file_owner "$trust/allowed_signers")" = "$(id -un)" ] ||
      fail "the degrade path did not leave same-user custody"

    # (e) SYMLINK REFUSAL (§7.9 P3) — a symlinked store is refused before it is
    # read. This gate is NOT root-conditional, so it is exercised unprivileged.
    ln -s "$store" "$tr/store-link"
    tr_reject apply "$tr/store-link" "$head"

    # (f) ROUNDHOUSE_TRUSTD_HOME IS SELFTEST-GATED (§7.9 P0). Without the
    # self-check flag a bogus override is IGNORED and trustd uses its co-located
    # library (succeeds); WITH the flag the override is honoured and a bogus home
    # has no library (fails). That asymmetry is the whole gate: a stray env var
    # can never point the root run's sourced code somewhere the caller chose.
    : >"$tr/home-probe"
    (unset ROUNDHOUSE_SELFTEST
      env ROUNDHOUSE_TRUSTD_HOME=/nonexistent-trustd-home \
        "$trustd_bin" selftest-own "$tr/home-probe" >/dev/null 2>&1) ||
      fail "trustd honoured ROUNDHOUSE_TRUSTD_HOME without the self-check flag"
    if env ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUSTD_HOME=/nonexistent-trustd-home \
      "$trustd_bin" selftest-own "$tr/home-probe" >/dev/null 2>&1; then
      fail "trustd ignored a SELFTEST ROUNDHOUSE_TRUSTD_HOME override"
    fi

    # (g) THE INSTALL LANE (§7.9's promised mitigation), gated behind the
    # enrollment fixture since the suite is unprivileged. It roots the binary,
    # the library tree, the pinned toolchain, the sudo lane, and seeds the KRL
    # from the enrollment-time trusted origin.
    ti_root="$tr/install-root"
    mkdir -p "$ti_root/etc/roundhouse/trust"
    # A VALID empty KRL at the enrollment trusted origin (a bogus file would make
    # ssh-keygen read every signature `bad`); the lane copies exactly this.
    ssh-keygen -q -k -f "$ti_root/etc/roundhouse/trust/revoked.krl" >/dev/null 2>&1 ||
      : >"$ti_root/etc/roundhouse/trust/revoked.krl"
    ti_jqdir=$(dirname "$(command -v jq)")
    env ROUNDHOUSE_U2_FIXTURE_ROOT="$ti_root" \
      ROUNDHOUSE_TRUSTD_TOOLCHAIN_SRC="$(dirname "$real_jj"):$(dirname "$real_yq"):$ti_jqdir" \
      "$enroll_bin" install-trustd "$(id -un)" >"$tr/install-out" 2>&1 ||
      fail "install-trustd failed: $(cat "$tr/install-out")"
    tip="$ti_root/usr/local/libexec/roundhouse-trustd"
    titr="$ti_root/usr/local/etc/roundhouse"
    [ -x "$tip/roundhouse-trustd" ] || fail "install lane did not root the trustd binary"
    [ -f "$tip/roundhouse" ] || fail "install lane did not co-locate the roundhouse library"
    [ -f "$tip/lib/fleet-trust.sh" ] || fail "install lane did not co-locate the lib tree"
    [ -f "$tip/toolchain" ] || fail "install lane wrote no toolchain manifest"
    for ti_t in jj yq jq; do
      [ -x "$tip/toolchain.d/$ti_t" ] || fail "install lane did not pin $ti_t root-owned"
    done
    grep -Fq 'NOPASSWD:NOSETENV' "$ti_root/etc/sudoers.d/roundhouse-trustd" ||
      fail "install lane wrote no hermetic sudoers entry"
    [ -f "$titr/krl" ] || fail "install lane did not seed the KRL"
    cmp -s "$ti_root/etc/roundhouse/trust/revoked.krl" "$titr/krl" ||
      fail "the seeded KRL is not the enrollment trusted-origin KRL (§7.9 residual 2)"

    # (h) THE HERMETIC MATERIALIZE THROUGH THE INSTALLED PREFIX. Point the lane
    # at the installed binary and drive fleet_trust_materialize's privileged
    # branch end to end: it invokes trustd through env -i (no sudo, unprivileged),
    # trustd sources the installed prefix's OWN library and materialises root-
    # (here self-, in the fixture) owned, and writes the was-privileged marker.
    rm -f "$titr/allowed_signers" "$titr/reviewed-ref" "$titr/generation" \
      "$titr/materialized-at" "$titr/privileged"
    (
      export ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$titr" \
        ROUNDHOUSE_FLEET_STORE="$store" ROUNDHOUSE_TRUSTD="$tip/roundhouse-trustd" \
        ROUNDHOUSE_TRUSTD_FIXTURE=1 ROUNDHOUSE_TRUSTD_HOME="$tip"
      fleet_trust_materialize "$store" "$head"
    ) || fail "the hermetic privileged materialize through the installed prefix failed"
    [ -f "$titr/allowed_signers" ] ||
      fail "the installed-prefix materialize wrote no roster"
    [ -f "$titr/privileged" ] ||
      fail "trustd wrote no was-privileged marker (§7.9 residual 7)"

    # (i) THE FORCED-DEGRADE FINDING (§7.9 residual 7). With the marker present
    # but no lane configured, the doctor calls the same-user custody a FINDING —
    # a host forced back to same-user is not the seamless never-had-a-lane case.
    # Remove the marker (the never-privileged host) and it is OK-degraded again.
    tr_doctor() {
      env ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$titr" \
        ROUNDHOUSE_FLEET_STORE="$store" "$cli" fleet-doctor 2>&1
    }
    tr_doctor | grep -E '^FINDING +privileged-lane ' | grep -Fq 'residual 7' ||
      fail "the doctor did not flag was-privileged-now-degraded as a finding"
    rm -f "$titr/privileged"
    tr_doctor | grep -E '^ok +privileged-lane ' | grep -Fq DEGRADED ||
      fail "the doctor did not report seamless OK-degraded for a never-privileged host"

    printf 'real-jj: trustd OK (derivation parity, fail-closed validation, generation monotonicity, degrade, symlink refusal, TRUSTD_HOME gating, install lane, hermetic materialize, forced-degrade finding)\n'
  )
fi
