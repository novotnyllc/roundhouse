# roundhouse self-check — the run driver end to end against real jj: the poll
# floor's three states, edit -> propagate -> apply, a conflict the run's own
# agent resolves and publishes, and a revert that is re-reviewed rather than
# matched against a stale verdict.
#
# Sourced by scripts/test-roundhouse in a fixed order, after
# tests/90-jj-bootstrap.sh, whose key/roster/KRL fixture generator and real-jj
# gate this section reuses; not a standalone test file.
# shellcheck shell=bash
#
# Part 1 is the two-host story; parts 2-3 the independent one-host scenarios;
# parts 4-6 the §7.12.3 reviewed-ref scenarios, each on its own fresh fleet.
# Split so no unit nears the 10-minute test cap on a macOS runner.
# roundhouse-test: parts=6

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
elif section_part 1; then
  printf 'real-jj: §6 propagation, §8.2b resolution, §10.8 rollback (jj %s)\n' \
    "$real_jj_version"
  (
    set -eu
    fail() {
      printf 'FAIL: real-jj: %s\n' "$*" >&2
      exit 1
    }
    # The ssh stub must still win when a real yq lives beside a real ssh
    # (/usr/bin on Linux runners): a directory holding only the stub, first.
    mkdir -p "$tmp/ssh-stub-only" && ln -sf "$tmp/bin/ssh" "$tmp/ssh-stub-only/ssh"
    PATH="$tmp/ssh-stub-only:$(dirname "$real_jj"):$(dirname "$real_yq"):$PATH"
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

    # --- §6.1(a)/§6.4: the poll floor's states ---
    # 1. fully published + empty @ -> the true no-op, and it says what it cost.
    runjj_out=$(runjj vireo "$cli" fleet-run --fast) ||
      fail "the no-op run failed"
    case $runjj_out in
      *'nothing new on the remote'*'no convergence pass'*) ;;
      *) fail "a settled store did not short-circuit at the poll floor: $runjj_out" ;;
    esac
    # The floor's fetch moves no jj-visible ref: main@origin is what the last
    # full pass gated, and the next one gates everything after it (§7.7).
    "$REAL_GIT" -C "$vireo" rev-parse --verify --quiet \
      refs/roundhouse/poll-floor/main >/dev/null ||
      fail "the poll floor did not fetch into its private ref"
    # A heartbeat that is owed is work: only a pass that reaches the end
    # publishes one (§6.3), so the floor must not exit past it.
    runjj_hb="$rjj/vireo/store.run/heartbeat.json"
    cp "$runjj_hb" "$runjj_hb.saved"
    rm -f "$runjj_hb"
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited while a published heartbeat was owed"
    mv "$runjj_hb.saved" "$runjj_hb"
    # …and so is an item waiting on canary evidence, which arrives as records.
    : >"$rjj/vireo/store.run/canary-waiting"
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited while an item waited on canary evidence"
    rm -f "$rjj/vireo/store.run/canary-waiting"
    # …and so is a retry owed: a failed apply or transiently unreadable gate
    # input, or a host-local verdict nothing on the remote carries.
    : >"$rjj/vireo/store.run/retry-owed"
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited while a retry was owed"
    rm -f "$rjj/vireo/store.run/retry-owed"
    runjj vireo "$cli" fleet-review hooks.commit-guard hold 'probe' >/dev/null ||
      fail "fleet-review could not record a verdict"
    [ -e "$rjj/vireo/store.run/retry-owed" ] ||
      fail "a host-local fleet-review verdict did not make the next pass owed"
    rm -f "$rjj/vireo/store.run/retry-owed" "$rjj/vireo/store.run/verdicts/hooks.commit-guard.yaml"
    # The comparison base is the converged REFERENCE's desired state.
    [ -s "$rjj/vireo/store.run/converged-desired" ] ||
      fail "the publishing pass recorded no converged desired-state digest"
    runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor did not exit on a settled store after the probes"
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

    # --- §10.1: `satisfied` IS canary evidence; `held` still is not ---
    # THE BUG THIS REPRODUCES: an item in a category with no state-alignment
    # verb (B-3 — agents, mcp_servers, projects) can never produce an `applied`
    # record on ANY host. The canary gate accepted only `applied`, so every
    # non-canary host waited on evidence that could not exist, forever, while
    # the canary itself journaled the item as `held` — indistinguishable in an
    # audit from an item a gate refused.
    #
    # A new GROUP layer rather than another fleet.yaml rewrite: both hosts are
    # in `development`, wren has no copy of this file, so it propagates with no
    # contest and this fixture cannot be read as a conflict-resolution test.
    # `canary_wait_hours: 0` because the soak is not what is under test here —
    # tests/72-records.sh owns the wait, the withdrawal and the liveness term.
    mkdir -p "$vireo/groups"
    cat >"$vireo/groups/development.yaml" <<'YAML'
policy:
  canary_wait_hours: 0
mcp_servers:
  context7: enabled
