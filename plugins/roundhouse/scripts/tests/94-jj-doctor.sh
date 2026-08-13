# roundhouse self-check — §10.4/§10.6/§10.7 against real jj: the private-remote
# gate on posture.yaml, the redaction sweep over a real push range, the hook
# trust gate end to end, symlink detection over the jj tree, and every doctor
# row — clean first, then one broken store per row.
#
# Sourced by scripts/test-roundhouse in a fixed order, after
# tests/90-jj-bootstrap.sh, whose key/roster/KRL fixture generator and real-jj
# gate this section reuses; not a standalone test file.
# shellcheck shell=bash

docjj_root="$tmp/fleet-doctor-jj"
mkdir -p "$docjj_root"

if [ "$real_jj_ok" != true ]; then
  printf '\n'
  printf '========================================================================\n'
  printf 'NOTICE: real-jj guards and doctor block skipped\n'
  printf '  required: jj >= 0.43 and yq   found: jj %s, yq %s\n' \
    "${real_jj_version:-none}" "${real_yq:-none}"
  printf '  §10.4 the sweep, §10.6 the guards and §10.7 doctor are UNVERIFIED.\n'
  printf '========================================================================\n'
  printf '\n'
else
  printf 'real-jj: §10.4 sweep, §10.6 guards, §10.7 doctor (jj %s)\n' "$real_jj_version"
  (
    set -eu
    fail() {
      printf 'FAIL: real-jj: %s\n' "$*" >&2
      exit 1
    }
    PATH="$(dirname "$real_jj"):$(dirname "$real_yq"):$PATH"
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    rjj="$docjj_root/real"
    mkdir -p "$rjj"
    cat >"$rjj/jj-config.toml" <<'TOML'
[user]
name = "roundhouse selfcheck"
email = "roundhouse-selfcheck@example.invalid"
[ui]
paginate = "never"
editor = "true"
TOML
    export JJ_CONFIG="$rjj/jj-config.toml"
    # jj 0.44 migrates `--repo` config out of the store, so every effective
    # read must run in the SAME XDG root as the write that produced it — which
    # is exactly what doctor's config-pins row depends on.
    export XDG_CONFIG_HOME="$rjj/xdg"
    export HOME="$rjj/home"
    mkdir -p "$HOME"

    rjj_key vireo
    rjj_krl seed.krl
    "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"

    doc="$rjj/vireo/store"
    docjj() {
      env ROUNDHOUSE_FLEET_STORE="$doc" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/vireo-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/vireo" \
        "$@"
    }
    docjj_lib() {
      env ROUNDHOUSE_FLEET_STORE="$doc" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/vireo-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/vireo" \
        bash -c 'ROUNDHOUSE_LIB_ONLY=1 . "$0"; shift; "$@"' "$cli" -- "$@"
    }
    docjj_probe() {
      # The visibility probe is a TEST hook, inert without the suite's own
      # kill-switch: relocating what proves a remote private is relocating a
      # gate, and a stray environment variable must never be able to do that.
      env ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_FLEET_VISIBILITY_PROBE="$1" \
        ROUNDHOUSE_FLEET_STORE="$doc" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/vireo-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/vireo" \
        "$cli" fleet-verify-remote
    }
    docjj_doctor() {
      # Doctor is READ-ONLY and its exit status is the contract: 0 clean, 1
      # with findings. Both are captured, never asserted from the text alone.
      docjj_status=0
      docjj_rows=$(docjj "$cli" fleet-doctor 2>&1) || docjj_status=$?
      printf '%s\n' "$docjj_rows"
    }
    docjj_row_ok() {
      printf '%s\n' "$docjj_rows" | grep -qE "^ok +$1 " ||
        fail "doctor row $1 did not pass on a clean store: $(printf '%s\n' "$docjj_rows" | grep -E "$1 " || printf '<absent>')"
    }
    docjj_row_fires() {
      printf '%s\n' "$docjj_rows" | grep -qE "^FINDING +$1 " ||
        fail "doctor row $1 did not fire when it should have"
      [ "$docjj_status" -eq 1 ] ||
        fail "doctor exited $docjj_status with a finding on its $1 row"
    }

    mkdir -p "$rjj/vireo"
    printf 'name: vireo\ndomain: fleet.example.invalid\n' \
      >"$rjj/vireo/identity.yaml"
    docjj "$cli" fleet-init >/dev/null || fail "fleet-init failed"
    jj -R "$doc" git remote add origin "$rjj/remote.git" >/dev/null
    docjj "$cli" fleet-enroll >/dev/null || fail "fleet-enroll failed"

    mkdir -p "$doc/hosts"
    cat >"$doc/fleet.yaml" <<'YAML'
policy:
  fast_interval_minutes: 20
  fast_jitter_minutes: 5
  cadence_hours: 12
  jitter_minutes: 90
plugins:
  ponytail: enabled
hooks:
  commit-guard: enabled
  ponytail/session-start: enabled
YAML
    printf 'platform: macos\ngroups: [development]\nhostname: vireo.invalid\nuser: claire\n' \
      >"$doc/hosts/vireo.yaml"

    # --- §10.6 the private-remote first-push gate, BEFORE anything publishes -
    # The logic carries verbatim from v1; only its reads change. The flag lives
    # host-local in store.local/posture.yaml, the remote is read with
    # `jj git remote list`, and "never pushed" is `present(main@origin)` empty
    # — no `git remote get-url`, no `git show-ref`.
    docjj_status=0
    docjj_out=$(docjj "$cli" fleet-run --fast 2>&1) || docjj_status=$?
    [ "$docjj_status" -ne 0 ] ||
      fail "the first push went out with the remote's visibility unverified"
    case $docjj_out in
      *'verified-private remote'*) ;;
      *) fail "the first-push refusal did not say what it wanted: $docjj_out" ;;
    esac
    [ -z "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" ] ||
      fail "the refused run pushed anyway"

    # A FAILED PROBE IS NOT EVIDENCE OF PRIVACY. Three verdicts, and only one
    # of them opens the gate.
    docjj_status=0
    docjj_probe 'exit 0' >/dev/null 2>&1 || docjj_status=$?
    [ "$docjj_status" -eq 65 ] ||
      fail "a remote answering unauthenticated reads was accepted as private"
    [ "$(docjj_lib fleet_posture_get remote_visibility_reason)" = public ] ||
      fail "the public verdict was not recorded"
    docjj_status=0
    docjj_probe 'printf "could not resolve host\n" >&2; exit 128' >/dev/null 2>&1 ||
      docjj_status=$?
    [ "$docjj_status" -eq 65 ] ||
      fail "an unreachable remote satisfied the first-push gate"
    [ "$(docjj_lib fleet_posture_get remote_visibility_reason)" = probe-inconclusive ] ||
      fail "an inconclusive probe was not recorded as inconclusive"
    docjj_probe 'printf "Permission denied (publickey)\n" >&2; exit 128' >/dev/null ||
      fail "an authentication refusal did not verify the remote as private"
    [ "$(docjj_lib fleet_posture_get remote_visibility_verified)" = true ] ||
      fail "the auth-required verdict did not open the gate"

    docjj_out=$(docjj "$cli" fleet-run --fast) ||
      fail "the run failed once the remote was verified: $docjj_out"
    case $docjj_out in
      *published*) ;;
      *) fail "the run did not publish after the gate opened: $docjj_out" ;;
    esac

    # --- §10.6 a RE-POINT lands the remote, defers the push, re-arms the gate --
    # Both faces of fleet-set-remote in one move. The store has already pushed to
    # origin, so main@origin is non-empty; jj keys that ref by remote NAME, so a
    # re-point to a NEW URL leaves it naming the OLD remote's tip. The old gate
    # read that as "already pushed" and skipped the posture check, publishing to
    # a possibly-public remote ungated; the old set-remote also pushed inline and
    # rolled the remote back on refusal, which is what deadlocked a fresh
    # bootstrap. Now the remote is LANDED, the push DEFERRED, the posture
    # invalidated, and the URL-keyed gate refuses until the new remote is
    # verified.
    "$REAL_GIT" init -q --bare -b main "$rjj/remote2.git"
    docjj_status=0
    docjj_out=$(docjj "$cli" fleet-set-remote "$rjj/remote2.git" 2>&1) || docjj_status=$?
    [ "$docjj_status" -eq 0 ] ||
      fail "fleet-set-remote to a fresh remote failed instead of landing it: $docjj_out"
    case $docjj_out in
      *'nothing pushed yet'*) ;;
      *) fail "fleet-set-remote did not defer the first push: $docjj_out" ;;
    esac
    # jj canonicalizes a local remote path (/var → /private/var on macOS), so
    # compare against the realpath jj actually stores, not the literal.
    [ "$(docjj_lib fleet_remote_url "$doc")" = "$(cd "$rjj/remote2.git" && pwd -P)" ] ||
      fail "fleet-set-remote did not land the new origin URL locally"
    [ -z "$("$REAL_GIT" -C "$rjj/remote2.git" show-ref 2>/dev/null)" ] ||
      fail "fleet-set-remote PUSHED to the new remote instead of deferring the first push"
    # The gate refuses the re-pointed remote even though main@origin is a stale
    # non-empty ref — the skip is closed.
    docjj_status=0
    docjj_lib fleet_first_push_gate "$doc" >/dev/null 2>&1 || docjj_status=$?
    [ "$docjj_status" -eq 65 ] ||
      fail "the URL-keyed gate did not refuse the re-pointed unverified remote (got $docjj_status)"
    # Once the NEW remote is verified, the gate opens for it.
    docjj_probe 'printf "Permission denied (publickey)\n" >&2; exit 128' >/dev/null ||
      fail "verifying the re-pointed remote did not record its posture"
    docjj_status=0
    docjj_lib fleet_first_push_gate "$doc" >/dev/null 2>&1 || docjj_status=$?
    [ "$docjj_status" -eq 0 ] ||
      fail "the gate stayed shut after the new remote was verified (got $docjj_status)"
    # Put origin back so the sections below keep using the original remote.
    jj -R "$doc" git remote set-url origin "$rjj/remote.git" >/dev/null
    docjj_probe 'printf "Permission denied (publickey)\n" >&2; exit 128' >/dev/null || :

    # --- §5.1.3 the hook trust gate, end to end ---
    # Both hooks are enabled in the layers. Neither may run: the standalone one
    # has no trusted source and no install path, and the plugin-delivered one
    # rides a plugin whose approval this host does not hold.
    docjj_journal="$doc/journal/vireo"
    for docjj_hook in 'hooks.commit-guard' 'hooks.ponytail/session-start'; do
      grep -rhq "item: $docjj_hook" "$docjj_journal" ||
        fail "$docjj_hook was never reviewed or journaled"
      [ -z "$(docjj_lib fleet_applied_digest "$doc" vireo "$docjj_hook")" ] ||
        fail "$docjj_hook was applied with no trust behind it"
    done
    grep -rlq . "$doc/alerts/vireo" 2>/dev/null &&
      grep -rhq 'enabled_but_untrusted' "$doc/alerts/vireo" ||
      fail "an untrusted enabled hook was held silently instead of being reported"
    # THE TRANSIENT WINDOW, which is what made `hooks` a held category until the
    # gate existed: nothing was installed and then removed either. The store's
    # own applied record is the only place an install is ever recorded, and a
    # standalone hook has no other side effect to look for.
    ! grep -rhq 'hooks.commit-guard' "$doc/applied" 2>/dev/null ||
      fail "a standalone hook reached applied/ at any point"

    # Approving the plugin approves its hooks (§5.1.3), and "approval this host
    # holds" is this host's own applied record — which an item reaches only by
    # passing this host's review, canary and apply gates. The install itself is
    # stood in for: `claude` is not on a CI runner, and what is under test is
    # the gate's reading of the record rather than the plugin installer.
    docjj_lib fleet_applied_record "$doc" vireo plugins.ponytail sha-pony \
      "$(docjj_lib fleet_now)"
    docjj "$cli" fleet-run --fast >/dev/null ||
      fail "the run failed after the plugin approval landed"
    [ -n "$(docjj_lib fleet_applied_digest "$doc" vireo 'hooks.ponytail/session-start')" ] ||
      fail "a hook riding an approved plugin was still refused"
    [ -z "$(docjj_lib fleet_applied_digest "$doc" vireo hooks.commit-guard)" ] ||
      fail "the standalone hook was trusted alongside the plugin-delivered one"

    # --- §10.6 store-symlink detection, over the TRACKED tree ---
    # Re-implemented: the v1 walk was a raw `git ls-tree -r <status-ref>`, a
    # banned git call against a deleted ref. And the detector must be scoped to
    # the tracked tree, because jj 0.44's own config migration leaves a symlink
    # into $HOME inside `.jj/`.
    ln -s /etc/passwd "$doc/hosts/evil.yaml"
    jj -R "$doc" describe -m "a symlink lands in the tree

