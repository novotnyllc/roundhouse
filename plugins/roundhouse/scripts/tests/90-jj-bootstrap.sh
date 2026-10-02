# roundhouse self-check — fleet store bootstrap: paths, the run environment,
# store identity, and the fleet-init / fleet-enroll ordering against real jj.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

# --- host-local path resolution, the run environment, store identity ---
# No jj and no yq: pure path and file logic, so it runs everywhere.

bootstrap_root="$tmp/fleet-bootstrap"
mkdir -p "$bootstrap_root"

(
  # shellcheck source=/dev/null
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"

  # R5: two roundhouse instances live on one machine (the Windows host and its
  # WSL sibling), each with its own certificate, store clone and repo config.
  # Nothing in CI can exercise that, so what CI CAN prove is that "run it
  # twice" is genuinely the same code: every host-local file resolves off the
  # one store resolver, so two store paths give two disjoint instance roots.
  for bootstrap_instance in alpha beta; do
    ROUNDHOUSE_FLEET_STORE="$bootstrap_root/$bootstrap_instance/store"
    export ROUNDHOUSE_FLEET_STORE
    for bootstrap_file in local.yaml krl store.run store.local; do
      fleet_instance_path "$bootstrap_file"
    done
    fleet_identity_path
    fleet_allowed_signers_path
  done >"$bootstrap_root/instance-paths"
  unset ROUNDHOUSE_FLEET_STORE
  [ "$(sort -u "$bootstrap_root/instance-paths" | grep -c .)" -eq 12 ] ||
    fail "two fleet instance roots did not resolve to disjoint host-local paths"
  grep -Fqx "$bootstrap_root/alpha/allowed_signers" "$bootstrap_root/instance-paths" ||
    fail "fleet_allowed_signers_path ignored the instance root"

  # The default instance root is the store's parent, so an unset override
  # still lands on ~/.config/roundhouse.
  [ "$(XDG_CONFIG_HOME="$bootstrap_root/xdg" fleet_instance_root)" = \
    "$bootstrap_root/xdg/roundhouse" ] ||
    fail "the default fleet instance root is not the store's parent"

  # §3.2: the run environment is one function, and it closes stdin. A run that
  # can block on a human hangs a machine nobody is sitting at.
  printf 'STDIN-LEAKED\n' >"$bootstrap_root/stdin-probe"
  bootstrap_env=$(
    fleet_run_env
    printf '%s|%s|%s|%s|%s|' "$JJ_EDITOR" "$GIT_EDITOR" "$PAGER" \
      "$GIT_TERMINAL_PROMPT" "$GIT_SSH_COMMAND"
    cat
  ) <"$bootstrap_root/stdin-probe"
  [ "$bootstrap_env" = 'true|true|cat|0|ssh -o BatchMode=yes|' ] ||
    fail "fleet_run_env did not pin the non-interactive environment and close stdin: $bootstrap_env"

  # The store scaffold carries NO identity marker file: §7.5's discriminator is
  # the genesis commit id, because a marker file could be copied into a hostile
  # store and a genesis commit cannot be produced without producing that commit.
  mkdir -p "$bootstrap_root/identity/store"
  fleet_write_store_scaffold "$bootstrap_root/identity/store"
  grep -Fqx '*  -text' "$bootstrap_root/identity/store/.gitattributes" ||
    fail "the store scaffold wrote no -text attribute"
  [ ! -e "$bootstrap_root/identity/store/.roundhouse-sync-store" ] ||
    fail "the store scaffold still writes an identity marker file (§7.5)"
)