YAML
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "the canary could not publish the no-apply-path item"
    # The canary records it SATISFIED, not held: no-op-because-correct is a
    # different fact from no-op-because-blocked and the journal says which.
    grep -rh -A2 'item: mcp_servers.context7' "$vireo/journal/vireo" |
      grep -q 'outcome: satisfied' ||
      fail "the canary journaled no satisfied outcome for an item with no apply verb"
    ! grep -rh -A2 'item: mcp_servers.context7' "$vireo/journal/vireo" |
      grep -q 'outcome: held' ||
      fail "the canary still journaled held for an already-satisfied item"

    runjj_out=$(runjj wren "$cli" fleet-run --fast) ||
      fail "wren's run failed on the satisfied item"
    case $runjj_out in
      *'wait  mcp_servers.context7'*)
        fail "the downstream host is still waiting on canary evidence that can never exist: $runjj_out"
        ;;
    esac
    grep -rh -A2 'item: mcp_servers.context7' "$wren/journal/wren" |
      grep -q 'outcome: satisfied' ||
      fail "the downstream host never converged the satisfied item"

    # …and the other half, which is what keeps this from being a false green:
    # a genuinely BLOCKED item on the canary still blocks downstream. The
    # standalone hook is held by §5.1.3's trust gate on every host, so its
    # journal record stays `held` and wren must keep waiting on it.
    grep -rh -A2 'item: hooks.commit-guard' "$vireo/journal/vireo" |
      grep -q 'outcome: held' ||
      fail "the blocked item stopped journaling held"
    case $runjj_out in
      *'wait  hooks.commit-guard'*) ;;
      *) fail "a downstream host stopped waiting on an item the canary could not apply: $runjj_out" ;;
    esac

    # --- §6.4: peers' record commits no longer defeat the floor ---
    # Settle vireo, then let wren publish a pass whose commit carries only
    # records (it is waiting on canary evidence, so it journals `held`).
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not settle before the floor probes"
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not settle before the floor probes"
    runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "vireo was not settled at the poll floor before the record-only probe"
    runjj_converged=$(cat "$rjj/vireo/store.run/converged")
    runjj_nudges="$rjj/nudges.log"
    : >"$runjj_nudges"
    SSH_COMMAND_LOG=$runjj_nudges runjj wren "$cli" fleet-run --fast >/dev/null ||
      fail "wren could not publish its record-only pass"
    # §6.1: a records-only publish nudges nobody — two hosts waiting on one
    # canary would otherwise nudge each other every pass for the whole wait.
    ! grep -q 'fleet-trigger' "$runjj_nudges" ||
      fail "a records-only publish nudged a peer"
    runjj_remote=$("$REAL_GIT" -C "$vireo" ls-remote origin refs/heads/main |
      awk '{ print $1; exit }')
    [ "$runjj_remote" != "$runjj_converged" ] ||
      fail "wren's pass published nothing, so the record-only probe proves nothing"
    # shellcheck disable=SC2046 # the desired-state roots, one pathspec each
    [ -z "$("$REAL_GIT" -C "$vireo" fetch --quiet --refmap= origin \
      "+refs/heads/main:refs/selfcheck/probe" 2>&1 && "$REAL_GIT" -C "$vireo" \
      diff --name-only "$runjj_converged" refs/selfcheck/probe -- \
      $(fleet_vcs_desired_roots))" ] ||
      fail "wren's probe commit touched desired state, so it is not record-only"
    runjj_origin_before=$(fleet_vcs_head_origin "$vireo")
    runjj_out=$(runjj vireo "$cli" fleet-run --fast) ||
      fail "vireo's run after a peer's record-only commit failed"
    case $runjj_out in
      *'record-only commit(s) on the remote'*'no convergence pass'*) ;;
      *) fail "a peer's record-only commit defeated the poll floor (§6.4): $runjj_out" ;;
    esac
    [ "$(fleet_vcs_head_origin "$vireo")" = "$runjj_origin_before" ] ||
      fail "the poll floor moved main@origin, dropping the skipped commits out of the next pass's §7.7 range"
    # §6.3: the same record-only commit IS work when it can end a silence.
    # Had vireo's last scan found wren silent, wren's journal in it is the
    # recovery that would otherwise leave the stale-host alert standing.
    runjj_live="$rjj/vireo/store.run/liveness.json"
    [ -s "$runjj_live" ] || fail "the converging pass recorded no stale-host scan state"
    cp "$runjj_live" "$runjj_live.saved"
    runjj_live_set() { jq -c "$1" "$runjj_live.saved" >"$runjj_live"; }
    runjj_live_set '.watch = ["wren"]'
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor sat out a silent peer's record-only commit (its stale-host alert would outlive the recovery)"
    # A watched peer the new commits do not touch is not work…
    runjj_live_set '.watch = ["no-such-peer"]'
    runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "a watched peer with no new journal kept the poll floor open"
    # …and neither is time, until a heard peer ages out of the window.
    runjj_live_set '.due = 0'
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited past a due stale-host scan (a peer could go stale unalerted)"
    mv "$runjj_live.saved" "$runjj_live"
    # A desired-state change from a peer DOES defeat it, and the next pass
    # converges on it.
    printf '# a peer edit to a shared layer\n' >>"$wren/groups/development.yaml"
    # The fixture ssh cannot reach a real peer, so an earlier nudge may have
    # parked vireo in the one-interval unreachable memo; clear it.
    rm -f "$rjj/wren/store.run/nudge-unreachable"
    runjj_wren_out=$(SSH_COMMAND_LOG=$runjj_nudges runjj wren "$cli" fleet-run --fast 2>&1) ||
      fail "wren could not publish its layer edit: $runjj_wren_out"
    grep -q 'rh-vireo.*fleet-trigger --fast' "$runjj_nudges" ||
      fail "a publish that changed desired state nudged nobody (nudges: $(cat "$runjj_nudges"); memo: $(cat "$rjj/wren/store.run/nudge-unreachable" 2>&1); pass: $(printf '%s\n' "$runjj_wren_out" | grep -v '^Working copy\|^Parent commit\|^Moved' | tail -15))"
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited past a peer's layer edit"
    runjj vireo "$cli" fleet-run --fast >/dev/null ||
      fail "vireo could not converge on the peer's layer edit"
    grep -Fq '# a peer edit to a shared layer' "$vireo/groups/development.yaml" ||
      fail "vireo's pass did not converge on the peer's layer edit"
    runjj vireo "$cli" fleet-run --fast >/dev/null || :
    runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "vireo did not settle at the poll floor after converging"

    # A fetched head that does not descend from what this host converged on
    # is a re-root or a rollback: the full pass's archive check, never the
    # floor's to sit out. (Last, because it rewrites the shared remote.)
    runjj_orphan="$rjj/orphan"
    "$REAL_GIT" init -q -b main "$runjj_orphan"
    for runjj_root in $(fleet_vcs_desired_roots); do
      [ ! -e "$vireo/$runjj_root" ] || cp -R "$vireo/$runjj_root" "$runjj_orphan/"
    done
    "$REAL_GIT" -C "$runjj_orphan" add -A
    "$REAL_GIT" -C "$runjj_orphan" -c user.name=x -c user.email=x@example.invalid \
      -c commit.gpgsign=false commit -qm 'unrelated history'
    # Same desired state, so only the ancestry check can refuse it.
    [ "$(fleet_vcs_desired_digest "$runjj_orphan" HEAD)" = \
      "$(cat "$rjj/vireo/store.run/converged-desired")" ] ||
      fail "the unrelated head differs in desired state, so it does not isolate the ancestry check"
    "$REAL_GIT" -C "$runjj_orphan" push -q --force "$rjj/remote.git" main:main ||
      fail "could not stage an unrelated remote head"
    ! runjj_lib vireo fleet_run_poll_floor "$vireo" ||
      fail "the poll floor exited on a remote head that does not descend from the converged one"

    printf 'real-jj: OK (poll floor states incl. record-only peers, propagate and apply, hooks held, rule-4 resolution, canary gate, satisfied-is-evidence, revert and --now binding)\n'
  ) || fail "real-jj run block failed (see the FAIL: real-jj: line above)"
fi

# --- the P0 scenarios: one block and one OK line each -------------------------
# Each builds its own fresh one-host fleet, so none depends on the order above
# or on another's leftovers, and a sibling change to one scenario touches only
# its own block.
p0jj_setup() {
  # p0jj_setup NAME — a fresh fleet of one host (vireo) under
  # $runjj_root/p0-NAME with a private remote, a verified posture, the fleet
  # and host layers the scenarios read, and its first run published. Defines
  # the helpers the scenarios use: runjj, runjj_lib; sets rjj and vireo.
  mkdir -p "$tmp/ssh-stub-only" && ln -sf "$tmp/bin/ssh" "$tmp/ssh-stub-only/ssh"
  PATH="$tmp/ssh-stub-only:$(dirname "$real_jj"):$(dirname "$real_yq"):$PATH"
  export PATH
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"
  rjj="$runjj_root/p0-$1"
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
  export XDG_CONFIG_HOME="$rjj/xdg"
  export HOME="$rjj/home"
  mkdir -p "$HOME"
  rjj_key vireo
  rjj_krl seed.krl
  "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"
  runjj() {
    runjj_host=$1
    shift
    env ROUNDHOUSE_FLEET_STORE="$rjj/$runjj_host/store" \
      ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/$runjj_host-key" \
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/$runjj_host" \
      "$@"
  }
  runjj_lib() {
    runjj_host=$1
    shift
    env ROUNDHOUSE_FLEET_STORE="$rjj/$runjj_host/store" \
      ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/$runjj_host-key" \
      ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/$runjj_host" \
      bash -c 'ROUNDHOUSE_LIB_ONLY=1 . "$0"; shift; "$@"' "$cli" -- "$@"
  }
  mkdir -p "$rjj/vireo"
  printf 'name: vireo\ndomain: fleet.example.invalid\n' >"$rjj/vireo/identity.yaml"
  runjj vireo "$cli" fleet-init >/dev/null || fail "fleet-init failed on vireo"
  vireo="$rjj/vireo/store"
  jj -R "$vireo" git remote add origin "$rjj/remote.git" >/dev/null
  runjj vireo "$cli" fleet-enroll >/dev/null || fail "fleet-enroll failed on vireo"
  env ROUNDHOUSE_SELFTEST=1 \
    ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "Permission denied (publickey)\n" >&2; exit 128' \
    ROUNDHOUSE_FLEET_STORE="$vireo" "$cli" fleet-verify-remote >/dev/null ||
    fail "fleet-verify-remote did not accept an authentication refusal as private"
  mkdir -p "$vireo/hosts" "$vireo/groups"
  cat >"$vireo/fleet.yaml" <<'YAML'
policy:
  canary_wait_hours: 0
config_files:
  ~/.claude/settings.json:
    keys:
      env.DISABLE_TELEMETRY: managed
YAML
  printf 'platform: macos\ngroups: [development, canary]\nhostname: vireo.invalid\nuser: claire\n' \
    >"$vireo/hosts/vireo.yaml"
  runjj vireo "$cli" fleet-run --fast >/dev/null ||
    fail "the first fleet-run on the $1 fleet failed"
}

