# Codex plugin state alignment. Sourced by scripts/roundhouse.
# shellcheck shell=bash

fleet_codex_state_map() {
  jq -ecs '
    if length != 1 then error("invalid plugin list") else .[0] end |
    (if type == "array" then . else .installed end) |
    if type != "array" or (all(.[]; type == "object" and
      ((.pluginId // .id) | type == "string" and length > 0) and
      (.installed | . == null or type == "boolean") and
      (.enabled | type == "boolean")) | not) then error("invalid plugin records")
    else map(select(.installed != false) | {key:(.pluginId // .id),
      value:(if .enabled then "enabled" else "disabled" end)}) end |
    if (map(.key) | length == (unique | length)) then from_entries
    else error("duplicate plugin records") end' 2>/dev/null
}

fleet_run_codex_apply_state() {
  local listing states
  [[ $1 =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*@[A-Za-z0-9_-]+$ ]] || return 75
  listing=$(fleet_run_codex_list "$1") || return 74
  states=$(fleet_codex_state_map <<<"$listing") || return 74
  jq -er --arg id "$1" '.[$id] // "absent"' <<<"$states" || return 74
}

fleet_codex_registration_state() {
  local listing states config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  local complete=true registered='{}' baseline='{}'
  if ! listing=$(bounded_query codex plugin list --json 2>/dev/null) ||
    ! states=$(fleet_codex_state_map <<<"$listing"); then
    complete=false
    states='{}'
  fi
  if [ -e "$config" ] || [ -L "$config" ]; then
    if ! registered=$(yq -p=toml -o=json -I=0 '(.plugins // {}) | del(._default) |
      with_entries(.value |= .enabled)' "$config" 2>/dev/null) ||
      ! jq -e 'type == "object"' >/dev/null <<<"$registered"; then
      complete=false
      registered='{}'
    fi
  fi
  if [ "$complete" = false ]; then
    baseline=$(fleet_capture_json_read "$(fleet_instance_path store.run)/agent-baseline.json" '{}' 2>/dev/null) || baseline='{}'
  fi
  jq -ce --argjson registered "$registered" --argjson baseline "$baseline" --argjson complete "$complete" '
    . as $listed |
    ($baseline | keys | map(select(startswith("codex:")) | ltrimstr("codex:"))) as $tracked |
    {complete:$complete, entries:((($registered | keys) + keys + $tracked | unique) |
      map(select(test("^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*@[A-Za-z0-9_-]+$")) | . as $id |
        {key:$id, value:{listed:$listed[$id], registered:($registered | has($id)),
                         configured:$registered[$id]}}) | from_entries)}' <<<"$states" || return 74
}

fleet_codex_marked_verb() {
  # Mark before invoking Codex so even an interrupted verb cannot turn a lost sibling into a removal.
  local target=$1 before after ids id marker rc=0
  local marked=()
  shift
  before=$(fleet_codex_registration_state) || return 74
  ids=$(jq -r --arg target "$target" '.entries | keys[] | select(. != $target)' <<<"$before") || return 74
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    marker=$(fleet_agent_pending_path "codex:$id") || return 75
    [ ! -L "$marker" ] || return 75
    [ ! -e "$marker" ] || continue
    fleet_agent_pending_mark codex "$id" || return 75
    marked+=("$id")
  done <<<"$ids"
  fleet_agent_pending_mark codex "$target" || return 75
  fleet_run_cli_invalidate
  "$@" || rc=$?
  if ! jq -e '.complete' >/dev/null <<<"$before" || ! after=$(fleet_codex_registration_state) ||
    ! jq -e '.complete' >/dev/null <<<"$after"; then
    printf 'roundhouse: could not verify Codex registrations after changing %s; keeping the pending markers\n' "$target" >&2
    return "$rc" # The caller can still verify the target with its scoped listing.
  fi
  for id in ${marked[@]+"${marked[@]}"}; do
    if jq -e --arg id "$id" --argjson before "$before" '.entries[$id] == $before.entries[$id]' >/dev/null <<<"$after"; then
      marker=$(fleet_agent_pending_path "codex:$id") || return 75
      rm -f "$marker" || return 75
    else
      printf 'roundhouse: Codex registration for %s changed while operating on %s; holding capture\n' "$id" "$target" >&2
      [ "$rc" -ne 0 ] || rc=74
    fi
  done
  return "$rc"
}

fleet_codex_state_verb() {
  bounded_verb "$@" >/dev/null </dev/null || return 74
}

fleet_run_apply_codex() {
  # Use Codex for every mutation, then verify against its own record.
  local id="$1" want="$2" have node hooks
  case $want in enabled | disabled | absent) ;; *) return 75 ;; esac
  command -v codex >/dev/null 2>&1 || return 75
  have=$(fleet_run_codex_apply_state "$id") || return $?
  if [ "$want" = absent ]; then
    [ "$have" != absent ] || return 70
    fleet_codex_marked_verb "$id" fleet_codex_state_verb codex plugin remove --json -- "$id" \
      || return $?
    [ "$(fleet_run_codex_apply_state "$id")" = absent ] || return 74
    return 0
  fi
  if [ "$want" = enabled ] || [ "$want" != "$have" ]; then
    node=$(fleet_node_path) || return 75
  fi
  if [ "$have" = absent ]; then
    fleet_codex_marked_verb "$id" fleet_codex_state_verb codex plugin add --json -- "$id" \
      || return $?
    have=$(fleet_run_codex_apply_state "$id") || return $?
    [ "$have" != absent ] || return 74
  fi
  if [ "$want" != "$have" ]; then
    fleet_codex_marked_verb "$id" fleet_codex_state_verb "$node" "$script_dir/codex-plugin-hooks.mjs" "$want" "$id" \
      || return $?
    [ "$(fleet_run_codex_apply_state "$id")" = "$want" ] || return 74
  fi
  [ "$want" = enabled ] || return 0
  # Codex itself blocks hook execution until this host trusts the hook.
  hooks=$(bounded_query "$node" "$script_dir/codex-plugin-hooks.mjs" status "$id" \
    </dev/null) || return 74
  case $(printf '%s\n' "$hooks" | jq -er '"\(.modified | numbers) \(.untrusted | numbers)"') in
    '0 0') return 0 ;;
    '') return 74 ;;
    *)
      printf 'roundhouse: Codex hooks for %s are not approved: this host has an untrusted or modified hook; review it with approve-codex-plugin-hooks\n' \
        "$id" >&2
      return 75
      ;;
  esac
}
