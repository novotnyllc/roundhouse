# roundhouse — liveness: the throttled heartbeat and the stale-host alert.
#
# §6.3 of the agent-settings loop design. The `alive` journal record exists for
# §10.1 condition 3 (a canary that goes silent after applying must block
# promotion), and it used to be published on EVERY completed pass. Every one of
# those is a commit on the shared `main`, so a fleet of quiet hosts manufactured
# a record commit per host per pass — the churn that defeated every peer's poll
# floor and filled the store with nothing.
#
# The split this unit enforces:
#
#   host-local   store.run/alive, rewritten on every pass, including a pass
#                that exits at the poll floor. It is the "this loop is running"
#                fact for this machine, and it never leaves it.
#   published    journal/<h>/<date>.yaml `outcome: alive`, at most every
#                `heartbeat_publish_hours` (default 6) — and ALWAYS after a pass
#                that applied or satisfied something, and at every canary
#                evidence deadline, so §10.1's gate is never left waiting on a
#                throttled record (see fleet_heartbeat_publish).
#
# The stale-host alert is the other half: every pass checks the PUBLISHED
# heartbeats of every other enrolled host, and a host with none inside
# `liveness_alert_hours` (default 12, two publication windows) is alerted on.
# It reads only the store's own journal, so it works whether or not any other
# tool (fleet-chezmoi included) is installed.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_heartbeat_dir() {
  fleet_instance_path store.run
}

fleet_heartbeat_local() {
  # fleet_heartbeat_local AT — the host-local heartbeat, every pass. Same
  # record shape as the journal's, so a reader needs one vocabulary; never
  # published, because nothing on another host needs a per-pass fact.
  heartbeat_dir=$(fleet_heartbeat_dir)
  mkdir -p "$heartbeat_dir"
  jq -cn --arg at "$1" '{outcome:"alive",at:$at}' >"$heartbeat_dir/alive.next" &&
    mv -f "$heartbeat_dir/alive.next" "$heartbeat_dir/alive"
}

fleet_heartbeat_state() {
  # The publication state as one JSON object: `published_at` and `due` are
  # epochs, `deadlines` the canary evidence instants still owed. An absent or
  # unreadable file reads as `{}`, which is "due now" — the safe direction: a
  # host that lost its state publishes once more rather than going silent.
  heartbeat_state=$(jq -c 'objects' "$(fleet_heartbeat_dir)/heartbeat.json" \
    2>/dev/null) || heartbeat_state=
  [ -n "$heartbeat_state" ] || heartbeat_state='{}'
  printf '%s\n' "$heartbeat_state"
}

fleet_heartbeat_due() {
  # fleet_heartbeat_due [NOW-EPOCH] — true when the next pass must publish a
  # heartbeat. The poll floor asks this BEFORE it may exit: a floor that
  # skipped the pass that publishes the heartbeat would make every quiet host
  # read as dead to its peers.
  heartbeat_now=${1:-$(date +%s)}
  fleet_heartbeat_state | jq -e --argjson now "$heartbeat_now" \
    '((.due // 0) | numbers) <= $now' >/dev/null 2>&1
}