p0jj_block() {
  # p0jj_block NAME SCENARIO-FUNCTION OK-TEXT — one scenario, in its own
  # subshell over its own fleet, with its own OK line.
  (
    set -eu
    fail() {
      printf 'FAIL: real-jj: %s\n' "$*" >&2
      exit 1
    }
    p0jj_setup "$1"
    "$2"
    printf 'real-jj: OK (%s)\n' "$3"
  ) || fail "real-jj $1 block failed (see the FAIL: real-jj: line above)"
}

p0jj_tombstone() {
  # --- §3.4: a tombstone uninstalls, inside the cap, and then goes quiet ---
  # The scalar form, which the fold knocks out: it reaches the run only
  # through the tombstone read, and the installed record names its one
  # marketplace. Disabled, so the live-session deferral does not apply.
  mkdir -p "$HOME/.claude/plugins"
  printf '{"version":2,"plugins":{"retired@test-market":[{"scope":"user","version":"1.0.0"}]}}\n' \
    >"$HOME/.claude/plugins/installed_plugins.json"
  printf '{"retired@test-market":false}\n' >"$rjj/plugin-enabled.json"
  : >"$rjj/plugin-actions"
  runjj_dev_group() {
    cat >"$vireo/groups/development.yaml" <<YAML
policy:
  canary_wait_hours: 0
  max_removals_per_run: $1
  max_removal_fraction: 1
mcp_servers:
  context7: enabled
plugins:
  retired: absent
YAML
  }
  runjj_tomb_run() {
    runjj vireo env CLAUDE_CONFIG_DIR="$HOME/.claude" \
      CLAUDE_PLUGIN_ENABLED_FILE="$rjj/plugin-enabled.json" \
      CLAUDE_PLUGIN_ACTION_LOG="$rjj/plugin-actions" "$cli" fleet-run --fast
  }
  runjj_tomb_count() {
    grep -rh -A2 'item: plugins.retired' "$vireo/journal/vireo" 2>/dev/null |
      grep -c 'outcome:' || true
  }
  # Over the cap, the uninstall is a removal like any other and holds.
  runjj_dev_group 0
  runjj_out=$(runjj_tomb_run) || fail "the capped tombstone run failed: $runjj_out"
  case $runjj_out in
    *'hold  plugins.retired — the removal set is over the cap'*) ;;
    *) fail "a tombstone uninstall was not counted toward the removal cap: $runjj_out" ;;
  esac
  jq -e '.plugins["retired@test-market"]' "$HOME/.claude/plugins/installed_plugins.json" \
    >/dev/null || fail "a capped tombstone uninstalled anyway"
  [ -f "$vireo/alerts/vireo/removal-cap.yaml" ] ||
    fail "the capped run raised no removal-cap alert"
  runjj_dev_group 5
  runjj_alive_count() {
    grep -rh 'outcome: alive' "$vireo/journal/vireo" 2>/dev/null | grep -c . || true
  }
  runjj_alive_before=$(runjj_alive_count)
  runjj_out=$(runjj_tomb_run) || fail "the tombstone run failed: $runjj_out"
  case $runjj_out in
    *'applied plugins.retired (uninstalled)'*) ;;
    *) fail "the tombstone did not uninstall the plugin: $runjj_out" ;;
  esac
  # A pass whose only change is a tombstone APPLIED something, and publishes
  # the heartbeat that evidence owes (a canary's downstream waits on it).
  [ "$(runjj_alive_count)" -gt "$runjj_alive_before" ] ||
    fail "a pass whose only change was a tombstone published no heartbeat"
  grep -Fqx 'uninstall retired@test-market' "$rjj/plugin-actions" ||
    fail "the tombstone did not go through claude plugin uninstall"
  # The cap no longer holds anything, so its CONDITION alert is cleared.
  [ ! -e "$vireo/alerts/vireo/removal-cap.yaml" ] ||
    fail "the removal-cap alert outlived its condition"
  ! jq -e '.plugins["retired@test-market"]' \
    "$HOME/.claude/plugins/installed_plugins.json" >/dev/null ||
    fail "the uninstalled plugin is still recorded as installed"
  grep -rh -A2 'item: plugins.retired' "$vireo/journal/vireo" |
    grep -q 'outcome: applied' || fail "the uninstall journaled no applied record"
  [ -z "$(fleet_applied_digest "$vireo" vireo plugins.retired)" ] ||
    fail "a tombstone was recorded as owned in applied/"
  # Converged: the next working pass says nothing more about it.
  runjj_tomb_before=$(runjj_tomb_count)
  printf '# another edit\n' >>"$vireo/fleet.yaml"
  runjj_tomb_run >/dev/null || fail "the pass after the uninstall failed"
  [ "$(runjj_tomb_count)" = "$runjj_tomb_before" ] ||
    fail "a converged tombstone journaled again on the next pass"
}

p0jj_takeover() {
  # --- §6.3: a dead holder's lock is taken over by the next run ---
  # The wedge itself: a lock a dead pre-nonce run left behind, aged far past
  # the stale threshold. The age check used to run first and refuse it
  # forever; the holder check runs first now.
  runjj_lock="$rjj/vireo/store.lock"
  sleep 1 &
  runjj_dead=$!
  wait "$runjj_dead" 2>/dev/null || :
  mkdir -p "$runjj_lock"
  printf '{"host":"vireo","pid":%s,"started_at":"2000-01-01T00:00:00Z"}\n' \
    "$runjj_dead" >"$runjj_lock/meta.json"
  runjj_out=$(runjj vireo "$cli" fleet-run --fast 2>&1) ||
    fail "a run refused a lock whose holder is dead: $runjj_out"
  case $runjj_out in
    *'took over the run lock'*) ;;
    *) fail "the takeover was not reported: $runjj_out" ;;
  esac
  [ ! -d "$runjj_lock" ] ||
    fail "the run did not release the lock it took over"
  jj -R "$vireo" file list -r "$(fleet_vcs_heads_local "$vireo")" \
    -T 'path ++ "\n"' | grep -qx 'alerts/vireo/lock-takeover.yaml' ||
    fail "the takeover alert was not published"
}

