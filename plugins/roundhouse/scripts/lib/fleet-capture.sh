# shellcheck shell=bash
# Claude observations are compared against this instance's agreed state in store.run.

fleet_capture_json_read() {
  [ ! -L "$1" ] || return 1
  if [ ! -e "$1" ]; then
    printf '%s\n' "$2"
  else
    jq -ces 'if length == 1 and (.[0] | type) == "object" then .[0] else error("expected one object") end' "$1"
  fi
}

fleet_capture_json_write() (
  mkdir -p "${1%/*}" || exit 1
  local tmp
  [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; } || exit 1
  tmp=$(mktemp "${1%/*}/.roundhouse-capture.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$1"
)

fleet_capture_id_valid() {
  case $1 in
    claude:*) [[ ${1#*:} =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*@[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] ;;
    *) return 1 ;;
  esac
}

fleet_agent_pending_path() {
  local id=$1
  fleet_capture_id_valid "$id" || return 1
  if [ "${#id}" -gt 200 ]; then
    id=$(printf '%s' "$id" | sha256_stream) || return 1
  fi
  fleet_instance_path "store.run/agent-pending/${id/:/.}"
}

fleet_agent_pending_mark() {
  local id=$1:$2 path record
  path=$(fleet_agent_pending_path "$id") || return 1
  record=$(jq -cn --arg id "$id" --arg from "$3" --arg to "$4" --arg via "${5:-}" \
    '{id:$id,from:$from,to:$to} + if $via == "" then {} else {via:$via} end') || return 1
  fleet_capture_json_write "$path" "$record"
}

fleet_agent_pending_matches() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  jq -se --arg id "$2" --arg from "$3" --arg to "$4" '
    length == 1 and (.[0] | .id == $id and .from == $from and
      (.to == $to or .via == $to) and $from != $to)
  ' "$1" >/dev/null 2>&1
}

fleet_capture_pending_ids() (
  local dir path id
  dir=$(fleet_instance_path store.run)
  for path in "$dir"/agent-pending/*; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    id=$(jq -er '.id | strings' "$path") || continue
    case $id in claude:*@__unqualified__) continue ;; esac
    [ "$path" = "$(fleet_agent_pending_path "$id")" ] || continue
    printf '%s\n' "$id"
  done
)

fleet_capture_listing_filter='
  def id_ok: type == "string" and test("^[A-Za-z0-9_-][A-Za-z0-9._-]*@[A-Za-z0-9_-][A-Za-z0-9._-]*$");
  def known_scope: IN("user","project","local","managed");
  def listing:
    [.[] | select(.kind == "plugin_manager" and .data.agent == "claude")] as $manager |
    [.[] | select(.kind == "plugin" and .data.agent == "claude" and .data.inventory_source == "manager")] as $rows |
    if ($manager | length) == 1 and $manager[0].status == "present" and
      $manager[0].data.authoritative == true and $manager[0].data.installed_count == ($rows | length) and
      all($rows[]; .status == "present" and (.data.manager_id | id_ok) and
        (.data.enabled | type) == "boolean" and
        .data.manager_id == (.data.name + "@" + .data.marketplace))
    then [$rows[].data | select(.scope == "user" or (.scope | known_scope | not))] |
      group_by(.manager_id) | map({
        key:.[0].manager_id,
        value:(if length == 1 and .[0].scope == "user" then .[0] else {uncertain:true} end)
      }) | from_entries
    else null end;'

fleet_capture_claude_observe() {
  local listing=$1 installed settings installed_path settings_path
  installed_path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  settings_path=$(fleet_run_settings_path)
  installed=$(fleet_run_installed_plugins) || return 1
  if [ -e "$installed_path" ]; then
    jq -es 'length == 1 and (.[0].plugins | type) == "object"' "$installed_path" >/dev/null || return 1
  fi
  settings=$(fleet_capture_json_read "$settings_path" '{}') || return 1
  local missing id path
  missing=$(jq -rc --argjson listing "$listing" --argjson settings "$settings" "$fleet_capture_listing_filter"'
    to_entries[] | .key as $id | select($listing[$id] == null and all(.value[]; .scope | known_scope)) |
    .value[] | select(.scope == "user") |
    [$id, ($settings.enabledPlugins[$id] | type), (.installPath // "")] | @tsv' <<<"$installed") || return 1
  local known_state
  while IFS=$'\t' read -r id known_state path; do
    [ -n "$id" ] || continue
    # A missing CLI row is admissible only for a damaged install with an
    # intact user record and explicit enabled state.
    [ "$known_state" = boolean ] && [ -n "$path" ] && [ ! -e "$path" ] || return 1
  done <<<"$missing"
  jq -cn --argjson listing "$listing" --argjson installed "$installed" \
    --argjson settings "$settings" "$fleet_capture_listing_filter"'
    (if $settings | has("enabledPlugins") then $settings.enabledPlugins else {} end) as $enabled |
    if ($enabled | type) != "object" or any($enabled[]; type != "boolean") or
      any($installed | to_entries[]; (.key | id_ok | not) or
        (.value | type) != "array" or (.value | length) == 0 or
        any(.value[]; type != "object")) or
      any($listing | to_entries[];
        .key as $id | .value.uncertain != true and all($installed[$id][]?; .scope != "user" and (.scope | known_scope)))
    then error("Claude records and plugin list disagree")
    else $installed | to_entries | map(
      .key as $id | ($id | split("@")[1]) as $market |
      [.value[] | select(.scope == "user")] as $user |
      any(.value[]; .scope | known_scope | not) as $uncertain |
      {key:$id, value:{
        value:(if $uncertain then "unknown"
          elif ($user | length) == 0 then "absent"
          elif ($user | length) != 1 then "unknown"
          elif ($enabled[$id] // $listing[$id].enabled) == true and $enabled[$id] != false
          then "enabled" else "disabled" end),
        marketplace:$market, user_scope:(if $uncertain then null else ($user | length) > 0 end)
      }}) | from_entries as $records |
      ($enabled | with_entries(select(.key | id_ok) | .value = {value:"unknown"})) + $records +
      ($listing | with_entries(select(.value.uncertain) | .value = {value:"unknown",user_scope:null}))
    end'
}

fleet_capture_observe() {
  local lists claude retry=false
  lists=$(jq -cs "$fleet_capture_listing_filter"'
    {claude:listing, retry:any(.[]; .kind == "plugin_manager" and
      .data.agent == "claude" and .status == "unavailable")}' "$1") ||
    lists='{"claude":null,"retry":true}'
  claude=$(jq -c .claude <<<"$lists")
  if [ "$claude" != null ]; then
    claude=$(fleet_capture_claude_observe "$claude" 2>/dev/null) || claude=null
  fi
  if jq -e '.retry' >/dev/null <<<"$lists" ||
    { [ "$claude" = null ] &&
      [ -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" ]; }; then
    retry=true
  fi
  jq -cn --argjson claude "$claude" --argjson retry "$retry" '{claude:$claude,retry:$retry}'
}

fleet_capture_collect() {
  local snapshot=$1/agents.jsonl rc=0
  mkdir -p "$1" || return 1
  if fleet_test_hook "${ROUNDHOUSE_SEED_SNAPSHOT:-}"; then
    cp "$ROUNDHOUSE_SEED_SNAPSHOT" "$snapshot" || return 1
  else
    collect_command --section agents --output "$snapshot" >/dev/null || rc=$?
  fi
  case $rc in
    0|2) [ ! -s "$snapshot" ] || { fleet_capture_observe "$snapshot"; return; } ;;
  esac
  printf '{"claude":null,"retry":true}\n'
}

fleet_capture_authority_filter='
  def authoritative($observed; $baseline; $h):
    $observed[$h] != null and
    (any($observed[$h][]?; .value | IN("enabled","disabled")) or
      all($baseline | to_entries[] | select(.key | startswith($h + ":"));
        .value | (if type == "object" then .value else null end) | IN("enabled","disabled") | not));'

fleet_capture_rows() {
  # Join desired item names to physical harness IDs. Claude can omit the
  # marketplace in YAML when the local inventory uniquely resolves its name.
  local definitions pending plugins markets name value market
  definitions=$(fleet_definitions_load "$1") || return 1
  pending=$(fleet_capture_pending_ids | jq -Rn '[inputs]') || return 1
  plugins=$(jq -r '(.plugins // {}) | to_entries[] |
    select(.key | test("^[A-Za-z0-9_-][A-Za-z0-9._-]*$")) | "\(.key)\t\(.value | tojson)"' <<<"$2") || return 1
  markets=$(while IFS=$'\t' read -r name value; do
    [ -n "$name" ] || continue
    market=$(fleet_run_plugin_market "$definitions" "$name" "$value" 2>/dev/null) || market=@
    if [ -n "$market" ] && ! fleet_capture_id_valid "claude:$name@$market"; then market=@; fi
    printf '%s\t%s\n' "$name" "$market"
  done <<<"$plugins") || return 1
  jq -cn --argjson desired "$2" --argjson observed "$3" --argjson baseline "$4" \
    --arg markets "$markets" --argjson pending "$pending" \
    "$fleet_capture_authority_filter$fleet_capture_listing_filter"'
    def state: (if type == "object" and has("state") then .state
      elif type == "object" then "enabled" else . end) |
      if IN("enabled","disabled","absent") then . else "malformed" end;
    def physical($h; $id): $h + ":" + $id;
    def plugin_rows($h; $category; $markets):
      ($observed[$h]) as $local |
      ($baseline | with_entries(select(.key | startswith($h + ":")))) as $base |
      ($local | keys? // []) as $local_ids |
      ($base | keys | map(ltrimstr($h + ":"))) as $base_ids |
      ($pending | map(select(startswith($h + ":")) | ltrimstr($h + ":"))) as $pending_ids |
      (($local_ids + $base_ids + $pending_ids) | unique) as $known_ids |
      (authoritative($observed; $baseline; $h) | not) as $unknown |
      [
        ($desired[$category] // {} | to_entries[]) |
        .key as $name | (.value | state) as $theirs |
        $markets[$name] as $market |
        (if ($name | id_ok) then [$name]
         elif $market == null or $market == "@" then []
         elif $market != "" then [$name + "@" + $market]
         else [$known_ids[] | select(startswith($name + "@"))] |
           [.[] | select($local[.].user_scope != false)] as $user_ids |
           if ($user_ids | length) > 0 then $user_ids else . end
         end) as $ids |
        (if ($ids | length) == 1 then $ids[0] else null end) as $id |
        ($category + "." + $name) as $item |
        {
          id:(if $id == null then null else physical($h; $id) end),
          item:$item, name:$name, harness:$h, ambiguous:(($ids | length) > 1),
          unqualified:($market == ""),
          marketplace:($id // "" | split("@")[1] // ""),
          theirs:(if $market == "@" or ($market == null and ($name | id_ok | not))
            then "malformed" else $theirs end),
          ours:(if $unknown and $local[$id // ""].value != "absent" then "unobserved"
            elif $id != null then ($local[$id].value // "absent")
            elif ($ids | length) == 0 and $theirs == "absent" then "absent"
            else "unresolved" end),
          base:((if $id == null then null else $base[physical($h; $id)] end) //
            (if $market == "" then $baseline[$item] else null end))
        }
      ] as $managed |
      [
        $known_ids[] as $id | ($id | split("@")[0]) as $name |
        select(all($managed[]; .id != physical($h; $id) and (.id != null or .name != $name))) |
        select($local[$id].user_scope != false or $base[physical($h; $id)] != null or
          ($pending_ids | index($id)) != null) | $id
      ] | group_by(split("@")[0]) | map(
        (length > 1) as $duplicate_name | .[] as $id |
        ($id | split("@")) as $parts | $parts[0] as $name |
        ($category + "." +
          (if $duplicate_name or any($managed[]; (.name | split("@")[0]) == $name)
            then $id else $name end)) as $item |
        {
          id:physical($h; $id), item:$item, name:$name,
          harness:$h, marketplace:$parts[1], theirs:"missing",
          ours:(if $unknown and $local[$id].value != "absent" then "unobserved"
            else ($local[$id].value // "absent") end),
          base:($base[physical($h; $id)] // $baseline[$item])
        }
      ) | $managed + .;
    ($markets | split("\n") | map(select(length > 0) | split("\t") |
      {key:.[0],value:.[1]}) | from_entries) as $market_map |
    plugin_rows("claude"; "plugins"; $market_map) |
    group_by(.id // .item) | map(if length == 1 then .[0]
      else .[] | .ambiguous = true end) |
    group_by(.item) | map((length > 1) as $duplicate | .[] |
      if $duplicate or .ambiguous == true then .ambiguous = true | .ours = "unknown" else . end)'
}

fleet_capture_initialized() {
  # Older baselines can only prove initialization for harnesses they recorded.
  jq -c '._initialized // {
    claude:any(keys[]; startswith("claude:"))
  }' <<<"$1"
}

fleet_capture_rebaseline() {
  local desired=$3 observed=$4 fetched=$5 layers=${6:-$1}
  local dir baseline initialized rows updated id settled
  [ "$fetched" = true ] || return 0
  dir=$(fleet_instance_path store.run)
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  # A first pass with no usable harness must still get a silent observation.
  if jq -e '.claude == null' <<<"$observed" >/dev/null; then
    return 0
  fi
  updated=$(jq -c --argjson base "$baseline" --argjson discard "${fleet_capture_discards:-[]}" \
    --argjson initialized "$initialized" --argjson observed "$observed" "$fleet_capture_authority_filter"'
    reduce (.[] | select(.theirs != "malformed" and (.ours | IN("enabled","disabled","absent")))) as $r ($base;
      if $r.ours == $r.theirs then
        .[$r.id // $r.item] = {value:$r.theirs} |
        if $r.id != null then del(.[$r.item]) else . end
      elif $r.id == null or $r.theirs != "missing" then .
      elif $r.ours != "absent" and
        ($initialized[$r.harness] != true or $r.base != null or ($discard | index($r.id)) != null) then
        .[$r.id] = {value:$r.ours,ignored:true}
      elif ($r.base | objects | .ignored) // false then del(.[$r.id])
      elif $r.base != null then .[$r.id] = {value:$r.ours,ignored:true}
      else . end) |
    ._initialized = (reduce ["claude"][] as $h ($initialized;
      if authoritative($observed; $base; $h) then .[$h] = true else . end))' <<<"$rows") || return 1
  if [ "$updated" != "$baseline" ]; then
    fleet_capture_json_write "$dir/agent-baseline.json" "$updated" || return 1
  fi
  settled=$(jq -r --argjson updated "$updated" '.[] |
    if .id == null and .ours == "absent" and .theirs == "absent" and
      $updated[.item] == {value:"absent"} then "claude:" + .name + "@__unqualified__"
    else select(.id != null and (.ours | IN("enabled","disabled","absent")) and
      ((.ours == .theirs and $updated[.id] == {value:.theirs}) or
       (.theirs == "missing" and
        (.base == null or $updated[.id] == null or .base == {value:.ours,ignored:true})))) |
      .id, (select(.unqualified == true) | (.id | split("@")[0]) + "@__unqualified__")
    end' <<<"$rows") || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    local marker
    marker=$(fleet_agent_pending_path "$id") || continue
    rm -f "$marker" || return 1
  done <<<"$settled"
}
