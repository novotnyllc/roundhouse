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
# #62's rule — root never runs a binary the user can replace — is exercised by
# entering the library's root branch with roundhouse_is_root overridden, against
# same-user decoy yq files that log when run, and by checking trustd's and the
# library's ownership rule agree on real paths (trustd's selftest-trusted hook).
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

# --- #62: root never runs a binary the user can replace: no store required ----
(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # ROOT NEVER RUNS A BINARY THE USER CAN REPLACE. Sourcing the library
  # runs select_mikefarah_yq, and choosing a yq means running its `--version`.
  # As root that probe ran Homebrew's, Linuxbrew's or the first-on-PATH yq
  # before trustd's pin applied. The suite is not root, so the root branch is
  # entered by overriding roundhouse_is_root; the ownership rule itself is the
  # real one, and the decoys are ordinary same-user files, which is exactly
  # what a user-writable Homebrew yq is.
  [ "$(head -1 "$trustd_bin")" = '#!/bin/bash -p' ] ||
    fail "#62: trustd's interpreter is found on PATH or imports BASH_ENV and functions"
  grep -q '^  trustd_uid=\$(/usr/bin/id -u 2>/dev/null) || return 0$' "$trustd_bin" ||
    fail "#62: trustd decides it is root from something the environment can supply"
  # bash takes EUID from the environment, so it must never decide rootness.
  ry_euid=$(env EUID=0 /bin/bash -c '. "$1"; roundhouse_is_root && echo root || echo user' _ \
    "$script_dir/lib/host.sh")
  [ "$(id -u)" -eq 0 ] || [ "$ry_euid" = user ] ||
    fail "#62: an EUID=0 in the environment makes the library think it is root"
  # Every root jj call (the library's too) goes through trustd's wrapper, which
  # neutralises every program-bearing jj key whatever config jj loads.
  for ry_flag in trustd_jj_guard --ignore-working-copy signing.backends.gpg.program \
    signing.backends.gpgsm.program signing.behavior fsmonitor.backend ui.paginate; do
    sed -n '/^trustd_pin_toolchain() {$/,/^}$/p' "$trustd_bin" | grep -Fq -- "$ry_flag" ||
      fail "#62: trustd's root jj wrapper does not pin $ry_flag"
  done
  grep -q '^  trustd_envs=\$(compgen -e)' "$trustd_bin" &&
    grep -q '^    darwin\*) HOME=/var/root ;;$' "$trustd_bin" ||
    fail "#62: a root trustd keeps the caller's environment (HOME picks jj's config)"
  ! grep -n 'jj -R ' "$trustd_bin" | grep -v ':[[:space:]]*#' | grep -q . ||
    fail "#62: trustd runs a jj that snapshots (and may sign) the same-user working copy"
  trustd_pin_line=$(grep -n '^trustd_pin_toolchain$' "$trustd_bin" | cut -d: -f1)
  trustd_src_line=$(grep -n '^ROUNDHOUSE_LIB_ONLY=1 \. ' "$trustd_bin" | cut -d: -f1)
  [ -n "$trustd_pin_line" ] && [ -n "$trustd_src_line" ] &&
    [ "$trustd_pin_line" -lt "$trustd_src_line" ] ||
    fail "#62: trustd sources the library (and its yq probes) before pinning the toolchain"
  # A store config that slips past the check dies with a per-run jj HOME
  # instead of persisting in root's own config dir.
  grep -q '^    trustd_jj_home=\$(mktemp -d "\$HOME/' "$trustd_bin" ||
    fail "#62: root jj keeps a HOME that outlives the run (migrated store config persists)"
  grep -q '^    trustd_tool_real=\$(trustd_trusted_path ' "$trustd_bin" ||
    fail "#62: trustd pins a tool without checking every directory above it"

  ry="$trustd_root/root-yq"
  mkdir -p "$ry/path" "$ry/hb/bin" "$ry/linuxbrew/.linuxbrew/bin" \
    "$ry/opt/homebrew/bin" "$ry/usr/local/bin" "$ry/pin"
  # Every decoy claims to be mikefarah yq and leaves a mark when it runs, so a
  # probe of any of them is visible whether or not it would have been chosen.
  for ry_decoy in path hb/bin linuxbrew/.linuxbrew/bin opt/homebrew/bin usr/local/bin pin; do
    printf '#!/bin/sh\necho "%s" >>"%s"\necho "yq (https://github.com/mikefarah/yq/) version v4.44.3"\n' \
      "$ry_decoy" "$ry/ran" >"$ry/$ry_decoy/yq"
    chmod 755 "$ry/$ry_decoy/yq"
  done
  ry_root() {
    # A root context: the decoys first on PATH and at the Homebrew/Linuxbrew
    # locations, and nothing of the suite's own yq selection inherited.
    unset -f yq
    unset ROUNDHOUSE_YQ
    roundhouse_is_root() { return 0; }
    yq_known_locations() {
      printf '%s\n' "$ry/hb/bin/yq" "$ry/linuxbrew/.linuxbrew/bin/yq" \
        "$ry/opt/homebrew/bin/yq" "$ry/usr/local/bin/yq"
    }
  }

  # No trusted yq at all: PATH holds only the decoy, so the outcome is fixed.
  # Selection runs nothing, `yq` refuses, and require_yq fails closed.
  : >"$ry/ran"
  ry_out=$(
    ry_root
    PATH=$ry/path
    select_mikefarah_yq
    [ -z "${ROUNDHOUSE_YQ:-}" ] || printf 'selected %s\n' "$ROUNDHOUSE_YQ"
    yq --version 2>&1 && printf 'yq answered\n'
    (require_yq) 2>&1 && printf 'require_yq passed\n'
    :
  )
  [ ! -s "$ry/ran" ] ||
    fail "#62: root-context yq selection ran a same-user yq: $(tr '\n' ' ' <"$ry/ran")"
  case $ry_out in
    *selected* | *'yq answered'* | *'require_yq passed'*)
      fail "#62: root-context yq selection did not fail closed: $ry_out" ;;
  esac
  case $ry_out in
    *'no root-owned mikefarah yq'*) ;;
    *) fail "#62: the root-context yq refusal names no reason: $ry_out" ;;
  esac

  # A forged pin: ROUNDHOUSE_YQ naming a same-user yq is neither run nor kept.
  : >"$ry/ran"
  ry_out=$(
    ry_root
    PATH=$ry/path
    ROUNDHOUSE_YQ=$ry/pin/yq
    select_mikefarah_yq
    [ -z "${ROUNDHOUSE_YQ:-}" ] || printf 'selected %s\n' "$ROUNDHOUSE_YQ"
    :
  )
  [ ! -s "$ry/ran" ] && [ -z "$ry_out" ] ||
    fail "#62: root-context selection trusted a same-user ROUNDHOUSE_YQ: $ry_out $(tr '\n' ' ' <"$ry/ran")"

  # The pin trustd makes before sourcing: root_trusted_path vouches for the pin
  # alone (the suite cannot make a root-owned file) and stays the real rule for
  # every decoy. The pin is kept, `yq` reaches it, and no decoy ever runs.
  : >"$ry/ran"
  ry_out=$(
    ry_root
    PATH=$ry/path:/usr/bin:/bin
    # Keep the real rule as real_root_trusted_path and vouch only for the pin.
    eval "real_$(declare -f root_trusted_path)"
    root_trusted_path() {
      if [ "$1" = "$ry/pin/yq" ]; then printf '%s\n' "$1"; else real_root_trusted_path "$1"; fi
    }
    ROUNDHOUSE_YQ=$ry/pin/yq
    export ROUNDHOUSE_YQ
    select_mikefarah_yq
    printf 'selected %s\n' "${ROUNDHOUSE_YQ:-}"
    yq --version >/dev/null
    (require_yq) || printf 'require_yq refused\n'
  )
  [ "$ry_out" = "selected $ry/pin/yq" ] ||
    fail "#62: root-context selection did not keep the pinned yq: $ry_out"
  [ "$(sort -u "$ry/ran")" = pin ] ||
    fail "#62: root-context selection with a pin ran: $(sort -u "$ry/ran" | tr '\n' ' ')"

  # The rule itself, in both copies (lib/host.sh's, and trustd's own, which must
  # run before that library is sourced): a root-owned system binary passes with
  # its physical path; a same-user file, a symlink to a trusted binary, a
  # root-owned but world-writable directory (the physical /tmp: on macOS /tmp
  # itself is a symlink) and a relative path do not. The walk over ancestors is
  # exercised here only where it accepts: the suite cannot make a root-owned
  # file under a directory the user can write.
  ln -s /usr/bin/env "$ry/env-link"
  ry_tmp=$(CDPATH='' cd -P /tmp && pwd -P)
  for ry_path in /usr/bin/env "$ry/path/yq" "$ry/env-link" "$ry_tmp" /usr/bin/../bin/env relative/yq; do
    ry_lib=$(root_trusted_path "$ry_path" 2>/dev/null) || ry_lib=refused
    ry_trustd=$("$trustd_bin" selftest-trusted "$ry_path" 2>/dev/null) || ry_trustd=refused
    [ "$ry_lib" = "$ry_trustd" ] ||
      fail "#62: trustd and the library disagree on $ry_path ($ry_trustd vs $ry_lib)"
    case $ry_path in
      /usr/bin/env)
        [ "$ry_lib" = /usr/bin/env ] || fail "#62: root_trusted_path refused root-owned /usr/bin/env" ;;
      /usr/bin/../bin/env)
        [ "$ry_lib" = /usr/bin/env ] || fail "#62: root_trusted_path did not resolve the physical path" ;;
      *)
        [ "$ry_lib" = refused ] || fail "#62: root_trusted_path accepted $ry_path as $ry_lib" ;;
    esac
  done
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
    # This fixture has no remote, so nothing is published and there is no
    # high-water mark to record: reviewed-ref only ever names a commit this
    # host saw on main@origin (§7.12.3). The revision trustd rendered rides in
    # materialized-at, beside the instant, for the drift compare.
    [ -f "$trust/reviewed-ref" ] && [ -z "$(fleet_trust_reviewed_ref)" ] ||
      fail "trustd recorded an unpublished head as reviewed-ref: $(cat "$trust/reviewed-ref" 2>/dev/null)"
    [ "$(fleet_trust_materialized_rev)" = "$head" ] ||
      fail "trustd did not record the revision it rendered"
    [ -f "$trust/materialized-at" ] ||
      fail "trustd did not record the materialization instant"
    # Rendered at the instant trustd recorded, so the equality is exact even if a
    # TTL boundary would otherwise fall between two wall-clock reads.
    fleet_trust_roster_at_head "$store" "$head" "$tr/oracle" \
      "$(fleet_trust_materialized_at)"
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
    # (#62) A store whose own jj config jj would migrate (an in-store
    # config.toml with no config id) is refused, never handed to jj, which
    # would copy it into the caller's HOME and run the programs it names — as
    # root, the user's choice of binary. A store that only has the id is fine.
    for tr_cfg in repo/config workspace-config; do
      case $tr_cfg in
        repo/config) tr_cfg_id=$store/.jj/repo/config-id ;;
        *) tr_cfg_id=$store/.jj/workspace-config-id ;;
      esac
      tr_had_id=false
      [ ! -f "$tr_cfg_id" ] || { tr_had_id=true; mv "$tr_cfg_id" "$tr/cfg-id-aside"; }
      printf '[ui]\npager = "%s/never-run"\n' "$tr" >"$store/.jj/$tr_cfg.toml"
      tr_reject apply "$store" "$head"
      [ ! -e "$tr/never-run" ] || fail "trustd ran a program named in the store's own jj config"
      rm -f "$store/.jj/$tr_cfg.toml"
      [ "$tr_had_id" = false ] || mv "$tr/cfg-id-aside" "$tr_cfg_id"
    done
    # .jj/repo as a file is a secondary workspace pointing at another repo,
    # whose config the check above never sees: refused.
    mv "$store/.jj/repo" "$tr/repo-aside"
    printf '%s\n' "$tr/repo-aside" >"$store/.jj/repo"
    tr_reject apply "$store" "$head"
    rm -f "$store/.jj/repo"
    mv "$tr/repo-aside" "$store/.jj/repo"
    # A revision that does not descend from the genesis pin is refused: the
    # store's virtual root is an ANCESTOR of the genesis, never a descendant.
    tr_root=$(jj -R "$store" log -r 'root()' --no-graph -T 'commit_id ++ "\n"' | head -1)
    [ -z "$tr_root" ] || tr_reject apply "$store" "$tr_root"

    # (c) GENERATION MONOTONICITY — a high-water mark above the store's
    # generation makes trustd refuse rather than roll back (§7.12.3).
    : >"$trust/reviewed-ref"
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

    # (j) THE PUBLISHED-ONLY MARK, MIRRORED (§7.12.3, §7.9 parity). trustd
    #     applies the same rule the run does, through the same library function:
    #     reviewed-ref records the newest commit seen on main@origin, never the
    #     adopted revision itself, so local work it materialized and that was
    #     then abandoned cannot wedge it; a legacy mark on such work is
    #     re-anchored only when proved; and a rewound origin still refuses.
    "$REAL_GIT" init -q --bare -b main "$tr/remote.git"
    jj -R "$store" git remote add origin "$tr/remote.git" >/dev/null
    tr_commit() {
      # tr_commit BASE TEXT -> one signed commit on BASE, as this host.
      jj -R "$store" new "$1" >/dev/null 2>&1
      printf 'probe: %s\n' "$2" >"$store/fleet.yaml"
      jj -R "$store" describe -m "$2" >/dev/null 2>&1
      jj -R "$store" log -r @ --no-graph -T commit_id
    }
    tr_publish() {
      jj -R "$store" bookmark set main --allow-backwards -r "$1" >/dev/null 2>&1
      jj -R "$store" git push --bookmark main >/dev/null 2>&1 ||
        fail "the parity fixture could not publish $1"
    }
    rm -f "$trust/reviewed-ref" "$trust/generation" "$trust/materialized-at"
    tr_pub=$(tr_commit "$head" 'published base')
    tr_publish "$tr_pub"
    tr_apply apply "$store" "$tr_pub" || fail "trustd refused a published head"
    [ "$(fleet_trust_reviewed_ref)" = "$tr_pub" ] ||
      fail "trustd did not record the published head it adopted"
    tr_local=$(tr_commit "$tr_pub" 'local work that never publishes')
    tr_apply apply "$store" "$tr_local" || fail "trustd refused local work atop main@origin"
    [ "$(fleet_trust_reviewed_ref)" = "$tr_pub" ] ||
      fail "trustd advanced reviewed-ref onto unpublished local work"
    [ "$(fleet_trust_materialized_rev)" = "$tr_local" ] ||
      fail "trustd did not record the local revision it rendered"
    jj -R "$store" abandon -r "$tr_local" >/dev/null 2>&1
    tr_moved=$(tr_commit "$tr_pub" 'origin moved on')
    tr_publish "$tr_moved"
    tr_apply apply "$store" "$tr_moved" ||
      fail "REGRESSION (trustd): abandoned local work wedged the privileged lane"
    [ "$(fleet_trust_reviewed_ref)" = "$tr_moved" ] ||
      fail "trustd did not advance reviewed-ref to the published head"
    #     THE PRIVILEGED LANE NEVER MIGRATES. The legacy state an older trustd
    #     left — the rendered local head as the mark, a one-field
    #     materialized-at — is refused even when it is this host's own work:
    #     every input a migration proof reads is same-user state, which is
    #     exactly what this helper does not trust. The operator re-points it.
    tr_legacy=$(tr_commit "$tr_moved" 'a head an older trustd recorded')
    printf '%s\n' "$tr_legacy" >"$trust/reviewed-ref"
    fleet_now >"$trust/materialized-at"
    jj -R "$store" abandon -r "$tr_legacy" >/dev/null 2>&1
    tr_moved2=$(tr_commit "$tr_moved" 'origin moved on again')
    tr_publish "$tr_moved2"
    tr_status=0
    tr_out=$(tr_apply apply "$store" "$tr_moved2" 2>&1) || tr_status=$?
    [ "$tr_status" -eq 65 ] ||
      fail "trustd re-anchored an unpublished mark from same-user evidence (got $tr_status): $tr_out"
    case $tr_out in
      *'is not on main@origin'*'re-point: '*) ;;
      *) fail "trustd's unpublished-mark refusal does not name the re-point command: $tr_out" ;;
    esac
    [ "$(fleet_trust_reviewed_ref)" = "$tr_legacy" ] ||
      fail "a refused trustd apply moved reviewed-ref"
    printf '%s\n' "$tr_moved" >"$trust/reviewed-ref"
    tr_apply apply "$store" "$tr_moved2" ||
      fail "trustd refused the head once the mark was re-pointed"
    #     A rewound origin: the hub goes back one commit, and trustd is asked to
    #     adopt the head it went back to.
    "$REAL_GIT" -C "$tr/remote.git" update-ref refs/heads/main "$tr_moved"
    jj -R "$store" git fetch >/dev/null 2>&1
    [ "$(jj -R "$store" log -r main@origin --no-graph -T commit_id)" = "$tr_moved" ] ||
      fail "the rewound hub head did not arrive"
    tr_status=0
    tr_out=$(tr_apply apply "$store" "$tr_moved" 2>&1) || tr_status=$?
    [ "$tr_status" -eq 65 ] ||
      fail "REWIND (trustd): a rewound origin's head was materialized (got $tr_status): $tr_out"
    case $tr_out in
      *'is not on main@origin'*) ;;
      *) fail "trustd's rewind refusal does not say the mark left main@origin: $tr_out" ;;
    esac
    [ "$(fleet_trust_reviewed_ref)" = "$tr_moved2" ] ||
      fail "a refused trustd apply moved reviewed-ref"

    printf 'real-jj: trustd OK (derivation parity, fail-closed validation, store-config refusal, generation monotonicity, degrade, symlink refusal, TRUSTD_HOME gating, install lane, hermetic materialize, forced-degrade finding, published-only reviewed-ref)\n'
  )
fi