p0jj_compaction() {
  # --- §6.4: the one-time alert compaction, published ---
  runjj_alerts="$vireo/alerts/vireo"
  mkdir -p "$runjj_alerts"
  for runjj_n in $(seq 1 40); do
    printf 'kind: integrity\nhost: vireo\nitems: [plugins.p%s]\ndetail: held %s\nat: "2026-08-%02dT00:00:00Z"\n' \
      "$((runjj_n % 4))" "$runjj_n" "$((runjj_n % 28 + 1))" \
      >"$runjj_alerts/202608$(printf %02d $((runjj_n % 28 + 1)))T00$(printf %02d "$runjj_n")-integrity-p$runjj_n.yaml"
  done
  runjj vireo "$cli" fleet-run --fast >/dev/null ||
    fail "vireo could not publish the stamped alert fixture"
  # Refused while the working copy carries an edit that is not a record.
  printf '# an unpublished layer edit\n' >>"$vireo/fleet.yaml"
  runjj_status=0
  runjj_out=$(runjj vireo "$cli" fleet-compact-alerts 2>&1) || runjj_status=$?
  [ "$runjj_status" -eq 65 ] ||
    fail "compaction published over an operator's unpublished layer edit (got $runjj_status): $runjj_out"
  runjj vireo "$cli" fleet-run --fast >/dev/null ||
    fail "vireo could not publish the pending layer edit"
  runjj_out=$(runjj vireo "$cli" fleet-compact-alerts) ||
    fail "fleet-compact-alerts failed: $runjj_out"
  case $runjj_out in
    *'published the compaction'*) ;;
    *) fail "the compaction did not publish: $runjj_out" ;;
  esac
  [ "$(fleet_vcs_heads_local "$vireo")" = "$(fleet_vcs_head_origin "$vireo")" ] ||
    fail "the compaction is not on the remote"
  runjj_tree=$(jj -R "$vireo" file list -r "$(fleet_vcs_head_origin "$vireo")" \
    -T 'path ++ "\n"')
  ! printf '%s\n' "$runjj_tree" | grep -Eq '^alerts/vireo/[0-9]{8}T[0-9]{4}-' ||
    fail "stamped alert files survived the published compaction"
  [ "$(printf '%s\n' "$runjj_tree" | grep -c '^alerts/vireo/integrity--plugins\.p')" -eq 4 ] ||
    fail "the compaction did not leave one keyed file per (kind, item)"
  [ -z "$(jj -R "$vireo" log -r @ --no-graph -T 'if(empty,"","dirty")')" ] ||
    fail "the compaction did not leave @ an empty child of main"
  runjj_out=$(runjj vireo "$cli" fleet-compact-alerts) ||
    fail "a second compaction failed: $runjj_out"
  case $runjj_out in
    *'nothing to publish'*) ;;
    *) fail "a second compaction was not a no-op: $runjj_out" ;;
  esac
}

