# roundhouse self-check — the run driver end to end against real jj: the poll
# floor's three states, edit -> propagate -> apply, a conflict the run's own
# agent resolves and publishes, and a revert that is re-reviewed rather than
# matched against a stale verdict.
#
# Sourced by scripts/test-roundhouse in a fixed order, after
# tests/90-jj-bootstrap.sh, whose key/roster/KRL fixture generator and real-jj
# gate this section reuses; not a standalone test file.
# shellcheck shell=bash

runjj_root="$tmp/fleet-run-jj"
mkdir -p "$runjj_root"

if [ "$real_jj_ok" != true ]; then
  printf '\n'
  printf '========================================================================\n'
  printf 'NOTICE: real-jj run block skipped\n'
  printf '  required: jj >= 0.43 and yq   found: jj %s, yq %s\n' \
    "${real_jj_version:-none}" "${real_yq:-none}"
  printf '  §6 propagation, §8.2b resolution and §10.8 rollback are UNVERIFIED.\n'
  printf '========================================================================\n'
  printf '\n'
else
  printf 'real-jj: §6 propagation, §8.2b resolution, §10.8 rollback (jj %s)\n' \
    "$real_jj_version"
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

    rjj="$runjj_root/real"
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
    # read must run in the SAME XDG root as the write that produced it.
    export XDG_CONFIG_HOME="$rjj/xdg"
    export HOME="$rjj/home"
    mkdir -p "$HOME"

    rjj_key vireo
    rjj_key wren
    rjj_krl seed.krl

    "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"

    runjj() {
      # One roundhouse invocation as one host. The store path places the
      # instance; every host-local file follows it.
      runjj_host=$1
      shift
      env ROUNDHOUSE_FLEET_STORE="$rjj/$runjj_host/store" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/$runjj_host-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/$runjj_host" \
        "$@"
    }
    runjj_identity() {
      # §12: identity.yaml is the host's own name, host-local and outside the
      # store. Two instances on one machine are two identity files, which is
      # what makes "run it twice" genuinely the same code (R5).
      mkdir -p "$rjj/$1"
      printf 'name: %s\ndomain: fleet.example.invalid\n' "$1" \
        >"$rjj/$1/identity.yaml"
    }
    runjj_lib() {
      # The same environment, for a helper read rather than a command.
      runjj_host=$1
      shift
      env ROUNDHOUSE_FLEET_STORE="$rjj/$runjj_host/store" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/$runjj_host-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/$runjj_host" \
        bash -c 'ROUNDHOUSE_LIB_ONLY=1 . "$0"; shift; "$@"' "$cli" -- "$@"
    }

    # --- host 1 roots the fleet ---
    runjj_identity vireo
    runjj_identity wren
    runjj vireo "$cli" fleet-init >/dev/null || fail "fleet-init failed on vireo"
    vireo="$rjj/vireo/store"
    jj -R "$vireo" git remote add origin "$rjj/remote.git" >/dev/null
    runjj vireo "$cli" fleet-enroll >/dev/null || fail "fleet-enroll failed on vireo"
    # wren is sponsored by vireo, the way `fleet-add` does it over the SSH lane:
    # a roster line committed BY THE SPONSOR. The channel step is not
    # reproducible in CI, but the roster edit — the only part the ratchet reads
    # — is exactly this.
    rjj_roster "$vireo/trust/signers.yaml" 2 vireo:durable wren:durable
    # §10.6: no FIRST push to a remote whose visibility is unverified. The gate
    # and its three-way verdict are tested in tests/94-jj-doctor.sh; here the
    # verb runs once so the run path is exercised end to end, through the same
    # test hook a real host can never reach.
    env ROUNDHOUSE_SELFTEST=1 \
      ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "Permission denied (publickey)\n" >&2; exit 128' \
      ROUNDHOUSE_FLEET_STORE="$rjj/vireo/store" "$cli" fleet-verify-remote >/dev/null ||
      fail "fleet-verify-remote did not accept an authentication refusal as private"

    mkdir -p "$vireo/hosts"
    cat >"$vireo/fleet.yaml" <<'YAML'
policy:
  fast_interval_minutes: 20
  fast_jitter_minutes: 5
  cadence_hours: 12
  jitter_minutes: 90
