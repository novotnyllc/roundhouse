# roundhouse — Claude observation and local holds; desired state is never written here.
# shellcheck shell=bash

fleet_capture_mark_claude() {
  local id=$1
  case $id in
    *@*) fleet_agent_pending_mark claude "$id" ;;
    *)
      # Before its first install Claude has not resolved the default market.
      fleet_agent_pending_mark claude "$id@__unqualified__"
      ;;
  esac
}

fleet_capture_skip_id() {
  # Resolve the qualified ID against the pass's observation-to-item index.
  printf '%s\n' "${fleet_capture_skip:-'{}'}" | jq -e \
    --arg id "$2" --arg name "${2%@*}" --arg harness "$1" '
      has("plugins." + $name) or has("plugins." + $id)' >/dev/null
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
      .claude != null and ((.claude[$id].value // "absent") == $state)' >/dev/null
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
  local dir fingerprint marker
  dir=$(fleet_run_state_dir)
  if [ ! -f "$dir/agent-baseline.json" ]; then
    command -v claude >/dev/null 2>&1 && return 0
    [ ! -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" ] || return 0
  fi
  for marker in "$dir"/agent-pending/*; do
    [ ! -e "$marker" ] || return 0
  done
  if [ -e "$dir/agent-discard.json" ]; then
    jq -e 'length == 0' "$dir/agent-discard.json" >/dev/null 2>&1 || return 0
  fi
  fingerprint=$(fleet_capture_fingerprint) || return 0
  [ "$fingerprint" != "$(cat "$dir/agent-fingerprint" 2>/dev/null)" ]
}

fleet_capture_prepare() {
  # STORE HOST DESIRED OBSERVED CLEAN FETCHED TMP LAYERS
  # Local differences and conflicts are held, never written into the store.
  local store=$1 host=$2 desired=$3 observed=$4 layers=${8:-$1}
  local dir baseline initialized discard rows id item harness theirs ours base first ambiguous
  local marker fallback merged direction kind message
  local skip=() discards=()
  fleet_capture_skip='{}'
  fleet_capture_discards='[]'
  fleet_capture_retry_unknown=$(jq -r '.retry == true' <<<"$observed") || return 1
  dir=$(fleet_run_state_dir)
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  discard=$(fleet_capture_json_read "$dir/agent-discard.json" '{}') || return 1
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  while IFS=$'\t' read -r id item harness theirs ours base first ambiguous; do
    [ -n "$item" ] || continue
    if [ "$ours" = unknown ]; then
      skip+=("$item")
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
    [ "$id" != claude:roundhouse@novotnyllc ] || continue
    marker=$(fleet_agent_pending_path "$id") || return 1
    if jq -e --arg id "$id" --arg item "$item" '.[$id] == true or .[$item] == true' \
      >/dev/null <<<"$discard"; then
      if [ "$theirs" != missing ]; then
        fleet_agent_pending_mark "$harness" "${id#*:}" || return 1
      fi
      discards+=("$id" "$item")
      continue
    fi
    fallback=$(fleet_agent_pending_path "${id%@*}@__unqualified__") || return 1
    [ ! -e "$marker" ] && [ ! -e "$fallback" ] || continue
    [ "$first" = false ] || continue
    merged=$(fleet_merge3 "$base" "$ours" "$theirs") || return 1
    case $merged in local | conflict) ;; *) continue ;; esac
    case $ours in
      absent) direction=removed ;;
      *) case $base in missing | absent | ignored:absent) direction=added ;;
           *) if [ "$ours" = disabled ]; then direction=disabled; else direction=enabled; fi ;;
         esac ;;
    esac
    skip+=("$item")
    kind=agent-local-change
    message="$id $direction locally; holding $item."
    if [ "$merged" = conflict ]; then
      kind=agent-capture-conflict
      message="$id $direction locally and changed in the fleet; holding $item."
    fi
    message="$message Edit the store to agree or run roundhouse fleet-discard $item to converge."
    printf 'roundhouse: %s\n' "$message"
    fleet_alert_raise "$7/alert-ledger" "$store" "$host" "$kind" "$kind" "$message" "$item" || return 1
  done < <(jq -r --argjson initialized "$initialized" '
    .[] | [.id // "-", .item, .harness, .theirs, .ours,
      (if .base == null then "missing" elif .base.ignored then "ignored:" + .base.value else .base.value end),
      ($initialized[.harness] != true), (.ambiguous == true)] | @tsv' <<<"$rows")
  if [ "${#skip[@]}" -gt 0 ]; then
    fleet_capture_skip=$(printf '%s\n' "${skip[@]}" | jq -Rn '[inputs | {key:.,value:true}] | from_entries') || return 1
  fi
  if [ "${#discards[@]}" -gt 0 ]; then
    fleet_capture_discards=$(printf '%s\n' "${discards[@]}" | jq -Rn '[inputs] | unique') || return 1
  fi
}

fleet_capture_pass_prepare() {
  # STORE HOST DESIRED CLEAN FETCHED TMP LAYERS
  fleet_capture_before_fingerprint=$(fleet_capture_fingerprint) || fleet_capture_before_fingerprint=
  fleet_capture_observed=$(fleet_capture_collect "$6/capture-before") ||
    fleet_capture_observed='{"claude":null,"retry":true}'
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
  fleet_capture_after_observed=$(fleet_capture_collect "$3/capture-after") ||
    fleet_capture_after_observed='{"claude":null,"retry":true}'
  if [ "$fleet_capture_retry_unknown" = true ] ||
    ! jq -e --argjson after "$fleet_capture_after_observed" '. == $after and .retry != true' \
      >/dev/null <<<"$fleet_capture_before_observed"; then
    : >"$dir/retry-owed" || return 1
    fleet_capture_after_fingerprint=$fleet_capture_before_fingerprint
  fi
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  rows=$(fleet_capture_rows "$5" "$4" "$fleet_capture_after_observed" "$baseline") || return 1
  extras=$(jq -cr --argjson initialized "$initialized" '[.[] |
    select($initialized[.harness] != true and .id != null and .theirs == "missing" and
      (.ours | IN("enabled","disabled"))) | .id] | join(", ")' <<<"$rows") || return 1
  if [ -n "$extras" ]; then
    fleet_alert_write "$1" "$2" agent-capture-ignored agent-capture-ignored \
      "Existing local plugins left in place: $extras." || return 1
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
        select((.ours == .theirs) or (.theirs == "missing" and
          (.base == {value:.ours,ignored:true} or (.ours == "absent" and .base == null)))) |
        .id,.item] +
      [select(authoritative($observed; $baseline; "claude")) | $decisions | keys[] |
        . as $key | select(all($rows[]; .id != $key and .item != $key))] | unique' <<<"$rows") || return 1
    discard=$(jq -c --argjson verified "$verified" 'delpaths($verified | map([.]))' <<<"$discard") || return 1
    if [ "$discard" = '{}' ]; then rm -f "$dir/agent-discard.json" || return 1
    else fleet_capture_json_write "$dir/agent-discard.json" "$discard" || return 1; fi
  fi
  printf '%s\n' "$fleet_capture_after_fingerprint" >"$dir/agent-fingerprint"
}