p0jj_disown() {
  # --- §8.2 P0: fleet-disown releases host-only ownership without a prune ---
  runjj_hostonly='config_files.~/.hostonly'
  # A tombstone the disown dry run can name (see below), in a shared layer.
  mkdir -p "$vireo/groups"
  printf 'plugins:\n  retired: absent\n' >"$vireo/groups/development.yaml"
  runjj_outcomes() {
    for runjj_day in "$vireo/journal/vireo"/*.yaml; do
      FLEET_ITEM=$1 yq -r '.[] | select(.item == strenv(FLEET_ITEM)) | .outcome' \
        "$runjj_day"
    done
  }
  printf 'platform: macos\ngroups: [development, canary]\nhostname: vireo.invalid\nuser: claire\nskills:\n  ponytail-audit: enabled\nconfig_files:\n  ~/.hostonly:\n    keys:\n      a: managed\n' \
    >"$vireo/hosts/vireo.yaml"
  runjj vireo "$cli" fleet-run --fast >/dev/null ||
    fail "vireo could not apply its host-only item"
  [ -n "$(fleet_applied_digest "$vireo" vireo "$runjj_hostonly")" ] ||
    fail "the host-only fixture item was never owned"
  runjj_out=$(runjj vireo "$cli" fleet-disown --host-only --dry-run) ||
    fail "fleet-disown --dry-run failed: $runjj_out"
  case $runjj_out in
    *"disown $runjj_hostonly "*) ;;
    *) fail "the dry run did not select the host-only item: $runjj_out" ;;
  esac
  case $runjj_out in
    *'disown config_files.~/.claude/settings.json'*)
      fail "the dry run selected an item the fleet layer asks for: $runjj_out" ;;
  esac
  [ -n "$(fleet_applied_digest "$vireo" vireo "$runjj_hostonly")" ] ||
    fail "a dry-run disown changed applied/"
  # An owned item that is TOMBSTONED is not left installed: the dry run says
  # its tombstone will uninstall it.
  fleet_applied_record "$vireo" vireo plugins.retired d-retired
  runjj_out=$(runjj vireo "$cli" fleet-disown --dry-run plugins.retired) ||
    fail "the tombstoned disown dry run failed: $runjj_out"
  case $runjj_out in
    *'will be uninstalled by its tombstone'*) ;;
    *) fail "the dry run did not say a tombstoned item will be uninstalled: $runjj_out" ;;
  esac
  fleet_applied_forget "$vireo" vireo plugins.retired
  runjj_status=0
  runjj vireo "$cli" fleet-disown plugins.never-owned >/dev/null 2>&1 ||
    runjj_status=$?
  [ "$runjj_status" -eq 65 ] ||
    fail "disowning an item this host does not own was not refused (got $runjj_status)"
  runjj_out=$(runjj vireo "$cli" fleet-disown --host-only) ||
    fail "fleet-disown failed: $runjj_out"
  case $runjj_out in
    *'published the disown'*) ;;
    *) fail "the disown did not publish: $runjj_out" ;;
  esac
  [ -z "$(fleet_applied_digest "$vireo" vireo "$runjj_hostonly")" ] ||
    fail "the disowned item is still owned"
  [ -n "$(fleet_applied_digest "$vireo" vireo 'config_files.~/.claude/settings.json')" ] ||
    fail "the disown released an item the fleet layer still asks for"
  runjj_outcomes "$runjj_hostonly" | grep -qx disowned ||
    fail "the disown journaled no disowned record"
  [ "$(fleet_vcs_heads_local "$vireo")" = "$(fleet_vcs_head_origin "$vireo")" ] ||
    fail "the disown is not on the remote"
  # Retiring the host layer now changes nothing: no prune, no `reverted`.
  printf 'platform: macos\ngroups: [development, canary]\nhostname: vireo.invalid\nuser: claire\nskills:\n  ponytail-audit: enabled\n' \
    >"$vireo/hosts/vireo.yaml"
  runjj_out=$(runjj vireo "$cli" fleet-run --fast) ||
    fail "the run after retiring the host-only item failed: $runjj_out"
  case $runjj_out in
    *"prune $runjj_hostonly"*) fail "a disowned item was pruned: $runjj_out" ;;
  esac
  ! runjj_outcomes "$runjj_hostonly" | grep -qx reverted ||
    fail "a disowned item was journaled reverted"
  # A bookmark move jj refuses is a FAILED publish. An @ that descends from a
  # stale head — here main's parent — is sideways from main; jj will not move
  # main there, and the publish must say so and fail rather than push the
  # unmoved main and report success while the work sits in an orphan.
  runjj_main=$(fleet_vcs_heads_local "$vireo")
  jj -R "$vireo" new "$runjj_main-" >/dev/null
  printf 'orphan: probe\n' >"$vireo/orphan-probe.yaml"
  runjj_status=0
  runjj_out=$(runjj_lib vireo fleet_run_publish "$vireo" vireo interactive/human \
    'a publish from a stale head' 'orphan-probe' 'stale-head probe' 2>&1) ||
    runjj_status=$?
  [ "$runjj_status" -eq 65 ] ||
    fail "a publish whose bookmark move jj refused did not fail with 65 (got $runjj_status): $runjj_out"
  case $runjj_out in
    *'could not move main to the new commit'*'nothing published'*) ;;
    *) fail "a refused bookmark move was not reported: $runjj_out" ;;
  esac
  [ "$(fleet_vcs_heads_local "$vireo")" = "$runjj_main" ] ||
    fail "main moved although the publish failed"
  [ "$(fleet_vcs_head_origin "$vireo")" = "$runjj_main" ] ||
    fail "the remote moved although the publish failed"
  runjj_orphan=$(jj -R "$vireo" log -r @ --no-graph -T 'commit_id')
  jj -R "$vireo" new "$runjj_main" >/dev/null
  jj -R "$vireo" abandon "$runjj_orphan" >/dev/null
  [ ! -e "$vireo/orphan-probe.yaml" ] || fail "the stale-head probe left its file in the working copy"
}

p0jj_abort() {
  # --- an abort mid-apply still lands the queued records ---
  # The loop queues applied/ and journal writes (one batch per pass). A pass
  # that dies after an item applied — errexit here; a signal the same way —
  # must still record it as owned and journal it, or the next pass sees an
  # installed item nobody owns.
  runjj_abort_a='config_files.~/.abort-a'
  runjj_abort_outcomes() {
    for runjj_day in "$vireo/journal/vireo"/*.yaml; do
      [ -f "$runjj_day" ] || continue
      FLEET_ITEM=$1 yq -r '.[] | select(.item == strenv(FLEET_ITEM)) | .outcome' \
        "$runjj_day"
    done
  }
  printf 'platform: macos\ngroups: [development, canary]\nhostname: vireo.invalid\nuser: claire\nconfig_files:\n  ~/.abort-a:\n    keys:\n      a: managed\n  ~/.abort-b:\n    keys:\n      b: managed\n' \
    >"$vireo/hosts/vireo.yaml"
  runjj_status=0
  runjj_out=$(runjj vireo env ROUNDHOUSE_FLEET_TEST_ABORT_AFTER_APPLY="$runjj_abort_a" \
    "$cli" fleet-run --fast 2>&1) || runjj_status=$?
  [ "$runjj_status" -ne 0 ] || fail "the pass did not abort after $runjj_abort_a applied: $runjj_out"
  case $runjj_out in
    *"self-test abort after applying $runjj_abort_a"*) ;;
    *) fail "the abort hook did not fire: $runjj_out" ;;
  esac
  [ -n "$(fleet_applied_digest "$vireo" vireo "$runjj_abort_a")" ] ||
    fail "an item applied before the abort was not recorded in applied/ (the queued batch was lost)"
  runjj_abort_outcomes "$runjj_abort_a" | grep -qx applied ||
    fail "an item applied before the abort was not journaled (the queued batch was lost)"
  [ ! -e "$vireo.lock" ] || fail "the aborted run left its lock behind"
  # The next run converges what is left and publishes.
  runjj vireo "$cli" fleet-run --fast >/dev/null ||
    fail "the run after an aborted pass did not converge"
}

p0jj_aging() {
  # --- §7.11.3: evidence aging, previewed, then published ---
  mkdir -p "$vireo/journal/vireo"
  cat >"$vireo/journal/vireo/2001-01-01.yaml" <<'YAML'
- {item: plugins.q, digest: q1, outcome: held, at: "2001-01-01T01:00:00Z"}
- {outcome: unreachable, source: none, at: "2001-01-01T02:00:00Z"}
YAML
  runjj vireo "$cli" fleet-run --fast >/dev/null ||
    fail "vireo could not publish the old journal fixture"
  runjj_out=$(runjj vireo "$cli" fleet-age-evidence --dry-run) ||
    fail "fleet-age-evidence --dry-run failed: $runjj_out"
  case $runjj_out in
    *'dry run'*'journal/vireo: 2 of '*'(1 day files removed'*) ;;
    *) fail "the aging dry run did not report the trim: $runjj_out" ;;
  esac
  [ -f "$vireo/journal/vireo/2001-01-01.yaml" ] || fail "the aging dry run changed the journal"
  runjj_out=$(runjj vireo "$cli" fleet-age-evidence) ||
    fail "fleet-age-evidence failed: $runjj_out"
  case $runjj_out in
    *'published the evidence aging'*) ;;
    *) fail "the evidence aging did not publish: $runjj_out" ;;
  esac
  ! jj -R "$vireo" file list -r "$(fleet_vcs_head_origin "$vireo")" -T 'path ++ "\n"' |
    grep -qx 'journal/vireo/2001-01-01.yaml' ||
    fail "the aged day file is still on the remote"
  grep -rhq 'outcome: alive' "$vireo/journal/vireo" ||
    fail "aging removed the newest heartbeat"
}

p0jj_verb_refusals() {
  # fleet_run_verb_begin's refusals, against a real store: a diverged main
  # (two bookmark heads), a run holding the lock, and an unpublished layer
  # edit. Each refuses BEFORE anything is written, and leaves no lock behind.
  runjj_lock="$rjj/vireo/store.lock"
  runjj_status=0
  runjj vireo bash -c 'ROUNDHOUSE_LIB_ONLY=1 . "$0"
    fleet_vcs_heads_local() { printf "%s\n" one two; }
    fleet_run_verb_begin "$ROUNDHOUSE_FLEET_STORE" vireo fleet-disown' "$cli" \
    2>"$rjj/verb-err" || runjj_status=$?
  [ "$runjj_status" -eq 65 ] && grep -q 'main is diverged' "$rjj/verb-err" ||
    fail "a publishing verb did not refuse a diverged main (got $runjj_status): $(cat "$rjj/verb-err")"
  [ ! -d "$runjj_lock" ] || fail "the diverged-main refusal left a lock"
  sleep 300 &
  runjj_holder=$!
  runjj_lib vireo fleet_lock_acquire "$runjj_lock" "$runjj_holder"
  runjj_status=0
  runjj vireo "$cli" fleet-disown --host-only 2>"$rjj/verb-err" >/dev/null ||
    runjj_status=$?
  kill "$runjj_holder" 2>/dev/null || :
  wait "$runjj_holder" 2>/dev/null || :
  rm -rf "$runjj_lock"
  [ "$runjj_status" -eq 75 ] && grep -q 'retry when it finishes' "$rjj/verb-err" ||
    fail "a publishing verb did not wait for a live run's lock (got $runjj_status): $(cat "$rjj/verb-err")"
  printf '# an unpublished layer edit\n' >>"$vireo/fleet.yaml"
  runjj_status=0
  runjj vireo "$cli" fleet-disown --host-only 2>"$rjj/verb-err" >/dev/null ||
    runjj_status=$?
  [ "$runjj_status" -eq 65 ] && grep -q 'unpublished edits (fleet.yaml)' "$rjj/verb-err" ||
    fail "a publishing verb published over a foreign working-copy edit (got $runjj_status): $(cat "$rjj/verb-err")"
  [ ! -d "$runjj_lock" ] || fail "the foreign-edit refusal left its lock behind"
}

# --- §7.12.3: reviewed-ref records only what this host SAW PUBLISHED ---------
# A run materializes before it publishes, so an older build that recorded the
# materialized head could leave the mark on a local reconcile no remote has:
# once that commit was abandoned, or origin moved past its base, every later
# head was its sibling and every pass refused. The fixtures below are the two
# shapes seen on real hosts (mac-studio, iris-wsl), the migration off the old
# rule, and the attacks the gate exists for, which must still hold.
p0jj_ratchet_init() {
  # Defines the scenario helpers over the fresh fleet p0jj_setup just built.
  rjj_key wren
  runjj_ref() { runjj_lib vireo fleet_trust_reviewed_ref; }
  runjj_unpub="$vireo/alerts/vireo/materialization--reviewed-ref-unpublished.yaml"
  # A second writer on the hub. One enrolled key in this fleet, so the peer
  # signs as vireo from its own clone; all the gate cares about is that origin
  # moved.
  jj git clone --colocate --config ui.editor='"true"' \
    --config ui.paginate=never "$rjj/remote.git" "$rjj/peer" >/dev/null 2>&1 ||
    fail "could not clone the hub for the peer writer"
  runjj_peer="$rjj/peer"
  jj -R "$runjj_peer" config set --repo user.email vireo@fleet.example.invalid
  jj -R "$runjj_peer" config set --repo signing.behavior '"own"'
  jj -R "$runjj_peer" config set --repo signing.backend '"ssh"'
  jj -R "$runjj_peer" config set --repo signing.key "$rjj/vireo-key"
  runjj_peer_push() {
    # runjj_peer_push N [BASE] — one signed shared-layer commit on the hub, on
    # main@origin or on BASE (a sideways move: a divergent origin).
    jj -R "$runjj_peer" git fetch >/dev/null 2>&1
    jj -R "$runjj_peer" new "${2:-main@origin}" >/dev/null 2>&1
    printf 'policy:\n  canary_wait_hours: 0\n# peer edit %s\n' "$1" \
      >"$runjj_peer/groups/canary.yaml"
    jj -R "$runjj_peer" describe -m "peer edit $1" >/dev/null 2>&1
    jj -R "$runjj_peer" bookmark set main --allow-backwards -r @ >/dev/null 2>&1
    jj -R "$runjj_peer" git push --bookmark main >/dev/null 2>&1 ||
      fail "the peer could not push edit $1"
    jj -R "$runjj_peer" log -r main@origin --no-graph -T 'commit_id'
  }
  runjj_drop_local() {
    # Every local commit above main@origin goes, and main is reset onto it:
    # §10.4's recovery, or a killed run's leftovers simply abandoned.
    jj -R "$vireo" abandon -r "main@origin..($1 | @)" >/dev/null 2>&1 ||
      fail "could not abandon the local work"
    jj -R "$vireo" bookmark set main --allow-backwards -r main@origin >/dev/null
    jj -R "$vireo" new main@origin >/dev/null
  }
  runjj_host_edit() {
    printf 'platform: macos\ngroups: [development, canary]\nhostname: vireo.invalid\nuser: claire\n# %s\n' \
      "$1" >"$vireo/hosts/vireo.yaml"
  }
  runjj_local_commit() {
    # runjj_local_commit BASE TEXT [SIGNER] -> a commit on BASE no remote has.
    jj -R "$vireo" new "$1" >/dev/null
    if [ -n "${3:-}" ]; then
      jj -R "$vireo" config set --repo user.email "$3@fleet.example.invalid"
      jj -R "$vireo" config set --repo signing.key "$rjj/$3-key"
    fi
    runjj_host_edit "$2"
    jj -R "$vireo" describe -m "$2" >/dev/null
    jj -R "$vireo" log -r @ --no-graph -T commit_id
    if [ -n "${3:-}" ]; then
      jj -R "$vireo" config set --repo user.email vireo@fleet.example.invalid
      jj -R "$vireo" config set --repo signing.key "$rjj/vireo-key"
    fi
  }
  runjj_legacy_state() {
    # The trust state an OLDER build left: <commit> as the mark, and the
    # one-field materialized-at that marks the format as legacy.
    printf '%s\n' "$1" >"$rjj/vireo/reviewed-ref"
    runjj_lib vireo fleet_now >"$rjj/vireo/materialized-at"
  }
  runjj_run() {
    # runjj_run — a converging pass (--full): these scenarios are about what a
    # pass that materializes does to the ratchet, and a fast pass rightly
    # stops at the poll floor when only records moved on the remote.
    runjj_status=0
    runjj_out=$(runjj vireo "$cli" fleet-run --full 2>&1) || runjj_status=$?
  }
}

p0jj_ratchet_wedge() {
  # mac-studio's shape: the hub is unreachable for one pass, which reconciles,
  # materializes and cannot publish — a killed run's exact leftovers — and
  # those leftovers are then abandoned while origin moves on.
  p0jj_ratchet_init
  #    The steady state first: after a publishing pass the mark is the head it
  #    PUSHED (fleet_trust_advance_published), which is published by definition.
  runjj_host_edit 'a published pass'
  runjj_run
  [ "$runjj_status" -eq 0 ] || fail "the steady-state pass failed: $runjj_out"
  runjj_published=$(fleet_vcs_head_origin "$vireo")
  [ "$(runjj_ref)" = "$runjj_published" ] ||
    fail "after a publishing pass, reviewed-ref is not the pushed head (got '$(runjj_ref)', want $runjj_published)"
  mv "$rjj/remote.git" "$rjj/remote.away"
  runjj_host_edit 'a pass that never publishes'
  runjj_run
  mv "$rjj/remote.away" "$rjj/remote.git"
  runjj_local=$(fleet_vcs_heads_local "$vireo")
  runjj_rendered=$(runjj_lib vireo fleet_trust_materialized_rev)
  #    THE PROPERTY: the materialized head is local work no remote has, and the
  #    mark did not follow it there; materialized-at records it for the drift
  #    compare.
  [ -n "$runjj_rendered" ] && [ "$runjj_rendered" != "$runjj_published" ] &&
    [ -n "$(jj -R "$vireo" log -r "$runjj_rendered & ::$runjj_local" --no-graph -T commit_id)" ] &&
    [ -z "$(jj -R "$vireo" log -r "$runjj_rendered & ::main@origin" --no-graph -T commit_id)" ] ||
    fail "the unreachable-hub pass did not materialize unpublished local work (rendered '$runjj_rendered')"
  [ "$(runjj_ref)" = "$runjj_published" ] ||
    fail "reviewed-ref advanced to a commit no remote has (got $(runjj_ref), published $runjj_published)"
  [ -z "$(runjj_lib vireo fleet_trust_materialization_drift "$vireo")" ] ||
    fail "rendering at local work read as roster drift"
  runjj_drop_local "$runjj_local"
  runjj_peer_push 1 >/dev/null
  runjj_run
  [ "$runjj_status" -eq 0 ] ||
    fail "REGRESSION: abandoned materialized local work while origin moved on wedged the host (got $runjj_status): $runjj_out"
  case $runjj_out in
    *published*) ;;
    *) fail "the pass after the abandoned local work did not publish: $runjj_out" ;;
  esac
  [ "$(runjj_ref)" = "$(fleet_vcs_head_origin "$vireo")" ] ||
    fail "reviewed-ref is not the head this pass published"
  [ ! -e "$runjj_unpub" ] || fail "a healthy pass left the reviewed-ref alert"
  #    Advancing the mark on a push must not move the drift compare: with a
  #    one-field materialized-at, the rendered revision is known only through
  #    reviewed-ref, so it is written into materialized-at first.
  runjj_rendered=$(runjj_lib vireo fleet_trust_materialized_rev)
  printf '%s\n' "$runjj_rendered" >"$rjj/vireo/reviewed-ref"
  runjj_lib vireo fleet_now >"$rjj/vireo/materialized-at"
  runjj_pushed=$(runjj_peer_push 2)
  jj -R "$vireo" git fetch >/dev/null 2>&1
  runjj_lib vireo fleet_trust_advance_published "$vireo" "$runjj_pushed"
  [ "$(runjj_ref)" = "$runjj_pushed" ] &&
    [ "$(runjj_lib vireo fleet_trust_materialized_rev)" = "$runjj_rendered" ] ||
    fail "advancing a legacy-format mark moved the drift compare off the rendered revision"
}

p0jj_ratchet_legacy() {
  # MIGRATION, provable, in both shapes seen on real hosts. An older build
  # recorded the rendered head itself; a host upgraded while wedged holds that
  # mark today. Its gap is this host's own signed work and the op log shows
  # origin never dropping anything, so it is re-anchored and the pass runs.
  p0jj_ratchet_init
  #    mac-studio as it stood when upgraded: the mark's commit was abandoned.
  runjj_legacy=$(runjj_local_commit main@origin 'a reconcile an older build materialized')
  runjj_legacy_state "$runjj_legacy"
  runjj_drop_local "$runjj_legacy"
  runjj_peer_push 1 >/dev/null
  runjj_run
  [ "$runjj_status" -eq 0 ] ||
    fail "MIGRATION (mac-studio): a legacy mark on own abandoned work was not re-anchored (got $runjj_status): $runjj_out"
  [ "$(runjj_ref)" = "$(fleet_vcs_head_origin "$vireo")" ] ||
    fail "the migrated mark is not the published head"
  #    iris-wsl exactly: the mark is a local reconcile on the published head,
  #    and main was NOT reset — it names an unpublished local converge, a
  #    SIBLING of the mark on the same base, which every pass had to keep
  #    holding. Nothing is abandoned; the held converge finally publishes.
  runjj_base=$(fleet_vcs_head_origin "$vireo")
  runjj_mark=$(runjj_local_commit "$runjj_base" 'reconcile vireo (materialized, never pushed)')
  runjj_converge=$(runjj_local_commit "$runjj_base" 'converge on vireo (never pushed)')
  jj -R "$vireo" bookmark set main -r "$runjj_converge" >/dev/null
  jj -R "$vireo" new "$runjj_converge" >/dev/null
  runjj_legacy_state "$runjj_mark"
  runjj_peer_push 2 >/dev/null
  runjj_run
  [ "$runjj_status" -eq 0 ] ||
    fail "MIGRATION (iris-wsl): a legacy mark beside an unpublished converge stayed wedged (got $runjj_status): $runjj_out"
  [ -n "$(jj -R "$vireo" log -r "$runjj_converge & ::main@origin" --no-graph -T commit_id)" ] ||
    fail "the held local converge never published after the re-anchor"
  [ "$(runjj_ref)" = "$(fleet_vcs_head_origin "$vireo")" ] ||
    fail "the iris-wsl mark was not re-anchored on the published head"
}

p0jj_ratchet_unprovable() {
  # MIGRATION, unprovable, and the recovery it names works. The gap holds a
  # commit this host did not sign — something only the remote could have
  # supplied, which origin has since dropped: hold, alert, doctor row.
  p0jj_ratchet_init
  runjj_foreign=$(runjj_local_commit main@origin 'a commit only the remote could have supplied' wren)
  runjj_legacy_state "$runjj_foreign"
  runjj_drop_local "$runjj_foreign"
  runjj_anchor=$(fleet_vcs_head_origin "$vireo")
  runjj_peer_push 1 >/dev/null
  runjj_run
  [ "$runjj_status" -eq 65 ] ||
    fail "MIGRATION: a legacy mark whose gap holds a peer's commit was re-anchored (got $runjj_status): $runjj_out"
  case $runjj_out in
    *'not provably local-only work (a commit not signed by this host is missing from origin)'*) ;;
    *) fail "the unprovable-migration refusal does not say why: $runjj_out" ;;
  esac
  [ -f "$runjj_unpub" ] ||
    fail "the unprovable reviewed-ref raised no keyed alert (the host-stuck state is silent)"
  runjj_detail=$(yq -r '.detail' "$runjj_unpub")
  case $runjj_detail in
    *"commit[${runjj_foreign:0:12}]"*"Newest published ancestor: commit[${runjj_anchor:0:12}]"*fleet-doctor*) ;;
    *) fail "the alert does not name the mark, its newest published ancestor and the doctor: $runjj_detail" ;;
  esac
  [ "$(runjj_ref)" = "$runjj_foreign" ] || fail "a refused pass moved reviewed-ref"
  runjj_doctor=$(runjj vireo "$cli" fleet-doctor 2>&1) || :
  printf '%s\n' "$runjj_doctor" | grep -E '^FINDING +reviewed-ref ' | grep -Fq 're-point: r=$(jj -R' ||
    fail "the doctor does not show the stuck reviewed-ref with its re-point command: $(printf '%s\n' "$runjj_doctor" | grep reviewed-ref)"
  #    The operator's recovery, run exactly as the refusal printed it.
  runjj_cmd=$(printf '%s\n' "$runjj_out" | sed -n 's/.*If origin was not rewound, re-point: \(.*\); refusing to materialize.*/\1/p' | head -1)
  [ -n "$runjj_cmd" ] || fail "the refusal printed no re-point command: $runjj_out"
  (cd "$rjj" && eval "$runjj_cmd") || fail "the printed re-point command failed: $runjj_cmd"
  [ "$(runjj_ref)" = "$runjj_anchor" ] ||
    fail "the printed re-point command did not re-point reviewed-ref at the named ancestor"
  runjj_run
  [ "$runjj_status" -eq 0 ] || fail "the pass after the printed recovery still refused: $runjj_out"
  [ ! -e "$runjj_unpub" ] || fail "the reviewed-ref alert outlived its condition"
}

p0jj_ratchet_rewind() {
  # A REWOUND ORIGIN STILL REFUSES. The hub is force-rewound to an earlier
  # published head and this host's main follows it (a reset onto main@origin,
  # the layer-parse fallback).
  p0jj_ratchet_init
  runjj_host_edit 'published before the rewind'
  runjj_run
  [ "$runjj_status" -eq 0 ] || fail "the pre-rewind pass failed: $runjj_out"
  runjj_held=$(runjj_ref)
  runjj_old=$(jj -R "$vireo" log -r "::$runjj_held ~ $runjj_held" --no-graph \
    --limit 1 -T commit_id)
  "$REAL_GIT" -C "$rjj/remote.git" update-ref refs/heads/main "$runjj_old"
  jj -R "$vireo" bookmark set main --allow-backwards -r "$runjj_old" >/dev/null
  jj -R "$vireo" new "$runjj_old" >/dev/null
  #    A mark this build wrote: a plain refusal, with the keyed alert.
  runjj_run
  [ "$runjj_status" -eq 65 ] ||
    fail "REWIND: a host following a rewound origin materialized (got $runjj_status): $runjj_out"
  case $runjj_out in
    *"reviewed-ref $runjj_held is not on main@origin"*) ;;
    *) fail "the rewind refusal does not name the mark origin dropped: $runjj_out" ;;
  esac
  [ -f "$runjj_unpub" ] || fail "the rewind raised no keyed alert"
  [ "$(runjj_ref)" = "$runjj_held" ] || fail "a rewound origin moved reviewed-ref backward"
  #    The same mark in the LEGACY format: the migration is considered, and its
  #    gap is all this host's own work, so signature alone would pass it. The op
  #    log is what remembers that origin once held more.
  runjj_legacy_state "$runjj_held"
  runjj_run
  [ "$runjj_status" -eq 65 ] ||
    fail "REWIND (legacy): the migration re-anchored past a rewind (got $runjj_status): $runjj_out"
  case $runjj_out in
    *'main@origin once held'*'which origin no longer has'*) ;;
    *) fail "the legacy rewind refusal does not name what origin dropped: $runjj_out" ;;
  esac
  [ "$(runjj_ref)" = "$runjj_held" ] || fail "a rewound origin moved the legacy mark"
}