# --- §6.3 the run lock: holder, nonce, takeover, release ---
# No jj: pure file and process logic, so it runs wherever the fold does (the
# stale threshold reads the store's policy through yq).
if [ -n "$fleet_fixture_yq" ]; then
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    verb_root="$bootstrap_root/lock"
    verb_store="$verb_root/store"
    mkdir -p "$verb_store/hosts"
    ROUNDHOUSE_FLEET_STORE=$verb_store
    HOME="$verb_root/home"
    export ROUNDHOUSE_FLEET_STORE HOME
    mkdir -p "$HOME"
    fleet_record_write "$(fleet_identity_path)" '{"name":"vireo"}'
    printf '%s\n' 'policy:' '  canary_group: canary' >"$verb_store/fleet.yaml"
    fleet_lock_command >/dev/null || fail "the run lock could not be taken by hand"
    # A hand-taken lock is `manual`, and is NEVER judged dead: its recorded pid
    # is a shell that may exit a second later, and a run that took it over
    # would publish the operator's half-done edits. The age rule governs it.
    [ "$(fleet_lock_meta_field "$(fleet_lock_path)" manual)" = true ] ||
      fail "a hand-taken lock was not marked manual"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$(fleet_lock_path)" 2>/dev/null ||
      verb_status=$?
    [ "$verb_status" -eq 10 ] ||
      fail "a hand-taken lock was not honoured as held (got $verb_status)"
    jq -c '.pid = 999999' "$(fleet_lock_path)/meta.json" >"$verb_root/manual-meta" &&
      mv "$verb_root/manual-meta" "$(fleet_lock_path)/meta.json"
    fleet_lock_holder_state "$(fleet_lock_path)"
    [ "$fleet_lock_state" = unknown ] ||
      fail "a hand-taken lock whose shell is gone was judged $fleet_lock_state"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$(fleet_lock_path)" 2>/dev/null ||
      verb_status=$?
    [ "$verb_status" -eq 10 ] ||
      fail "a run took over a hand-taken lock whose shell had exited (got $verb_status)"
    fleet_unlock_command >/dev/null
    [ ! -d "$(fleet_lock_path)" ] || fail "fleet-unlock did not release a hand-taken lock"
    # fleet-unlock REFUSES a verified-live run's lock unless forced.
    sleep 300 &
    verb_live_run=$!
    fleet_lock_acquire "$(fleet_lock_path)" "$verb_live_run"
    verb_status=0
    fleet_unlock_command >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 75 ] && [ -d "$(fleet_lock_path)" ] ||
      fail "fleet-unlock released a verified-live run's lock (got $verb_status)"
    fleet_unlock_command --force >/dev/null ||
      fail "fleet-unlock --force did not release a live run's lock"
    [ ! -d "$(fleet_lock_path)" ] || fail "fleet-unlock --force left the lock"
    kill "$verb_live_run" 2>/dev/null || :
    wait "$verb_live_run" 2>/dev/null || :
    # fleet-unlock releases BY IDENTITY: a lock with no meta carries nothing to
    # protect and goes; one whose meta cannot be read needs --force.
    mkdir -p "$(fleet_lock_path)"
    fleet_unlock_command >/dev/null || fail "fleet-unlock refused an evidence-less lock directory"
    [ ! -d "$(fleet_lock_path)" ] || fail "fleet-unlock left an evidence-less lock directory"
    mkdir -p "$(fleet_lock_path)"
    printf ':::not json\n' >"$(fleet_lock_path)/meta.json"
    verb_status=0
    fleet_unlock_command >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 75 ] && [ -d "$(fleet_lock_path)" ] ||
      fail "fleet-unlock released a lock whose meta it could not read (got $verb_status)"
    fleet_unlock_command --force >/dev/null ||
      fail "fleet-unlock --force did not release an unreadable lock"
    [ ! -d "$(fleet_lock_path)" ] || fail "fleet-unlock --force left an unreadable lock"

    # --- §6.3 lock liveness: the holder is asked before the clock ---
    verb_lock=$(fleet_lock_path)
    verb_alerts="$verb_store/alerts/vireo"
    verb_lock_holder() {
      # A real process to name as the holder: alive until killed, with a start
      # time and command `ps` can read back.
      sleep 300 &
      verb_holder=$!
    }
    verb_lock_holder
    fleet_lock_acquire "$verb_lock" "$verb_holder" ||
      fail "the lock could not be taken for a fixture holder"
    verb_first_nonce=$fleet_lock_nonce_held
    [ -n "$verb_first_nonce" ] &&
      [ "$(fleet_lock_meta_field "$verb_lock" nonce)" = "$verb_first_nonce" ] ||
      fail "the lock meta did not record this acquisition's nonce"
    for verb_field in host pid start_time command nonce; do
      [ -n "$(fleet_lock_meta_field "$verb_lock" "$verb_field")" ] ||
        fail "the lock meta does not record the holder's $verb_field"
    done
    # A LIVE matching holder still blocks, whatever its age.
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 10 ] ||
      fail "a live holder did not block the run (got $verb_status)"
    # PID REUSE: the same pid, but not the process that took the lock.
    jq -c '.start_time = "Thu Jan  1 00:00:00 1970"' "$verb_lock/meta.json" \
      >"$verb_root/reused-meta" && mv "$verb_root/reused-meta" "$verb_lock/meta.json"
    rm -rf "$verb_alerts"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>"$verb_root/takeover-err" ||
      verb_status=$?
    [ "$verb_status" -eq 0 ] ||
      fail "a reused pid with a different start time was not taken over (got $verb_status)"
    [ "$(fleet_lock_meta_field "$verb_lock" nonce)" = "$fleet_lock_nonce_held" ] &&
      [ "$fleet_lock_nonce_held" != "$verb_first_nonce" ] ||
      fail "the takeover did not recreate the lock under a new nonce"
    [ "$(fleet_lock_meta_field "$verb_lock" pid)" = "$$" ] ||
      fail "the taken-over lock does not name the new holder"
    grep -q 'took over the run lock' "$verb_root/takeover-err" ||
      fail "the takeover was not reported"
    grep -rqs 'kind: lock-takeover' "$verb_alerts" ||
      fail "the takeover raised no alert"
    ! grep -rqs 'sleep 300' "$verb_alerts" ||
      fail "the dead holder's command line reached a replicated record"
    [ -z "$(find "$(dirname "$verb_lock")" -maxdepth 1 -name "$(basename "$verb_lock").dead.*")" ] ||
      fail "the takeover left the dead lock beside the live one"
    # RELEASE IS BY NONCE: the dead run, exiting late, must not remove its
    # successor's lock by path.
    ! fleet_lock_release "$verb_lock" "$verb_first_nonce" ||
      fail "a stale nonce reported releasing the successor's lock"
    [ -d "$verb_lock" ] ||
      fail "a stale nonce released the successor's lock"
    fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    [ ! -d "$verb_lock" ] || fail "the holding nonce did not release its own lock"
    # The start time does not depend on the READER's zone or locale: a
    # scheduled run and an interactive one need not share either, and a
    # mismatch there would take over a live run's lock.
    fleet_lock_acquire "$verb_lock" "$verb_holder"
    TZ=Pacific/Kiritimati LC_ALL=C fleet_lock_holder_state "$verb_lock"
    [ "$fleet_lock_state" = live ] ||
      fail "a reader in another time zone judged a live holder $fleet_lock_state"
    rm -rf "$verb_lock"
    # A different COMMAND at the same pid and start time is not the holder either.
    fleet_lock_acquire "$verb_lock" "$verb_holder"
    jq -c '.command = "something else entirely"' "$verb_lock/meta.json" \
      >"$verb_root/command-meta" && mv "$verb_root/command-meta" "$verb_lock/meta.json"
    fleet_lock_holder_state "$verb_lock"
    [ "$fleet_lock_state" = dead ] ||
      fail "a pid running a different command read as the live holder ($fleet_lock_state)"
    rm -rf "$verb_lock"
    # A pid that is GONE is dead, and the takeover is immediate rather than two
    # cadences later.
    fleet_lock_acquire "$verb_lock" "$verb_holder"
    kill "$verb_holder" 2>/dev/null || :
    wait "$verb_holder" 2>/dev/null || :
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 0 ] ||
      fail "a lock whose holder pid is gone was not taken over (got $verb_status)"
    fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    # The rename-and-verify step: a lock that is no longer the one judged dead
    # (a racing run replaced it) is put back untouched and the takeover refused.
    fleet_lock_acquire "$verb_lock"
    verb_racer=$fleet_lock_nonce_held
    ! fleet_lock_takeover "$verb_lock" not-the-judged-nonce ||
      fail "a takeover moved a lock whose nonce it never judged"
    [ "$(fleet_lock_meta_field "$verb_lock" nonce)" = "$verb_racer" ] ||
      fail "a refused takeover did not put the racing run's lock back"
    fleet_lock_release "$verb_lock" "$verb_racer"
    # LOCK TRANSITIONS ARE SERIALIZED (fleet_lock_transition_enter): a takeover
    # holds the transition mutex until its new lock is in place, so a racing
    # takeover of the SAME dead holder waits for it, then finds a lock it never
    # judged and leaves it alone — it never renames the live lock aside.
    mkdir -p "$verb_lock"
    printf '{"host":"vireo","pid":%s,"started_at":"2000-01-01T00:00:00Z"}\n' \
      "$verb_holder" >"$verb_lock/meta.json"
    verb_dead_id=$(fleet_lock_identity "$verb_lock")
    (ROUNDHOUSE_TEST_LOCK_TRANSITION_PAUSE=2 fleet_lock_takeover "$verb_lock" "$verb_dead_id") &
    verb_first=$!
    for verb_n in $(seq 1 50); do
      [ ! -d "$verb_lock.t" ] || break
      sleep 0.1
    done
    [ -d "$verb_lock.t" ] || fail "the first takeover never entered its transition"
    verb_wait_start=$(date +%s)
    ! fleet_lock_takeover "$verb_lock" "$verb_dead_id" ||
      fail "two takeovers of one dead holder both succeeded"
    verb_waited=$(($(date +%s) - verb_wait_start))
    wait "$verb_first" || fail "the first takeover of a dead holder failed"
    [ "$verb_waited" -ge 1 ] ||
      fail "a racing takeover did not wait for the transition in progress"
    verb_live_id=$(fleet_lock_identity "$verb_lock")
    [ -n "$verb_live_id" ] && [ "$verb_live_id" != "$verb_dead_id" ] &&
      [ ! -e "$verb_lock.t" ] &&
      [ -z "$(find "$(dirname "$verb_lock")" -maxdepth 1 -name "$(basename "$verb_lock").dead.*")" ] ||
      fail "a racing takeover disturbed the lock the first one made live"
    fleet_lock_release "$verb_lock" "$verb_live_id" ||
      fail "the live lock could not be released after the race"
    # A transition mutex a crashed transition left behind is broken once it is
    # older than a minute, so it can never wedge release or takeover.
    fleet_lock_acquire "$verb_lock"
    verb_racer=$fleet_lock_nonce_held
    mkdir "$verb_lock.t"
    touch -t 200001010000 "$verb_lock.t"
    fleet_lock_release "$verb_lock" "$verb_racer" ||
      fail "a stale transition mutex blocked the release"
    [ ! -d "$verb_lock" ] && [ ! -e "$verb_lock.t" ] ||
      fail "a release behind a stale transition mutex left the lock or the mutex"
    # A holder that stalled past the break must not remove the mutex of the
    # transition that broke it: leave checks its own token.
    fleet_lock_transition_enter "$verb_lock" || fail "could not enter the transition mutex"
    printf 'someone-else\n' >"$verb_lock.t/owner"
    fleet_lock_transition_leave "$verb_lock"
    [ -d "$verb_lock.t" ] || fail "a stalled holder's leave removed its successor's mutex"
    rm -rf "$verb_lock.t"
    fleet_lock_transition_enter "$verb_lock" || fail "could not re-enter the transition mutex"
    fleet_lock_transition_leave "$verb_lock"
    [ ! -e "$verb_lock.t" ] || fail "the holder's own leave did not remove its mutex"
    # A PRE-NONCE lock left by a dead run — the wedge itself — is recovered too:
    # its pid and start stamp are the identity the takeover binds to.
    mkdir -p "$verb_lock"
    printf '{"host":"vireo","pid":%s,"started_at":"2000-01-01T00:00:00Z"}\n' \
      "$verb_holder" >"$verb_lock/meta.json"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 0 ] ||
      fail "a pre-nonce lock with a dead pid was not taken over (got $verb_status)"
    fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    # The PRIMITIVE reports a takeover (exit 11, with the dead holder's pid and
    # stamp) and alerts nothing: the alert, and the stale threshold, are the
    # run's (fleet_run_lock_take), so fleet-store.sh needs neither.
    mkdir -p "$verb_lock"
    printf '{"host":"vireo","pid":%s,"started_at":"2000-01-01T00:00:00Z"}\n' \
      "$verb_holder" >"$verb_lock/meta.json"
    rm -rf "$verb_alerts"
    verb_status=0
    fleet_lock_take "$verb_lock" 999999 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 11 ] && case $fleet_lock_taken_from in *"pid $verb_holder "*) true ;; *) false ;; esac ||
      fail "the lock primitive did not report a takeover with its dead holder (got $verb_status: $fleet_lock_taken_from)"
    [ ! -d "$verb_alerts" ] || fail "the lock primitive wrote an alert itself"
    fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    ! sed -n '/^fleet_lock_take() {/,/^}/p' "$(dirname -- "$cli")/lib/fleet-store.sh" |
      grep -Eq 'fleet_alert_write|fleet_run_stale_after' ||
      fail "the lock primitive reaches back into the run's alert or policy code"
    # …but a pre-nonce lock whose pid is ALIVE proves nothing about its holder,
    # so the age rule still governs it — and the refusal names the age ONCE.
    mkdir -p "$verb_lock"
    printf '{"host":"vireo","pid":%s,"started_at":"2000-01-01T00:00:00Z"}\n' "$$" \
      >"$verb_lock/meta.json"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>"$verb_root/stale-err" ||
      verb_status=$?
    [ "$verb_status" -eq 75 ] ||
      fail "an aged lock with an unprovable live pid was not refused (got $verb_status)"
    # Match the age itself, not the whole line: the lock path is under a
    # mktemp root whose random suffix can read like "9s9".
    grep -Eq ' is [0-9]+s old;' "$verb_root/stale-err" &&
      ! grep -Eq '[0-9]+s[0-9]+s old' "$verb_root/stale-err" ||
      fail "the stale refusal does not name the age exactly once: $(cat "$verb_root/stale-err")"
    rm -f "$verb_lock/meta.json"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>"$verb_root/stale-err" ||
      verb_status=$?
    [ "$verb_status" -eq 75 ] && grep -q 'unknown age' "$verb_root/stale-err" ||
      fail "a lock with no meta was not refused as of unknown age (got $verb_status)"
    rmdir "$verb_lock"

    # --- the pass ceiling: a provably hung run is stopped, then taken over ---
    # A run hung inside an inventory query once held the lock for ~37 hours.
    # Past the ceiling, a holder that is PROVABLY the recorded run (pid, start
    # time and command) is stopped with everything under it and its lock is
    # taken over the ordinary way; anything less than that proof is never
    # signalled. The ceiling is shortened through the self-check hook.
    ROUNDHOUSE_TEST_PASS_CEILING=60
    export ROUNDHOUSE_TEST_PASS_CEILING
    verb_tree() {
      # PID and every descendant, from one `ps` of the table.
      ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
        { kids[$2] = kids[$2] " " $1 }
        END {
          n = 1; q[1] = root
          for (i = 1; i <= n; i++) {
            m = split(kids[q[i]], k, " ")
            for (j = 1; j <= m; j++) if (k[j] != "") q[++n] = k[j]
          }
          for (i = 1; i <= n; i++) printf "%s ", q[i]
        }'
    }
    verb_hung_holder() {
      # The shape of a real hung run, not a toy: a top-level shell leading
      # its own process group (the recorded pid), whose TERM trap releases the
      # lock and CARRIES ON — the old run trap — with a subshell under it that
      # ignores TERM (the pass), and a grandchild in a process group of its
      # own (a manager query run under a bound). Not this shell's child,
      # so a stopped one is reaped at once rather than lingering as a zombie.
      verb_hung=$(
        perl -e 'setpgrp(0, 0); exec @ARGV' bash -c '
          case $2 in
            release) trap "rm -rf \"\$1\"" TERM ;;
            keep) trap : TERM ;;
            # default (and spawner): the leader dies on TERM at once, as the
            # real top-level script does, and only its children are left.
          esac
          # spawner: a descendant leading its own group answers TERM by
          # starting a helper and exiting, so no live member is the
          # ancestor of the helper any more; only its group still finds it.
          [ "$2" != spawner ] ||
            perl -e "setpgrp(0, 0); exec @ARGV" bash -c "trap \"sleep 594 & exit 0\" TERM; while :; do sleep 1; done" &
          ( trap "" TERM; perl -e "setpgrp(0, 0); exec q(sleep), 593" & while :; do sleep 1; done ) &
          while :; do sleep 1; done' verb-hung "$verb_lock" "${1:-keep}" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!"
      )
      # The fixture's OWN `sleep 593`, found in its own tree: other units of
      # the parallel runner run this same fixture.
      verb_hung_tries=0
      verb_hung_child=
      verb_hung_spawner=
      [ "${1:-keep}" = spawner ] || verb_hung_spawner=none
      while { [ -z "$verb_hung_child" ] || [ -z "$verb_hung_spawner" ]; } &&
        [ "$verb_hung_tries" -lt 50 ]; do
        sleep 0.1
        verb_hung_tries=$((verb_hung_tries + 1))
        verb_hung_tree=$(verb_tree "$verb_hung")
        for verb_pid in $verb_hung_tree; do
          case $(ps -o command= -p "$verb_pid" 2>/dev/null) in
            'sleep 593'*) verb_hung_child=$verb_pid ;;
            *'sleep 594 &'*) verb_hung_spawner=$verb_pid ;;
          esac
        done
      done
      [ -n "$verb_hung_child" ] && [ -n "$verb_hung_spawner" ] &&
        [ "$(printf '%s\n' $verb_hung_tree | wc -l | tr -d ' ')" -ge 4 ] ||
        fail "the hung-run fixture did not start its tree ($verb_hung_tree)"
    }
    # A failing assertion must not leave a looping fixture behind — and only
    # the fixture's own processes are killed, never a recycled pid.
    verb_cleanup() {
      for verb_pid in ${verb_hung_tree:-} ${verb_hung_child:-}; do
        case $(ps -o command= -p "$verb_pid" 2>/dev/null) in
          *verb-hung* | *'sleep 594'* | 'sleep 593'* | 'sleep 1'*) kill -KILL "$verb_pid" 2>/dev/null || : ;;
        esac
      done
      # The spawner's TERM helper is in neither set: it starts after the first
      # look. Find it by the groups the run led, as the assertion below does.
      for verb_pid in $(ps -A -o pid= -o pgid= -o command= 2>/dev/null | awk -v tree=" ${verb_hung_tree:-} " '
        index(tree, " " $2 " ") && $3 == "sleep" && $4 == "594" { print $1 }'); do
        kill -KILL "$verb_pid" 2>/dev/null || :
      done
    }
    trap verb_cleanup EXIT
    verb_backdate() {
      # `verb_backdate JQ` — rewrite the lock meta: age it past the ceiling
      # and apply JQ.
      jq -c '.started_at = "2000-01-01T00:00:00Z" | '"$1" "$verb_lock/meta.json" \
        >"$verb_root/meta.tmp" && mv "$verb_root/meta.tmp" "$verb_lock/meta.json"
    }
    verb_alive() { kill -0 "$1" 2>/dev/null; }
    verb_reap() {
      kill -KILL "$@" 2>/dev/null || :
      for verb_reap_pid in "$@"; do wait "$verb_reap_pid" 2>/dev/null || :; done
    }
    # Under the ceiling a live run is the ordinary overlap, untouched.
    verb_hung_holder
    fleet_lock_acquire "$verb_lock" "$verb_hung" || fail "could not lock for the hung fixture"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 10 ] && verb_alive "$verb_hung" ||
      fail "a live run under the ceiling was not left alone (got $verb_status)"
    # A HAND-TAKEN lock past the ceiling is never stopped: it keeps the 75.
    verb_backdate '.manual = true'
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 75 ] && verb_alive "$verb_hung" && verb_alive "$verb_hung_child" ||
      fail "a manual lock past the ceiling was stopped or taken (got $verb_status)"
    # A mismatched start time, command or pid is NOT the recorded run: it is
    # judged dead and taken over like any crash, and nothing is signalled.
    for verb_mismatch in '.start_time = "Thu Jan  1 00:00:00 1970"' \
      '.command = "not-the-holder"' "pid"; do
      rm -rf "$verb_alerts"
      jq -c '.manual = false' "$verb_lock/meta.json" >"$verb_root/meta.tmp" &&
        mv "$verb_root/meta.tmp" "$verb_lock/meta.json"
      if [ "$verb_mismatch" = pid ]; then
        # The recorded pid now belongs to a different live process, carrying
        # the hung run's start time and command.
        sleep 300 &
        verb_other=$!
        verb_backdate ".pid = $verb_other"
      else
        verb_backdate "$verb_mismatch"
      fi
      verb_status=0
      fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
      [ "$verb_status" -eq 0 ] && verb_alive "$verb_hung" && verb_alive "$verb_hung_child" ||
        fail "a holder with a mismatched $verb_mismatch was signalled or not taken over (got $verb_status)"
      if [ "$verb_mismatch" = pid ]; then
        verb_alive "$verb_other" || fail "the process now at the recorded pid was signalled"
        verb_reap "$verb_other"
      fi
      ! grep -rq 'stopped a run' "$verb_alerts" 2>/dev/null ||
        fail "a mismatched $verb_mismatch was reported as a stopped run"
      fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
      fleet_lock_acquire "$verb_lock" "$verb_hung" || fail "could not re-lock for the hung fixture"
    done
    # The recorded run itself, past the ceiling: stopped (its group, its
    # tree, the subshell that ignores TERM, the grandchild in a group of its
    # own), confirmed gone, its lock taken (renamed aside under the transition
    # mutex when it is still there; simply free when the dying run released
    # it), alerted by name — and this process, outside its group, untouched.
    fleet_lock_release "$verb_lock" "$(fleet_lock_identity "$verb_lock")" || :
    for verb_variant in keep release default spawner; do
      # shellcheck disable=SC2086 # one pid per word
      kill -KILL $verb_hung_tree $verb_hung_child 2>/dev/null || :
      verb_hung_holder "$verb_variant"
      fleet_lock_acquire "$verb_lock" "$verb_hung" || fail "could not lock for the $verb_variant fixture"
      rm -rf "$verb_alerts"
      verb_backdate '.'
      verb_status=0
      fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>"$verb_root/ceiling-err" ||
        verb_status=$?
      [ "$verb_status" -eq 0 ] ||
        fail "a hung run ($verb_variant) past the ceiling was not taken over (got $verb_status): $(cat "$verb_root/ceiling-err")"
      for verb_pid in $verb_hung_tree "$verb_hung_child"; do
        ! verb_alive "$verb_pid" ||
          fail "process $verb_pid of the hung run ($verb_variant) survived the ceiling stop"
      done
      # Nothing of the run is left in any group a member led either: the
      # spawner's helper was started after the first look, by a process that
      # then exited.
      ! ps -A -o pgid= -o command= 2>/dev/null | awk -v tree=" $verb_hung_tree " '
        index(tree, " " $1 " ") && $2 == "sleep" && $3 == "594" { found = 1 } END { exit !found }' ||
        fail "a helper the hung run ($verb_variant) started on TERM survived the ceiling stop"
      [ "$(fleet_lock_meta_field "$verb_lock" pid)" = "$$" ] &&
        [ "$(fleet_lock_meta_field "$verb_lock" nonce)" = "$fleet_lock_nonce_held" ] ||
        fail "the stopped run's lock ($verb_variant) was not taken with a fresh nonce"
      [ ! -e "$verb_lock.t" ] || fail "the ceiling takeover left its transition mutex"
      grep -q "stopped a run that held the run lock past the 60s ceiling (pid $verb_hung " \
        "$verb_alerts/lock-takeover.yaml" ||
        fail "the ceiling stop ($verb_variant) raised no lock-takeover alert naming the stopped run: $(cat "$verb_alerts"/* 2>/dev/null)"
      grep -q 'past the 60s ceiling; stopping it' "$verb_root/ceiling-err" ||
        fail "the ceiling stop was not reported"
      # The holder led its own group, the meta says so, and the stop left
      # that group EMPTY, not just the processes it had looked at.
      [ "$(fleet_lock_group_state "$verb_hung")" = empty ] ||
        fail "the ceiling stop ($verb_variant) left the run's process group non-empty"
      fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    done

    # --- the run's process group: a KILLed top-level shell is not a dead run ---
    # The lock names the top-level shell, and the pass runs in subshells under
    # it. KILL (or the OOM killer) ends that shell without its traps and
    # leaves the subshells working; the pid alone read that as a dead holder,
    # and a second run took the lock over beside them. A holder that leads its
    # own group (fleet_lock_lead_group) records it, and is live while anything
    # in that group is. The fixture is 07's fixture_group_holder.
    verb_wait_gone() {
      # `verb_wait_gone PID` — up to ~5 s for PID to be gone (reaped).
      verb_gone_tries=0
      while verb_alive "$1" && [ "$verb_gone_tries" -lt 50 ]; do
        sleep 0.1
        verb_gone_tries=$((verb_gone_tries + 1))
      done
      ! verb_alive "$1"
    }
    trap 'verb_cleanup; fixture_group_kill "${verb_group:-x}" verb-group' EXIT
    verb_group=$(fixture_group_holder verb-group) || fail "the process-group fixture did not start"
    verb_group_pass=$(fixture_group_members "$verb_group" verb-group | grep -vx "$verb_group" | head -1)
    fleet_lock_acquire "$verb_lock" "$verb_group" || fail "could not lock for the process-group fixture"
    [ "$(fleet_lock_meta_field "$verb_lock" pgid)" = "$verb_group" ] &&
      [ -n "$(fleet_lock_boot_id)" ] &&
      [ "$(fleet_lock_meta_field "$verb_lock" boot)" = "$(fleet_lock_boot_id)" ] ||
      fail "the lock meta does not record the holder's own process group and this boot"
    verb_group_nonce=$fleet_lock_nonce_held
    verb_group_meta=$(cat "$verb_lock/meta.json")
    # The holder exiting MID-PROBE, between the start-time read and the
    # command read, is judged by its group too, never dead on an empty command.
    (
      fleet_lock_proc_command() {
        kill -KILL "$verb_group" 2>/dev/null || :
        verb_wait_gone "$verb_group"
      }
      fleet_lock_holder_state "$verb_lock"
      [ "$fleet_lock_state" = live ] && [ "$fleet_lock_live_by" = group ]
    ) || fail "a holder that exited mid-probe was not judged by its group"
    kill -KILL "$verb_group" 2>/dev/null || :
    verb_wait_gone "$verb_group" || fail "the process-group fixture's top-level shell survived KILL"
    verb_alive "$verb_group_pass" || fail "the process-group fixture's subshell died with its top-level shell"
    # The lock reads LIVE, by its group…
    fleet_lock_holder_state "$verb_lock"
    [ "$fleet_lock_state" = live ] && [ "$fleet_lock_live_by" = group ] ||
      fail "a lock whose KILLed holder's group still works read $fleet_lock_state (by ${fleet_lock_live_by:-nothing})"
    # …so a second run is the ordinary overlap and takes nothing over…
    rm -rf "$verb_alerts"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 10 ] && [ "$(fleet_lock_meta_field "$verb_lock" nonce)" = "$verb_group_nonce" ] &&
      verb_alive "$verb_group_pass" ||
      fail "a second run did not leave a KILLed holder's working group alone (got $verb_status)"
    # …and past the ceiling it REFUSES with 75: the recorded process is gone,
    # so nothing left is provably the run, and nothing is signalled on less.
    verb_backdate '.'
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>"$verb_root/group-err" || verb_status=$?
    [ "$verb_status" -eq 75 ] && [ "$(fleet_lock_meta_field "$verb_lock" nonce)" = "$verb_group_nonce" ] &&
      verb_alive "$verb_group_pass" && [ ! -d "$verb_alerts" ] ||
      fail "a KILLed holder's working group past the ceiling was not refused with 75, untouched (got $verb_status)"
    grep -q "process group $verb_group, its top-level pid gone" "$verb_root/group-err" ||
      fail "the refusal does not name the group that is left: $(cat "$verb_root/group-err")"
    ! fleet_lock_stop_holder "$verb_lock" "$(fleet_lock_identity "$verb_lock")" &&
      verb_alive "$verb_group_pass" ||
      fail "the holder stop signalled a group whose recorded process is gone"
    # A HAND-TAKEN lock is never judged and never stopped, group or not.
    verb_backdate '.manual = true'
    fleet_lock_holder_state "$verb_lock"
    [ "$fleet_lock_state" = unknown ] || fail "a manual lock was judged $fleet_lock_state by its group"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 75 ] && verb_alive "$verb_group_pass" &&
      [ "$(fleet_lock_meta_field "$verb_lock" nonce)" = "$verb_group_nonce" ] ||
      fail "a manual lock with a working group was stopped or taken (got $verb_status)"
    ! fleet_lock_stop_holder "$verb_lock" "$(fleet_lock_identity "$verb_lock")" &&
      verb_alive "$verb_group_pass" || fail "the holder stop signalled a manual lock's group"
    # AN OLD-FORMAT META (no pgid), a group the holder did not lead, or a lock
    # from another boot keeps the pid rule exactly as before: the holder's pid
    # is gone, so it is dead.
    for verb_old in 'del(.pgid)' '.pgid = 1' 'del(.boot)' '.boot = "an-earlier-boot"'; do
      printf '%s\n' "$verb_group_meta" | jq -c "$verb_old" >"$verb_lock/meta.json"
      fleet_lock_holder_state "$verb_lock"
      [ "$fleet_lock_state" = dead ] ||
        fail "a lock meta with $verb_old was judged $fleet_lock_state, not by its pid"
    done
    # …but a boot that cannot be READ right now proves no reboot: unknown.
    printf '%s\n' "$verb_group_meta" >"$verb_lock/meta.json"
    (
      fleet_lock_boot_id() { :; }
      fleet_lock_holder_state "$verb_lock"
      [ "$fleet_lock_state" = unknown ]
    ) || fail "an unreadable boot id was read as a reboot"
    printf '%s\n' "$verb_group_meta" | jq -c 'del(.pgid, .boot)' >"$verb_lock/meta.json"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 0 ] && [ "$(fleet_lock_meta_field "$verb_lock" pid)" = "$$" ] ||
      fail "an old-format lock whose holder pid is gone was not taken over (got $verb_status)"
    fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    # ONCE THE GROUP IS EMPTY the holder is dead, and the takeover proceeds.
    mkdir "$verb_lock"
    printf '%s\n' "$verb_group_meta" >"$verb_lock/meta.json"
    fixture_group_kill "$verb_group" verb-group
    verb_wait_gone "$verb_group_pass" || fail "the process-group fixture's subshell survived KILL"
    verb_group_tries=0
    until [ "$(fleet_lock_group_state "$verb_group")" = empty ] || [ "$verb_group_tries" -ge 50 ]; do
      sleep 0.1
      verb_group_tries=$((verb_group_tries + 1))
    done
    fleet_lock_holder_state "$verb_lock"
    [ "$fleet_lock_state" = dead ] || fail "a lock whose holder's group is empty read $fleet_lock_state"
    rm -rf "$verb_alerts"
    verb_status=0
    fleet_run_lock_take "$verb_store" vireo "$verb_lock" 2>/dev/null || verb_status=$?
    [ "$verb_status" -eq 0 ] && [ "$(fleet_lock_meta_field "$verb_lock" pid)" = "$$" ] &&
      grep -rqs 'kind: lock-takeover' "$verb_alerts" ||
      fail "a lock whose holder's group is empty was not taken over and alerted (got $verb_status)"
    fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    trap verb_cleanup EXIT

    # EVERY RUN-LOCK VERB LEADS ITS OWN GROUP (fleet_lock_lead_group): with no
    # terminal and no group of its own, the verb runs in a child that leads a
    # new group, under a thin parent that stays where the caller put it,
    # passes TERM/INT/HUP on to the whole group, and exits with the child's
    # status. The probe starts in a new session: no controlling terminal, and
    # not its session's group leader.
    verb_lead="$verb_root/lead"
    cat >"$verb_lead-probe" <<'PROBE'