config_files:
  ~/.claude/settings.json:
    keys:
      env.DISABLE_TELEMETRY: managed
hooks:
  commit-guard: enabled
YAML
    printf 'platform: macos\ngroups: [development]\nhostname: vireo.invalid\nuser: claire\n' \
      >"$vireo/hosts/vireo.yaml"
    printf 'platform: macos\ngroups: [development]\nhostname: wren.invalid\nuser: claire\n' \
      >"$vireo/hosts/wren.yaml"

    runjj_out=$(runjj vireo "$cli" fleet-run --fast) ||
      fail "the first fleet-run on a fresh fleet failed: $runjj_out"
    case $runjj_out in
      *published*) ;;
      *) fail "the first run did not publish: $runjj_out" ;;
    esac

    # §5.1.3: hooks fold, resolve, review and JOURNAL — and are never applied.
    # "The gate is coming" is not a gate.
    runjj_journal="$vireo/journal/vireo"
    grep -rhq 'item: hooks.commit-guard' "$runjj_journal" ||
      fail "an enabled hook was never reviewed or journaled"
    grep -rh -A2 'item: hooks.commit-guard' "$runjj_journal" | grep -q 'outcome: held' ||
      fail "an enabled hook was applied instead of held (§5.1.3)"
    grep -rhq 'outcome: alive' "$runjj_journal" ||
      fail "the run wrote no §10.1 liveness heartbeat"

    # --- CHARACTERIZATION: where convergence evidence is PUBLISHED (§2) ---
    # Asserted, not assumed, because a plan proposed relocating it. The v2
    # design deleted `host/<name>` branches outright and replaced them with
    # host-keyed PATHS on the one `main` bookmark — the same single-writer
    # guarantee (§7.3's path->identity table enforces it) without a branch
    # checkout that can strand the store. So evidence on `main` is the DESIGN,
    # not a hub leak, and this pins it: the day the topology is deliberately
    # changed, this fixture is the one that says so out loud.
    # See docs/specs/2026-08-10-dsc-scaling.md for the bounding mitigation
    # (journal compaction/TTL) that addresses the growth this shape implies.
    runjj_published=$(jj -R "$vireo" file list \
      -r "$(fleet_vcs_heads_local "$vireo")" -T 'path ++ "\n"')
    printf '%s\n' "$runjj_published" | grep -q "^journal/vireo/" ||
      fail "the hub's convergence journal is not on the published main tree"
    [ -z "$(jj -R "$vireo" bookmark list -a -T 'name ++ "\n"' 2>/dev/null |
      grep '^host/' || true)" ] ||
      fail "a host/<name> bookmark exists; §2 of the v2 design deleted that topology"

    # §5's rendered aliases and the include line that makes them reachable.
    grep -Fq 'Host rh-wren' "$HOME/.ssh/config.d/roundhouse" ||
      fail "the run rendered no ssh aliases from hosts/*.yaml"
    [ "$(head -1 "$HOME/.ssh/config")" = "Include $HOME/.ssh/config.d/roundhouse" ] ||
      fail "the rendered aliases are not included from ~/.ssh/config"

    # §8.1's invariant, and the state every run must end in: @ is an EMPTY
    # child of main, described by nothing. Never a bare `jj new -m ''` — an
    # undescribed ancestor of the bookmark refuses to push forever.
    runjj_shape=$(jj -R "$vireo" log -r @ --no-graph \
      -T 'if(empty,"empty","dirty") ++ " " ++ if(description,"described","undescribed") ++ " " ++ parents.map(|p| p.commit_id()).join(",")')
    [ "$runjj_shape" = "empty undescribed $(fleet_vcs_heads_local "$vireo")" ] ||
      fail "the run did not end with @ an empty child of the published main: $runjj_shape"

    # --- §6.1(a): the poll floor's three states ---
    # 1. fully published + empty @ -> the true no-op, and it says what it cost.
    runjj_out=$(runjj vireo "$cli" fleet-run --fast) ||
      fail "the no-op run failed"
    case $runjj_out in
      *'no fetch'*) ;;
      *) fail "a settled store did not short-circuit at the poll floor: $runjj_out" ;;
    esac
    # 2. a dirty @ is work to publish, even with an unchanged remote.
    printf '# a pending hand edit\n' >>"$vireo/fleet.yaml"
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited on a dirty working copy"
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "the run that publishes a pending hand edit failed"
    # 3. committed but unpushed: `ls-remote` still matches, and rev 5's
    #    remote-only check exited here and left the edit unpublished forever.
    printf '# a second edit\n' >>"$vireo/fleet.yaml"
    jj -R "$vireo" describe -m 'local commit, not pushed' >/dev/null
    jj -R "$vireo" bookmark set main \
      -r "$(jj -R "$vireo" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$vireo" new "$(fleet_vcs_heads_local "$vireo")" >/dev/null
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited with a committed-but-unpushed edit (§6.1a, all three conditions)"
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "the run that publishes an unpushed commit failed"

    # --- host 2 clones and converges: the edit story, end to end ---
    jj git clone --colocate --config ui.editor='"true"' \
      --config ui.paginate=never "$rjj/remote.git" "$rjj/wren/store" >/dev/null 2>&1 ||
      fail "could not clone the fleet store for the second host"
    wren="$rjj/wren/store"
    runjj wren "$cli" fleet-init >/dev/null || fail "fleet-init failed on wren"
    runjj wren "$cli" fleet-enroll >/dev/null || fail "fleet-enroll failed on wren"
    # §10.6: posture is host-local — wren verifies its own cloned remote as
    # private before its first push, exactly as vireo did above (the join flow
    # runs this; the test-hook probe stands in for the unreproducible channel).
    env ROUNDHOUSE_SELFTEST=1 \
      ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "Permission denied (publickey)\n" >&2; exit 128' \
      ROUNDHOUSE_FLEET_STORE="$rjj/wren/store" "$cli" fleet-verify-remote >/dev/null ||
      fail "wren could not verify its cloned remote as private"
    runjj wren "$cli" fleet-run --fast >/dev/null ||
      fail "the second host could not converge on the published state"
    grep -rhq 'item: config_files' "$wren/journal/wren" ||
      fail "the second host reviewed none of the published items"
    [ -n "$(fleet_applied_digest "$wren" wren 'config_files.~/.claude/settings.json')" ] ||
      fail "wren recorded no ownership for an item it converged (§10.3)"

    # A host-layer edit that does not reach the other host is the LAYERING
    # working, not a failure: vireo's own file is not wren's business.
    printf 'platform: macos\ngroups: [development]\nhostname: vireo.invalid\nuser: claire\nskills:\n  ponytail-audit: enabled\n' \
      >"$vireo/hosts/vireo.yaml"
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not publish its host-layer edit"
    runjj wren "$cli" fleet-run --fast >/dev/null ||
      fail "wren could not converge after a host-layer edit elsewhere"
    [ -z "$(fleet_applied_digest "$wren" wren skills.ponytail-audit)" ] ||
      fail "a host-layer edit on vireo reached wren"

    # --- §8.2/§8.2b: a real divergence the run's own agent resolves ---
    # vireo publishes a shared-layer edit; wren has already committed its own,
    # unpushed. Both sides are agent-authored, so rule 2 does not escalate,
    # and only vireo's value is recorded applied by a PEER — which is exactly
    # rule 4's "exactly one side qualifies".
    runjj_fleet_yaml() {
      # The shared layer, rewritten whole: appending a second top-level key
      # would exercise §7.7's duplicate-key row by accident. The contested item
      # is a `config_files` entry because that is a category the apply layer
      # actually converges — an item nothing can apply is never recorded in
      # `applied/`, and §8.2b rule 4 reads exactly that record.
      cat >"$1" <<YAML
policy:
  fast_interval_minutes: 20
  fast_jitter_minutes: 5
  cadence_hours: 12
  jitter_minutes: 90
config_files:
  ~/.claude/settings.json:
    keys:
      env.DISABLE_TELEMETRY: managed
$2
hooks:
  commit-guard: enabled
YAML
    }
    runjj_fleet_yaml "$vireo/fleet.yaml" '  ~/.codex/config.toml:
    keys:
      model: managed'
    # DESCRIBED AGENT-AUTHORED, the same way wren's side is below. Leaving the
    # edit in the working copy makes §8.2 step 1 describe it as
    # `hand edit on vireo` / `interactive/human` — so this side would read as
    # HUMAN and rule 2 would (correctly) escalate before rule 4 was ever
    # consulted. The comment above has always said both sides are
    # agent-authored; until rule 2 could see a side's trailers at all, nothing
    # held the fixture to it.
    jj -R "$vireo" describe -m "converge on vireo