p0jj_ratchet_diverge() {
  # A DIVERGENT ORIGIN STILL REFUSES, including one forked from BELOW this
  # host's latest push. The host published A and then B on top of it; the hub
  # is force-pushed to D, forked from A, which drops B. A mark left at the
  # FETCHED head (A) would still be an ancestor of D and accept it; the mark
  # advances to the pushed head, so D is refused.
  p0jj_ratchet_init
  runjj_host_edit 'A'
  runjj_run
  [ "$runjj_status" -eq 0 ] || fail "the pass publishing A failed: $runjj_out"
  runjj_a=$(fleet_vcs_head_origin "$vireo")
  runjj_host_edit 'B'
  runjj_run
  [ "$runjj_status" -eq 0 ] || fail "the pass publishing B failed: $runjj_out"
  runjj_b=$(fleet_vcs_head_origin "$vireo")
  [ "$runjj_b" != "$runjj_a" ] && [ "$(runjj_ref)" = "$runjj_b" ] ||
    fail "the mark did not advance to the pushed head B (got $(runjj_ref), A $runjj_a, B $runjj_b)"
  runjj_d=$(runjj_peer_push D "$runjj_a")
  [ -z "$(jj -R "$runjj_peer" log -r "$runjj_b & ::$runjj_d" --no-graph -T commit_id)" ] ||
    fail "the fixture's D is not forked from below B"
  jj -R "$vireo" git fetch >/dev/null 2>&1
  jj -R "$vireo" bookmark set main --allow-backwards -r "$runjj_d" >/dev/null
  jj -R "$vireo" new "$runjj_d" >/dev/null
  runjj_host_edit 'a pass on the divergent line'
  runjj_run
  [ "$runjj_status" -eq 65 ] ||
    fail "DIVERGENCE: a head forked from below this host's push was materialized (got $runjj_status): $runjj_out"
  case $runjj_out in
    *"reviewed-ref $runjj_b is not on main@origin"*) ;;
    *) fail "the divergence refusal does not name the pushed mark: $runjj_out" ;;
  esac
  [ "$(runjj_ref)" = "$runjj_b" ] || fail "a divergent origin moved reviewed-ref"
}