. "$1/fleet-store.sh"
# The child runs this script again from the top: only the first pass records.
[ -e "$2.before" ] || printf '%s\n' "$$" >"$2.before"
fleet_lock_lead_group "$0" "$@"
trap 'printf "term\n" >"$2.term"; exit 143' TERM
printf '%s|%s|%s|%s|%s\n' "$$" "$(fleet_lock_proc_pgid "$$")" "$PPID" \
  "${ROUNDHOUSE_LOCK_GROUP_LEADER:-unset}" "$3 $4" >"$2.after"
[ "$3" != wait ] || while :; do sleep 1; done
exit 7
PROBE
    verb_lead_run() {
      perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV' \
        bash -c 'bash "$@"; exit $?' verb-lead "$verb_lead-probe" "$(dirname -- "$cli")/lib" "$verb_lead" "$@" </dev/null
    }
    rm -f "$verb_lead".*
    verb_status=0
    verb_lead_run exit "two words" || verb_status=$?
    verb_lead_parent=$(cat "$verb_lead.before" 2>/dev/null)
    verb_lead_after=$(cat "$verb_lead.after" 2>/dev/null)
    verb_lead_child=${verb_lead_after%%|*}
    [ "$verb_status" -eq 7 ] && [ -n "$verb_lead_parent" ] && [ "$verb_lead_child" != "$verb_lead_parent" ] &&
      [ "$verb_lead_after" = "$verb_lead_child|$verb_lead_child|$verb_lead_parent|unset|exit two words" ] ||
      fail "a run-lock verb did not run as its own group leader under its thin parent (exit $verb_status): $verb_lead_parent / $verb_lead_after"
    # TERM to the parent — what timeout(1) or a killpg of the caller's group
    # reaches — ends the run through its own trap, and the parent says so.
    rm -f "$verb_lead".*
    verb_lead_run wait "" &
    verb_lead_bg=$!
    verb_tries=0
    until [ -s "$verb_lead.after" ] || [ "$verb_tries" -ge 50 ]; do
      sleep 0.1
      verb_tries=$((verb_tries + 1))
    done
    verb_lead_parent=$(cat "$verb_lead.before" 2>/dev/null)
    verb_lead_child=$(cut -d'|' -f1 "$verb_lead.after" 2>/dev/null)
    [ -n "$verb_lead_parent" ] && [ -n "$verb_lead_child" ] || fail "the forwarding probe never started"
    kill -TERM "$verb_lead_parent" 2>/dev/null || :
    verb_status=0
    wait "$verb_lead_bg" || verb_status=$?
    verb_wait_gone "$verb_lead_child" || kill -KILL -- "-$verb_lead_child" 2>/dev/null || :
    [ "$verb_status" -eq 143 ] && [ -f "$verb_lead.term" ] && ! verb_alive "$verb_lead_child" ||
      fail "a TERM to the thin parent did not end the run through its trap (exit $verb_status)"
    # Which verbs: every *_command that takes the run lock, read from the code
    # rather than from a second list. Only DIRECT calls in a command's own
    # body are seen; a verb reaching the lock through another helper is not.
    verb_lead_verbs=" $(awk '/fleet_lock_lead_group "\$0"/ { print prev } { prev = $0 }' "$cli" | tr -d '|)') "
    for verb_fn in $(sed -n 's/^\(fleet_[a-z_]*_command\)() .*/\1/p' "$(dirname -- "$cli")"/lib/*.sh); do
      cli_function_body "$verb_fn" | grep -Eq 'fleet_run_verb_begin|fleet_run_lock_take' || continue
      verb_name=$(printf '%s\n' "${verb_fn%_command}" | tr _ -)
      case $verb_lead_verbs in
        *" $verb_name "*) ;;
        *) fail "the run-lock verb $verb_name does not lead its own process group" ;;
      esac
    done
    case $verb_lead_verbs in
      *" fleet-run "*" fleet-disown "*) ;;
      *) fail "the lead-group verb list could not be read from the dispatcher: $verb_lead_verbs" ;;
    esac
    # The stop itself refuses anything but a live verdict on the same lock.
    sleep 300 &
    verb_other=$!
    fleet_lock_acquire "$verb_lock" "$verb_other" manual
    fleet_lock_holder_state "$verb_lock"
    ! fleet_lock_stop_holder "$verb_lock" "$(fleet_lock_identity "$verb_lock")" &&
      verb_alive "$verb_other" || fail "the holder stop signalled a manual lock's holder"
    fleet_lock_release "$verb_lock" "$fleet_lock_nonce_held"
    verb_reap "$verb_other"
    # A LOOK THAT FAILS STOPS NOTHING: when the process table cannot be read
    # mid-stop, no signal goes out on a set that may be missing the run's
    # descendants, nothing is taken over, and the refusal is the stale 75.
    verb_cleanup
    verb_hung_holder keep
    fleet_lock_acquire "$verb_lock" "$verb_hung" || fail "could not lock for the snapshot-failure fixture"
    rm -rf "$verb_alerts"
    verb_backdate '.'
    verb_status=0
    (
      fleet_lock_stop_snapshot() { return 1; }
      fleet_run_lock_take "$verb_store" vireo "$verb_lock"
    ) 2>"$verb_root/snapfail-err" || verb_status=$?
    [ "$verb_status" -eq 75 ] || fail "a failed process-table read did not refuse with 75 (got $verb_status)"
    for verb_pid in "$verb_hung" "$verb_hung_child"; do
      verb_alive "$verb_pid" || fail "process $verb_pid was signalled although the process table could not be read"
    done
    [ "$(fleet_lock_meta_field "$verb_lock" pid)" = "$verb_hung" ] && [ ! -d "$verb_alerts" ] ||
      fail "a failed stop took the lock over or alerted"
    verb_cleanup
    fleet_lock_release "$verb_lock" "$(fleet_lock_identity "$verb_lock")" || rm -rf "$verb_lock"
    # EVERY LOCK-OWNING VERB ENDS ON A SIGNAL, as the pass does: past the
    # ceiling a publishing verb is stoppable too, and a TERM trap that only
    # released the lock let it carry on, lockless, through the grace period.
    for verb_fn in fleet_age_evidence_command fleet_compact_alerts_command fleet_disown_command; do
      verb_body=$(cli_function_body "$verb_fn")
      printf '%s\n' "$verb_body" | grep -q 'fleet_lock_signals_exit' &&
        ! printf '%s\n' "$verb_body" | grep -E "trap 'fleet_lock_release" | grep -qE 'HUP|INT|TERM' ||
        fail "$verb_fn does not exit on HUP/INT/TERM while it holds the lock"
    done
    # …and behaviourally: fleet-age-evidence, TERMed mid-way, runs not one
    # more command and releases its lock.
    rm -f "$verb_root/verb-started" "$verb_root/verb-continued" "$verb_root/verb-pid"
    (
      fleet_run_env() { :; }
      fleet_records_retention_days() { printf '30\n'; }
      fleet_fold() { printf '{}\n'; }
      fleet_run_verb_begin() {
        fleet_lock_acquire "$(fleet_lock_path)" || return 75
        fleet_run_verb_nonce=$fleet_lock_nonce_held
      }
      fleet_records_age() {
        : >"$verb_root/verb-started"
        sleep 2
        : >"$verb_root/verb-continued"
      }
      fleet_age_evidence_command >/dev/null 2>&1 &
      printf '%s\n' "$!" >"$verb_root/verb-pid"
      wait "$!" 2>/dev/null || :
    ) &
    verb_runner=$!
    verb_tries=0
    while [ ! -f "$verb_root/verb-started" ] && [ "$verb_tries" -lt 100 ]; do
      sleep 0.1
      verb_tries=$((verb_tries + 1))
    done
    [ -f "$verb_root/verb-started" ] || fail "the age-evidence fixture never started"
    # TERM to the verb's whole tree, as the ceiling stop sends it (a `( )`
    # function backgrounded is a fork with the body's subshell under it).
    verb_term_tree=$(verb_tree "$(cat "$verb_root/verb-pid")")
    # shellcheck disable=SC2086 # one pid per word
    kill -TERM $verb_term_tree 2>/dev/null || :
    wait "$verb_runner" 2>/dev/null || :
    verb_tries=0
    while [ -n "$(for verb_pid in $verb_term_tree; do verb_alive "$verb_pid" && printf x; done)" ] &&
      [ "$verb_tries" -lt 50 ]; do
      sleep 0.1
      verb_tries=$((verb_tries + 1))
    done
    sleep 2.5
    [ ! -f "$verb_root/verb-continued" ] ||
      fail "fleet-age-evidence carried on after TERM"
    [ ! -d "$verb_lock" ] || fail "fleet-age-evidence did not release its lock on TERM"
    unset ROUNDHOUSE_TEST_PASS_CEILING
  ) || exit 1
fi

# --- real jj: bootstrap ordering, the pins, and enrollment ---
# Everything below can only be falsified by real tools: §3.3's brick case is a
# claim about what jj 0.44 does when signing config precedes the certificate,
# and a comment cannot verify it. The suite sanitizes PATH early, so probe the
# standard install locations in addition to whatever survives on PATH.
bootstrap_tool_path() {
  bootstrap_found=$(command -v "$1" 2>/dev/null || true)
  if [ -z "$bootstrap_found" ]; then
    for candidate in "/opt/homebrew/bin/$1" "/usr/local/bin/$1" \
      "$HOME/.local/bin/$1" "$HOME/.cargo/bin/$1"; do
      [ ! -x "$candidate" ] || {
        bootstrap_found=$candidate
        break
      }
    done
  fi
  printf '%s\n' "$bootstrap_found"
}
real_jj=$(bootstrap_tool_path jj)
real_yq=$(bootstrap_tool_path yq)
real_jj_version=
real_jj_ok=false
if [ -n "$real_jj" ] && [ -n "$real_yq" ]; then
  real_jj_version=$("$real_jj" --version 2>/dev/null |
    sed -n 's/^jj \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  real_jj_major=${real_jj_version%%.*}
  real_jj_minor=${real_jj_version#*.}
  if [ -n "$real_jj_version" ] &&
    { [ "$real_jj_major" -gt 0 ] || [ "$real_jj_minor" -ge 43 ]; } 2>/dev/null; then
    real_jj_ok=true
  fi
fi
# CI installs jj and sets this, so the five real-jj sections RUN there rather
# than printing a NOTICE nobody reads. One guard, here, where the gate is
# decided: a per-section check is five places for the skip to survive in.
if [ "${ROUNDHOUSE_REQUIRE_REAL_JJ:-false}" = true ] && [ "$real_jj_ok" != true ]; then
  fail "ROUNDHOUSE_REQUIRE_REAL_JJ is set but jj >= 0.43 and yq are not both usable (jj ${real_jj_version:-none}, yq ${real_yq:-none})"
fi

# --- the key/roster/KRL fixture generator, shared by every real-jj section ---
# Real ed25519 node keys, a real hand-editable roster listing them by value,
# and a real KRL. THERE IS NO CA AND NO CERTIFICATE. Nothing expires on an
# unwritten date and nothing is stubbed: the signature gate this material feeds
# is the one thing v1 tested only under an env-var bypass, which is why the
# bypass is deleted. Defined at section scope rather than inside the block below
# so sections 91 and 92 mint their own material with the same three lines; each
# sets `$rjj` to its own directory first.
rjj_key() {
  # rjj_key <node-id> — one plain ed25519 node key. THERE IS NO CA AND NO
  # CERTIFICATE: the roster lists this key by value, which is what binds the
  # principal natively rather than through a wildcard authority line.
  /usr/bin/ssh-keygen -q -t ed25519 -N '' -C '' -f "$rjj/$1-key"
}
rjj_signer() {
  # keytype + base64 only, the way the roster carries it.
  awk '{ printf "%s %s", $1, $2 }' "$rjj/$1-key.pub"
}
rjj_roster() {
  # rjj_roster <dest> <generation> <name>:<class>[:<valid_before>]...
  # The roster as a real host would hand-edit it, one block per machine.
  rjj_roster_dest=$1
  rjj_roster_gen=$2
  shift 2
  printf 'generation: %s\n' "$rjj_roster_gen" >"$rjj_roster_dest"
  for rjj_roster_class in durable ephemeral; do
    rjj_roster_any=false
    for rjj_roster_spec in "$@"; do
      rjj_roster_name=${rjj_roster_spec%%:*}
      rjj_roster_rest=${rjj_roster_spec#*:}
      rjj_roster_kind=${rjj_roster_rest%%:*}
      [ "$rjj_roster_kind" = "$rjj_roster_class" ] || continue
      if [ "$rjj_roster_any" = false ]; then
        printf '%s:\n' "$rjj_roster_class" >>"$rjj_roster_dest"
        rjj_roster_any=true
      fi
      printf '  %s:\n    principal: %s@fleet.example.invalid\n    key: "%s"\n' \
        "$rjj_roster_name" "$rjj_roster_name" "$(rjj_signer "$rjj_roster_name")" \
        >>"$rjj_roster_dest"
      printf '    enrolled_at: 2020-01-01T00:00:00Z\n    channel_auth: known_hosts\n' \
        >>"$rjj_roster_dest"
      [ "$rjj_roster_class" != ephemeral ] ||
        printf '    sponsor: vireo\n' >>"$rjj_roster_dest"
      # DELIBERATELY UNQUOTED: yq types a bare ISO8601 stamp as a timestamp,
      # and a hand-editable roster cannot be relied on to quote its dates, so
      # the fixture is the unfriendly case.
      case $rjj_roster_rest in
        *:*) printf '    valid_before: %s\n' "${rjj_roster_rest#*:}" \
          >>"$rjj_roster_dest" ;;
      esac
    done
  done
}
rjj_krl() {
  # rjj_krl <name> [revoked-key.pub]... — no keys mints an empty KRL, which is
  # the honest "no revocations known yet" state and is the normal steady state:
  # the KRL is the emergency lever, never the removal path.
  rjj_krl_name=$1
  shift
  /usr/bin/ssh-keygen -q -k -f "$rjj/$rjj_krl_name" "$@"
}

if ! section_requested 90; then
  # Loaded only as the real-jj prerequisite of 91+: they need the probe and the
  # fixture generators above. The subshell below leaks nothing to them, so its
  # assertions run once, in 90's own run, not again under every later section.
  :
elif [ "$real_jj_ok" != true ]; then
  printf '\n'
  printf '========================================================================\n'
  printf 'NOTICE: real-jj bootstrap block skipped\n'
  printf '  required: jj >= 0.43 and yq   found: jj %s, yq %s\n' \
    "${real_jj_version:-none}" "${real_yq:-none}"
  printf '  §3.3 bootstrap ordering is UNVERIFIED in this run.\n'
  printf '  Run this suite once on a jj-equipped host before merge.\n'
  printf '========================================================================\n'
  printf '\n'
else
  printf 'real-jj: fleet bootstrap ordering and enrollment (jj %s)\n' "$real_jj_version"
  (
    set -eu
    # Distinct failure voice: anything below is a real-jj finding, not a
    # fixture regression.
    fail() {
      printf 'FAIL: real-jj: %s\n' "$*" >&2
      exit 1
    }
    PATH="$(dirname "$real_jj"):$(dirname "$real_yq"):$PATH"
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    rjj="$bootstrap_root/real"
    mkdir -p "$rjj"
    # Ambient jj identity, standing in for the operator's own ~/.config/jj.
    # fleet-init's repo-local pins must win over it.
    cat >"$rjj/jj-config.toml" <<'TOML'
[user]
name = "roundhouse selfcheck"
email = "roundhouse-selfcheck@example.invalid"
[ui]
paginate = "never"
TOML
    export JJ_CONFIG="$rjj/jj-config.toml"
    # jj 0.44 does not keep `--repo` config in the store: it migrates
    # .jj/repo/config.toml to $XDG_CONFIG_HOME/jj/repos/<opaque-hash>/ and
    # leaves a symlink behind (the [rev2] observation §2 records). So the XDG
    # root is machine-wide and shared by every instance — one root here, with
    # instances told apart by store path, which is what a real machine looks
    # like. Reading a pin back from a different XDG root silently answers with
    # the operator's own jj config instead.
    export XDG_CONFIG_HOME="$rjj/xdg"

    # The key/roster/KRL fixture generator is defined at section scope above.
    rjj_key corvid
    rjj_krl empty.krl
    [ -s "$rjj/empty.krl" ] ||
      fail "the key/roster/KRL fixture generator produced nothing"

    rjj_run() {
      # One roundhouse invocation against one instance root. The store path is
      # the ONLY thing that distinguishes two instances: every host-local file
      # follows it, and no host-local file follows XDG.
      rjj_instance=$1
      shift
      mkdir -p "$rjj/$rjj_instance"
      # §7.1's principal is `<node_id>@<domain>`, and identity.yaml is the only
      # source that survives a rename. Written here so the fixture host names
      # are the ones the assertions below use, rather than this machine's.
      [ -f "$rjj/$rjj_instance/identity.yaml" ] ||
        printf 'name: %s\ndomain: fleet.example.invalid\n' "$rjj_instance" \
          >"$rjj/$rjj_instance/identity.yaml"
      env ROUNDHOUSE_FLEET_STORE="$rjj/$rjj_instance/store" \
        ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/$rjj_instance-key" \
        ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_TRUST_ROOT="$rjj/$rjj_instance" \
        "$@"
    }

    # 1. §3.3, the brick case — the reason fleet-init and fleet-enroll are two
    #    commands. With signing.behavior=own and signing.key naming a file
    #    that does not exist, `jj git init --colocate` does not merely fail to
    #    sign: it dies and the repo is NEVER CREATED.
    cat >"$rjj/bricked-config.toml" <<TOML
[user]
name = "roundhouse selfcheck"
email = "vireo@fleet.example.invalid"
[ui]
paginate = "never"
editor = "true"
[signing]
backend = "ssh"
behavior = "own"
key = "$rjj/no-such-key"
[signing.backends.ssh]
program = "/usr/bin/ssh-keygen"
TOML
    mkdir -p "$rjj/bricked"
    rjj_brick_status=0
    JJ_CONFIG="$rjj/bricked-config.toml" jj git init --colocate "$rjj/bricked" \
      >/dev/null 2>"$rjj/bricked.err" || rjj_brick_status=$?
    [ "$rjj_brick_status" -ne 0 ] ||
      fail "[signing] before the certificate no longer bricks jj git init — re-derive §3.3 before merging enroll back into init"
    grep -qi 'signing error\|sign failed' "$rjj/bricked.err" ||
      fail "jj git init failed for a reason other than signing: $(cat "$rjj/bricked.err")"
    [ ! -d "$rjj/bricked/.jj" ] ||
      fail "the bricked init left a jj repository behind (the failure mode changed)"

    # 2. The split order succeeds, and fleet-init writes NO signing config.
    rjj_init=$(rjj_run vireo "$cli" fleet-init) ||
      fail "fleet-init failed on a host with no certificate"
    [ -d "$rjj/vireo/store/.jj" ] ||
      fail "fleet-init created no colocated jj repository"
    [ -d "$rjj/vireo/store/.git" ] ||
      fail "the fleet store carries no git backing"
    # fleet-init CANNOT report a store id: the roster commit fleet-enroll makes
    # IS the genesis, and a scaffold commit here would become the genesis
    # instead — so store_id would name a commit carrying no roster, signed by
    # nobody.
    ! printf '%s\n' "$rjj_init" | grep -q 'store id [0-9a-f]' ||
      fail "fleet-init reported a store id before the roster commit existed (§12)"
    [ -z "$(fleet_store_id "$rjj/vireo/store")" ] ||
      fail "fleet-init created history; the roster commit must BE the genesis"
    # Repo scope, not effective value: jj answers `none`/`keep` for unset
    # signing keys, so the question is whether fleet-init wrote any of them
    # HERE — which is the thing that bricks the next init.
    rjj_repo_signing() {
      jj -R "$1" config list --repo signing 2>/dev/null | grep -c '^signing' ||
        true
    }
    [ "$(rjj_repo_signing "$rjj/vireo/store")" -eq 0 ] ||
      fail "fleet-init wrote repo-local [signing] before a key existed (§3.3)"
    # §3.1 and §3.2 by EFFECTIVE value, which is also doctor's row.
    rjj_drift=$(fleet_pins_drift "$rjj/vireo/store" || true)
    [ -z "$rjj_drift" ] ||
      fail "fleet-init left config pins unset or wrong: $rjj_drift"
    grep -Fqx '*  -text' "$rjj/vireo/store/.gitattributes" ||
      fail "fleet-init wrote no store scaffold"

    # 3. The 1Password inheritance trap, in its own store so the probe cannot
    #    disturb a jj working copy. The owner's global git config signs every
    #    commit through op-ssh-sign, so any agent shelling out to git inside
    #    the store pops an approval dialog — and §8.4's own premise is that
    #    agents shell out to git. The stand-in fails loudly and records that
    #    it ran, so a leak is a failure and never a hang.
    cat >"$rjj/op-ssh-sign" <<'SH'
#!/usr/bin/env bash
printf 'leaked\n' >>"$OP_SSH_SIGN_MARKER"
printf 'op-ssh-sign: interactive approval required\n' >&2
exit 1
SH
    chmod +x "$rjj/op-ssh-sign"
    cat >"$rjj/ambient-gitconfig" <<TOML
[user]
	name = ambient
	email = ambient@example.invalid
[commit]
	gpgsign = true
[tag]
	gpgsign = true
[gpg]
	format = ssh
[gpg "ssh"]
	program = $rjj/op-ssh-sign
[core]
	pager = less
	editor = false
TOML
    OP_SSH_SIGN_MARKER="$rjj/op-ssh-sign-ran"
    export OP_SSH_SIGN_MARKER
    GIT_CONFIG_GLOBAL="$rjj/ambient-gitconfig"
    export GIT_CONFIG_GLOBAL
    rjj_run ambient "$cli" fleet-init >/dev/null ||
      fail "fleet-init failed under an ambient signing git config"
    [ "$(git -C "$rjj/ambient/store" config --get gpg.ssh.program)" = ssh-keygen ] ||
      fail "the ambient gpg.ssh.program was not overridden repo-locally"
    [ "$(git -C "$rjj/ambient/store" config --get core.pager)" = cat ] ||
      fail "the ambient pager was not overridden repo-locally"
    printf 'ambient probe\n' >"$rjj/ambient/store/.git-probe"
    git -C "$rjj/ambient/store" add -f .git-probe
    git -C "$rjj/ambient/store" commit -q -m 'ambient probe' ||
      fail "a plain git commit inside the store fell through to the ambient signer"
    [ ! -f "$OP_SSH_SIGN_MARKER" ] ||
      fail "op-ssh-sign leaked into the store repo (§3.2 point 3)"
    unset GIT_CONFIG_GLOBAL

    # 4. fleet-enroll, in §3.3's order: keygen -> user.email -> [signing] ->
    #    the SELF-SIGNED roster commit, which IS the genesis.
    rjj_no_store_status=0
    rjj_run corvid "$cli" fleet-enroll >/dev/null 2>&1 || rjj_no_store_status=$?
    [ "$rjj_no_store_status" -eq 69 ] ||
      fail "fleet-enroll did not refuse a host with no store (got $rjj_no_store_status)"
    rjj_enroll=$(rjj_run vireo "$cli" fleet-enroll) ||
      fail "fleet-enroll failed on a host with no key (it is supposed to mint one)"
    assert_contains "$rjj_enroll" 'vireo@'
    [ -f "$rjj/vireo-key" ] ||
      fail "fleet-enroll minted no node key — there is no CA to ask for one"
    [ "$(fleet_signer_entry "$rjj/vireo-key.pub")" = \
      "$(awk '{ printf "%s %s", $1, $2 }' "$rjj/vireo-key.pub")" ] ||
      fail "the minted key is not a usable signer entry"
    rjj_signers="$rjj/vireo/allowed_signers"
    [ -f "$rjj_signers" ] ||
      fail "fleet-enroll materialized no allowed_signers under \$TRUST"
    # PER-KEY LINES, never a wildcard authority: the principal is bound
    # natively, and `namespaces="git"` is what keeps a roundhouse-enroll
    # possession proof from being replayed as a commit signature.
    ! grep -q 'cert-authority' "$rjj_signers" ||
      fail "the materialized roster carries a cert-authority line (there is no CA)"
    grep -q '^[^ ]*@[^ ]* namespaces="git" ssh-ed25519 ' "$rjj_signers" ||
      fail "the materialized roster line is not <principal> namespaces=\"git\" <key>"
    ! grep -qE 'valid-before=|valid-after=' "$rjj_signers" ||
      fail "the materialized roster carries a TIME OPTION, which is evaluated at wall clock and is therefore retroactive (§7.1b)"
    [ -f "$rjj/vireo/krl" ] ||
      fail "fleet-enroll installed no host-local KRL"
    rjj_store_id=$(printf '%s\n' "$rjj_enroll" |
      sed -n 's/^.*store id \([0-9a-f][0-9a-f]*\).*$/\1/p')
    [ -n "$rjj_store_id" ] ||
      fail "fleet-enroll reported no store id UPWARD (§12: it is an output)"
    [ "$(fleet_store_id "$rjj/vireo/store")" = "$rjj_store_id" ] ||
      fail "the reported store id is not this store's genesis commit id"
    # §7.5: the FOUNDER MUST END PINNED, like every sponsored host. store_id is
    # an output, but it is also written back into the founder's own
    # identity.yaml — without it host 1 stays pinless forever and any parentless
    # commit reaches roster_derive's genesis self-verify branch.
    [ "$(FLEET_IDENTITY_KEY=store_id yq -r '.[strenv(FLEET_IDENTITY_KEY)] // ""' \
      "$rjj/vireo/identity.yaml")" = "$rjj_store_id" ] ||
      fail "the founder did not back-fill its own store_id — it ends unpinned (§7.5)"
    # The genesis roster must list the key that signed it.
    jj -R "$rjj/vireo/store" file show -r "$rjj_store_id" \
      "root:$fleet_trust_roster_file" | grep -Fq "$(rjj_signer vireo)" ||
      fail "the genesis roster does not list the key that signed the genesis commit"
    case $(jj -R "$rjj/vireo/store" config get user.email) in
      *@*) ;;
      *) fail "user.email is not a roster principal (§7.3's equality gate)" ;;
    esac
    [ "$(jj -R "$rjj/vireo/store" config get signing.behavior)" = own ] ||
      fail "fleet-enroll did not write signing.behavior own"
    [ "$(jj -R "$rjj/vireo/store" config get signing.key)" = "$rjj/vireo-key" ] ||
      fail "signing points at something other than the minted node key"
    fleet_signing_ready "$rjj/vireo/store" ||
      fail "fleet_signing_ready refused a correctly enrolled store"

    # The library assertions below call the ratchet directly rather than
    # through the CLI, so they need the same $TRUST this instance was enrolled
    # against — the trust roots are read FRESH per invocation and never from
    # repo config, which is the point.
    export ROUNDHOUSE_SELFTEST=1
    export ROUNDHOUSE_TRUST_ROOT="$rjj/vireo"
    export ROUNDHOUSE_FLEET_STORE="$rjj/vireo/store"

    # 5. The gate this whole ordering exists to make possible: the genesis
    #    commit verifies good against its OWN roster, and its signature
    #    principal equals its committer email (§7.3).
    rjj_signature=$(fleet_trust_signature_read "$rjj/vireo/store" \
      "$rjj_store_id" "$rjj_signers")
    case $rjj_signature in
      'good '*) ;;
      *) fail "the genesis commit did not verify good: $rjj_signature" ;;
    esac
    [ "$(printf '%s' "$rjj_signature" | awk '{ print $2 }')" = \
      "$(printf '%s' "$rjj_signature" | awk '{ print $3 }')" ] ||
      fail "the genesis signature principal does not equal its committer: $rjj_signature"

    # 6. Enrollment is IDEMPOTENT, and it is also the heal path, the rename
    #    path and the reconstitution path. A second run must not mint a second
    #    genesis or a second key.
    rjj_run vireo "$cli" fleet-enroll >/dev/null ||
      fail "fleet-enroll is not idempotent"
    [ "$(fleet_store_id "$rjj/vireo/store")" = "$rjj_store_id" ] ||
      fail "re-running fleet-enroll moved the genesis"

    # 7. §7.9's detection compare: a hand-edited materialized roster is
    #    precisely the self-enrollment signature, and the mismatch is a hold
    #    rather than a repair.
    [ -z "$(fleet_trust_materialization_drift "$rjj/vireo/store")" ] ||
      fail "a freshly materialized roster already disagrees with the ratchet"
    printf 'attacker@fleet.example.invalid namespaces="git" %s\n' \
      "$(rjj_signer corvid)" >>"$rjj_signers"
    [ -n "$(fleet_trust_materialization_drift "$rjj/vireo/store")" ] ||
      fail "a key appended to the materialized roster was not detected (§7.9)"
    rjj_run vireo "$cli" fleet-enroll >/dev/null

    # 8. §7.5 at init, against a real clone. `jj git clone` performs no check
    #    whatsoever on the remote's content, so this comparison is the only
    #    thing standing between this fleet and a foreign store — and the
    #    genesis commit id is UNFORGEABLE where a marker file was merely
    #    copyable.
    "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"
    "$REAL_GIT" -C "$rjj/vireo/store" push -q "$rjj/remote.git" main ||
      fail "could not publish the fleet store to the fixture remote"
    # The three commands that run OUTSIDE the store's repo config carry the
    # pins explicitly (§3.2): a clone happens before fleet-init writes any.
    jj git clone --colocate --config ui.editor='"true"' \
      --config ui.paginate=never "$rjj/remote.git" "$rjj/corvid/store" \
      >/dev/null 2>&1 ||
      fail "could not clone the fleet store for the second host"
    [ -f "$rjj/corvid/store/$fleet_trust_roster_file" ] ||
      fail "the clone checked out no roster"
    printf 'name: corvid\nstore_id: %s\n' "$rjj_store_id" \
      >"$rjj/corvid/identity.yaml"
    rjj_run corvid "$cli" fleet-init >/dev/null ||
      fail "fleet-init refused a clone whose genesis matches identity.yaml"
    [ -z "$(fleet_pins_drift "$rjj/corvid/store" || true)" ] ||
      fail "fleet-init did not pin a cloned store (the repo config is host-local)"
    printf 'name: corvid\nstore_id: %s\n' 0000000000000000 \
      >"$rjj/corvid/identity.yaml"
    rjj_foreign_status=0
    rjj_run corvid "$cli" fleet-init >/dev/null 2>&1 || rjj_foreign_status=$?
    [ "$rjj_foreign_status" -eq 65 ] ||
      fail "fleet-init accepted a store belonging to another fleet (got $rjj_foreign_status)"
    # And the reverse: a host that already knows the fleet's store id must not
    # be able to root a SECOND store claiming that identity.
    mkdir -p "$rjj/wren"
    printf 'name: wren\nstore_id: %s\n' "$rjj_store_id" >"$rjj/wren/identity.yaml"
    rjj_run wren "$cli" fleet-init >/dev/null 2>&1 || :
    rjj_reroot_status=0
    rjj_run wren "$cli" fleet-enroll >/dev/null 2>&1 || rjj_reroot_status=$?
    [ "$rjj_reroot_status" -eq 65 ] ||
      fail "a host named the fleet's store id and minted a second genesis anyway"

    # 9. A store with HISTORY but no roster behind it: refuse, never heal.
    #    Both verbs keyed their "already set up, just heal" path on the store id
    #    alone — and §7.5/§12 make the store id and the roster the same fact
    #    seen twice, so a store id with no `trust/signers.yaml` is a DIFFERENT
    #    store's remains. A leftover v0.5 store looked exactly like this, and
    #    healing it produced something that looked enrolled and verified
    #    nothing; every later verb then failed somewhere further downstream.
    rjj_legacy="$rjj/legacy/store"
    mkdir -p "$rjj/legacy"
    jj git clone --colocate --config ui.editor='"true"' \
      --config ui.paginate=never "$rjj/remote.git" "$rjj_legacy" >/dev/null 2>&1 ||
      fail "could not clone the fleet store for the legacy-remnant fixture"
    printf 'name: legacy\nstore_id: %s\n' "$rjj_store_id" \
      >"$rjj/legacy/identity.yaml"
    # Same lineage, same store id — only the roster is gone, which is the whole
    # point: the store id check passes and this one has to be what refuses.
    rm -f "$rjj_legacy/$fleet_trust_roster_file"
    jj -R "$rjj_legacy" describe -m 'drop the roster' >/dev/null
    jj -R "$rjj_legacy" bookmark set main \
      -r "$(jj -R "$rjj_legacy" log -r @ --no-graph -T 'commit_id')" >/dev/null
    jj -R "$rjj_legacy" new "$(jj -R "$rjj_legacy" log \
      -r 'heads(bookmarks(exact:"main"))' --no-graph -T 'commit_id')" >/dev/null
    # THE REFUSAL LEAVES NOTHING BEHIND. A preflight that fires after minting the
    # node key and pointing the repo's [signing] block at it hands back a store
    # this build just called unusable AND reconfigured — half-enrolled state is
    # worse than no refusal. So the key must not exist and the config must not
    # be rewritten when the verb refuses.
    # Pins are read as EFFECTIVE values through fleet_pins_drift, never as file
    # contents: jj 0.44 migrates a written `.jj/repo/config.toml` out to
    # $XDG_CONFIG_HOME/jj/repos/<hash>/, so a path-based check here would
    # compare two absent files and pass vacuously. A fresh clone carries no
    # pins, so drift is non-empty now and must STAY non-empty across a refusal
    # — the corvid case above is the positive control where a successful
    # fleet-init drives it to empty.
    rm -f "$rjj/legacy-key" "$rjj/legacy-key.pub"
    [ -n "$(fleet_pins_drift "$rjj_legacy" || true)" ] ||
      fail "the legacy fixture was already pinned; the no-write assertion below would be vacuous"
    for rjj_legacy_verb in fleet-init fleet-enroll; do
      rjj_legacy_status=0
      rjj_legacy_out=$(rjj_run legacy "$cli" "$rjj_legacy_verb" 2>&1) ||
        rjj_legacy_status=$?
      [ "$rjj_legacy_status" -eq 65 ] ||
        fail "$rjj_legacy_verb healed a store with history and no roster (got $rjj_legacy_status)"
      case $rjj_legacy_out in
        *'re-init'* | *'move it aside'*) ;;
        *) fail "$rjj_legacy_verb refused without naming the remedy: $rjj_legacy_out" ;;
      esac
      [ ! -f "$rjj/legacy-key" ] ||
        fail "$rjj_legacy_verb minted a node key before refusing the store"
      [ -n "$(fleet_pins_drift "$rjj_legacy" || true)" ] ||
        fail "$rjj_legacy_verb pinned the repository config before refusing the store"
    done
    # A preflight that CANNOT RUN must refuse, never authorize: "I could not
    # check" is not "the check passed", and reading it as one would let
    # fleet-init/fleet-enroll mutate exactly the history this exists to reject.
    rjj_legacy_status=0
    rjj_legacy_out=$(TMPDIR="$rjj/no-such-tmpdir" rjj_run legacy "$cli" fleet-init 2>&1) ||
      rjj_legacy_status=$?
    [ "$rjj_legacy_status" -eq 65 ] ||
      fail "fleet-init proceeded when the lineage preflight could not allocate a tempfile (got $rjj_legacy_status)"
    case $rjj_legacy_out in
      *'could not be checked'*) ;;
      *) fail "the unrunnable preflight did not say it could not check: $rjj_legacy_out" ;;
    esac

    # …and the ordinary clone, which has a roster, is unaffected. (corvid's
    # identity was rewritten by the foreign-store fixture above; restore it.)
    printf 'name: corvid\nstore_id: %s\n' "$rjj_store_id" \
      >"$rjj/corvid/identity.yaml"
    rjj_run corvid "$cli" fleet-init >/dev/null ||
      fail "the lineage check refused a healthy cloned store"

    printf 'real-jj: OK (brick order, config pins, op-ssh-sign containment, keygen enrollment, genesis-as-store-id, legacy-remnant refusal, materialization drift)\n'
  ) || fail "real-jj bootstrap block failed (see the FAIL: real-jj: line above)"
fi