$(fleet_vcs_trailers vireo scheduled/agent 'vireo edit' 'config_files.~/.codex/config.toml')" >/dev/null
    jj -R "$vireo" bookmark set main \
      -r "$(jj -R "$vireo" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$vireo" new "$(fleet_vcs_heads_local "$vireo")" >/dev/null
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not publish the contested edit"

    runjj_fleet_yaml "$wren/fleet.yaml" '  ~/.codex/config.toml:
    keys:
      model: unmanaged'
    jj -R "$wren" describe -m "converge on wren

$(fleet_vcs_trailers wren scheduled/agent 'wren edit' 'config_files.~/.codex/config.toml')" >/dev/null
    jj -R "$wren" bookmark set main \
      -r "$(jj -R "$wren" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$wren" new "$(fleet_vcs_heads_local "$wren")" >/dev/null

    runjj_out=$(runjj wren "$cli" fleet-run --fast) ||
      fail "the run failed on a conflicted bookmark: $runjj_out"
    [ "$(fleet_vcs_heads_local "$wren" | grep -c .)" -eq 1 ] ||
      fail "the conflicted bookmark was never resolved back to one head"
    [ -z "$(fleet_vcs_conflicted "$wren" "$(fleet_vcs_heads_local "$wren")")" ] ||
      fail "the published head is still conflicted (§8.4)"
    grep -rhq 'outcome: resolved' "$wren/journal/wren" ||
      fail "the agent resolution wrote no §5 resolved record"
    # yq quotes the value because the rationale carries a colon.
    grep -rhq "resolution: 'rule 4:" "$wren/journal/wren" ||
      fail "the resolution did not name the ladder rule that decided it"
    # The value that won is the one a peer is actually carrying.
    yq -e '.config_files["~/.codex/config.toml"].keys.model == "managed"' \
      "$wren/fleet.yaml" >/dev/null ||
      fail "the resolution did not land the winning side's value in the working copy"
    # §10.4/§8.4: history may contain a commit that WAS conflicted and was
    # resolved in place; it may never contain a published conflicted tree.
    [ -z "$(fleet_vcs_git_conflict_paths "$wren" "$(fleet_vcs_heads_local "$wren")")" ] ||
      fail "a materialized conflict path reached the published git tree"

    # --- §10.1: the canary gate blocks, and its liveness term is why ---
    # vireo joins the canary group, then publishes something new. wren must
    # WAIT: there is no canary evidence for that digest at any age.
    printf 'platform: macos\ngroups: [development, canary]\nhostname: vireo.invalid\nuser: claire\nskills:\n  ponytail-audit: enabled\n' \
      >"$vireo/hosts/vireo.yaml"
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not publish its canary membership"
    runjj_fleet_yaml "$vireo/fleet.yaml" '  ~/.codex/config.toml:
    keys:
      model: managed
  ~/.gitconfig:
    keys:
      user.name: managed'
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not publish the canary-gated item"
    runjj_out=$(runjj wren "$cli" fleet-run --fast) ||
      fail "wren's run failed while an item waited on the canary"
    case $runjj_out in
      *'no canary evidence'*) ;;
      *) fail "a non-canary host applied an item with no canary evidence: $runjj_out" ;;
    esac
    [ -z "$(fleet_applied_digest "$wren" wren 'config_files.~/.gitconfig')" ] ||
      fail "the canary gate let an unwitnessed item through"

    # --- §10.8: rollback is a signed revert through the ordinary gates ---
    runjj_before=$(yq -o=json -I=0 '.config_files' "$vireo/fleet.yaml")
    runjj_bad=$(fleet_vcs_heads_local "$vireo")
    runjj_out=$(runjj vireo "$cli" fleet-rollback 'config_files.~/.gitconfig') ||
      fail "fleet-rollback failed: $runjj_out"
    # The published head is the run'"'"'s own record commit; the revert sits under
    # it, which is §6 step 6'"'"'s order and not an accident.
    runjj_head=$(fleet_vcs_heads_local "$vireo")
    runjj_revert=
    for runjj_c in $(jj -R "$vireo" log -r "$runjj_bad..$runjj_head" \
      --no-graph -T 'commit_id ++ "\n"'); do
      if jj -R "$vireo" log -r "$runjj_c" --no-graph -T 'description' |
        grep -q '^roundhouse-reverts: '; then
        runjj_revert=$runjj_c
        break
      fi
    done
    [ -n "$runjj_revert" ] ||
      fail "no commit in the published range carries a roundhouse-reverts trailer"
    # …and it CONVERGED onto the MOVED remote. wren advanced main@origin at line
    # 307, so vireo's bare `fleet-rollback` pushed against a stale tracking ref
    # and hit jj's concurrent-move (stale-info) rejection — the routine race the
    # §6.1 fetch→converge→publish cycle absorbs. A bare publisher never fetched,
    # so fleet_vcs_publish fetches, reconciles the revert onto wren's head and
    # re-publishes ONCE (never a force). The proof it did not silently swallow
    # the rejection nor blindly force: local main matches main@origin, and the
    # revert is an ancestor of what actually reached the remote.
    [ "$(fleet_vcs_heads_local "$vireo")" = "$(fleet_vcs_head_origin "$vireo")" ] ||
      fail "the rollback did not converge onto the moved remote (main != main@origin)"
    [ -n "$(jj -R "$vireo" log -r "$runjj_revert & ::present(main@origin)" \
      --no-graph -T 'commit_id')" ] ||
      fail "the reverted change never reached the moved remote head after the concurrent move"
    # The content returns exactly, and the change id is NEW — which is the
    # measurement that makes the revert-signature predicate necessary.
    yq -e '.config_files["~/.gitconfig"] == null' "$vireo/fleet.yaml" >/dev/null ||
      fail "the revert did not restore the prior content: $runjj_before"
    # The revert reversed the LAYER and left this run'"'"'s evidence alone: a
    # whole-commit reverse would delete journal records peers already saw and
    # make the host disown what it installed (§10.3).
    grep -rhq 'outcome: alive' "$vireo/journal/vireo" ||
      fail "the rollback reversed the journal along with the layer edit"
    [ "$(jj -R "$vireo" log -r "$runjj_revert" --no-graph -T 'change_id')" != \
      "$(jj -R "$vireo" log -r "$runjj_bad" --no-graph -T 'change_id')" ] ||
      fail "the revert reused the reverted change's id"
    jj -R "$vireo" log -r "$runjj_revert" --no-graph -T 'description' |
      grep -q '^roundhouse-reverts: ' ||
      fail "the revert commit carries no roundhouse-reverts trailer"
    grep -rhq 'outcome: reverted' "$vireo/journal/vireo" ||
      fail "the rollback journaled no reverted record"

    # `--now` is the ONLY canary bypass in the design, so it is bound rather
    # than being a flag that turns a gate off: it is refused for anything that
    # is not a verified revert this host previously applied and withdrew.
    runjj_fleet_yaml "$vireo/fleet.yaml" '  ~/.codex/config.toml:
    keys:
      model: managed
  ~/.ssh/config:
    keys:
      Compression: managed'
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not publish the forward change"
    runjj_status=0
    runjj_out=$(runjj vireo "$cli" fleet-rollback 'config_files.~/.ssh/config' --now 2>&1) ||
      runjj_status=$?
    [ "$runjj_status" -eq 65 ] ||
      fail "--now accelerated a change this host never applied and withdrew (got $runjj_status)"
    case $runjj_out in
      *refused*) ;;
      *) fail "the --now refusal did not say what it refused: $runjj_out" ;;
    esac

    printf 'real-jj: OK (poll floor three states, propagate and apply, hooks held, rule-4 resolution, canary gate, revert and --now binding)\n'
  ) || fail "real-jj run block failed (see the FAIL: real-jj: line above)"
fi