p0jj_catchup() {
  # --- §7.11.2: the catch-up had the same wedge, and the same cure ---
  # A host offline across a re-root looks its reviewed-ref up in the archive. A
  # legacy mark over its OWN never-published reconcile is in no archive, so
  # step 3 refused every pass across the re-root. It is re-anchored by the same
  # two proofs, with the archive counted as published; an unprovable one keeps
  # the refusal.
  p0jj_ratchet_init
  runjj_published=$(fleet_vcs_head_origin "$vireo")
  "$REAL_GIT" -C "$vireo" update-ref refs/roundhouse/archive/20261001 "$runjj_published"
  # The re-root, as fleet-reroot lays it down: a new parentless root carrying
  # the checkpoint's roster, signed by a key that roster trusts.
  jj -R "$vireo" file show -r "$runjj_published" root:trust/signers.yaml \
    >"$rjj/checkpoint-roster.yaml"
  jj -R "$vireo" new 'root()' >/dev/null
  mkdir -p "$vireo/trust"
  cp "$rjj/checkpoint-roster.yaml" "$vireo/trust/signers.yaml"
  printf 'policy:\n  canary_wait_hours: 0\n' >"$vireo/fleet.yaml"
  jj -R "$vireo" describe -m 're-root on the checkpointed state' >/dev/null
  runjj_newroot=$(jj -R "$vireo" log -r @ --no-graph -T commit_id)
  jj -R "$vireo" new main@origin >/dev/null
  #    Unprovable first: the dropped mark was signed by a peer.
  runjj_foreign=$(runjj_local_commit main@origin 'a reconcile that never reached the hub' wren)
  runjj_legacy_state "$runjj_foreign"
  runjj_drop_local "$runjj_foreign"
  runjj_status=0
  runjj_out=$(runjj_lib vireo fleet_trust_catch_up "$vireo" "$runjj_newroot") ||
    runjj_status=$?
  [ "$runjj_status" -ne 0 ] ||
    fail "CATCH-UP: a peer-signed mark absent from the archive was adopted across a re-root"
  case $runjj_out in
    *'absent from the archive'*'not provably local-only work'*) ;;
    *) fail "the catch-up refusal does not say why the mark is unprovable: $runjj_out" ;;
  esac
  [ "$(runjj_ref)" = "$runjj_foreign" ] || fail "a refused catch-up moved reviewed-ref"
  #    Provable: this host's own work atop what the archive holds.
  runjj_own=$(runjj_local_commit main@origin 'a reconcile of its own that never reached the hub')
  runjj_legacy_state "$runjj_own"
  runjj_drop_local "$runjj_own"
  runjj_out=$(runjj_lib vireo fleet_trust_catch_up "$vireo" "$runjj_newroot") ||
    fail "CATCH-UP: a legacy mark on this host's own unpublished work wedged the re-root: $runjj_out"
  [ -z "$runjj_out" ] || fail "the re-anchored catch-up printed a hold reason: $runjj_out"
  [ "$(runjj_ref)" = "$runjj_newroot" ] ||
    fail "the catch-up did not advance reviewed-ref to the new root"
}

