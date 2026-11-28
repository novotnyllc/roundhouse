# roundhouse — Claude observation and local holds; desired state is never written here.
# shellcheck shell=bash

fleet_capture_claude_update() {
  local id=$1
  shift
  fleet_capture_verb "claude:$id" update unchanged -- "$@"
}

fleet_capture_item_state() {
  local id=${1#claude:} raw
  fleet_capture_id_valid "claude:$id" || return 1
  raw=$(fleet_capture_guard_live "$id") || return 1
  jq -cen --arg id "$id" --argjson raw "$raw" '
    if $raw.query_ok == false or $raw.uncertain == true or $raw.installed == null or
      $raw.settings == null or any($raw.settings[]; type != "boolean") or
      ($raw.installed != [] and $raw.installed != [$id]) or
      ($raw.installed == [] and ($raw.manager_state | IN("true","false"))) or
      (($raw.settings[$id] | type) == "boolean" and ($raw.manager_state | IN("true","false")) and
        ($raw.settings[$id] | tostring) != $raw.manager_state)
    then error("inconsistent Claude item observation")
    else {installed:($raw.installed == [$id]),
      state:(if $raw.installed == [] then null elif $raw.manager_state == "true" then "enabled"
        elif $raw.manager_state == "false" then "disabled"
        elif ($raw.settings[$id] | type) == "boolean" then
          if $raw.settings[$id] then "enabled" else "disabled" end
        else null end),sources:$raw} end |
    if .state != null then .sources.state = (.state == "enabled" | tostring) else . end'
}

fleet_capture_verb() {
  # ID OP TO -- argv: intent is durable before the native call, receipt only after proof.
  local id=$1 op=$2 to=$3 path journal home live after seq op_id record rc=0 failure=74 read_failure=74
  local fleet_capture_active_op= fleet_mutator_lock= expected chain carry=false
  shift 3
  [ "${1:-}" = -- ] || return 64
  shift
  [ "$#" -gt 0 ] || return 64
  case $op in install|uninstall|enable|disable|update|seal|refresh) ;; *) return 64 ;; esac
  [ "$op" != uninstall ] || failure=75
  read_failure=$failure
  case $op in enable|disable) read_failure=75 ;; esac
  local observed=${fleet_capture_observed:-${fleet_capture_before_observed:-${fleet_capture_chain_observed:-}}} collect_dir baseline discard
  local name=${id#claude:} discarded=false state base
  if [ -z "$observed" ]; then
    collect_dir=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-capture-verb.XXXXXX") || return 74
    observed=$(fleet_capture_collect "$collect_dir") || observed='{"trusted":false}'
    rm -rf "$collect_dir"
    if ! jq -e '.trusted == true' >/dev/null <<<"$observed"; then
      printf 'roundhouse: Claude plugin inventory not trusted; making no Claude plugin changes this pass\n'
    fi
  fi
  jq -e '.trusted == true' >/dev/null <<<"$observed" || return 74
  [ -z "${fleet_capture_chain:-}" ] || fleet_capture_chain_observed=$observed
  fleet_capture_id_valid "$id" || return "$failure"
  path=$(fleet_agent_journal_path "$id") || return "$failure"
  fleet_capture_migrate_pending || return "$failure"
  journal=$(fleet_agent_journal_read "$id") || return "$failure"
  home=$(fleet_capture_home) || return "$failure"
  baseline=$(fleet_capture_json_read "$(fleet_run_state_dir)/agent-baseline.json" '{}') || return 74
  base=$(jq -c --arg id "$id" '.[$id]' <<<"$baseline") || return 74
  discard=$(fleet_capture_json_read "$(fleet_run_state_dir)/agent-discard.json" '{}') || return 74
  state=$(jq -r --arg id "$name" '.claude[$id].value // "absent"' <<<"$observed") || return 74
  if fleet_capture_discard_matches "$discard" "$id" "$state" "$journal" "$base"; then discarded=true; fi
  if [ "$id" != claude:roundhouse@novotnyllc ] && [ "$discarded" != true ]; then
    fleet_capture_quarantined "${name%@*}" && return "$failure"
    if [ -z "${fleet_capture_before_records:-}" ] &&
      jq -e '.raced == true' >/dev/null <<<"$base"; then
      printf '  hold  %s — held; run fleet-discard\n' "$id" >&2
      return 74
    fi
  fi
  if [ "$discarded" != true ] && fleet_agent_journal_unresolved "$journal"; then
    if [ "$id" != claude:roundhouse@novotnyllc ]; then
      printf '  hold  %s — interrupted Claude operation; run fleet-discard or agree in the store\n' "$id" >&2
      return "$failure"
    fi
    journal=$(jq -c --arg home "$home" 'if .home != $home then {id:.id,home:$home}
      else del(.intent) end' <<<"$journal") || return "$failure"
  fi
  chain=${fleet_capture_chain:-}
  expected=$(jq -r --arg chain "$chain" '
    if $chain != "" and .receipt.chain == $chain then .receipt.observed.sources // empty
    else empty end' <<<"$journal") || return "$failure"
  [ -z "$expected" ] || carry=true
  if [ -z "$expected" ] && [ -z "${fleet_capture_before_records:-}" ]; then
    baseline=$(fleet_capture_effective_base "$baseline") || return "$failure"
    # Without an effective base, only a missing plugin can be installed safely.
    expected=$(jq -cn --arg id "$id" --arg name "$name" --argjson baseline "$baseline" '
      ($baseline[$id].value // "absent") as $state |
      {installed:(if $state == "absent" then [] else [$name] end),settings:null,
        state:(if $state == "enabled" then "true" elif $state == "disabled" then "false"
          else "unknown" end)}') || return "$failure"
  fi
  live=$(fleet_capture_item_state "$id") || return 74
  if [ "$id" != claude:roundhouse@novotnyllc ] && [ "$discarded" != true ]; then
    if [ "$carry" != true ] && [ -z "${fleet_capture_before_records:-}" ] &&
      jq -e '.installed != [] and .state == "unknown"' >/dev/null <<<"$expected"; then
      printf '  hold  %s — held; run fleet-discard\n' "$id" >&2
      return 74
    fi
    fleet_capture_guard_destructive "$name" "$expected" unknown "$(jq -c .sources <<<"$live")" || {
      if [ -z "${fleet_capture_before_records:-}" ]; then
        printf '  hold  %s — held; run fleet-discard\n' "$id" >&2
      fi
      return 74
    }
  fi
  if [ "$discarded" = true ]; then
    state=$(jq -r 'if .installed then .state // "unknown" else "absent" end' <<<"$live") || return 74
    fleet_capture_discard_matches "$discard" "$id" "$state" "$journal" "$base" || return 74
  fi
  [ -z "${fleet_lock_nonce_held:-}" ] || fleet_mutator_lock=$(fleet_lock_path)
  # These verbs change bytes only; they cannot claim enabled-state provenance.
  case $op in update|seal|refresh)
    fleet_run_cli_invalidate
    "$@" || rc=$?
    [ -z "$fleet_mutator_lock" ] || fleet_lock_mutator "$fleet_mutator_lock" "$fleet_lock_nonce_held" || return "$failure"
    return "$rc" ;;
  esac
  seq=$(fleet_capture_next_seq) || return "$failure"
  op_id=$(fleet_lock_nonce) || return "$failure"
  [ -n "$op_id" ] || return "$failure"
  record=$(jq -c --arg op "$op" --arg to "$to" --arg op_id "$op_id" --arg home "$home" \
    --argjson from "$live" --argjson pid "$$" --arg start "$(fleet_lock_proc_start "$$")" \
    --argjson seq "$seq" 'if .home != $home then {id:.id,home:$home} else . end |
      .intent = {op:$op,to:$to,from:$from,op_id:$op_id,pid:$pid,start:$start,seq:$seq}' \
    <<<"$journal") || return "$failure"
  fleet_capture_json_write "$path" "$record" || return "$failure"
  fleet_capture_active_op=$op_id
  fleet_run_cli_invalidate
  "$@" || rc=$?
  [ -z "$fleet_mutator_lock" ] || fleet_lock_mutator "$fleet_mutator_lock" "$fleet_lock_nonce_held" || return "$failure"
  fleet_mutator_lock=
  fleet_capture_active_op=
  fleet_run_cli_invalidate
  after=$(fleet_capture_item_state "$id") || return "$read_failure"
  if [ "$rc" -eq 0 ] && jq -e --arg op "$op" '
    if $op == "install" then .installed == true
    elif $op == "uninstall" then .installed == false
    elif $op == "enable" then .installed == true and .state == "enabled"
    else .installed == true and .state == "disabled" end' >/dev/null <<<"$after"; then
    record=$(jq -c --argjson after "$after" --arg op "$op" --arg chain "$chain" --argjson seq "$seq" '
      .receipt = {installed:$after.installed,
        state:(if $op == "install" and $after.state != "enabled" then null else $after.state end),
        observed:$after,chain:$chain,seq:$seq,op:$op} | del(.intent)' \
      <<<"$record") || return "$failure"
    if [ "$discarded" = true ] && jq -e '.raced == true' >/dev/null <<<"$base"; then
      # The intent still fences a crash while the authorized old race is retired.
      baseline=$(jq -c --arg id "$id" 'del(.[$id].raced, .[$id].raced_removal)' <<<"$baseline") || return "$failure"
      fleet_capture_json_write "$(fleet_run_state_dir)/agent-baseline.json" "$baseline" || return "$failure"
    fi
    if [ "$discarded" = true ]; then
      local quarantine identities records
      quarantine=$(fleet_capture_quarantine_path "${name%@*}") || return "$failure"
      if [ -e "$quarantine" ]; then
        identities=$(fleet_capture_pending_ids | jq -Rn '[inputs]') || return "$failure"
        records=$(fleet_capture_guard_records) || return "$failure"
        identities=$(jq -cn --argjson ids "$identities" --argjson records "$records" --argjson base "$baseline" '
          ($ids + ($base | keys) + ($records.registry | keys | map("claude:" + .))) |
          unique | map({id:.})') || return "$failure"
        if fleet_capture_name_unique "${name%@*}" "$identities"; then
          rm -f "$quarantine" || return "$failure"
        fi
      fi
    fi
    fleet_capture_json_write "$path" "$record" || return "$failure"
    return 0
  fi
  if [ "$after" = "$live" ]; then
    # No effect restores the evidence from before this attempt.
    if jq -e '.receipt != null or .intent != null' >/dev/null <<<"$journal"; then
      fleet_capture_json_write "$path" "$journal" || return "$failure"
    else
      rm -f "$path" || return "$failure"
    fi
  fi
  case $op in
    enable|disable) jq -e '.state != null' >/dev/null <<<"$after" || return "$read_failure" ;;
  esac
  return "$failure"
}

fleet_capture_alert_detail() {
  local id=$1 detail="$1 $2"
  if [ "${#detail}" -gt "$fleet_replicated_cap" ]; then
    detail="claude:sha256:$(printf '%s' "$id" | sha256_stream | sed 's/.\{16\}/&-/g;s/-$//') $2"
  fi
  printf '%s\n' "$detail"
}

fleet_capture_skip_id() {
  # Resolve the qualified ID against the pass's observation-to-item index.
  printf '%s\n' "${fleet_capture_skip:-'{}'}" | jq -e \
    --arg id "$2" --arg name "${2%@*}" --arg physical "$1:$2" '
      [.["plugins." + $name], .["plugins." + $id]] |
      any(. == true or . == $physical)' >/dev/null
}

fleet_capture_state_matches() {
  local item=$1 value=$2 observed=$3 defs=$4 market name
  name=${item#plugins.}
  case $name in
    *@*) ;;
    *)
      market=$(fleet_run_plugin_market "$defs" "$name" "$value") || return 1
      if [ -n "$market" ]; then
        name=$name@$market
      else
        name=$(printf '%s\n' "$observed" | jq -er --arg name "$name" \
          '.claude as $local | [$local // {} | keys[] | select(split("@")[0] == $name)] |
          . as $ids | [.[] | select($local[.].user_scope != false)] |
          if length == 0 then $ids else . end |
          if length == 1 then .[0] else empty end') || return 1
      fi
      ;;
  esac
  printf '%s\n' "$observed" | jq -e --arg id "$name" \
    --arg state "$(fleet_run_state_of "$value")" '
      .trusted == true and ((.claude[$id].value // "absent") == $state)' >/dev/null
}

fleet_capture_fingerprint() {
  # Record hashes only wake a pass; versions never enter the merge.
  for capture_fp in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
    if [ -f "$capture_fp" ] && [ -r "$capture_fp" ]; then
      sha256_file "$capture_fp" || return 1
    else
      printf 'missing\n'
    fi
  done | sha256_stream
}

fleet_capture_dirty() {
  local dir fingerprint marker baseline journal id
  dir=$(fleet_run_state_dir)
  if [ ! -f "$dir/agent-baseline.json" ]; then
    command -v claude >/dev/null 2>&1 && return 0
    [ ! -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" ] || return 0
  fi
  for marker in "$dir"/agent-pending/* "$dir"/agent-quarantine/*; do
    [ ! -e "$marker" ] || return 0
  done
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 0
  for marker in "$dir"/agent-journal/*; do
    [ -e "$marker" ] || continue
    journal=$(fleet_capture_json_read "$marker" '{}') || return 0
    fleet_agent_journal_unresolved "$journal" && return 0
    id=$(jq -er '.id' <<<"$journal") || return 0
    jq -e --arg id "$id" --argjson baseline "$baseline" '
      .receipt != null and .receipt.seq > ($baseline[$id].seq // 0)' \
      >/dev/null <<<"$journal" && return 0
  done
  fingerprint=$(fleet_capture_fingerprint) || return 0
  [ "$fingerprint" != "$(cat "$dir/agent-fingerprint" 2>/dev/null)" ]
}

fleet_capture_prepare() {
  # STORE HOST DESIRED OBSERVED CLEAN FETCHED TMP LAYERS
  # Local differences and conflicts are held, never written into the store.
  local store=$1 host=$2 desired=$3 observed=$4 layers=${8:-$1}
  local dir baseline initialized discard rows fields id item theirs ours base first ambiguous unqualified
  local journal merged direction kind message detail row_base
  local skip=() discards=() first_holds=()
  fleet_capture_skip='{}'
  fleet_capture_discards='[]'
  fleet_capture_retry_unknown=$(jq -r '.inapplicable != true and .trusted != true' <<<"$observed") || return 1
  dir=$(fleet_run_state_dir)
  fleet_capture_migrate_pending || return 1
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  discard=$(fleet_capture_json_read "$dir/agent-discard.json" '{}') || return 1
  fleet_capture_authoritative=$(jq -r '.trusted == true' <<<"$observed") || return 1
  if [ "$fleet_capture_retry_unknown" = true ]; then
    printf 'roundhouse: Claude plugin inventory not trusted; making no Claude plugin changes this pass\n'
  fi
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  fleet_capture_race_holds=$(jq -c --argjson discard "$discard" "$fleet_capture_discard_filter"'
    [.[] | select(.id != null and .id != "claude:roundhouse@novotnyllc" and (.base | objects | .raced == true)) |
      select(discarded($discard; .id; .ours; {}; .base) | not) | .id] | unique' <<<"$rows") || return 1
  fields=$(jq -r --argjson initialized "$initialized" '
    def state: IN("enabled","disabled","absent");
    .[] | (if .base == null then "missing"
      elif (.base | type) != "object" or (.base.value | state | not) then "malformed"
      elif .base.ignored then "ignored:" + .base.value else .base.value end) as $base |
    [.id // "-", .item,
      (if .theirs | IN("enabled","disabled","absent","missing") then .theirs else "malformed" end),
      (if .ours | IN("enabled","disabled","absent","unresolved","unobserved") then .ours else "unknown" end),
      $base, (.base == null and $initialized[.harness] != true), (.ambiguous == true), (.unqualified == true)] | @tsv' <<<"$rows") ||
    return 1
  while IFS=$'\t' read -r id item theirs ours base first ambiguous unqualified; do
    [ -n "$item" ] || continue
    if [ "$theirs" = malformed ] || { [ "$base" = malformed ] && [ "$id" != claude:roundhouse@novotnyllc ]; }; then
      skip+=("$item"$'\t'"$id")
      printf 'roundhouse: holding %s: malformed plugin state.\n' "$item"
      continue
    fi
    # The self plugin follows the fleet even when its individual state is uncertain.
    [ "$id" != claude:roundhouse@novotnyllc ] || continue
    local quarantine_name=${item#plugins.}
    quarantine_name=${quarantine_name%@*}
    if fleet_capture_id_valid "$id"; then
      journal=$(fleet_agent_journal_read "$id") || journal='{"intent":{"op_id":"unreadable"}}'
      row_base=$(jq -c --arg id "$id" --arg item "$item" '.[] | select(.id == $id and .item == $item) | .base' <<<"$rows") || return 1
      if [ "$fleet_capture_authoritative" = true ] &&
        fleet_capture_discard_matches "$discard" "$id" "$ours" "$journal" "$row_base" &&
        { ! fleet_capture_quarantined "$quarantine_name" ||
          fleet_capture_name_unique "$quarantine_name" "$rows"; }; then
        discards+=("$id")
        for kind in agent-local-change agent-capture-conflict agent-capture-interrupted; do
          fleet_alert_checked "$7/alert-ledger" "$kind" "$item"
        done
        continue
      fi
      if [ "$fleet_capture_authoritative" = true ] &&
        { [ "$ours" = enabled ] || [ "$ours" = disabled ] || [ "$ours" = absent ]; } &&
        jq -e --arg id "$id" 'has($id)' >/dev/null <<<"$discard"; then
        discard=$(jq -c --arg id "$id" 'del(.[$id])' <<<"$discard") || return 1
        fleet_capture_json_write "$dir/agent-discard.json" "$discard" || return 1
      fi
    fi
    if [ "$id" != claude:roundhouse@novotnyllc ] && fleet_capture_quarantined "$quarantine_name"; then
      if [ "$fleet_capture_authoritative" = true ] && [ "$ours" = "$theirs" ] &&
        fleet_capture_name_unique "$quarantine_name" "$rows" &&
        { [ "$ours" = enabled ] || [ "$ours" = disabled ] || [ "$ours" = absent ]; }; then
        skip+=("$item"$'\t'"$id")
        fleet_alert_checked "$7/alert-ledger" agent-capture-interrupted "$item"
        continue
      else
        skip+=("$item"$'\t'"$id")
        detail=$(fleet_capture_alert_detail "${id/#-/claude:$quarantine_name}" 'has an unresolved legacy operation; holding this item.') || return 1
        printf 'roundhouse: %s\n' "$detail"
        fleet_alert_raise "$7/alert-ledger" "$store" "$host" agent-capture-interrupted \
          agent-capture-interrupted "$detail" "$item" || return 1
        continue
      fi
    fi
    if fleet_capture_id_valid "$id" && [ "$id" != claude:roundhouse@novotnyllc ]; then
      if fleet_agent_journal_unresolved "$journal"; then
        if [ "$fleet_capture_authoritative" = true ] && [ "$ours" = "$theirs" ] &&
          { [ "$ours" = enabled ] || [ "$ours" = disabled ] || [ "$ours" = absent ]; }; then
          # Keep crash protection until rebaseline durably records this agreement.
          skip+=("$item"$'\t'"$id")
          fleet_alert_checked "$7/alert-ledger" agent-capture-interrupted "$item"
          continue
        else
          skip+=("$item"$'\t'"$id")
          direction=changed
          case $ours in absent) direction=removed ;; enabled|disabled)
            case $base in missing|absent|ignored:absent) direction=added ;; *) direction=$ours ;; esac ;;
          esac
          detail="$id $direction locally; interrupted Claude operation; holding this item."
          printf 'roundhouse: %s\n' "$detail"
          detail=$(fleet_capture_alert_detail "$id" "$direction locally; interrupted Claude operation; holding this item.") || return 1
          fleet_alert_raise "$7/alert-ledger" "$store" "$host" agent-capture-interrupted \
            agent-capture-interrupted "$detail" "$item" || return 1
          continue
        fi
      else
        fleet_alert_checked "$7/alert-ledger" agent-capture-interrupted "$item"
      fi
      if jq -e '.raced == true' >/dev/null <<<"$row_base" &&
        { [ "$fleet_capture_authoritative" != true ] || [ "$ours" != "$theirs" ]; }; then
        skip+=("$item"$'\t'"$id")
        detail="$id changed locally during a previous pass; holding this item."
        printf 'roundhouse: %s\n' "$detail"
        detail=$(fleet_capture_alert_detail "$id" 'changed locally during a previous pass; holding this item.') || return 1
        fleet_alert_raise "$7/alert-ledger" "$store" "$host" agent-local-change \
          agent-local-change "$detail" "$item" || return 1
        continue
      fi
    fi
    # Untrusted passes reach independent hook work; the Claude verb boundary defers writes.
    [ "$ours" != unobserved ] || continue
    if [ "$ours" = unknown ]; then
      skip+=("$item"$'\t'"$id")
      fleet_capture_retry_unknown=true
      if [ "$ambiguous" = true ]; then
        fleet_alert_raise "$7/alert-ledger" "$store" "$host" agent-capture-ambiguous \
          agent-capture-ambiguous "Multiple plugin identities resolve to $item. Holding this item." "$item" || return 1
      fi
      continue
    fi
    for kind in agent-local-change agent-capture-conflict agent-capture-ambiguous; do
      fleet_alert_checked "$7/alert-ledger" "$kind" "$item"
    done
    [ "$ours" != unresolved ] || continue
    fleet_capture_id_valid "$id" || continue
    # Roundhouse never holds itself: its own plugin always converges to the fleet.
    [ "$id" != claude:roundhouse@novotnyllc ] || continue
    # First observation adopts missing installs, but preserves an installed state disagreement.
    if [ "$first" = true ] && { [ "$ours" = absent ] || [ "$ours" = "$theirs" ] || [ "$theirs" = missing ]; }; then
      continue
    fi
    if [ "$first" = true ]; then
      merged=local
    else
      merged=$(fleet_merge3 "$base" "$ours" "$theirs") || return 1
    fi
    case $merged in local | conflict) ;; *) continue ;; esac
    case $ours in
      absent) direction=removed ;;
      *) case $base in missing)
           if [ "$first" = true ] && { [ "$theirs" = enabled ] || [ "$theirs" = disabled ]; }; then
             direction=$ours
           else direction=added; fi ;;
           absent | ignored:absent) direction=added ;;
           *) if [ "$ours" = disabled ]; then direction=disabled; else direction=enabled; fi ;;
         esac ;;
    esac
    skip+=("$item"$'\t'"$id")
    if [ "$first" = true ]; then first_holds+=("$id"$'\t'"$theirs"); fi
    kind=agent-local-change
    message="$id $direction locally; holding $item."
    if [ "$merged" = conflict ]; then
      kind=agent-capture-conflict
      message="$id $direction locally and changed in the fleet; holding $item."
    fi
    message="$message Edit the store to agree or run roundhouse fleet-discard $item to converge."
    printf 'roundhouse: %s\n' "$message"
    detail="$id $direction locally"
    [ "$merged" != conflict ] || detail="$detail and changed in the fleet"
    detail="$detail; holding this item."
    if [ "${#detail}" -gt "$fleet_replicated_cap" ]; then
      detail="claude:sha256:$(printf '%s' "$id" | sha256_stream | sed 's/.\{16\}/&-/g;s/-$//') $direction locally; holding this item. See fleet-run output."
    fi
    fleet_alert_raise "$7/alert-ledger" "$store" "$host" "$kind" "$kind" "$detail" "$item" || return 1
  done <<<"$fields"
  if [ "${#skip[@]}" -gt 0 ]; then
    fleet_capture_skip=$(printf '%s\n' "${skip[@]}" | jq -Rn '
      [inputs | split("\t") | {key:.[0],value:(if .[1] == "-" then true else .[1] end)}] | from_entries') ||
      return 1
  fi
  if [ "${#first_holds[@]}" -gt 0 ]; then
    # Persist the trusted first observation even if the post-scan cannot be trusted.
    baseline=$(printf '%s\n' "${first_holds[@]}" | jq -Rn --argjson base "$baseline" \
      --argjson initialized "$initialized" '
      [inputs | split("\t") | {key:.[0],value:{value:.[1]}}] | from_entries |
      . + $base | ._initialized = $initialized') || return 1
    fleet_capture_json_write "$dir/agent-baseline.json" "$baseline" || return 1
  fi
  if [ "${#discards[@]}" -gt 0 ]; then
    fleet_capture_discards=$(printf '%s\n' "${discards[@]}" | jq -Rn '[inputs] | unique') || return 1
  fi
}

fleet_capture_pass_prepare() {
  # STORE HOST DESIRED CLEAN FETCHED TMP LAYERS
  fleet_capture_before_records=$(fleet_capture_guard_records) || return 1
  fleet_capture_before_fingerprint=$(fleet_capture_fingerprint) || fleet_capture_before_fingerprint=
  fleet_capture_observed=$(fleet_capture_collect "$6/capture-before" "$3" "$7") ||
    fleet_capture_observed='{"claude":null,"trusted":false,"retry":true}'
  fleet_capture_before_observed=$fleet_capture_observed
  fleet_capture_prepare "$1" "$2" "$3" "$fleet_capture_observed" "$4" "$5" "$6" "$7" || return $?
  printf '%s\n' "$fleet_capture_skip" | jq -r 'keys[]' >"$6/capture-skip"
}

fleet_capture_pass_observe_after() {
  # STORE HOST TMP DESIRED LAYERS; replicated alerts use the ordinary publish.
  local baseline initialized rows extras dir
  dir=$(fleet_run_state_dir)
  fleet_run_cli_invalidate
  fleet_capture_after_fingerprint=$(fleet_capture_fingerprint) || fleet_capture_after_fingerprint=
  fleet_capture_after_observed=$(fleet_capture_collect "$3/capture-after" "$4" "$5") ||
    fleet_capture_after_observed='{"claude":null,"trusted":false,"retry":true}'
  if [ "$fleet_capture_retry_unknown" = true ] ||
    ! jq -e --argjson after "$fleet_capture_after_observed" '. == $after and (.trusted == true or .inapplicable == true)' \
      >/dev/null <<<"$fleet_capture_before_observed"; then
    : >"$dir/retry-owed" || return 1
    fleet_capture_after_fingerprint=$fleet_capture_before_fingerprint
  fi
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  rows=$(fleet_capture_rows "$5" "$4" "$fleet_capture_after_observed" "$baseline") || return 1
  extras=$(jq -c --argjson initialized "$initialized" '[.[] |
    select($initialized[.harness] != true and .base == null and .id != null and .theirs == "missing" and
      (.ours | IN("enabled","disabled"))) | .id]' <<<"$rows") || return 1
  if [ "$extras" != '[]' ]; then
    printf 'roundhouse: Existing local plugins left in place: %s.\n' "$(jq -r 'join(", ")' <<<"$extras")"
    fleet_alert_write "$1" "$2" agent-capture-ignored agent-capture-ignored \
      "Existing local plugins left in place: $(jq length <<<"$extras"). See fleet-run output for plugin IDs." || return 1
  fi
}

fleet_capture_pass_agree() {
  # Agreement advances only after the ordinary pass publish succeeds.
  local dir baseline discard verified published expected actual rows
  dir=$(fleet_run_state_dir)
  # Plain publication may recover a concurrent move; never agree against the old tree.
  published=$(fleet_vcs_heads_local "$1") || return 1
  if ! expected=$(fleet_vcs_desired_digest "$1" "$5") ||
    ! actual=$(fleet_vcs_desired_digest "$1" "$published") || [ "$expected" != "$actual" ]; then
    : >"$dir/retry-owed"
    return
  fi
  fleet_capture_rebaseline "$1" "$2" "$3" "$fleet_capture_after_observed" true "$4" || return 1
  if [ -e "$dir/agent-discard.json" ]; then
    baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
    discard=$(fleet_capture_json_read "$dir/agent-discard.json" '{}') || return 1
    rows=$(fleet_capture_rows "$4" "$3" "$fleet_capture_after_observed" "$baseline") || return 1
    verified=$(jq -c --argjson discard "$fleet_capture_discards" --argjson decisions "$discard" \
      --argjson observed "$fleet_capture_after_observed" --argjson baseline "$baseline" \
      "$fleet_capture_authority_filter"'
      . as $rows | [.[] |
        . as $row | select(.id != null and ($discard | index($row.id)) != null) |
        select($observed.trusted == true) |
        select((.ours == .theirs) or (.theirs == "missing" and
          ((.base.value == .ours and .base.ignored == true) or (.ours == "absent" and .base == null)))) |
        .id,.item] +
      [select(authoritative($observed)) | $decisions | keys[] |
        . as $key | select(all($rows[]; .id != $key and .item != $key))] | unique' <<<"$rows") || return 1
    discard=$(jq -c --argjson verified "$verified" 'delpaths($verified | map([.]))' <<<"$discard") || return 1
    if [ "$discard" = '{}' ]; then rm -f "$dir/agent-discard.json" || return 1
    else fleet_capture_json_write "$dir/agent-discard.json" "$discard" || return 1; fi
  fi
  printf '%s\n' "$fleet_capture_after_fingerprint" >"$dir/agent-fingerprint"
}

fleet_capture_guard_records() {
  # Keep independent evidence even when the manager inventory cannot be trusted.
  local registry settings registry_present=false settings_present=false
  registry=$(fleet_run_installed_plugins | jq -cse '
    if length == 1 then .[0] else null end') || registry=null
  settings=$(fleet_capture_json_read "$(fleet_run_settings_path)" '{}' 2>/dev/null) || settings=null
  [ ! -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" ] || registry_present=true
  [ ! -e "$(fleet_run_settings_path)" ] || settings_present=true
  jq -cn --argjson registry "$registry" --argjson settings "$settings" \
    --argjson registry_present "$registry_present" --argjson settings_present "$settings_present" '
    {registry:$registry,registry_present:$registry_present,settings_present:$settings_present, enabled:(if $settings == null then null
      elif $settings | has("enabledPlugins") then
        $settings.enabledPlugins | if type == "object" then . else null end
      else {} end)}'
}

fleet_capture_guard_target() {
  # Project-only rows and version changes never count as a user-state change.
  local id=$1 records=$2 observed=$3 state=${4:-unknown}
  jq -c --arg id "$id" --argjson observed "$observed" --arg state "$state" '
    def matches: if $id | contains("@") then . == $id else startswith($id + "@") end;
    def target: if . == null then null else with_entries(select(.key | matches)) end;
    (.registry | target | if . == null then null else
      [to_entries[] | select(any(.value[]?; .scope == "user")) | .key] | sort end) as $installed |
    (.enabled | target) as $settings |
    {installed:$installed, settings:$settings, manager_state:$state,
      uncertain:(any(.registry | target | .[]?;
        type != "array" or ([.[]? | select(.scope == "user")] | length) > 1 or
        any(.[]?; (.scope | IN("user","project","local","managed")) | not))),
      state:(if $state != "unknown" then
          # Capture already used the explicit state for this installed identity.
          [$installed[]? | $settings[.] | booleans] |
          if length == 1 then (.[0] | tostring) else $state end
        else [$observed.claude // {} | to_entries[] | select(.key | matches) |
          .value.value | select(IN("enabled","disabled"))] |
          if length == 1 then (.[0] == "enabled" | tostring) else "unknown" end
        end)}' <<<"$records"
}

fleet_capture_guard_live() {
  local records enabled query_ok=true
  # Bypass the plan's manager cache. Read the on-disk evidence after the query.
  enabled=$(fleet_run_apply_ctx= fleet_run_plugin_enabled "$1" true) || { enabled=unknown; query_ok=false; }
  records=$(fleet_capture_guard_records) || return 1
  fleet_capture_guard_target "$1" "$records" '{}' "$enabled" |
    jq -c --argjson query_ok "$query_ok" '. + {query_ok:$query_ok}'
}

fleet_capture_guard_remember() {
  # A retry must recognize this local change even if both pass scans failed.
  local id prior path baseline initialized updated
  id=$(jq -r --arg id "$1" --argjson before "$2" '
    if $id | contains("@") then $id
    else (($before.installed // []) + (.installed // []) | unique) |
      if length == 1 then .[0] else empty end end
  ' <<<"$fleet_capture_guard_current") || return 1
  fleet_capture_id_valid "claude:$id" || return 0
  prior=$(jq -r --arg id "$id" --arg initial "$3" '
    (if .state == "unknown" then $initial else .state end) as $state |
    if .installed == [] then "absent"
    elif $state == "true" then "enabled"
    elif $state == "false" then "disabled"
    elif ((.installed // []) | index($id) != null) and (.settings[$id] | type == "boolean") then
      if .settings[$id] then "enabled" else "disabled" end
    else empty end' <<<"$2") || return 1
  path="$(fleet_run_state_dir)/agent-baseline.json"
  baseline=$(fleet_capture_json_read "$path" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  updated=$(jq -c --arg id "claude:$id" --arg prior "$prior" --arg reason "${4:-}" --argjson initialized "$initialized" '
    if has($id) then .[$id].raced = true
    elif $prior != "" then .[$id] = {value:$prior,raced:true} | ._initialized = $initialized
    else . end |
    if $reason == "raced_removal" and has($id) then .[$id].raced_removal = true else . end
  ' <<<"$baseline") || return 1
  [ "$updated" = "$baseline" ] || fleet_capture_json_write "$path" "$updated"
}

fleet_capture_race_held() {
  local id=$1
  [ "${fleet_capture_race_holds:-[]}" != '[]' ] || return 1
  jq -e --arg id "$id" 'any(.[]; if $id | contains("@") then . == ("claude:" + $id)
    else startswith("claude:" + $id + "@") end)' >/dev/null <<<"${fleet_capture_race_holds:-[]}"
}

fleet_capture_guard_destructive() {
  # Every verb compares with its chain receipt, pass-start observation, or effective base.
  local expected=${2:-} initial=${3:-unknown} comparison
  fleet_capture_guard_current=
  [ -n "$expected" ] || [ -n "${fleet_capture_before_records:-}" ] || return 1
  if fleet_capture_race_held "$1"; then
    printf '  defer %s — a previous Claude change still awaits verification\n' "$1"
    return 1
  fi
  if [ -z "$expected" ]; then
    expected=$(fleet_capture_guard_target "$1" "$fleet_capture_before_records" \
      "$fleet_capture_before_observed") || return 1
  fi
  fleet_capture_guard_current=${4:-}
  [ -n "$fleet_capture_guard_current" ] || fleet_capture_guard_current=$(fleet_capture_guard_live "$1") || return 1
  comparison=$(jq -r --argjson before "$expected" --arg initial "$initial" '
    def changed($old): . != null and $old != null and . != $old;
    if .query_ok == false or .uncertain == true or .installed == null or .settings == null or
      any(.settings[]; type != "boolean") then "unobserved"
    elif (.installed | changed($before.installed)) or (.settings | changed($before.settings)) or
      # The CLI enabled state is checked on its own: settings must not mask an owner enable.
      ($before.state != "unknown" and (.manager_state | IN("true","false")) and
        .manager_state != $before.state) or
      (if $before.state == "unknown" then
        $initial != "unknown" and .manager_state != "unknown" and .manager_state != $initial
      else .state != "unknown" and .state != $before.state end)
    then "changed"
    elif .installed != [] and (($before.state == "unknown") != (.state == "unknown")) then "unobserved"
    elif (.installed != null and $before.installed != null) or
      (.state != "unknown" and $before.state != "unknown") then "stable"
    else "unobserved" end
  ' <<<"$fleet_capture_guard_current") || return 1
  if [ "$comparison" = changed ]; then
    fleet_capture_guard_remember "$1" "$expected" "$initial" ||
      printf 'roundhouse: could not remember the previous Claude observation for %s\n' "$1" >&2
    printf '  defer %s — its Claude observation changed during this pass\n' "$1"
    return 1
  elif [ "$comparison" = unobserved ]; then
    printf '  defer %s — no comparable Claude observation for this pass\n' "$1"
    return 1
  fi
}
