# roundhouse — Claude observation and local holds; desired state is never written here.
# shellcheck shell=bash

fleet_capture_mark_claude() {
  local id=$1 from=$2
  case $id in
    *@*) ;;
    *) id=$id@__unqualified__ ;;
  esac
  case $from in true) from=enabled ;; false) from=disabled ;; esac
  fleet_agent_pending_mark claude "$id" "$from" "$3" "${4:-}"
}

fleet_capture_claude_update() {
  # Version updates leave the observed enabled/disabled state unchanged.
  local id=$1 marker rc=0
  shift
  marker=$(fleet_agent_pending_path "claude:$id") || return 75
  fleet_capture_mark_claude "$id" unchanged unchanged || return 75
  "$@" || rc=$?
  rm -f "$marker" || return 75
  return "$rc"
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
  local dir baseline initialized discard rows fields id item theirs ours base first ambiguous unqualified
  local marker fallback fallback_id from merged direction kind message detail
  local skip=() discards=()
  fleet_capture_skip='{}'
  fleet_capture_discards='[]'
  fleet_capture_retry_unknown=$(jq -r '.retry == true' <<<"$observed") || return 1
  dir=$(fleet_run_state_dir)
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  discard=$(fleet_capture_json_read "$dir/agent-discard.json" '{}') || return 1
  fleet_capture_authoritative=$(jq -r --argjson baseline "$baseline" "$fleet_capture_authority_filter"'
    authoritative(.; $baseline; "claude")' <<<"$observed") || return 1
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  fleet_capture_race_holds=$(jq -c --argjson discard "$discard" '
    [.[] | select(.id != null and .ours == "unobserved" and (.base | objects | .raced == true)) |
      select($discard[.id] != true and $discard[.item] != true) | .id] | unique' <<<"$rows") || return 1
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
    if [ "$theirs" = malformed ] || [ "$base" = malformed ]; then
      skip+=("$item"$'\t'"$id")
      printf 'roundhouse: holding %s: malformed plugin state.\n' "$item"
      continue
    fi
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
    [ "$id" != claude:roundhouse@novotnyllc ] || continue
    marker=$(fleet_agent_pending_path "$id") || return 1
    if jq -e --arg id "$id" --arg item "$item" '.[$id] == true or .[$item] == true' \
      >/dev/null <<<"$discard"; then
      discards+=("$id" "$item")
      continue
    fi
    [ "$first" = false ] || continue
    from=${base#ignored:}
    [ "$from" != missing ] || from=absent
    ! fleet_agent_pending_matches "$marker" "$id" "$from" "$ours" || continue
    if [ "$unqualified" = true ]; then
      fallback_id=${id%@*}@__unqualified__
      fallback=$(fleet_agent_pending_path "$fallback_id") || return 1
      ! fleet_agent_pending_matches "$fallback" "$fallback_id" "$from" "$ours" || continue
    fi
    merged=$(fleet_merge3 "$base" "$ours" "$theirs") || return 1
    case $merged in local | conflict) ;; *) continue ;; esac
    case $ours in
      absent) direction=removed ;;
      *) case $base in missing | absent | ignored:absent) direction=added ;;
           *) if [ "$ours" = disabled ]; then direction=disabled; else direction=enabled; fi ;;
         esac ;;
    esac
    skip+=("$item"$'\t'"$id")
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
  if [ "${#discards[@]}" -gt 0 ]; then
    fleet_capture_discards=$(printf '%s\n' "${discards[@]}" | jq -Rn '[inputs] | unique') || return 1
  fi
}

fleet_capture_pass_prepare() {
  # STORE HOST DESIRED CLEAN FETCHED TMP LAYERS
  fleet_capture_before_records=$(fleet_capture_guard_records) || return 1
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

fleet_capture_guard_records() {
  # Keep independent evidence even when the manager inventory cannot be trusted.
  local registry settings
  registry=$(fleet_run_installed_plugins | jq -cse '
    if length == 1 then .[0] else null end') || registry=null
  settings=$(fleet_capture_json_read "$(fleet_run_settings_path)" '{}' 2>/dev/null) || settings=null
  jq -cn --argjson registry "$registry" --argjson settings "$settings" '
    {registry:$registry, enabled:(if $settings == null then null
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
  local records enabled
  # Bypass the plan's manager cache. Read the on-disk evidence after the query.
  enabled=$(fleet_run_apply_ctx= fleet_run_plugin_enabled "$1" true) || enabled=unknown
  records=$(fleet_capture_guard_records) || return 1
  fleet_capture_guard_target "$1" "$records" '{}' "$enabled"
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
  updated=$(jq -c --arg id "claude:$id" --arg prior "$prior" --argjson initialized "$initialized" '
    if has($id) then .[$id].raced = true
    elif $prior != "" then .[$id] = {value:$prior,raced:true} | ._initialized = $initialized
    else . end
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
  # Standalone supervised operations have no fleet-run observation to compare.
  local expected=${2:-} initial=${3:-unknown} changed
  fleet_capture_guard_current=
  [ -n "${fleet_capture_before_records:-}" ] || return 0
  if fleet_capture_race_held "$1"; then
    printf '  defer %s — a previous Claude change still awaits verification\n' "$1"
    return 1
  fi
  if [ -z "$expected" ]; then
    expected=$(fleet_capture_guard_target "$1" "$fleet_capture_before_records" \
      "$fleet_capture_before_observed") || return 1
  fi
  fleet_capture_guard_current=$(fleet_capture_guard_live "$1") || return 1
  changed=$(jq -r --argjson before "$expected" --arg initial "$initial" '
    def changed($old): . != null and $old != null and . != $old;
    (.installed | changed($before.installed)) or (.settings | changed($before.settings)) or
      (if $before.state == "unknown" then
        $initial != "unknown" and .manager_state != "unknown" and .manager_state != $initial
      else .state != "unknown" and .state != $before.state end)
  ' <<<"$fleet_capture_guard_current") || return 1
  if [ "$changed" = true ]; then
    fleet_capture_guard_remember "$1" "$expected" "$initial" ||
      printf 'roundhouse: could not remember the previous Claude observation for %s\n' "$1" >&2
    printf '  defer %s — its Claude observation changed during this pass\n' "$1"
    return 1
  fi
}