if [ "$real_jj_ok" = true ] && section_part 2; then
  p0jj_block tombstone p0jj_tombstone 'capped tombstone uninstall, then silent'
  p0jj_block takeover p0jj_takeover 'dead-holder lock takeover, alerted and published'
  p0jj_block compaction p0jj_compaction \
    'alert compaction refused over a layer edit, published, idempotent'
  p0jj_block disown p0jj_disown 'host-only disown: dry run, refusal, publish, no prune after'
fi
if [ "$real_jj_ok" = true ] && section_part 3; then
  p0jj_block aging p0jj_aging 'evidence aging previewed by --dry-run, then published'
  p0jj_block abort p0jj_abort 'a pass aborted mid-apply still lands its queued applied/ and journal records'
  p0jj_block verbs p0jj_verb_refusals \
    'publishing verbs refuse a diverged main, a live lock and a foreign edit'
fi
if [ "$real_jj_ok" = true ] && section_part 4; then
  p0jj_block ratchet-wedge p0jj_ratchet_wedge \
    'mac-studio: abandoned materialized local work never wedges reviewed-ref'
  p0jj_block ratchet-legacy p0jj_ratchet_legacy \
    'legacy marks re-anchored when proved: mac-studio and iris-wsl shapes'
fi
if [ "$real_jj_ok" = true ] && section_part 5; then
  p0jj_block ratchet-unprovable p0jj_ratchet_unprovable \
    'unprovable legacy mark held, alerted, doctored, and the printed re-point recovers it'
  p0jj_block ratchet-rewind p0jj_ratchet_rewind \
    'a rewound origin refused, in the current and the legacy format'
fi
if [ "$real_jj_ok" = true ] && section_part 6; then
  p0jj_block ratchet-diverge p0jj_ratchet_diverge \
    'an origin forked from below the pushed head refused'
  p0jj_block catchup p0jj_catchup \
    'catch-up across a re-root: legacy local mark re-anchored when proved, refused when not'
fi
