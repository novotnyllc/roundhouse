# roundhouse self-check — §6.3 liveness: the throttled heartbeat and the
# stale-host alert.
#
# No jj and no store repository: the heartbeat's publication decision and the
# stale-host scan are pure file logic over journal/ and store.run/. Where the
# poll floor consults them against a real store is tests/93-jj-run.sh.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'liveness: §6.3 heartbeat throttle and stale-host alert\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    live_root="$tmp/liveness"
    live_store="$live_root/store"
    mkdir -p "$live_store"
    ROUNDHOUSE_FLEET_STORE=$live_store
    HOME="$live_root/home"
    export ROUNDHOUSE_FLEET_STORE HOME
    mkdir -p "$HOME"

    live_at() {
      # live_at HOURS -> an ISO instant HOURS after a fixed origin, so every
      # assertion below is about arithmetic and never about the wall clock.
      jq -rn --argjson h "$1" '1790812800 + ($h * 3600 | floor) | todate'
    }
    live_alive_count() {
      find "$live_store/journal/vireo" -type f -name '*.yaml' 2>/dev/null |
        while IFS= read -r live_file; do
          yq -r '.[] | select(.outcome == "alive") | .at' "$live_file"
        done | grep -c . || true
    }

    # --- the throttle: published at most every heartbeat_publish_hours ---
    live_fold='{}'
    fleet_heartbeat_due "$(jq -rn --arg at "$(live_at 0)" '$at | fromdateiso8601')" ||
      fail "a host with no heartbeat state did not owe a heartbeat"
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 0)" "$live_fold" false false ||
      fail "the first heartbeat could not be published"
    [ "$(live_alive_count)" -eq 1 ] ||
      fail "the first pass published no heartbeat (a fresh host must be seen alive)"
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 1)" "$live_fold" false false
    [ "$(live_alive_count)" -eq 1 ] ||
      fail "a no-op pass inside the 6h window published a heartbeat (§6.3 throttle)"
    ! fleet_heartbeat_due "$(jq -rn --arg at "$(live_at 1)" '$at | fromdateiso8601')" ||
      fail "the poll floor would be told a heartbeat is owed one hour after one was published"
    # A pass that APPLIED something always publishes: the commit exists anyway,
    # and it restarts the window.
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 2)" "$live_fold" false true
    [ "$(live_alive_count)" -eq 2 ] ||
      fail "an applying pass did not publish its heartbeat"
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 7)" "$live_fold" false false
    [ "$(live_alive_count)" -eq 2 ] ||
      fail "the window did not restart at the applying pass's heartbeat"
    fleet_heartbeat_due "$(jq -rn --arg at "$(live_at 8)" '$at | fromdateiso8601')" ||
      fail "no heartbeat was owed six hours after the last published one"
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 8)" "$live_fold" false false
    [ "$(live_alive_count)" -eq 3 ] ||
      fail "a no-op pass past the 6h window did not publish a heartbeat"

    # --- a canary owes a record at applied_at + canary_wait_hours ---
    # §10.1 condition 3 needs a record dated at or after that instant; a
    # throttled canary would otherwise leave downstream waiting up to a window.
    live_canary_fold='{"policy":{"canary_wait_hours":3}}'
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 9)" "$live_canary_fold" true true
    [ "$(live_alive_count)" -eq 4 ] || fail "the canary's applying pass published no heartbeat"
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 11)" "$live_canary_fold" true false
    [ "$(live_alive_count)" -eq 4 ] ||
      fail "the canary published before its evidence deadline with nothing to say"
    fleet_heartbeat_due "$(jq -rn --arg at "$(live_at 12)" '$at | fromdateiso8601')" ||
      fail "the canary's evidence deadline did not make a heartbeat due (it would wait 6h)"
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 12)" "$live_canary_fold" true false
    [ "$(live_alive_count)" -eq 5 ] ||
      fail "the canary did not publish at its evidence deadline"
    [ "$(fleet_heartbeat_state | jq -r '.deadlines | length')" -eq 0 ] ||
      fail "a met canary deadline stayed owed"
    ! fleet_heartbeat_due "$(jq -rn --arg at "$(live_at 13)" '$at | fromdateiso8601')" ||
      fail "a heartbeat was still owed after the deadline was met"
    # A NON-canary owes nobody: applying records no deadline.
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 14)" "$live_canary_fold" false true
    [ "$(fleet_heartbeat_state | jq -r '.deadlines | length')" -eq 0 ] ||
      fail "a non-canary host recorded a canary evidence deadline"
    # A zero window turns the throttle off rather than dividing by it.
    live_off_fold='{"policy":{"heartbeat_publish_hours":0}}'
    live_before=$(live_alive_count)
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 14.5)" "$live_off_fold" false false
    fleet_heartbeat_publish "$live_store" vireo "$(live_at 14.6)" "$live_off_fold" false false
    [ "$(live_alive_count)" -eq $((live_before + 2)) ] ||
      fail "heartbeat_publish_hours: 0 did not publish on every pass"
    # Lost state is "owed now", never "silent forever".
    printf 'not json\n' >"$(fleet_instance_path store.run)/heartbeat.json"
    fleet_heartbeat_due "$(jq -rn --arg at "$(live_at 15)" '$at | fromdateiso8601')" ||
      fail "an unreadable heartbeat state did not read as due"

    # The host-local heartbeat is every pass, and it never enters the store.
    fleet_heartbeat_local "$(live_at 16)"
    [ "$(jq -r '.at' "$(fleet_instance_path store.run)/alive")" = "$(live_at 16)" ] ||
      fail "the host-local heartbeat was not written"
    case $(fleet_instance_path store.run) in
      "$live_store"/*) fail "the host-local heartbeat lives inside the replicated store" ;;
    esac

    # --- the stale-host alert: another host silent past liveness_alert_hours ---
    live_now=$(live_at 40)
    printf 'vireo\nwren\nrobin\nnewbie\n' >"$live_root/hosts"
    fleet_journal_append "$live_store" wren \
      "$(jq -cn --arg at "$(live_at 39)" '{outcome:"alive",at:$at}')"
    fleet_journal_append "$live_store" robin \
      "$(jq -cn --arg at "$(live_at 27)" '{outcome:"alive",at:$at}')"
    # A recent record that is NOT a heartbeat does not make robin live: held
    # journals are what a wedged loop writes on its way down.
    fleet_journal_append "$live_store" robin \
      "$(jq -cn --arg at "$(live_at 27.5)" '{item:"plugins.x",digest:"d",outcome:"held",at:$at}')"
    live_out=$(fleet_liveness_alerts "$live_store" vireo "$live_root/hosts" \
      /dev/null "$live_fold" "$live_now")
    [ "$live_out" = 'stale robin' ] ||
      fail "the stale-host scan did not name exactly the silent host: $live_out"
    live_alert=$(find "$live_store/alerts/vireo" -name '*-stale-host-robin.yaml' | head -1)
    [ -n "$live_alert" ] || fail "no stale-host alert was written for a silent host"
    [ "$(yq -r '.kind' "$live_alert")" = stale-host ] ||
      fail "the stale-host alert has the wrong kind"
    # One alert per silence, not one per pass.
    rm -f "$live_alert"
    fleet_liveness_alerts "$live_store" vireo "$live_root/hosts" /dev/null \
      "$live_fold" "$live_now" >/dev/null
    [ -z "$(find "$live_store/alerts/vireo" -name '*-stale-host-robin.yaml')" ] ||
      fail "a host already alerted on was alerted again on the next pass"
    # A host that never journaled is not a host that went silent.
    [ ! -d "$live_store/alerts/vireo" ] ||
      [ -z "$(find "$live_store/alerts/vireo" -name '*newbie*')" ] ||
      fail "an enrolled host that has never run was alerted as stale"
    # robin comes back, then goes silent again: alerted afresh.
    fleet_journal_append "$live_store" robin \
      "$(jq -cn --arg at "$(live_at 39.5)" '{outcome:"alive",at:$at}')"
    [ -z "$(fleet_liveness_alerts "$live_store" vireo "$live_root/hosts" /dev/null \
      "$live_fold" "$live_now")" ] || fail "a host that published a fresh heartbeat still read as stale"
    fleet_liveness_alerts "$live_store" vireo "$live_root/hosts" /dev/null \
      "$live_fold" "$(live_at 52)" >/dev/null
    [ -n "$(find "$live_store/alerts/vireo" -name '*-stale-host-robin.yaml')" ] ||
      fail "a host that went silent again after recovering was not alerted afresh"
    # A heartbeat on an EARLIER day file still counts inside the window: the
    # scan stops only at a day wholly before the cutoff.
    rm -rf "$live_store/journal/wren"
    fleet_journal_append "$live_store" wren \
      "$(jq -cn --arg at "$(live_at 47)" '{outcome:"alive",at:$at}')"
    fleet_journal_append "$live_store" wren \
      "$(jq -cn --arg at "$(live_at 51)" '{item:"plugins.x",digest:"d",outcome:"held",at:$at}')"
    case $(fleet_liveness_alerts "$live_store" vireo "$live_root/hosts" /dev/null \
      "$live_fold" "$(live_at 52)") in
      *wren*) fail "a heartbeat in the previous day's file was missed by the bounded scan" ;;
    esac
    # Only current roster members are checked, when the roster is readable.
    printf 'vireo@fleet.example.invalid namespaces="git" ssh-ed25519 AAAA\n' \
      >"$live_root/roster"
    [ -z "$(fleet_liveness_alerts "$live_store" vireo "$live_root/hosts" \
      "$live_root/roster" "$live_fold" "$(live_at 70)")" ] ||
      fail "a host that left the roster was still checked for liveness"
    # …and the knob turns it off.
    [ -z "$(fleet_liveness_alerts "$live_store" vireo "$live_root/hosts" /dev/null \
      '{"policy":{"liveness_alert_hours":0}}' "$(live_at 70)")" ] ||
      fail "liveness_alert_hours: 0 did not disable the stale-host alert"
    # The policy defaults carry both keys, so a store with no policy block runs
    # the documented 6h/12h.
    [ "$(fleet_policy_int '{}' heartbeat_publish_hours)" = 6 ] ||
      fail "heartbeat_publish_hours does not default to 6"
    [ "$(fleet_policy_int '{}' liveness_alert_hours)" = 12 ] ||
      fail "liveness_alert_hours does not default to 12"
  )
fi