fleet_heartbeat_publish() {
  # fleet_heartbeat_publish STORE HOST AT FOLD SELF-CANARY APPLIED-ANY
  #
  # Publishes `outcome: alive` into journal/<h>/ when ANY of:
  #
  #   1. this pass applied or satisfied an item (APPLIED-ANY=true). Free: the
  #      pass already carries evidence records, so the commit exists anyway.
  #   2. the throttle window elapsed: `heartbeat_publish_hours` since the last
  #      published heartbeat. Zero or less turns the throttle off.
  #   3. a canary evidence deadline arrived. §10.1 condition 3 accepts any
  #      record dated at or after `applied_at + canary_wait_hours`; a canary
  #      that applied at T and then throttled its heartbeat would leave every
  #      downstream host waiting up to a whole window past T + wait. So a
  #      canary host that applies records the instant it owes a record, and the
  #      first pass at or after it publishes. Non-canary hosts owe nobody.
  #
  # Exit status is the journal append's; the caller never fails the run on it.
  heartbeat_state=$(fleet_heartbeat_state)
  heartbeat_now=$(jq -rn --arg at "$3" '$at | fromdateiso8601') || return 1
  heartbeat_every=$(($(fleet_policy_int "$4" heartbeat_publish_hours) * 3600))
  heartbeat_wait=$(fleet_policy_get "$4" canary_wait_hours 2>/dev/null || printf 0)
  # Due against THIS pass's policy, not the `due` the previous pass stored:
  # a window the store just shortened (or zeroed) applies immediately.
  heartbeat_publish=$(jq -rn --argjson s "$heartbeat_state" \
    --argjson now "$heartbeat_now" --argjson every "$heartbeat_every" \
    --arg applied "$6" '
      if $applied == "true" then "yes"
      elif ((($s.published_at // 0) | numbers) + ([$every, 0] | max)) <= $now
        then "yes"
      elif any(($s.deadlines // [])[] | numbers; . <= $now) then "yes"
      else "no" end') || heartbeat_publish=yes
  heartbeat_published=$(printf '%s\n' "$heartbeat_state" |
    jq -r '(.published_at // 0) | numbers')
  if [ "$heartbeat_publish" = yes ]; then
    fleet_journal_append "$1" "$2" \
      "$(jq -cn --arg at "$3" '{outcome:"alive",at:$at}')" || return 1
    heartbeat_published=$heartbeat_now
  fi
  heartbeat_dir=$(fleet_heartbeat_dir)
  mkdir -p "$heartbeat_dir"
  jq -cn --argjson s "$heartbeat_state" --argjson now "$heartbeat_now" \
    --argjson pub "${heartbeat_published:-0}" --argjson every "$heartbeat_every" \
    --arg wait "$heartbeat_wait" --arg canary "$5" --arg applied "$6" '
      ((($s.deadlines // []) | map(numbers))) as $owed |
      (if $canary == "true" and $applied == "true"
        then (($wait | tonumber? // 0) * 3600 | floor) else 0 end) as $soak |
      ($owed + (if $soak > 0 then [$now + $soak] else [] end)
        | map(select(. > $pub)) | unique) as $owed |
      {published_at: $pub, deadlines: $owed,
       due: ([$pub + ([$every, 0] | max)] + $owed | min)}' \
    >"$heartbeat_dir/heartbeat.json.next" &&
    mv -f "$heartbeat_dir/heartbeat.json.next" "$heartbeat_dir/heartbeat.json"
}

fleet_liveness_last_alive() {
  # fleet_liveness_last_alive STORE HOST CUTOFF-ISO -> the newest published
  # `alive` at or after CUTOFF, exit 0. Exit 1 when the host has journaled but
  # published no heartbeat since CUTOFF; exit 2 when it has never journaled at
  # all (enrolled, never run — not yet a host that can go silent).
  #
  # Bounded on purpose: day files are named by their records' own date, so only
  # the files dated on or after CUTOFF's day can hold a qualifying record, and
  # the scan stops at the first older one instead of parsing a host's whole
  # history on every pass.
  liveness_dir="$1/journal/$2"
  liveness_any=false
  liveness_cutoff_day=${3%%T*}
  while IFS= read -r liveness_file; do
    [ -n "$liveness_file" ] || continue
    liveness_any=true
    liveness_day=$(basename "$liveness_file" .yaml)
    [ "$(printf '%s\n%s\n' "$liveness_day" "$liveness_cutoff_day" |
      LC_ALL=C sort | head -1)" = "$liveness_cutoff_day" ] || break
    liveness_at=$(yq -r '[(. // [])[] | select(.outcome == "alive") | .at] |
      sort | .[-1] // ""' "$liveness_file" 2>/dev/null) || continue
    [ -n "$liveness_at" ] && [ "$liveness_at" != null ] || continue
    # ISO-8601 Z sorts chronologically, so the window test is a string compare.
    [ "$(printf '%s\n%s\n' "$liveness_at" "$3" | LC_ALL=C sort | head -1)" = "$3" ] ||
      continue
    printf '%s\n' "$liveness_at"
    return 0
  done <<EOF
$(find "$liveness_dir" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | LC_ALL=C sort -r)
EOF
  [ "$liveness_any" = true ] || return 2
  return 1
}

fleet_liveness_alerts() {
  # fleet_liveness_alerts STORE HOST HOSTS-FILE ROSTER-FILE FOLD NOW-ISO
  #
  # Every OTHER enrolled host — and, when the reviewed roster is readable, only
  # those still in it, so a retired or expired member is not a silent one — is
  # checked for a published heartbeat inside `liveness_alert_hours`. A host
  # that has never journaled is skipped: enrolled-but-never-run is what
  # fleet-doctor's enrollment rows are for, and alerting on it would fire for
  # every host between `fleet-add` and its first pass.
  #
  # One alert per host per silence: store.run/liveness-alerted remembers who
  # was already alerted, so a dead peer is one record and not one per pass; a
  # host that comes back drops out of the memo and alerts afresh if it goes
  # silent again. Prints `stale <host>` per silent host for the caller.
  liveness_hours=$(fleet_policy_int "$5" liveness_alert_hours)
  [ "$liveness_hours" -gt 0 ] 2>/dev/null || return 0
  liveness_now=$(jq -rn --arg at "$6" '$at | fromdateiso8601') || return 1
  liveness_cutoff=$(jq -rn --argjson e "$((liveness_now - liveness_hours * 3600))" \
    '$e | todate') || return 1
  liveness_memo=$(fleet_heartbeat_dir)/liveness-alerted
  mkdir -p "$(dirname "$liveness_memo")"
  : >"$liveness_memo.next"
  while IFS= read -r liveness_peer; do
    [ -n "$liveness_peer" ] && [ "$liveness_peer" != "$2" ] || continue
    if [ -s "${4:-}" ]; then
      awk -v p="$liveness_peer@" 'index($1, p) == 1 { found = 1 }
        END { exit(found ? 0 : 1) }' "$4" || continue
    fi
    liveness_status=0
    fleet_liveness_last_alive "$1" "$liveness_peer" "$liveness_cutoff" \
      >/dev/null || liveness_status=$?
    [ "$liveness_status" -eq 1 ] || continue
    printf 'stale %s\n' "$liveness_peer"
    if grep -Fqx "$liveness_peer" "$liveness_memo" 2>/dev/null; then
      printf '%s\n' "$liveness_peer" >>"$liveness_memo.next"
      continue
    fi
    fleet_alert_write "$1" "$2" stale-host \
      "stale-host-$(printf '%s' "$liveness_peer" | tr -c 'A-Za-z0-9._-' '-')" \
      "$liveness_peer has published no heartbeat in the last ${liveness_hours}h (since $liveness_cutoff); check its scheduled job (roundhouse fleet-schedule status) and its route to the store remote" &&
      printf '%s\n' "$liveness_peer" >>"$liveness_memo.next"
  done <"$3"
  mv -f "$liveness_memo.next" "$liveness_memo"
}