$(docjj_lib fleet_vcs_trailers vireo interactive/human 'symlink fixture' -)" >/dev/null
    docjj_head=$(jj -R "$doc" log -r @ --no-graph -T 'commit_id')
    docjj_links=$(docjj_lib fleet_store_symlinks "$doc" "$docjj_head")
    printf '%s\n' "$docjj_links" | grep -Fqx hosts/evil.yaml ||
      fail "the jj-tree symlink walk missed a symlink in the store: $docjj_links"
    printf '%s\n' "$docjj_links" | grep -q '\.jj/' &&
      fail "the symlink walk left the tracked tree and reported jj's own plumbing"
    # The caller-relative trap: `jj file list` without a template prints paths
    # relative to the CALLER's directory, and the walk must not.
    case $docjj_links in
      /* | ../*) fail "the symlink walk reported caller-relative paths: $docjj_links" ;;
    esac
    jj -R "$doc" abandon -r @ >/dev/null
    rm -f "$doc/hosts/evil.yaml"
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null

    # --- §10.4 the redaction sweep, over the range about to be published ---
    # fleet_vcs_trailers does NOT do this: it collapses newlines so the block
    # stays parseable and nothing more. The sweep is the enforcement point.
    docjj_sweep_commit() {
      # One described commit carrying $1 as its description, on top of main.
      printf '%s\n' "$2" >"$doc/hosts/vireo.yaml"
      jj -R "$doc" describe -m "$1" >/dev/null
      jj -R "$doc" bookmark set main \
        -r "$(jj -R "$doc" log -r @ --no-graph -T 'commit_id')" >/dev/null
      jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    }
    docjj_host_yaml='platform: macos
groups: [development]
hostname: vireo.invalid
user: claire
'
    docjj_sweep_commit "converge on vireo

roundhouse-host: vireo
roundhouse-session: scheduled/agent
roundhouse-intent: rotate ghp_0123456789abcdefghij
roundhouse-items: -" "$docjj_host_yaml"
    docjj_status=0
    docjj_out=$(docjj "$cli" fleet-run --fast 2>&1) || docjj_status=$?
    [ "$docjj_status" -ne 0 ] ||
      fail "a token quoted into a roundhouse-intent trailer was published"
    case $docjj_out in
      *'secret class'*) ;;
      *) fail "the sweep refusal did not name what it matched: $docjj_out" ;;
    esac
    case $docjj_out in
      *'description line 5'*) ;;
      *) fail "the sweep refusal did not name the line within the description: $docjj_out" ;;
    esac
    case $docjj_out in
      *abandon* | *'op restore'*) ;;
      *) fail "the sweep refusal did not give the recovery command: $docjj_out" ;;
    esac
    # §10.4's own remedy cannot un-publish, so the refusal has to bite before
    # the wire — and nothing may have gone out.
    [ "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" != \
      "$(docjj_lib fleet_vcs_heads_local "$doc")" ] ||
      fail "the sweep refused after the push rather than before it"

    # The 400-byte cap on replicated free text, on the same walk.
    jj -R "$doc" abandon -r "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj_long=$(awk 'BEGIN { while (n++ < 401) printf "x" }')
    docjj_sweep_commit "converge on vireo

roundhouse-host: vireo
roundhouse-session: scheduled/agent
roundhouse-intent: $docjj_long
roundhouse-items: -" "$docjj_host_yaml"
    docjj_status=0
    docjj_out=$(docjj "$cli" fleet-run --fast 2>&1) || docjj_status=$?
    [ "$docjj_status" -ne 0 ] ||
      fail "a 401-byte roundhouse-intent trailer was published"
    case $docjj_out in
      *'exceeds 400 bytes'*) ;;
      *) fail "the cap refusal did not say what it capped: $docjj_out" ;;
    esac

    # …and the other direction, over the same real range: a description that
    # quotes a COMMIT ID THIS STORE CONTAINS publishes. `fleet-checkpoint`'s own
    # description quotes one, and the entropy heuristic read it as single-case
    # hex and refused the guarded publish — which is how a guard teaches people
    # to route around it.
    #
    # The exemption is PROVED, not inferred from shape: a 40-character
    # lowercase-hex credential and a commit id are the same string, so the
    # sweep asks the repository. That is why this fixture quotes a REAL id out
    # of this store rather than a plausible-looking constant, and why the two
    # refusals below still stand.
    jj -R "$doc" abandon -r "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj_real=$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')
    [ "${#docjj_real}" -eq 40 ] ||
      fail "the fixture commit id is not 40 hex: $docjj_real"
    docjj_sweep_commit "checkpoint 3 through $docjj_real

roundhouse-host: vireo
roundhouse-session: scheduled/agent
roundhouse-intent: seal through $docjj_real
roundhouse-items: -" "$docjj_host_yaml
groups: [development]
"
    docjj_out=$(docjj "$cli" fleet-run --fast 2>&1) ||
      fail "the sweep refused a description quoting a commit id this store contains: $docjj_out"
    [ "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" = \
      "$(docjj_lib fleet_vcs_heads_local "$doc")" ] ||
      fail "the content-address description did not reach the remote"

    # A 40-hex token this store CANNOT resolve is not a content address, and a
    # 64-hex digest has no cheap proof available either. Both still refuse —
    # this is the pair that keeps the exemption from being a hex pass.
    for docjj_notaddr in 8e765ed0c1b24a97ff3d6e5a0b1c2d3e4f506172 \
      9f2c1a4b7e0d3856af91cc42b7e5d80613a4f29cbd75e01834a6c9b2df75e013; do
      jj -R "$doc" abandon -r "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
      jj -R "$doc" bookmark set main \
        -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" >/dev/null
      jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
      docjj_sweep_commit "converge on vireo

roundhouse-host: vireo
roundhouse-session: scheduled/agent
roundhouse-intent: seal through $docjj_notaddr
roundhouse-items: -" "$docjj_host_yaml
groups: [development]
"
      docjj_status=0
      docjj_out=$(docjj "$cli" fleet-run --fast 2>&1) || docjj_status=$?
      [ "$docjj_status" -ne 0 ] ||
        fail "a hex token this store cannot resolve was published as a content address: $docjj_notaddr"
      case $docjj_out in
        *'secret class'*) ;;
        *) fail "the refusal did not name what it matched for $docjj_notaddr: $docjj_out" ;;
      esac
    done
    jj -R "$doc" abandon -r "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null

    # A secret CREATED AND THEN DELETED inside the push range. This is the case
    # the sweep exists for and the one a range diff elides: the working tree is
    # clean by the time anything looks at it.
    jj -R "$doc" abandon -r "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    mkdir -p "$doc/findings/vireo"
    printf 'quote: |\n  export TOKEN=ghp_0123456789abcdefghij\n' \
      >"$doc/findings/vireo/20260807T0914-leak.yaml"
    docjj_sweep_commit "a finding lands

roundhouse-host: vireo
roundhouse-session: scheduled/agent
roundhouse-intent: finding
roundhouse-items: -" "$docjj_host_yaml"
    rm -f "$doc/findings/vireo/20260807T0914-leak.yaml"
    docjj_sweep_commit "and is deleted again

roundhouse-host: vireo
roundhouse-session: scheduled/agent
roundhouse-intent: cleanup
roundhouse-items: -" "$docjj_host_yaml"
    [ ! -f "$doc/findings/vireo/20260807T0914-leak.yaml" ] ||
      fail "the create-then-delete fixture left the file in the tree"
    docjj_status=0
    docjj_out=$(docjj "$cli" fleet-run --fast 2>&1) || docjj_status=$?
    [ "$docjj_status" -ne 0 ] ||
      fail "a secret created and deleted inside the push range was published"
    case $docjj_out in
      *'findings/vireo/20260807T0914-leak.yaml:2'*) ;;
      *) fail "the sweep did not name the file and the line within it: $docjj_out" ;;
    esac

    # Drop both commits from local history the way the refusal says to, and the
    # push succeeds again — a guard that cannot be recovered from is an outage.
    jj -R "$doc" abandon -r "present(main@origin)..heads(bookmarks(exact:\"main\"))" \
      >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj "$cli" fleet-run --fast >/dev/null ||
      fail "the store did not recover after the swept commits were abandoned"

    # --- §10.7 doctor, clean: every row's NON-FIRING case, in one run ---
    # The standalone hook is a genuine finding, so it comes out of the layers
    # before the baseline and goes back in below as that row's firing case.
    docjj_stage() {
      # One described, trailered commit on main, published only when asked:
      # doctor reads the reviewed ref, which is the local bookmark head.
      jj -R "$doc" describe -m "$1

$(docjj_lib fleet_vcs_trailers vireo scheduled/agent "$1" -)" >/dev/null
      jj -R "$doc" bookmark set main \
        -r "$(jj -R "$doc" log -r @ --no-graph -T 'commit_id')" >/dev/null
      jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    }
    docjj_fleet_yaml() {
      cat >"$doc/fleet.yaml" <<YAML
policy:
  fast_interval_minutes: 20
  fast_jitter_minutes: 5
  cadence_hours: 12
  jitter_minutes: 90
plugins:
  ponytail: enabled
hooks:
  ponytail/session-start: enabled
$1
YAML
    }
    docjj_fleet_yaml ''
    docjj "$cli" fleet-run --fast >/dev/null ||
      fail "the run failed after the standalone hook left the layers"

    docjj_doctor >/dev/null
    [ "$docjj_status" -eq 0 ] ||
      fail "doctor found something on a healthy store: $(printf '%s\n' "$docjj_rows" | grep '^FINDING')"
    for docjj_expect in tools genesis-pin config-pins signing-key trust-roots \
      krl privileged-lane trustd-binary head-signature ratchet-replay monotonicity \
      materialization-digest git-cross-check path-identity roster-coherence \
      roster-lines generation class-enforcement soak revsets working-copy \
      undescribed conflicts conflict-paths store-symlinks \
      host-local-leak description-sweep findings-sweep trailers poll-floor \
      remote-posture run-lock rewrite-messages banned-keys digest raw-git-push \
      revert-signature canary-overrides ssh-fields chezmoi hooks \
      machine-truth clock; do
      docjj_row_ok "$docjj_expect"
    done
    [ "$(printf '%s\n' "$docjj_rows" | grep -c '^ok ')" -ge 30 ] ||
      fail "doctor printed fewer than the ~30 rows §10.7 tables"

    # B-3: a checkpoint record without a jj tag is a normal finding, not an
    # arithmetic error from a two-line `grep -c || printf 0` substitution.
    mkdir -p "$doc/checkpoints"
    printf 'checkpoint: untagged\n' >"$doc/checkpoints/untagged.yaml"
    docjj_status=0
    docjj_doctor >/dev/null || docjj_status=$?
    [ "$docjj_status" -eq 1 ] ||
      fail "an untagged checkpoint record did not produce a doctor finding"
    ! printf '%s\n' "$docjj_rows" | grep -Eq 'integer( expression)? expected' ||
      fail "doctor checkpoint arithmetic emitted an integer error: $docjj_rows"
    printf '%s\n' "$docjj_rows" | grep -qE '^FINDING +checkpoint-tags ' ||
      fail "an untagged checkpoint did not fire checkpoint-tags"
    rm -rf "$doc/checkpoints"

    # --- and one broken store per row that can be broken cheaply ---
    # Each of these was observed to fail silently at some point, which is the
    # only reason any of them exists.

    # §5.1.3: an enabled hook nothing trusts is REPORTED, by name.
    docjj_fleet_yaml '  commit-guard: enabled'
    docjj_stage 'a standalone hook returns'
    docjj_doctor >/dev/null
    docjj_row_fires hooks
    docjj_fleet_yaml ''
    docjj_stage 'and leaves again'

    # §7.1: a typo'd KRL path reports every signature `bad`, and a host that
    # can verify nothing converges everything UNVERIFIED. Both read as an
    # attack when they are a missing file, so the skip is surfaced.
    mv "$rjj/vireo/krl" "$rjj/vireo/krl.away"
    docjj_doctor >/dev/null
    docjj_row_fires signature-skip
    mv "$rjj/vireo/krl.away" "$rjj/vireo/krl"

    # §3.1: the pins, by EFFECTIVE value — never by reading a file jj migrated.
    jj -R "$doc" config set --repo ui.paginate auto
    docjj_doctor >/dev/null
    docjj_row_fires config-pins
    jj -R "$doc" config set --repo ui.paginate never

    # §7.5: the store identity is a COMPARISON. Two fleets pointed at one
    # remote is the threat, and only the host-local expected value tells them
    # apart.
    printf 'name: vireo\ndomain: fleet.example.invalid\nstore_id: not-this-fleet\n' \
      >"$rjj/vireo/identity.yaml"
    docjj_doctor >/dev/null
    docjj_row_fires genesis-pin
    printf 'name: vireo\ndomain: fleet.example.invalid\n' \
      >"$rjj/vireo/identity.yaml"

    # §10.6: a host-local file inside the tracked tree is a copy of this
    # machine's identity on every machine.
    cp "$rjj/vireo/identity.yaml" "$doc/identity.yaml"
    jj -R "$doc" describe -m "leak

$(docjj_lib fleet_vcs_trailers vireo interactive/human 'leak fixture' -)" >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj_doctor >/dev/null
    docjj_row_fires host-local-leak
    rm -f "$doc/identity.yaml"

    # §5/§8.2b: a run that stops writing trailers degrades every future
    # conflict to an escalation, and an undescribed ancestor of the bookmark
    # refuses to push forever — the brick that keeps coming back.
    jj -R "$doc" describe -m 'no trailers here' >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj_doctor >/dev/null
    docjj_row_fires trailers

    # §14: no DSC record carries schema: or schema_version: — swept grep-wide
    # rather than row by row, because the stale-lock refusal record carried the
    # same two keys and its §10.6 row mentioned only the threshold.
    printf 'schema: roundhouse.something\n' >"$doc/hosts/schema-probe.yaml"
    docjj_doctor >/dev/null
    docjj_row_fires banned-keys
    rm -f "$doc/hosts/schema-probe.yaml"

    # §10.6: the run lock, past a threshold that is TWO FULL CADENCES and never
    # anything derived from the fast interval.
    docjj_lock=$(docjj_lib fleet_lock_path)
    mkdir -p "$docjj_lock"
    printf '{"host":"vireo","pid":1,"started_at":"2000-01-01T00:00:00Z"}\n' \
      >"$docjj_lock/meta.json"
    docjj_doctor >/dev/null
    docjj_row_fires run-lock
    rm -rf "$docjj_lock"

    # jj#9571: a raw `git push` from the colocated repo bypasses every guard in
    # fleet_vcs_publish, and jj's own refusal is not self-enforcing. Comparing
    # the two sides' commits is not the check — jj auto-imports git refs, so a
    # divergence heals before anything sees it. The configuration that makes a
    # raw push easy does not heal.
    "$REAL_GIT" -C "$doc" config remote.origin.push 'refs/heads/*:refs/heads/*'
    docjj_doctor >/dev/null
    docjj_row_fires raw-git-push
    "$REAL_GIT" -C "$doc" config --unset remote.origin.push

    # --- the §7 rows, FIRED. Every one of these appeared only in the clean
    #     baseline above, which is an assertion a `return 0` also passes.

    # §7.1/§7.3 head-signature, ratchet-replay AND path-identity: an UNSIGNED
    # commit on main, touching a LAYER FILE THAT CARRIES ITEMS.
    #
    # The layer file matters. `fleet_run_signature_holds` emits a hold per ITEM
    # the touched file contributes, so a commit that only rewrites host FACTS
    # (`platform`, `groups`, `hostname`, `user` — all scalars) contributes no
    # items and produces no holds however badly it verifies. That is also why
    # a path-identity violation on an evidence path cannot fire this row: no
    # item resolves from `journal/<h>/`, so there is nothing to hold.
    docjj_fleet_yaml '  unsigned-probe: enabled'
    jj -R "$doc" --config signing.behavior=drop describe -m "unsigned hand edit

$(docjj_lib fleet_vcs_trailers vireo interactive/human 'unsigned fixture' -)" \
      >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj_doctor >/dev/null
    docjj_row_fires head-signature
    docjj_row_fires ratchet-replay
    docjj_row_fires path-identity
    jj -R "$doc" abandon -r 'present(main@origin)..heads(bookmarks(exact:"main"))' \
      >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" \
      >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj_fleet_yaml ''
    docjj_stage 'the unsigned probe leaves the layers'

    # §7.9 materialization-digest: a key appended to the materialized roster is
    # PRECISELY the self-enrollment signature, and the row is the only thing
    # that sees it.
    docjj_signers=$(docjj_lib fleet_allowed_signers_path)
    cp "$docjj_signers" "$rjj/signers.good"
    printf 'attacker@fleet.example.invalid namespaces="git" %s\n' \
      "$(rjj_signer vireo)" >>"$docjj_signers"
    docjj_doctor >/dev/null
    docjj_row_fires materialization-digest
    cp "$rjj/signers.good" "$docjj_signers"
    docjj_doctor >/dev/null
    docjj_row_ok materialization-digest

    # (Its FALSE-POSITIVE side — an ephemeral TTL boundary falling between the
    # materialize and the compare — is asserted directly in
    # tests/91-jj-integrity.sh, where the two instants can be pinned rather
    # than waited for.)
    [ -f "$rjj/vireo/materialized-at" ] ||
      fail "materialize recorded no instant beside the roster, so the compare has none to use"

    # §7.1 monotonicity: a JJ_TIMESTAMP-backdated commit. Its own row, because
    # ratchet-replay deliberately greps the timestamp lines out.
    printf 'probe: backdated\n' >>"$doc/hosts/vireo.yaml"
    JJ_TIMESTAMP='2000-01-01T00:00:00Z' jj -R "$doc" describe -m "backdated

$(docjj_lib fleet_vcs_trailers vireo scheduled/agent 'backdate fixture' -)" \
      >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null
    docjj_doctor >/dev/null
    docjj_row_fires monotonicity
    jj -R "$doc" abandon -r 'present(main@origin)..heads(bookmarks(exact:"main"))' \
      >/dev/null
    jj -R "$doc" bookmark set main \
      -r "$(jj -R "$doc" log -r 'present(main@origin)' --no-graph -T 'commit_id')" \
      >/dev/null
    jj -R "$doc" new "$(docjj_lib fleet_vcs_heads_local "$doc")" >/dev/null

    # §7.1 roster-coherence and soak, over a hand-broken roster: a malformed
    # principal, and a durable member with no `enrolled_at` — the field whose
    # absence used to switch the soak off entirely.
    cp "$doc/trust/signers.yaml" "$rjj/roster.good"
    yq -i -P '.durable.brokenprincipal.principal = "not-a-principal" |
      .durable.brokenprincipal.key = "ssh-ed25519 AAAAbroken"' \
      "$doc/trust/signers.yaml"
    docjj_doctor >/dev/null
    docjj_row_fires roster-coherence
    docjj_row_fires soak
    cp "$rjj/roster.good" "$doc/trust/signers.yaml"

    # §7.1 rule 6 class-enforcement, and the empty class specifically: a class
    # this reader cannot name used to be granted full DURABLE authority, which
    # is exactly what the every-parent intersection produces for a principal
    # whose class disagreed across parents.
    docjj_lib fleet_trust_class_allows '' fleet.yaml &&
      fail "the empty class was granted a fleet-shared layer"
    docjj_lib fleet_trust_class_allows unknown-class trust/signers.yaml &&
      fail "an unrecognised class was permitted to sponsor"
    docjj_lib fleet_trust_class_allows durable fleet.yaml ||
      fail "a durable member was refused a fleet layer"

    # §10.6 run-lock, the OTHER direction: a lock whose meta.json is gone has
    # an unknown age, and reading that as "under the threshold" reported `ok`
    # about the state that wedges every future run on this host forever.
    docjj_lock=$(docjj_lib fleet_lock_path)
    mkdir -p "$docjj_lock"
    docjj_doctor >/dev/null
    docjj_row_fires run-lock
    rm -rf "$docjj_lock"

    printf 'real-jj: OK (first-push gate three verdicts, hook gate both delivery forms, sweep over descriptions and a create-then-delete, symlink walk, doctor clean and %s rows fired)\n' 18
  ) || fail "real-jj guards and doctor block failed (see the FAIL: real-jj: line above)"
fi
